# C3 第一组迁移：基础引导链（IBootPatcher / TXMPatcher / TXMDevPatcher）

日期：2026-09-09。范围：把 C2 建立的结构化补丁结果 + 消融模型（`StructuredPatcher`）扩展到基础引导链中尚未迁移的补丁器。本组不改动内核、DeviceTree、Manifest、Filesystem 补丁器（留待后续 C3 组），不重迁 `AVPBooterPatcher`。不应用任何新二进制补丁，`research/0_binary_patch_comparison.md` 未改。

事实与推断区分：本文「迁移的方法与要求」「清单修正」「parity 结果」均为代码/清单/测试可验证的事实；`patchRootfssBypass` 的必要性判定标记为待验证假设。

## 1. 迁移的补丁器

| 组件 | patcher | 迁移方式 |
| --- | --- | --- |
| iBSS/iBEC/LLB（base） | `IBootPatcher` | 类体内声明 `buildSteps()`/`emittedRecords`/`commit(_:)` 并 conform `StructuredPatcher` |
| iBSS（jb/exp） | `IBootJBPatcher` | 由 extension 一致性改为类体内 `override func buildSteps()`（只返回 nonce step） |
| TXM（regular） | `TXMPatcher` | 类体内声明结构化一致性；单一 `patchTrustcacheBypass` step |
| TXM（dev/jb/exp） | `TXMDevPatcher` | `override func buildSteps()` 返回 6 个 step（不 compose super） |

`findAll()`/`apply()` 全部保留（`Patcher` 协议要求，且 `patch-component` CLI 直接调用）。`buildSteps()` 调用与 `findAll()` 相同的方法集合，成功路径的 record 与 `findAll()` 逐字节相同。

### 子类重构原因

`IBootPatcher` 与 `IBootJBPatcher`、`TXMPatcher` 与 `TXMDevPatcher` 强耦合：非 final 类通过 extension 提供的协议 witness 为静态派发，子类无法 override；同时子类自动继承父类的协议一致性，若父类新增 extension 一致性会与子类已有 extension 冲突（redundant conformance，编译错误）。因此把 witness 方法声明在**类体内**（`public`，动态派发），一致性声明放基类，子类用 `override func buildSteps()` 提供各自的 step 集合。`IBootJBPatcher` 只返回 nonce step（不 compose base 的 serial/image4，否则 iBSS 组件会把这两个方法各跑两遍——一遍来自 `IBootPatcher(.ibss)` 工厂、一遍来自 `IBootJBPatcher(.ibss)` 工厂——破坏字节 parity）。此重构与基类迁移在同一改动内完成，避免中间态编译失败。方法体与 emit 的 record 不变。

## 2. 每模式方法集合与顺序（buildSteps 复现 findAll）

| 模式（=组件） | 方法顺序 |
| --- | --- |
| iBSS | patchSerialLabels, patchImage4Callback |
| iBEC | patchSerialLabels, patchImage4Callback, patchBootArgs, patchBootxPrecondition |
| LLB | patchSerialLabels, patchImage4Callback, patchBootArgs, patchRootfssBypass, patchPanicBypass |

`buildSteps()` 按 `mode` 分支产出对应集合，与 `IBootPatcher.findAll()` 的执行顺序一致。`IBootJBPatcher.buildSteps()` 在 `mode == .ibss` 时返回 `[patchSkipGenerateNonce]`，其他模式返回空。`TXMDevPatcher.buildSteps()` 按 `findAll()` 顺序返回 patchTrustcacheBypass, patchSelector24ForcePass, patchGetTaskAllowForceTrue, patchSelector42_29Shellcode, patchDebuggerEntitlementForceTrue, patchDeveloperModeBypass。

## 3. 必要性判定与理由

