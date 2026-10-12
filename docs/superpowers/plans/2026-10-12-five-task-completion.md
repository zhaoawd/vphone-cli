# Five Task Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完成 T24、T40、T09、T10、T11 的原接受条件，包括必要依赖、故障恢复、构建及真实验收。

**Architecture:** 复用现有声明、FirmwareTransaction、VM manifest、create checkpoint 和 launchpad.json。先补齐固定声明与执行证据，再接入稳定身份、generation、desired plan 和分组件 receipt，最终验证宿主责任链和四层来源。

**Tech Stack:** macOS 15+、Swift 6、SwiftPM、Python 项目 `.venv`、zsh、现有固件 fixture。

**Spec:** `docs/superpowers/specs/2026-10-12-five-task-completion-design.md`

**Status:** 用户已批准计划，选择“逐项子代理实施和审查”。执行中。

## Global Constraints

- 固定上游 `2d21d21fbdd4f51f013616273ceda9b35a3e0789`；保留 regular/dev/jb/exp/less。
- `codex/upstream-2d21d21-integration` 是开发分支；主工作区现有构建产物和三个未跟踪研究文档保留。
- 产品修改在该分支进行；编译、签名和验收构建在独立目录执行，避免覆盖主工作区产物。
- 不读写根目录 `TODO.md`。执行进度写本计划的 ledger 及研究记录。
- 未知来源、坏记录、缺必需补丁、失效绑定均不取得写入资格；保留原接受条件。
- 外部可执行 patchset 默认关闭；root 不加载其代码。
- 新补丁同步更新 `research/0_binary_patch_comparison.md`；内核工作先读 `skills/kernel-analysis-vphone600/SKILL.md`。
- 未取得针对最终冻结工件和目标 VM 的具体授权前，不进行 AMFI/TCC 修改或真实 VM 写入。
- 测试全部通过不等于五项已验收；不能跳过 T40 所需的 T12/T17/T32/T34 必要能力及其前置条件。

## Review Focus

1. 校验后替换同长度文件、链接或目录：旧预览、旧 receipt 和旧授权必须失效（Task 3、4、6）。
2. 组合 patcher 只完成其中一条必需声明：其他成功记录不能代替缺失声明（Task 2）。
3. 文件发布成功后 fsync 或回复失败：表达结果不确定，读回后恢复，不能重复提交（Task 4、6、7）。
4. 新 host 搭配旧 guest/kernel/boot chain：显示四层实际来源，不能自动升级其他层（Task 6、10、12）。
5. VM 改名、移动、clone 与更换 Disk.img：前两者保留稳定身份，clone 明确身份规则，磁盘替换使旧写入证明失效（Task 3、4、10）。

## 文件与接口边界

| 模块 | 文件 | 职责 |
| --- | --- | --- |
| 声明 | `sources/FirmwarePatcher/PatchSet/PatchDeclaration.swift`、`PatchDeclarationCatalogData.swift`、`PatchSelectionMigrationData.swift` | 固定目标映射、适用性、逐记录归属 |
| 执行门 | `sources/FirmwarePatcher/PatchSet/PatchDeclarationGate.swift`、`VariantPlanResolver.swift` | 冻结选择和必需声明证据 |
| generation | 新建 `sources/FirmwarePatcher/Pipeline/FirmwareGeneration.swift` | 原件、来源、设备及 GPU 输入的不可混用记录 |
| desired plan | 新建 `sources/FirmwarePatcher/Pipeline/FirmwareDesiredPlanStore.swift`；修改 `FirmwarePlanBinding.swift`、`FirmwareTransaction.swift` | C2 持久化、显式导入、恢复边界 |
| receipt | 新建 `sources/FirmwarePatcher/Pipeline/FirmwareComponentReceipt.swift` | 按组件证明发布字节，与 plan/generation 关联 |
| guest 计划 | 新建 `scripts/patchers/plan_gate.py`；修改 `scripts/patchers/cfw.py` 及调用写入的 CFW 脚本 | 读取固定计划、输出文件变化证据 |
| 在线更新 | `sources/vphone-cli/VPhoneGuestEnvironment.swift`、`sources/VPhoneDaemon/Daemon/Wire/EnvironmentTransaction.swift` | 更新协调、严格回报及持久故障处理 |
| kernel 更新 | 新建 `sources/FirmwarePatcher/Pipeline/FirmwareKernelUpdate.swift`、`sources/vphone-cli/VPhoneVMUpdateKernelCLI.swift` | 停机更新、Preboot 唯一目标及恢复 |
| 创建冻结 | `sources/VPhoneCore/VPhoneCreateResourceSnapshot.swift`、`VPhoneResources.swift`、`VPhoneCreateRunner.swift` | 固定资源、外部工具链、CFW 输入及最终绑定 |
| 宿主路线 | `sources/VPhoneLaunchpadKit/VPhoneLaunchpadLaunchRoute.swift`、`sources/VPhoneBundleStore/VPhoneLaunchpadLauncherRequest.swift`、`scripts/check_bundle.py`、`scripts/check_launchpad_bundle.py` | caller、路径、安全拒绝和 TCC 责任链 |
| 四层来源 | `sources/VPhoneCore/VPhoneMachineBinding.swift`、`VPhoneMachineBindingPersistence.swift`、CLI/create 入口 | 仅提交被实际更新层的来源 |

