# T30：Swift 测试同步与标准回归复核

日期：2026-10-15。使用 diagnosing-bugs 方法；范围为测试同步机制及标准 firmware-free Swift 验证。未操作真实 VM、AMFI、TCC 或安装工件。

## 原始问题与基线

上轮 `parallel-three/swift.log`、`swift-final.log` 在常规 Swift Testing 失败。共同问题是 `startedWorkerIOFailureWaitsAndDrainsBeforeUnlock` 的观察者等待、完成标记和恢复文件断言；第二轮还出现 `EnvironmentOperationTests` 的释放信号量超时、重叠写入和已关机拒绝。

本轮首先运行原命令 `make test_swift`，再次复现 worker 观察者等待超时；随后出现创建取消、子进程准备等失败。运行超过 10 分钟后，已失败基线被主动结束，以进行最小复现。`baseline-stop.json` 记录已核实属于本轮 `run_tests.py swift` 的进程树。该轮未完整结束，不作完整测试统计或通过声明。只读进程检查还观察到其他任务及应用消耗 CPU；这项相关观测不作为上述失败根因结论。

## 假设

1. worker 测试观察者在共享 Dispatch 队列排队，超过子进程 15 秒期限；专用观察者线程应消除这项依赖。
2. 环境写入测试在 `Task.detached` 中同步等待信号量，占用合作执行器；限制合作线程时应稳定失败，异步等待结合独立写入线程应通过。
3. 生产 worker 的锁定或输出排空错误；观察者及时执行时仍应失败。
4. 子进程未正确启动或输出；应在观察者等待之前出现 started 缺失或启动错误。

## 环境写入：最小红绿

命令：`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --skip-build --disable-sandbox --cache-path .build/test-cache --filter EnvironmentOperationTests/guestGateExcludesConcurrentWritersWithoutBlockingOrdinaryReads`。

- 原测试：5.049 秒，8 issues；释放信号量超时、重叠写入、shutdown sealed，与完整测试中的现象相同。见 `environment-strict-red.log`。
- 第一版修改仅在测试：同步 writer 改由 `Thread.detachNewThread` 执行，异步事件把进入和完成状态送回原测试任务。该版本在最小实验通过，但后续全量仍失败：测试主体恢复执行时 writer 的 5 秒期限已经结束。因此该版本被后续实现替代。
- 同命令：0.002 秒通过，见 `environment-strict-green.log`。

此对照确认原测试同步机制占用合作执行器，导致测试自身不能及时释放 writer。最终实现把两个同步参与者均放在专用线程，入场、释放和完成等待各保持 5 秒；完成结果通过 continuation 返回原测试任务断言。`Mutex` 保护 writer 的结果；各拒绝断言同时确认方法抛错且没有执行 body。未修改 `GuestMaintenanceGate` 生产逻辑。

临时在 writer 入场前延迟 6 秒，最终实现于 5.001 秒抛出 ETIMEDOUT，证明入场等待有界；探针随后删除。见 `deadline-cleanup-red.log`。最终实现在单合作线程、同时运行事务测试的设置下仍通过，见 `final-focused-strict.log`。

## worker：受控队列对照

临时在测试夹具中加入 64 个等待共享队列任务，由独立线程在 17 秒后释放。注入发生于实际 child 的 started 标记出现后。原生产 `FirmwareTransaction.run` 的同步 read/wait、子进程 15 秒 alarm、测试 10 秒 observer 等待以及 4 MiB 输出断言均保持。

- 原共享队列观察者：`fileOutput=false` 的 64 个占位任务均确认开始，观察者排队 17.001703 秒才开始；child 已 started、仍无 done。实际完成及恢复锁断言失败。见 `worker-saturated-red.log`。
- 只把观察者替换为 `Thread.detachNewThread`：相同 `fileOutput=false` 占位任务均确认开始，观察者在 0.000055 秒开始，完整输出、锁和恢复断言通过。见 `worker-saturated-green.log`。
- 同时运行的 `fileOutput=true` 参数中，两轮占位任务开始等待均超时，不能宣称这组确认了全部 64 任务开始。该参数原观察者延迟约 15 秒并失败，改后延迟约 0.000081 秒并通过；严格配对的因果结论以首个参数为依据。

