# P2 第十二批：API 文件上传

日期：2026-09-29。固定上游为 `9d218dedf58d4b19db5e51c8b584c1f14a96eee3`，参考 `VPhoneDaemon/Daemon/GuestFileTransfer.swift` 和 `GuestHyperTextHandler.swift`；本地增加会话身份校验和上传事务。

## 行为

显式 `transport:api` 的 `file_put` 接受绝对客户机 `path`、`data_b64` 或宿主绝对路径 `load`，可选八进制字符串 `perm`，默认 `644`，最大 `0777`。同时提供两种来源时，优先使用 `data_b64`，无效 base64 不回退到文件。内联最多 1 MiB，文件最多 64 MiB。宿主只打开普通文件，不跟随最后一级符号链接，以 64 KiB 分块复制到私有临时文件，再交给 URLSession 上传。复制完成后的来源修改不影响上传；不承诺复制过程是文件系统原子快照。

会话要求 `files` 和 `file_upload_identity`，最多四个上传任务，期限 120 秒。请求携带客户机进程 UUID、二进制摘要和 Content-Length。客户机先检查身份和长度，再创建同目录私有暂存；保留 NIO 上传背压。异步写完成后检查精确长度、fsync、设置权限并原子替换目标。末级目标符号链接被替换，不跟随其指向。断线、短体和写失败清理暂存，提交前保留旧目标。

宿主核对响应 path、size、UUID、摘要及会话代际。停止或重连会取消本地上传。请求提交后的错误带 `operation_may_continue:true`；响应丢失、取消或超时不能证明客户机未提交。没有应用层自动重发。HTTP 栈提前拒绝大请求时，客户端可能表现为传输错误或期限到期，不能依赖一定收到 HTTP 状态码。

## 验证

- 上传及命令专项：10 项 XCTest 和 3 项 Swift Testing 通过；覆盖二进制、空文件、容量、来源变更、符号链接/FIFO/目录拒绝、权限、UUID 大小写、错误身份、重定向、响应丢失和真实 Unix socket 到 HTTP 路径。
- 首轮测试发现 UUID 字符串大小写不一致；客户机改为 UUID 值比较。随后发现测试使用了错误的权限字段名；改为本地合约 `perm`，并补充宿主 load 参数检查。最终专项通过。
- 无固件完整回归通过：Python 385 项；Swift Testing 702 项、98 suites；XCTest 177 项、3 项跳过、0 失败。该次运行还包含同期进程拆分测试和客户机 C 测试，不代表上传独占这些测试数量。
- 独立 iOS API daemon 构建及 pins/签名/产物检查通过。宿主完整构建通过。

没有安装客户机候选、启动 VM 或修改固件/kernel/DSC 补丁。文件上传在真实客户机上仍未验收。默认 1337 路径保留。日志在 `research/artifacts/upstream-remaining-2026-09-29/`；来源和产物摘要见配套 JSON。
