# 结构化补丁结果与消融实验（C2）

日期：2026-09-09。范围：实现 checklist C2，新增结构化补丁结果模型、必要性规则、稳定补丁标识、流水线失败判定与消融（ablation）CLI，并迁移两个示例补丁器。设计依据见 `c2_design.md`。未应用新的二进制补丁，未修改 `research/0_binary_patch_comparison.md`。

## 1. 结果模型

在不改变任何补丁方法字节语义的前提下，新增并行的结构化结果类型（`sources/FirmwarePatcher/Core/`）：

- `PatchOutcome`：单个补丁方法（step）的结果种类。
- `PatchRequirement` + `PatchRule`：必要性与命名谓词。
- `PatchID`：稳定的方法级标识。
- `PatchResult` / `PatchGateSnapshot` / `ComponentReport` / `Coverage` / `PatchRunReport`：可序列化的结果记录与运行汇总。
- `StructuredPatcher` 协议 + `PatchStep` + `RawStepResult` + `StructuredExecution`（step 执行器）+ `LegacyPatcherAdapter`。

`PatchRecord`（`Core/PatchRecord.swift`）保持不变，仍是字节级写入记录。`PatchResult.recordIndices` 建立「方法结果 → 它 emit 的字节记录」的关联，指向所属 `ComponentReport.records` 数组的下标。

## 2. 结果种类与输出映射

方法运行返回 `RawStepResult`（`matched` / `idempotent` / `noMatch` / `ambiguous(count)` / `encodeFail(reason)`）。执行器按 `RawStepResult × PatchRequirement × PatchGateSnapshot` 映射为 `PatchOutcome`（`PatchOutcomeMapping.outcome`）。

| RawStepResult | 条件 | PatchOutcome | 是否使组件失败 |
| --- | --- | --- | --- |
| matched | — | applied | 否 |
| idempotent | — | alreadyApplied | 否 |
| ambiguous(n) | — | failed（"expected 1 match, found n"） | 仅当有效必要 |
| encodeFail(r) | — | failed（"encode failed: r"） | 仅当有效必要 |
| noMatch | requirement 为 conditional(rule) 且 rule 对门控快照求值为 false | notApplicable（记录 rule 名与门控快照） | 否 |
| noMatch | 其他（required / optional / rule 为 true） | failed（"anchor not found"） | 仅当有效必要 |

约束：`notApplicable` 只由 conditional rule 判定 false 时产生；无匹配的默认结果是 `failed`。`ambiguous`/`encodeFail` 一律 `failed`，不因 `optional` 而软化。此映射实现 checklist「禁止将无匹配默认视为不适用」。

`optional` 的 `failed` 结果种类保留为 `failed`，但不使组件失败——「结果种类」与「是否使流水线失败」解耦。

## 3. 必要性规则

`PatchRequirement` 三种：

- `required`：必须 applied/alreadyApplied，否则 failed 使组件失败。
- `optional`：缺失不使流水线失败。
- `conditional(PatchRule)`：由谓词决定本输入是否要求该补丁。

`PatchRule` 与流水线门控 1:1 对齐：`always`、`iosBaseIs18`、`iosBaseIs27`、`cloudOSFridaCapable`（= `enableFrida && cloudOSIsFridaCapable`）、`excGuardActive`（= `variant == .dev || iosBaseIs18 || forceExcGuard`）。`PatchGateSnapshot` 记录原始门控与派生门控（`excGuardActive`/`applyIOS27`/`applyFrida`），供离线复核。

「有效必要」定义：`required`，或 `conditional` 且其 rule 对本次门控快照求值为 true。`PatchResult.isRequiredFailure` = 结果 `failed` 且有效必要。

## 4. 稳定补丁标识

`PatchID = <component>.<patcher>.<method>`（全小写点分 leaf 由作者显式声明）：

- `component`：流水线组件逻辑名（`avpbooter`/`ibss`/`ibec`/`llb`/`txm`/`kernelcache`/`devicetree`/`filesystem`/`manifest`）。迁移的两个补丁器其 `Patcher.component` 恰为该逻辑名（`avpbooter`、`ibss`），直接复用。
- `patcher`：补丁器类型简名（`AVPBooterPatcher`、`IBootJBPatcher`）。
- `method`：Swift 方法名，与 `research/firmware_compatibility.json` 的 `methods[].name` 一致（C1 对齐键）。

`PatchID` 编码为单个点分字符串，使报告 JSON 与 `--ablate` 取值使用同一标识。`PatchRecord.patchID`（字节级键，不稳定、非 1:1）保持不变；两套字符串通过 `recordIndices` 关联，不要求相等。

C1 对齐由测试保证（`C1AlignmentTests`）：`AVPBooterPatcher`（单补丁器组件）声明的 step method 集合与清单 `AVPBooter.methods[].name` 相等；`IBootJBPatcher`（iBSS 为多补丁器组件）声明的 step method 集合是清单 `iBSS.methods[].name` 的子集，且 `patchSkipGenerateNonce` 的 `required` 标记一致。

