# T06/T07：连接关闭与 worker 监护差异审查

日期：2026-10-01。本地基线 `8d84bbc`（分支 `codex/upstream-4bab3b7-integration`）。固定上游 `upstream-2.2.3` = `a969cd5d9206932dc1a2797348027fbc7d0ee347`；历史基线 `upstream-2.0.8` = `9d218dedf58d4b19db5e51c8b584c1f14a96eee3`。上游对象用 `git show`/`git diff` 读取，未 checkout、merge 或 cherry-pick。

## 来源与筛查范围

| 上游提交 | 路径 | 本项 |
| --- | --- | --- |
| `1df6c43c` Let the host close vphoned connections so replies are not truncated | `VPhoneDaemon/Daemon/{APIWire,GuestFileTransfer,GuestHyperTextHandler,GuestPortForwardHandler,GuestWebSocketHandler}.swift`；`VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControl.swift` | T06 |
| `2e2ed0a8` Restart the vphoned worker every second and log why it exits | `VPhoneDaemon/Native/vphoned_proxy.c`；`VPhoneDaemon/Configuration/vphoned.plist`；`Research/vphoned_http_api.md` | T07 |

筛查命令：`git log upstream-2.0.8..upstream-2.2.3 -- VPhoneDaemon`（35 个提交）及 `-- VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication`（11 个提交）。按 close、SIGPIPE、shutdown、timeout、dup、autoRead、EAGAIN、waitpid、retry 检索差异。结果：

- 只有上述两个提交改变连接关闭或 worker 监护。
- `0f9a949` 中的 close/timeout 行来自 GuestIrisinInstaller 文件拆分，增删成对，不改变行为。
- `fa89134`（IcliKit 0.7.4：launchd 回复泄漏导致监听端口不释放）属于 T08 依赖升级，本项未处理。
- 上游宿主 TCP 代理 `VPhoneAPIProxy.swift` 在两个 tag 之间无变化。
- 两个 tag 之间没有涉及 SIGPIPE、短写、dup fd 或上传背压的上游改动。

## T06 对照

改动前，本地 `sources/VPhoneDaemon/Daemon/` 与 `upstream-2.0.8` 的关闭语句一致，缺少 `1df6c43c` 的全部 daemon 改动。

| 上游变化 | 改动前本地 | 结论与处理 | 本地依据（改动后行号） |
| --- | --- | --- | --- |
| `Channel.closeAfterPeer()`：最后一次写出后不主动关闭，30 秒后备关闭，开启 autoRead 以观察 EOF | 无 | 缺失，已迁入；放在仅依赖 NIOCore 的新文件，便于单独编译检查 | `APIConnectionClose.swift:21-48` |
| 同上，后续读取的数据 | 上游让后续字节进入 HTTP/WebSocket 处理器 | 本地有意不同：在管线最前端丢弃后续字节；重复调用只保留一个定时器 | `APIConnectionClose.swift:27-29,51-56` |
| HTTP 普通回复结束后 `closeAfterPeer` | `channel.close` | 缺失，已迁入 | `GuestHyperTextHandler.swift:301` |
| 文件下载结束后 `closeAfterPeer` | `channel.close` | 缺失，已迁入；读取失败分支仍立即关闭，与上游一致 | `GuestFileTransfer.swift:51` |
| 端口转发：回显 close、错误关闭、后端关闭三处改为 `closeAfterPeer` | `close` | 缺失，已迁入 | `GuestPortForwardHandler.swift:110,160,213` |
| 事件 WebSocket：收到 close 帧后回显 close，再 `closeAfterPeer` | 直接 `context.close` | 缺失，已迁入；本地另在 close 后移出事件广播并忽略后续帧 | `GuestWebSocketHandler.swift:24,45-51` |
| 宿主 HTTP 事务读完回复后关闭连接（`VPhoneGuestControl.swift` `defer { connection.close() }`） | 本地宿主不直接在 VSOCK 上做 HTTP 事务。URLSession 经 TCP 代理访问 1339；代理在客户端 EOF 后对客户机方向 `shutdown(SHUT_WR)`，最多排空 5 秒，worker 退出时释放复制的 fd | 已等价存在；新增回归测试 | `VPhoneAPIProxy.swift:71,243-245,264`；`VPhoneAPIVSockConnector.swift:16` |

本地额外约束（有意不同）：`closeAfterPeer` 使连接在回复后保持到宿主关闭。宿主代理只检查连接的第一个请求头（token、Origin/Host、凭据移除）。为不新增未经代理检查的请求路径，`GuestHyperTextHandler` 对同一连接的第二个请求头返回 400 且不执行（`GuestHyperTextHandler.swift:17,28-37`）。返回回复而不是忽略，原因是 NIO `HTTPServerPipelineHandler` 在已交付请求未回复时吞掉 `read()`，宿主 EOF 将只能由 30 秒后备关闭处理（swift-nio 2.83.0 `HTTPServerPipelineHandler.swift:470-481`）。

