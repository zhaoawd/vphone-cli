# Task 8 第四版 host／第七版 kernel 来源启动尝试独立审查

日期：2026-10-14。审查者：acceptance_audit。只读核对启动、guest 查询、正式停止、停机读回、源 VM 元数据、附件和进程观察、容器格式比较及 AMFI 清理拒绝证据。仅写本文件和对应 JSON；未操作 VM、挂载、AMFI、系统服务或调试进程。

结论：证据支持指定第四版 VM 可执行文件在限定副本上进入 Virtualization.framework started 状态，并由正式 stop 停止。未取得正常 guest 启动或 shell 证据，正常启动未验收，原因未查明。临时 AMFI 调试进程清理仍未完成。Task 8/T34 保持未完整验收。

## 启动与停止证据

vm-boot-v4-kernel-v7.json 记录正式第四版 CLI 执行 `vm launch task8-copy --library-root /private/tmp/vphone-task8-acceptance-vms --headless`，运行 410.661522 秒后退出 0。summary 的实际 VM argv 指向已授权第四版 `2.6.20261016-local/VPhone.bundle/Contents/MacOS/vphone-vm`，配置为限定副本，带 --no-vphoned-update 及已冻结 binding SHA；未使用第七版 VM 可执行文件。

日志中的 framework started 表示框架启动操作成功。日志序列为 iBoot 输出、框架启动、guest control/camera 连接反复失败；未出现可供本次验收的 guest shell 或内核运行环境结果。日志文字“booting normally”不能作为正常 guest 启动通过证据。

guest-capabilities 通过 host 端返回 ok=true、命令退出 0，但 guest_connected=false、shell=false、guest_capabilities 为空。其 target PID 90543、instance ID `CAAA862F-BB3A-4D08-A00A-8210BF655B36` 与启动 summary 一致。该响应证明本次 host 控制实例可查询，不证明 guest 已运行。随后只读 `uname -a; sysctl kern.osrelease hw.machine` 请求退出 1，返回 guest not connected，未取得命令执行结果。

vm-stop-v4-kernel-v7.json/log 记录正式 stop 退出 0，对上述同一 PID/instance 发送 SIGINT。启动日志显示 requestStop 后 graceful shutdown 超时，随后 framework stop 成功并输出 VM stopped。因此 launch 的退出 0 是停止后的进程结果，不能据此判定正常启动或 guest 正常关机通过。

## 停机、来源及源 VM 观察

post-boot-v7-readback.json 记录 stopped_vm_lock_acquired=true、pending_transaction=false，绑定仍为 host 第四版／kernel 来源第七版。Disk.img inode 保持 589096904；启动尝试后的完整磁盘 SHA `9918d2bdd8f4cb9b653ebe0a5d552cd3f61bb4986421652f08c4049adfb82531` 等于启动前 receipt 和停机提交读回。post-boot-v7-attachments.plist 不含本轮副本、备份或事务镜像附件。

源 VM vm-new 的六个关键文件在保存观察中 device/inode/size/mtime/ctime 均标记与原观察一致，all_source_metadata_unchanged=true。此项是元数据比较，不升级为本轮对源 Disk.img 重新计算完整内容摘要。审查者只解析保存证据，未重复读取源或副本磁盘。

## 容器格式对照与原因范围

container-format/comparison.json 的两份 IMG4 摘要匹配先前提交读回。对照记录支持：

| 对象 | 基线 | 安装后第七版 | 结果 |
| --- | --- | --- | --- |
| description | KernelManagement_host-487.0.4 | kernelcache | 缩短 18 字节 |
| IM4P 额外子元素 | 315 字节 PAYP | 无 | 原元素缺失 |
| IMG4 文件大小 | 43,997,230 字节 | 43,996,897 字节 | 减少 333 字节 |
| payload octet／解码 payload | SHA d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb | 相同 | 内容保持 |
| 压缩类型 | NONE | NONE | 保持 |
| IMG4 尾部 | 原始 IM4M；无 IM4R | 相同 | 原始字节保持 |

