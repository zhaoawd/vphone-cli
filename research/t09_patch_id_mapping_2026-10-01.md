# T09：补丁 ID、集合与预设映射（上游 2.2.3 → 本地）

日期：2026-10-01。上游固定目标 `upstream-2.2.3`（`a969cd5d9206932dc1a2797348027fbc7d0ee347`）。
本地 HEAD `8d84bbc`，分支 `codex/upstream-4bab3b7-integration`。
机器可读台账：[`t09_patch_id_mapping_2026-10-01.json`](t09_patch_id_mapping_2026-10-01.json)。

本任务只做声明层映射：对齐上游 `VPhonePatchKit` 声明与本地补丁实现（Swift 补丁器或 Python/zsh CFW 步骤），记录 ID 变迁、记录前缀、patch set、版本条件、standard/experimental 选中状态、本地五变体（regular/dev/jb/exp/less）适用性。不做二进制验证，不分析内核指令字节。

## 1. 方法

1. 上游声明：读 `git show upstream-2.2.3:VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/*PatchSet.swift`，解析每个 `VPhonePatchDeclaration`（含 `DeviceTreePatcher` 的 `property(...)` 辅助函数）。共 9 个 bundled patch set、117 条声明。
2. 旧 ID（ae5e4531 之前）：按同一 patch set 内声明顺序与 `title` 字段，对齐 `ae5e4531^` 与 `ae5e4531` 两版声明，得到 `{旧 ID → ae5e4531 后 ID}`。ae5e4531 后到 2.2.3 之间的 ID 变化单独用 `git log -S` 定位（仅 `dyld-exp-mis_trust_auth` 一条，见 §5）。
3. 记录前缀与记录字面量：`git grep` 上游 `FirmwarePatcher`、`VPhoneCommand/Firmware` 下形如 `{component}-{effect}-{name}[.site]` 的字符串字面量，按 `VPhonePatchDeclaration.covers(recordIdentifier:)` 规则（`record == id || record.hasPrefix(id + ".")`，最长 ID 优先）归属到声明。区分“记录字面量”（`patchID:`/`id:`/静态 `patchID`/`recordGroup`，即补丁写入时发出的记录）与“门控字面量”（`on(...)`、`plan.isEnabled(...)`、`gate.allows(...)` 等选择判断）。
4. 旧记录字面量：从 `git diff -U0 ae5e4531^ ae5e4531` 的等长删除/新增行配对，得到 `{旧记录字面量 → 新记录字面量}`。
5. 本地对应：以（a）旧记录字面量在本地指定文件中出现、（b）目标函数名一致、（c）锚点字符串集合重叠三项为依据。Swift 补丁器若旧记录字面量未在指定本地文件出现，自动降级为 `uncertain`。
6. 五变体适用性：取自本地 `FirmwarePipeline.buildComponentList`（`sources/FirmwarePatcher/Pipeline/FirmwarePipeline.swift`）、各 patcher `buildSteps`、以及 `scripts/cfw_install*.sh`；每条给出 `文件:行号` 证据与 `condition`。

### 复现命令（脚本在 scratch 目录，未提交）

计数与提取脚本位于会话 scratch 目录。关键命令：

```sh
# 上游声明总数（117）
git show upstream-2.2.3:VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/FirmwareBootChainPatchSet.swift   # 逐文件
git ls-tree --name-only upstream-2.2.3 VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/                    # 9 个 *PatchSet.swift

# standard 排除的 15 个 ID
git show upstream-2.2.3:VPhoneExecutable/VPhoneVirtualization/Resources/patches_presets/standard.plist

# ID 改名提交前后
git show ae5e4531 --stat
git diff -U0 ae5e4531^ ae5e4531 -- VPhoneExecutable/VPhoneCommand/FirmwarePatcher

# 记录字面量归属（上游）
git grep -nE '"[a-z0-9_]+-[a-z0-9_-]+' upstream-2.2.3 -- \
  'VPhoneExecutable/VPhoneCommand/*.swift' ':!*/PatchSets/*' ':!*Tests*'

# 本地记录字面量
grep -rn 'patchID: "' sources/FirmwarePatcher
```

`t09_patch_id_mapping_2026-10-01.json` 的 `checks` 字段由脚本从源码计算，非手工估数。

