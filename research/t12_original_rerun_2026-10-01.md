# T12：原件与检查点重跑（差异审查与迁入）

日期：2026-10-01。分支 `worktree-agent-af9fc022239a81f91`，基线 `6c7cb3f`。
上游参考 tag `upstream-2.2.3`，基线 `upstream-2.0.8`。本文分开陈述事实、推断和未验证项。标识符、命令和字段名保留原文。

## 1. 来源

| 提交 | 内容 | 上游路径 |
| --- | --- | --- |
| `5b0b16d` | 新增 `FirmwarePipelineOriginals.swift`（存档位置、`pristineInput`、`restorePristine`、`discardStash`、`staleFirmwareError`）和 `ComponentDescriptor.restorable` | `VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Pipeline/` |
| `a3d2382e` | `patchComponents` 从存档重打补丁；选择为空时恢复未补丁镜像；Filesystem/Manifest 和 `.less` 不参与；`fw prepare` 删除旧存档；精简导出排除存档 | 同上，及 `VPhoneFirmwarePreparer.swift`、`VPhoneBundleTransfer.swift`、`VPhoneBundleOperations.swift` |

检索方式：`git log upstream-2.0.8..upstream-2.2.3`（124 个提交）按 `FirmwarePipelineOriginals`、`FirmwarePipeline.swift`、`VPhoneFirmwarePreparer.swift`、`PatchSelection`、`VPhoneBundleOperations.swift` 路径及 original/pristine/stash/selection 关键词筛选。与原件保存和重打补丁直接相关的只有上述两个提交。`30c8512`（声明与 preset）和 `ae5e453`（补丁 ID 命名）属 T09/T10 范围。上游没有 `vm create` 检查点或续跑。

上游的补丁选择来自 `<vm>/PatchSelection.plist`（`fw set-patches`）。本地没有该文件；本地选择由 T10/T11 已解析计划决定：变体、门控快照、启用的声明集合（`VariantPlanResolver.resolve`）。

## 2. 对照表

位置为本地文件:行号（基于本次提交后的工作树）。

