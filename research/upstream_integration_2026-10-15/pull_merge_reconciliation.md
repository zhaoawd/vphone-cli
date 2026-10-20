# 拉取与本地修改合并（2026-10-15）

原分支 `codex/upstream-2d21d21-integration` 位于 `2df4be8c`，本地未提交修改阻止拉取。已保存完整工作区和未跟踪文件至 stash `1c6f0b45ce903c4276d4ff83dc1d24c47647ff08`，执行 `git pull --ff-only` 到 `fcd19e78`，再恢复本地修改。Capstone overlay 保留。

八个文本冲突已解决。Swift 本地修改及原有证据文件保留；研究台账保留两侧记录和未完成范围。当前修改仍未提交，备份 stash 未删除。

## 合并结果

- 远端 journal v2 要求 Undo 来源证明；本地原 v2 要求最终磁盘检查点。为保持两组要求，合并后的完整安装采用 journal v3；环境更新保留远端 v2，旧 v1 只允许原有恢复流程。
- final reader 保留来源索引重建、来源重验及状态复查，增加本地事务 ID；最终报告使用本地原子持久化后继续执行远端 journal 绑定。
- 完整安装在快照修改后重新只读核验，卸载后封存最终磁盘摘要。检查点同时绑定 Undo 索引、最终报告及 journal 的 Undo 摘要，发布和恢复均核对。
- 发布前先核对远端来源证明，再核对本地检查点；两组检查结束后继续复查磁盘身份和持有者。未取消 IOMFB 生产迁移门控。
- 测试夹具保留远端旧版本拒绝和本地检查点行为；新增缺检查点拒绝、发布后 Undo 索引变化拒绝、移除检查点要求或降级 journal 拒绝。

## 验证

最终协议的 Python 定向测试 82 项通过。Swift 相关测试 27 项通过（Receipt、Undo、CLI、恢复锁）；命令为 `swift test --disable-sandbox --cache-path .build/test-cache --filter 'FirmwareLegacyReceiptTests|PatchUndoLogTests|FirmwareComponentUndoTests|FWReceiptsCLITests|FirmwareRecoveryLockTests'`。

`zsh -n scripts/cfw_install_host.sh`、Python runtime preflight 和 `git diff --check` 通过。与备份逐文件核对：没有原文件缺失，31 个原文件内容一致，其余为已核对的合并文件。远端无需合并的 148 个文件均与 `fcd19e78` 一致。

`make test_python` 最终执行 857 项，跳过 2 项，239.028 秒，退出 0。协议调整期间的两次全量已主动中断，不作为最终证据。最终日志为 `.build/pull-merge-python-final.log`；定向日志为 `.build/pull-merge-python-focused-v3.log` 和 `.build/pull-merge-swift-focused.log`。最终运行涉及的 32 个变更源码/测试文件摘要前后一致，见 `.build/pull-merge-source-manifest.json`。

未运行完整 Swift 入口、真实固件比较、真实 APFS/Preboot 或 VM 验收。本次没有发布、推送或操作实际 VM。