## 2. 统计

| 维度 | 结果 |
| --- | --- |
| 上游声明总数 | 117 |
| 状态 `mapped` | 115 |
| 状态 `uncertain` | 1（`system-launchdaemons-boot-environment`） |
| 状态 `upstream_only` | 1（`dyld-exp-mis_trust_auth`） |
| `local_only`（本地有、上游 2.2.3 无声明） | 11 条 |

各 patch set 声明数：

| Patch set | 声明数 |
| --- | ---: |
| com.vphone.patchset.bootchain | 19 |
| com.vphone.patchset.kernel.base | 18 |
| com.vphone.patchset.kernel.cfw | 31 |
| com.vphone.patchset.kernel.hypervisor | 1 |
| com.vphone.patchset.kernel.frida | 2 |
| com.vphone.patchset.devicetree | 23 |
| com.vphone.patchset.guest.system | 17 |
| com.vphone.patchset.guest.display | 2 |
| com.vphone.patchset.guest.identity | 4 |

各顶层组件（`{component}` 段，`system-<binary>` 归为 system）声明数：

| 组件 | 数 |
| --- | ---: |
| kernel | 52 |
| devicetree | 23 |
| system | 13 |
| dyld | 9 |
| txm | 6 |
| llb | 5 |
| ibec | 4 |
| ibss | 3 |
| avpbooter | 1 |
| preboot | 1 |

实现语言分布（声明层）：boot chain（avpbooter/ibss/ibec/llb）、txm、kernel base/cfw/frida/hypervisor、devicetree 为 Swift 补丁器；`dyld-*` 与 `system-*`、`preboot-*` 为 Python（`scripts/patchers/`）+ zsh（`scripts/cfw_install*.sh`）；less 变体的 `system-*` 部分由 Swift `CryptexFilesystemPatcher` 实现。

## 3. ID 唯一性检查结果

- 上游 117 条声明 ID 两两不重复（`checks.duplicate_ids` 为空）。
- 无声明 ID 是另一声明 ID 的“点后缀前缀”（`checks.record_prefix_overlaps` 为空）。ae5e4531 的改名说明特意消除了下划线前缀歧义（`kernel-boot-post_validation` 与 `kernel-boot-post_validation_unsigned` 用点分隔各自的记录站点，分属 kernel.base 与 kernel.cfw 两个 set）。
- 无记录字面量被多于一个声明覆盖（`checks.record_literals_shared_by_multiple_declarations` 为空）。
- 18 条声明在源码中没有独立“记录字面量”（`checks.declarations_without_record_literal`）：它们是 `dyld-*` DSC 补丁与 `system-*` guest 步骤，补丁效果不发出 `PatchRecord`，而通过安装器的 `on("<id>")` 门控执行；其中仅 `preboot-exp-devicetree_identity` 连门控字面量都没有独立字符串（由 `FirmwareGuestIdentityPatchSet.prebootDeviceTreeIdentity` 常量引用，见 `VPhoneCustomFirmwareInstaller.swift:982`）。这不是重复或缺失，是这些补丁不走 record 机制。

## 4. standard 排除的 15 个 ID 与本地变体逐项对照

`standard.plist` 的 Selection 为 `Block`，排除下列 15 个 ID；`experimental.plist` 为 `All`（全选，各自版本门仍生效）。本地无与上游 preset 同名的机制，以下给出各 ID 在本地五变体中的实际开启情况（依据 §1 第 6 项证据）。