本实验支持测试观察者排队导致子进程先到期。生产 drain 实现在调用线程同步读取，不依赖这个测试全局队列。最终仅保留观察者专用线程及解释性注释；临时压力注入和 DEBUG 探针全部删除。

## 中间版本定向验证

`swift test --disable-sandbox --cache-path .build/test-cache --filter 'EnvironmentOperationTests|NativeTransferTests|FirmwareReceiptPublicationTests'`：29 项、3 suites 通过，17.396 秒。包括并行传输取消任务新增的回归。该轮 Environment 仍为单 writer 线程加异步事件的中间版本，不能作为最终双线程实现的验证。见 `focused-green.log`。

合并构建曾发现传输取消任务的旧尾随闭包调用及测试宏表达式编译错误，已由该任务修复；`intermediate-build-failure.log` 保留其中一次失败。该问题与本次两处同步根因分开记录。

## 标准回归中的退出夹具问题

第一轮修复后 `make test_swift` 记录在 `standard-final.log`。worker 通过，环境测试尚为中间版本并失败；另有 HTTP/WebSocket、代际准备、VMRuntimeEntry、退出时限失败。运行静止后只读采样发现 `VPhoneLaunchpadChildProcess` 的 stdout reader 等待 `read`；未完成测试为 `terminationWaitsForOrdinaryPanicTailAndClosedLog`。该测试在 `prepareForTermination` 断言失败后仍无界等待 `run.value`，shell fixture 有无限循环。该轮被主动结束，进程树见 `standard-stop.json`，调用栈见 `standard-stall.sample.txt`。

中间方案曾增加 ready 后 10 秒自退出 124 的兜底。该方案在受限调度以及正常并行事务组中都提前结束正常 fixture，因此已撤销。`deadline-cleanup-red.log`、`final-focused-strict.log`、`final-focused.log` 保留该中间方案的结果，不能作为最终源码结果。

最终方案仅在 `prepareForTermination` 返回非 drained 后发布清理标记；fixture 读到标记或发现夹具目录已移除时退出 124。defer 也发布该标记。成功路径没有新增时间限制，原 SIGINT handler、成功状态 130、完整日志、panic tail 和输出关闭断言全部保持。临时忽略 SIGINT 的反证运行在 7.032 秒内自然结束，保留 6 issues（未排空、124、尾部缺失等），见 `marker-cleanup-red.log`。退出 124 不被算作成功；忽略信号的注入随后删除。

上述中间方案的三个相关 suite 在单合作线程下运行时，事务测试推迟了退出测试主体约 54 秒；退出 fixture 因而走 124 路径，保留 4 issues，见 `final-focused-strict.log`。环境测试和 worker 在同次运行通过。这项受限调度结果不能作为正常调度通过结论。

本轮未修改标准 runner 分组或放宽任何既有超时。最终源码的正常调度定向命令包含 `EnvironmentOperationTests|CommandTerminationTests|FirmwareReceiptPublicationTests`：23 项、3 suites 全部通过，16.666 秒，见 `marker-final-focused.log`。

## 最后一次完整标准验证

`make test_swift` 已自然结束，退出码 2；日志 `standard-complete.log`。XCTest 321 项，跳过 7 项，0 失败。常规 Swift Testing 1514 项、236 suites，148.679 秒，14 issues。本次修改的 worker、环境互斥、普通 panic tail 三项测试全部通过。

剩余失败：

| 范围 | 现象 | issues |
| --- | --- | --- |
| ChildCancellationTests | deferred child 与强制退出的时间顺序断言失败 | 1 |
| OutputXPCTests | helper 等待超时 | 1 |
| APIWebSocketTests | URL session 超时 -1001 | 7 |
| APIHTTPTests | 连接失败 -1004 | 4 |
| CommandTerminationTests 的 escaped writer | 实测 2.628532 秒超过原 2 秒界限 | 1 |

这些剩余失败原因未查明，本次未修改其生产逻辑、时间界限或 runner 分组。上述两处调度根因不自动解释所有剩余失败；标准入口尚未全通过。

