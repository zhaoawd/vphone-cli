# D4：创建检查点与续跑

日期：2026-09-17。基线：`61eebdb`。设计输入：[C5/D4 字段与测试草案](c5_d4_fields_and_tests_2026-09-14.md)。

状态：状态模型、检查点存储、续跑入口、只读状态视图、真实阶段执行器与验证器、无 VM 测试已实现。真实 VM 的中断恢复验收未执行，D4 验收条件中的“真实 restore 中断后重新探测状态”未取得实机证据，D4 保持未完成。本轮未启动、恢复、挂载或安装任何 VM，未使用 sudo，未访问仓库中的 VM 目录。

## 代码位置

| 路径 | 内容 |
| --- | --- |
| `sources/VPhoneCore/VPhoneCreateCheckpoint.swift` | 阶段、状态、选项、身份、产物、检查点结构与结构校验，产物指纹 |
| `sources/VPhoneCore/VPhoneCreateCheckpointStore.swift` | 检查点目录、运行锁、持久化写入、尝试归档、只读加载 |
| `sources/VPhoneCore/VPhoneCreateRunner.swift` | 执行器、验证器、探测器协议；新建与续跑流程；错误类型；C4 事务检查 |
| `sources/vphone-cli/VPhoneCreateLiveStages.swift` | 真实执行器、只读验证器、实时状态探测器 |
| `sources/vphone-cli/VPhoneCreateOrchestrator.swift` | `run`（新建）与 `resume`（续跑）接入 runner；原阶段实现改为返回证据 |
| `sources/vphone-cli/VPhoneVMCreateCLI.swift` | `vm create --resume`、`--restart-from`、`--accept-tool-change`；`vm create-status` |
| `sources/VPhoneCore/VPhoneVMRuntimeState.swift`、`VPhoneVMLock.swift` | 新增占用操作 `create-checkpoint`；该操作在存在 `.firmware-transaction` 时仍可取得实例锁 |

未修改 `sources/vphone-cli/VPhoneFWCLI.swift` 与 `sources/FirmwarePatcher/`。C4 事务日志由 VPhoneCore 以 JSON 只读解析 `phase` 字段，不引用 FirmwarePatcher 类型。

## 状态模型

### 文件布局

- `<bundle>/.create-checkpoint/checkpoint.json`：当前检查点。
- `<bundle>/.create-checkpoint/attempts/<attempt_id>-<sha256 前 12 位>.json`：每次续跑开始前，上一份检查点的原始字节。已存在且内容相同时复用，内容不同时拒绝，不覆盖。

JSON 使用 snake_case 字段名、ISO 8601 时间、排序键。

### 顶层字段

| 字段 | 含义 | 约束 |
| --- | --- | --- |
| `schema_version` | 当前为 1 | 其他值在完整解码前拒绝 |
| `creation_id` | 创建身份 | UUID；续跑保留 |
| `created_at`、`updated_at` | 创建与最近写入时间 | |
| `bundle_identity` | `name`、`path`、`directory_id`（`st_dev:st_ino`）、`machine_identifier_sha256` | 续跑时路径、目录 inode 必须一致；机器标识摘要已记录时必须一致 |
| `effective_options` | variant、iPhone/cloudOS 来源、spoof_build、force_dsc_max_slide、enable_frida、cpu_count、memory_mb、disk_size_gb | sudo 密码、root popup、interactive、verbosity、keep-artifacts 不属于该字段 |
| `inputs_digest` | `effective_options` 规范化 JSON 的 SHA-256 | 与 `effective_options` 不一致时拒绝 |
| `tool` | `executable_sha256`（vphone-cli 可执行文件摘要）、`stage_contract_version` | 见续跑判断第 4 步 |
| `attempt_id`、`resumed_from` | 本次尝试；上一尝试 ID、上一检查点文件摘要及归档位置 | `attempt_id` 必须在 `attempts` 中存在 |
| `attempts[]` | 每次尝试的类型（create/resume）、开始时间、pid、`restart_from`、是否接受工具变化、续跑前检查结果 | ID 不重复 |
| `stages[]` | 固定 7 项，顺序为 prepare、patch、restore、cfw、first_boot、jb_finalize、verification | 缺项、重复、未知阶段均拒绝 |
| `artifacts[]` | 产物记录，键为（name, recorded_by） | 键不重复；路径为包内相对路径 |
| `recovery_required` | kind、stage、detail、action | 非空时整体状态为 `recovery_required` |

