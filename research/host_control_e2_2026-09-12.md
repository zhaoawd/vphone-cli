# E2：宿主控制的传输、命令与画面能力分离

日期：2026-09-12。实现基线：`daec4f3`。本项不修改固件补丁，也不启动或复制 C4 镜像。

## 问题与修改

原 `VPhoneHostControl` 同时负责监听 socket、JSON 命令、客户机操作、AppKit 输入和截图，并在各命令内创建主线程任务，通过信号量同步返回。构造控制入口需要具体 VM 视图；E1 的读写期限不覆盖命令等待，未返回的截图回调会持续占用连接。

| 模块 | 负责内容 | 原因 |
| --- | --- | --- |
| `VPhoneHostControl` | Unix socket 路径、权限、接收上限、单次请求/响应和连接关闭 | 传输只传递 `Data`，不再解析或执行具体命令 |
| `VPhoneHostCommandService` | 最多 16 个执行名额、180 秒命令期限、取消、单次结果交付 | 将连接生命周期与可能迟到的底层操作分开管理 |
| `VPhoneHostCommandExecutor` | JSON 参数校验、命令调用、返回字段和截图策略 | `execute(Data) async -> Data` 不要求视图或 socket；命令在 MainActor 内执行，不跨线程共享命令结果盒 |
| `VPhoneHostCapabilities` | 客户机、画面、相机和定位操作接口及现有实现适配 | 真实实现与测试替身使用同一接口；定位继续使用现有系统定位控制器 |
| `VPhoneHostScreenAdapter` | AppKit 视图输入、截图编码和截图文件保存 | 具体视图与 `VPhoneScreenRecorder` 只由可选画面适配器持有 |

AppDelegate 在原有 GUI 分支创建画面适配器和命令执行对象，然后启动 socket。E3 将负责把实际 VM 的 socket 生命周期移出该分支。本项的无视图 socket 测试证明模块可以这样组合，不表示真实 `--headless` 已接通。

现有 UDS 没有录屏命令。本项保留菜单录屏行为，截图继续通过画面适配器使用现有 recorder；没有新增未经验证的 UDS 录屏功能。

## 兼容行为

- 保留现有命令字段、成功/错误响应和默认选项；原有定位校验函数随命令执行模块迁移。
- GUI 的 tap、swipe、key、type、app_launch、app_terminate、open_url 默认附带紧凑截图；`screen:false` 关闭附图。
- shell 默认不附图，`screen:true` 显式请求；file_*、app_list、app_foreground、ipa_install 和定位/相机命令保留原附图行为。
- screenshot 即使带 `screen:false` 也尝试截图；`color:true` 继续选择彩色编码。画面不可用时返回原有 `no active VM view` 错误。无画面时其他命令仍可执行，附图请求不会使已成功的客户机操作失败。
- `file_put` 保留 `data_b64` 优先于 `load`、默认权限 `644` 和 E1 容量限制。宿主文件读写使用独立任务，避免占用 MainActor。
- 相机继续使用原有“同 generation 且两个帧索引均大于零”的回执判据；不将本项解释为 E6 的指定帧或应用显示验收。

新增输入约束：`delay` 与 swipe 的 `ms` 限制在 0–60000 毫秒。负数过去会在转换为 `UInt64` 时触发异常；新实现返回 `invalid_argument`。该范围限制是明确的协议变更。默认 delay=500、swipe ms=300 保持不变。

## 能力发现

请求：`{"t":"capabilities"}`，不需要客户机连接或画面。响应保留 `ok:true`，新增字段如下。

| 字段 | 含义 |
| --- | --- |
| `protocol_version:1` | 本次宿主能力发现响应版本，与 camera_present 中的回执版本分别解释 |
| `guest_connected` | 查询时客户机控制通道的连接状态 |
| `guest_capabilities` | 已连接客户机的能力声明；断线时为空数组 |
| `screen_available` | 可选画面实现当前是否可用 |
| `commands` | 命令名称到布尔值的映射，根据宿主实现、画面、客户机声明和相机连接状态计算 |
| `limits` | 请求字节、内联文件字节、宿主文件字节、连接上限和 `command_timeout_ms` |

状态查询命令可以在客户机断线时仍可用，例如存在定位实现时的 location_source_status。命令可用只表示查询时具备其入口所需能力；参数、generation、文件、连接后续变化仍可能使调用失败。旧命令继续使用原校验和客户机错误，不强制把所有错误改写为新格式。

## 期限、取消和迟到结果

E1 的请求读取、响应写入各 5 秒仍然有效。新命令期限从 service 接收已完成的请求开始计算，默认 180 秒。期限由同一常量提供给实际 service 与能力响应。

| 情况 | 响应 code | `operation_may_continue` | 名额处理 |
| --- | --- | --- | --- |
| 达到命令期限 | `command_timeout` | true | 请求任务取消；保留执行名额，直到底层任务真正结束 |
| 调用方取消或宿主控制停止 | `command_cancelled` | 已提交时 true | 立即结束待交付响应；对操作任务调用 cancel |
| service 已停止或提交前已取消 | `command_cancelled` | false | 不创建操作 |
| 16 个操作仍在执行 | `command_busy` | false | 不创建操作，也不排队等待名额 |

每次调用的 continuation 只保存和恢复一次。正常完成、超时、取消之间先交付的结果生效；迟到结果只释放执行名额，不再次发送响应。测试覆盖不响应 Task 取消的悬挂操作，确认超时后新请求收到 busy，操作实际返回后可以接受新请求。

取消表示宿主停止等待并请求协作取消，不证明客户机 shell、文件写入或私有截图操作已经停止。已经开始的宿主文件 I/O 也可能继续完成。取消后的新增截图和 camera receipt 轮询会停止，file_put 在宿主文件读取结束后会再次检查取消状态。

socket 对端断开本身尚未转换为命令取消；该请求受命令期限限制。停止后的 service 不再接受新请求，应使用新实例重新构造控制入口。MainActor 的同步阻塞可能延迟计时任务调度，期限不构成对任意同步阻塞代码的强制中断。E4 仍需验证真实客户机传输的取消和断线行为。

## 验证

新增 15 个测试通过：命令替身 10 项、命令生命周期 4 项、无视图真实 Unix socket 1 项。既有协议和定位解析测试同时通过。负数 delay/ms 在输入操作发生前被拒绝。

本轮替身测试覆盖 shell、文件、应用、定位、相机和截图的成功、错误及不可用情况；GUI 默认附图策略由画面替身验证。完整 `make test` 通过：81 个 Python 测试；107 个 XCTest（3 个跳过）；331 个 Swift Testing 测试、53 个 suite。首轮完整回归发现并修复了既有资源测试的进程环境竞争，独立提交 `f6cd301`，见[环境隔离记录](test_environment_isolation_2026-09-12.md)。

本项不声称已完成真实 GUI 截图、headless VM、相机应用显示或双 VM 验收。当前宿主此前记录的私有 entitlements 运行限制未在本项修改。

`make build` 通过，完成 release 编译、entitlements 签名及 app bundle。构建通过不替代真实 VM 验收。日志及 SHA-256 清单保存在 `research/artifacts/e2-control-2026-09-12/`。
