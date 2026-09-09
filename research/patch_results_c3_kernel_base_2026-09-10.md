# C3 第二组迁移：基础内核（KernelPatcher）

日期：2026-09-10。范围：把 C2 建立的结构化补丁结果 + 消融模型（`StructuredPatcher`）扩展到基础内核编排器 `KernelPatcher` 及其 `Kernel/Patches/` 下的 12 个补丁方法。严格照第一组引导链（`IBootPatcher`/`TXMPatcher`/`TXMDevPatcher`，见 `research/patch_results_c3_bootchain_2026-09-09.md`）已确立的范式。

本组不改动 `KernelPatcherBase`（JB/EXP 共用）、`KernelJBPatcher*`、`KernelEXPPatcher`（第三、四组），不改 `KernelPatcherBase.emit(...)` 的签名或写字节行为。

**性质：纯加法、字节等价迁移。** 12 个方法体内的 emit/append/writeBytes/匹配锚点逻辑一律未改；只对其中 3 个方法（#7/#10/#11）新增或修改 `return` 表达式与返回类型。未写入任何新补丁字节（见 §7）。

事实与推断区分：本文「迁移范围」「requirement/signal 决策表」「setup 幂等化方案」「字节等价论证」「parity 结果」均为代码/测试可验证的事实；「§8 两处 C1 清单遗留不一致」为对现状的事实描述，其处置为待用户定夺项。

## 1. 迁移范围与文件改动

| 文件 | 改动 |
| --- | --- |
| `Kernel/KernelPatcher.swift` | 新增 `private var didPrepare`、`func ensurePrepared()`；`findAll()` 的 4 行内联 setup 替换为 `ensurePrepared()`（`patches = []` 保持最前） |
| `Kernel/KernelPatcher+Structured.swift`（新建） | `extension KernelPatcher: StructuredPatcher`；`KernelStepSignal` 枚举；`buildSteps()`/`emittedRecords`/`commit(_:)`/`patchedData`；`rawResult(_:)`/`step(_:_:run:)`/12 个 step 工厂 |
| `Kernel/Patches/KernelPatchPostValidation.swift` | `patchPostValidationCMP()` 返回类型 `Bool → KernelStepSignal`（仅改 return） |
| `Kernel/Patches/KernelPatchApfsMount.swift` | 聚合方法 `patchApfsMount()` 返回类型 `Bool → KernelStepSignal`（仅改 return；4 个子方法保持 `Bool`） |
| `Kernel/Patches/KernelPatchSandbox.swift` | `patchSandbox()` 返回类型 `Bool → KernelStepSignal`（仅改 return） |
| `Tests/FirmwarePatcherTests/FirmwarePatcherTests.swift` | 在 `MigratedPatcherParityTests` 新增 2 个 kernel parity 用例（合成 no-match + env 门控真字节） |

`KernelPatcher` 是 `final`、无子类，不存在 IBoot 那种「witness 必须放类体以支持子类动态派发覆盖」的约束，故一致性完整放在 extension 文件。`findAll()`/`apply()` 保留（`Patcher` 协议要求，且 `patch-component` CLI 直接调用 `apply()`）。

## 2. buildSteps 顺序（复现 findAll）

`buildSteps()` 按 `findAll()` 的确切顺序声明 12 个 step：

| # | 方法 | requirement |
| --- | --- | --- |
| 1 | patchApfsRootSnapshot | `.required` |
| 2 | patchApfsSealBroken | `.required` |
| 3 | patchBsdInitRootvp | `.required` |
| 4 | patchLaunchConstraints | `.required` |
| 5 | patchDebugger | `.required` |
| 6 | patchPostValidationNOP | `.required` |
| 7 | patchPostValidationCMP | `.required` |
| 8 | patchDyldPolicy | `.required` |
| 9 | patchApfsGraft | `.required` |
| 10 | patchApfsMount | `.required` |
| 11 | patchSandbox | `.required` |
| 12 | patchExcGuardBehavior | `.conditional(.excGuardActive)` |

方法名与 C1 清单 `research/firmware_compatibility.json` 的 kernelcache 组件 `methods[].name` 逐一对齐（清单同名、同 required：1–11 required=true，12 required=false）。`PatchID(component: "kernelcache", patcher: "KernelPatcher", method:)`。

