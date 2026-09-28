# P2 第七批：宿主 HTTP/WebSocket 基础库

日期：2026-09-28。第五、六批已提交为 `2efd925`。固定上游为 `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3`。本批代码、测试及来源记录纳入本次提交。

## 范围

新增独立 SwiftPM product/target `VPhoneAPIKit`。调用方显式提供 HTTP/HTTPS endpoint 和可选 token。库提供 health 检查、JSON RPC 和 WebSocket 请求/事件接口；默认 CLI、`VPhoneControl`、Unix socket、GUI/headless 和 1337 客户机路径未接入该库。没有新增监听端口、启动 VM 或安装候选 daemon。

上游 `VPhoneKit/VPhoneExternalAccessKit/VPhoneAPIClient.swift` 的 JSON 值、错误、响应和事件类型迁入 `VPhoneAPIValue.swift`，保留原 Codable 表示。HTTP/WebSocket 客户端按上游 API v1 字段与路径适配本地期限、取消和响应关联要求。未引入额外依赖。逐文件摘要及上游参考见 [来源清单](p2_host_api_sources_2026-09-28.json)。

## 接口与约束

| 对象 | 本批行为 |
| --- | --- |
| endpoint | 仅 HTTP/HTTPS；拒绝 URL 内的用户名、密码、query 和 fragment；允许显式基础路径 |
| token | 显式参数，不隐式读取环境变量；16–256 个 URL-unreserved 字符；HTTP 和 WS 均使用 Authorization Bearer header，不加入 URL |
| HTTP 重定向 | 拒绝重定向，不向重定向 endpoint 转发凭据 |
| health | GET `/v1/health`；要求 HTTP 200、status=ok、api_version=1、64 位小写十六进制 binary_hash 和字符串 capability 列表；可指定必需能力及预期 daemon SHA-256 |
| RPC | POST `/v1/rpc`；自动生成字符串 ID；method 1–128 字符；JSON 请求最多 1 MiB |
| 响应 | JSON 消息最多 8 MiB；校验 type、ID 及 result/error 互斥；保留 null result 和客户机错误 code/message；HTTP 成功要求 200 |
| HTTP 接收 | 按 URLSession 数据块接收；检查 Content-Length，并在每次追加前检查累计容量；期限或取消后停止本地任务 |
| WS 请求 | `/v1/events`；单个接收循环；按 ID 关联并发响应；每个 socket 具有独立 UUID generation，写入生成的请求 ID；最多 16 个本地待响应请求 |
| WS 事件 | 支持无 RPC 时显式启动事件接收；缓冲最多 64 条；溢出关闭连接并返回 event_overflow，不静默丢弃 |
| 期限 | HTTP/WS 默认 30 秒，可配置为大于 0 且不超过 130 秒；HTTP 从提交到完成使用绝对期限，WS 期限覆盖发送等待和响应等待 |
| 取消和断线 | 调用方取消、期限、完成只交付一次；WS 断线/关闭使所有等待失败；重复、未知、超时后及旧 generation 响应不会完成其他请求；关闭后需新建 socket |

8 MiB 响应、16 个等待和 64 条事件是本地库的容量选择，不代表客户机容量。请求完成或本地等待取消会释放等待名额；客户机可能仍在执行已提交的操作，这些上限不约束客户机尚未结束的操作数量。调用方使用完毕须关闭 WebSocket。

health 只校验查询时的响应。API 版本不自动启用其他能力；业务命令的 capability 映射尚未接入。health 与后续 WebSocket 分别建立连接，本批未证明两者对应同一次 daemon 运行，也未实现 daemon 重启后的自动探测、摘要更新或自动重连。generation 是本地请求隔离标识，不是客户机身份认证。

JSON 数字沿用上游 `Double` 表示。本库的关联 ID 始终使用字符串；没有承诺任意大整数的无损往返。文件上传、下载、端口隧道和二进制相机协议未纳入该 JSON 接口。

## 验证

测试使用 `VPhoneAPIKit` 的真实生产解析和状态管理代码。Swift 传输替身覆盖乱序、并发、取消、超时、迟到及重复响应、断线、generation、错误隔离、等待上限和事件溢出。Python 标准库测试服务只监听 `127.0.0.1` 随机端口，通过实际 URLSession 验证 HTTP/WS Bearer、RPC、health、重定向拒绝、固定长度/分块响应上限、期限、调用方取消和并发 WS 响应。

首次容量测试中，仅发送超大 Content-Length 而不发送正文的测试响应触发期限；发送 JSON 类型和正文首字节后，该测试通过容量检查。生产接收实现同时从逐字节读取改为数据块回调。最终结果以回归日志为准。

新增 21 项测试已纳入完整回归。首次完整回归中，多项新测试约 15 秒后才继续执行，超出了模拟正常响应和服务启动的 2–5 秒等待；独立运行无此失败。测试现将正常响应/服务启动等待设为 30 秒，并保留 50 毫秒专用期限测试；WS 期限测试不再要求并行测试调度必须在 1 秒内恢复。生产库默认期限保持 30 秒。

| 检查 | 结果 |
| --- | --- |
| `make test_swift` | 退出 0；Swift Testing 686 项、94 suites；XCTest 145 项，3 项跳过，0 失败 |
| 归档传输内存检查 | 两条 1 GiB 路径通过；file/producer 峰值 RSS 为 7,651,328 / 7,766,016 字节 |
| `make build` | 退出 0；VPhoneAPIKit release 编译、默认 app 资源、签名和 entitlements 检查通过 |
| 上游来源 | JSON 类型为固定上游文件的未修改前缀；客户端和状态管理为本地适配 |

日志位于 `research/artifacts/p2-host-api-2026-09-28/`（Git 忽略）。本轮不重跑无改动的 Python 生产模块测试；本机 HTTP 服务由 Swift 测试调用项目 `.venv/bin/python3`。

## 后续范围

P2 仍为部分完成；P5 尚未完成。下一批可接入显式宿主代理或直接 VSOCK 传输，补齐代理 token/Origin/Host 检查及凭据清理，再逐命令验证参数、结果、错误和 capabilities。文件传输、手势串行、shell、定位 owner/generation/sequence、相机 v3 合约与配套测试镜像均需独立验证。

真实 VM 导入、启动、恢复和客户机安装继续按此前要求跳过。宿主库编译及回环测试不证明候选 daemon 在 iOS 上可运行，也不替代 VM 或应用验收。
