# T32/T33 应用消费验收准备（2026-10-24）

当前仅完成接口与验收条件核对，未生成新的运行计划，未启动 VM 或辅助窗口。已批准的 b98e0a56… 离线计划继续执行。以下条件尚无真实运行结果，不能将 T32/T33 标为完成。

## 已查证的接口与限制

本地 ICLI checkout 的 HEAD 为 `651ce0d0aed59d2601c35595f1a2ba7e29bb4169`，与候选 API manifest 的 `icli` pin 一致。所查六份 ICLI 源文件已与该 HEAD 逐字节比较通过。候选 manifest 仍记录 `activated=false`、`runtime_validated=false`。源码事实不替代当前候选的运行能力核验。

| 对象 | 源码结果 | 验证限制 |
| --- | --- | --- |
| `apps.open_url` | 接受 URL 和可选 `bundle_id`，返回请求的 URL/应用标识 | 返回成功不能单独证明页面已打开 |
| `apps.foreground` | 返回 `bundle_id`、PID、`verified` 和来源 | 需要 `verified=true`，PID 必须有效 |
| `ui.tree` | 对核实的前台应用 PID 查询 AX，结果含 `source=ax`、PID、元素及截断标记 | AX 查询失败可能返回错误；缺数据不能补成成功 |
| `ui.describe` | 同一次观察包含前台标识、截图、AX 和可选 OCR，并在结束时复核前台标识 | `context_changed` 只比较应用标识和核实状态，另需核对前后 PID 与 AX PID |
| AX 元素 | 显式返回 `label`、`value`、可见性、frame 和角色 | 构建号应取自可见文字或值，不能从 identifier、请求参数或文件读取结果推断显示成功 |
| `device.snapshot` | 返回系统/内核、启动、存储及锁屏等信息 | 所查实现没有 `ProductBuildVersion`，不能用它替代设置页面读回 |
| `files.read(binary=true)` | 返回 `encoding`、`content`、完整文件 `size` 和 `truncated` | 若用于 AA.gl 对照，必须拒绝截断并校验完整长度；日志只能保存摘要，不能直接记录嵌套 `content` 原始数据 |

接口来源：

- [GuestAPI.swift](/Users/kolar/github/vphone-cli/sources/VPhoneDaemon/Daemon/GuestAPI.swift)
- [GuestAPI+Input.swift](/Users/kolar/github/vphone-cli/sources/VPhoneDaemon/Daemon/GuestAPI+Input.swift)
- [GuestAPI+Device.swift](/Users/kolar/github/vphone-cli/sources/VPhoneDaemon/Daemon/GuestAPI+Device.swift)
- [ICLI Screen.swift](/Users/kolar/github/vphone-cli/.build/daemon-api-icli086-20261021/Xcode/SourcePackages/checkouts/icli/Sources/IcliKit/Input/Screen.swift)
- [ICLI Accessibility.m](/Users/kolar/github/vphone-cli/.build/daemon-api-icli086-20261021/Xcode/SourcePackages/checkouts/icli/Sources/IcliPrivate/Accessibility.m)

宿主 [VPhoneHostRPC.swift](/Users/kolar/github/vphone-cli/sources/vphone-cli/VPhoneHostRPC.swift) 已登记这些方法，但实际转发还要求来宾声明相应能力：`apps.foreground` 对应 `apps`，`apps.open_url` 对应 `url`，页面/AX 对应 `ui_inspection`，`files.list` 对应 `files`，`files.read` 对应 `file_tools`，`processes.list` 对应 `processes`。当前来宾源码的 health 列表包含这些名称；实际运行时仍需核对所连接会话的声明，不能由源码列表推定连接成功。

## 后续验收条件

regular 继续保留 AA.gl 读取、解锁、应用前台和显示帧的独立结果。读取仍返回 EPERM 时保存失败；解锁前后的读取条件尚未实际比较，原因未查明。可通过已有进程和文件接口记录身份、权限及锁屏快照，不能据静态 entitlements 差异修改权限或补造原因。

EXP 离线计划已指定两处 `SystemVersion.plist` 的测试构建号 `23Z999999`。后续应用消费观察应打开系统设置的关于本机页面，核对以下结果：

