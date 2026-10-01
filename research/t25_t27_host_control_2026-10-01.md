# T25（VM 侧）与 T27：宿主控制并发、headless、方法转发与 Inspector 整理

日期：2026-10-01。基线 `6c7cb3f`。上游参考为本地 tag `upstream-2.2.3`（基线 `upstream-2.0.8`），只用 `git show`/`git archive` 读取，未 checkout、merge 或 cherry-pick。未操作 VM。

范围：`vphone.sock` 的 VM 侧行为（并发、headless、vphoned 方法转发、多 VM 目标身份）与 UI Inspector 悬空引用。不在范围：`be7f061`（Launchpad 控制服务器与 `vphone-launchpad-cli`，归 T26）。

## 来源

| 提交 | 上游路径 | 内容 |
| --- | --- | --- |
| `0cafa79` | `VPhoneExecutable/VPhoneVirtualization/UI/VPhoneHostAutomationServer.swift`、`.../VPhoneVirtualMachineAppDelegate.swift`、`Documents/Guides/create-and-run.md` | 每连接在并发队列读写，命令在 MainActor 上 await；socket 在 headless 启动也创建；headless 下 tap/swipe 走 vphoned `input.touch`，紧凑图来自 `screen.screenshot`；窗口 swipe 在手势结束后回复 |
| `6fb0636` | `VPhoneHostAutomationServer.swift`、`.../GuestCommunication/VPhoneGuestControl.swift` | `{"t":"rpc","method":...,"params":{...}}` 转发任意 vphoned 方法；`key` 的非硬件键名转发到 `input.key`；两者先等待已排队输入；请求行上限 1 MiB |
| `627497b` | `VPhoneGuestControl.swift`、`VPhoneGuestControlSystem.swift`、`Menu/VPhoneMenuDiagnostics.swift`、`Panels/VPhoneGuestPanelsWindowController.swift` | 删除 UI Inspector 面板、Diagnostics 菜单项（⌥⌘U）和未使用的 `accessibilityTree` 调用；vphoned 保留 `ui.*` 与 `ui_inspection` |
| `addc8c4` | `Resources/Localizable.xcstrings` | 删除 Inspector 专用的 53 个字符串键 |

`git log upstream-2.0.8..upstream-2.2.3 -- '*HostAutomation*' '*GuestControl*'` 共 12 个提交。除上表外的 8 个不属于本任务：`1df6c43`（连接关闭，T06 已记录）、`5922ef1`/`bc6d007`/`a16ea3b`/`8682c98`/`6e1b0cf`（触控板、方向、剪贴板、拖放，T23 范围）、`2aaafaf`（UDID，T19 范围）、`4da0847`（跳过 Setup Assistant）与 `b40c8e5`（钥匙串编辑）在清单中的归属待确认。

## 对照表

“已等价”指行为结果相同，机制可以不同。行号为本次提交后的位置。

