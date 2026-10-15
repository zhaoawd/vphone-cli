# 第二阶段源码、恢复、内存与小样本 trace 独立审查

结论：冻结的 1 MiB 读取实现、已覆盖的合成文件恢复回归、内存回归及两份小样本 trace 未发现阻断。正式三组基准尚未完成；本审查不判断性能收益、完整 CLI 耗时或真实 VM 行为。审查只读取源码和已保存证据，并运行纯 Python 校验脚本，没有构建、运行基准、发送 guest 请求或操作 VM、Store、AMFI。

校验脚本为 `stage2-independent-check.py`，结构化结果为 `stage2-independent-review.json`。脚本重新计算冻结文件、日志、trace 和三组实际测试二进制的 SHA256，并以独占创建方式保存结果。脚本通过，未重新执行 Swift 测试或业务 helper。

## 源码与拒绝边界

隔离副本 `/private/tmp/vphone-kernel-io-optimization-20261014` 的 manifest 共 8 个文件全部匹配，永久证据副本也匹配。生产文件 SHA256 为 `01711a3a9aab78984daea314ca25d773cbf650fdf39ceab7961cacf55321c6e1`；新增 reader 测试 SHA256 为 `cfeb9d0b53596f33ddd395f5eaf327c7a13a3aef13485176a2357e7054674237`。共享工作区 V9 manifest 列出的 16 项 source/tests 摘要全部保持。

capture/validate 使用已打开普通文件的已知长度，每次最多填充 1 MiB，再逐 4096 字节判断。offsets、cursor、pending 和 interrupted 的含义及持久化写入单位保持。所有批内切片从各自 `Data.startIndex` 推导；pending 路径将三个逻辑块转为零起点副本，避免非零起点切片与 interrupted 文件数据混用。isWritePrefix 至 reverse、publish、readBlock、writeBlock、sync 和 struct 结尾，与冻结 timers 副本逐字节一致。

reader 在同一 fd 上执行显式偏移的 pread，不拥有或关闭 fd，不改变 descriptor offset。正短读继续填充；EINTR 在相同偏移重试；提前 EOF、其他错误、非法返回量及范围或计数溢出均拒绝。失败前已经获得的正数字节仍计入实际读取量。每批和每个逻辑块保留 autoreleasepool。主扫描缓冲逻辑容量上限为 capture 2 MiB、validate 3 MiB；pending 三副本合计最多 12 KiB。这些数值不代表总 RSS，不包含 offsets、trace 或原有 SHA/复制工作内存。

初稿 validate 只探测 live EOF，遗漏 old/new 在最后不足块读取前增长的拒绝边界。RED01 因 stride 参数类型错误而编译失败，不能作为功能 RED。RED02 实际执行 1 个 XCTest，original/candidate 两个案例均因未抛错产生断言失败，共 2 failures。冻结修正按 old → new → live 顺序在 size 偏移探测 EOF；guard 保持短路，未执行的探测不计数。GREEN02 中同一增长测试实际通过。GREEN01 的 clang ModuleCache 沙箱权限失败单独保留，未作为业务失败或通过证据。

等价目标限定为稳定普通文件的 4096 字节逻辑判定。已知长度预检和正短读填充具有明确的拒绝条件；批量读取改变多流读取窗口，因此这些回归不能证明任意并发修改时序下的观察完全相同。

## 实际回归与内存

`stage2-green-regressions-02.json/log` 记录 exit 0，wrapper 用时 93.72077549993992 秒，未超时或中断。XCTest 父进程选择 28 项，其中实际通过 27 项、跳过 1 项：10 reader、7 equivalence、9 recorder、1 memory parent 实际通过；memory child 入口在父进程跳过，另由父测试启动 4 个独立子操作，均实际通过。

7 个 equivalence 测试覆盖空文件、4 KiB 和 1 MiB 两侧及尾块、逐 4096 块 offsets、publish/reverse 往返、双方向全部 4097 种合法写入前缀、pending/interrupted 恢复、每个变化块的保存及写后失败、未知字节、长度和 inode 变化、批次边界写前变更保留。上述结论来自实际 helper 的合成普通文件测试，不扩展为真实 VM 验收。

Swift Testing 汇总为 20 tests、2 suites；独立数得 18 项实际通过，2 项真实 fixture 入口跳过：`actualPublicForceExcGuardPlansProduceDifferentPayloads` 和 `actualCandidateRegionUsesSourceFlow`。包含 kernel update/rollback 已覆盖的拒绝、恢复、历史关联及数据保持测试；未把跳过项写成已执行。

| 操作 | 输入字节 | ru_maxrss 前值 | ru_maxrss 后值 | 增量字节 |
| --- | ---: | ---: | ---: | ---: |
| capture | 67108867 | 25657344 | 28672000 | 3014656 |
| validate | 67108867 | 27525120 | 29851648 | 2326528 |
| publish | 16777219 | 27623424 | 30081024 | 2457600 |
| reverse | 16777219 | 27607040 | 30064640 | 2457600 |

这是每个独立子进程中 Darwin `getrusage` 的 ru_maxrss 前后差，均低于测试既有的 capture/validate 64 MiB、publish/reverse 16 MiB 阈值。该指标支持本次已执行的内存回归通过，不能单独证明任意输入的精确常驻内存上限。

## 实际小样本 trace

两次 direct xctest smoke 输入均为 1048579 字节，实际子进程 PID 分别为 capture 54839、validate 55293。对应 prefix 当前各仅一份 trace；文件名、footer、全部 span、wrapper child PID 和标准输出自报 PID 一致。footer 完整、父子区间有效，helper span 位于相同标准输出单调时钟窗口内，日志没有 logger 错误。对既有文件的复核没有补造运行前 prefix 状态。

| 操作 | 已完成逻辑块 | 每流正数字节 | 每流 native pread attempts | helper 内 SHA 次数/字节 | helper 内 fsync |
| --- | ---: | ---: | ---: | --- | ---: |
| capture | 257 | old/new 各 1048579 | old/new 各 3 | 5 / 5242895 | 3 |
| validate | 257 | old/new/live 各 1048579 | 三流各 3 | 2 / 2097158 | 0 |

每流 3 次包含两个数据读取和一次 EOF 探测；成功 EOF 计一次尝试、零正数字节。capture 的 SHA 角色为 live 两次、输入 candidate 一次、original/candidate 快照各一次；validate 仅两个快照各一次，准备阶段两个 SHA 位于 helper 外。helper 后代关系、角色、实际字节和 compare 字段均独立核验，未依赖 runner 的 readsize 声明代替实际 trace。

capture trace SHA256 为 `a3b8dcf7f4704c0b796857bae37e34f953d66e7e99e0cc2e18d2378b53d97bc1`，validate 为 `82534263eae02a1fe506dc617121b0f5ca96a5cc5482bced4bc7f2a6d0c0fee1`。native pread attempts 包含 EINTR、EOF 和错误；baseline 计数是 FileHandle API 调用次数，未观测其内部 syscall，不能据两者相除声称实际 syscall 收益。

三组 variant 的实际 binary、source、Package、共同 benchmark 测试、成功构建记录及 xctest 工具 SHA 均匹配声明，三组 binary SHA 不同，声明编译 flags 相同。timed 副本保留原 optimization 编译路径，记录明确。该检查只确认本轮冻结工件和记录关联，不替代尚待执行的正式多轮基准。小样本耗时、嵌套 inclusive 时间和首次 recorder 开销未相加，也未推算完整 CLI 比例。
