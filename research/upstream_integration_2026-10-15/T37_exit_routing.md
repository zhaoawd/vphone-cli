# T37：SIGTERM 与主 VM 窗口关闭（2026-10-15）

本轮处理 U2 中两个宿主退出入口：SIGTERM 和主 VM 窗口关闭。两者进入已有 `handleInterrupt()`，继续等待 guest 写入，再按原策略请求关机或回退。T37 的完整停止矩阵及真实 VM 验收未完成，历史状态不升级为 accepted。

## 1. 基线与问题

基线 `94d6ca0e`，分支 `codex/upstream-2d21d21-integration`。固定上游目标保持 `8a75092013eda87a4e30ed029b72028cb9279ac4`；本轮依据当前源码与新任务台账 T37 的退出入口要求修正本地缺口，没有重新获取上游对象，不声明逐提交或二进制等价。

| 对象 | 已确认现象 | 证据 |
| --- | --- | --- |
| VM 进程信号 | AppDelegate 仅注册 SIGINT，SIGTERM 未进入现有关机回调 | 原源码；将原 SIGINT 注册逻辑提取后，原生子进程 4 组信号组合中，3 组包含 SIGTERM 的组合失败 |
| 主窗口关闭 | `windowWillClose` 只清理剪贴板；退出依赖 AppDelegate 的“最后一个窗口关闭”。存在辅助窗口时，这一条件不成立 | 原 WindowController 与 AppDelegate；实际窗口 delegate 的 3 项回归失败，停止请求数为 0 |
| guest 写入 | 现有 `sealAndWait()` 先封闭后续写入，等待活动写入及待恢复状态；反复停止请求不会跳过该等待 | `VPhoneGuestWriteCoordinator`、`handleInterrupt()` 及已有写入协调测试 |

最初抽取信号类时，非 actor 回调捕获 AppDelegate 触发 Swift 6 隔离编译错误。随后将回调明确为 `@MainActor @Sendable`，并在主队列事件处理器中使用 `MainActor.assumeIsolated`。编译失败日志保留，不将它当作行为复现。AppDelegate 明确标注 `@MainActor`。

现有 `vm launch` 父进程已经将 SIGINT/SIGTERM/SIGHUP/SIGQUIT 转为 VM 子进程的 SIGINT，并等待子进程退出。本轮补充的是直接到达 VM 运行进程的 SIGTERM，不改变该父进程的转发方式。

## 2. 修改

`VPhoneShutdownSignals` 保存本进程 SIGINT/SIGTERM 的原处理器和 DispatchSource。两种信号的回调均在主队列执行；实例释放时取消来源并恢复原处理器。AppDelegate 持有该实例，收到任一信号时调用原 `handleInterrupt()`，资源清理结束后、退出前才释放实例。重复停止的日志改为 `repeated shutdown request`，适用于信号、菜单或窗口产生的重复请求。

AppDelegate 通过 `makeWindowController()` 建立主窗口的停止回调；该回调弱引用 AppDelegate。主窗口 `windowShouldClose` 调用停止回调并返回 false，保留窗口和资源，直到应用完成原有关机流程。该行为不再依赖辅助窗口数量。未配置停止回调的独立 WindowController 继续允许关闭。辅助文件、应用与 Keychain 窗口不接入这一主窗口回调。

未修改 guest 关机请求、10 秒超时、重复请求的 force-stop 策略、CLI PID 身份判定、磁盘持有者规则、guest 写入协调器或恢复规则。没有新增 firmware/kernel/DSC/Mach-O 补丁或权限。

## 3. 回归范围

`tests/test_shutdown_signals.py` 编译生产信号类和独立 Swift 6 夹具，只向该测试子进程发送信号。四组顺序为 TERM→TERM、INT→TERM、TERM→INT、INT→INT。每次等待实际回调确认后再发送下一次信号，避免用信号合并推断回调次数。夹具确认回调位于主线程；第一次回调后进程仍存活；第二次回调释放注册后，原处理器使进程以约定状态 74 退出。SIGTERM 未注册的基线明确缺少回调。

最终原生夹具也对保存的 SIGINT-only 基线执行了对照：仍有 3 组缺少 SIGTERM 回调，INT→INT 保持通过。对照外层脚本以 0 退出仅表示预期失败被确认，不能表述为基线信号行为通过。

`VMWindowCloseTests` 使用实际 `NSWindowDelegate`，不显示窗口、不发送合成键鼠事件、不创建 VZVirtualMachine。测试覆盖 AppDelegate 的实际主窗口接线、辅助窗口存在及重复关闭、没有关闭回调时的默认行为，以及活动写入期间关闭延后、排队和后续写入拒绝。初步失败测试使用独立写入回调；最终测试进一步执行 AppDelegate 的真实 `handleInterrupt()` 和真实协调器，只在等待结束后、即将进入框架操作的位置替换后续动作，确认重复关闭不能跳过活动写入。测试结束时关闭本次创建的窗口。关机后的实际窗口关闭和 Virtualization.framework 状态仍须真实 VM 验证。

命令、源码摘要和失败/成功日志见 [证据清单](evidence/T37-exit-routing/manifest.json)。标准 Swift 的既有内核幂等失败保留原结论，不通过改变该断言完成本任务。

| 验证 | 结果 |
| --- | --- |
| 原生信号 | 1 项 Python 回归包含 4 组顺序，全部通过；首轮 3 组含 SIGTERM 的组合失败记录保留 |
| 初次相关 Swift | 窗口/写入协调 XCTest 9 项、关机/停止/CLI Swift Testing 35 项，共 44 项通过 |
| 最终窗口回归 | 3 项 XCTest 在最终标准构建中通过，包括实际 AppDelegate 等待活动写入及重复关闭 |
| 标准 Python | `VPHONE_DAEMON_SOURCE_PACKAGES="$PWD/.build/daemon-api-t59-20261015/Xcode/SourcePackages" make test_python`：786 项通过，无跳过，198.527 秒 |
| 标准 Swift | 初次及最终执行均只保留同一项已记录内核幂等 issue。最终常规 Swift Testing 1510 项、1 issue；`run_tests.py` 退出 1，外层 make 退出 2 |
| 真实 VM、完整签名 App | 未执行 |

最终窗口测试改为调用实际 AppDelegate 后重跑了标准 Swift；信号处理器的释放也移至资源清理之后。上述最终失败位于 `KernelStructuredMergeTests.swift:197`，实际 emittedRecords 为 2，断言为 1；本轮未修改该补丁、测试或断言。限时测试组独立补跑，结果写入证据清单；标准入口后续 tar/文件摘要内存与 guest 组件检查此次没有重跑，这些路径未修改。

最终构建的限时组独立执行 9 项，通过；包含 CLI 四种停止信号的参数化转发用例。没有将补跑结果提升为标准 Swift 全通过。

## 4. 未验收范围

本轮不操作真实 VM、系统 Store、AMFI 或 TCC，不构建或部署完整签名 App。当前宿主模块由 SwiftPM 测试构建；这不证明实际 VM 关机、磁盘释放、启动中的停止或已停止 VM 的全部退出竞态。完整签名产物和上述 VM 矩阵仍按原 T24/T37/T40 计划处理。