标准入口在常规 Swift Testing 失败后停止。随后按原命令分别补跑：限时组 9 项、8 suites，通过，10.488 秒；tar 传输内存检查、文件摘要内存检查和 guest 组件宿主检查均退出 0。命令及退出码见 `followup-results.json`。tar file/producer 路径均超过 1 GiB，峰值 RSS 分别 8,683,520 / 8,994,816 字节；512 MiB 摘要检查峰值 RSS 8,404,992 字节。组件检查不证明 guest 运行效果。

`source-manifest.json` 记录最后标准运行所测三个测试源码及 runner 的摘要。`archive-manifest.json` 保存日志和压缩副本摘要。无临时探针残留，未修改仓库根 TODO.md，未提交代码。

## 恢复执行：剩余 14 issues 的最小实验

本节证据位于 `evidence/resume-swift/`，与上文上一轮失败分开记录。恢复后，尚未修改源码时，18 项相关测试按原期限定向通过，3.526 秒（`focused-baseline.log`）。这证明失败依赖运行条件，不能单凭定向通过认定原全量失败已解决。

实验前报告的待验证假设按顺序为：

1. HTTP 和 WebSocket 夹具在读取状态前检查截止时间，观察任务晚恢复会丢弃已经按时产生的状态。预测：只延迟观察、保持生产者按时完成，会复现原错误码。
2. WebSocket 发送任务本身可能在截止后才运行。预测：记录实际发送时间可区别按时发送和真正迟发送；修复不能接受后者。
3. HTTP 进程可能退出或未完成 bind/listen。预测：缺失实际服务端就绪记录，或子进程已退出；不能以观察任务延迟解释这种情况。
4. ChildCancellation 测试比较的是等待调用方恢复时刻，可能晚于允许的强制退出。预测：仅延迟调用方读取结果会触发旧断言，子进程实际完成顺序保持。
5. XPC 的输出持久化与 ACK 包含异步任务，短墙钟测试可能与大规模并行夹具争用调度。预测：独立原期限通过而原标准并行失败；该条件差异不单独证明生产实现有缺陷。

### WebSocket：生产者时间与观察者时间

`socket-poll-red.log`：消息在 20 ms 截止前发送，观察者在 poll 内等待 40 ms 后恢复。旧 `messages` 抛出原错误 `NSURLErrorDomain -1001`；真正等待 40 ms 后才发送的负对照仍被拒绝。两个测试共 1 issue。

修复在 mock transport 的 `send` 锁内记录 `ContinuousClock.Instant`。`messages` 只统计截止前已发送的消息，允许迟恢复的观察者读取这些消息；截止后实际发送的消息仍不能满足条件。默认 30 秒未改。`socket-poll-green.log` 的 12 项通过；没有改 WebSocket 生产实现。这确认夹具算法缺陷，并不证明上轮 7 次失败全部只有这一原因。

### HTTP：真实服务器 bind/listen 时间

`http-poll-red-child-green.log`：真实 Python loopback server 使用 1 秒启动期限，测试观察 poll 等待 2 秒。未配置启动延迟的正例被旧循环报告为 `NSURLErrorDomain -1004`；真实服务延迟 1.5 秒启动的负例仍被拒绝。RED 阶段尚无生产者时间戳；GREEN 阶段由实际 bind/listen 时间证明正例在期限内就绪，负例在期限后就绪。

服务端在 `ThreadingHTTPServer` 完成 bind/listen 后记录 `CLOCK_MONOTONIC_RAW` 纳秒时间，写入 `ready.json`。旧 `port` 文件保留供其他调用方使用。Swift 使用同一 Darwin 时钟建立期限并校验生产者时间；截止后就绪仍失败。负例还要求错误诊断中的实际就绪时间晚于期限，以排除“服务器根本未启动”产生同类错误的假通过。失败和取消会清理已启动的服务器。标准启动期限仍为 30 秒；实验参数仅供夹具回归使用。

### ChildCancellation：在退出保护内记录子进程完成

`child-observer-red-native.log`：只在 `run.wait()` 返回后增加 1.2 秒观察延迟，旧日期顺序断言失败；退出码、完成文件及未收到 SIGINT 的断言仍满足。该日志同时包含并行任务请求的 NativeTransferTests 15 项通过，整体退出 1 来自本测试刻意制造的 RED。