## 3. signal 来源与决策表（决定改不改方法体）

| # | 方法 | 方法体是否改 | step 判定 | signal 语义 |
| --- | --- | --- | --- | --- |
| 1,2,3,4,5,6,8,9 | 单锚方法 | 否（保持 `Bool`） | record-delta | `patches.count > before ? .matched : .noMatch` |
| 7 | patchPostValidationCMP | 是（`→ KernelStepSignal`） | `rawResult(...)` | 唯一命中并 emit→`.matched`；`uniqueHits.count>1`→`.ambiguous(count)`；无锚/未命中→`.noAnchor` |
| 10 | patchApfsMount（聚合 13–16） | 是（`→ KernelStepSignal`） | `rawResult(...)` | 4 子补丁全成功→`.matched`；部分→`.partial("applied N/4 ...")`；全未命中→`.noAnchor` |
| 11 | patchSandbox | 是（`→ KernelStepSignal`） | `rawResult(...)` | 5 个 hook 全 patch→`.matched`；`0<N<5`→`.partial("patched N/5 ...")`；ops 表未找到或 N==0→`.noAnchor` |
| 12 | patchExcGuardBehavior | 否（保持 `Bool`） | 门控 + record-delta | 见 §5 |

`rawResult` 映射与 IBoot 完全一致：`matched→.matched`、`noAnchor→.noMatch`、`partial(r)→.encodeFail(reason:r)`、`ambiguous(c)→.ambiguous(count:c)`。

单锚 step 统一经私有 `countDeltaStep(...)` 工厂包装：闭包先调 `ensurePrepared()`，再记 `before = patches.count`、跑补丁体、按 delta 返回。这与 IBoot `image4CallbackStep` 的 record-delta 模式相同。#7/#10/#11 的 step 工厂在闭包内先 `ensurePrepared()` 再 `return rawResult(方法())`。

`patchApfsMount` 的子方法（`patchApfsVfsopMountCmp`/`patchApfsMountUpgradeChecks`/`patchHandleFsiocGraft`/`patchHandleGetDevByRoleEntitlement`）保持返回 `Bool` 不变；聚合方法据 4 个 `Bool` 的成功计数组合出 signal。

## 4. setup 幂等化方案（内核 emit-on-find 的关键差异）

重量级 setup（`parseMachO`/`buildADRPIndex`/`buildBLIndex`/`findPanic`）绝不能进 `buildSteps()` 声明体：消融枚举 `FirmwarePipeline.knownAblationTargets` 会用 `makePatcher(Data(), false)` 后立即调 `buildSteps()`，故 `buildSteps()` 必须廉价、在空 `Data()` 上安全（只构造 `PatchStep` 数组，不解析）。做法：

- 在 `KernelPatcher` 类体加 `private var didPrepare = false`（stored property 必须在类体，不能在 extension）。
- 加 `func ensurePrepared()`：`guard !didPrepare else { return }; parseMachO(); buildADRPIndex(); buildBLIndex(); findPanic(); didPrepare = true`（顺序与 `findAll()` 原状一致）。
- `findAll()` 里那 4 行直接 setup 调用替换为 `ensurePrepared()`（`patches = []` 保持最前）。
- 每个 step 的 run 闭包在跑补丁体前先调 `ensurePrepared()`（统一在 step 工厂的 run 包装里调），保证即使首个 step 被消融也不丢 setup。

**访问级别说明（与主控原文 “private func ensurePrepared()” 的偏差）**：`ensurePrepared()` 被跨文件调用（`KernelPatcher.swift` 的 `findAll` 与 `KernelPatcher+Structured.swift` 的 step 闭包），Swift `private` 为文件作用域无法跨文件访问，故 `ensurePrepared()` 声明为 `internal`（默认，不加修饰符）。`didPrepare` 仅在 `ensurePrepared()` 内访问（同文件），保持 `private`。这是使设计可编译的最小必要偏差，不改变「setup 恰好执行一次」的行为。

