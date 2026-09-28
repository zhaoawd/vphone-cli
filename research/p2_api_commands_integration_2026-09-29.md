# P2 第十批：只读宿主应用命令映射

日期：2026-09-29。固定上游：`2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3`。基于第九批托管会话继续实现；第九批与本批一并纳入本次提交，前置提交为第八批 `6845e1c`。

## 入口与范围

通过现有 `vphone.sock` 发送以下请求：

```json
{"t":"app_list","transport":"api","filter":"user"}
{"t":"app_foreground","transport":"api"}
```

前置条件为宿主启动时显式指定 `--api-listen`，候选 daemon 已由其他流程安装并运行，托管会话处于 `ready` 且声明 `apps` 能力。本批不安装 daemon，也不启动 VM。

省略 `transport` 或指定 `classic` 时仍使用现有 1337 路径。`transport:"api"` 只接受上述两条命令，其他命令返回 `unsupported_transport`，不会转到经典路径。非法 transport 返回 `invalid_argument`。DFU 仍拒绝业务命令。

查询 `{"t":"capabilities"}` 不需要指定 transport。启用托管会话时，响应增加 `api_commands`，其中 `app_list`、`app_foreground` 分别表示当前 API 路径可用性。原 `commands`、`guest_connected`、`guest_capabilities` 保留经典路径含义。会话不在 ready 或缺少 `apps` 时，两项为 false。

## 参数与结果

| 宿主命令 | API 方法 | 参数与结果 |
| --- | --- | --- |
| `app_list` | `apps.list` | filter 默认 all，仅接受 all/user/system/running；发送同名字段 |
| `app_foreground` | `apps.foreground` | 发送空参数对象；返回 bundle_id、name、pid，保留非空 source，增加 verified 布尔值 |

应用列表保留既有八个字段：`bundle_id`、`name`、`version`、`type`、`state`、`pid`、`path`、`data_container`。`data_container` 来自固定 IcliSystem 版本的 `data_path`；候选 daemon 保留该字段。目录扫描记录可以缺少 name/version/data_path，此时输出空字符串。必需字段缺失、字段类型错误、空应用 bundle_id、负数/小数/越界 PID 均拒绝整个响应，不返回部分列表；未知字段不转发。

前台查询要求 `verified` 为布尔值并原样返回。`ok:true` 表示查询和字段解析成功；即使 pid 大于零，也不会把 `verified:false` 改为 true。此字段不证明宿主已验证真实前台应用。无有效前台应用时允许空 bundle_id 和 pid=0；source 为空时省略，与经典结果的空 source 处理一致。

结果到达后检查任务取消和连接代际。代际变化、断线及错误不触发重放或经典路径重试。两条查询不触发宿主截图；GUI 菜单和其他业务命令尚未迁移。

## 错误映射

| 条件 | 宿主 code |
| --- | --- |
| 未启用 API、会话未 ready / 会话报告 not_ready | `api_not_ready` |
| 缺少 apps 能力 | `capability_unavailable` |
| 连接代际变化 | `api_stale_session` |
| socket 断开或事件缓冲溢出 | `api_disconnected` |
| API RPC 超时 / 请求槽满 | `api_timeout` / `api_busy` |
| 信封或字段不符合合约 | `api_protocol` |
| API 响应超过现有 8 MiB 限制 | `api_response_too_large` |
| 其他 API 错误 / 其他传输错误 | `api_guest_error` / `api_transport` |
| 任务取消 | `command_cancelled` |

错误响应保留 `ok:false`、`error` 和稳定 code。任意客户机错误消息不写入该响应，以避免透传凭据或 URL；诊断细节因此受限。现有 Unix socket 同用户检查、命令期限、连接上限继续适用。停止本地等待不证明已提交客户机请求已终止。

## 来源与验证

映射依据本地经典 `VPhoneControl.appList/appForeground` 和固定上游 GuestAPI 的 `apps.list/apps.foreground`。数据容器字段另核对固定 IcliSystem `74843a56df54936c3949239a4ffb3ddcbe37dee4` 的 Apps.swift 与 LaunchServices.m。适配器和显式路由为本地实现。来源、文件及日志摘要见 [来源清单](p2_api_commands_sources_2026-09-29.json)。

- 新增 8 项 XCTest 已通过：四种 filter、数据容器与字段映射、verified 保留、默认经典路径、API 不可用时不回退、能力发现、非法请求/结果、错误脱敏、取消、过期代际，以及真实 Unix socket→托管 WebSocket 查询。
- 真实 socket 测试通过 Python 回环 fixture 提供 HTTP health 与 WebSocket；没有客户机 VM。候选 daemon 和 Icli 的实际应用枚举/前台行为尚未验证。
- 现有 HostCommandExecutorTests 24 项通过。
- `make test_swift` 最终复跑通过：Swift Testing 696 项、96 个 suite；XCTest 171 项执行、3 项跳过、0 失败。tar pipe 内存检查通过。
- 首次全量运行有 1 项既有测试失败：`ProcessRunnerTests.timeoutKillsChildIgnoringTermination` 预期 stdout 包含 ready，实际为空。该组 9 项单独复跑及随后完整复跑均通过。原因尚未查明；没有修改进程 runner 或该测试。首次失败与复跑日志均保留。
- 宿主 `make build` 通过：release 编译、资源打包、应用签名和 entitlements 校验完成。

日志目录：`research/artifacts/p2-api-commands-2026-09-29/`（被 Git 忽略）。

本批没有修改候选 daemon、固件、kernel/DSC 补丁或安装选择。第九批的来源清单保留当时文件快照，本批来源清单记录后续变化。

## 后续工作

接下来可处理文件读取合约：区分内联内容与文件流，验证容量、取消和下载到宿主路径的规则，再接入写操作。应用启动、终止、安装仍需独立映射及行为证据。P2 与 P5 均未整体完成；真实 VM 验收继续跳过。