固件来源为带 user、password、query 或 fragment 的 URL 时，`display` 去除这些部分，`redacted` 为 true，`sha256` 为完整字符串摘要。需要重跑 prepare 时，调用方必须重新提供来源，摘要一致才视为未改变。

### 阶段记录与状态

每个阶段记录 `status`、`attempt_id`、`pid`、`started_at`、`finished_at`、`executor_result`（completed/threw）、`verifier_version`、`evidence`、`inputs`（开始时所有可用产物的指纹）、`outputs`、`reason`、`error`、`history[]`。

| status | 含义 |
| --- | --- |
| `pending` | 未开始 |
| `running` | 已写入开始记录；进程退出后仍为 running 表示中断，续跑时必须探测并重跑 |
| `succeeded` | 执行器返回，且只读验证器返回 verified |
| `unverified` | 执行器返回，验证器没有可确认结果的证据；必须带 `reason`；不计为成功 |
| `failed` | 执行器抛错，或验证器拒绝，或验证器报告的产物不可读 |
| `cancelled` | 执行器抛出 `CancellationError` |
| `not_applicable` | 仅由变体规则产生：less 无 cfw；非 jb/exp 无 jb_finalize |

阶段被重跑或 `--restart-from` 重置时，原记录移入 `history`，并写明原因（`interrupted: running when its process exited`、`rerun after failed` 等），不覆盖。

结构校验另外要求：`succeeded`/`unverified` 必须有 `executor_result = completed`、`verifier_version`、起止时间，且之前不能有未完成阶段；`running`/`failed`/`cancelled` 必须有 attempt 与开始时间；同时最多一个 `running`；`not_applicable` 与变体规则必须一致；产物只能由已完成阶段记录。

整体状态由阶段推导，不单独存储：存在 `recovery_required` → `recovery_required`；存在 failed → `failed`；cancelled → `cancelled`；running → `interrupted`；全部完成且无 unverified → `succeeded`；全部完成且有 unverified → `completed_unverified`；其他 → `incomplete`。

### 产物与指纹

| kind | 计算内容 | 用途 |
| --- | --- | --- |
| `sha256_file` | 文件内容 SHA-256 | 小文件：AVPBooter、config.plist、restore-info.json |
| `file_metadata` | 大小、mtime（纳秒）、inode | Disk.img |
| `tree_metadata` | 每个条目的相对路径、类型、大小、mtime、inode | `iPhone*_Restore` 目录 |

`file_metadata` 与 `tree_metadata` 不读取内容。保持大小、mtime 与 inode 不变的内容修改不会被发现；这是为避免对约 10 GiB 目录做全量哈希而接受的限制。

同名产物可由多个阶段分别记录（例如 restore_tree 由 prepare 和 patch 记录）。续跑时每个名称以“重跑起点之前最近一个阶段”的记录为基线比较。

### 保留规则

- `retain_until` 列出需要该产物的阶段。所有这些阶段都完成（succeeded、unverified 或 not_applicable）后才允许默认清理删除。
- 真实流程中 `restore_tree` 的 `retain_until` 为 patch、restore、cfw、first_boot、verification。前三者使用该目录；后两者失败时可能需要重新 restore。jb_finalize 不在列表中。
- 删除后记录 `availability = removed`、原因和重建命令 `vphone-cli vm create --resume <name> --restart-from prepare`。之后若重跑需要该产物的阶段，续跑以 `artifactUnavailable` 拒绝。
- `--keep-artifacts` 时不删除。