| # | 上游 ID | 本地对应状态 | 本地开启的变体 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | kernel-exp-frida_thread_set_state_entitlement_flag | mapped | jb、exp（均需 `--frida` 且 cloudOS≥26.4） | 本地在 KernelJBPatcher，条件 `PatchRule.cloudOSFridaCapable`；上游 frida set 版本门 cloudOS `.atLeast(26,4)`，standard 屏蔽、experimental 选中 |
| 2 | kernel-exp-frida_vm_map_delete_immutable_code | mapped | jb、exp（同上） | 同上 |
| 3 | kernel-exp-hv_vmm | mapped | exp | 本地 KernelEXPPatcher，仅 exp 变体构造；上游 hypervisor set 单独一条 |
| 4 | dyld-exp-hv_vmm | mapped | exp | 本地 `cfw_patch_hv_vmm_dsc.py`，仅 `cfw_install_exp.sh` 调用 |
| 5 | system-watchdogd-exp-hv_vmm_cache | mapped | exp | 本地 `cfw_patch_watchdogd.py`，仅 exp |
| 6 | devicetree-exp-target_sub_type | mapped | exp | 本地在 `identityPropertyPatches`，仅 `includeIdentityPatches`（exp）运行 |
| 7 | devicetree-exp-compatible_secondary | mapped | exp | 同上 |
| 8 | devicetree-exp-product_fdr_product_type | mapped | exp | 同上 |
| 9 | devicetree-exp-product_sub_product_type | mapped | exp | 同上 |
| 10 | devicetree-exp-product_unique_model | mapped | exp | 同上 |
| 11 | devicetree-exp-product_gestalt_variants_rename | mapped | exp | 同上 |
| 12 | devicetree-exp-arm_io_device_type | mapped | exp | 同上 |
| 13 | devicetree-exp-arm_io_soc_generation | mapped | exp | 同上 |
| 14 | preboot-exp-devicetree_identity | mapped | exp | 本地 `cfw_patch_post_restore_dt.py`（EXP-JB-6），仅 exp |
| 15 | dyld-exp-mis_trust_auth | upstream_only | 无 | 本地未实现，见 §5 |

对照结论：上游 standard 排除的 15 项，本地对应的 14 项全部集中在本地 exp 变体（frida 两项还需 `--frida`），本地 jb 变体不包含 hv_vmm/身份重写/mis_trust_auth；这与“本地 exp = 本地 jb + hv_vmm 隐藏 + D47AP 身份”的分工一致。第 15 项 mis_trust_auth 本地无对应实现。因此上游 standard（全部 bundled set、Block 15 项）与本地 jb 变体在“身份重写、hv_vmm 隐藏”上取向相反：上游 standard 保留相机、devicetree 基础属性与相机节点（`devicetree-cfw-*` 不在排除表），屏蔽 D47AP 身份；本地 jb 同样保留相机，但本地 jb 的 DeviceTree 仅 `basePropertyPatches`（4 条），不含身份属性与相机节点——`dtIncludeIdentity = variant == .exp`（`FirmwarePipeline.swift:736`）。这是本地与上游的一处实际差异，见 §6。

## 5. dyld-exp-mis_trust_auth（upstream_only）

上游演进：`fe3cf50`(2026-09-30) 提交 “Stop editing the shared cache to accept an online-authorized profile” 把 ae5e4531 时的 `dyld-cfw-mis_trust_auth` 改名/改效果为 `dyld-exp-mis_trust_auth` 并移入 standard 的 Block 表；配套 `1c19bb4` 删除了 `system-installd-cfw-adhoc_signature`、`system-misagent-cfw-device_identity` 两条声明（改为 libmisfix 用户态 spawn hook）。上游实现文件：`DyldSharedCache/Patchers/DyldSharedCacheMISTrustAuthPatcher.swift`（记录 `dyld-exp-mis_trust_auth.force_success`）。

本地检索结论：`scripts/patchers/`、`scripts/cfw_install*.sh`、`sources/` 中未找到 `mis_trust_auth` / `checkTrustAndAuthorization` / `RespectUppTrustAndAuthorization` 的补丁实现，也没有 libmisfix 及其 spawn hook。复现：

```sh
grep -rin 'mis_trust_auth\|checkTrustAndAuthorization\|libmisfix\|RespectUppTrust' scripts sources
```

因此该声明标 `upstream_only`：上游用来在 26.x 旧环境下作为“更新环境”的替代开关、并在 27 上禁用；本地无此路径，也无 libmisfix 用户态替代。T10/T11 需要决定本地是否引入该声明与实现（见 §8）。

## 6. 上游 preset 与本地五变体不能按名称等同（逐条事实）