未变的通信边界：

| 项目 | 状态 | 本地依据 |
| --- | --- | --- |
| 1337/1339 分离 | 未改；经典 1337 协议与 GUI 路径未触及 | `VPhoneAppDelegate.swift:143-159` |
| 代理 token、Origin/Host、凭据移除 | 未改 | `VPhoneAPIRequestGate.swift`；`VPhoneAPIProxy.swift:153-192` |
| SIGPIPE | 已存在：宿主 fd 设置 SO_NOSIGPIPE | `VPhoneAPISocket.swift:20` |
| 短写 | 已存在：初始请求循环写出；转发按实际写出字节移除 | `VPhoneAPIProxy.swift:209-221,267-273` |
| 超时 | 已存在：准入/连接/写 5 秒、空闲 300 秒、排空 5 秒 | `VPhoneAPIProxy.swift:16-22` |
| dup fd | 已存在：`F_DUPFD_CLOEXEC` 并持有框架连接对象 | `VPhoneAPISocket.swift:10-14` |
| 上传背压 | 已存在：客户机写文件期间关闭 autoRead；代理每方向 32 KiB 缓冲，写出前不再读取 | `GuestFileTransfer.swift:97-106`；`VPhoneAPIProxy.swift:241,256` |
| 期限/取消/迟到响应、会话代际 | 未改 | `VPhoneAPIHTTPExchange.swift:15-46`；`VPhoneAPISession.swift:78-120` |

## T07 对照

改动前，本地 `vphoned_proxy.c` 与 `vphoned.plist` 与 `upstream-2.0.8` 相同。

| 上游变化 | 改动前本地 | 结论与处理 | 本地依据（改动后行号） |
| --- | --- | --- | --- |
| worker 退出后固定 1 秒重试，取消 1/2/4/8 秒指数退避 | 指数退避，上限约 10 秒 | 缺失，已迁入 | `vphoned_proxy.c:64-70,123,159` |
| 每次退出记录退出码或信号 | 只记录 "worker exited" | 缺失，已迁入 | `vphoned_proxy.c:152-158` |
| waitpid 失败时记录 `strerror(errno)` | 无 | 本地有意不同：上游在 `close()`、`access()` 之后读取 errno；本地在 waitpid 后立即保存 | `vphoned_proxy.c:135,153` |
| plist：`ThrottleInterval` 1、`ProcessType` Interactive、stdout/stderr 写入 `/var/log/vphoned.log` | 无这些键 | 缺失，已迁入；与上游 2.2.3 plist 逐字节一致 | `Configuration/vphoned.plist:15-22` |
| `Research/vphoned_http_api.md` 说明 | 本地无该文件 | 以本记录代替，未新建上游文档副本 | — |

保留项：SIGTERM/SIGINT 停止（`vphoned_proxy.c:89-92`）；停止时 3 秒后升级 SIGKILL（`:72-83`）；存活管道使代理死亡后 worker `_exit`（`:42-49`）；成功退出交还 launchd（`:142-145`）；pending-update 失败返回 1（`:147-151`）。会话代际检查在宿主 `VPhoneAPISession`，本项未改。

worker 区分：本项只涉及客户机 API daemon 的 proxy 与 I/O worker（`--io`）。native restore worker 是宿主 CLI 子进程，监护在 `sources/vphone-cli/VPhoneNativeRestoreWorker.swift:109-162`（阶段期限、SIGTERM→SIGKILL、父进程 250 ms 检查），`2e2ed0a8` 不涉及，本项未改。

默认安装范围：`make build` 与 CFW 安装仍使用 `scripts/vphoned/vphoned.plist` 的经典 daemon。本项 plist 只进入 `make daemon_api_build` 候选产物，候选未安装、未激活。

## 修改

| 文件 | 内容 |
| --- | --- |
| `sources/VPhoneDaemon/Daemon/APIConnectionClose.swift`（新） | `closeAfterPeer`、`APIDiscardAfterReply` |
| `sources/VPhoneDaemon/Daemon/GuestHyperTextHandler.swift` | 回复后 `closeAfterPeer`；单连接单请求 |
| `sources/VPhoneDaemon/Daemon/GuestFileTransfer.swift` | 下载结束后 `closeAfterPeer` |
| `sources/VPhoneDaemon/Daemon/GuestPortForwardHandler.swift` | 三处 `closeAfterPeer` |
| `sources/VPhoneDaemon/Daemon/GuestWebSocketHandler.swift` | 回显 close、移出广播、忽略后续帧 |
| `sources/VPhoneDaemon/Native/vphoned_proxy.c` | 固定 1 秒重试、退出原因、保存 waitpid 错误 |
| `sources/VPhoneDaemon/Configuration/vphoned.plist` | 上游 4 个 launchd 键 |
| `tests/fixtures/daemon_proxy/main.c` | harness 增加 signal、bind 动作与 SIGCHLD 忽略开关 |
| `tests/test_daemon_proxy.py` | 新增 5 项 |
| `tests/test_daemon_api_build.py` | 新增 plist 检查 1 项 |
| `tests/fixtures/host_api/server.py` | `--wait-for-peer-close` 模式：回复后等待对端关闭并记录耗时；WebSocket 回显 close |
| `tests/VPhoneAPIKitTests/APIHTTPTests.swift`、`APIProxyTests.swift` | fixture 参数；新增宿主关闭测试 1 项 |

