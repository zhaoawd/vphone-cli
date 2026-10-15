# 独立内核 I/O 性能验证结果

已按顺序完成分项计时、1 MiB 读取等价性回归和隔离基准。优化保存在独立工件，未安装、未热替换冻结 V9，未在 Task 8 验收磁盘运行基准。

## 实验设置

Apple M1、8 核、16 GiB 内存，macOS 27.0、Swift 6.3。三个副本均使用 release 构建、相同基准测试源码和构建参数；源码、测试二进制、Package、构建记录及 XCTest 工具摘要见 [benchmark-variants.json](benchmark-variants.json)。

输入为完整写入的 **536870915 字节（512 MiB+3）** 合成文件，含 5 个变更块。每次使用新 XCTest 进程，文件准备与准备阶段 fsync 不计入 helper 时间；capture 内原有复制、SHA 和同步仍计入。validate 准备阶段的两次 SHA 不计入 helper。采用暖缓存，不驱逐缓存。

每版本每操作预热一次，随后按三种轮换顺序各测三次：共 24 次调用，其中 6 次预热排除、18 次计入。每次检查 Task 8 无运行 VM、挂载或 pending；三个工件目录加排他锁。全部调用退出 0，未触发超时或清理信号。完整原始记录见 [observations](isolated-512m-observations.jsonl)，汇总见 [results](isolated-512m-results.json)。

[独立结果审查](benchmark-results-independent-review.md)复核 24 份调用记录、16 份 trace、轮换顺序、输入摘要、块偏移、SHA 角色与字节，并重新计算中位数和比例，通过。

## 耗时结果

下表为三次中位数；括号内为最小值至最大值，单位为秒。

| 操作 | 未计时基线：完整 helper | 仅计时、4 KiB：完整 helper | 计时、1 MiB：完整 helper | 相对未计时基线减少 |
| --- | ---: | ---: | ---: | ---: |
| capture | 1.908（1.893–1.920） | 2.416（1.932–2.439） | 1.661（1.636–1.734） | 12.9% |
| validate | 1.369（1.349–1.596） | 1.358（1.347–1.397） | 0.722（0.699–0.764） | 47.3% |

| 操作 | 仅计时、4 KiB：比较循环中位数 | 计时、1 MiB：比较循环中位数 | 比较循环减少 |
| --- | ---: | ---: | ---: |
| capture | 0.635 | 0.345 | 45.7% |
| validate | 0.768 | 0.140 | 81.8% |

仅计时 capture 的中位数高于未计时基线，且 SHA 与比较阶段均有波动。原因未查明；该差额不能全部归因于计时器开销。完整 helper 的收益采用未计时基线作为参照。系统负载、频率和物理 I/O 未受控；三次测量不建立统计置信区间。这些结果只覆盖本实验的合成 helper，**不能外推为 64 GiB 或完整发布命令的加速比例**。

## SHA、读取与比较计数

每次 capture 内仍有 5 次完整 SHA，逻辑字节合计 2684354575；每次 validate 内仍有 2 次，合计 1073741830。计时和 1 MiB 版本均核对实际 SHA 对象、调用点和父子关系。优化版本累计 SHA 耗时中位数分别为 capture 1.314 秒、validate 0.581 秒。未合并或跳过 SHA。

两版本均判断 **131073 个 4096 字节持久块**，得到相同的 5 个变更偏移；末块仅 3 字节。capture 的 old/new 流各读取 536870915 字节；validate 的 old/new/live 流各读取相同字节数。

| 操作 | 4 KiB 版本的读取调用计数 | 1 MiB 版本的读取调用计数 |
| --- | --- | --- |
| capture | old/new 各 131074 次 FileHandle API 调用 | old/new 各 514 次 native pread 尝试 |
| validate | old/new 各 131073 次、live 131074 次 FileHandle API 调用 | old/new/live 各 514 次 native pread 尝试 |

pread 计数包含 EOF、EINTR 和错误尝试；成功基准中每流为 513 次数据读取与 1 次 EOF。旧计数是 FileHandle API 调用，未测量其内部系统调用数，不能将上表写成系统调用减少 256 倍。

## 分项计时与范围

opt-in 计时记录调用点、单调开始时间、累计 inclusive 时间、实际流字节、结果及父子关系；正常退出时独占创建 trace，丢事件、未闭合 span 或 footer 缺失使测量无效。计时器保留 fsync 的返回值及 errno，不改变同步顺序。