- **patchImage4Callback → `.required`**（iBSS/iBEC/LLB 三模式）。理由：`image4_validate_property_callback` 绕过是引导链接受被改固件镜像的核心，且是每个 iBoot 组件唯一保证「组件必须产出补丁否则失败」的锚。若全部 iBoot 方法都 `.optional`，结构化路径在**零记录**时不会失败（`StructuredExecution.run` 在 records 为空时只返回 fallback，不做「组件空即失败」检查），弱于 legacy 的「空即失败」。将该方法定为 required 同时修复此回归并对齐其真实作用。此收紧属 C2 预期行为。
- **patchSerialLabels、patchBootArgs、patchBootxPrecondition、patchRootfssBypass、patchPanicBypass → `.optional`**。这些方法清单原本 required=false。`patchBootxPrecondition` 语义上是 genuinely-conditional（仅 26.4+ iBoot 存在），但现有 `PatchRule` 集合无 iBoot 版本门，无法表达为 `.conditional`，故只能 `.optional`；其歧义（多候选）仍经 `PatchOutcomeMapping` 的 `ambiguous → failed` 硬失败，不因 optional 软化。`patchRootfssBypass` 的必要性为待验证假设（见 §6）。
- **TXMPatcher.patchTrustcacheBypass → `.required`**：方法已在无锚点时 `throw PatcherError.patchSiteNotFound`，step 捕获后转 `.noMatch`（照 `AVPBooterPatcher` 模式）。
- **TXMDevPatcher 全部 6 方法 → `.required`**：与清单既有 required=true 一致，属对齐既有声明的预期收紧（迁移前 dev 补丁 silent-skip 时组件仍因 trustcache 1 条非空而「通过」）。

## 4. 返回信号（字节不变，仅供 step 精确判定）

为让 step 在不改字节的前提下区分「完整 / 部分 / 无匹配 / 歧义」，给以下方法增加返回值（沿用 `IBootJBPatcher.patchSkipGenerateNonce` 返回 Bool 的先例），emit 调用与字节完全不变：

- `IBootPatcher`：`patchSerialLabels`、`patchBootArgs`、`patchBootxPrecondition`、`patchRootfssBypass` 返回 `IBootStepSignal`（matched / noAnchor / partial / ambiguous）。`patchImage4Callback` 与 `patchPanicBypass` 无部分 emit 风险，step 用 record-delta 判定，方法保持 Void。
- `TXMDevPatcher`：`patchSelector24ForcePass`（2 条）、`patchSelector42_29Shellcode`（6 条）返回 `TXMDevStepSignal`（matched / noAnchor / partial）。其余单条方法用 record-delta。

映射：matched→`.matched`；noAnchor→`.noMatch`；partial→`.encodeFail`（→ failed，即使 optional，因为字符串已写而指针未改写属破坏性半成品）；ambiguous→`.ambiguous`。

## 5. 映射修正：optional + noMatch → notApplicable

`PatchOutcomeMapping.outcome(for:requirement:gates:)` 原将 `.optional` + `noMatch` 判为 `failed`（此前仅因 optional 的 failed 不计入 `hasRequiredFailure` 而无害，但会在报告里把「合法缺失的可选锚」错标为 failure）。本组修正为：`.optional` + `noMatch → notApplicable(reason: "optional, no anchor")`；仅 `.required` 与规则为真的 `.conditional` 在无匹配时判 `failed`；`.conditional` 规则为假仍 → `notApplicable`（原有行为）。`ambiguous`/`encodeFail` 一律 `failed`（不变）。

此修正对基础引导链是必要的：`patchSerialLabels`（含装饰性幂等分支）、`patchBootxPrecondition`（26.4 前构造真缺失）等可选方法在无锚点时应报 `notApplicable` 而非 `failed`。已核对 `conditionalRuleControlsNotApplicableVsFailed`、`ambiguousFailsEvenWhenOptional`、`partialSuccessKeepsAppliedResults` 三项既有合成用例不回归，并新增合成用例 `optionalMissingBecomesNotApplicableNotFailed` 固化该行为。

## 6. 清单修正（research/firmware_compatibility.json）

C1 对齐测试要求「迁移补丁器的 step 方法叶子集合 == 该组件清单 `methods[].name`」。修正如下（应用到 less/regular/dev/jb/exp 中同名组件，因 iBEC/LLB 在所有变体运行）：

- iBSS/iBEC/LLB 新增 `patchImage4Callback`（required=true）。
- 按实际 mode 分支修正方法集合：iBSS 仅 `{patchSerialLabels, patchImage4Callback}`（jb/exp 追加 `patchSkipGenerateNonce`）；iBEC 去 `patchRootfssBypass`/`patchPanicBypass`；LLB 去 `patchBootxPrecondition`。
- TXM（dev/jb/exp）把 `patchSelector24Shellcode` 更名为 `patchSelector24ForcePass`（对齐 Swift 方法名；不改 Swift 名，符合内核补丁 guardrail 的保守取向）。

