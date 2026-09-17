# C5 补丁实验记录实现与验证

日期：2026-09-17。代码基线：`acbd83b`（实现期间 HEAD 由 `61eebdb` 更新为该文档提交），改动未提交。字段设计来源：[C5/D4 字段与测试准备](c5_d4_fields_and_tests_2026-09-14.md)。本次未启动、停止或恢复任何 VM，未使用 sudo，未读写 `vm`、`vm-2607`、`vm-new`、`vm.backups`、`.build/d3/vm-regular`、`.build/d3/vm-exp`。

## 实现范围

| 项目 | 内容 |
| --- | --- |
| 记录入口 | `vphone-cli fw patch --record-out <path>` 与 `vphone-cli patch-firmware --record-out <path>`（Makefile 的 `fw_patch*` 使用后者）。不传该选项时行为不变。 |
| 查看与比较 | `vphone-cli fw record show <record.json>`；`vphone-cli fw record compare <A> <B> [--json]` |
| 模型与比较 | `sources/FirmwarePatcher/Pipeline/PatchExperimentRecord.swift` |
| 条件采集与运行 | `sources/FirmwarePatcher/Pipeline/PatchExperimentRecorder.swift` |
| 流水线改动 | `FirmwarePipeline` 增加 `trace`（阶段、当前组件、门控、已处理组件及其 `ComponentReport`、事务对象）；抽出 `transactionRoots()`、`makeReport(...)`、`readManifestString(...)`。`FirmwareTransaction` 增加只读 `journalSnapshot`、`archiveURL`，`Journal`/`Entry` 增加 `Equatable`。补丁逻辑、补丁选择与补丁数量未改动。 |
| 未改动 | `VPhoneCreateOrchestrator.swift`、`VPhoneVMCreateCLI.swift`；`vm create` 流程不写实验记录。 |

记录为显式选项，默认不写入 VM 目录。原因：写入 VM 目录会进入 less 流程的 root 权限目录及 D3/D4 使用的 bundle；记录位于固件输入根目录（Restore 目录、AVPBooter）或 `.firmware-transaction`、`.firmware-history` 内时，运行前拒绝，避免记录文件改变其记录的输入摘要。

## 运行顺序

1. 采集实验条件（源码状态、工具、固件构建号、有效选项、输入摘要）。
2. 删除同名旧摘要文件，写入 `status: running` 的记录。该写入失败时停止，流水线不运行。
3. 运行 `patchAllStructured`。
4. 由 `trace`、返回的 `PatchRunReport` 或抛出的错误生成最终记录，校验后持久写入。
5. 从磁盘重新解码 JSON，生成 `<name>.summary.txt`。摘要与 `fw record show` 输出均来自同一个解码后的记录。
6. 流水线抛出的错误原样重新抛出；此时若最终记录写入失败，只在 stderr 输出记录错误。流水线成功而记录写入失败时，命令以记录写入错误退出。

## 记录字段（schema 1）

JSON 键名沿用现有 `PatchRunReport` 的 camelCase 拼写。可选值显式写为 `null`，不省略键。

