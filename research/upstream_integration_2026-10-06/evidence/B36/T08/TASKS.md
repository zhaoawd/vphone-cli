# B36：T08 运行准备与 worktree 交接

## 已完成

- 用户批准单 CDHash 临时 AMFI；新宿主 --help 退出 0。
- CFW 只读分类为 full_migration_required，冷态恢复副本准备完成。
- 研究 VM 未启动、未部署新候选。
- 临时辅助进程结束，独立核对 amfid 归属 PID 1；正常 detach 未验证。
- 源 VM 原命令恢复、客户机往返和原健康监测 healthy 验证通过。
- 记录失败与限制；5 GiB 阈值未触发。

## 进行中

- 在 codex/upstream-2d21d21-integration 提交全部当前改动。
- 主 checkout 切回 codex/handoff-20261001，创建独立 worktree。

## 待办

- 后续开发仅在独立 worktree 进行，复核固定运行工件路径与摘要。
- 完整现代环境迁移及 RootHide 冷启动自动激活验收。
- 默认构建产物、运行来源一致性和 T08 整体验收。