`required`/`gate`/`expected_not_applicable` 字段保持与 §3 一致（`patchBootArgs` 的 `extraBootArgs` 注入说明保留）。`python3 -m unittest tests.test_firmware_compatibility` 全过；两个 Swift 清单测试（catalog 配对、变体集）不交叉校验方法名，不受影响。

## 7. 字节 parity 证明

手段：env 门控真字节 parity（沿用 C2 `MigratedPatcherParityTests` 模式）。输入为 IM4P 容器，测试内经 `IM4PHandler.load(contentsOf:).payload` 解压后再比对，避免人工解压。

- 输入目录：`vm-2607/iPhone17,3_26.1_23B85_Restore/Firmware`
  - `VPHONE_TEST_IBSS_IM4P=.../dfu/iBSS.vresearch101.RELEASE.im4p`
  - `VPHONE_TEST_IBEC_IM4P=.../dfu/iBEC.vresearch101.RELEASE.im4p`
  - `VPHONE_TEST_LLB_IM4P=.../all_flash/LLB.vresearch101.RELEASE.im4p`
  - `VPHONE_TEST_TXM_IM4P=.../txm.iphoneos.research.im4p`
- 判据：迁移前 `findAll()` 与新 step 路径产出的 `[PatchRecord]` 逐条相等，且非空。
- 结果：9 项 parity 用例全过。

关于计数与输入选择：`vm-2607` 是已安装/部分改写的 VM 固件，其 llb/txm_dev 部分锚点已被前次改写而不再命中（在该输入上实测 llb=7、txm_dev=3，低于参照）。为覆盖全部方法，验收改用未改写的库存输入：从 cloudOS IPSW `ipsws/399b664dd623358c3de118ffc114e42dcd51c9309e751d43-727c4f5e2432.ipsw` 抽取 `iBSS/iBEC/LLB.vresearch101.RELEASE.im4p`，txm 取自基础 IPSW `ipsws/iPhone17,3_26.1_23B85_Restore.ipsw` 的 `txm.iphoneos.research.im4p`（这些正是 `fw_prepare` cloudOS 合并注入流水线的原始引导链二进制）。用这组库存输入设置 `VPHONE_TEST_*_IM4P` 后 9 项 parity 用例全过，覆盖 iBSS/iBEC/LLB 三模式与 TXMPatcher/TXMDevPatcher 的完整方法集。stock 参照计数为 ibss 4 / ibec 7 / llb 13 / txm 1 / txm_dev 12（`0_binary_patch_comparison.md:863-868`）。parity 判据是「同一输入上 old `findAll()` == new step 路径逐字节相等」，在库存与已安装两类输入上均成立。

## 8. 未改动项与验证

- `extractPatchedData`/legacy 检测未改：结构化路径用 `patcher.patchedData` 取字节，迁移后 `IBootPatcher`/`TXMPatcher`/`TXMDevPatcher` 被 `patcher as? any StructuredPatcher` 命中并走 `StructuredExecution.run`；`extractPatchedData` 内 `as? IBootPatcher`/`as? TXMPatcher` 分支对结构化路径成为死代码但无害（仍供 legacy `patchData` 与手工 fallback）。
- 验证命令：`swift build` 成功；`python3 -m unittest tests.test_firmware_compatibility` 14 项全过；`make test`（Python 69、Swift 270）全过；`swift test --filter MigratedPatcherParityTests` 9 项全过；`make build` 签名成功。

## 9. 限制与后续

- **待验证假设**：`patchRootfssBypass`（LLB rootfs 签名/大小校验绕过）是否 LLB 引导被改 rootfs 的硬需求未查明，暂定 `.optional`；建议用全流水线 dry-run + 启动/消融实验确认后再决定是否收紧为 `.required`（代码中已加注 待验证 注释）。
- **剩余 C3 组**：基础内核（`KernelPatcher`，28 方法）、JB 内核（`KernelJBPatcher`，59 方法，含 iOS-27/--frida 门控）、EXP 内核（`KernelEXPPatcher`）仍为 legacy 覆盖；DeviceTree/Manifest/Filesystem 亦未迁移。内核补丁器需额外注意「emit-on-find 即写回」风险（本组的 collect-then-apply 补丁器不存在该风险），消融拦截与字节 parity 策略需按内核补丁器实际写回时机重新评估。