| 字段 | 内容 | 规则 |
| --- | --- | --- |
| `schema`、`schemaVersion` | `vphone.patch-experiment-record`、`1` | 其他名称或版本拒绝加载 |
| `runID`、`startedAt`、`finishedAt` | UUID 与带毫秒的 ISO 8601 UTC 时间 | 运行中 `finishedAt` 为 `null`；不进入条件摘要 |
| `status`、`failedStage`、`error` | `running`/`succeeded`/`failed`/`cancelled`；阶段名（`FirmwareRunStage` 原值或 `record`）与组件；错误文本 | `succeeded` 不能带失败阶段或错误；失败与取消必须带失败阶段；`CancellationError` 记为 `cancelled` |
| `conditions.tool.source` | `status`（clean/dirty/unavailable）、`commit`、`scope`、`changes[]`、`submodules[]` | `changes[]` 为 `git status --porcelain=v1 -z --untracked-files=all --ignore-submodules=none` 在范围 `Makefile Package.resolved Package.swift requirements.txt scripts sources vendor` 内的逐文件结果：路径、XY 状态、工作树文件 SHA-256；删除文件为 `null` 并注明原因；子模块内修改递归列出；重命名同时记录原路径 |
| `conditions.tool` 其他字段 | `buildCommit`、`executableSHA256`、`swiftCompiler`、`hostOS`、`packageResolvedSHA256`、`buildDependenciesSHA256`、`python`、`sealTool` | 每项为 `{value, reason}`，二者恰有一个非空。`python`、`sealTool` 仅 less 采集，其他变体记为未使用 |
| `conditions.firmware` | `iPhone`（`iPhone-BuildManifest.plist`）与 `cloudOS`（`BuildManifest.plist`）的 `ProductVersion`、`ProductBuildVersion`；`origin` | 仅读取清单键，不从目录名补全；`fw prepare` 不保存 IPSW 来源，`origin` 记为未知并注明原因；不记录 URL |
| `conditions.options` | `variant`、`forceExcGuard`、`frida`、`noBinpack`、`noVphoned`、`ablate`（去空白、去重、排序）、`allowAblationOutput` | 所有字段始终写出，包括默认值 |
| `conditions.inputs` | `files[]`：流水线各组件实际查找到的文件及两份门控清单，含相对路径、组件、字节数、SHA-256；`roots[]`：事务根的 `vphone-tree-sha256-v1` 树摘要（与 `FirmwareTransaction.digest` 同一算法） | 路径唯一；无法计算时摘要为 `null` 并注明原因，整体 `availability` 为 `unavailable` |
| `conditionDigest` | `conditions` 规范 JSON（键排序、紧凑、斜杠不转义）的 SHA-256 | 加载时重新计算，不一致即拒绝 |
| `patch` | `report`（现有 `PatchRunReport`，未改字段）、`reason`、`reportSHA256`、`failedRequired`、`plannedComponents`、`processedComponents`、`notRunComponents` | 抛错时用已完成组件的 `ComponentReport` 组成部分报告并注明；门控未求值时 `report` 为 `null`；`failedRequired` 加载时须等于 `report.failedRequired`；未运行组件不写成功或不适用 |
| `transaction` | `state`（committed/uncommitted/none）、`reason`、`location`（相对 VM 目录）、`journal`（现有 `FirmwareTransaction.Journal`） | `committed` 要求 journal 阶段为 `committed`；未提交 journal 不能对应 `succeeded` 或可用输出 |
| `outputs` | 成功且事务已提交时：同路径组件文件的 SHA-256，事务根摘要取自 journal `output` | 否则为 `unavailable` 并注明原因（消融 dry-run、失败、取消）；运行中为 `pending` |
| `run` | `vmDirectory`、`executable`、`sourceRoot`、`recordPath` 绝对路径 | 不进入任何比较结果 |

成功判定的附加检查：事务 journal 的 `original` 必须等于记录采集到的输入根摘要，否则状态记为 `failed`，失败阶段为 `record`。

## 持久写入与失败处理

写入顺序：同目录临时文件（`O_EXCL`）、写入、`fsync`、`rename`、目录 `fsync`。

| 失败位置 | 磁盘结果 |
| --- | --- |
| `rename` 之前（创建、写入、`fsync`、`rename` 本身） | 删除临时文件；目标保留原内容（开始时写入的 `running` 记录） |
| `rename` 之后的目录 `fsync` | 删除目标文件，不保留一份看似完整但持久性未确认的记录 |
| 最终记录已写入、摘要写入失败 | JSON 记录完整有效；摘要不存在；命令报告摘要写入错误 |

进程被 SIGKILL 或 SIGINT 终止时，磁盘上保留 `running` 记录（`finishedAt` 为 `null`），不写成失败或取消。本次未增加信号处理。