### Task 1：T09 固定目标声明与迁移决定

**Files:** 修改 `scripts/generate_patch_id_migration.py`、上述声明文件；新增 `scripts/generate_target_patch_catalog.py`、`research/upstream_integration_2026-10-06/T09_target_applicability.json`、`tests/FirmwarePatcherTests/TargetCatalogTests.swift`。
**Interfaces:** 输入固定 Git 源码、现有 `PatchDeclaration` 和五模式 live steps；输出 `PatchDeclarationCatalog.all` 的完整目标对应关系，未实现项明确拒绝。

- [ ] 写 `targetIDsHaveExactlyOneDecision`、`everyVariantAndVersionHasExplicitApplicability`：141 个目标 ID 无重复、无遗漏，新增 ID 不能因缺映射而默认启用。

```swift
#expect(Set(PatchDeclarationCatalog.all.flatMap(\.upstreamIDs)).count == 141)
```
- [ ] 运行定向测试，确认新增目标映射断言在旧表上失败；记录具体缺项。
- [ ] 逐项审核目标实现、预设及条件，生成声明与决定表；更名、拆分、合并、移除沿用显式迁移，不能分别执行的选择拒绝。
- [ ] 运行 `swift test --force-resolved-versions --filter 'TargetCatalogTests|PatchSelectionMigration|PatchSelectionFileMigration|PlanSelectionValidationTests'`，要求无失败；重复迁移输出相同，显式关闭保留。
- [ ] 提交该任务涉及的源文件、测试和研究决定，使用 `feat: bind patch catalog to fixed upstream target`。

### Task 2：T10 每条声明和实际记录的执行门

**Files:** 修改 `PatchDeclaration.swift`、`PatchDeclarationGate.swift`、`VariantPlanResolver.swift`、`sources/FirmwarePatcher/Core/StructuredPatcher.swift`；新增 `tests/FirmwarePatcherTests/RequiredDeclarationEvidenceTests.swift`。
**Interfaces:** `PatchDeclarationGate.enforce(report:plan:)` 保留签名；报告增加声明归属及已应用验证证据。可变后缀记录只能通过显式声明规则归属，禁止任意前缀接受。发布门检查完整计划的全部必需声明，不能因整个组件缺失而略过；只读 dry-run 不发布结果。

- [ ] 写 `combinedStepCannotHideMissingRequiredDeclaration`、`unknownRecordInEnabledStepIsRefused`、`alreadyAppliedNeedsVerifiedOutput`：单个必需项缺失、未知记录和无证明的 alreadyApplied 均抛错。

```swift
// report 删除恰好一条必需声明的全部记录，保留同一步骤的其他成功记录。
#expect(throws: (any Error).self) { try PatchDeclarationGate.enforce(report: report, plan: plan) }
```
- [ ] 在旧实现上运行上述测试并记录失败；不能以新增接口的编译失败替代行为复现。
- [ ] 将实际 record 归属与冻结 selected 声明求交，拒绝零/多归属，逐项检查必需声明；校验后才允许事务提交。
- [ ] 运行声明门、结构化执行、五模式及完整固件对照测试；缺一条必需记录的故障注入不得改变原固件。
- [ ] 提交为 `fix: require per-declaration execution evidence`。

