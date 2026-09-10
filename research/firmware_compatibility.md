# 固件兼容性清单（C1）

日期：2026-09-09。

机器可读真源：[`research/firmware_compatibility.json`](firmware_compatibility.json)（`schema_version: 1`）。
格式校验：[`tests/test_firmware_compatibility.py`](../tests/test_firmware_compatibility.py)（Python unittest，`make test` 自动发现）。
与代码 catalog 的一致性：[`tests/VPhoneCoreTests/FirmwareCompatibilityManifestTests.swift`](../tests/VPhoneCoreTests/FirmwareCompatibilityManifestTests.swift)（swift-testing）。

本文说明清单格式、四阶段与两种计数口径、如何新增记录、当前覆盖情况与待澄清项。

## 1. 维度（dimensions）

- `device`：`iPhone17,3`（`VPhoneFirmwareCatalog.device`，硬编码单值）。
- `variants`：`less` / `regular` / `dev` / `jb` / `exp`（`FirmwarePipeline.Variant`）。
- `kernel_types`：仅 `research`（内核文件名恒为 `kernelcache.research.vphone600`，`FirmwarePipeline.swift:343`）。release/development/kasan **无对应代码输入，含义待确认**；`dev` 是补丁变体（`KernelPatcher(isDev:)`），不是内核映像类型。
- `options`：`--force-exc-guard`、`--frida`、`--no-binpack`、`--no-vphoned`（见 JSON `dimensions.options` 的 `source` 行号）。
- `auto_gates`：从固件读出、非用户选项的自动门控：`iosBaseIs18`、`iosBaseIs27`、`cloudOSIsFridaCapable`（`FirmwarePipeline.swift:138/139/148`）。

`methods[].gate` 使用 `PatchRule` 标识：`excGuardActive = variant == .dev || iosBaseIs18 || forceExcGuard`，`iosBaseIs27`，以及 `cloudOSFridaCapable`（求值读取快照派生字段 `applyFrida = enableFrida && cloudOSIsFridaCapable`）。`KernelPatcher.applyExcGuard` 参数仍表示 `iosBaseIs18 || forceExcGuard`，补丁器另以 `isDev` 启用 dev 行为。规则名称、快照字段及补丁器参数承担不同职责。

## 2. 固件（firmware）

- `firmware.ios`：23 条 catalog 配对（iPhone17,3，含精确构建号；构建号从 IPSW URL 解析）。每条附推荐 `cloudos_name`。
- `firmware.cloudos`：4 个 cloudOS 镜像（按 major）。catalog **不含 cloudOS 构建号**（URL 为 private-cloud-compute 哈希）。已知构建号来自证据/测试脚本：26.1→`23B85`、26.3→`23D128`、26.4→`23E5207q`；26.2 构建号未记录（`build: null`，`build_known: false`）。

> 说明：`c1_inventory.md` 记为「24 条 catalog 配对」，实测 `VPhoneFirmwareCatalog.pairings` 为 **23** 条（15 条 18.6.2–26.6.1 + 8 条 iOS 27 beta）。本清单以 23 为准；Swift 一致性测试直接从 catalog 解析，自动跟随代码。

## 3. 四阶段（stage）

按验证强度递增，语义见 JSON `policy.stage_semantics`：

| 阶段 | 含义 | 证据要求 |
| --- | --- | --- |
| `code_selectable` | 可由代码/catalog 选择并进入流水线，未做补丁或启动验证 | 无 |
| `patch_verified` | 补丁产出预期字节/record 结果（字节 parity 或 record 计数），无需真机 | 建议带证据 |
| `boot_verified` | 真机完成启动（至少一次） | ≥1 条带日期证据 |
| `capability_verified` | 真机验证具体能力（触控/相机/定位/JB/vphoned 等） | `capabilities` 非空 + 带日期证据 |

未列出的组合默认阶段为 `unverified`（`policy.unlisted_combination_stage`）——即「明确显示为未验证」。

## 4. 两种计数（count）

不使用单一总数判断兼容，分列两种口径（`policy.count_semantics`）：