## 比较规则

`PatchExperimentRecord.compare` 输出三个独立结果，每个为 `same`/`different`/`undetermined`，并列出差异字段路径：

| 结果 | 比较对象 | 说明 |
| --- | --- | --- |
| 实验条件 | `conditions` 全部字段 | 不含 `runID`、时间、`run` 绝对路径、事务身份 |
| 补丁结果 | `status`、`failedStage`、`patch` | 任一记录为 `running` 时为 `undetermined` |
| 产物摘要 | `outputs` | 任一记录输出不可用或存在缺失摘要时为 `undetermined`，不推断相同 |

差异路径规则：对象按键递归；元素为含唯一 `path` 的对象数组按路径匹配（如 `conditions.inputs.files[<相对路径>].digest`）；标量数组（如 `ablate`）作为一个值比较；其他数组按下标。`excluded` 单独列出 `runID`、`startedAt`、`finishedAt`、`error`、`transaction.*`、`run.*` 中不同的字段。文本输出每个结果最多列 40 条差异，`--json` 输出全部。

`fw record compare` 退出码：三个结果均为 `same` 时 0；任一为 `different` 或 `undetermined` 时 1；记录无法加载或校验失败时 2。同一份失败记录与自身比较，产物结果为 `undetermined`，退出码为 1。

## 无 VM 测试

新增测试：`tests/FirmwarePatcherTests/PatchExperimentRecordTests.swift`（Swift Testing，12 个测试函数，含参数化用例）与 `tests/VPhoneCLITests/PatchExperimentRecordCLITests.swift`（1 个测试函数）。测试使用临时目录中的合成 VM 目录、直通 loader 及注入的环境值；除有意触发必要补丁失败的用例外，组件均以消融方式运行。

| 设计文档场景 | 测试 | 断言 |
| --- | --- | --- |
| 相同输入两次实验 | `identicalRunsInDifferentDirectoriesCompareSame` | 两个不同临时目录的记录：三个结果均为 `same`，条件摘要相同；差异只在排除字段 |
| 选项或组件变化 | `changedConditionIsNamed`（variant、forceExcGuard、消融、单字节输入） | 条件差异分别只有 `conditions.options.variant`、`conditions.options.forceExcGuard`、`conditions.options.ablate`；单字节变化指出内核文件与 Restore 根摘要；forceExcGuard 同时在补丁结果中出现门控差异 |
| 必要补丁失败 | `requiredFailureAfterPartialSuccessKeepsCompletedParts` | `failed`、阶段 `patch`、组件 `iBSS`；已处理 AVPBooter、iBSS；报告等于流水线返回值；事务 `uncommitted`；输出不可用；摘要文件等于 `summary()` |
| 部分成功后取消 | `cancellationAfterPartialSuccessKeepsOriginalError` | 抛出原 `CancellationError`；`cancelled`；部分报告只含 AVPBooter；事务未提交 |
| 记录写入失败 | `finalWriteFailureDoesNotMaskRunError`、`finalWriteFailureAfterSuccessIsReported`（各 4 例：write/ENOSPC、fsync/EIO、rename/EXDEV、目录 fsync/EIO）、`initialWriteFailureStopsBeforePatching` | 运行错误不被覆盖；磁盘上无完整记录（只有 `running` 记录或无记录）、无摘要、无临时文件；初始写入失败时不创建事务 |
| 状态文件损坏或未知版本 | `corruptAndUnknownRecordsAreRejected` | 截断 JSON、schemaVersion 2、schema 名称、缺键、改条件不改摘要、`failedRequired` 不一致、Known 值同时有值和原因、状态与字段矛盾均被拒绝 |
| C4 事务未提交 | `uncommittedTransactionIsNotSuccessfulOutput` | 引用 `building` 阶段真实事务：`failed`、阶段 `commit`、输出不可用；伪造为成功、committed 或可用输出均校验失败 |
| 源码状态 | `sourceStateListsChangedAddedAndDeletedFiles` | 临时 git 仓库：clean；修改、删除、新增文件分别为 M、D、??，范围外文件不列出；无仓库时 unavailable 并注明原因 |
| 记录位置 | `recordInsideFirmwareInputIsRejectedBeforePatching` | Restore 目录内的记录路径在运行前被拒绝 |
| 摘要来源 | `summaryIsRenderedFromTheRecord` | 摘要文件等于解码记录的 `summary()` |
| CLI 接线 | `failedPatchRunWritesARecordThatShowAndCompareAccept` | `patch-firmware --record-out` 失败运行写出 `failed` 记录；`show` 退出 0；自比较退出 1（产物 `undetermined`）；截断记录比较退出 2 |

