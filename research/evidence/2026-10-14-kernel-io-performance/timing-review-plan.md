# 内核磁盘 I/O 分项计时与读取等价性审查计划

日期：2026-10-14。编写者：signed_v6。本轮只读检查源码并提出计划，没有修改生产源码、运行基准、建立优化副本或操作 VM/AMFI。冻结 V9、当前 Task 8 验收及其工件保持。后续实施须使用 root 准备的独立副本与新证据路径。

已阅读 diagnosing-bugs 技能、CONTEXT.md、Task 8 回退实现及既有 performance-analysis.md。用户整体已授权独立优化工件实施；根任务将本子任务的计划编写阶段限定为只读计时方案审查，因此本代理当时未执行复现、插桩或修复。本文件不提供实测性能结论。既有静态调用次数和短采样仅用于确定插入点，不能作为全程耗时分摊。

## 测量顺序与待验证假设

1. 首先在保持现有 4 KiB 比较算法的独立副本加入分项计时，建立完整调用次数、逻辑读取量和单调时间基线。
2. 验证计时开启/关闭的输出与拒绝行为一致，并测量计时本身的开销。
3. 完成 capture/validate 读取粒度等价性矩阵，再仅把顺序读取缓冲增至约 1 MiB。持久块大小仍为 4096，offsets、cursor、pending、direction 和 interrupted block 语义不变。
4. 同输入、同计时方式对照 4 KiB 与 1 MiB，分别报告读取调用次数、阶段时间、完整操作时间与峰值 RSS。校验/恢复等价性是收益结论的前提。

待验证假设：重复全量 SHA、generation 原件验证、Store 严格验证和小粒度比较循环分别构成可见成本。先测各自时间和读取量；不能预先认定某一项占主导，也不能据读取调用减少推定完整操作必然加速。

## 计时与计数合同

使用单调时钟，记录 span_id、parent_span_id、operation、phase、调用点、对象角色、开始/结束/持续纳秒、成功或错误类别、实际读取字节、读取调用数、比较块数及写入字节。日期只用于运行元数据，不用墙上时钟计算持续时间。错误和取消也关闭 span，不把提前退出的部分读取计为完整文件。

每个 fileSHA 调用记录实际 consume 的字节，按调用点和对象角色汇总调用次数、成功/失败次数、累计逻辑字节及累计时间。重复读取同一文件每次均计数，不做去重；另列唯一对象及单次逻辑大小。fileSHA、treeDigest 原件读取、比较流、复制流、严格 Data 读取和签名 API 分开分类。逻辑字节指用户态读取返回的字节，不代表 SSD 物理 I/O；稀疏文件、APFS clone、页缓存和 Security 内部读取不能由此推算。

FileManager.copyItem、clonefile、hdiutil 和 Security 的内部读取量不可由上述 consume 计数得知，字节字段记为未知。可另记复制对象的逻辑大小，但不能把它当作实测读取量，也不能假定 APFS clone 按逻辑大小读取。fsync 同样只记录调用及时间，不编造同步字节。

父 span 的 inclusive 时间包含子调用。generation、verifyOrigin、Session.recheck、Store verifiedReceipt、capture 和 validate 之间存在嵌套，禁止把它们的 inclusive 时间直接相加。主报告保留调用树；同线程串行区间可用直接子区间的并集计算 exclusive 时间。并发或重叠 span 不使用简单减法。只有明确互不重叠的叶事件可以累计作为该类别的工作时间；累计工作时间也不等于操作墙上时间。按 parent/callsite 分组显示，避免把 treeDigest 的 readFile 字节再加到 generation 字节总量中。

块循环内只累计局部计数并在循环结束或错误退出时提交汇总，不逐 4 KiB 写日志，也不为每次比较都获取时钟。需要拆分读取与比较 CPU 时，以独立诊断运行或有限采样测量并单列其开销，不能把高开销逐块探针作为正式基线。

计时禁用时无额外文件访问；开启时不增加内容哈希、校验、同步、重试或取消检查。暂存内存中的固定大小统计项，避免记录 payload、整个 journal、逐块数组或任意文件内容。动态调用点键受限，防止 telemetry 自身随块数增长。

## 完整插入点清单

下表行号对应当前冻结源码，实施前在独立副本重新核对。名称和调用点用于区分重复执行，不能通过同名事件把不同校验点合并。

