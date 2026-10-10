# T08 后续开发位置（2026-10-11）

- 代码 worktree：`/Users/kolar/.codex/worktrees/t08-roothide/vphone-cli`
- 开发分支：`codex/upstream-2d21d21-integration`
- 本轮实现与证据提交：`c94b6167`
- 主 checkout：`/Users/kolar/github/vphone-cli`，分支 `codex/handoff-20261001`
- 固定运行工件：主 checkout 的 `.build/research-b35/source/.build`，核对 B35 signed-artifacts.json 与 vm-validation-plan.md。
- 研究 VM：主 checkout 的 `vm-roothide-b33-20261010`，当前停机；源 `vm-new` 和原健康监测已恢复 healthy。

所有后续开发、构建脚本修改及研究记录更新在代码 worktree 进行。历史脚本以 parents 推导原 checkout；在新 worktree 运行之前必须显式区分代码根、冻结工件根与 VM 路径，不能直接复用推导路径。运行工件未迁移，未创建 VM 的重复副本。

继续项：完整现代环境迁移、RootHide 冷启动自动激活、默认构建与实际运行来源一致性和 T08 整体验收。受控场景 180° 未旋转原因及因果验证见 B34；B35 已通过相关 22 项回归。B36 未启动研究 VM，没有新增运行验收。磁盘余量低于 5 GiB 时停止。