| 上游行为 | 本地结论 | 本地位置 |
| --- | --- | --- |
| `0cafa79` 多客户端并发服务，一个慢请求不阻塞其他客户端 | 已等价。E1/E2 起每个连接派发到全局队列。本次改为命令 await 期间不占用工作线程（原实现用信号量阻塞线程） | `VPhoneHostControl.swift:161-205` |
| `0cafa79` accept 遇 `EINTR`/`ECONNABORTED` 不结束监听 | 已等价，机制不同：非阻塞 `DispatchSourceRead`，`EINTR` 重试，其他错误等待下次可读事件 | `VPhoneHostControl.swift:161-167` |
| `0cafa79` 连接数不设上限、15 秒 socket 超时 | 本地有意不同：最多 16 个连接，超限立即关闭；读/写各 5 秒期限；命令 180 秒期限（E1/E2） | `HostControlIO.swift:6-9`、`VPhoneHostCommandService.swift:8,25-27` |
| `0cafa79` headless 启动创建 socket | 已等价（E3 起 GUI/headless/DFU 共用启动路径） | `VPhoneAppDelegate.swift:292-303` |
| `0cafa79` headless 下 tap/swipe 经 vphoned `input.touch`，紧凑图与 `screenshot` 来自客户机截图 | 缺失，未迁入，归 T23。本地 headless 的 tap/swipe/screenshot 返回 `no active VM view`。迁入需同时处理归一化坐标、方向和整次手势固定路由。替代路径：配置 `--api-listen` 后用 `rpc` 的 `screen.screenshot`、`input.tap`、`input.swipe`（坐标为屏幕点，见下文） | `VPhoneHostCommandExecutor.swift:92-99,120-128,152-166` |
| `0cafa79` 窗口 swipe 在手势最后一个事件后回复 | 已等价（`injectSwipeAndWait`） | `VPhoneVirtualMachineView.swift:337`、`VPhoneHostCommandExecutor.swift:169` |
| `0cafa79` 同一客户端的输入保持顺序 | 已迁入，范围更严格：所有客户端的 socket 输入（tap、swipe、硬件键、转发的输入方法）经同一输入队列逐个执行 | `VPhoneHostInputQueue.swift`、`VPhoneHostCommandExecutor.swift:131,169,222,1048` |
| `6fb0636` `rpc` 转发任意 vphoned 方法 | 已迁入，本地有意不同：只转发方法表内的方法；每个方法要求 API 会话就绪且客户机声明对应能力；表外方法返回 `unsupported_method`；5 个方法拒绝转发；只走 API 传输（1339） | `VPhoneHostRPC.swift:22-116`、`VPhoneHostCommandExecutor.swift:72,1027-1071` |
| `6fb0636` `key` 的非硬件键名转发到 `input.key` | 已迁入。存在 API 会话时转发，要求 `input_gestures`；无 API 会话或显式 `transport:"classic"` 时保持原错误 `unknown key: <name>` | `VPhoneHostCommandExecutor.swift:194-239` |
| `6fb0636` `rpc`/`key` 先等待已排队输入 | 已迁入（输入队列） | 同上 |
| `6fb0636` `rpc` 默认不附图，`screen:true` 时附图 | 已迁入 | `VPhoneHostCommandExecutor.swift:1064-1069` |
| `6fb0636` 请求行上限 1 MiB | 已等价。本地上限 2 MiB（E1），不小于上游 | `HostControlIO.swift:6` |
| 上游 socket 无对端 UID 检查、启动时无条件 `unlink` | 本地有意不同：保留 `getpeereid` 同用户检查、目录属主检查、0600 权限、活动 socket 不替换 | `VPhoneHostControl.swift:61-107,127,171` |
| `627497b` 删除 Inspector 面板与菜单 ⌥⌘U | 不适用：本地 `sources/` 无该面板、菜单项和快捷键 | 见 T27 |
| `627497b` 删除未使用的 `accessibilityTree` 调用 | 已迁入：本地 `VPhoneControl.accessibilityTree` 无调用者，已删除 | 见 T27 |
| `addc8c4` 删除字符串目录中的 Inspector 键 | 不适用：本地无 `.xcstrings`/`.strings` | 见 T27 |

## T25 改动

| 文件 | 内容 |
| --- | --- |
| `sources/vphone-cli/VPhoneHostControl.swift` | `handleClient` 读完请求后释放工作线程；命令在 MainActor 上 await；响应在另一个工作线程写出并关闭描述符；新增可选 `completion` |
| `sources/vphone-cli/VPhoneHostRPC.swift`（新） | 方法表（123 个方法 → 能力）、拒绝表（5 个）、请求校验、调用与错误映射 |
| `sources/vphone-cli/VPhoneHostInputQueue.swift`（新） | 跨客户端的输入串行队列；未开始的请求被取消时不执行 |
| `sources/vphone-cli/VPhoneHostTarget.swift`（新） | VM 目标身份（`vm`、`instance_id`、`pid`、`process_started_at`）及请求 `target` 校验 |
| `sources/vphone-cli/VPhoneHostCommandExecutor.swift` | `target` 校验先于 DFU 检查和任何命令；`rpc` 分派；tap/swipe/硬件键进入输入队列；非硬件键转发；`capabilities` 增加 `commands.rpc`、`rpc_methods`、`target` |
| `sources/vphone-cli/VPhoneHostAPICommands.swift` | API 错误码映射提取为 `hostCode(forAPIError:)`，供 `rpc` 复用；映射内容不变 |
| `sources/vphone-cli/VPhoneAppDelegate.swift` | 用 VM 锁的运行记录构造 `VPhoneHostTarget` 传给执行器 |