## 5. 流水线失败判定

替换旧 `patchData` 的「空数组即失败」（`Pipeline/FirmwarePipeline.swift` 旧 `:203-205`）：

- 组件失败 ⇔ 存在有效必要且 `failed` 的结果（`ComponentReport.hasRequiredFailure`）。
- `optional` 的 failed、`notApplicable`、`ablated`、`applied`、`alreadyApplied` 均不使组件失败。
- 被 `ablated` 的 required 结果不使组件/流水线失败，但计入 `PatchRunReport.ablation`，整次运行标为 `isAblationRun`。
- 退出码：存在任一有效必要的 `failed`（跨所有组件）时，CLI 以非零退出（入口检查 `PatchRunReport.failedRequired` 后抛错）。其他组件的成功不掩盖该失败。

执行路径：`patchAllStructured(ablate:allowOutput:)` 逐组件运行 `patchDataStructured`，收集 `ComponentReport`，成功且非 dry 时保存该组件，最后返回 `PatchRunReport`（不因 required failed 抛错，由调用方检查 `failedRequired`）。`patchAll()` 改为薄封装：以无消融、允许写回调用结构化路径，成功返回展平后的 `[PatchRecord]`，存在 required failed 时抛错。CLI 入口（`patch-firmware`、`fw patch`）改走结构化路径。

与旧路径的行为差异（成功路径字节相同）：旧 `patchAll` 在首个失败组件处立即抛错并停止；新路径处理全部组件后再抛错，以便在失败时也产出完整报告；失败组件不保存。此差异仅在存在 required failed 时可见。

## 6. 消融 CLI 与 dry-run 护栏

选项（`patch-firmware`、`fw patch`，并镜像到 `patch-component`）：

- `--ablate <id>[,<id>...]`：可重复、逗号分隔。取值按 `PatchID.description` 的三粒度精确匹配：组件（`avpbooter`）、补丁器（`avpbooter.AVPBooterPatcher`）、全名（`avpbooter.AVPBooterPatcher.patchDGSTBypass`）。
- `--allow-ablation-output`：显式放行，将消融后的（部分打过补丁的）固件写回 bundle。
- `--report-out <path>`：写 `PatchRunReport` JSON（`.prettyPrinted, .sortedKeys`）。`--records-out` 语义不变，仍只写 `[PatchRecord]`。

行为：

- 未知 id：在加载任何组件前校验（校验位于 `prepare()` 之前，仅依赖 `buildComponentList()` 声明的 step id 全集，不读磁盘）。任一取值匹配不到即抛 `PatcherError.invalidFormat` 并非零退出，不静默忽略。
- 消融拦截点在方法运行前：命中 ablation 的 step 记 `PatchResult(outcome: .ablated)`，`run` 闭包不调用，不写任何字节（对内核 `emit` 即时写回尤其关键，为 C3 内核迁移铺好）。
- dry-run 护栏：有 `--ablate` 且未加 `--allow-ablation-output` 时整次运行为 dry——所有 `loader.save` 被跳过，`--records-out`/`--report-out` 照常写，并打印 `ABLATION RUN (dry)` 行。
- 日志前缀（新前缀，不改动任何既有 `[-]` 行）：`[=]` applied/alreadyApplied、`[~]` notApplicable、`[x]` FAILED、`[A]` ABLATED、`[L]` legacy。

## 7. 消融运行作为 C1 证据

一次 ablation run 的 `PatchRunReport` 是「移除某必要补丁后指定组合能否启动/能力通过」的实验数据载体。可引用的字段：

- `ablation`（被移除的 `PatchID` 列表）、`isAblationRun`。
- 对应 `PatchResult`：`id`、`requirement`、`rule`、`outcome`、`reason`、`gates`。
- `gates`（`PatchGateSnapshot`）记录求值时的门控，供离线复核。

C1 的 `expected_not_applicable` 可与本模型的 `notApplicable(reason)`（同一 rule）交叉校验。C3 之后可将 ablation report 文件登记到 C1 组合条目的 `evidence[].source`。

## 8. 迁移范围（结构化 vs legacy）

本次迁移两个补丁器为 `StructuredPatcher`，方法体与 emit 的 `PatchRecord` 与迁移前逐字节相同：

- `AVPBooterPatcher.patchDGSTBypass`（`required`）：覆盖 applied/failed（无匹配）路径。
- `IBootJBPatcher.patchSkipGenerateNonce`（`required`）：覆盖 alreadyApplied（幂等 nonce）路径。