**幂等性验证**：`didPrepare` 的 `guard` 保证 `parseMachO`/`buildADRPIndex`/`buildBLIndex`/`findPanic` 每实例只执行一次，不会因二次调用重复 append 索引导致行为变化。生产路径中同一实例最多触发一次 setup：`findAll()` 最多被调一次（`apply()` 仅在 `patches.isEmpty` 时调 `findAll`），结构化路径不调 `findAll` 而由首个执行的 step 触发。字节 parity 用独立实例分别跑 legacy/结构化（见 §7），两实例各自 setup 一次，顺序一致。

## 5. excGuard 的 conditional 建模与 isDev 门控复现

`patchExcGuardBehavior`（#12）**无条件声明**（保证可作消融目标），`requirement = .conditional(.excGuardActive)`。step run 闭包：

```
ensurePrepared()
guard isDev || applyExcGuard else { return .noMatch }
let before = patches.count
patchExcGuardBehavior()
return patches.count > before ? .matched : .noMatch
```

即只有 `isDev || applyExcGuard` 时才真正跑补丁体（与 legacy `KernelPatcher.findAll()` 的 `if isDev || applyExcGuard { patchExcGuardBehavior() }` 完全一致），否则不跑、返回 `.noMatch`；配合 `.conditional(.excGuardActive)`，门为假时经 `PatchOutcomeMapping` 归 `notApplicable`。

四种门组合下的 requirement/outcome（requirement 恒为 `.conditional(.excGuardActive)`；`gates.excGuardActive = iosBaseIs18 || forceExcGuard`，见 `FirmwarePipeline.swift:178`；管线为 regular/jb/exp 传入 `applyExcGuard = iosBaseIs18 || forceExcGuard`，dev 传入 `isDev=true, applyExcGuard=false`）：

| isDev | applyExcGuard | step 返回 | rule excGuardActive | outcome | 典型场景 |
| --- | --- | --- | --- | --- | --- |
| F | F | `.noMatch` | false | `notApplicable`（规则假 + 无锚） | regular/jb/exp，26.x 基线，无 `--force-exc-guard` |
| F | T | `.matched` | true | `applied` | 18.x 基线，或 regular/jb/exp `--force-exc-guard` |
| T | F | `.matched` | 见 §8(b) | `applied` | dev 变体（26.x 基线，excGuardActive 可能为 false→命中 mapping 的「matched 但规则假→applied」分支） |
| T | T | `.matched` | true | `applied` | dev + 18.x/force |

以上四组均不产生 required failure（`notApplicable`/`applied` 皆非 `failed`）。

## 6. requirement 决策（1–11 全 required）

1–11 全部 `.required`，与 C1 清单 required=true 一致。这与第一组一样是「结构化路径对 legacy『整器空即失败』的收紧」：legacy 内核路径经 `LegacyPatcherAdapter`，仅当整个 `KernelPatcher` 产出零记录才失败；结构化路径下每个 required 方法无锚点（`.noMatch`）即 `failed` 且 required→`hasRequiredFailure`→组件失败。此收紧对齐清单既有 required=true 声明，属 C2 预期行为。

**实测佐证（非回归）**：在从 cloudOS IPSW 抽取的**库存（未改写）** `kernelcache.research.vphone600` 上，11 个 required 方法族全部命中（见 §7 计数），结构化路径干净通过。真实 `fw_prepare` 管线始终对新抽取的库存内核打补丁，故此收紧在实际管线中不构成回归。在**已安装/已改写**的 VM 内核（`vm-new`/`vm-2607`）上，部分锚点已被前次改写消耗，仅幂等类补丁（launch_constraints/dyld_policy/sandbox 共 14 条）复命中，其余 required 方法返回 `.noMatch`——此时结构化路径会报 required failure，而 legacy 路径（整器非空即通过）容忍之。这是两路径在**已改写输入**上的语义差异，与第一组一致；字节 parity 在两类输入上均成立（§7）。

## 7. 字节等价论证与 parity 结果

**论证**：3 个改返回类型的方法（#7/#10/#11）其 record 全部来自未改动的 `emit(...)` 调用；返回值在 legacy `findAll()` 中本就被 `@discardableResult` 丢弃（`findAll` 返回 `patches`，与这些方法返回值无关）。因此返回值从不影响 `findAll` 的记录输出。

