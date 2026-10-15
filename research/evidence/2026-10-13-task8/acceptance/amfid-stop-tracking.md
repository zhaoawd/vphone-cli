# Task 8 amfid 停止问题

原因未查明。B 的固定第四版临时驱动记录了删除断点、Detach(False)、Destroy 和正常退出，但当时同一 amfid95240 的实际状态仍为 SSTOP。严格核对 PID、路径、UID、PPID、开始时间及非 traced 后，仅 SIGCONT 恢复；随后原 preflight 和启动继续。证据为 `kernel-v9-plan-b-amfi-resume-check.json`。不能将驱动退出 0 视为 daemon 已恢复运行。

回退 A 后，外部核对同一 amfid 为运行状态，未发送恢复信号，见 `kernel-v9-rollback-a-amfi-restore-check.json`。

本轮 Documents 停机重启前，实际 amfid69981 为 SRUN、非 traced；固定第四版 VM 的 preflight 退出 0，未启动临时驱动、未发送 amfid 信号。见 `kernel-v9-documents-reboot-a-pre-boot-check.json`。

本轮跨回退 B 启动前，实际 amfid92569 为 SRUN、非 traced；固定第四版 VM 的 preflight 退出 0。见 `kernel-v9-documents-rollback-b-pre-boot-check.json`。本轮两次启动均未运行临时 AMFI 驱动、未发送 amfid 信号。两次观察的 PID 不同，未调查其变化原因，不能据此确定历史停止原因。

授权范围保持：固定第四版 VM CDHash `43c00d51b4c7f07a5feba006f3c244edbac39cea`、既有两个 hook、allow_all=false；只在必要时使用已冻结 F99 once 驱动。外部恢复工具仅在该驱动完整清理证据与同一 daemon 身份匹配时允许 SIGCONT，不请求新暂停、服务终止或新 CDHash。第九版 VM 不执行或放行。旧 PID88460 的一次暂停授权不扩用到其他 PID。

本问题不与内核发布耗时或数据标记丢失合并归因。