设计文档中的锁冲突与并发、阶段故障矩阵、不适用阶段、恢复输入保留属于 D4 创建检查点，本次未实现。

### 执行结果

| 命令 | 结果 |
| --- | --- |
| `swift test --filter PatchExperimentRecord` | 13 个测试、2 个 suite 通过 |
| `make test_swift`（最终代码） | Swift Testing 350 个测试、55 个 suite 通过；XCTest 143 项、3 项跳过、0 失败 |
| `make test_python` | 126 项通过（OK），耗时 36.7 秒 |

加入记录位置检查和差异条数上限之前的一次 `make test_swift`：Swift Testing 349 个测试、55 个 suite 通过；XCTest 143 项、3 项跳过、0 失败。两次运行均未出现 ResourcesTests 的 `VPHONE_ROOT` 并发失败。`make test_python` 在最终两处小改动（记录位置检查、文本差异上限）之前执行，这两处改动不涉及 Python 代码。

## 真实输入运行（无 VM 启动）

### 实验设置

| 项目 | 值 |
| --- | --- |
| 输入 | `ipsws/iPhone17,3_26.1_23B85_Restore.ipsw` 与 `ipsws/399b664dd623358c3de118ffc114e42dcd51c9309e751d43-727c4f5e2432.ipsw`，以 `cp -c` 克隆到 `.build/c5/ipsws/` |
| 准备 | 在 `.build/c5/prep/` 执行 `scripts/fw_prepare.sh <iPhone ipsw> <cloudOS ipsw>`（`VPHONE_PYTHON=.venv/bin/python3`，`IPSW_DIR=.build/c5/ipsws`），退出 0，日志 `.build/c5/prepare.log` |
| VM 目录 | `.build/c5/lib/vmA`、`vmB`、`vmC`：各自 `cp -c -R` 准备好的 Restore 目录，并克隆 `/System/Library/Frameworks/Virtualization.framework/Resources/AVPBooter.vresearch1.bin`。`vmD`：克隆 vmA 补丁后的 Restore 与 AVPBooter |
| 工具 | `.build/debug/vphone-cli`（`swift build`，SHA-256 `14e7ab83d716268bd74c67a724cb9a869d0e34a92b620e4696d9fc6536979a2e`） |
| 命令 | `vphone-cli patch-firmware --vm-directory <vmX> --variant regular [--force-exc-guard] --record-out .build/c5/records/runX.json --quiet` |
| 运行 | A、B：相同选项；C：`--force-exc-guard`；D：对已补丁输入再次补丁 |

每次补丁运行约 31–33 秒（含两次 10 GiB Restore 树摘要：记录采集一次，C4 事务一次）。`du -sh .build/c5/lib` 显示 83G，该值包含 APFS 克隆共享块；运行前后 `df` 可用空间约 302 GiB → 301 GiB。

### 结果

| 运行 | 退出码 | 记录状态 | 说明 |
| --- | --- | --- | --- |
| A | 0 | succeeded | 58 条字节记录；方法结果 applied=27、notApplicable=2；事务 committed |
| B | 0 | succeeded | 同 A |
| C | 0 | succeeded | forceExcGuard=true |
| D | 1 | failed | 阶段 `patch`、组件 `kernelcache`；8 个 KernelPatcher 必要补丁失败；已处理 AVPBooter–kernelcache，未运行 DeviceTree、Filesystem、Manifest；事务 `uncommitted`（building）；输出 `unavailable` |

