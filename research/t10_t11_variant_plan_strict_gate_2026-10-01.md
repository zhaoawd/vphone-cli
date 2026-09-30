# T10/T11：五变体选择策略与严格计划及声明完整性

日期：2026-10-01。分支 `codex/upstream-4bab3b7-integration`，本地 HEAD `8d84bbc`。
上游参考固定 tag `upstream-2.2.3`（`a969cd5d9206932dc1a2797348027fbc7d0ee347`）。
输入：T09 映射 `research/t09_patch_id_mapping_2026-10-01.json`。

本文分开陈述事实、推断和待验证假设。标识符、命令、字段名保留原文。

## 1. 范围与设计决定

本轮实现声明层（T10）与严格计划及写入门（T11），覆盖 Swift `FirmwarePatcher`（引导链、内核、DeviceTree、less 的 filesystem/manifest）。沿用实施计划已定的六条设计决定：

1. 保留本地 regular/dev/jb/exp/less 变体维度与公开入口，默认 regular；上游声明 ID 只作为稳定标识叠加在本地变体之上，不改写为上游 preset。
2. 版本条件以本地 `PatchRule` 为准；上游 `VPhonePatchApplicability` 仅在声明表 `upstreamApplicability` 字段记录，用于交叉引用，不静默采用。
3. 未声明记录严格拒绝。resolver 与写入门共用同一“是否启用”判定，语义一致；不沿用上游 `VPhonePatchGate.allows(record:)` 对未声明 record 返回 true 的失败开放行为。
4. `dyld-exp-mis_trust_auth` 与 libmisfix 本地无实现，声明表标 `notImplemented`；任何变体、任何显式选择它时 resolver 拒绝并给出原因。
5. 本轮严格计划只覆盖 Swift 写入的组件。guest 侧 Python/zsh 步骤（`dyld-*`/`system-*`/`preboot-*`）只进入声明表并做只读一致性检查，不改其执行路径，也不受写入门约束（见 §7 未覆盖范围）。
6. 不改任何补丁的匹配逻辑、写入字节或默认行为。见 §6 输出不变论证。

## 2. 声明表（T10 产出）

数据位置：`sources/FirmwarePatcher/PatchSet/PatchDeclarationCatalogData.swift`（由 T09 映射生成，见 §8 复现）。人类可读副本 `research/t10_patch_declarations_2026-10-01.json`。模型与查询在 `PatchDeclaration.swift`、`PatchDeclarationCatalog.swift`。

每条声明字段：

| 字段 | 含义 |
| --- | --- |
| `id` | 稳定声明 ID：有上游声明的用上游 ID；无上游声明的 Swift 步骤用 `{component}-{effect}-{name}` 本地 ID |
| `coverage` | `swift`（本轮写入门覆盖）/ `guestStep`（guest 步骤，仅声明与只读检查）/ `notImplemented` |
| `swiftSteps` | 本声明授权的本地 Swift 步骤 `PatchID.description`；一条记录归属到发出它的步骤所属声明 |
| `variants` | 该声明步骤出现在哪些变体的组件列表中（与版本门无关；条件步骤即使规则为假也算成员） |
| `optIn` | `none` / `frida`（额外显式 opt-in） |
| `required` | 上游 `bootEssential` |
| `versionRule` | 本地 `PatchRule`（权威）；guest/notImplemented 为 nil |
| `upstreamIDs` | 对应上游声明 ID（local_only 为空） |
| `upstreamApplicability` | 上游 `VPhonePatchApplicability` 文本，仅交叉引用 |
| `requires`/`conflicts`/`after` | 依赖/冲突/顺序（真实数据为空；作为拒绝机制供校验，见 §4） |

统计（事实，来自生成器与 §8 复现）：

| 维度 | 数 |
| --- | ---: |
| 声明总数 | 119 |
| `swift` 声明 | 96 |
| `guestStep` 声明 | 22 |
| `notImplemented` 声明 | 1（`dyld-exp-mis_trust_auth`） |
| swift 声明绑定的唯一步骤数 | 91 |

