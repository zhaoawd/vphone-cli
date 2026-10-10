# B36：运行准备与收尾（2026-10-11）

用户已批准冻结 VM 工件 CDHash `62026af109b33fdd468c2c2df2fcdb4211136bf0` 的临时 AMFI 放行，范围为 paths=[]、allow_all=false、spoof_apple=true，结束后清理。原 vm-new 维护授权持续有效。

新宿主 `--help` 退出 0，输出为空；本轮研究 VM 未启动，未部署现代候选，未验证真实 RootHide 自动激活。研究副本 CFW 只读检查退出 0，分类为 `full_migration_required`：launchd 加载 `/b`，缺少 `/vh` 和五项现代库。检查记录磁盘采样及元数据保持，挂载随后释放。冷态 APFS 克隆恢复副本已准备。完整现代迁移仍待开发，不能用单项库替换完成此迁移。

源 VM 正常停止后，自动审批因额度限制未执行后续核对，研究启动没有继续。额度恢复后完成收尾。临时驱动收到 SIGINT、SIGTERM 后仍运行；结束本轮驱动采用 SIGKILL。监管进程记录退出 -9，debugserver 随后退出；独立核对确认三项本轮辅助 PID 均不存在，同一 amfid 归属 PID 1 且无 traced 状态。正常 detach 未验证。清理脚本首次结束核对遇到退出过程身份断言失败，原始错误保留；脚本增加 zombie 状态判断，未将脚本异常视为清理成功证据。

源 VM 按原启动命令恢复，三个连续 app_list 客户机往返通过。身份核对后恢复原健康监测 PID 21157，新的健康记录为 healthy，UDS/vsock 均 healthy。研究副本磁盘无打开句柄。未修改持久安全设置。记录最低余量 287191146496 字节，5 GiB 阈值未触发；监管时限触发后驱动未响应 SIGINT，实际结束用时约 9164 秒，不能宣称两小时内自动清理成功。

用户要求将改动提交到独立分支，主 checkout 切回 codex/handoff-20261001，后续开发使用独立 worktree。提交范围包括 B33–B36 证据、RootHide 启动恢复修改和相关测试。B35 相关 22 项测试已通过；本轮没有新增产品修改。T08 180°原因已由 B34 确认，剩余完整现代迁移、自动激活及默认产物整体验收尚未完成。

证据：cfw-eligibility.json、vm-help.json、amfi-cleanup-first-failure.json、amfi-cleanup-post-kill-race.log、amfi-cleanup-independent.json、source-restoration.json。冻结构建及 API 仍位于主 checkout 的忽略目录 .build/research-b35；移动代码 worktree 不自动迁移运行工件。继续实验前须重新核对工件路径与摘要，并确保源和同身份副本不同时启动。