| 对象 | 插入点 | 分项及边界 |
| --- | --- | --- |
| 命令总耗时 | VPhoneVMUpdateKernelCLI / VPhoneVMRollbackKernelCLI | desired/history 准备、prepare、publish、recover/list/preview 各自计时；命令开始到结束单列。外部 wrapper 包括进程启动，不能与函数时间混用 |
| 锁与来源作用域 | FirmwareInstalledOrigin.withTrustedStore / withVerifiedSource；Store.withVerifiedExecutable / withRevalidatedExecutable；Transaction.withWorkerLock | Store/VM/worker 获取时间、回调执行与作用域结束分开；保留锁顺序、失效时点和原检查次数 |
| 更新准备与发布 | FirmwareKernelUpdate.prepare、publish、recheck | 三个 recheck 调用点分别命名；clone、真实 producer、Gate、region、重打包、artifact 写入、candidate 挂载写入、capture、report/receipt、commit 分开 |
| 回退历史 | FirmwareKernelHistory.read；FirmwareKernelRollback.targets/prepare；Selection.validate | 每个历史 transaction、历史证据读取/解码/关联、pristine 重建、live/target desired、generation 与源码资格分别记录；list 多目标不能混作单目标成本 |
| generation | FirmwareGeneration.loadVerified、verifyOriginals、treeDigest、readFile、originalURLs | 外层 loadVerified 分调用者；manifest 读取/解码、身份、目录枚举、每个原件递归及叶文件内容读取分开；originalURLs 内再次 loadVerified 继续记录，不缓存 |
| desired 与绑定 | FirmwareDesiredPlanStore.read/validate；FirmwarePlanBinding.capture/validate/currentCatalog | 区分 desired/manifest/identity/catalog 与其嵌套 generation，记录 currentCatalog 及 schema3/schema4，不改变 Gate/CAS |
| Store | VPhoneCoreBundleStore.verifiedReceipt:151–174 | secureTree、receipt 读取/解码/字段校验、requireBundleLayout、Bundle verify、各 executable cdhash 分开；记录 active callback 所在阶段 |
| 签名 API | VPhoneBundleCodeSignature.verify/cdhash/staticCode | SecStaticCodeCreateWithPath、SecStaticCodeCheckValidityWithErrors、SecCodeCopySigningInformation 分开。cdhash 内先 verify；Bundle nested 检查可能重复涉及 CLI/VM，内部实际字节未知，不编造字节量 |
| Session | Session.init、recheck、produceBinary | Store callback、CLI SHA、pristine 读取、解码、实际补丁算法、记录重建/effects、后置 source SHA 分开；真 producer 不用历史证据替代 |
| capture | FirmwareKernelDisk.capture:25–51 | identity、起始 disk/candidate SHA、两次 copyItem、双流比较、old/new/root 三次 sync、结束 disk/old/new SHA 分开；比较流计旧/新实际字节、read 调用、块数、变化块数、尾块长度 |
| validate | FirmwareKernelDisk.validate:54–100 | identity/offset/cursor 结构、old/new SHA、可选 interrupted SHA、三流比较、pending prefix 校验、最后 live EOF 探针分开；标记调用者 publish、commit-final 或 recover |
| 发布/恢复 | FirmwareKernelDisk.publish/reverse/readBlock/writeBlock | 前置 validate、每块源/目标读取、身份与 pread 检查、pwrite、Disk fsync、before/after durable cursor 保存、afterWrite hook、最终 Disk SHA 分开；仍按 4096 单块发布 |
| origin | FirmwareTransaction.verifyOrigin、commit(origin:) | point=candidate/published、prepared、bindingPublished、metadata 索引和调用点入标签；前置关联/hash、planBinding、validateReport、origin callback、尾部 output SHA 分开 |
| commit | Transaction.commit(qualifiedOrigin:) | ready/publishing 切换、Disk.publish、metadata 备份与发布、binding 发布、最终 disk.validate、committed journal、archive 分开；原阶段顺序保持 |
| 挂载与读回 | FirmwareKernelMount.withVolumes、InstalledReadback live operations | 镜像 mount 前 SHA、attach、inspect/association、body、DSC、detach、mount 后 SHA 分开。先用纯合成/适配测试，真实镜像和工具执行须由 root 后续单独安排 |
| report/receipt/proof | Transaction.saveReport/validateReport/readPublication/verifyPublication/prepareKernelReceipts；ComponentReceipt.verifyEffect | 严格读取、内容摘要、解码、Gate/effects、关联检查各自分项；kernel-only 的 publication.records 为空时不误记通用 receipt verify |
| 文件/目录同步 | KernelDisk.sync/writeBlock；Transaction.metadataDigest(sync:)/digest(sync:)/writeDurably/syncDirectory/move；Generation.write/copy/sync；KernelUpdate candidate handle.synchronize | 同步对象角色、调用点、次数、持续时间及错误。同步调用本身不知道内核物理写回字节，不以文件大小充当 fsync 字节 |
| journal | Transaction.saveJournal:882；writeDurably:949–963 | encode、临时文件创建与写入、beforeJournalSync hook、文件 synchronize、rename、父目录 fsync 分开。保存次数按 phase/cursor/pending/forward-reverse 记录，不改变编码字节或 journal schema |