其余补丁器（`IBootPatcher`、`TXMPatcher`/`TXMDevPatcher`、`KernelPatcher`、`KernelJBPatcher`、`KernelEXPPatcher`、`DeviceTreePatcher`、`CryptexFilesystemPatcher`、`ManifestHashPatcher`）走 `LegacyPatcherAdapter`：运行原 `findAll()`+`apply()`，产出一条 `coverage: legacy` 的聚合结果——记录为空即 `failed`（保持旧「空即失败」语义），否则 `applied`。`coverage: legacy` 使未迁移补丁器在报告中明确显示为未迁移。legacy 补丁器的方法不可单独消融（未声明 `PatchID.method`）；`--ablate` 命中其 component/patcher 级前缀时可整体消融并标 legacy。

结构化执行只运行一次 step 序列（不复用旧 `findAll→apply` 两段式）：step 的 `run` 闭包调用现有私有方法（追加 record），执行器读记录增量得 `recordIndices`，随后 `commit(records)` 把已收集的 record 写回 buffer。被消融的 step 因未收集 record，`commit` 不写其字节。

## 9. 字节 parity 证明（已完成部分 + 受阻部分）

- 已完成——单元级 record 相等（真实固件字节）：对同一输入 payload，迁移前 `findAll()` 与新 step 路径产出的 `[PatchRecord]` 逐条相等。测试 `MigratedPatcherParityTests`：
  - `avpBooterFindAllEqualsStepPath_realData`：输入取自 `vm-2607/AVPBooter.vresearch1.bin`（只读），断言 old==new 且非空，通过。
  - `iBootJBFindAllEqualsStepPath_realData`：输入取自 `vm-2607` 的 iBSS IM4P 解压 payload（只读），断言 old==new，通过。
  - `avpBooterFindAllEqualsStepPath_syntheticNoMatch`：垃圾输入下两路径均无 record，通过。
- 受阻——CLI 级 parity（`patch-firmware --records-out` 前后 JSON diff）：已签名的 release 二进制被宿主 amfidont 守护进程 SIGKILL（退出码 137），无法运行；故未执行 CLI 级对比。
- 受阻——离线 scratch VM 的 dry-run sha256 对比：`vm-2607` 的 iBSS 文件命名为 `iBSS.d47.RELEASE.im4p`，与当前流水线搜索模式 `iBSS.vresearch101.RELEASE.im4p` 不符，`findFile` 无法匹配，全流水线运行不可行；从本地 IPSW 离线创建匹配命名的 VM 未执行。dry-run「不写回」契约由合成用例（消融 step 不产出 record/不写字节）与 save 跳过逻辑保证；`dryAblationRunDoesNotSave` 测试在设置 `VPHONE_TEST_VMDIR`（指向命名匹配的已准备 VM）时才实际驱动全流水线并断言 `saveCount == 0`，默认跳过以保证快速套件通过。

结论：本次达到的 parity 证明为「迁移补丁器的单元级 record 相等（含真实固件字节）」。成功路径的字节输出不变由「结构化路径不改变方法调用顺序与 emit/append 时机，只在方法前加消融拦截、方法后读增量」保证。

## 10. 合成测试

`SyntheticStructuredPatcher`（以 `BytePatchPatcher` 为蓝本）配合新增 internal `patchDataStructured` 驱动，覆盖 C2 十个用例（`StructuredPatchResultTests`）：必要失败、rule 驱动的 notApplicable vs failed（同一 step 两种门控两种结果）、alreadyApplied、歧义即 failed（即使 optional）、同组件部分成功、补丁组缺一条 record 失败、消融必要补丁不使组件失败、未知 id 报错、legacy 覆盖与空即失败语义。另有 `dryAblationRunDoesNotSave`（spy loader）与 C1 对齐测试。

## 11. 局限

- 只迁移两个单方法补丁器；内核多方法补丁器与 DeviceTree/Manifest/Filesystem 仍为 legacy。
- legacy 组件只有一条聚合结果，无法区分「必要方法静默跳过但组件仍非空」（依赖既有 `[-]` grep，`tests/test_firmware_patches.sh` 判据在 C3 前继续可用）。
- 结构化补丁器若声明零 step，其组件不因空而失败（与 legacy 的「空即失败」不同）；当前两个迁移补丁器在流水线中不会出现该情况。
- CLI 级 parity 与全流水线 dry-run sha256 未执行（原因见第 9 节）。

## 12. C3 待办

- 分组迁移内核补丁器（`KernelPatcher`/`KernelJBPatcher`/`KernelEXPPatcher`），按 XNU 语义声明每方法的 `PatchID`、`requirement` 与 `PatchRule`，覆盖 `applyIOS27`/`applyFrida`/`excGuardActive` 门控。
- 将 `tests/test_firmware_patches.sh` 的判据从 `[-]` grep 切换到 `--report-out` JSON（`outcome==failed && requirement 有效必要`），届时 `[-]` 判据退役。
- 用真实固件确认每个 required 方法确实匹配（迁移到结构化后，此前靠 `[-]` grep 通过的组合会真正 `failed`——预期的收紧）。