### Task 3：T11/T12 稳定身份与可信 generation

**Files:** 新建 `FirmwareGeneration.swift`、`tests/FirmwarePatcherTests/FirmwareGenerationTests.swift`；修改 `FirmwarePlanBinding.swift`、`sources/VPhoneCore/VPhoneCreateCheckpoint.swift`、`sources/vphone-cli/VPhoneCreateLiveStages.swift`。
**Interfaces:** `FirmwareGeneration.prepare(in directory: URL, inputs: [URL], source: Source) throws -> Prepared`、`publish(_ prepared: Prepared, planSHA256: String) throws -> Manifest`、`loadVerified(in directory: URL, id: String) throws -> Manifest`；这些类型定义在 `FirmwareGeneration` 内。Source 记录固定输入 manifest 摘要、build、设备/GPU 及来源识别结果。Manifest 绑定 `machineIdentifier` 摘要、磁盘身份、设备/GPU、build 及完整原件摘要。generation 内容身份不包含 planDigest；应用证据另关联 planDigest，避免摘要循环。

- [ ] 写 `renamePreservesIdentity`、`diskReplacementInvalidatesGeneration`、`badOriginalCannotBecomeSource`、`failedNewGenerationPreservesOld`；原件同长度改写和链接替换均拒绝。
- [ ] 运行测试并确认旧 path/inode 绑定不能满足移动和 generation 不混用要求。
- [ ] 从已验证 prepare 来源创建不可混用原件集合及 manifest；发布前逐字节摘要读回；未知旧原件只进入显式识别路线，不自动成为可信 generation。
- [ ] 运行 `swift test --force-resolved-versions --filter 'FirmwareGenerationTests|FirmwarePlanBindingTests|CreateCheckpoint|CreateLiveStages'`；覆盖 A→A、A→B→A、中断和取消，旧 generation 保持可恢复。
- [ ] 提交为 `feat: bind firmware originals to stable VM generations`。

### Task 4：T11 desired plan 原子保存与 legacy 导入

**Files:** 新建 `FirmwareDesiredPlanStore.swift`、`tests/FirmwarePatcherTests/FirmwareDesiredPlanStoreTests.swift`；修改 `FirmwarePlanBinding.swift`、`FirmwareTransaction.swift`、`sources/vphone-cli/VPhoneFWCLI.swift`。
**Interfaces:** `FirmwareDesiredPlanStore.read(in directory: URL) throws -> Read`、`prepare(in directory: URL, plan: VariantPlanResolver.VariantPlan, generation: FirmwareGeneration.Manifest) throws -> Prepared`、`publish(_ prepared: Prepared, expectedSHA256: String?) throws -> Record`。嵌套 Read 区分 missing、legacy、ready；权限、损坏、未知 schema、身份不符分别抛确定错误。nil expectedSHA256 只表示经验证的文件缺失，不能表示忽略并发变化。`fw selection-migrate` 不直接授权执行；CLI 通过 pipeline 的持锁适配方法调用 store。

- [ ] 写 `missingIsDistinctFromPermissionDenied`、`unsupportedSchemaDoesNotDefault`、`legacyImportPreservesOriginal`、`publishFailureRequiresReadback`、`journalCannotAuthorizeNewExecution`；备份、rename 和 fsync 边界逐项注入故障。
- [ ] 运行测试，确认当前只有事务证据而没有 desired store；损坏输入不得走默认配置。
- [ ] 在 VM 锁下实现显式预览/导入和原子发布，保存旧版本；存储固定 schema、target/catalog/plan 摘要及 Task 3 的 VM/generation/disk 关联，执行前重新验证绑定。
- [ ] 运行 desired store、binding、transaction、CLI 故障测试；发布不确定时保留证据并拒绝盲目重试，恢复不重新运行 patcher。
- [ ] 提交为 `feat: persist bound desired firmware plans`。

### Task 5：T10 guest Python/zsh 使用同一冻结计划

