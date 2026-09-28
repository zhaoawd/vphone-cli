# P2 第八批：显式宿主 API 代理与 VSOCK 接线

日期：2026-09-28。上一批宿主 API 库已提交为 `a0af165`。固定上游为 `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3`。本批代码、测试及来源记录纳入本次提交。

## 入口与范围

`boot --api-listen 127.0.0.1:8765` 和 `vm launch NAME --api-listen 127.0.0.1:8765` 显式启用代理；端口 0 由系统分配。必须事先在进程环境提供 `VPHONE_API_TOKEN`，内容为 16–256 个 URL-unreserved 字符。地址只接受 IPv4 `127.0.0.1`，不接受非回环地址、主机名或 URL 路径。DFU 和 `--no-vphoned` 拒绝此选项。

启动前检查 token，错误信息不包含 token 值。`vm launch` 只把监听地址作为子进程参数传递，token 通过既有环境继承，不加入命令行或 trace。启动日志只输出实际 URL、VSOCK 1339 和 token 的环境变量名称。本批使用显式固定 token，不生成、落盘或打印随机 token；代理重启不会自动更换环境中的 token。

每个通过认证的 TCP 连接对应一个独立的 VSOCK 1339 连接。API daemon 必须已经安装；本批不安装、启动或自动更新候选 daemon。未提供选项时不创建监听器。原 GUI、Unix socket、headless 命令和自动更新仍使用现有 1337 客户机路径，没有迁移到候选 API。

## 来源与适配

| 对象 | 本批结果 |
| --- | --- |
| VPhoneAPIRequestGate | 从固定上游迁入；加强 Host/Origin、唯一凭据和 HTTP framing 检查，并移除 token 子协议 |
| VPhoneAPIProxy | 参考固定上游 TCP→VSOCK 转发设计；使用本地 POSIX/Dispatch 实现，不增加宿主 SwiftNIO 依赖 |
| VPhoneAPISocket | 复制并持有连接 fd，保留 VZ 连接对象；启用非阻塞、FD_CLOEXEC 和 SO_NOSIGPIPE |
| VPhoneAPIVSockConnector | 在 MainActor 调用 Virtualization.framework 的 1339 连接接口；仅将持有生命周期对象的 fd 包装交给代理 |
| CLI/AppDelegate | 增加显式启动参数、父子进程转发、启动前 token 校验、VM 启动后的代理创建及进程退出时停止 |

完整上游路径、blob 和 SHA-256 见 [来源清单](p2_api_proxy_sources_2026-09-28.json)。前几批来源清单保留各批提交时的快照。本批不改变固件补丁、kernel/DSC patch、guest payload 构建或 CFW 安装选择。

## 请求与资源约束

| 对象 | 本批行为 |
| --- | --- |
| 认证时点 | 先收齐并校验初始 HTTP 请求头，成功后才请求客户机连接；无效 token/Origin/Host 不连接客户机 |
| 凭据形式 | Bearer、token query 或 vphone-token 子协议三选一；缺失、错误和重复凭据均拒绝；比较使用上游逐字节比较实现 |
| 凭据移除 | 移除 Authorization、token query（含百分号编码的名称）和 token 子协议；拒绝 Proxy-Authorization；保留其他 query、子协议和已读取正文 |
| 请求头 | 最多 16 KiB，等待最多 5 秒；拒绝折行、控制字符、多个 Host、Origin、非回环 Host、非 origin-form target、重复 Content-Length/Transfer-Encoding 及二者共存 |
| Host | 认证成功后重写为 vphoned；不放宽候选 daemon 自身的 Host/Origin 检查 |
| 活跃连接 | 最多 16 个；超额 TCP 连接关闭，不创建转发 worker |
| 客户机连接尝试 | 最多 16 个尚未回调的尝试；宿主等待最多 5 秒；超时后仍保留尝试名额，直到实际回调，防止未完成回调累积 |
| 失败 | 请求拒绝返回 401；客户机连接失败返回 502；尝试名额耗尽返回 503；连接等待超时返回 504；错误不包含请求或凭据 |
| 转发缓冲 | 每方向最多 32 KiB 用户态待写缓冲，写出前不继续读该方向；内核 socket 缓冲另计 |
| 写入 | 非阻塞写入；连续 5 秒不能推进则关闭；初始请求写入使用独立的 5 秒期限 |
| 空闲与 EOF | 无字节进展 300 秒关闭；任一方向 EOF 后最多排空 5 秒，已读数据写完后才半关闭目标方向 |
| 停止与迟到连接 | 停止监听并 shutdown 活跃 socket，唤醒连接等待；worker 持有 fd 直到退出，避免关闭已复用的描述符；迟到回调只释放连接，不转发请求 |