修复在 `deferring` 闭包内部、真实 `runBash` 返回后记录完成时刻，随后才解除退出保护。保留原退出码 0、finished 文件、无 got-int、退出码 130 和顺序检查。测试参数分别使用 0 和 1.2 秒观察延迟。`http-poll-red-child-green.log` 中两个参数均通过。生产取消实现未改。

`readiness-green.log`：上述阶段实现的 20 项、3 suites 全部通过，3.252 秒。HTTP 负例诊断断言及失败清理随后补充，最终源码验证见下节。

### 标准入口的时限分组

既有 `LATENCY_TESTS` 用两个 SwiftPM 调用分开大规模夹具与短时限测试，两组内部都保留默认并行。依据上一轮标准 14 issues 与本轮原期限定向通过证据，本轮按 17 个精确测试名扩展原 9 项列表。HTTP/WebSocket 读取夹具、XPC 持久化 ACK 以及 escaped pipe 150 ms/2 秒检查进入原时限组；测试中的原有期限没有放宽。没有移动整个 suite，也没有修改生产超时。

这是测试运行合同隔离。XPC 和 escaped pipe 的生产实现根因仍未确认；分组通过不能写成生产故障已修复。`runner-tests.log` 的 6 项测试通过，覆盖两组使用同一筛选集合、保留并行、清除真实固件选择器，以及后续内存和 guest 组件检查顺序。

### 恢复后的标准执行与集成回归

最终就绪时间/清理实现与并行任务的导出修改合并后，`final-focused.log`：54 项、8 suites 全部通过，21.266 秒。

第一轮 `make test_swift`（`standard-final.log`）自然退出 2。XCTest 321 项、跳过 7 项、无失败；常规 Swift Testing 1507 项、235 suites、140.742 秒，仅 `exportAndImportReportProgress` 失败。该失败来自并行 T60 任务新增的 system-tar 尾部进度回调：泵送累计值 1074278400 大于成员逻辑总量 1074267272，新增 `(total,total)` 导致进度回落。T60 任务负责修复；原 `BundleOpsTests.swift:570` 单调性断言保持。

标准入口遇该失败停止，随后原筛选集合 `LATENCY_TESTS` 按 `--skip-build` 单独执行：26 项、10 suites 全部通过，8.294 秒（`latency-green.log`）。上一轮 14 issues 涉及的测试在本轮常规和时限两组均未复现。不能把这一分步结果写成第一轮标准入口通过。

### 最终源码验证结果

T60 删除新增的 system-tar 尾部回调，保留原始 `onBytes` 字节语义，并增加两后端、两压缩形式的单调性回归。`export-progress-green.log`：BundleOpsTests 与 NativeTransferTests 共 41 项、2 suites 通过，26.411 秒。

最终 `make test_swift` 自然退出 **0**，见 `standard-complete.log` 和 `standard-result.json`：

| 范围 | 结果 |
| --- | --- |
| XCTest | 321 项，跳过 7 项，0 失败 |
| 常规 Swift Testing | 1507 项、235 suites，146.340 秒，0 issues |
| 时限 Swift Testing | 26 项、10 suites，10.990 秒，0 issues |
| tar pipe 内存检查 | file/producer 均通过；分别处理 1073743360 / 1073745920 字节，峰值 RSS 8798208 / 9011200 字节 |
| 文件摘要内存检查 | 536870912 字节，峰值 RSS 8388608 字节，摘要检查通过 |
| guest 组件宿主检查 | loader links、VCam data plane、VirtIOSound converter/latency 均通过 |

两个 Swift Testing 调用合计 1533 项。标准日志证明两组及全部后续检查均由同一个入口执行，未以手动补跑替代最后标准结果。`source-manifest.json` 的 14 个相关源码摘要在执行后全部匹配；`archive-manifest.json` 记录 13 份日志及 gzip 副本摘要。

本轮已确认并修复两个夹具轮询缺陷和一个测试完成时间取值缺陷。原 XPC 与 escaped pipe 全量失败在分组后未再出现，但其生产实现原因未查明，不作生产故障修复结论。没有修改 WebSocket/HTTP/取消生产时限；没有进行固件、restore、boot 或真实 VM 验收。所有临时 `DEBUG-T30` 探针已移除，未读写仓库根 TODO.md，未提交。