| 上游行为 | 本地 | 结论 |
| --- | --- | --- |
| 原件位置：首次 `fw patch` 写入前把每个组件复制到 `<vm>/FirmwareOriginals/<相对路径>` | 每次 patch 以 C4 事务暂存输入根（`FirmwareTransaction.swift:47-82`，根由 `FirmwarePipeline.swift:270-276` 给出：VM 根组件文件和整个 Restore 目录）。提交时补丁前的输入移到事务的 `backup/`（`FirmwareTransaction.swift:129-133`），事务目录归档为 `.firmware-history/<id>/`（`:199-209`）。create 的再生成来源是 IPSW：native prepare 重新解包（`VPhoneNativeFirmwarePreparer.swift:28`、`:116-148`），script prepare 删除旧树后从提取缓存克隆（`scripts/fw_prepare.sh:398-415`、`:652-670`） | 本地有意不同 |
| 原件身份：只按文件存在判断；首次运行无法确认存档未打过补丁 | 事务 journal 记录每个输入根的内容 SHA-256（`FirmwareTransaction.swift:60`），暂存后和提交前复核（`:78`、`:120`）。native prepare 在提取前后核对源 IPSW 的 dev/inode/长度/mtime/ctime（`VPhoneNativeFirmwarePreparer.swift:182-190`）。create 用 `tree_metadata` 指纹核对 Restore 树（`VPhoneCreateCheckpoint.swift:546-551`），该指纹不读内容。script prepare 的提取缓存只按目录非空复用（`fw_prepare.sh:400-401`），不核对内容 | 本地有意不同 |
| 重跑 `fw patch` 从存档重打，结果与单次运行相同 | 独立 `fw patch` 每次从当前树开始。对已补丁树重跑时，必需补丁位点缺失，组件失败，事务记录失败并不提交（`FirmwarePipeline.swift:246-249`、`:402-406`），`.firmware-transaction` 保留，需要 `--recover`。该结论来自代码阅读，未用真实固件运行 | 缺失，未迁入（见 §5） |
| 选择变化（选项层：变体、frida）后重新生成 | `variant`、`enable_frida` 映射到 patch 阶段（`VPhoneCreateCheckpoint.swift:142-153`）。patch 已完成时普通续跑拒绝（`VPhoneCreateRunner.swift:321-331`）。`--restart-from patch` 因 `restore_tree`/`avpbooter` 指纹与 prepare 记录不一致被拒绝（`VPhoneCreateRunner.swift:384-400`；patch 不声明重写产物，`VPhoneCreateLiveStages.swift:150-160`）。`--restart-from prepare` 重新提取未补丁输入，再打一次补丁 | 已等价（机制不同）；本次补回归测试 |
| 选择变化（工具层：同一选项下新构建解析出不同计划） | 原状态：`--accept-tool-change` 后跳过的 patch 只核对事务已提交与变体（`VPhoneCreateLiveStages.swift:200-218`），不核对选择 | 缺失，本次迁入（§3） |
| 选择为空时恢复未补丁镜像 | 本地没有逐组件选择入口（无 `PatchSelection.plist`），选择随变体整体变化。回到未补丁输入只能重新 prepare | 不适用 |
| 未补丁组件不重写，保留 restore 的 mtime | 事务只发布 `original != output` 的根（`FirmwareTransaction.swift:129`）；粒度是整个 Restore 树或 AVPBooter，不是组件 | 部分等价 |
| Filesystem、Manifest 不复原；`.less` 不参与复原 | 本地不复原单个组件，less 与其他变体同一事务流程 | 不适用 |
| 旧版本打过补丁的 VM：存档首次失败时删除，提示删除 Restore 树后重新 `fw prepare` | create：`--restart-from patch` 的拒绝提示建议 `--restart-from prepare`（`VPhoneCreateOrchestrator.swift:460-465`）。原 patch 校验失败提示建议 `--restart-from patch`，该命令必然因树指纹被拒绝；本次改为 prepare（`VPhoneCreateOrchestrator.swift:485-491`）。独立 `fw patch` 的失败信息不含重新 prepare 的指引 | create 部分已修正；独立入口未改 |
| `fw prepare` 删除旧存档（AVPBooter 文件名不含版本） | 本地无存档目录。prepare 前 `refreshBootROM` 从资源复制原始 ROM（`VPhoneCreateOrchestrator.swift:606-620`）。独立 native prepare 遇到已有 Restore 路径拒绝；检查点重跑把旧树移入 `.firmware-prepare-backup-*`（`VPhoneNativeFirmwarePreparer.swift:116-148`） | 已等价（create 路径） |
| 精简导出排除存档 | 未带 IPSW 的导出排除 `*_Restore*`（`VPhoneBundleOps.swift:315-316`、`:330`、`:357-359`）。`fnmatch` flags 为 0 时 `*` 匹配 `/`，因此 `.firmware-history/<id>/backup/<…_Restore>` 和 `.firmware-prepare-backup-*/<…_Restore>` 在 native 写入器与进度统计中也被排除（推断）。tar `--exclude` 的对应行为未测。`backup/AVPBooter*.bin` 不被排除 | 部分等价（推断） |
| 失败与取消后的恢复 | patch 失败留下 `.firmware-transaction` 时记为 `recovery_required`（`VPhoneCreateRunner.swift:545-546`、`:631-645`），`fw patch --recover` 回滚后续跑从未补丁树开始。prepare 失败或取消清理暂存，续跑重新提取 | 已等价（机制不同） |
| 旧检查点兼容 | 新增 evidence 键为可选；缺失时不比较。`schema_version`、`stage_contract_version` 不变 | 本次保持 |
| retain_until 与清理范围 | `restore_tree` 保留到 patch、restore、cfw、first_boot、verification（`VPhoneCreateLiveStages.swift:16`）。默认清理只删除当前 Restore 树（`VPhoneRestoreInfo.swift:98-104`）。`.firmware-history`、`.firmware-prepare-backup-*` 不在自动清理范围 | 未改 |

## 3. 改动