计时由单调时钟或 DispatchTime 驱动，poll 最长按 50 毫秒间隔检查；线程调度可能延迟退出。代理只认证连接的初始 HTTP 请求头，随后进行字节转发；当前候选 daemon 的普通 HTTP 响应关闭连接，WebSocket upgrade 后复用已认证连接。本批没有实现面向任意 keep-alive 后端的逐请求认证或凭据过滤。

停止等待或断开连接不证明已提交到客户机的操作终止。Virtualization.framework 的连接回调没有在本批获得底层强制取消能力；未返回回调持续占用尝试名额。框架行为需要真实 VM 验证。

## 验证

- 9 项 XCTest 使用真实 TCP/socketpair：HTTP health、512 KiB JSON 往返、并发 WebSocket、拒绝请求不连接客户机、失败与超时、迟到连接释放、连接和未回调尝试上限、停止清理、未返回回调不保留宿主 fd、客户机不读取时的写期限，以及 fd 复制/SIGPIPE 配置。
- 6 项请求头测试含 15 组非法 Host/请求头样本，覆盖逐字节分片、16 KiB 边界、凭据移除、重复凭据和二进制正文保留。
- 3 项 CLI 测试覆盖选项转发、模式/地址拒绝及 token 错误不回显。
- 回环服务用项目 `.venv` 启动，只监听 `127.0.0.1`；代理后的服务要求没有 Authorization 且 Host=vphoned，再执行 HTTP/WS 测试。
- 测试发现并修复两处生命周期问题：Dispatch 回调继承 MainActor 导致执行队列断言；未完成回调的计数信号量销毁断言。现分别使用显式 Sendable 回调和锁保护的尝试计数，停止及未完成回调测试通过。后续复核将宿主 socket 的释放与回调对象生命周期分离；worker 退出后显式释放 socket，真实 `/dev/fd` 枚举确认未返回回调只保留尝试状态，不保留已结束的宿主连接。

| 检查 | 结果 |
| --- | --- |
| `make test` | 退出 0；Python 385 项；Swift Testing 695 项、96 suites；XCTest 154 项，3 项跳过，0 失败 |
| fd 生命周期修正后的 `make test_swift` | 退出 0；695 项 Swift Testing 和 154 项 XCTest（3 项跳过），0 失败 |
| 追加 fd 枚举断言后的代理专项 | 9 项 XCTest 通过 |
| 归档传输内存回归 | 两条 1 GiB 路径通过；最终 file/producer 峰值 RSS 为 7,634,944 / 7,815,168 字节 |
| `make build` | 退出 0；release 编译、默认 app 资源、签名及 entitlements 检查通过 |

日志位于 `research/artifacts/p2-api-proxy-2026-09-28/`（Git 忽略）。

## 未完成范围

真实 VM 导入、启动、恢复及客户机安装继续跳过。本批 VSOCK 适配器已编译，运行测试中的客户机端由本机 TCP/socketpair 替代；不能据此认定真实 VSOCK、候选 iOS daemon 或应用行为通过。

后续需把 health、daemon 摘要、capabilities 和自动重连绑定到 VM 会话，再逐命令适配参数、结果和错误。固定环境 token 的轮换由调用方负责；随机 token 的安全交付、IPv6/非回环监听、文件流式 API、定位和相机合约尚未接入。P2 仍为部分完成，P5 未完成。