多声明绑定同一步骤（事实）：`kernelcache.KernelPatcher.patchApfsMount`（4 条上游声明：apfs_vfsop_mount / apfs_mount_upgrade_checks / handle_fsioc_graft / handle_get_dev_by_role）、`kernelcache.KernelPatcher.patchSandbox`（5 条 sandbox_* 声明）。原因：上游把一个本地方法拆成多条声明。

一声明绑定多步骤（事实）：`kernel-boot-post_validation`（NOP+CMP 两步）、`kernel-boot-iomfb_swapend`（VariableSize+HandlerSize 两步）、`txm-boot-trustcache_bypass`（TXMPatcher 与 TXMDevPatcher 两个变体替代实现）。

特殊项（事实）：`kernel-boot-amfi_execve` 上游声明 `bootEssential`，但两侧 orchestrator 都无调用者（不在任何 `buildSteps`）；本地声明 `swiftSteps` 为空、`required=false`，并在数据中注明。这是本地与上游的一处差异（见 §5）。

`local_only` Swift（无上游声明）：`filesystem-less-cryptex_merge`、`manifest-less-hash_rewrite`（均 less 变体）。

## 3. 计划解析（T10 产出）

实现 `VariantPlanResolver.resolve(variant:gates:...)`（`VariantPlanResolver.swift`）。它从流水线自身 `buildComponentList()`/`buildSteps()` 推导每变体的实际步骤集合（`liveStepIDs`，不写盘、空数据构造），再与声明表连接，输出 `VariantPlan`：

- `selected`：本变体启用的声明（含 required/optional）。
- `excludedByVersion`：版本规则为假（如 26 基线上的 iOS-27-only）。
- `excludedByOptIn`：需要 `--frida` 但未开启，或被显式 block。
- `excludedByVariant`：声明不属于本变体（如非 exp 变体下的 `devicetree-exp-*`、`kernel-exp-hv_vmm`）。
- `guestUncovered`：guest 声明，本轮不覆盖执行门。
- `notImplemented`：始终列出，永不启用。
- `enabledSteps`：本变体实际运行的 Swift 步骤（选中声明的步骤与本变体 live 步骤取交，处理变体替代实现，见 trustcache）。

只读入口：`vphone-cli fw plan`（新增子命令，挂在既有 `fw` 下，`sources/vphone-cli/VPhoneFWCLI.swift`）。它不碰 VM、不修改任何文件；门控值由 `--base-os`/`--frida`/`--force-exc-guard`/`--base-unknown` 建模，`--all` 遍历五变体，`--json` 输出 `VariantPlan`。`--select`/`--block` 可显式覆盖并触发未知/未实现拒绝。

默认门控（base 26、无 frida、无 force-exc-guard）各变体启用步骤数（事实，命令见 §9）：

| 变体 | enabledSteps |
| --- | ---: |
| regular | 28 |
| dev | 34 |
| jb | 58 |
| exp | 78 |
| less | 15 |

其他门控示例：jb `--base-os 27 --frida` = 68；exp `--base-os 27 --frida` = 88。（regular 默认 28 而非 29：`kernel-boot-thread_guard_violation`/patchExcGuardBehavior 规则 `excGuardActive` 默认为假，属 `excludedByVersion`。）

## 4. 严格校验与写入门（T11 产出）

### resolver 校验（`resolve` 与 `PatchDeclarationCatalog.validateStructure`）

逐类拒绝，错误含具体 ID（`CatalogError`）：

| 类别 | 触发 |
| --- | --- |
| `duplicateDeclaration` | 声明 ID 重复 |
| `missingDependency` | `requires` 目标不存在（结构）或未启用（解析） |
| `conflict` | 两条启用声明互相 `conflicts` |
| `cyclicOrder` | `after` 图有环 |
| `unknownDeclaration` | `--select`/`--block` 命名不存在的 ID |
| `notImplementedSelected` | 选择 `notImplemented` 声明（如 mis_trust_auth） |
| `versionIndeterminate` | 基线版本不可读，而 required 且版本门为 iosBaseIs18/27 的声明无法判定 |
| `requiredMissing` | required 声明适用于本变体且规则成立，但其步骤都不在流水线 live 步骤中 |
| `liveStepUndeclared` | 流水线某步骤在声明表中无归属 |