1. `sources/vphone-cli/VPhoneCreateLiveStages.swift`
   - 新增 `VPhoneCreatePatchSelection`。选择身份为下列文本的 SHA-256：`vphone-patch-selection-v1`、变体、门控快照（`PatchGateSnapshot` 排序键 JSON）、`selected` 声明 ID、`enabledSteps`。计划由 `VariantPlanResolver.resolve` 解析，不另建清单。
   - 变体与门控从事务归档的 `report.json` 读取。该文件由流水线在提交前写入（`FirmwarePipeline.swift:245`）。
   - patch 执行器在恰有一个新归档时写入 evidence `patch_selection_sha256`。解析失败时抛错，阶段记为失败。
   - patch 验证器在 evidence 含该键时，用当前构建重新解析同一归档的变体和门控；不一致则拒绝，原因含 `patch selection changed since the patch stage ran`。`report.json` 不可读时拒绝。evidence 不含该键（T12 之前写入）时不比较。
   - 新增可注入字段 `patchSelectionDigest`，默认 `VPhoneCreatePatchSelection.digest`，供测试模拟不同构建。
2. `sources/vphone-cli/VPhoneCreateOrchestrator.swift`：`verificationFailed(stage: .patch)` 的提示改为 `--restart-from prepare`；其他阶段不变。
3. 测试：`tests/VPhoneCLITests/CreateLiveStagesTests.swift` 新增 3 项，`tests/VPhoneCLITests/NativeFirmwarePrepareTests.swift` 新增 2 项。

未改动：FirmwarePatcher 的补丁匹配、写入字节、事务与记录入口；默认 prepare 后端（`script`）、默认变体（`regular`）；检查点格式；清理范围。没有新增或修改二进制补丁，因此未更新 `research/0_binary_patch_comparison.md`。

## 4. 测试与结果

新增测试：

| 测试 | 内容 |
| --- | --- |
| `CreateLiveStagesTests.patchSelectionIdentityFollowsTheResolvedPlan` | 同一输入摘要相同；变体、iOS 27 门控、frida 各自改变摘要；文本含已解析计划的声明与步骤集合；未知变体抛错 |
| `CreateLiveStagesTests.patchVerifierRejectsAChangedSelectionAndKeepsHistoricalEvidence` | 摘要一致时通过；注入不同解析结果时拒绝；无该键的历史 evidence 通过；有该键但 `report.json` 缺失时拒绝 |
| `CreateLiveStagesTests.patchVerificationRefusalPointsToPrepareNotPatch` | patch 校验失败提示 `--restart-from prepare`，不含 `--restart-from patch`；cfw 提示不变 |
| `NativeFirmwarePrepareTests.selectionChangeRegeneratesFromOriginalsInsteadOfPatchingTwice` | 真实 native prepare（合成 IPSW）加合成 patch（仅对未补丁字节生效，按事务方式以新 inode 发布并写入已提交归档）。regular 完成 patch 后改为 jb：普通续跑和 `--restart-from patch` 均拒绝，检查点字节和补丁内容不变；`--restart-from prepare` 后内容为单次 jb 补丁结果，旧树在 `.firmware-prepare-backup-*`；整棵 Restore 树逐文件 SHA-256 与另一个直接以 jb 创建的 bundle 相同 |
| `NativeFirmwarePrepareTests.acceptedToolChangeWithAnotherSelectionRequiresRegeneration` | 接受工具变化后，若新构建解析出不同选择，续跑以 `verificationFailed(stage: .patch)` 拒绝，检查点字节不变；选择相同时继续并记录 `verify.patch = verified`；`--restart-from prepare` 后 patch 记录新摘要 |

`selectionChange…` 覆盖的是已存在的本地行为，作为 T12 验收条件“补丁选择变化从原件重新生成”的回归资产。`acceptedToolChange…` 和 `patchVerifierRejects…` 覆盖本次迁入的行为。

命令与实际结果（swift 命令的环境与 `scripts/run_tests.py` 相同：`--disable-sandbox --cache-path .build/test-cache`，`CLANG_MODULE_CACHE_PATH`/`SWIFT_MODULECACHE_PATH=.build/test-module-cache`，清除 `VPHONE_TEST_*`）：