### rpc 合约

请求：`{"t":"rpc","method":"<vphoned 方法>","params":{...},"screen":false,"delay":500}`。`transport` 可省略或为 `"api"`；`"classic"` 返回 `unsupported_transport`。`method` 为 1–128 字节字符串；`params` 省略或为 JSON 对象。参数原样传给 1339 API；手势坐标为屏幕点（`GuestAPI+Input.swift` 注释），与 socket `tap`/`swipe` 的像素坐标不同。

成功：`{"ok":true,"method":...,"result":<方法结果>}`。失败 `code`：

| code | 条件 | 是否已发送到客户机 |
| --- | --- | --- |
| `invalid_argument` | method/params/transport 类型错误 | 否 |
| `unsupported_method` | 方法不在方法表 | 否 |
| `method_not_forwardable` | 方法在拒绝表，或 `input.hid` 带 `down`；返回原因 | 否 |
| `api_not_ready` | 无 API 会话或会话非 ready | 否 |
| `capability_unavailable` | 客户机未声明所需能力（返回 `capability`）；DFU | 否 |
| `command_cancelled` | 输入队列中未开始即被取消 | 否 |
| `api_stale_session`、`api_timeout`、`api_disconnected`、`api_busy`、`api_protocol`、`api_transport` 等 | 会话代际变化或传输错误（映射同 `transport:"api"` 命令） | 是，`operation_may_continue:true` |
| `api_guest_error` | 客户机返回错误；只返回 `guest_code`（`[a-z0-9_]{1,64}`），不返回客户机错误文本 | 是，`operation_may_continue:true` |

方法表依据：`sources/VPhoneDaemon/Daemon/GuestAPI*.swift` 中各方法所在区域文件，对应 `health()` 声明的区域能力名。`agent.health`、`settings.*`、`developer_mode.*`、`power.low_power_mode` 在 daemon 中没有专用能力，只要求 API 会话就绪（会话握手已要求 `session_identity` 与实例身份）。`HostRPCTests.testMethodTableMatchesLocalDaemonSourcesAndDeclaredCapabilities` 从源码提取 128 个方法，断言方法表与拒绝表的并集等于该集合，且表内能力均在 daemon 声明列表中。

拒绝转发的方法与原因：

| 方法 | 原因 | 保留的宿主路径 |
| --- | --- | --- |
| `input.touch` | 单个触控阶段会把一次手势拆到多个请求，无法固定整次手势的路由和会话代际 | `tap`、`swipe`、`input.touch_sequence` |
| `input.hid` 带 `down` | 半次按键跨请求 | 不带 `down` 的 `input.hid`、`key` |
| `location.set`、`location.clear` | 绕过定位 owner/generation 合约 | `location_source_*`、`location_stream_*` |
| `agent.apply_update`、`environment.install` | 客户机组件替换有独立的更新事务（T17） | 现有更新流程 |

### 多 VM 目标身份

每个 VM 进程的 socket 位于自身 bundle 目录。`capabilities` 返回 `target`：`vm`（bundle 目录名）、`instance_id`（VM 锁本次启动写入的 UUID）、`pid`、`process_started_at`（内核 `p_starttime`）。任意请求可带 `target` 对象，所带字段全部匹配才执行；不匹配返回 `target_mismatch`、`operation_may_continue:false` 和本 socket 的实际 `target`，不执行命令；格式错误返回 `invalid_argument`。socket 没有身份记录时，带 `target` 的请求一律 `target_mismatch`。不带 `target` 的请求行为不变。

目标退出后 socket 路径被删除，连接失败（`ENOENT`）；进程异常退出留下的 socket 文件无监听者，连接返回 `ECONNREFUSED`；两种情况都不会转到其他 VM。重启后同一路径由新进程监听，新 `instance_id` 与旧值不同，持有旧身份的请求被拒绝。

现有客户端（`scripts/host_control_client.py`、F1/F2/F3 脚本）未发送 `target`；是否接入属于后续工作，本次未改。

## 必须保留项核对