## 写入与锁

- 运行锁：对 `.create-checkpoint` 目录 inode 加非阻塞 flock，在整个 create/resume 过程中持有。第二个调用取锁失败后返回 `runInProgress`，不写入。
- 实例锁：每次写检查点时取 bundle 目录锁（操作名 `create-checkpoint`），写完释放。不能在整个创建过程中持有该锁，因为 fw prepare（`vm_lock.py`）、fw patch、DFU 启动、CFW 脚本和启动子进程各自取同一把锁。生产实现对该锁最多重试 30 秒，用于子进程退出与锁释放之间的间隔；测试注入不重试的实现。
- `create-checkpoint` 操作在存在 `.firmware-transaction` 时仍可取锁，使 patch 失败且事务未恢复时仍能写入 `failed` 与 `recovery_required`。其他操作的行为不变。
- 单次写入：`O_EXCL` 临时文件 → write → fsync → rename → fsync 目录。临时文件在任何失败路径上删除。文件持久化不代表整个 VM 创建具有原子性。
- 写入失败时 runner 停止，不继续执行后续阶段。记录失败结果的写入也失败时，错误同时包含写入错误和原始阶段错误；磁盘上的该阶段保持 `running`，续跑按中断处理。

## 续跑判断顺序

`VPhoneCreateRunner.resume` 在第 6 步之前不写任何文件。

1. 占用：取运行锁；bundle 锁被其他进程持有时拒绝（`bundleBusy`）。
2. 加载与身份：检查点文件必须是普通文件（非符号链接）；先解码 `schema_version`，再完整解码并做结构校验；校验 bundle 路径、目录 inode 与机器标识摘要。检查点已全部完成且未指定 `--restart-from` 时，报告整体状态并返回，不写入。
3. 未恢复状态：存在 `.firmware-transaction` 时以 `recoveryRequired(kind: firmware_transaction)` 停止，提示 `vphone-cli fw patch <name> --recover`；对重跑起点及之后所有非 pending、非 not_applicable 的阶段调用探测器，任一返回 busy 时以 `recoveryRequired(kind: live_state)` 停止。
4. 选项、契约与工具：合并命令行覆盖项后逐字段比较；每个变化字段映射到最早受影响阶段（来源、CPU、内存、磁盘、涉及 less 的 variant 变化 → prepare；其他 variant、frida → patch；spoof_build、force_dsc_max_slide → cfw）；若该阶段到重跑起点之间已有非 not_applicable 阶段则拒绝。`stage_contract_version` 不同时拒绝且不可覆盖；可执行文件摘要不同时拒绝，除非传入 `--accept-tool-change`，接受情况记入尝试记录。重跑 prepare 且来源已脱敏时要求重新提供来源。
5. 复核：对每个将被跳过的 succeeded/unverified 阶段重新调用验证器（使用已存证据）；succeeded 阶段必须仍为 verified。然后对每个产物名称，以重跑起点之前最近的记录为基线重新计算指纹；重跑阶段声明会重写的产物（`artifactsRewrittenOnRerun`）不比较；已删除产物若被重跑阶段需要则拒绝。
6. 开始新尝试：归档上一份检查点字节，写入新的 `attempt_id`、`resumed_from`、尝试记录与检查结果，清除 `recovery_required`，将重跑阶段的旧记录移入历史，删除重跑阶段此前记录的产物，按新 variant 重新计算 pending 阶段的适用性。
7. 从重跑起点依次执行；每个阶段先写 `running`，执行器返回后调用验证器，再写结果；每个阶段完成后检查可清理产物。

`--restart-from` 不能晚于下一个未完成阶段。patch 成功后产物已改变的场景下，`--restart-from patch` 因 restore_tree 与 prepare 记录不一致被拒绝；`--restart-from prepare` 可以执行。

## 真实阶段