| 命令 | 结果 |
| --- | --- |
| 改动前 `swift test --filter "CreateCheckpointTests\|PrepareBackendCheckpointTests\|CreateLiveStagesTests\|NativeFirmwarePrepareTests"` | 退出 0；`52 tests in 2 suites passed`；`38 tests in 2 suites passed` |
| 改动后同一命令（首次） | 退出 1；测试编译错误：`.verificationFailed` 未限定类型（`CreateLiveStagesTests.swift:245`、`:250`）。改为 `VPhoneCreateRunError.verificationFailed` |
| 改动后同一命令（复跑） | 退出 0；`52 tests in 2 suites passed`；`43 tests in 2 suites passed`；新增 5 项均通过，无失败 |
| 对照：临时把验证器比较改为不执行，运行 `swift test --filter "patchVerifierRejectsAChangedSelectionAndKeepsHistoricalEvidence\|acceptedToolChangeWithAnotherSelectionRequiresRegeneration"` | 退出 1；两项均失败。后者在续跑中进入 restore 阶段（`stage restore failed`），即旧选择的固件被接受。随后恢复比较代码 |
| `python3 scripts/run_tests.py swift`（`make test_swift` 的命令体） | 退出 0。Swift Testing 10 次运行：37/5、75/7、13/2、9/2、330/37、83/17、18/1、37/5、28/4、176/31（测试/suite），共 806 项、111 suites，全部通过；XCTest 4 个包 82、72、24、5 项，3 项跳过，0 失败；`check_tar_pipe_memory` 两条 1 GiB 路径峰值 RSS 7,847,936 / 7,979,008 字节；`test_guest_components` `124 checks, 0 failures` |

环境说明：本 worktree 内直接调用 `make` 被会话的工作树隔离检查拒绝，因此以 `make test_swift` 的命令体 `python3 scripts/run_tests.py swift` 运行。worktree 准备沿用 T08：`.venv` 链接到主仓库，初始化 `vendor/*` 子模块，生成被忽略的 `sources/vphone-cli/VPhoneBuildInfo.swift`。

## 5. 事实、推断与未验证

事实：

- 本地 create 在 patch 已提交后，任何补丁选择变化（选项层）都不能在已补丁树上重跑 patch；只有 `--restart-from prepare` 被接受，且结果与从未补丁输入单次生成一致（合成输入测试）。
- 本次之前，接受工具变化后跳过的 patch 阶段不比较补丁选择。本次之后，T12 起写入的 patch evidence 会在续跑时比较。
- 补丁前的输入树保留在 `.firmware-history/<id>/backup/`，journal 记录其内容摘要（`FirmwareTransactionTests.stagedWritesDoNotAlterOriginalAndCommitPublishesAllFiles` 断言了 AVPBooter 的备份内容）。

推断：

- 独立 `fw patch` 对已补丁树重跑会因必需位点缺失而失败且不提交。依据是 `FirmwarePipeline.swift` 的失败分支和补丁器“已补丁字节无位点”的行为；未用真实固件运行。
- 精简导出通过 `*_Restore*` 同时排除了历史与 prepare 备份中的 Restore 树（native 写入器）；tar 路径未测。

未验证（需要真实 IPSW、真实恢复或 VM）：

- 真实固件上 patch 执行器写入的 `patch_selection_sha256` 与验证器复算一致。单测使用合成 `report.json`；真实流水线写出的 `report.json` 的解码未在真实运行中验证（`PatchRunReport` 编码与 `ReportHeader` 解码字段相同，属推断）。
- 真实 26.1 组件上 `--restart-from prepare` 后的 patch、restore、cfw、first_boot、verification。
- 独立 `fw patch` 重跑的实际错误信息与事务残留。

## 6. 未覆盖范围与待决问题

- 独立 `fw patch` 不可重跑（上游 a3d2382e 的主要场景）。迁入需让事务从保留的原件暂存，或新增存档目录，均需修改 FirmwarePatcher 事务入口，并决定存档的身份（例如以 journal 的输入摘要为准）、空间和清理规则。本次未做，待决定是否需要。
- 独立 `fw patch` 失败信息不提示“删除 Restore 树后重新 prepare”。
- `.firmware-history/<id>/backup/` 保存每次 patch 前的整棵 Restore 树，`.firmware-prepare-backup-*` 保存检查点重跑前的旧树。两者都不在自动清理范围，重复 patch 或重跑会持续占用空间。是否需要清理策略待定。
- 选择身份只覆盖 Swift 写入的组件；guest 侧 `guestStep` 声明（Python/zsh）不在 T11 写入门内，也不在本身份内。
- script prepare 的提取缓存按名称复用，不核对内容。
- 未执行 `make test_python`、`make test_firmware`（无夹具）；未操作 VM，未安装 helper。