比较结果（输出文件 `.build/c5/cmpAB.txt`、`cmpAC.txt`、`cmpAC.json`、`cmpAD.txt`）：

| 比较 | 退出码 | 实验条件 | 补丁结果 | 产物摘要 | 排除字段差异 |
| --- | --- | --- | --- | --- | --- |
| A vs B | 0 | same（条件摘要均为 `a43b8ea7…a12a7b6`） | same | same | finishedAt、run.recordPath、run.vmDirectory、runID、startedAt、transaction.journal.id、transaction.journal.vmPath、transaction.location |
| A vs C | 1 | different：仅 `conditions.options.forceExcGuard: false -> true` | different：26 条，包括 `patch.report.components[5].records[28]` 新增 PACIBSP→RET 记录、对应结果由 notApplicable 变为 applied，以及各结果门控快照 | different：内核文件 SHA-256 与 Restore 根摘要 | 另含 journal 选项与输出摘要 |
| A vs D | 1 | different：输入文件摘要与大小（D 的输入为 A 的输出） | different | undetermined（D 输出不可用） | 另含 error、事务状态与 journal 字段 |

`fw record show .build/c5/records/runA.json` 的输出与 `runA.summary.txt` 逐字节相同（`cmp` 通过）。

记录中的事实：

- `source.status` 为 `dirty`，列出本次 6 个改动源码文件及 SHA-256；源码 commit 为 `acbd83b…`。
- `buildCommit` 为 `2bfe7f4`，与源码 commit 不同。该值来自 `sources/vphone-cli/VPhoneBuildInfo.swift`，`swift build` 不重新生成该文件；可执行文件 SHA-256 是本次工具身份的直接依据。
- 混合 `BuildManifest.plist` 与 `iPhone-BuildManifest.plist` 均为 26.1 / 23B85。另行核对 cloudOS IPSW 内原始 `BuildManifest.plist` 同为 26.1 / 23B85，因此两个构建号在此输入组合中相同。
- `buildDependenciesSHA256` 为未知（仓库构建无 `build-dependencies.json`）；`python`、`sealTool` 为 regular 变体未使用。

证据位置：`.build/c5/records/run{A,B,C,D}.json` 及 `.summary.txt`、`.build/c5/run{A,B,C,D}.log`、`.build/c5/cmp*.txt`。vmD 保留未恢复的 `.firmware-transaction`（失败运行的预期状态）。

## 限制与待处理项

- less 变体真实运行未执行：需要 root（`fw_patch_less` 要求 sudo），本次不使用 sudo。less 的 `python`、`sealTool` 采集及大镜像树摘要耗时仅经代码路径与单元测试覆盖，真实值未验证。
- 取得 bundle 锁失败时不写记录（记录器在锁内运行）。
- 进程被信号终止时只留下 `running` 记录。
- 源码状态为运行时工作树状态，可能与构建可执行文件时的状态不同；该差异无法由记录判断，需依靠 `executableSHA256` 对应构建。`swiftCompiler` 只记录编译期版本区间，不含完整工具链版本和 Xcode 版本。
- `firmware.origin` 始终未知：`fw prepare` 当前不保存 IPSW 来源。
- 补丁结果差异中，门控快照在每个结果内重复出现，一个选项变化会产生多条差异；文本输出已截断为 40 条。
- 记录采集时对事务根再做一次树摘要，regular 26.1 输入每次约增加一次 10 GiB 读取；less 输入的额外耗时未测量。
- `vm create` 未接入记录（D4 并行修改范围）。
- 本次实现未修改补丁逻辑，因此未更新 `research/0_binary_patch_comparison.md`。