| 阶段 | 执行器 | 验证器（只读） | 记录产物 | 重跑时允许重写 |
| --- | --- | --- | --- | --- |
| prepare | 从 Virtualization.framework 重新复制 AVPBooter，然后运行 fw prepare | 仅有一个 `iPhone*_Restore`；两个 BuildManifest 可读出版本与构建号 | restore_tree、avpbooter | restore_tree、avpbooter |
| patch | 进程内 FirmwarePipeline；记录新增的 `.firmware-history` 条目 | 无 `.firmware-transaction`；恰有一个新增归档；其 journal `phase = committed` 且 `options.variant` 与当前 variant 相同 | restore_tree、avpbooter | 无 |
| restore | DFU、SHSH、restore-update（原逻辑） | 无进程持有 bundle 锁；udid-prediction 的 ECID 与证据一致；config.plist 有 machineIdentifier；恢复版本可读取 | disk_image、restore_info、config | disk_image、config、restore_info |
| cfw | 等待 5 秒后运行 host-mount 安装并记录 variant | 无进程持有 bundle 锁；restore-info.json 的 variant 与当前 variant 相同；无 `.cfw_mount.*` 残留 | disk_image、restore_info | disk_image、restore_info |
| first_boot | 原首次启动与命令注入 | 有启动退出码；无进程持有 bundle 锁；提示符匹配或操作员确认为 verified；60 秒未见提示符为 unverified | disk_image | disk_image |
| jb_finalize | 打印提示（原逻辑） | 始终 unverified：主机侧没有读取 `/var/log/vphone_jb_setup.log` 的证据收集器 | 无 | 无 |
| verification | 非 less：启动分析；less：前台启动 | 非 less：检测到提示符为 verified；less：unverified，退出码不能证明启动成功 | disk_image | disk_image |

探测器（`VPhoneCreateLiveProber`）的输入均可注入：

- 所有阶段：bundle 锁被持有 → busy；`ps` 中存在该 bundle 的 `vphone-cli --config <bundle>/config.plist` 进程 → busy。
- restore：从 `udid-prediction.txt` 读取 ECID；存在命令行含 `pymobiledevice3_bridge.py`、`restore-` 与该 ECID 的进程 → busy；`recovery-probe --ecid` 仍有应答 → busy。无 udid-prediction 时记录“未寻址设备”。
- cfw：`hdiutil info` 中存在位于 bundle 内的镜像 → busy。
- idle 时把检查项写入证据，保存到新尝试的 `checks["probe.<stage>"]`。

prepare 执行器重新复制 AVPBooter 的原因：patch 会就地发布修改后的 AVPBooter；如果不复制，`--restart-from prepare` 之后 patch 会作用于已修改的 ROM。

## CLI

```text
vphone-cli vm create <name> [选项]                       新建（行为见下节）
vphone-cli vm create --resume <name> [选项]              续跑
vphone-cli vm create --resume <name> --restart-from <stage>
vphone-cli vm create --resume <name> --accept-tool-change
vphone-cli vm create-status [<name>] [--json]            只读查看
```

- 续跑时未传入的选项沿用检查点；标志类选项只在传入时参与比较。`--restart-from`、`--accept-tool-change` 只能与 `--resume` 一起使用。
- 同名目录已存在且含 `.create-checkpoint` 时，新建报错并给出 `create-status` 与 `--resume` 命令；无检查点时保持原 `already exists` 错误。
- 续跑或新建失败时打印整体状态、`recovery_required` 内容和下一步命令；产物变化类错误提示从 prepare 重启或删除后重建。
- `create-status` 不取锁、不写文件。文本输出列出各阶段状态、原因、错误、历史条数、已删除产物、恢复要求、下一阶段，以及 bundle 锁、运行锁、C4 事务的实时状态。`--json` 输出 `bundle`、`checkpoint_error`、`overall_status`、`next_stage`、`live`、`checkpoint`。检查点缺失或无效时退出码为 2。

