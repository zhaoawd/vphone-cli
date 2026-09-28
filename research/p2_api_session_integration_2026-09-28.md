# P2 第九批：API 会话身份与重连

日期：2026-09-28。第八批已提交为 `6845e1c`。固定上游仍为 `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3`。

## 行为与边界

显式启用 `--api-listen` 后，宿主通过本地已认证代理运行 `VPhoneAPISession`。会话绑定实际 VM 锁的 `state.instanceID`，HTTP health 成功后建立 WebSocket。两次返回的 API 版本、daemon 进程 UUID、二进制 SHA-256 和能力集合必须一致，才进入 `ready`。

候选 daemon 的 API v1 增加 `instance_id` 字段、`session_identity` 能力和只读 `agent.health` RPC；`connected` 事件返回完整 health。UUID 在每个 API worker 进程内固定，worker 重启后重新生成。固定上游的 connected 事件只有 API 版本，本批身份字段和宿主会话状态机是本地扩展。来源与本批文件摘要见 [来源清单](p2_api_session_sources_2026-09-28.json)。

原始 HTTP/WebSocket 客户端仍接受缺少实例字段的旧 health；托管会话要求实例字段和显式能力。未满足条件时返回不可用状态并重试，不从 `api_version=1` 推断扩展能力。

| 对象 | 行为 |
| --- | --- |
| 状态 | `idle`、`connecting`、`ready`、`reconnecting`、`stopped` |
| VM 身份 | `vmInstanceID` 对应持锁宿主进程的 runtime instanceID |
| 连接身份 | 每次新 WebSocket 分配新的 `generation`；仅 ready 时公开 |
| health | 仅 ready 时公开 `apiVersion`、`binaryHash`、`capabilities`、`ios`、`instanceID` |
| 握手期限 | 默认 5 秒；宿主集成的 HTTP/RPC 请求期限也是 5 秒 |
| 心跳 | 每次成功后等待 3 秒，通过当前 WebSocket 调用 `agent.health`，重新比较身份、摘要和能力 |
| 失败重连 | 清除公开 health/generation，关闭连接，等待 1 秒后重新执行 HTTP health 与 WebSocket 握手 |
| 请求 | 仅 ready 时提交；可要求特定 capability；断线后不重放已提交请求；返回前再次检查代际 |
| 停止 | 同步清除公开状态，取消监控并关闭旧 socket；迟到探测不能恢复旧状态；允许显式重新 start |
| 错误 | 状态仅公开有限错误码；远端错误文本、URL、凭据不进入状态 |
| 事件 | 管理器消费连接事件以检测断线；业务事件分发尚未接入 |

Unix socket 的 `capabilities` 响应在显式启用时增加 `api_session`，使用上述 camelCase 字段。未启用和 DFU 不增加该字段。原 `guest_connected`、`guest_capabilities`、`commands` 仍报告原 1337 控制路径。关闭宿主时先停止托管会话，再停止代理。

宿主默认记录并比较 daemon 自报摘要；库调用方可以提供 `expectedBinaryHash` 固定值。本批没有增加 CLI 摘要固定选项，自报摘要不构成二进制真实性证明。旧候选 daemon 未更新时，原始代理仍可使用，托管会话不会进入 ready。候选构建不安装或激活 daemon。

## 验证

- `make test`：Python 385 项通过；Swift Testing 696 项、96 个 suite 通过；XCTest 162 项执行，3 项跳过，0 失败。tar pipe 内存检查通过。
- 随后增加完整代理接线测试，`swift test --filter 'APIProxyTests|APISessionTests'` 共 17 项通过。新增测试确认已认证代理后的会话握手、业务 RPC 和代理停止后的状态清除。
- 会话测试覆盖 HTTP/WS 实例不一致、能力缺失、摘要固定值不匹配、握手期限、心跳身份变化、断线重新分配代际、已提交请求不重放，以及停止后的迟到 HTTP 探测。Wire 测试覆盖旧 health 兼容和非法实例字段。
- Unix socket 测试覆盖可选状态字段、停止状态，以及未启用/DFU 时省略字段；原有能力字段回归通过。
- `make daemon_api_build`：iOS arm64 候选构建和签名、依赖 pins、产物元数据检查通过；没有安装或激活。
- 宿主 `make build`：release 编译、资源打包、应用签名和 entitlements 校验通过。

日志位于 `research/artifacts/p2-api-session-2026-09-28/`（被 Git 忽略），其摘要写入来源清单。

候选 `vphoned` SHA-256：`d1bb072b9361a7533dd2812130f0f96ae07d72a3b2f5e5319daa06a0d502a4ea`。

## 后续工作

下一批先建立只读宿主业务命令的参数、结果、错误和能力映射，再接入有副作用的命令。候选 daemon 安装选择、guest 同步、业务事件、其他 guest components 和完整 bundle 布局仍待处理。真实 VSOCK、worker 重启、guest 应用行为与 VM 验收继续按既有要求跳过；宿主 fixture 与构建结果不证明这些行为通过。