1. 上游只有两个 bundled preset（standard、experimental），均引用全部 9 个 bundled set，差异仅在 Selection；本地有五个变体（regular/dev/jb/exp/less），由 `FirmwarePipeline.Variant` 与不同 patcher 组合决定，且 less 是另一条独立管线（Cryptex 合并 + Manifest 哈希，不打引导链/内核）。二者不是同一维度。
2. 上游 standard ≠ 本地 regular。本地 regular 只运行 `AVPBooterPatcher`、`IBootPatcher`（ibss/ibec/llb 基础）、`TXMPatcher`、`KernelPatcher`（base，dev 相关关闭）、`DeviceTreePatcher`（仅基础属性），不含任何 `kernel-boot-*`/`kernel-cfw-*` cfw 内核补丁、不含 guest DSC/守护进程步骤。上游 standard 则选中 bootchain + kernel.base + kernel.cfw + devicetree + guest.system + guest.display + guest.identity（相机），只屏蔽 15 项。上游 standard 对应的完整 CFW 能力，本地需 jb/exp 才具备。
3. 上游 standard ≈ 本地 jb（能力面），但 DeviceTree 身份不同：上游 standard 保留 `devicetree-cfw-*`（相机几何、相机/音频/SMC 节点）并屏蔽 8 条 `devicetree-exp-*` 身份；本地 jb 的 DeviceTree 只运行 `basePropertyPatches`（4 条：serial_number、home_button_type、artwork_device_subtype、island_notch_location），相机节点与身份属性都在 `identityPropertyPatches`/`experimentalNodeAdditions`，仅 exp 运行。事实：本地 jb 不装相机 DeviceTree 节点，上游 standard 装。（本地相机 DSC 与 watchdogd 等 exp 步骤同理只在 exp。）
4. 上游 experimental = 全选（含 hv_vmm、身份、frida、mis_trust_auth，受各自版本门）；本地 exp = jb + KernelEXPPatcher（hv_vmm 内核改名）+ DeviceTree 身份/相机节点 + `cfw_install_exp.sh` 的 hv_vmm DSC/watchdogd/post-restore DT/相机 DSC/build spoof。本地 exp 不含 mis_trust_auth。事实：上游 experimental 比本地 exp 多 `dyld-exp-mis_trust_auth` 一项。
5. 上游 frida 两项由 `--frida` 之外无独立变体，standard 屏蔽、experimental 选中且版本门 cloudOS≥26.4；本地 frida 两项在 jb 与 exp 变体下均可用，但要 `--frida` 且 cloudOS≥26.4（`applyFrida = enableFrida && cloudOSIsFridaCapable`）。事实：本地 frida 可用于 jb，上游 standard/experimental 的 frida 归属由 Selection 决定，与“变体”不对应。
6. 上游 dev 概念：上游 `FirmwarePipeline.Variant` 仍有 `.dev`（`TXMDevPatcher` 替换 `TXMPatcher`），但上游 preset 不按 dev/regular 区分——`fw patch` 固定以 `variant: .jb` 调用（`VPhoneFirmwareCommand.swift:325`），补丁取舍交给 preset。本地仍以变体（make target）区分 regular/dev/jb/exp。事实：上游“变体”退化为内部实现细节，选择权移到 preset；本地选择权仍在变体。
7. less：上游 2.2.3 保留 `.less` 变体（`CryptexFilesystemPatcher`、`ManifestHashPatcher`），但不给它 patch set 声明；本地 less 同样无声明。less 的 guest 步骤（GPU、mobileactivationd、launchd_cache_loader、vphoned、binpack）在本地由 Swift `CryptexFilesystemPatcher` 内联执行，条件是 `noBinpack`/`noVphoned`，与 `system-*` 声明不是同名同源。

## 7. uncertain 条目清单

| ID | 缺什么 |
| --- | --- |
| system-launchdaemons-boot-environment | 上游该声明安装 `VPhoneGuestEnvironment.libraries`（launchdhook、SystemHook、libvcamcaptured、libcamfix、libmisfix）到 `/usr/lib`、建 `/vh` 别名、写 `libmisfix.plist`（`VPhoneCustomFirmwareInstaller.swift:896` `installEnvironment`）。本地没有等价单一步骤：jb/exp 用 BaseBin + `inject-dylib "/b"` 装 launchdhook，exp 另把 libvcamcaptured、libcamfix 装到 procursus 的 MobileSubstrate 目录；本地无 SystemHook、无 libmisfix。库清单、装载路径（`/usr/lib` vs procursus tweak）、注入机制（spawn hook vs BaseBin/TweakLoader）都不同，不能判为同一补丁。需人工确认本地“环境”与上游“environment 声明”是否视为同一条、以及库清单如何统一（与差异报告 §4 “guest 库清单”条目相关）。 |

