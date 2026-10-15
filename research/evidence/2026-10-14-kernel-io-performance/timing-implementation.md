# 第一阶段计时实现

实现仅位于 `/private/tmp/vphone-kernel-io-optimization-20261014`。本阶段保持 4096 字节比较与发布粒度，没有摘要复用、校验删减、额外内容遍历、同步删减或读取优化。共享仓库的 sources/tests、冻结 V9 和 Task8 Store/VM 数据未修改。最初补丁及 13 个文件摘要在 `timers-stage1.patch`、`timers-stage1-manifest.json`；errno 窄修正后的冻结为 `timers-stage1-v2.patch`、`timers-stage1-manifest-v2.json`，旧冻结保留。

新增独立 `VPhoneKernelIOTrace` target，由 FirmwarePatcher 和 VPhoneBundleStore 引用，依赖仅 Foundation/Darwin。单一 recorder 维护跨模块、同线程同步调用的父子关系，避免两份 internal 类型和并发日志竞争。所有本轮新增 Swift 文件与修改文件的 `swiftc -frontend -parse` 返回 0。该检查仅证明语法解析；Swift 构建和实际测试由 root 统一执行，本实现者未运行构建、Swift tests 或基准。

## 启用与完成协议

显式设置 `VPHONE_KERNEL_IO_TRACE=/absolute/output-prefix` 才启用。计时禁用时不创建 trace 文件、不调用额外 stat/hash/遍历；禁用 recorder 不生成 span UUID，也不解析路径标签。现有读取调用前后仍有轻量函数分支和局部计数，其成本须由未插桩与仅插桩对照测量，不能声称零扰动。

scope 内只收集内存事件，不创建、打开、追加或同步日志文件。完整进程正常退出时，atexit 统一写 `<prefix>.<pid>.jsonl`，使用 `O_EXCL`、`O_NOFOLLOW`、0600，不覆盖旧文件。不同子进程按 PID 形成独立日志。日志不执行 fsync，不进入业务 journal、receipt、proof、desired 或 binding。

内存上限为 100000 个事件。超限丢弃后续事件并标记测量不完整，不改变原业务返回或错误。输出失败不抛出新业务错误；退出阶段向 stderr 输出 `[kernel-io-trace] measurement incomplete`。进程异常终止可能没有输出；没有 terminal footer 的运行不可作为完整测量。业务操作自身拒绝时，只要所有 scope 和日志均完整，测量仍可为 complete，失败阶段由 outcome 标注。

每条 span 包括 `type=span`、`schema_version=1`、`id`、可空 `parent_id`、`pid`、`thread_id`、`phase`、`caller_file`、`caller_line`、`caller_function`、`started_ns`、`elapsed_ns`、`inclusive=true`、`outcome`、可空 `error_type`、`counts` 和 `labels`。可空 Codable 字段可能省略，分析时按 null 处理。开始与持续时间使用 DispatchTime 单调纳秒。错误仅记录类型，不输出错误消息、payload、原件字节、journal 内容或摘要内容。

末行 `type=measurement_end` 包含 schema/pid、`complete`、`events`、`dropped`、`open_spans` 和 `io_error`。必须有唯一末尾 footer，complete=true、dropped=0、open_spans=0、io_error=null，且 events 等于实际 span 行数。文件写入中途失败可能留下部分行或缺 footer，均应拒收；stderr 亦保留失败信号。

父 span 的时间和聚合计时均为 inclusive，禁止相加作为总耗时。`parent_id` 关联实际同步调用树，线程 ID 使用当前 Mach thread。发布与恢复在单个调用末尾输出统计；每块 readBlock、writeBlock、saveJournal、writeDurably、journal encode 和 fsync 的时间只累计到所属 publish/reverse span 的 `aggregate.<phase>.calls/elapsed_ns/success/error`。这些聚合项也存在嵌套，不能相加。每个比较循环只取外层开始/结束时钟，循环内只累计局部读取和块计数，不逐 4 KiB 输出事件或取比较时钟。真实 fsync 的分项测量仍在每个原有 fsync 调用前后取时钟，但只累计统计，原 fsync 次数不变。

## 调用覆盖与字节含义