## 新建流程的行为变化

- 新建后在 bundle 内写入 `.create-checkpoint/`。初始检查点写入失败时删除刚创建的 bundle，避免留下无续跑路径的同名目录。
- 默认清理 `iPhone*_Restore` 的时机从“cfw 之后、first_boot 之前”改为“first_boot 与 verification 均完成之后”。磁盘占用峰值不变，占用时间延长到验证启动结束。
- prepare 开始前重新复制 AVPBooter；复制源与 `vm new` 相同。
- `=== Done ===` 从验证启动之前移到全部阶段之后，并按整体状态输出：`succeeded`、`completed_unverified`（列出 unverified 阶段与原因）或未完成。jb/exp 因 jb_finalize 为 unverified，整体状态为 `completed_unverified`；less 因 verification 为 unverified，整体状态同样为 `completed_unverified`。进程退出码在这两种情况下仍为 0，失败阶段仍以非零退出。
- cfw 之后 restore-info.json 未记录 variant 时，cfw 阶段判定失败；原实现中该记录为尽力而为，失败不影响创建结果。
- first_boot 的启动退出码和提示符检测结果进入证据；原实现不检查退出码，该判定逻辑未改变。

## 测试

执行环境：worktree `agent-a7ec2a3f1200058a1`，macOS 主机，Swift 6 工具链。未运行 Python 测试，本轮未修改 Python 或脚本。

