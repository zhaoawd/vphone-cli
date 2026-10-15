# 第一阶段计时工件独立审查

日期：2026-10-14。审查者：signed_v6。审查结论：timers-only v2 源码及现有纯测试未发现阻断问题，可由 root 继续执行计时探针和基线。实际生产 helper 的 trace 字节/次数尚未由本审查核对，尚无性能收益结论；1 MiB 算法仍须按既定顺序在计时阶段完成后进入。

范围为隔离目录 /private/tmp/vphone-kernel-io-optimization-20261014。依据 timers-stage1-manifest-v2.json，13 项文件 SHA-256 全部匹配，当前 focused Package 也匹配。共享工作区 V9 的 16 项冻结源码摘要保持。本代理未构建 Swift package、运行基准、修改实施源码或操作 Store、VM、挂载、真实进程和 AMFI。

## 源码与语义

- capture/validate 仍逐 4096 字节读取、比较。变化 offsets、尾部处理、cursor、pending、forward/reverse、interrupted block、prefix 拒绝及 autoreleasepool 保持。读调用次数与返回字节在循环局部累计，外层 span 结束时提交；不逐比较块取时钟或写事件。
- fileSHA、readFile、treeDigest、loadVerified 保存调用点和父子关系。fileSHA 记录消费字节，readFile 记录实际成功返回字节，包括消费回调抛错前已读值；二者表示同一读流时不可双计。失败/短路只报告实际进入的调用，不按文件大小补计。
- Store 仍执行 secureTree、receipt/layout 和原有严格签名；cdhash 内仍先 verify。Security 内部字节未知。验证 flags、callback 有效期、真实 executable、锁、generation、Gate/CAS 与原校验次数保持。
- 共享 VPhoneKernelIOTrace 模块以线程内 stack 建立同步父子关系，记录单调时间、调用点、成功/错误与局部统计。事件数上限为 100000；丢事件或未结束 span 标为 incomplete，不改变业务返回或原 throw 对象。
- 所有 scope 只写内存；public flush 入口为 private，正常退出时 atexit 才以 O_EXCL 输出。没有在 intent、pwrite、fsync、cursor、文件 synchronize、rename 或目录同步之间插入 trace 文件 I/O。输出失败单独报告，原业务结果保持，旧输出不覆盖。
- 每块 readBlock/writeBlock、journal 和 fsync 在 publish/reverse 下仅按 phase 聚合，避免每块事件膨胀。聚合时间仍可能包含嵌套 encode/writeDurably/saveJournal，不能相加当总时间。
- v2 同时保全 public lazy recorder 初始化前和内部 stack/clock 前的入口 errno，在真实 fsync 前恢复；syscall 后立即保存 errno，诊断结束后恢复。同步调用次数及持久化顺序不变。errno 仅在失败 labels.error_code 中报告，不作为累计计数。

## 分析器与测试证据

独立运行分析器纯测试 10 项，退出 0，unittest 0.001 秒，wrapper 0.082 秒。测试前后分析器与测试脚本摘要一致，证据为 timers-stage1-independent-analyzer-tests.log/json。分析器拒绝缺 footer、incomplete、丢事件、未结束 span、错误协议/进程/线程/调用点类型、负数或布尔计数、缺失/循环/越界 parent 和重复 JSON/ID。同组重叠显式标记，并提供逐线程 interval union；不输出跨 phase 总时间。

root 统一构建并运行 timers-stage1-regressions-02，退出 0，30.826559 秒，包含 9 项 KernelIOTrace XCTest（0 失败、约 0.012 秒）及 38 项 Swift Testing（4 suite、0 失败、21.278 秒）。本代理只读取日志，未重复构建。计时测试覆盖禁用无输出、启用内存收集和顺序、父子区间/调用点、原 throw 对象和 stack、失败 EBADF、普通文件 fsync、E2BIG 成功路径对照、事件上限及输出失败不覆盖。回归包含 generation 实际脚本、kernel update/rollback 及签名 Store 测试。

E2BIG 测试对照公共入口和启用的独立 recorder；公共 static recorder 是否首次初始化取决于此前测试顺序，因此不把 lazy 首次路径记为独立实测。该入口的 errno 保存顺序已按源码复核。

首轮 timers-stage1-regressions-01 退出 1 的原记录保留；其 generation 脚本环境问题及后续 venv 修复由 root 记录。不能将首轮整体记为通过，也不将第二轮 wrapper 总时长当纯测试时间。

## 构建输入与限制

旧 timers-stage1.patch 的 Package 对照基线曾是简化 library manifest，原文件保留。后续 corrected-full-package 和 v2 patch 使用共享原完整 Package 与保存的完整 timers Package 对照。baseline/timers focused manifests 保存实际 Package SHA 及逐 target declaration SHA；原有 FW/Core/Archive/test 声明相应保持，FW/Store 增加 trace 依赖。实际构建输入以这些记录为准，不把 full Package SHA 当作 focused 构建输入。

首版核心测量覆盖 fileSHA/generation/Store/签名、capture/validate 比较流、fsync/journal。它未给所有 copyItem/clone、KernelMount attach/detach 和每个细分校验步骤提供独立 span，不能据此宣称完整 CLI 分项覆盖。复制、Security、hdiutil 内部读取量未知。helper 和 logger 输出时间应单独报告；原始调用流保留重叠，inclusive 或 aggregate 时间不能直接相加。

下一项证据应来自极小合成普通文件上的实际 capture/validate/readFile trace，核对长度、尾部 EOF 调用、失败已读量、父子包含和完整 footer，再建立未插桩/仅插桩基线。性能基准由 root 串行执行；未测试的 1 MiB 算法、真实磁盘、CLI 总收益或 Task 8 结论均不由本审查提升。

## 冻结摘要

| 对象 | SHA-256 |
| --- | --- |
| KernelIOTrace.swift v2 | 89800994c7c92f7431b60a37ec864120152a3ab39cf26dc42a09b1dd6f3de9dd |
| KernelIOTraceTests.swift v2 | be73e65fde0d9e3c5b38c7bb1902c4f4a24442a2d551b3bfdd37025d34ba68e7 |
| v2 patch | e8e947f86ce8ac32a0fdc910c3872e6752cb4cd398f5b891b282c3281cf2765c |
| analyze-trace.py | 9b9c92d3f8c3e0dfa75de3f906420d1ae438d04336d61f0b1baa7c4379cf4955 |
| test-analyze-trace.py | b060490069930009996883ed4aa3a85840470a874bf8f77df676ba3ade77c3e7 |