先完成的 generation、Store/签名和事务合成探针共生成 13962 条完整事件。下面列出其中的部分累计值；探针含成功、预期拒绝与恢复场景，嵌套和并发计时会重叠，**各行不能相加或换算完整 CLI 占比**。

| 阶段 | 调用次数 | 累计 inclusive 秒 |
| --- | ---: | ---: |
| generation.verifyOriginals | 311 | 1.876 |
| generation.loadVerified | 291 | 1.913 |
| store.verifiedReceipt | 2 | 0.024257 |
| store.secureTree | 2 | 0.001774 |
| security.SecStaticCodeCheckValidityWithErrors | 9 | 0.026371 |
| transaction.saveJournal | 54 | 0.256682 |
| transaction.writeDurably | 96 | 0.060925 |
| FirmwareTransaction.fsync 独立 span | 177 | 0.000381 |

按调用点的字节、时间、结果与计数见 [component-timings.json](component-timings.json)。publish/reverse 内的子操作使用聚合计数，不能再当独立 span 重复计入。Security、文件复制、hdiutil 内部字节量未推算；完整 CLI 的 52 次整盘 SHA 仍是成功路径静态计数，其全程耗时占比尚未动态测定。

## 等价性与恢复验证

- 7 项差异与恢复测试通过：覆盖 0/1/4095/4096/4097 字节、1 MiB 边界与多批次尾部；块偏移、发布及恢复结果相同；forward/reverse pending 前缀、写入中断、外部篡改、长度变化和身份替换按测试矩阵拒绝或恢复。
- 10 项读取测试通过：覆盖短读、EINTR、提前 EOF、读取错误、部分读取后错误计数、偏移与计数溢出、文件描述符当前位置保持及非零 Data 索引。
- 尾部增长回归先实际失败：原件与候选在末尾不足块读取前增长均未被拒绝。补齐 old/new/live EOF 检查后，同一回归通过。编译失败与实际 RED、GREEN 分别保留。
- 更新/回退定向 Swift Testing 为 18 项实际通过、2 项真实 fixture 入口跳过；计时器 9 项通过。内存父测试通过，另有 1 个仅供子进程调用的入口跳过；4 个实际内存子操作均通过。峰值增长分别为 capture 3014656、validate 2326528、publish/reverse 各 2457600 字节。

capture 主扫描缓冲上限 2 MiB，validate 为 3 MiB，pending 分支另有最多 12 KiB 的块副本。上述容量不包含原有 offsets、SHA/复制内存或 trace；ru_maxrss 是进程历史峰值，不能作为精确分配量。发布、恢复、readBlock、writeBlock 与同步代码段和仅计时副本逐字节相同。

证据见 [回归记录](stage2-green-regressions-02.json)、[独立源码与 trace 审查](stage2-independent-review.md)、[阶段二 patch](stage2-artifact-stage2.patch) 与 [冻结 manifest](stage2-artifact-manifest.json)。patch 对仅计时副本的 `git apply --check` 通过；未实际应用到该冻结副本。

[最终保持核对](final-preservation-check.json)通过：原共享源码/测试等 843 个文件、冻结 V9 的 16 个源码文件与已安装 CLI 摘要保持；三份独立工件的源码、测试二进制、Package、构建记录及工具摘要均与基准前一致。现有未提交修改保留，未提交 Git。完整证据文件摘要见 [final-evidence-manifest.json](final-evidence-manifest.json)。

## 验收问题分别跟踪

Task 8 的 A 更新、B 更新、公开回退 A 的实际读回和第四版启动已通过。原 description、PAYP 和外围保留有先前读回证据。本轮保持这些工件与验收状态。

**数据标记丢失：**旧 tmp 标记在回退 A 后为 ENOENT，数据保留验收未通过，原因未查明。新 Documents 标记只通过同一实例内 sync 与实际读回，停机落盘和跨回退保持仍待验证。离线原盘 Data 加密且锁定，诊断按约定拒绝读取；没有据此推断标记内容。

**amfid 停止：**B 临时驱动 detach 后同进程仍停止，严格核对身份后 SIGCONT 恢复；原因未查明。回退 A 后外部核验为运行，未发送恢复信号。本轮未操作 AMFI，不将该问题与内核发布耗时合并归因。

单次 verifyOrigin 内合并 SHA、capture 摘要与比较融合、跳过 metadata 循环重验、跨阶段缓存及 fsync 批量化均继续后置，须单独设计验证作用域、内容稳定性证据和故障恢复矩阵。