| 草案场景 | 测试 | 驱动方式与断言 |
| --- | --- | --- |
| 阶段故障矩阵 | `CreateCheckpointTests.faultMatrixFirstRunAndResume`，7 阶段 × 5 故障 = 35 例 | 故障：执行前失败、执行后失败、检查点提交前中断（rename 注入）、取消、验证器拒绝。首次运行断言执行序列、故障阶段状态（failed/cancelled/running）、之前阶段完成、之后阶段 pending、整体不为成功；续跑断言只从故障阶段执行、首个探测阶段为故障阶段、跳过阶段先被复核、历史条目、`resumed_from`、归档内容。patch 在提交前中断时，续跑以 restore_tree 变化拒绝，随后 `--restart-from prepare` 完成 |
| 产物损坏或移走 | `changedArtifactAfterSuccessRefusesResumeWithoutExecuting`、`movedArtifactRefusesResume`、`restartFromStageWhoseOutputWasModifiedLaterIsRefused`、`rerunStageMayRewriteItsDeclaredArtifacts` | 修改、移走产物后续跑被拒且执行器未运行、检查点字节不变；声明可重写的产物不阻止重跑 |
| bundle 身份 | `movedBundleIsRefused`、`clonedOrReplacedBundleIsRefused`、`changedMachineIdentifierIsRefused` | 移动路径、同路径替换为副本（新 inode）、机器标识变化均拒绝 |
| 状态文件损坏或未来版本 | `truncatedCheckpointIsRejected`、`futureSchemaIsRejected`、`duplicateStageIsRejected`、`unknownStageIsRejected`、`succeededWithoutVerifierIsRejected`、`notApplicableWithoutVariantRuleIsRejected`、`artifactPathEscapingBundleIsRejected`、`symlinkedCheckpointIsRejected`、`missingCheckpointIsNotResumable` | 加载与续跑均拒绝；执行器、验证器、探测器调用均为空；文件字节不变 |
| C4 事务未提交 | `uncommittedFirmwareTransactionRequiresRecovery`（building、publishing、rollingBack 共 3 例）、`patchFailureLeavingTransactionIsRecordedAsRecoveryRequired` | 续跑报告 `firmware_transaction` 与 phase，不执行、不写入，patch 保持 failed；首次运行中 patch 留下事务时写入 `recovery_required`；移除事务后续跑重跑 patch |
| restore 中断重新探测 | `busyLiveStateStopsResumeUntilProbeIsIdle`（核心，伪探测器）；`CreateLiveStagesTests` 中 restore/cfw/boot 探测 6 项 | busy 时不执行、不写入；idle 时重跑 restore 并保存探测证据。真实探测器在锁被持有、同 ECID 桥接进程、设备端点应答、bundle 启动进程、bundle 内镜像挂载时返回 busy；其他 ECID 的进程不影响 |
| 锁冲突与并发续跑 | `heldRunLockRefusesResumeWithoutWriting`、`runLockHeldByChildProcessRefusesUntilItExits`、`heldBundleLockRefusesResumeWithoutWriting`、`bundleLockTakenBetweenStagesFailsTheWriteAndStops`、`concurrentResumeAdmitsOneWriter` | 使用真实目录 flock（同进程独立描述符及 python3 子进程）；失败方不修改检查点；子进程退出后续跑成功；两个线程并发续跑时只有一个执行阶段 |
| 不适用阶段 | `notApplicableFollowsVariantRules`（less、regular、dev、jb、exp 共 5 例）、`pendingStageIsNeverTreatedAsNotApplicable` | 只有变体规则产生 not_applicable，且有原因；执行序列不含不适用阶段；缺少规则的状态被校验拒绝 |
| 恢复输入保留 | `recoveryInputsAreKeptUntilRetainingStagesFinish`、`keepArtifactsSkipsRemoval`、`removableArtifactsFollowSynthesizedStageStates` | first_boot 失败后 restore_tree 保留且记录可用；续跑完成后删除并记录重建命令；合成状态中 first_boot/verification 未完成时不可删除，jb_finalize 不阻止删除 |
| 写入失败注入 | `writeFailureBeforeStageStopsWithoutExecuting`（writeTemporary、syncFile、rename、syncDirectory 共 4 例）、`failureRecordWriteErrorKeepsOriginalError` | 执行器不运行；syncDirectory 失败时 running 已落盘，其余为 pending；无临时文件残留；失败记录写入失败时保留原始错误，续跑先探测 |
| 其他 | `freshCreateRecordsEveryStageAndOverallStatus`、`unverifiedStageNeverReportsOverallSuccess`、`optionChangeAffectingCompletedStageIsRefused`、`variantChangeBeforePatchRecomputesApplicability`、`toolChangeRequiresExplicitAcceptance`、`credentialsInSourcesAreNotStoredAndMustBeResupplied`、`sourceRecordRedactsOnlyURLSecrets`、`restartAfterNextUnfinishedStageIsRejected` | 整体状态推导、完成后续跑不写入、选项/工具变化规则、来源脱敏 |
| 真实验证器与状态视图 | `CreateLiveStagesTests`：jb_finalize、first_boot、less verification、patch 事务、prepare 目录、重写声明、状态视图 | jb_finalize 不因提示输出变为 verified；patch 仅接受一个已提交且 variant 一致的归档；状态视图只读 |

测试结果见下文“验证记录”。

## 验证记录

| 命令 | 结果 |
| --- | --- |
| `swift build --disable-sandbox --product vphone-cli` | 构建完成；新增文件无编译警告 |
| `swift test --disable-sandbox --filter CreateCheckpointTests` | 40 个测试函数、83 个用例通过 |
| `swift test --disable-sandbox --filter CreateLiveStagesTests` | 13 个测试函数、13 个用例通过 |
| `make test_swift`（`python3 scripts/run_tests.py swift`，跳过 `FirmwareIntegrationTests`） | 退出码 0；Swift Testing 390 个测试、55 个 suite 通过；XCTest 143 项、3 项跳过、0 失败 |

新增测试合计 53 个测试函数、96 个用例。本轮 `make test_swift` 未出现 ResourcesTests 的 `VPHONE_ROOT` 并行竞争失败。`make test_python` 未运行。

## 限制与待验证假设