## fileSHA 调用点清单

在 FirmwareGeneration.fileSHA256 入口用默认源码定位参数或明确只读上下文获取直接调用者；readFile 的叶级计数区分 fileSHA、treeDigest 和其他消费路径。不得只在 readFile 里记录一个总量而丢失上游阶段。以下为内核更新/回退实际关联范围的直接调用点；普通固件或 guest 旁路以对应标签记录，不混入内核成功路径计数。

| 文件及行号 | 对象/语义 |
| --- | --- |
| FirmwareKernelUpdate 32、204 | prepare 的 live Disk；每次 recheck 的 live Disk |
| FirmwareKernelUpdate 99、138 | clone candidate 核对；receipt 前 candidate imageSHA |
| FirmwareKernelUpdate 167、169 | origin callback 内 pristine input；该 point 的 candidate/live image |
| FirmwareKernelRollback 173、238 | history producer input；rollback prepare 的当前 Disk |
| FirmwareKernelMount 12、30 | 只读挂载前/卸载后的 image |
| FirmwareKernelDisk 29、30、48–50 | capture 初始 live/candidate；备份后 live/original/candidate |
| FirmwareKernelDisk 59、60、65 | validate original/candidate；可选 interrupted block |
| FirmwareKernelDisk 140、160 | reverse 最终 live SHA；publish 最终 live SHA |
| FirmwareInstalledOrigin 62、233 | Session 初始 executable SHA；每次 Session.recheck executable SHA |
| FirmwareInstalledOrigin 107、159、209 | producer input 后置核对；通用 commitBinary input；guest evidence 旁路 |
| FirmwareTransaction 142、187 | verifyOrigin 前部 output 与尾部 output；candidate kernelOnly 的跳过条件须原样保留 |
| FirmwareTransaction 163、169、784、792 | proof 当前关联；recovery committed proof/output |
| FirmwareTransaction 440、528、544 | filesystem proof 旁路；publication proof 旁路；所有 metadataDigest 的实际文件 |

补充测量 VPhoneFileDigest/VPhoneCreateDigest 的严格文件读取、内存 SHA 和 Transaction.digest；它们不全部经过 fileSHA256。用独立类别避免把 generation 树摘要、64 GiB 镜像纯 SHA 和内存 payload SHA 混在一起。计数以实际进入调用为准，guard 短路、异常、取消或 schema 条件不同均不能按静态清单补足次数。

## 计时输出不改变持久化语义

计时只附加在独立工件内，以不抛出新业务错误的内存收集器记录；不写入 journal、receipt、proof、desired、binding、generation 或历史归档。操作结束后由外围诊断入口输出到独立证据目录，不能在任一 durable intent、pwrite、fsync、cursor 更新或 rename 中间插入计时文件写入/同步。输出失败单独标记本轮测量不可用，不把原业务成功变成其他事务结果，也不能吞掉原业务错误。

不增删或重排 fsync、synchronize、rename、锁、校验、hook、取消点与错误处理。计时 wrapper 在失败 syscall 后必须先捕获返回值和 errno，再读取时钟/更新计数；避免诊断调用覆盖原 errno。Security status/CFError、原 throw 类型和恢复分支保持。Swift 6 并发统计须使用明确安全的同步/作用域，不能以 unsafe 全局可变状态逃避检查。数据收集有可测开销，不声称完全零扰动；因而必须比较未插桩与仅插桩基线。