补充（非 uncertain，但需留意的粒度/调用差异，见 JSON `notes`）：
- `kernel-boot-amfi_execve`：上游与本地均声明并实现 `patchAmfiExecveKillPath`，但两侧 orchestrator 都不调用（文件头注释 disabled）。上游仍把它声明为 `bootEssential=true`，2.2.3 下不发出记录。两侧状态一致，标 `mapped`。
- 本地若干 step 与上游声明非 1:1：上游 `kernel-boot-apfs_vfsop_mount`/`apfs_mount_upgrade_checks`/`handle_fsioc_graft`/`handle_get_dev_by_role` 四条声明，本地合并在一个 step `patchApfsMount`（四个子函数）；上游 5 条 `kernel-*-sandbox_*` 对本地一个 step `patchSandbox`（hooks 表）；上游 `kernel-boot-post_validation`、`kernel-boot-iomfb_swapend` 各一条对本地两个 step。JSON 各条 `notes` 已记录。

## 8. T10/T11 实施前需人决定的问题

1. `dyld-exp-mis_trust_auth` 是否纳入本地。上游用它在 26.x 旧环境作为 libmisfix 的替代开关、并在 27 禁用。本地既无该 DSC 补丁也无 libmisfix 用户态方案。T10 定义变体集合前需决定：本地是否引入该声明（以及是否引入 libmisfix 环境），还是在本地映射中永久标 `upstream_only`。这直接影响 T11 的 Gate 是否需要为本地不存在的 record 放行。
2. 本地“变体”与上游“preset/Selection”的对应模型。T10 要定义 regular/dev/jb/exp/less 的集合与显式 opt-in。需先决定：是把本地五变体重新表达为“preset + 版本门 + 勾选”（向上游 PatchKit 靠拢），还是保留变体维度、仅在其上叠加声明级选择。§6 的 7 条不对应事实说明二者不能按名称直接套用，必须由人给出对齐规则（尤其 standard↔jb 的 DeviceTree 身份/相机节点差异：本地 jb 是否应像上游 standard 那样装相机节点）。
3. 记录机制不统一。上游 `dyld-*`/`system-*` 18 条声明不发 `PatchRecord`、靠安装器 `on("<id>")` 门控；本地这些步骤是 Python/zsh，没有 record、也没有 `VPhonePatchGate`。T11 要求“写入记录必须有声明归属、未声明 record 按本地规则拒绝”。需决定：本地是否为 guest 侧步骤引入声明/门控层，否则 T11 的严格计划只能覆盖 Swift 引导链/内核补丁，guest 侧仍无归属检查。
4. 上游 `VPhonePatchGate` 对未声明 record “失败开放”（`allows(record:)` 返回 true 并告警），而 `VPhonePatchPlan.isRecordEnabled` 对未声明 record 返回 false（差异报告 §4）。T11 要求本地入口严格：需人决定本地采用哪种语义（失败开放+告警 vs 严格拒绝），以及是否保留上游这处不对称。
5. 五变体的版本门归属。本地版本条件用 `PatchRule`（iosBaseIs18/iosBaseIs27/cloudOSFridaCapable/excGuardActive）表达，上游用 `VPhonePatchApplicability`（结构化 iOSBase/cloudOS 要求）。两套并存时，T10/T11 需决定以哪一套为准、如何互译（例如上游 `iOSBase: .major(27)` ↔ 本地 `PatchRule.iosBaseIs27`；上游 frida `cloudOS: .atLeast(26,4)` ↔ 本地 `cloudOSFridaCapable` 还额外要求 `--frida`）。

## 9. 与 0_binary_patch_comparison.md 的关系

本任务未新增或改动补丁，仅建立声明层映射，未触及 `research/0_binary_patch_comparison.md`。若后续按 T10/T11 引入本地声明/Gate 或新增补丁，再按 CLAUDE.md 要求同步该文档。
