# B29：RootHide VM 构造与验证

2026-10-10。用户授权构造 RootHide VM，并要求磁盘余量低于 5G 时停止。本轮按更保守的 5 GiB（5,368,709,120 字节）执行。没有新增整项任务验收，T08 保持部分完成。

## 结果

样本目录：`/Users/qcz3840/github/vphone-cli/vm-roothide-20261010`。通过生产 `vm clone` 从已停机的 `vm-new` 创建，保留原设备身份；源 VM 与样本不得同时运行。磁盘逻辑容量 64 GiB，APFS 共享区块不能按两个文件的 allocated size 相加计算独占空间。

RootHide 物理目录为 `/private/var/containers/Bundle/Application/.jbroot-000114514191980C`。先验证独立恢复 shell 和 API 可用，再通过既有 bootstrap.uninstall 卸载 rootless `/var/jb`；用 bootstrap.install 安装 Irisin 4.5.26。随后以固定的 89 个官方来源软件包生成事务，通过实际 `irisin-install` 执行 dry-run 和安装。dry-run 保持初始 dpkg 状态摘要，实际安装退出 0；最终 90 条记录（89 包加 firmware 虚拟记录）均为 `install ok installed`。事务顺序按保存的官方 TransactionPlanner 规则构造，没有执行 libsolv SAT 求解器选包，不能视为 Irisin 图形界面完整流程验收。

补齐 RootHide 基础目录、加载器 `.jbroot` 链接、账户数据库和 SSH 主机密钥。已有密钥保持，不导出私钥或 master.passwd。`dpkg --audit` 最终无输出；RootHide shell、root/mobile 身份、/dev/null、apt 2.6.0 和 curl 8.0.1 实际运行通过。冷启动前后，dpkg 状态、pwd.db、spwd.db 和 ed25519 密钥摘要一致。Fila、Inspector、Xrash、iGhostVT、Irisin 已注册，未做应用交互验收。

最终运行 `runs/20261010-022458-b3cc7574` 验证 API 候选摘要、libroothide 检测、单一 RootHide root、Irisin loaded 和 OpenSSH 9.2 banner。没有尝试 SSH 身份认证。另一次独立采样观察到物理 RootHide 路径下的 irisind 以 UID 0 运行，随后按官方源码的空闲退出行为消失；仅凭延迟采样 pid=0 不能判定失败。

## 启动限制

现有旧 CFW 冷启动没有自动加载 RootHide 服务。研究启动脚本通过串口显式启动 API_ONLY 候选，再调用官方 `bootstrapIrisinDaemon` helper 和 RootHide launchctl。最终日志中 Irisin 与 SSH 激活命令均退出 0。脚本路径：`/Users/qcz3840/github/vphone-cli/research/artifacts/roothide-vm-2026-10-10-b29/boot_sample.py`；`--smoke` 在就绪后正常停机，默认保持运行至 Ctrl-C 或低空间停止。该脚本是本样本研究辅助文件，没有接入产品自动启动流程。

宿主依赖既有冻结工件 `/private/tmp/vphone-b26-runtime/vphone-cli.app/Contents/MacOS/vphone-vm`，SHA256 `c8e8be423f47c2bc85a7bca5715c306a49cbacba1442a5882416493660a5f8ff`、CDHash `62a1f395413f6878c4de0042f6e77962aa2b1219`。同摘要、同签名的持久副本在另一执行路径立即收到 SIGKILL，原因未查明；未通过新增 AMFI 放行处理。首次沙箱内启动发生 AppKit 注册 SIGABRT，沙箱外使用原冻结路径可运行。失败记录保留。没有建立可移植宿主封装。

所有启动使用 `--no-vphoned-update`。API_ONLY 候选位于 `/var/root/vphone-b29-api`，SHA256 `83075a0c9de2ff5bbfd01b211ce204f59bd18cdf9eb0efb7bd0891a62f00bc07`；未替换系统 classic daemon、缓存或媒体库。旧 256 字节相机协议继续保留。没有修改产品源码、System 固件、持久 SIP/AMFI、TCC 或系统 helper。

实际 `services.start` 请求仍返回 `api_guest_error`、guest_code=`failed`；当前包络未保存原始状态值，不能将该次结果写为状态 144。初始 Irisin 安装曾返回 service_start warning 144，历史状态 144 的原因未查明。官方 helper 的显式启动成功不等于该 API 方法已修复。原始 XPC 诊断、部分角度旋转和完整 T08 服务矩阵继续待验收。

## 磁盘与清理

构造开始可用空间 38,993,920,000 字节（约 36.32 GiB）。本轮安装阶段记录最低 34,820,734,976 字节（约 32.43 GiB）；最终启动阶段最低 35,295,256,576 字节。独立线程每 0.5 秒检查磁盘，低于 5 GiB 时对本轮 VM 只发一次 SIGINT，等待正常关机；45 秒仍未退出才终止进程。阈值表示停止触发条件，关机期间仍可能继续写入。模拟低空间验证了停止事件和单次信号，没有实际填满磁盘。

已删除客户机中本轮生成的 `/var/root/vphone-b29`、传输分片、bundle.tar 和 bundle.tar.gz；清理前后 dpkg 状态、系统 classic daemon 和缓存摘要一致。初次清理在删除前因 RootHide PATH 未设置而退出，修正后重跑通过。宿主 `/private/tmp/vphone-b29-prepared` 已删除，软件包摘要、固定索引、事务、脚本和运行证据已保全。89 个下载包约 90 MiB 仍保留在 `/private/tmp/vphone-b29-packages`，避免重复下载。

最终可用空间 37,314,560,000 字节（约 34.75 GiB），未触发阈值。测试 VM 已停机，记录 ApplePSCI system off、Guest stopped、退出 0，并独立确认两个 Disk.img 无打开句柄。既有 vm-2607 PID 35668 保持运行。源 vm-new 的 config、classic 载荷、restore-info、NVRAM 摘要，以及 Disk.img 容量和 mtime 保持；没有计算完整 64 GiB 摘要。

## 证据范围

`manifest.json` 固定归档文件摘要；`summary.json` 记录未验收范围；construction 保存事务、安装输出、软件包状态、服务采样和冷启动读回；packages 保存官方来源快照、SHA256 和准备脚本；runs 同时保留失败及最终成功记录。未归档 token、私钥、账户密码文件或 VM/运行时二进制。OwnGoal 的签名端点本次返回 404，下载采用 HTTPS、官方索引和 SHA256 核对，没有独立 GPG 认证证据。