**Files:** 新建 `scripts/patchers/plan_gate.py`、`tests/test_patch_plan_gate.py`；修改 `scripts/patchers/cfw.py`、`scripts/cfw_install.sh`、`scripts/cfw_install_dev.sh`、`scripts/cfw_install_jb.sh`、`scripts/cfw_install_exp.sh`、`scripts/cfw_install_host.sh`、`sources/vphone-cli/VPhoneRestoreCLI.swift`。
**Interfaces:** `load_plan(path, expected_sha256, context) -> FrozenPlan`、`authorize(plan, declaration_id, target) -> None`、`record_change(plan, declaration_id, target, before, after) -> dict`。Swift 输出当前已验证计划及期望摘要；guest 记录绑定同一 planDigest。

- [ ] 写 `test_changed_plan_refused_before_write`、`test_guest_mode_cannot_be_overridden`、`test_unknown_record_refused`；脚本路径和真实 mode 不符、缺字段或摘要变化时原目标保持。
- [ ] 运行 `.venv/bin/python3 -m unittest tests.test_patch_plan_gate` 并确认旧无门路径不能通过。
- [ ] 所有 guest 写入入口在首次副作用前验证冻结计划；实际写入生成声明、目标和前后摘要证据，禁用外部 patchset 及隐式默认回退。
- [ ] 运行相关 CFW Python 测试、zsh 语法检查和 `make test_python`；核对默认成功路径输出及 EXP 隔离范围。
- [ ] 提交为 `feat: enforce frozen plans for guest firmware writes`。

### Task 6：T32 分组件 receipt 与来源发布

**Files:** 新建 `FirmwareComponentReceipt.swift`、`tests/FirmwarePatcherTests/FirmwareComponentReceiptTests.swift`；修改 `FirmwareTransaction.swift`、`VPhoneMachineBinding.swift`、`VPhoneMachineBindingPersistence.swift`。
**Interfaces:** `FirmwareComponentReceipt.capture(component: String, plan: VariantPlanResolver.VariantPlan, generation: FirmwareGeneration.Manifest, records: [PatchRecord], outputs: [URL]) throws -> Record`、`verify(_ record: Record, in directory: URL) throws`；`VPhoneMachineBinding.replacingOrigin(_ layer: Layer, with version: String) throws -> Self` 只替换指定层，嵌套 Layer 固定为 host/guestEnvironment/kernel/bootChain，保留现有 host-only API。

- [ ] 写 `missingRecordCannotPublishReceipt`、`receiptFailureRollsBackPublication`、`kernelReceiptDoesNotAdvanceBootChain`、`guestReceiptDoesNotAdvanceKernel`、`staleBindingCannotPublishOrigin`。
- [ ] 运行测试，确认 journal/report 完整性不能代替分组件输出证据。
- [ ] 对每条实际记录读回输出；同一恢复 journal 管理组件发布、receipt 和来源提交，结果不确定时按实际字节恢复，不自动推定 applied。
- [ ] 运行 receipt、transaction、binding 故障测试，覆盖部分失败、坏 receipt、写入拒绝及 fsync 失败。
- [ ] 提交为 `feat: publish verified component receipts and origins`。

### Task 7：T17 在线安装、激活、回退与 Stop 协调

**Files:** 修改 `VPhoneGuestEnvironment.swift`、`EnvironmentTransaction.swift` 及其 daemon 调用方；扩展 `tests/VPhoneCLITests/GuestEnvironmentUpdateTests.swift`、`tests/VPhoneDaemonWireTests/EnvironmentTransactionTests.swift`。
**Interfaces:** 保留现有 environment API 命令；install/restore 回报必须提供 transaction、完整组件集合、前后 hash 和状态。单 VM 写入协调使自动/手动同步、rollback 与 Stop 有确定顺序。

- [ ] 写 journal 保存失败、restore 缺字段/重复组件/错 hash、安装成功丢回复、更新与 Stop/自动同步竞争的失败用例；旧映射库不得被报告为全部激活。
- [ ] 运行测试，复现 `try? save(journal)` 和宽松 restore 解码的行为问题。
- [ ] 将 journal 错误传播至调用方并停止下一次写入，严格校验 restore，按实例及 mode 绑定资格；丢回复只通过状态与文件读回恢复，不自动重放安装。
- [ ] 运行在线更新和 daemon wire 套件，逐项证明文件安装、mapped copy、实际行为、重启需求分开表达；不扩大 respring/reboot 范围。
- [ ] 提交为 `fix: coordinate and verify guest environment transactions`。