| 约束 | 结果 | 位置/证据 |
| --- | --- | --- |
| Unix socket 同用户限制 | 未改：`getpeereid` 后比较 `geteuid()`；目录属主与权限、socket 0600 | `VPhoneHostControl.swift:61-67,127,171` |
| VM 锁与 PID+启动时间身份 | 未改 VM 锁；新增 `target` 使用锁的 `instanceID`/`pid` 与内核启动时间 | `VPhoneVMLock.swift:50-68`、`VPhoneHostTarget.swift` |
| 整次手势固定路由 | 未改 `VPhoneTouchRoute`；`input.touch` 不转发 | `VPhoneTouchRoute.swift:26-33`、`VPhoneHostRPC.swift:74-80` |
| 输入串行化 | 视图手势队列未改；新增跨客户端输入队列 | `VPhoneVirtualMachineView.swift:412`、`VPhoneHostInputQueue.swift` |
| 请求期限/取消/迟到响应 | `rpc` 与其他命令同经 `VPhoneHostCommandService`（180 秒、取消、单次交付、迟到结果只释放名额） | `HostRPCTests.testServiceDeadlineAndCancellationApplyToForwardedCalls` |
| session generation | `VPhoneAPISession.call` 前后比较代际；`rpc` 返回前再比较一次，变化时 `api_stale_session` | `VPhoneAPISession.swift:72-81`、`VPhoneHostRPC.swift:138-146` |

## T27：Inspector 与入口整理

检查命令（改动前）：

```
grep -rniE "inspector|ui_inspection|accessibility|accessibility_tree|\bocr\b|ui\.tree|uiInspector|axserver" sources scripts/vphoned docs README.md
find sources tests -name "*.xcstrings" -o -name "*.strings" -o -name "Localizable*"
grep -rn "keyEquivalent: \"u\"" sources/vphone-cli
```

结果：

- 菜单、快捷键：`sources/vphone-cli` 无 Inspector 菜单项或 ⌥⌘U；不适用。
- 字符串：无字符串目录；不适用。
- 宿主悬空引用：`VPhoneControl.accessibilityTree(depth:)`（`VPhoneControl.swift` 原 848-856 行）无调用者；经典 vphoned 的 hello 能力列表不声明 `accessibility_tree`，该方法调用必然抛出 `unsupportedCapability`。请求超时表中的 `"accessibility_tree"` 只服务该方法。两处已删除，独立提交 `21c1092`。
- capability 列表与 headless 方法表：宿主 `capabilities.commands` 无 Inspector 或 UI 树条目。`rpc` 方法表包含 `ui.*` 与 `accessibility.tree`（能力 `ui_inspection`），与上游保留 vphoned `ui.*` 的处理一致。
- 保留：经典客户机守护进程 `scripts/vphoned/vphoned_accessibility.{h,m}` 与 `vphoned.m` 中的 `accessibility_tree` 存根处理。删除需要重建并部署客户机二进制，属于客户机组件更新范围；本次不改。API daemon 的 `ui.*` 方法与 `ui_inspection` 能力保留。

改动后同一 `grep`（排除 `VPhoneHostRPC.swift` 方法表与 `sources/VPhoneDaemon`、`scripts/vphoned`）无输出。

## 验证

环境：worktree 的 `.venv` 为指向主仓库 `.venv` 的符号链接；`vendor/*` 子模块递归初始化；按 Makefile 格式生成 `sources/vphone-cli/VPhoneBuildInfo.swift`（均被 Git 忽略）。日志位于 `research/artifacts/t25-t27-2026-10-01/`（Git 忽略）。