### 写入门（`PatchDeclarationGate`，接入 `FirmwarePipeline.patchAllStructured`）

位置：`staged.executeStructured` 之后、`report.failedRequired` 检查通过之后、`transaction.commit()` 之前。逐条检查报告中 `outcome` 为 `applied`/`alreadyApplied` 的步骤结果：

- 步骤无任何声明绑定 → `undeclared`，拒绝。
- 步骤有声明但对本变体/版本/opt-in 未启用 → `notEnabled`，拒绝。
- 否则通过。

拒绝时抛 `PatcherError.patchVerificationFailed`，由 `patchAllStructured` 既有 `do/catch` 调 `transaction.recordFailure` 并重抛。因为门在 `commit()` 之前、补丁写在暂存目录（`transaction.stage`），拒绝时原固件不被替换（保留既有事务与失败记录机制）。`notApplicable`/`ablated`/`failed` 结果不计入门检查；ablation dry-run（`allowOutput=false`）在进入事务块前已返回，不触发门。

判定一致性（决定 3）：resolver 的 `enabledSteps` 与写入门都调用 `PatchDeclarationCatalog.status(ofStep:variant:gates:)`，同一判定函数。

## 5. 与上游 Plan/Gate 的差异

事实：

1. 单元不同。上游声明单元是 `VPhonePatchDeclaration`（选择/版本作用于声明，记录按 `covers(recordIdentifier:)` 前缀归属声明）。本地声明单元仍是本地 Swift 步骤 `PatchID`；记录到步骤的归属由结构化执行的 `recordIndices` 直接建立，不靠字符串前缀（本地记录字面量前缀不统一：`jb.`、`kernel.`、`kernelcache_jb.`、`txm_dev.` 等）。
2. 未声明记录处理相反。上游 `VPhonePatchGate.allows(record:)` 对未声明 record 返回 true 并告警（失败开放）；`VPhonePatchPlan.isRecordEnabled` 对未声明 record 返回 false。本地写入门对未声明步骤一律拒绝（决定 3）。
3. 版本条件双轨。上游用 `VPhonePatchApplicability`（结构化 iOSBase/cloudOS 要求）；本地用 `PatchRule`（iosBaseIs18/iosBaseIs27/cloudOSFridaCapable/excGuardActive）。本地以 `PatchRule` 为准，`upstreamApplicability` 只记录。两者对应关系见 T09 §4/§6，不一致处（如 frida 额外要求 `--frida`）在 T09 中已列。
4. preset 与变体不对应。上游只有 standard/experimental 两个 preset；本地五变体是独立维度。本声明表不引入 preset，`variants` 直接取自本地组件列表。§6 结论（standard↔jb 的 DeviceTree 相机节点/身份差异）保留为 T09 记录的事实，本轮不改变本地 jb 的 DeviceTree 行为。
5. `dyld-exp-mis_trust_auth` 本地 `notImplemented`（决定 4），上游 experimental 选中。
6. `kernel-boot-amfi_execve` 两侧都无调用者；上游仍声明 `bootEssential=true` 且 2.2.3 下不发记录，本地 `required=false` 且无绑定步骤。二者运行时都不发出该记录，行为一致；仅声明的 `required` 标记不同。

## 6. 输出不变论证（决定 6）

推断（有测试支持）：写入门在正确配置下永不拒绝，因此提交路径的字节输出与加门前一致。

依据：
- 结构化执行只在步骤的 requirement 规则成立时运行该步骤（条件为假的步骤 `notApplicable`、不发记录）。因此任何 `applied`/`alreadyApplied` 且发记录的步骤，其规则必为真。
- 声明表的 `variants` 与 `versionRule` 与流水线实际步骤集合一致，由测试 `resolvedPlanMatchesLiveStepsForEveryVariantAndGate` 对五变体 × 五组门控快照断言 `plan.enabledStepIDs == 流水线执行步骤集合`（执行集合由 `buildSteps` 的 requirement 独立推导，非手写清单）。
- 因此发出记录的步骤必在 `enabledSteps` 中，`status` 返回 `enabled`，门不拒绝，`commit()` 照常执行。