## 验证

环境：worktree 未含 `.venv`，建立被 `.gitignore` 忽略的符号链接指向主仓库 `.venv`（`run_tests.py` 与 Swift HTTP fixture 固定读取 `ROOT/.venv`）。在 worktree 内初始化 `vendor/*` 子模块（递归），并按 Makefile 格式生成被忽略的 `sources/vphone-cli/VPhoneBuildInfo.swift`。

| 命令 | 结果 |
| --- | --- |
| `.venv/bin/python3 -B -m unittest tests.test_daemon_proxy -v` | 12 项通过 |
| 同一测试对改动前 proxy（HEAD）副本 | 4 项失败：固定重试（6 秒内未到第 4 个 worker）、退出码、信号、waitpid 错误 |
| 同一测试对上游 2.2.3 proxy 副本 | 1 项失败：ECHILD 被记录为 "No such file or directory" |
| `swift test --filter APIProxyTests` | XCTest 11 项通过；新增测试 0.237 秒 |
| 同一新增测试，临时去掉代理对客户机方向的 `shutdown`（负对照，已恢复） | 失败：5 秒内 fixture 未观察到宿主关闭 |
| `swift test --filter 'APIProxyTests\|APIHTTPTests\|...'` | Swift Testing 15 项、2 个 suite 通过；该正则未选中 XCTest |
| `make daemon_api_build`（改动后） | 退出 0；iOS 交叉编译、依赖 pin、候选签名与 manifest 检查通过；候选 `vphoned` SHA-256 `c4774436b3007764e8b4b2f20552dc2289dde7b4dcbb25a4188bf7a7dd3dc864` |
| NIO 临时检查（scratchpad SwiftPM 包，固定 swift-nio `34d486b0`，编译同一份 `APIConnectionClose.swift`，macOS TCP 回环） | 16 项检查通过，详见下文 |
| `make test_python` | 397 项通过 |
| `make test_swift` | 退出 0；Swift Testing 10 次运行共 738 项通过；XCTest 共 179 项执行、3 项跳过、0 失败；tar pipe 两条 1 GiB 路径峰值 RSS 8,945,664 / 8,028,160 字节；`test_guest_components` 124 项检查 0 失败 |

NIO 临时检查结果（事实）：本地版本回复 64 KiB 后不先关闭；同一次写入中的第二个请求得到 83 字节 400 回复且未执行；回复后再发送的请求无回复且未执行；宿主 `SHUT_WR` 后 EOF 在 0.001 秒内出现；宿主不关闭时 1 秒后备定时器在 1.003 秒关闭；autoRead 关闭后仍观察到 EOF。上游版本同一场景执行了第二个请求。该检查位于 scratchpad，不是仓库回归资产。

## 事实、推断与未验证

事实：

- 本地 daemon 源码现包含 `1df6c43c` 的关闭行为和 `2e2ed0a8` 的重试、日志及 plist 改动，并编译进候选产物。
- 宿主经代理访问时，在 fixture 等待对端关闭的条件下，HTTP、RPC、下载、上传、WebSocket 五类连接的回复完整，宿主在测试时长 0.237 秒内关闭。

推断（待验证假设）：

- 客户机 XNU vsock 在 close/shutdown 时丢弃待发数据，是上游提交说明的观察；本地未复现。本地改动能否消除 8–16 KiB 回复截断需要真实客户机验证。
- 宿主 macOS VSOCK fd 上的 `shutdown(SHUT_WR)` 能否使客户机 NIO 观察到 EOF 未验证；测试中客户机端由 TCP 替代。

未验证：

- 真实 VM 中的回复完整性、WebSocket close 往返、端口转发关闭。
- iOS launchd 对 `ThrottleInterval`、`ProcessType`、`StandardOutPath` 的处理；`/var/log/vphoned.log` 可写性；该日志没有轮转，增长未处理。
- worker 早期退出后 1 秒重试在 iOS 启动期的实际恢复时间。
- 只在 30 秒后备关闭时释放的连接：需要等待服务器 EOF 的客户端会占用连接 30 秒，未测。
- 候选 daemon 未安装、未激活；未操作 VM。