### Task 8：T34 kernel-only 停机更新及恢复

**Files:** 新建 `FirmwareKernelUpdate.swift`、`VPhoneVMUpdateKernelCLI.swift`、`tests/FirmwarePatcherTests/FirmwareKernelUpdateTests.swift`；复用 `sources/FirmwarePatcher/Binary/VPhoneKernelcacheSwap.swift` 及 `KernelcacheSwapTests.swift`，修改 `sources/vphone-cli/VPhoneVMCLI.swift`、`sources/VPhoneLaunchpadKit/VPhoneLaunchpadCommandLine.swift` 接入操作入口。
**Interfaces:** `FirmwareKernelUpdate.prepare(in directory: URL, plan: VariantPlanResolver.VariantPlan, generation: FirmwareGeneration.Manifest) throws -> Prepared`、`publish(_ prepared: Prepared) throws -> FirmwareComponentReceipt.Record`；只接受已停机、磁盘已释放、唯一普通文件 Preboot 目标及已证明 DSC 兼容性。

- [ ] 写零/多候选、错 generation、坏原件、只读挂载恢复失败、7 GiB→6 GiB DSC 超界、发布中断和 receipt 失败测试。
- [ ] 运行测试，确认现有 IMG4 payload swap 尚不能完成整条磁盘更新。
- [ ] 从 Task 3 原件执行 Task 4 冻结计划；保留 IM4M 原字节，事务性发布 kernel、Task 6 receipt 和 kernel 来源，其他启动链及 guest 数据不变。
- [ ] 运行 kernel swap/update、DSC 兼容性和事务恢复测试；记录新内核实际启动与离线执行分别验收。
- [ ] 提交为 `feat: update stopped VM kernels with transactional recovery`。

### Task 9：T40 创建输入及外部工具链冻结

**Files:** 修改 `VPhoneCreateResourceSnapshot.swift`、`VPhoneResources.swift`、`VPhoneCreateRunner.swift`、`sources/vphone-cli/VPhoneCreateLiveStages.swift`；扩展 `tests/VPhoneCoreTests/CreateResourceSnapshotTests.swift`、`tests/VPhoneCLITests/CreateResourceFreezeTests.swift` 和 Python 工具链集成测试。
**Interfaces:** 保留 `VPhoneCreateResourceSnapshot.capture(resources:executable:)`；Manifest 扩展外部工具、版本、摘要及保留边界。snapshot.resources 的所有创建路径指向已固定输入；恢复时验证 checkpoint 的工具链摘要。

- [ ] 写捕获后替换 Python/framework/packages/native library、PATH 工具、SDK、CFW 输入和缓存的测试；旧来源不可访问时副本流程仍通过，未纳入闭包的依赖在写入前拒绝。
- [ ] 运行测试，确认当前 closureLimits 所列外部输入仍影响创建行为。
- [ ] 复用 B28 副本实验已验证的探测方法，完成产品路径、延迟加载 libusb、CA、子进程及编译输入；按实际大小实施容量和保留限制，不复制无关 `.build` 或 VM 数据。
- [ ] 运行创建定向测试与隔离实际 Bundle 创建流程；证明来源变化、取消、恢复不会混用工具链。
- [ ] 提交为 `feat: freeze complete create inputs and toolchain dependencies`。

### Task 10：T40 新机可信绑定和四层来源路由

**Files:** 修改 `sources/vphone-cli/VPhoneCreateOrchestrator.swift`、`VPhoneCreateLiveStages.swift`、`VPhoneVMBindingCLI.swift`、`VPhoneMachineBindingPersistence.swift`、`sources/VPhoneLaunchpadKit/VPhoneLaunchpadCoreBundle.swift`；扩展 binding/create/CLI 测试。
**Interfaces:** 创建成功发布经过 store 验证的 host binding 和 receipt；Task 6 的指定层来源 API 为唯一组件来源更新入口。已有 VM 继续使用其绑定版本。

