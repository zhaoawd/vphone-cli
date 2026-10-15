# 三组基准控制工具初次独立审查

结果：存在执行及证据关联阻断，修正前不应运行正式三组基准。审查只读取研究目录脚本和冻结 Benchmark 源码，并执行 8 个纯函数/小型普通 JSON 文件测试。没有执行任何控制器入口、基准、构建、大文件 I/O、VM、AMFI、挂载或真实进程检查。源码摘要、测试日志及结构化结论见同名 JSON 和 `benchmark-controller-review-initial-tests.log`。

1. `run-recorded.py:53` 和 `run-benchmarks.py:122` 均没有子进程超时。子进程挂起时 wrapper 可持续持有 Task8 目录锁，也没有 timeout 的结构化失败产物。应限定本次创建的独立进程组，TERM 后有界等待，必要时 KILL 并 reap；任何超时都不能通过样本验收。外层等待应给 wrapper 留出清理时间，且退出或失败时 finally 释放已取得的锁。此结论来自代码，没有制造实际挂起进程。
2. `run-benchmarks.py:58–75` 未验证 `elapsed_seconds` 为有限非负值，也未核对其与 `elapsed_ns/1e9` 的对应关系。纯测试确认 NaN、-10 和 900 秒均可在 ns=90 时被接收，并进入汇总。还应对时钟、PID、字节、RSS 和声明 readsize 使用严格类型合同，拒绝 JSON NaN/Infinity 及重复键；输出端使用 `allow_nan=false`。当前只要求 offsets 与 expected_offsets 相同，纯测试确认二者同时空数组可被接收；应按已冻结输入构造规则独立计算期望 offsets。
3. `helper_trace` 的 SHA 限定为 helper 后代，但 compare 在整份 trace 中检索。纯测试确认 compare 可以作为另一个 root，且位于实际测量窗口之前。compare 必须是该次 helper 的后代。SHA 5/2 次及实际字节检查已有，但角色分布未检查：capture 应为 live_disk 两次、candidate_image 一次、original/candidate 快照各一次；validate 为两个快照各一次。纯测试确认五次 SHA 全为 candidate_image 仍可接收。实际读调用数与声明缓冲合同应按最终算法 trace 字段核对，不能把 runner 的 readsize 声明当成读取已验证。
4. 三组 variant 目前只验证名字顺序、隔离目录和 binary SHA，没有强制 common actual test-source SHA、相同编译 flags、实际构建记录或固定 trace/read_bytes 三组矩阵，也不拒绝三组指向同一工件。正式 freeze 应提供可核对的来源及构建记录，并由控制器验证冻结合同。wrapper JSON 目前仅校验 exit_code，应关联 exact command、environment_overrides、锁保持、超时状态、日志路径及本次创建的子进程身份。
5. `run-recorded` 持有 Task8 目录锁，但没有隔离 artifact root 锁；进程文本检查只覆盖 `/private/tmp/...`，缺 `/tmp/...` 别名。`prepare-test-manifest` 仅限制 root 路径，其 Package.swift 读写会跟随符号链接或硬链接；应拒绝这些文件类型，并在锁内保持 fd/路径身份。该工具先替换 Package，再独占创建 metadata，可能在结果文件冲突时留下已修改但记录不完整的 manifest；应在变更前保留独占证据输出。这里要求的是隔离写入边界，没有发现或声称现有副本实际存在链接。

已经具备的检查包括：每轮 trace prefix 新鲜性、trace/sample PID 一致、footer 完整性、父子线程和区间校验、SHA 实际字节、比较逻辑字节/块数、warmup 排除及前三轮 Latin 交替。summary 使用外部样本的 helper 时间及 compare 时间，没有把父子 inclusive 相加声称 CLI 总耗时。Benchmark 源码的 end clock 在结果检查之前；其输入为合成普通文件，未引用验收 VM 数据。

8 个测试中的负例目前是 `InitialBoundaryReproductions`，它们通过表示成功复现初版的误接收，不能作为正式控制工具已验收。工具修正后必须将这些断言反转为拒绝回归，并追加超时与锁释放的纯模拟测试。正式 24 次运行、三组实际来源/编译一致性和收益仍未验收。