- #10 特别说明：legacy `patchApfsMount` 返回 `r13&&r14&&r15&&r16`，但子补丁 emit-on-find——部分成功时成功的子补丁字节已写入。故 legacy「返回 false（部分成功）」与本组「返回 `.partial`」在**字节结果上完全相同**，只是把 legacy 的布尔忠实表达为 `partial→encodeFail→failed`。
- #7/#11 同理：`return true/false` 改为 signal，emit 调用与匹配逻辑逐字不动。

**parity 测试**：照第一组 `MigratedPatcherParityTests` 的 env 门控真字节模式，新增 `kernelFindAllEqualsStepPath_realData`（`VPHONE_TEST_KERNELCACHE_IM4P` 指向 `kernelcache.*.im4p`，测试内经 `IM4PHandler.load(...).payload` 解压；或 `VPHONE_TEST_KERNELCACHE` 指向已解压原始内核；未设→跳过）与 `kernelFindAllEqualsStepPath_syntheticNoMatch`（垃圾输入，两路径均产 0 记录，无 env 依赖，快套件内实跑）。判据：同一输入上 legacy `findAll()` 与结构化 `buildSteps()→run()` 产出的 `[PatchRecord]` 逐条相等（offset/originalBytes/patchedBytes 全等）且顺序一致，并非空。`applyExcGuard: true` 以在两路径中都跑到 #12。

实测（本会话）：
- 库存内核（cloudOS IPSW `399b664…` 抽取的 `kernelcache.research.vphone600`）：parity 用例通过，**28 条记录**逐字节相等；11 个 required 方法族全部命中（apfs_root_snapshot / apfs_seal_broken / bsd_init_rootvp / launch_constraints(2) / debugger(2) / post_validation(NOP+CMP,2) / dyld_policy(2) / apfs_graft(1) / apfs_mount 的 4 子补丁(apfs_vfsop_mount+apfs_mount_upgrade_checks+handle_fsioc_graft+handle_get_dev_by_role) / sandbox(5 hook×2=10)）。
- 已改写 VM 内核（`vm-new`/`vm-2607`）：parity 用例通过，14 条记录逐字节相等（仅幂等类补丁复命中，见 §6）。
- 合成 no-match：通过（两路径均 0 记录）。

## 8. 两处 C1 清单遗留不一致（本组不修，待用户定夺）

- **(a) gate 字符串 vs PatchRule case rawValue**：清单 `research/firmware_compatibility.json` 的 kernelcache `patchExcGuardBehavior` 项 `gate = "applyExcGuard"`，而代码 `PatchRule.excGuardActive` 的 rawValue 为 `"excGuardActive"`。二者命名不一致（`PatchRule.swift` 注释称每个 case 与清单 gate 字符串 1:1）。现有 Swift 清单对齐测试只比对方法名与 required，不交叉校验 gate 字符串，故不触发失败；但字符串本身不对齐。
- **(b) gate 语义 vs findAll 运行门**：清单/`PatchGateSnapshot` 的 `excGuardActive = iosBaseIs18 || forceExcGuard`（**不含 isDev**），而 `findAll()`（及本组 step run）以 `isDev || applyExcGuard` 运行 excGuard。对 regular/jb/exp 二者等价（`applyExcGuard = iosBaseIs18 || forceExcGuard`，`isDev=false`）；但 dev 变体（`isDev=true, applyExcGuard=false`）在 excGuardActive 为假的基线上会真正运行并命中 excGuard，命中 `PatchOutcomeMapping` 的「`.matched` 但规则为假→记为 `applied`（附警告注释）」分支，而非规则驱动的 `notApplicable`。语义上 dev 的 excGuard 门比 rule 更宽。

两处均为 C1 建模与代码运行门之间的既有不一致，**本组不修**，仅记录为待用户定夺的 C1 后续项。

## 9. `0_binary_patch_comparison.md` 无需改动

本迁移未写入任何新补丁字节（纯加法字节等价，§7 已证），与第一组一致，故 `research/0_binary_patch_comparison.md` 无需改动，未改。