| 对象 | 实现覆盖 | 计数与限制 |
| --- | --- | --- |
| FirmwareGeneration.fileSHA256 | 每次调用独立 span，默认 `#fileID/#line/#function` 取得直接调用者 | `bytes` 为实际 consume 字节，`consumer_actual`；与其 readFile 子事件描述同一次读取，不可重复累计 |
| loadVerified / verifyOriginals / treeDigest | 逐调用及递归 span，默认调用点，保留原校验次数 | 原件读取量由 readFile 子事件关联，不额外枚举或读取；父层不伪造 bytes |
| FirmwareGeneration.readFile | 每次流式调用与错误退出 | `stream_read_actual`；bytes 是每次成功 read 返回的字节，read_calls 在实际尝试前累计，含 EOF，消费闭包失败前已读字节仍计入 |
| Store verifiedReceipt | 外层资格检查，secureTree、receipt 读取/解码、layout 分项 | Security 与 Foundation 内部读取字节未知，不按文件大小推算 |
| Security verify/cdhash/staticCode | 外层、嵌套 verify、SecStaticCodeCheckValidityWithErrors 与 SecCodeCopySigningInformation | 调用和业务错误保持；原始 Security 非成功返回标记为 error。内部 bytes 未知 |
| KernelUpdate prepare/publish/publishQualified/recheck | 父阶段；recheck 默认调用者定位 | 可区分不同 recheck 入口及其嵌套 generation、Store、Disk SHA |
| InstalledOrigin.recheck / KernelRollback.prepare | 资格与回退准备父阶段 | 不删改来源检查或历史目标校验 |
| KernelDisk capture / validate | 完整调用及单独比较循环 | 比较流实际 old/new/live bytes/read_calls、完成块数、逻辑比较字节；capture 另记变化块数。validate 尾部 EOF 探针按实际调用及返回字节计数 |
| KernelDisk publish / reverse | 外层聚合范围，原 readBlock/writeBlock 与最终 SHA 保持 | 块操作及 journal/sync 聚合；没有逐块 JSONL 事件 |
| 原有同步 | Generation、KernelDisk、Transaction、DesiredPlanStore、PatchExperimentRecord 的直接 fsync；Generation/KernelUpdate/Transaction/BundleStore 的 FileHandle.synchronize | 只测原调用；fsync 字节未知，不填 bytes。公共入口保存 errno 后才访问 lazy recorder；内部保存入口 errno，经前置 stack/clock 后在真实 fsync 前恢复。syscall 后的 errno 在任何计时结束/统计之前保存，之后恢复；errno 仅作为失败 labels.error_code，不作为可累加计数 |
| Journal | saveJournal、encode、writeDurably、原文件 synchronize 和目录 fsync | 保留编码、beforeJournalSync、同步、rename、目录同步的原顺序；trace 文件输出只在整个进程退出后发生 |

路径标签仅包含 basename、推断 role 与 byte_semantics。role 包括 live_disk、original_disk_snapshot、candidate_disk_snapshot、candidate_image、interrupted_block、generation_original 和 file。basename 推断不证明文件身份；报告须同时结合调用点、父阶段和实际读取字节。生产 `kernel-candidate.img` 与合成测试 `candidate.img` 均归为 candidate_image，和归档候选快照区分。

本阶段没有为每个 copyItem/clonefile、mount、DSC、严格 Data 读取或内存 SHA 新增独立探针。它们可能包含在父阶段 inclusive 时间中，内部读取字节未知；不能用父阶段剩余耗时直接认定某一未测子项占用。此范围以 root 本轮明确要求的 SHA、generation、Store、比较循环、同步和 journal 为准。需要进一步归因时应追加独立阶段后重新冻结，不能从当前记录补造次数或 bytes。

## 普通文件测试入口

隔离副本新增 `tests/VPhoneKernelIOTraceTests/KernelIOTraceTests.swift`，v2 共 9 个测试函数。root 可统一执行 `swift test --filter KernelIOTraceTests`，使用其审定的 scratch 与构建配置。测试覆盖禁用无输出、启用仅内存且业务顺序不变、父子区间与调用点、原错误对象及栈恢复、非法 fd 的 fsync errno/返回、普通文件真实 fsync、事件上限的不完整 footer、输出失败不覆盖旧文件且不改变业务结果。v2 新增直接 Darwin.fsync 与启用 recorder / 公共入口的普通文件成功调用对照，使用 E2BIG 非零入口 errno。测试只使用普通临时目录/文件，没有 VM、客户机、Store、AMFI、hdiutil 或挂载。

root 报告首次 8 个 recorder 测试全部通过；同轮 Generation 两个 realScript 用例因隔离副本缺 `.venv/bin/python` 失败，root 正补齐脚本和 Python 环境。v2 新测试与受影响回归等待 root 统一执行，本实现者未自行运行。当前 focused Package 由 root 维护；v2 patch 的 Package before 使用原共享仓库 `fd8df9f…e262`，after 使用保留的 full timers `4eafc65…52b4`，没有将 focused 测试清单作为生产补丁。此阶段不能据语法解析或已编写测试宣称性能收益、完整运行等价性通过，或授权实施 1 MiB 优化。
