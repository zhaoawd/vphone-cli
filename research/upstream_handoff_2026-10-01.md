# 上游 2.2.3 整合交接（2026-10-01）

分支 `codex/upstream-4bab3b7-integration`，交接时 origin HEAD 为 `edeaa7f`。固定上游目标 `2.2.3 / a969cd5d`（本地 tag `upstream-2.2.3`，基线 `upstream-2.0.8`）。执行清单见 [upstream_execution_tasks_2026-10-01.md](upstream_execution_tasks_2026-10-01.md)，实施计划见 [upstream_implementation_plan.md](upstream_implementation_plan.md)。

## 1. 已完成（均已推送，每项有 `research/tXX_*` 记录）

T00–T13a、T14 A 部分与缓存认领、T15、T16（含提权只读检查）、T17（代码；真实验收第一段未完成）、T20、T24、T25、T26 B1–B6、T27；B2 与 B4/T15 真实验收；T03 备份与恢复启动。v2 客户机环境设计与用户决定 D1–D5 见 [v2_guest_environment_design_2026-10-01.md](v2_guest_environment_design_2026-10-01.md) 第 12 节。

## 2. 执行顺序

每一步：读对应记录与设计章节 → 在独立分支或 worktree 实施 → 先写能复现问题的测试并确认修改前失败 → 实施 → 运行验证命令 → 写研究记录（中文、事实/推断/未验证分开）→ 单独提交。

| 序号 | 任务 | 依赖 | 依据 | 验证 |
| --- | --- | --- | --- | --- |
| 1 | 小修复：`cfw update-environment --check` 的进度文字改到 stderr，stdout 只输出 JSON | 无 | t16 记录第 10 节 | `make test_python`、相关 Swift 测试 |
| 2 | 小修复：`vm clone` 排除 `.cfw-history`（`vm_backup.sh` 保留） | 无 | t15 记录"需要你决定"第 2 项；本交接第 4 节 | `swift test --filter BundleOps`、`make test_swift` |
| 3 | v2 环境 B1：记录与判定（含修正 T16 `variant_records` 读取层级） | 无 | v2 设计第 3.4、7.1、9 节表格 B1 行 | `make test_python`、`make test_swift`；历史检查点摘要不变；`fw plan` 输出 environment 声明 |
| 4 | v2 环境 B2：API 守护进程并行身份 | 3 | v2 设计第 4.2 节、第 9 节 B2 行 | `make daemon_api_build`、一致性测试 |
| 5 | v2 环境 B3：离线安装器（合成目录树测试） | 3、4 | v2 设计第 3、7.1 节、第 9 节 B3 行；同步 `0_binary_patch_comparison.md` | 合成树成功/拒绝/失败断言；后置判定 `already_current` |
| 6 | v2 环境 B4：驱动接入 | 5 | 第 9 节 B4 行；T15 事务 | `test_cfw_disk_transaction`、`test_cfw_host_isolation` |
| 7 | v2 环境 B5：create/cfw 入口、evidence 与校验 | 6 | 第 9 节 B5 行；`--guest-environment classic|v2`，默认 classic，首批只开放 regular | `make test_swift`、`make test_python`、签名构建 |
| 8 | v2 真实验收 R1–R9（需用户授权；R4 决定 D6） | 7 | 第 8 节 | 见设计第 8 节；记录到设计文档 |
| 9 | T16 停机替换与 T17 在线更新的成功路径真实验收（在 v2 VM 副本上） | 8 | t16 第 9–10 节、t17 第 6、9 节 | 记录到对应文档 |
| 10 | v2 环境 B6（迁移命令，仅在自建克隆上）、B7（开放 dev） | 8 | 第 9 节 | 同上 |
| 11 | T18、T19 | 8；用户先确认范围 | 清单 T18/T19；T13b 已并入 T18 | 需单独设计 |
| 12 | T21、T22、T23 | 15、17、18 等 | 清单对应段 | — |
| 13 | T14 B 部分（GPU/v2 布局） | 用户决定（推迟到 T17–T19 后） | t14 第 10 节 | — |
| 14 | T28–T31（文档、发布、回归、恢复演练；含 T30 备份清理命令） | 前述交付范围 | 清单对应段 | 全量 `make test`、`make test_firmware`（夹具齐备时） |

## 3. 宿主与环境约束

- 用户在用的 VM：`vm-2607`、`vm-new`，以 `--config` 从主树 `.build/vphone-cli.app` 运行，不在库中。不对其执行命令或发信号。不要在主仓库目录运行 `make build`；签名构建在独立 worktree 内进行（其 `.build` 独立）。
- 保留的测试 VM：`~/vphone-b4-accept/lp-b4-accept2`（regular，classic，T15 已安装）；`~/.vphone/VMs/rig-baseline`（exp，用户基线，只用 APFS 克隆）。完整备份：`~/.vphone/backups/rig-baseline-2026-10-01/`；恢复映像 `~/.vphone/backups/t03-restorecheck.sparsebundle`。
- amfidont 会随 `amfid` 重启退出，真实 VM 步骤前检查 `pgrep -fl amfidont`；由用户运行 `zsh scripts/start_amfidont_for_vphone.sh` 启动（需要密码）。
- regular 客户机没有 shell，经典守护进程不声明 `shell`；exp/jb 的 shell 为 `/var/jb/bin/sh`，需设置 PATH。
- 从运行中的客户机 shell 热加载 launchd 任务失败（`Service cannot load in requested session`），且该类操作被宿主自动权限检查拒绝；v2 设计已改为随环境安装。
- IPSW 缓存：`~/.vphone/ipsws` 现有 4 个条目没有完成标记；用户可用 `vphone-cli fw cache adopt`（命令见 t14 记录第 12 节）认领，否则下次 prepare 会重新获取。
- 子代理或自动化不得发送合成键鼠事件（曾误点用户窗口）。
- 测试运行器：`make test_python`、`make test_swift`；固件对比需要夹具（当前缺失）。

## 4. 待用户决定或已知问题

- D6（v2 在 regular 内核上不可用时的方案）待 R4 结果。
- T15：`vm clone` 排除 `.cfw-history` 已决定未实现（第 2 步）；`.firmware-history`/`.cfw-history`/`.firmware-prepare-backup-*` 清理命令归 T30。
- 并行测试竞态：`ExtractPermissionsTests` 偶发失败，原因未查明（t14 记录）。
- `test_interrupt_keeps_original_and_removes_copy` 曾超时一次，未复现（t16 记录）。
- T17 第一段验收未完成，前提改为 v2 VM（t17 记录第 9 节）。
- 中文字符串 129 条 `needs_review`（Launchpad）。
- T13b 与 T18 涉及 MIS 相关补丁，此前派发曾被安全分类器拦截；开始前先与用户确认范围。
