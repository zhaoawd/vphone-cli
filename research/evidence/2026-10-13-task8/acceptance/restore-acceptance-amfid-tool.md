# Task 8 固定 V4 驱动后的 amfid 状态核验

本工具仅用于已授权固定 F99 驱动成功完成后的清理。原驱动、runtime 和 V4 CDHash 保持。工具先核验驱动摘要、退出码 0、原始日志的单一 READY PID、两个匹配钩子返回 1、断点删除及 Detach(False)/CLEANUP_DONE，再用 libproc 读取该 PID 的实际身份与 BSD 状态。已运行则不发信号；仅当同一 `/usr/libexec/amfid`、UID 0、PPID 1、开始时间不晚于该日志创建时间、非 traced、SSTOP 且 xstatus=SIGSTOP 时，发送一次 SIGCONT 并核验同一身份恢复 SRUN。证据变化、PID 消失或复用、traced、状态异常均拒绝，不发送新的暂停或重试信号。

驱动日志成功不能证明 daemon 实际恢复；B 的实际记录已出现该区别。Detach 后仍停止的具体原因未查明。工具没有 LLDB API，不附加，不删除服务，不修改持久配置，不增加放行摘要。

实现使用 `proc_bsdinfo.pbi_flags` 的 `PROC_FLAG_TRACED=2`，依据本机 SDK `sys/proc_info.h:104`；不能使用 `sys/proc.h` 的内部 `P_TRACED=0x800`。初稿混用了两个常量，root 在实际使用前修正。独立 literal 2 负例覆盖 native 读取、动作前及动作后状态；将 helper 常量在纯 mock 中改回旧值会产生 3 个预期失败。原初稿测试日志保留。

12 项纯模拟测试通过，覆盖运行不发信号、同一停止 daemon 仅一次 CONT、证据/作用域/日志/身份/trace/竞态拒绝、信号失败、恢复超时和排他输出。原驱动模拟 Detach 成功但 BSD 仍停止的 RED 保留。测试仅使用模拟进程 API 与普通临时文件；没有观察或操作真实 PID。当前尚未实际执行本工具，第三次启动是否需要使用由实际 V4 预检决定。