18 + 315 与总尺寸减少 333 字节一致。以上为实际容器差异。没有对照启动实验建立这些差异与本次 guest 未连接的因果关系；启动异常原因未查明。不能将 PAYP 缺失写为已确认启动失败原因，也不能由相同 payload 推定容器变更不影响启动。

本次源、目标 payload 相同。即使后续补充成功启动证据，也不能由本次发布证明不同 payload 的更新后启动。已提交且启动后的 kernel-only 回退入口尚未实现；此前发布后未提交事务恢复不替代该项验收。本次审查不要求立即补实现回退。

## AMFI 清理尚未完成

post-boot-v7-processes.log 保存观察仍包含本次 driver PID 89299、debugserver PID 89316 及被附加 amfid PID 88460。amfi-cleanup-review-rejection.json 记录 driver 已发送 SIGINT，但清理未完成，LLDB Continue 阻塞。不能报告本次临时 AMFI 进程已经清理。

自动批准审查拒绝 `sudo -n /bin/kill -STOP 88460`，executed=false。保存理由为：停止系统 amfid 会暂时中断核心代码签名服务并扩大副作用，缺少可信用户对该精确系统进程操作的授权。记录中 user_approval_requested=true、user_approval_received=false。该动作没有执行；精确用户批准仍待回复。审查者未尝试替代信号、调试命令或其他清理绕过。

后续须在已有授权及必要的精确批准范围内完成安全 detach/清理，保存 driver/debugserver 退出和系统服务状态。正常启动、不同 payload 场景及提交后回退仍分别缺少验收结果；这些缺口不否定已确认的离线发布、提交和未提交恢复证据。

## 审查输入摘要

| 文件 | SHA-256 |
| --- | --- |
| vm-boot-v4-kernel-v7.json | `d38f593493892251c41a3a2d435b612dd7af54acf69a01e8997a598b59a364f2` |
| vm-boot-v4-kernel-v7.log | `003522bfb36ecdd9c6504608a71a6b6d80d9850e8455d224194f60ce1f766ef4` |
| vm-boot-v4-kernel-v7-summary.json | `84d6cf8d2902ea7d6a296e944001c1f3cb884fd5b3980a34a82c8f773268bd4e` |
| guest-capabilities-v4-kernel-v7.log | `9a4741da0dc658cec6f31ca6ce96bf5558271e366022ea6bc65cbf5f436f5880` |
| guest-shell-v4-kernel-v7.log | `a38b8184d34089657128089cc0a181fbb8d153ddf8130ec5efae89559cda1818` |
| vm-stop-v4-kernel-v7.json | `c82d0351eeaededaac4730c61ded043e11cc3308ac0b06e0dca1944e98d56934` |
| vm-stop-v4-kernel-v7.log | `69fc4e09dfaa7157ec5460151a247967c610d05c94cc329adaa4c732d1c96e78` |
| post-boot-v7-readback.json | `4ff3a81c34db6f696a28a6be251b3e3ae6656edf3162f687a2dd382f24b04e2e` |
| post-boot-v7-attachments.plist | `0b053dcbc0b1999bbae1470cd73d1463bf6e16de55f80cc87f2a0822ffd75deb` |
| post-boot-v7-processes.log | `0f5d0f9529b3dd63c49d3b13e4ae181d9848198f798b4e4c4eca4a1da24de44b` |
| container-format/comparison.json | `a6af4cf008b56d27a418664067a82953de1712db61b1325522662ddb3c554d15` |
| container-format/diagnosis.md | `f0c83d23379e7d98f402c9ad4f1568a010e9df48d6cda576ee66a456a40ad60f` |
| amfi-cleanup-review-rejection.json | `c769316f2bbf338b9206273f9483e532108ed69c3aa1c95fa5fcb5fd731fa8cc` |
