# P2 第十一批：API 文件读取与流式下载

日期：2026-09-29。前置第九、十批已提交为 `3bfa613`。固定上游仍为 `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3`。本批尚未提交。

## 入口与容量

已有 Unix socket `file_get` 增加显式 API 路由：

```json
{"t":"file_get","transport":"api","path":"/var/mobile/example.bin"}
{"t":"file_get","transport":"api","path":"/var/mobile/example.bin","save":"/tmp/example.bin"}
```

客户机 path 必须为绝对路径且不能包含 NUL。save 必须为非空绝对文件路径，拒绝末尾斜线、`.`、`..` 和非字符串；父目录必须已经存在。本批不创建保存父目录。省略 transport 或使用 classic 时，保留原有下载实现。

| 对象 | API 路径行为 |
| --- | --- |
| 内联 | 最多 1 MiB，响应保留 `ok`、`size`、Base64 `data`；空文件合法 |
| 保存 | 最多 64 MiB，响应保留 `ok`、`path`、`size` |
| API 传输 | GET `/v1/files/content?path=...`，通过现有认证代理；路径使用 URLQueryItem 编码，并显式编码 `+` |
| 并发 | 每个托管会话最多 4 个下载；超额返回 `api_busy` |
| 期限 | 托管下载 120 秒绝对期限；已有 RPC/握手期限保留。底层客户端可显式配置不超过 130 秒 |
| 流式写入 | URLSession 每次 Data 回调直接写文件，不在宿主代码中累计整份响应。URLSession 自身缓冲由框架管理 |
| 大小检查 | 已知 Content-Length 超限时拒绝；每个数据块写入前再次检查累计大小；缺少长度的 chunked 响应同样受限 |
| 完整性 | 已知响应长度必须与实际写入字节数一致；连接提前结束或 URLSession 报错时拒绝发布 |

内联与保存均先写私有临时文件。内联最终只读取最多 1 MiB；保存不将整份文件读入 Data。四个并发保存的内容最多共 256 MiB，另有文件系统和框架开销。本批没有声明端到端峰值 RSS 上限。

## 会话身份与客户机适配

`api_commands.file_get` 仅在会话 ready 且声明 `files`、`file_download_identity` 时为 true。候选 daemon 增加后者能力，并在成功下载响应上返回 `X-Vphone-Instance-ID` 和 `X-Vphone-Binary-Hash`。宿主比较这两个响应头与已握手 health 中的身份与摘要，防止把另一次 daemon 运行的 HTTP 响应当作当前会话数据。

响应必须为 HTTP 200、原始 Content-Type 为 application/octet-stream，且没有内容编码或编码为 identity。拒绝重定向，不透传凭据到其他 URL。HTTP 下载完成后再次检查任务取消与连接代际；会话停止、断线或重连会取消仍在运行的下载。本批不续传、不重试、不切换到经典路径。

身份与摘要仍由 daemon 自报，不构成独立的二进制真实性证明。正在写入的客户机文件没有快照一致性保证。旧候选 daemon 未声明新能力时，API file_get 不可用。

候选下载入口以 O_NONBLOCK/O_CLOEXEC 打开文件，再检查普通文件类型；此更改避免 FIFO 打开在类型检查之前等待写端。真实客户机上的文件、VSOCK 和 FIFO 行为尚未验收。

## 宿主文件发布

每次下载用 mkdtemp 创建 0700 私有目录，内容文件以 O_EXCL/O_NOFOLLOW 和 0600 创建。保存时临时目录位于目标父目录，以支持同文件系统发布；内联时位于宿主临时目录。

完整下载通过身份、长度和代际校验后，使用 macOS `renamex_np(..., RENAME_EXCL)` 原子发布。已有文件、目录或符号链接均不覆盖。API 保存因此与经典路径的既有覆盖行为有明确区别。临时目录及未发布内容在成功返回、失败、超时、取消或结果被丢弃时清理。进程强制退出或系统崩溃后的临时目录清理不在本批实现范围内。

文件系统同步写入期间，取消需要等待当前系统调用返回；绝对网络期限不提供对阻塞文件系统调用的强制中断。宿主现有目录权限及同用户信任边界继续适用。

## 错误

沿用第十批会话和能力错误；新增或映射：

| 条件 | code |
| --- | --- |
| 非法 path/save | `invalid_argument` |
| 内联/保存超过容量 | `file_too_large` |
| 目标已存在 | `destination_exists` |
| 宿主文件操作失败 | `io_error` |
| HTTP 非 200/重定向 | `api_http` |
| 下载响应身份不匹配 | `api_stale_session` |
| 非二进制响应类型/长度校验失败 | `api_protocol` |

URLSession 直接报告的截断、连接错误仍映射为 `api_transport`；下载期限为 `api_timeout`，取消为 `command_cancelled`。错误消息不包含任意 HTTP 正文、URL 或 token。

## 验证与来源

- 相关 22 项测试通过，覆盖原应用合约、认证代理、文件内联/保存、目标已存在及符号链接、非法参数、身份和类型拒绝、重定向拒绝、chunked 容量、截断、期限、取消及四下载上限。
- 之后将保存测试扩展至精确 64 MiB；该测试及全量 175 项 XCTest 通过（3 项跳过）。
- 首次下载测试发现 `+` 被 Python query 解析为空格，以及 URLResponse.mimeType 未拒绝错误原始 Content-Type。已分别增加 `%2B` 编码和原始响应头检查；对应复测通过。
- 首次完整 Swift Testing 在 HTTP fixture 清理阶段停滞。采样停在 `APIHTTPFixture.stop()` → `Process.waitUntilExit()`；停止该次测试后，HTTP 组 5 项独立复跑通过。未获得稳定最小复现，触发原因尚未查明；没有修改进程管理代码，也不将单组通过视为该问题已修复。
- `make daemon_api_build`：候选 iOS daemon 构建及依赖 pins、架构、签名、entitlements/产物检查通过。
- `make test_swift` 完整复跑通过：Swift Testing 696 项、96 个 suite；XCTest 175 项、3 项跳过、0 失败。tar pipe 内存检查通过。
- 宿主 `make build` 通过：release 编译、资源打包、签名和 entitlements 校验完成。收尾修正新增代码的弃用 API 警告后，4 项下载测试及最终 `make build` 再次通过。

流式协议以固定上游 GuestFileTransfer 为依据，宿主实现、身份响应头与容量/发布规则为本地适配。来源和文件/日志摘要见 [来源清单](p2_api_files_sources_2026-09-29.json)。日志位于 `research/artifacts/p2-api-files-2026-09-29/`（Git 忽略）。

本批不修改固件/kernel/DSC 补丁和默认客户机安装选择。候选 daemon 只构建，不安装、激活或启动 VM。真实 VM 验收继续跳过。

候选 `vphoned` SHA-256：`8ce42a291dd0892aa2ce83d5d0f1e1a87984f0377b800fe3f256248642e292af`。

## 后续工作

下一批处理文件上传：显式路径/权限、容量和背压、临时文件提交、取消和失败后的客户机清理。应用启动、终止、安装和其余业务映射仍待完成。