- `method_count`：声明的补丁编排方法数量。一个方法可以产生零条或多条 `PatchRecord`。当前流水线各补丁器均已迁移为 `StructuredPatcher`，按“有效必要且 failed → 组件失败”判定；稳定标识为 `patch_id = <component>.<patcher>.<method>`，`method` 与清单 `methods[].name` 对齐。`C1AlignmentTests` 同时检查方法集合及条件规则名称。详见 [结构化补丁结果与消融](patch_results_ablation_2026-09-09.md)。
- `record_count`：实际写入的 `PatchRecord` 条数，按输入分键：
  - `"<iPhone构建>/<cloudOS构建>"`：特定输入的实测计数（如 `23B85/23B85`）。
  - `"unknown"`：该位置构建号缺失。
  - `"summary(...)"`：研究文档 Summary 表的通用（非特定构建）计数。

同一变体在不同门控下 record 数不同。当前 `KernelJBPatcher` 声明 33 个步骤，加基础内核 12 个步骤，jb 的 kernelcache 组件共 45 个步骤。历史研究记录的 JB 内核方法计数为 59（`0_binary_patch_comparison.md:830`、Cross-Version snapshot `:849-856`），`record_count` 为 26.x 基线 **84**、26.5 基线 **83**、27.0 基线 **95**（`:125`、`:868`）。

## 5. 计数口径差异（需统一）

三套数字互不一致，登记如下并标记待确认，**本任务不修改 CLAUDE.md**：

| 来源 | Regular | Dev | JB | EXP | 口径 |
| --- | --: | --: | --: | --: | --- |
| CLAUDE.md 变体表 patches | 52 | 66 | 127 | 141 | **待确认**（疑过时） |
| CLAUDE.md phases | 10 | 12 | 14 | 18 | **待确认** |
| `0_binary_patch_comparison.md:839` Grand total | 56 | 70 | 132 | 163 | record（含 CFW） |
| `0_binary_patch_comparison.md:836` Boot chain total | 46 | 58 | 117 | 132 | record（仅引导链） |
| 历史 method / record（JB 内核） | — | — | 方法 59 | — | `:830`（method） |
| record（JB 内核，按基线） | — | — | 84（26.x）/ 83（26.5）/ 95（27.0） | — | `:125`、`:868`（record） |

CFW 安装脚本用 `N/7` 阶段标记（`scripts/cfw_install.sh`，base=7 阶段），也不等于 10/12/14/18。清单方法集合以当前代码声明为准；历史 method（59）与 record（84/83/95）保留为历史口径，不代表当前步骤数；CLAUDE.md 的 52/66/127/141 与 10/12/14/18 标记为 **待确认**。

此外 iBSS/iBEC/LLB 存在 Summary 表与 Migration parity 两套 record 计数（iBEC 4 vs 7、LLB 6 vs 13、iBSS base 2 vs 4），JSON 中这些组件 `record_count` 保留 `summary` 键并在 `note` 记录差异，`method_count` 记 `null`（含义待确认）。

## 6. 当前覆盖（combinations，共 38 条）

按变体 × 阶段统计的组合条数（`variants: [...]` 数组按其中每个变体分别计入）：

| 变体 \ 阶段 | code_selectable | patch_verified | boot_verified | capability_verified |
| --- | --: | --: | --: | --: |
| less | 23 | 1 | 0 | 0 |
| regular | 23 | 7 | 0 | 0 |
| dev | 23 | 7 | 0 | 0 |
| jb | 23 | 10 | 0 | 3 |
| exp | 23 | 7 | 0 | 1 |

- `code_selectable`：23 条 bulk 组合，每条 `variants: ["less","regular","dev","jb","exp"]`，cloudOS 构建号 `null`（catalog 仅版本）。
- `patch_verified`：26.1(`23B85`)/cloudOS 26.1(`23B85`) 与 26.3(`23D127`)/cloudOS 26.3(`23D128`) 的 regular/dev/jb 字节 parity（2026-03-10）；26.5(`23F77`) jb 合成组件 83 records 与 main byte-identical（2026-07-20）。
- `patch_verified` 新增 `pv-261-c3-bootchain-20260910`：26.1 / 23B85 精确配对的 regular/dev/jb/exp 非 less 引导链生产流水线、必要集合及落盘 payload 验证通过（2026-09-10）；宿主 AVPBooter 为 macOS 26.5.1 / 25F80，不含磁盘镜像有效性、恢复或启动。历史 `pv-261-parity` 条目保留。详见 [精确引导链验收](c3_full_pipeline_acceptance_2026-09-10.md)。
- `capability_verified`：
  - 27.0(`24A5408d`)/cloudOS 26.4(`23E5207q`) jb `--frida`（2026-08-17）：vphoned、ddi-mount、jb-setup 通过；frida-server 部分（未运行 host client）。
  - 27.0(`24A5380h`) jb（2026-07-15/17）：display、ddi-mount、vphoned。
  - 27.0(`24A5390f`) jb（2026-07-21/22/23）：display(Campo)、jb-setup(respring 修复)。
  - 26.6.1(`23G83`) exp（rig-baseline，2026-09-08/09）：touch、vm-stop 通过；`--no-vphoned` 原生触控路径部分（陈旧帧）。