| 命令 | 结果 |
| --- | --- |
| `swift build --build-tests` | 成功，无 error |
| `swift test --skip-build --filter Host`（第一次） | 挂起，手动终止。原因：新测试的客户端阻塞 I/O 放在 `Task.detached`，16 个并发客户端占满协作线程池，部分请求晚于服务端 5 秒读期限写出，等待条件不可达。修改测试辅助：客户端 I/O 改在 GCD 线程，轮询改为 10 秒有界等待 |
| 同上（第二次） | 1 项失败：`try?` 包裹的 `XCTUnwrap` 仍记录失败；测试辅助改为抛出普通错误 |
| 同上（第三次） | 退出 0。XCTest：VPhoneCLITests 74 项（含 `HostRPCTests` 13、`HostControlLifecycleTests` 12）、VPhoneCoreTests 9 项、VPhoneAPIKitTests 1 项，均通过；Swift Testing 4 次运行共 16 项通过 |
| 变异检查 1：accept 改为串行处理 | `testSlowCommandAndSlowPeerDoNotBlockOtherClients` 失败（`readTimeout`，5.378 秒）；已恢复源码 |
| 变异检查 2：`rpc` 输入方法不进输入队列 | `testForwardedInputWaitsForAnEarlierSocketGestureToFinish`、`testCancelledQueuedInputDoesNotRun` 失败；已恢复源码 |
| `make test_swift`（第一次） | 退出 0；Swift Testing 10 次运行共 801 项通过；XCTest 共 200 项执行、3 项跳过、0 失败；tar pipe 两条 1 GiB 路径峰值 RSS 7,831,552 / 9,093,120 字节；`test_guest_components` 124 项检查 0 失败 |
| 之后修改：显式 `transport:"classic"` 的非硬件键不转发（新增 1 条断言）；`swift test --skip-build --filter Host`（第四次） | 退出 0；XCTest VPhoneCLITests 74、VPhoneCoreTests 9、VPhoneAPIKitTests 1 项通过；Swift Testing 16 项通过 |
| `make test_swift`（最终） | 退出 0；Swift Testing 10 次运行共 801 项通过；XCTest 共 200 项执行、3 项跳过、0 失败；tar pipe 峰值 RSS 7,831,552 / 10,125,312 字节；`test_guest_components` 124 项检查 0 失败。日志 `make_test_swift_final.log` |
| `make test_python` | 未执行。本次无 Python 改动 |

新增测试：

| 测试 | 覆盖 |
| --- | --- |
| `HostRPCTests`（13 项） | 方法表与 daemon 源码一致；参数与结果透传；`screen` 默认关闭；未知/拒绝/非法请求不调用客户机；就绪、能力、DFU 门控；代际变化、客户机错误、传输错误的 `operation_may_continue`；服务期限；非硬件键转发；输入排在未完成手势之后；取消的排队输入不执行；`capabilities` 的 `rpc_methods`/`target`；`target` 匹配、不匹配、格式错误 |
| `HostControlLifecycleTests` 新增 5 项（真实 Unix socket） | 慢命令与未发完请求的连接不阻塞另外 8 个客户端；第 17 个连接被关闭且不影响已接受的 16 个；两个 VM socket 的错误 VM 名与错误启动实例被拒绝，写操作只落到所属 VM；目标退出后连接失败、遗留 socket 文件连接失败、进行中命令收到取消或连接关闭；重启后旧 `instance_id`/旧 PID 被拒绝 |
| `HostAPICommandTests.testUnixSocketToManagedWebSocketWithoutClassicGuest` 增加 2 个断言 | 经真实 WebSocket fixture 的 `rpc apps.search` 成功；未声明能力的 `clipboard.get` 返回 `capability_unavailable` |

## 事实、推断与未验证

事实：

- 本地 socket 在 GUI、headless、DFU 下均启动；多客户端并发由真实 socket 测试覆盖，串行 accept 的变异使测试失败。
- `rpc` 只调用方法表内且能力已声明的方法；表外和拒绝表方法不发送到客户机。
- 带 `target` 的请求在身份不符时不执行任何命令。

推断（待验证假设）：

- 输入队列只保证宿主侧发出顺序。socket `tap`/`swipe` 经经典 1337 通道，`rpc` 输入经 1339 API；两条传输到达客户机的先后顺序未验证。
- `rpc` 输入方法与用户在窗口中的实时鼠标手势不经同一队列，二者可能交错。

未验证（需真实 VM）：

- 真实 VM 下的多客户端并发、headless 启动下的 `rpc` 与 `key` 转发、`rpc` 方法在客户机上的实际效果（含 `screen.screenshot`、`input.*`、`ui.*`）。
- 双 VM 同时运行时的 `target` 拒绝与重启后旧身份拒绝；本次只用测试替身和真实 Unix socket 覆盖。
- `rpc` 依赖 `--api-listen` 创建的 API 会话；未配置时所有 `rpc` 返回 `api_not_ready`。

未覆盖范围：headless tap/swipe/screenshot 经客户机实现（T23）；Launchpad 控制服务器与 CLI（`be7f061`，T26）；现有脚本客户端发送 `target`。
