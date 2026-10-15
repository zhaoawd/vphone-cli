# 512 MiB 合成基准独立审查

结果：实际 24 个样本及结果汇总通过只读复核。6 个 warmup 排除，18 个 measured 样本按三组、两个操作、三轮计入。重新计算的中位数、范围和 RSS 数列与结果文件完全一致。本轮 optimized 相对未插桩 baseline 的完整 helper 耗时中位数下降：capture 12.92%，validate 47.29%。范围仅为 warm、512 MiB+3 字节的合成普通文件，不能表述为完整 CLI 或真实 VM 的加速。

| 操作 | baseline helper 中位数 / 范围（秒） | timed4k helper 中位数 / 范围（秒） | buffered1m helper 中位数 / 范围（秒） | baseline / optimized 比率 | 耗时下降 |
| --- | --- | --- | --- | --- | --- |
| capture | 1.907613459 / 1.893213542–1.920056166 | 2.415776208 / 1.931794791–2.438756166 | 1.661059458 / 1.636216083–1.733670583 | 1.1484 | 12.92% |
| validate | 1.368736792 / 1.348523416–1.596468666 | 1.357616792 / 1.346847875–1.396791500 | 0.721516042 / 0.699104666–0.763695500 | 1.8970 | 47.29% |

| 操作 | timed4k compare 中位数（秒） | buffered1m compare 中位数（秒） | timed / optimized 比率 | 比较阶段耗时下降 |
| --- | --- | --- | --- | --- |
| capture | 0.635480042 | 0.345068125 | 1.8416 | 45.70% |
| validate | 0.768465875 | 0.140184291 | 5.4818 | 81.76% |

`isolated-512m-controller.json` 为 exit0、69.287765 秒、未超时、无中断、cleanup_complete=true。该时间包括控制、准备和 warmup，不是单次 helper 或 CLI 时间。24 个 label、子 PID 和样本均唯一。warmup 顺序为 baseline→timed4k→buffered1m；measured 第 1/2/3 轮依次为 baseline→timed4k→buffered1m、timed4k→buffered1m→baseline、buffered1m→baseline→timed4k；每组均先 capture 后 validate。

所有原始 wrapper JSON、合并 stdout/stderr 日志和 16 个 trace 均重新读取。每个 wrapper 的 exact XCTest command、环境、120 秒边界、actual child PID、guard-held=true、exit0、无超时/中断、无清理信号、cleanup_complete=true/error=null 与样本关联。baseline 没有 trace；两个计时组均为 fresh prefix+相同 actual PID，footer 完整且没有 measurement incomplete。artifact root 锁由冻结控制器持有；Task8 锁和 pending/进程/附件检查由各 recorded wrapper 的正常 guarded 路径支持。原始 wrapper 未保存各次 ps/hdiutil/pending 的独立快照，本审查没有据此声称自行观察过实际进程或挂载状态。

所有输入均为 536870915 字节，original SHA `22cc91f262967b04f2af005ab2b4fe740119967c5e8782c01f399a3f61e6a688`，candidate SHA `8c21bc2f3c04efe527693165d9bdd91254b85207af9540dda1018372b4c17cab`。actual offsets 与独立计算值一致：`[0, 1044480, 1048576, 268435456, 536870912]`。每次比较 131073 个 4096 逻辑块，末块 3 字节；capture 变化块为 5 个。old/new/live 的实际字节与逻辑字节保持。

独立 trace 图与角色计数复核确认，helper 内 capture 每次 5 次 SHA（live 两次、candidate image 一次、original/candidate snapshot 各一次），validate 每次 2 次 snapshot SHA。包括 warmup 的 16 份 trace 共 40/16 次 measured-window SHA。每次 SHA 的 consume 和唯一 readFile 叶事件均为实际 536870915 字节、514 次读取尝试（含 EOF）；二者描述同一次读取，不重复累计。validate 各 trace 的两个 setup SHA 均在测量窗口之前，合计 16 次，未误计入 helper 的 2 次。compare 均为同一 helper 的后代且处于测量窗口，详细值与 observation 记录一致。

| 比较流 | timed4k 记录的 FileHandle API 尝试数 | buffered1m 记录的 native pread 尝试数 |
| --- | --- | --- |
| capture old/new，各流 | 131074 | 514 |
| validate old/new，各流 | 131073 | 514 |
| validate live | 131074 | 514 |

两列计数口径不同：FileHandle 的 API 调用不等于底层 syscall 数，native pread 列包含 EINTR/EOF/error 尝试。这里只报告各自实际计数，不将其比例表述为 syscall 或速度倍率。同步、复制和 SHA 等仍包含在完整 helper 时间中；父子 inclusive 时间及其聚合项没有相加作为总耗时。

timed4k capture 中位数为 2.415776208 秒，范围 1.931794791–2.438756166 秒，其波动原因未查明。不能把它与 baseline 的全部差额归因于计时器。每组仅三个 measured 样本；系统负载、频率及物理 I/O 没有受控归因，页缓存没有驱逐。RSS 是进程历史峰值，包含准备与初始化，不能等同于 helper 的瞬时内存或据此证明无泄漏。capture 的首次 trace 初始化可能在测量内，validate 的初始化可在准备阶段，这一设置差异已保留。

本审查没有重新读取三组大型二进制或系统 XCTest 工具来计算摘要；root/controller 已在执行前后校验该冻结工件合同。所有读取的原始证据摘要及前后稳定性检查、原始耗时数列、精确比率、轮次、PID 和计数保存在 `benchmark-results-independent-review.json`。没有调用任何业务入口、控制器、构建、基准、VM、AMFI、实际进程检查或挂载。当前结果不提供 64 GiB 完整操作、52 次 SHA 占比、Store/DSC/真实固件流程或 Task8 VM 的性能结论。