- `boot_verified`：无独立条目（真机组合均已达 `capability_verified`）。regular/dev 变体**无完整真机 boot 证据**。

清单能解释同一变体在不同输入下的记录差异：例如 jb 变体的 kernelcache `record_count` 随 iOS-27 与 `--frida` 门控在 84/83/95 间变化，通过各方法的 `gate` 与 `expected_not_applicable` 字段可追溯是哪些方法在 18.x/26.x 基线不适用。

## 7. 如何新增记录

1. 在 `research/firmware_compatibility.json` 的 `combinations` 增一条：
   - `id` 全局唯一；`ios`/`cloudos` 的 `version` 必须已在 `firmware` 中登记（否则先补 `firmware` 条目）。
   - 构建号必须匹配 `^[0-9]{2}[A-Z][0-9A-Za-z]+$` 或为 `null`；`null` 时必须在 `limitations` 写明含「构建号」的说明。
   - 提升到 `boot_verified` 及以上需 ≥1 条带 ISO 日期（`YYYY-MM-DD`）的 `evidence`，其 `source` 的文件路径（`:` 前部分）必须在仓库中存在。
   - `capability_verified` 需 `capabilities` 非空，每条 `result` ∈ `passed|failed|partial`。
2. 运行 `python3 -m unittest tests.test_firmware_compatibility -v` 与 `make test`。
3. 若改动了 catalog 或变体，`FirmwareCompatibilityManifestTests` 会捕捉漂移。

## 8. 待澄清项（open_questions）

见 JSON `open_questions`，共 6 项：内核类型维度含义待确认；cloudOS 构建号缺失；三套计数口径不一致（CLAUDE.md 待确认）；regular/dev 无真机 boot 证据；C3 本轮 24 + 1 场景已完成，其他组合与运行验收未随之完成；`ipsws/patch_refactor_input` fixtures 目录不存在。

## 9. 门控一致性修正（2026-09-10）

清单方法的旧 gate 名称 `applyExcGuard`、`applyFrida` 分别迁移为 `PatchRule.rawValue` 的 `excGuardActive`、`cloudOSFridaCapable`。生产门控行为和补丁字节未修改；`KernelPatcher.applyExcGuard` 参数保持原名与含义。

五变体（less、regular、dev、jb、exp）的实际流水线步骤与清单方法集合、条件规则名称对齐测试通过。EXC_GUARD 测试从实际流水线报告获取门控快照，覆盖 regular/dev/jb/exp × iOS 18 开关 × force 开关共 16 个组合，并检查实际内核工厂产生的结构化结果。针对 Swift 测试 18 项、Python 清单校验 14 项通过。本记录不包含本轮真实固件样本或启动验收结果。

## 10. C3 本轮验收登记（2026-09-10）

新增七条 patch_verified，261 非 less 既有条目追加完整 parity 证据。24 个非 less 场景与 1 个 less 默认场景全部通过限定范围内的验收，见 [C3 收尾验收](c3_completion_acceptance_2026-09-10.md)。新增 263 的 cloudOS 构建为原始 BuildManifest/SystemVersion 标识的 23D129；历史 23D128 保持独立，未复验。

本轮范围不表示 23 个 catalog 配对的所有变体与选项均受支持。历史 capability 条目不提升，code_selectable 保持可选择语义。Filesystem 采用结构证明及实际字节链/独立产物校验，不宣称两次完整 APFS/AEA 镜像逐字节比较；恢复/启动及 C4 中断恢复未由本轮验证。