- `file_metadata`、`tree_metadata` 不检测保持大小、mtime、inode 的内容修改（事实，由算法决定）。
- 身份比较使用 bundle 路径的规范化字符串；用不同拼写（例如经符号链接）指定同一库根会被判为路径不一致（事实）。
- `stage_contract_version` 需要在阶段输出契约变化时人工递增；未递增时，工具摘要检查是唯一的防护，且可被 `--accept-tool-change` 放行（事实）。
- less 创建整体以 root 运行，检查点文件属主为 root，续跑也需要 root（推断，未实测）。
- 生产锁重试 30 秒足以覆盖 DFU/CFW 子进程退出后的锁释放间隔（待验证假设）。
- 真实探测器通过命令行文本识别 restore 桥接进程；如果桥接进程命令行不包含 `--ecid 0x<ECID>`，该项探测会漏报（待验证假设；当前执行器传入该参数）。
- `recovery-probe` 无应答被解释为设备端点不存在；探测超时 2 秒是否足以区分（待验证假设）。
- 首次启动 60 秒未检测到提示符时继续执行的原逻辑保留，结果记为 unverified；这种情况下 first_boot 仍计为完成并允许清理 restore_tree（设计决定）。
- jb_finalize 没有证据收集器，jb/exp 创建整体状态不会为 `succeeded`。要改为 verified，需要在 verification 启动中通过 vphoned 读取 `/var/log/vphone_jb_setup.log` 或终态标记（未实现）。

## 待执行的真实 VM 验收

前置条件：专用、未被其他任务占用的库根与 VM 名称（不使用 `vm`、`vm-2607`、`vm-new`、`vm.backups`）；可重新准备的固件输入；空间预算至少覆盖一个 restore 目录、一个 Disk.img 及 C4 暂存；当前工作树构建并签名的应用（`make build`）；amfidont 允许该构建。

1. restore 中断
   1. `vphone-cli vm create d4-acc -V regular -l <专用库根> ...`，在输出 `Restoring...` 之后、restore-update 结束之前向 vphone-cli 主进程发送 SIGKILL（不向子进程发信号）。
   2. 立即执行 `vm create-status d4-acc --json`，记录：restore 为 `running`；`live.bundle_lock_held` 的值；`ps -axo pid=,command=` 中 DFU 子进程与 `pymobiledevice3_bridge.py restore-update` 进程是否存在。
   3. 子进程仍存在时执行 `vm create --resume d4-acc`，必须以 `recovery_required (live_state, stage restore)` 退出，检查点字节不变（对 checkpoint.json 做 `shasum -a 256` 前后比较）。
   4. 手动终止残留子进程，确认 bundle 锁释放、`recovery-probe --ecid` 无应答，再次续跑。必须记录：新尝试的 `checks["probe.restore"]` 内容；restore 从 DFU 启动重新开始；restore 成功后 cfw、first_boot、verification 依次执行；`attempts/` 下存在上一份检查点归档。
   5. 同一流程再做一次“子进程先退出、主进程后被杀”的顺序，确认 idle 探测与重跑。
2. cfw 中断：在 CFW 挂载期间终止主进程；续跑必须因 bundle 锁或 bundle 内挂载镜像返回 busy；清理挂载后续跑，cfw 重复安装成功，D3 的重复安装结论适用。
3. patch 中断：在 C4 事务 publishing 阶段终止；续跑必须提示 `fw patch --recover`；恢复后续跑，patch 从头执行并提交。另做一次“事务已提交、检查点未写入”（在 archive 之后、成功记录写入之前终止）：续跑必须以 restore_tree 变化拒绝，`--restart-from prepare` 完成。
4. first_boot/verification 断开：终止启动子进程；续跑重跑该阶段；restore_tree 在 verification 完成前保持存在。
5. 每个场景记录：命令、时间、终止信号与目标 pid、`create-status --json` 输出、检查点文件摘要、最终整体状态、产物是否保留。整体状态为 `failed`、`interrupted`、`recovery_required` 或 `incomplete` 时不得报告为创建成功。