## 1 MiB 读取等价性矩阵

优化范围仅限 capture/validate 顺序读缓冲。每个缓冲继续按 4096 的逻辑块、绝对文件 offset 逐项比较；块语义不跨缓冲。Data 切片可能 startIndex 非零，必须以集合索引正确计算区间，不能再次把相对偏移当作 Data 索引。发布/reverse 的 readBlock、pwrite、cursor 和每块同步不改。

| 实验设置 | 必须比较的结果 |
| --- | --- |
| 空、1字节、4095/4096/4097、1 MiB前后、两缓冲前后、非整块尾部 | capture 的 size、offsets 顺序/唯一性、original/candidate SHA；validate 成败及尾部 EOF 行为 |
| 零变化、首/中/尾块、相邻与跨1 MiB边界变化、全块变化、稀疏与普通文件 | 与4 KiB版完全相同的变化块集合；偏移仍按4096对齐，不能以1 MiB区块粗略替代 |
| original/candidate 长度不同、live截断/增长、old/new异常、链接/身份变化 | 原拒绝条件保持；不把较大缓冲的短读当作已验证EOF，错误时不发布部分成功结果 |
| forward/reverse，cursor=0/中间/末尾，pending true/false | 每个逻辑块按原公式选择old/new、pending边界和expected，不跨块使用prefix检查 |
| 合法pwrite前缀、零字节/全字节前缀、交错old/new未知修改、未列offset外部修改 | isWritePrefix及外部修改拒绝与4 KiB版一致，不能因缓冲含多个块而放宽 |
| interruptedSHA/index合法、缺失、越界、字节损坏、reverse中断后再次恢复 | interrupted block仍只替代对应4096块；pending reverse关系和最终SHA一致 |
| 人工短读、EOF、读取异常 | 通过读取适配测试明确旧/新版结果。read(upToCount:)不保证每次填满；若使用聚合补齐会改变旧版拒绝行为，须先单独定义并审查合同，不能直接宣称等价 |
| 注入journal、Disk写入、同步、receipt/binding/commit/archive失败及未知外部写入 | 现有恢复矩阵仍通过；操作/持久化事件顺序、durable cursor和错误结果保持 |

先用小型普通临时文件跑实际 capture/validate 与差分参考，构造确定性读错误和边界状态。测试必须能在跳过一个比较块、错误跨块prefix或遗漏尾部检查的临时 mutant 上失败；不修改冻结 V9。正确性通过后才测大文件，不用大基准替代拒绝测试。

## 收益测量与交付门槛

独立副本建立后冻结源清单、编译参数、优化级别、主机/系统、输入生成规则与摘要、稀疏/clone状态、逻辑大小、变更块数、运行顺序和其他I/O负载。仅在独立临时目录测试，不使用当前验收VM、源VM或冻结工件目录。

三组对照：未插桩4 KiB、仅插桩4 KiB、相同插桩1 MiB。分别测 capture比较循环、validate三流比较、包含原有SHA/复制/同步的完整capture及validate。先小输入确认，再由root决定固定大型输入；各组至少3次，交替顺序，保留每次原始值和中位数/范围。记录 warm-up；未经可控驱逐不把某轮称为冷缓存。不得为了测量清理系统缓存或并行争用当前验收I/O。

在完整、无短读且文件大小整除的普通读流中，1 MiB/4096=256，读取调用数具有约256倍下降的理论空间；应报告实际read次数和EOF探针，不能把它写成256倍速度收益。逻辑读取字节应保持；若减少，先解释是否漏读。RSS须记录峰值，读取时间、比较时间、SHA、同步及总耗时分别展示，不合并嵌套时间。

验收要求：全部差分/拒绝/恢复检查通过；内容、offsets及持久化合同不变；实际读取次数下降；阶段与完整操作时间有原始数据支撑，仪器开销可见；无未解释RSS增长或泄漏。若仅比较循环变快而完整操作无可分辨收益，按此结果报告，不提升结论。没有基线、噪声过大、语义不同或输出缺失时保持未验证。

本阶段交付仅此计划。等待 root 建立隔离副本后，再独立审查计时实现与测试边界；本计划不授权安装 Store 工件、启动 VM、扩大 AMFI 或热替换 V9。