未执行项：真实固件字节对比未运行（见 §9），未在真实 commit 路径上直接验证“加门前后逐字节相同”。上述为推断加单元测试支持，非固件级证据。

## 7. 未覆盖范围

- guest 侧 Python/zsh 步骤（22 条 `guestStep` 声明：`dyld-*`、`system-*`、`preboot-exp-devicetree_identity`）本轮只进声明表并在 `fw plan` 中列为 `guestUncovered`，其执行路径（`scripts/patchers/`、`scripts/cfw_install*.sh`）未接入写入门。原因：这些步骤不发 `PatchRecord`，无本地 `VPhonePatchGate`。为它们引入声明/门控层属后续工作。
- `dyld-exp-mis_trust_auth` 与 libmisfix 未实现（T18）。
- `system-launchdaemons-boot-environment` 在 T09 标 `uncertain`（本地无等价单一步骤）；本表按 guest 处理，含义待确认项仍以 T09 §7 为准。
- 真实 VM 恢复/启动、真实固件字节对比未做（无固件夹具）。

## 8. 声明表复现

生成器（会话 scratch，未提交）：读 `research/t09_patch_id_mapping_2026-10-01.json`，按 coverage 分类，Swift 步骤取自 T09 `local.identifiers`；DeviceTree 步骤方法名含点，从源码 `DeviceTreePatcher.swift` 的 `patchID:` 字面量按归一化名配对（两处大小写/下划线不规则用显式 override：`ispRtb`、`smc.smc_ext`）；`kernel-boot-amfi_execve` 强制空步骤。输出 `PatchDeclarationCatalogData.swift` 与 `research/t10_patch_declarations_2026-10-01.json`。

关键校验（生成器 stderr，事实）：`declarations=119 swift=96 guest=22 notImpl=1`；`swift 唯一步骤=91`；多绑定步骤仅 apfs_mount(4)、sandbox(5)。

## 9. 命令与原始结果

module cache 环境沿用 `scripts/run_tests.py`（`--cache-path .build/test-cache`、`CLANG_MODULE_CACHE_PATH`/`SWIFT_MODULECACHE_PATH=.build/test-module-cache`）。

- 专项：`swift test --filter "VariantPlanTests|DeclarationGateTests"` → `23 tests in 2 suites passed`（含 T10 一致性、五变体、EXP 隔离、frida opt-in、less 独立；T11 八类拒绝各一例、写入门 undeclared/notEnabled/clean、拒绝前字节不变）。
- `python3 scripts/run_tests.py swift`（等价 `make test_swift`）→ EXIT=0；FirmwarePatcherTests `176 tests in 31 suites passed`，其余套件通过，`check_tar_pipe_memory` `124 checks, 0 failures`，`test_guest_components` 通过。
- `python3 scripts/run_tests.py python`（等价 `make test_python`）→ EXIT=0，`Ran 391 tests ... OK`。
- `python3 scripts/run_tests.py fixtures`（等价 `make test_fixtures`）→ EXIT=1，固件夹具缺失（`ipsws/patch_refactor_input` 缺 raw_payloads/reference_patches/Firmware 等）。因此 `make test_firmware` 未执行，真实固件字节对比未运行。
- `vphone-cli fw plan --all`、`fw plan -V <v> --json`、`fw plan -V exp --select dyld-exp-mis_trust_auth`（拒绝）已运行，输出符合预期。默认门控各变体 enabledSteps：regular 28 / dev 34 / jb 58 / exp 78 / less 15。

## 10. 与 0_binary_patch_comparison.md 的关系

本轮未新增或改动二进制补丁，不改既有计数。仅在该文档加一条指向本声明表与 `fw plan` 的说明。
