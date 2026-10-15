# 第一阶段计时工件独立审查补充：实际 trace

日期：2026-10-14。审查者：signed_v6。本记录补充 timers-stage1-independent-review.md，不覆盖旧审查。结论：保存的合成生产 helper trace 与 root 检查结果一致，实际读取次数、字节及父子区间核对通过；第一阶段已具备进入独立读取算法验证所需的计时证据。尚无 1 MiB 算法收益或完整 CLI 性能结论。

本代理仅读取冻结计时副本、合成测试源码、日志、trace 和检查结果，运行独立的保存数据分析脚本。没有重新运行 helper、Swift 构建、基准、VM、挂载、Store 或 AMFI。独立脚本 stage1-independent-production-probe-check.py 及同名 JSON 保留完整断言和文件摘要。

## 实际计数

输入 N=1048579 字节，即 1 MiB 加 3 字节。实际变化块为 4 项，持久块仍为 4096。

| 对象 | 实际结果 |
| --- | --- |
| capture 内 fileSHA | 5 次，累计 5242895 字节，即 5N |
| capture 比较 | 257 块；old/new 各读取 N 字节，各 258 次 read，包含各自 EOF 探针 |
| capture 同步 | helper 内 3 次 kernelDisk.fsync |
| validate 内 fileSHA | 2 次，累计 2097158 字节，即 2N；另 2 次 setup SHA 在 helper 外，已排除 |
| validate 比较 | 257 块；old/new/live 各 N 字节；read 次数分别为 257/257/258，live 包含最后 EOF 探针 |
| 消费回调失败 | generation.readFile 记录 error、实际 1048576 字节、1 次读取；对应源码与通过的 XCTest 直接检查抛出的原 Error 对象身份 |

独立按 parent_id 遍历所有后代，限定 helper 内 SHA 和比较流；没有仅按整个进程 group 总量推断。所有上述数值与 stage1-production-probe-check.json 逐项相等。

capture 外部 helper 窗口为 19897208 ns，root span 为 8265708 ns，比较 span 为 2594709 ns。validate 三项分别为 4091542、3985500、1409875 ns。外部窗口还包含第一次 recorder 访问和包装开销，差异没有独立分项；这些短探针不能作为稳定吞吐基准、完整 CLI 时间比例或优化收益。

## trace 完整性与运行关联

四份 trace 均通过分析器的协议、非负计数、父子存在/线程/包含区间及完整 footer 检查；没有 dropped、open span 或 io_error。对应运行日志均无 kernel-io-trace 错误，prefix 与唯一运行标签匹配，文件名、footer 和全部 span 的自报 PID 一致。读取前后摘要稳定。

两个 smoke 进程的标准日志明确自报 label、PID、operation 和单调测量窗口，独立核对各 helper root span 位于该窗口内。capture PID=94468，validate PID=96165。

production-probes 的两份 trace 分别为 PID 自报 847（1 事件）和 849（13961 事件），合计 13962。全部 phase 事件次数与 root 检查完全相等，generation、Store/签名、真实 journal、capture/validate/publish/reverse、同步等核心 phase 实际存在。847 的 partial consumer caller 与 XCTest 源码相符；849 的 phase 与其余 Swift Testing fixture 范围相符。

该 fixture runner 没有保存外部 subprocess/child PID，stdout 也未独立自报这两个 PID，因此本审查不宣称独立鉴定了进程类型。关联仅限唯一 prefix、测试范围、日志无 logger 错误和文件名/footer/span 的自报 PID 一致。root 已确认没有额外外部记录，不补造。未来正式基准应拒绝已有 prefix 文件，再共同核对 logger stderr、测试标准自报 PID/label/单调窗口与 trace，不能碰撞后读取旧 footer。

## 输入与范围

第一阶段源代码在 /private/tmp/vphone-kernel-io-timed-20261014 单独保全，原计时源码及缓存/二进制已经复制，第二阶段只在 optimization 副本实施。第一版源码/纯测试审查和本次实际计数检查共同建立第一阶段结论。

这些 fixture 是合成文件上的生产 helper 和真实 generation/Store/journal 测试，不是 Task 8 验收磁盘，也没有完整 CLI 分项覆盖。Security、clone、hdiutil 内部字节仍未知；fileSHA consumer 与 readFile 叶流不可双计，inclusive/aggregate 时间不可相加当墙上时间。第一阶段证据不改变冻结 V9、Task 8 标记调查或 AMFI 结论。

## trace 摘要

| 文件 | SHA-256 |
| --- | --- |
| stage1-smoke-capture.94468.jsonl | 5fffd10b8889784a7d62cdd5ebb606742f450b655306de28f6e95e4b4ac06e4c |
| stage1-smoke-validate.96165.jsonl | 8bb8ce6ecdad1bf135855dd9182e9bc834ede37459a7ac5f00bdee094d287253 |
| stage1-production-probes.847.jsonl | 652304aed6cd1dbeaf918eda0edef348989f5f2ff136368633df5d7cb3b2ce84 |
| stage1-production-probes.849.jsonl | 8bf52a7e99565d8e3b96c3aed8e49f378df98286e04b043a60d0240761d4edb2 |