- [ ] 写创建取消不发布绑定、缺/坏 Bundle 不回退、local/CI 并存、同 series 不同 patch、clone/export/rename 和纯兼容连接不改 guest 的测试。
- [ ] 运行测试，确认现有资源 snapshot 不等于可信 store receipt，不能直接据此发布绑定。
- [ ] 将创建最终发布和来源提交接入已有锁及恢复记录；显示 host、guest、kernel、boot-chain 四层及 unknown 状态，切 host 仅更新 host。
- [ ] 运行 create、binding 和 CLI 套件；涉及完整 archive 的测试使用足够空间的真实测试副本，不能以 APFS clone 代替归档往返。
- [ ] 提交为 `feat: preserve verified per-VM origins across lifecycle operations`。

### Task 11：T24 宿主拒绝矩阵及 TCC 责任链

**Files:** 修改 launcher/store/helper 的现有入口及 `scripts/check_bundle.py`、`scripts/check_launchpad_bundle.py`；扩展 `tests/VPhoneLaunchpadKitTests/LaunchRouteTests.swift`、`tests/test_bundle_validation.py`、`tests/test_launchpad_bundle.py`。
**Interfaces:** 不新增通用特权 verb。实际 app/helper 的签名、usage description、entitlement 和负责 TCC 的身份写入验收证据；普通 fallback 保留相同安全门槛。

- [ ] 写错误 owner、共享可写目录、校验后链接替换、旧 helper、unknown verb 以及 launcher 缺失 fallback 的用例；先保存失败输出。
- [ ] 修正用例证明的实际缺陷；逐项运行相关测试，禁止通过关闭原有安全检查使测试通过。
- [ ] 在独立构建目录执行 `make build`、guest 构建及 Launchpad 构建，校验依赖闭包、签名、架构和资源；冻结最终工件 SHA256/CDHash。
- [ ] 编写针对最终工件、临时服务和测试 VM 副本的具体授权/恢复清单，取得所需授权后验证 CLI 与 Launchpad → launcher → store 路线的 TCC 允许、拒绝、撤销、重连及真实旧协议拒绝。
- [ ] 保留成功、失败和清理证据；条件未满足则 T24 保持未验收，不能用 AMFI 放行代替 TCC。提交为 `test: verify host policy and permission responsibility chains`。

### Task 12：完整验证、独立审查和五项验收

**Files:** 更新本计划 ledger、`research/upstream_integration_2026-10-06/tasks.json`、同目录 README、`research/0_binary_patch_comparison.md` 及本轮证据。
**Interfaces:** 原任务接受条件为最终判据；依赖任务按各自证据独立评估。独立审查只读，不修改用户 VM 或系统状态。

- [ ] 运行 `make test_python`、`make test_swift`，以及 `VPHONE_TEST_FIXTURES=/Users/qcz3840/github/vphone-cli/ipsws/patch_refactor_input make test_firmware`；修复变更导致的失败并重跑受影响检查。
- [ ] 比较固定上游与本地固件输出，逐项记录预期模式差异、记录及字节证据；本地历史 Python 参考结果不能代替固定上游对照。
- [ ] 在已授权副本上完成创建、正常启动、可信绑定、host 切换/回退、guest 升级/回退、kernel-only 更新/回退和 mixed-version 矩阵；读回四层来源、关键 guest hash 和实例，验收失败保留恢复路径。
- [ ] 依据 executing-plans 或 subagent-driven-development 的要求完成一次全分支独立审查；实际影响为 Critical/Important 的问题通过失败测试修复并重跑完整检查。
- [ ] 对照五项原验收逐条记录证据，全部满足后才改为 accepted；提交完成记录，保留尚未取得授权或环境阻塞的真实状态。未经授权不 push 或合并其他分支。

## 自审结果

T09 对应 Task 1；T10 对应 Task 2、5；T11 对应 Task 3、4；T24 对应 Task 11；T40 对应 Task 6–10、12。generation、receipt、在线激活和 kernel 更新作为五项完成所需的实现步骤保留。Task 3 先定义输入内容身份，Task 4 再绑定计划，Task 6 记录应用结果，避免 generation/plan 摘要循环。Task 11 的系统授权只在最终工件冻结后提出。

执行方式：用户已选择逐项子代理实施和审查。每个任务使用独立实施子代理，完成后由独立子代理审查需求符合性及代码质量，末尾再进行全分支审查。选择执行方式不扩大系统操作授权。