1. 前后均为核实的 `com.apple.Preferences`，有效 PID 保持；AX PID 与之相同，`context_changed=false`。
2. 可见 AX 文字/值包含完整的预期构建号，保留实际条目及页面上下文；仅发现相似子串或 identifier 不足以通过。
3. 保存截图并视觉核对确为关于本机/构建号页面，且显示值与预期一致。打开 URL 的成功回复、修改后的 plist 或计划参数不能替代页面证据。
4. 保留现有显示帧、正常关机、辅助退出及启动后只读复核条件。不同接口有不同结果时分别记录，不能用页面成功覆盖文件读取或关机失败。

可准备的导航请求为 `apps.open_url`，目标 `com.apple.Preferences`，URL 为 `prefs:root=General&path=About`。该 URL 尚未在当前客户机验证；若不能打开目标页面，保留失败，不把请求中的目标页面写成观察结果。

观察器需明确记录两层等待预算：当前宿主 RPC 为 75 秒，已准备的外层传输为 100 秒。`screen.unlock` 未传参数时客户机默认 10 秒；其允许范围为 1 至 60 秒，后续计划需明确选择和验证请求参数。扩大等待不能单独证明 SpringBoard 已就绪，仍需实际应用和页面证据。

## 未完成的准备与授权范围

需等原离线事务及收尾通过后，再核对当前发布状态、制作完整启动备份、实现页面证据验证并冻结新计划。已有 10 项入口/传输夹具回归不覆盖上述真实页面消费。

当前批准计划明确 `VMStarts=0`、`securityWindows=0`。上述运行、导航和新增观察还没有具名批准。本次没有改变该范围，也没有执行这些请求。后续 VM 程序的实际 SHA-256、CDHash 和监督工具需在新计划准备时重新核对；旧窗口不能自动复用。

本项不新增 CFW 补丁，不修改历史验收结果，不声称补丁运行因果效果已通过。整项 `accepted=false`。

源码、候选接口 manifest 和准备记录见 `evidence/T32-T33-completion-20261023/application-consumer-preparation-20261024/manifest.json`。真实页面、导航和读取请求仍待具名运行验收。

## 摘要日志封装

为后续 `files.read` 和 `ui.describe` 准备了独立传输封装：日志保存二进制长度和 SHA-256，调用方仍收到原始回复以核验完整内容。覆盖 classic 顶层 `data/image`、RPC 文件的 `result.content` 及页面的 `result.screenshot.data`。文件错误、大小和截断状态保留；无法按预期解析的二进制回复在写日志前失败。

原样转发基线的6项回归先失败，封装后6项通过；连同入口和传输共16项联合回归通过，1.645秒、退出0。所有二进制数据为夹具，未读取真实AA.gl或截图。新模块尚未接入观察器入口或任何运行计划；后续实际使用前需接入、验证并列入冻结输入。原始失败、源码和结果保存在 `hash-only-response-preparation-20261024/manifest.json`。


## 页面和文件回复校验准备

新增`t32_t33_runtime_evidence.py`及9项隔离回归，0.016秒、退出0。该模块不发请求、不启动VM，尚未接入运行观察器。它要求外部观察的前后Settings PID、`ui.describe.frontmost.pid`及AX PID相同，`verified=true`、`context_changed=false`；所查`describeScreen`没有返回结束时的PID，因此后续必须另取前后`apps.foreground`回复。

构建号只从有效frame内可见AX元素的label/value匹配完整标记；相似子串、identifier、不可见元素、变化PID、不完整AX树及不匹配截图均拒绝。截图须为可解码JPEG且长度、尺寸与回复相符。即使夹具通过，输出仍明确`visualReviewRequired=true`、`runtimeValidated=false`及`patchCausalityValidated=false`，不能替代关于本机页面的视觉核对和完整运行验收。

AA.gl文件回复校验要求路径相符、base64、`truncated=false`，完整size大于0且与解码长度相同，只返回摘要。没有读取真实AA.gl；EPERM原因仍未查明。新增回归命令：研究tools目录下以仓库`.venv/bin/python3 -B -m unittest -v test_t32_t33_runtime_evidence`执行。源码和日志见`evidence/T32-T33-completion-20261023/application-evidence-checks-20261024/manifest.json`。

摘要日志封装已在后续入口接入并通过17项组合回归，实际新运行计划仍未生成或执行；此前“尚未接入入口”是历史状态。证据见`budgeted-runtime-entrypoint-v3-20261024/manifest.json`。
