# D4：创建检查点与续跑

2026-09-22 修复：`--resume` 不允许修改 `--disk-size`，即使指定 `--restart-from prepare`。`Disk.img` 在首次创建 bundle 时分配，续跑阶段不重新分配磁盘；此前新参数仅改变检查点。修改大小现在在归档、写检查点及执行阶段前拒绝；重复传入原值仍可续跑。回归测试覆盖 prepare 失败和全部阶段完成后的重跑，并检查拒绝后检查点及磁盘内容不变。

日期：2026-09-17。基线：`61eebdb`。设计输入：[C5/D4 字段与测试草案](c5_d4_fields_and_tests_2026-09-14.md)。

状态：状态模型、检查点存储、续跑入口、只读状态视图、真实阶段执行器与验证器、无 VM 测试已实现。真实 VM 的中断恢复验收进行中：场景 1（restore 中断）已执行一次，续跑的 restore 本身完成，但阶段被验证器拒绝，暴露的缺陷与修复见“真实验收发现与修复（2026-09-17）”。修复后的构建尚未重新执行真实验收，D4 保持未完成。场景 1 完成后的 `--restart-from` 检查暴露了续跑产物校验、拒绝提示文本和启动进程路径匹配的缺陷，修复见“真实验收发现与修复：restart-from、拒绝提示与启动进程路径（2026-09-17）”，修复后的构建同样尚未重新执行真实验收。

2026-09-17 更新：在 `8b6365f` 构建上完成真实验收场景 1 补充路径与场景 2–4，`--restart-from prepare` 重建已删除 restore 树、修改后的拒绝提示和含 `..` 的启动进程路径匹配均在实机确认，D4 完成。另记录 restore 桥接进程在 FCS 密钥请求失败后挂起的问题，同日在桥接脚本中修复并实机验收（见“问题：restore 桥接进程挂起”）。见“真实验收记录：`8b6365f` 构建（2026-09-17）”。

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
- 删除后记录 `availability = removed`、原因和重建命令 `vphone-cli vm create --resume <name> --restart-from prepare`。之后续跑时，若重跑起点及之后某个需要该产物的阶段开始前，没有更早的重跑阶段重新生成该产物，续跑以 `artifactUnavailable` 拒绝；判断规则见“续跑判断顺序”第 5 步。
- `--keep-artifacts` 时不删除。

## 写入与锁

- 运行锁：对 `.create-checkpoint` 目录 inode 加非阻塞 flock，在整个 create/resume 过程中持有。第二个调用取锁失败后返回 `runInProgress`，不写入。
- 实例锁：每次写检查点时取 bundle 目录锁（操作名 `create-checkpoint`），写完释放。不能在整个创建过程中持有该锁，因为 fw prepare（`vm_lock.py`）、fw patch、DFU 启动、CFW 脚本和启动子进程各自取同一把锁。生产实现对该锁最多重试 `VPhoneCreateCheckpointStore.bundleLockRetryTimeout`（30 秒），用于子进程退出与锁释放之间的间隔；测试注入不重试的实现。
- 运行记录：取实例锁时 `VPhoneVMLock` 写入 `<bundle>/.vphone-runtime.json`（本操作为 `create-checkpoint`）。释放锁时不删除该文件，与其他操作相同，见“真实验收发现与修复”中的缺陷 2。
- `create-checkpoint` 操作在存在 `.firmware-transaction` 时仍可取锁，使 patch 失败且事务未恢复时仍能写入 `failed` 与 `recovery_required`。其他操作的行为不变。
- 单次写入：`O_EXCL` 临时文件 → write → fsync → rename → fsync 目录。临时文件在任何失败路径上删除。文件持久化不代表整个 VM 创建具有原子性。
- 写入失败时 runner 停止，不继续执行后续阶段。记录失败结果的写入也失败时，错误同时包含写入错误和原始阶段错误；磁盘上的该阶段保持 `running`，续跑按中断处理。

## 续跑判断顺序

`VPhoneCreateRunner.resume` 在第 6 步之前不写任何文件。

1. 占用：取运行锁；bundle 锁被其他进程持有时拒绝（`bundleBusy`）。
2. 加载与身份：检查点文件必须是普通文件（非符号链接）；先解码 `schema_version`，再完整解码并做结构校验；校验 bundle 路径、目录 inode 与机器标识摘要。检查点已全部完成且未指定 `--restart-from` 时，报告整体状态并返回，不写入。
3. 未恢复状态：存在 `.firmware-transaction` 时以 `recoveryRequired(kind: firmware_transaction)` 停止，提示 `vphone-cli fw patch <name> --recover`；对重跑起点及之后所有非 pending、非 not_applicable 的阶段调用探测器，任一返回 busy 时以 `recoveryRequired(kind: live_state)` 停止。
4. 选项、契约与工具：合并命令行覆盖项后逐字段比较；每个变化字段映射到最早受影响阶段（来源、CPU、内存、磁盘、涉及 less 的 variant 变化 → prepare；其他 variant、frida → patch；spoof_build、force_dsc_max_slide → cfw）；若该阶段到重跑起点之间已有非 not_applicable 阶段则拒绝。`stage_contract_version` 不同时拒绝且不可覆盖；可执行文件摘要不同时拒绝，除非传入 `--accept-tool-change`，接受情况记入尝试记录。重跑 prepare 且来源已脱敏时要求重新提供来源。
5. 复核：对每个将被跳过的 succeeded/unverified 阶段重新调用验证器（使用已存证据）；succeeded 阶段必须仍为 verified。然后对每个产物名称，以重跑起点之前最近的记录为基线重新计算指纹；重跑阶段声明会重写的产物（`artifactsRewrittenOnRerun`）不比较；已删除产物：取重跑阶段中第一个在 `artifactsRewrittenOnRerun` 中声明该产物的阶段作为重新生成阶段，`retain_until` 中位于重跑起点及之后、且不晚于重新生成阶段的阶段仍需要已删除的副本，存在这样的阶段则拒绝；没有重新生成阶段时，重跑起点及之后的所有使用阶段都需要该副本。未拒绝且存在使用阶段时，检查结果记入 `checks["artifact.<name>"]`（`removed; regenerated by <stage> before <stages>`）。被跳过阶段已完成并已由验证器复核，其可用产物仍按基线指纹比较。
6. 开始新尝试：归档上一份检查点字节，写入新的 `attempt_id`、`resumed_from`、尝试记录与检查结果，清除 `recovery_required`，将重跑阶段的旧记录移入历史，删除重跑阶段此前记录的产物，按新 variant 重新计算 pending 阶段的适用性。
7. 从重跑起点依次执行；每个阶段先写 `running`，执行器返回后调用验证器，再写结果；每个阶段完成后检查可清理产物。

`--restart-from` 不能晚于下一个未完成阶段。patch 成功后产物已改变的场景下，`--restart-from patch` 因 restore_tree 与 prepare 记录不一致被拒绝；`--restart-from prepare` 可以执行。

## 真实阶段

| 阶段 | 执行器 | 验证器（只读） | 记录产物 | 重跑时允许重写 |
| --- | --- | --- | --- | --- |
| prepare | 从 Virtualization.framework 重新复制 AVPBooter，然后运行 fw prepare | 仅有一个 `iPhone*_Restore`；两个 BuildManifest 可读出版本与构建号 | restore_tree、avpbooter | restore_tree、avpbooter |
| patch | 进程内 FirmwarePipeline；记录新增的 `.firmware-history` 条目 | 无 `.firmware-transaction`；恰有一个新增归档；其 journal `phase = committed` 且 `options.variant` 与当前 variant 相同 | restore_tree、avpbooter | 无 |
| restore | DFU、SHSH、restore-update（原逻辑）；返回前停止 DFU 子进程并等待其退出（最多 60 秒） | 最多等待 30 秒后无进程持有 bundle 锁；udid-prediction 的 ECID 与证据一致；config.plist 有 machineIdentifier；恢复版本可读取 | disk_image、restore_info、config | disk_image、config、restore_info |
| cfw | 等待 5 秒后运行 host-mount 安装并记录 variant | 最多等待 30 秒后无进程持有 bundle 锁；restore-info.json 的 variant 与当前 variant 相同；无 `.cfw_mount.*` 残留 | disk_image、restore_info | disk_image、restore_info |
| first_boot | 原首次启动与命令注入；返回前停止启动子进程并等待其退出（最多 60 秒） | 有启动退出码；最多等待 30 秒后无进程持有 bundle 锁；提示符匹配或操作员确认为 verified；60 秒未见提示符为 unverified | disk_image | disk_image |
| jb_finalize | 打印提示（原逻辑） | 始终 unverified：主机侧没有读取 `/var/log/vphone_jb_setup.log` 的证据收集器 | 无 | 无 |
| verification | 非 less：启动分析，返回前停止启动子进程并等待其退出（最多 60 秒）；less：前台启动 | 最多等待 30 秒后无进程持有 bundle 锁；非 less：检测到提示符为 verified；less：unverified，退出码不能证明启动成功 | disk_image | disk_image |

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
- `create-status` 不取锁、不写文件。文本输出列出各阶段状态、原因、错误、历史条数、已删除产物、恢复要求、下一阶段，以及 bundle 锁、运行锁、C4 事务的实时状态。`--json` 输出 `bundle`、`checkpoint_error`、`overall_status`、`checkpoint_overall_status`、`next_stage`、`live`、`checkpoint`。运行锁被持有时 `overall_status` 为 `running`，否则等于 `checkpoint_overall_status`；`checkpoint_overall_status` 只由阶段记录推导，续跑使用同一推导。检查点缺失或无效时退出码为 2。
- 续跑因 bundle 锁被占用（`bundleBusy`）、运行锁被占用（`runInProgress`）或未写入的 `recovery_required`（C4 事务、实时状态探测）被拒绝时，提示首行说明拒绝原因和“检查点未改变”及其推导状态，随后是停止或等待的操作说明，最后才是续跑命令。

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
| 真实验收缺陷回归（2026-09-17） | `CreateLiveStagesTests`：`verifierAcceptsWhenTheLockIsReleasedWithinTheBound`、`verifierRejectsAfterTheBoundWhenTheLockIsNeverReleased`、`verifierWaitsForARealBundleLockHolderToRelease`、`stageReturnsOnlyAfterItsChildExited`、`stuckChildFailsTheStageAfterTheBound`、`realChildHoldingTheBundleLockHasReleasedItWhenTheStageReturns`、`statusViewShowsRunningOnlyWhileAnotherProcessHoldsTheRunLock`、`busyResumeLeadsWithStopGuidanceAndKeepsTheCheckpoint`、`unrecordedLiveStateAndRunInProgressRefusalsPrintGuidanceFirst`；`CreateCheckpointTests.checkpointWritesReleaseTheBundleLockAndLeaveOnlyADiagnosticRecord` | 锁在界限内释放时验证通过，始终不释放时在注入的 0.3 秒界限后拒绝（restore、cfw、first_boot、verification）；真实 flock 持有者延迟释放后验证通过；子进程等待使用伪子进程（延迟退出、永不退出、阶段本身抛错）和真实 python3 锁持有进程（SIGINT 后 0.5 秒退出），阶段返回时锁已释放；另一进程持有运行锁时状态视图为 `running`，释放后为推导状态；bundle 锁被占用时续跑抛出 `bundleBusy`、检查点字节不变、提示中操作说明先于续跑命令；检查点写入成功和写入失败后 bundle 锁均已释放，运行记录保留 |
| restart-from、拒绝提示与路径匹配回归（2026-09-17，第二轮） | `CreateCheckpointTests`：`restartFromPrepareRegeneratesARemovedRestoreTree`、`restartFromPrepareWithoutKeepArtifactsRemovesTheTreeAgain`、`restartAfterPrepareWithRemovedTreeIsRefusedWithoutWriting`（patch、restore、cfw、first_boot、verification 共 5 例）、`removedArtifactStillRefusedWhenTheRegeneratingStageRunsAfterAConsumer`、`keptStageArtifactsAreStillValidatedWhenARemovedArtifactIsRegenerated`、`artifactLookupReturnsTheLatestRecord`；`CreateLiveStagesTests`：`removedArtifactRefusalLeadsWithItsCauseNotStopped`、`toolChangeRefusalLeadsWithItsCauseAndLabelsTheRecordedRequirement`、`everyRefusalBeforeWriteSaysRefusedAndUnchanged`；`LaunchLayoutTests.matchesConfigPathWithDotDotAndSymlinksButNotPrefixCollisions` | 见“真实验收发现与修复：restart-from、拒绝提示与启动进程路径（2026-09-17）” |
| 真实验证器与状态视图 | `CreateLiveStagesTests`：jb_finalize、first_boot、less verification、patch 事务、prepare 目录、重写声明、状态视图 | jb_finalize 不因提示输出变为 verified；patch 仅接受一个已提交且 variant 一致的归档；状态视图只读 |

测试结果见下文“验证记录”。

## 验证记录

| 命令 | 结果 |
| --- | --- |
| `swift build --disable-sandbox --product vphone-cli` | 构建完成；新增文件无编译警告 |
| `swift test --disable-sandbox --filter CreateCheckpointTests` | 40 个测试函数、83 个用例通过 |
| `swift test --disable-sandbox --filter CreateLiveStagesTests` | 13 个测试函数、13 个用例通过 |
| `make test_swift`（`python3 scripts/run_tests.py swift`，跳过 `FirmwareIntegrationTests`） | 退出码 0；Swift Testing 390 个测试、55 个 suite 通过；XCTest 143 项、3 项跳过、0 失败 |

新增测试合计 53 个测试函数、96 个用例。

2026-09-17 真实验收缺陷修复后（工作树 `codex/autophone-location-multivm-integration`，HEAD `ec9a20f` 加未提交修改）：

| 命令 | 结果 |
| --- | --- |
| `swift build --disable-sandbox --product vphone-cli`、`swift build --disable-sandbox --build-tests` | 构建完成；修改文件无编译警告 |
| `swift test --disable-sandbox --filter CreateCheckpointTests` | 41 个测试函数通过 |
| `swift test --disable-sandbox --filter CreateLiveStagesTests` | 22 个测试函数通过 |
| `make test_swift` | 退出码 2。XCTest 143 项、3 项跳过、0 失败；Swift Testing 452 个测试、63 个 suite，1 个失败：`DoctorCLITests.reportExitCodeFollowsWorstFindingAndCommandParses`（`DoctorCLITests.swift:100`，期望 `pythonRuntime` 错误项）。该测试属于同一工作树中并行开发、尚未提交的 D5 诊断命令，本轮未修改其文件；该失败与本轮修改的关系未查明，D4 相关 suite 全部通过 |本轮 `make test_swift` 未出现 ResourcesTests 的 `VPHONE_ROOT` 并行竞争失败。`make test_python` 未运行。

## 限制与待验证假设

- `file_metadata`、`tree_metadata` 不检测保持大小、mtime、inode 的内容修改（事实，由算法决定）。
- 身份比较使用 bundle 路径的规范化字符串；用不同拼写（例如经符号链接）指定同一库根会被判为路径不一致（事实）。
- `stage_contract_version` 需要在阶段输出契约变化时人工递增；未递增时，工具摘要检查是唯一的防护，且可被 `--accept-tool-change` 放行（事实）。
- less 创建整体以 root 运行，检查点文件属主为 root，续跑也需要 root（推断，未实测）。
- 生产锁重试 30 秒、验证器等待 30 秒、执行器等待子进程退出 60 秒足以覆盖 DFU/CFW/启动子进程退出与锁释放之间的间隔（待验证假设；2026-09-17 实机中锁在验证器拒绝后数秒内释放，具体间隔未测量）。
- 子进程超过 60 秒未退出时，阶段以 `childDidNotExit` 失败；记录失败结果的写入需要 bundle 锁，若该子进程仍持有锁，写入在 30 秒后失败，磁盘上该阶段保持 `running`，续跑按中断处理并探测（设计结果，未实测）。
- 真实探测器通过命令行文本识别 restore 桥接进程；如果桥接进程命令行不包含 `--ecid 0x<ECID>`，该项探测会漏报（待验证假设；当前执行器传入该参数）。
- `recovery-probe` 无应答被解释为设备端点不存在；探测超时 2 秒是否足以区分（待验证假设）。
- 首次启动 60 秒未检测到提示符时继续执行的原逻辑保留，结果记为 unverified；这种情况下 first_boot 仍计为完成并允许清理 restore_tree（设计决定）。
- jb_finalize 没有证据收集器，jb/exp 创建整体状态不会为 `succeeded`。要改为 verified，需要在 verification 启动中通过 vphoned 读取 `/var/log/vphone_jb_setup.log` 或终态标记（未实现）。

## 真实验收发现与修复（2026-09-17）

### 实验设置

- 构建：`make build` 签名的应用，库根 `.build/d4acc/lib`，VM 名称 `d4-acc`。证据目录 `.build/d4acc/logs`。
- 命令：`vm create d4-acc -V regular -l .build/d4acc/lib --root-popup -v`；restore-update 期间向主进程发送 SIGKILL（`s1-kill.time`：09:53:04Z，pid 95712）；子进程在 2 秒内自行退出（`s1-status-after-kill.json`：`live.bundle_lock_held = false`，restore 为 `running`，整体 `interrupted`）。
- 随后手动启动 DFU（`s1-manual-dfu.pid`，日志首行 `VM lock acquired`），在其持有 bundle 锁时执行续跑（`s1-resume-busy.log`）；之后执行 `vm create --resume d4-acc`（`s1-resume.log`）。

### 结果

- 续跑前检查通过，新尝试从 restore 开始；DFU 启动、SHSH、restore-update 完成，`restore-info.json` 写入正确。
- 输出 `[+] Panic marker observed; stopping DFU now.` 之后，阶段以 `verifier rejected: bundle lock still held after restore (DFU child alive)` 失败；失败记录中探测器同样观察到锁被持有，写入 `recovery_required (live_state, stage restore)`（`s1-final.json`，整体 `recovery_required`）。数秒后没有进程持有该锁。
- 进程退出后 `<bundle>/.vphone-runtime.json` 仍存在，内容为 `"operation": "create-checkpoint"` 与已退出的续跑进程 pid 98556。
- 运行锁被持有期间（`s1-poll.json` 取自首次 create 运行中，`s1-resume-early.json` 取自 09:54Z 前后的续跑运行中，均为 `live.create_run_in_progress = true`），`create-status --json` 的 `overall_status` 为 `interrupted`。
- 手动 DFU 持有锁时的续跑输出 `Error: bundle is busy ... stop it first`，提示为通用的 `Inspect`/`Resume` 两行，整体状态 `interrupted`。

### 缺陷 1：验证器与子进程退出竞争

- 原因：`runRestorePhase` 以 `defer { dfu.terminate() }` 停止 DFU 子进程。`VPhoneManagedProcess.terminate()` 发送 SIGINT，最多等待 2 秒，仍在运行时发送 SIGKILL 后立即返回，不等待进程退出。runner 随后立即调用验证器，`case .restore` 中 `lockHeld(bundleURL)` 只检查一次。`runFirstBoot`（出错路径）与 `runBootAnalysis`（成功与出错路径）使用相同的 `defer` 模式；`cfw`、`first_boot`、`verification` 的验证器使用相同的单次检查。
- 推断（未直接观测）：本次 DFU 子进程在 2 秒内未响应 SIGINT，`terminate()` 走 SIGKILL 分支返回，进程终止与文件描述符关闭晚于验证器的检查。日志中两行输出之间没有时间戳，无法确认走的是哪个分支。
- 修复：
  - 执行器：新增 `VPhoneCreateOrchestrator.withStoppedChild`。阶段主体结束后（成功或抛错）停止子进程，并以 `awaitExit` 等待其退出，最多 `childExitTimeout`（60 秒）。成功路径超时抛出 `VPhoneCreateError.childDidNotExit`，阶段记为 failed；出错路径保留原错误并打印子进程未退出的警告。`VPhoneManagedProcess` 只提供无界的 `waitUntilExit`，`awaitExit` 以不匹配任何文本的模式调用 `waitForOutput`（每次 0.25 秒）轮询 `.exited`。restore（DFU）、first_boot（启动进程）、verification 的启动分析均改用该函数。
  - 验证器：`VPhoneCreateLiveStages.waitForLockRelease` 以 0.1 秒间隔轮询 bundle 锁，最多 `lockReleaseTimeout`，默认值为检查点写入使用的 `VPhoneCreateCheckpointStore.bundleLockRetryTimeout`（30 秒）；超时后拒绝，原因包含等待时长。restore、cfw、first_boot、verification 均使用。持续被持有的锁仍产生拒绝，等待有上限。
- 影响：正常路径中子进程退出后才进入验证；一个在 SIGKILL 后仍不退出的子进程最多使阶段额外耗时 60 秒（执行器）或 30 秒（验证器）后失败。

### 缺陷 2：运行记录残留

- 调查结果：`.vphone-runtime.json` 按设计不在释放锁时删除，不作为占用证据。证据：
  - `VPhoneVMRuntimeState` 注释：`Diagnostic record only. Kernel lock ownership, not this file, determines use.`；`read(in:)` 注释说明内容可能过期。
  - `VPhoneVMLock.deinit` 只执行 `flock(LOCK_UN)` 与 `close`；`scripts/vm_lock.py` 写入后 exec 目标命令，不删除记录。`boot`、`dfu`、`fw-prepare`、`cfw` 等所有操作都保留记录。
  - 读取方均先检查内核锁或 pid 存活：`VPhoneBundleGuard.holderDetail` 与 `requireDFUOwner`（注释：`it is never deleted and can name a reused pid`）、`VPhoneVMStopper.confirmedInstanceID`（注释：`it is never deleted on exit, so it survives every VM run`）、D5 诊断中的 `vmOccupancy`（记录 `record_pid_alive`）。
  - [F2 双 VM 准备](f2_dual_vm_preparation_2026-09-16.md) 将该文件定义为诊断记录，不作为占用证据。
- 决定：`create-checkpoint` 保持与其他操作一致，不删除记录，未修改 `VPhoneVMLock`。实际需要保证的是锁释放：`CreateCheckpointTests.checkpointWritesReleaseTheBundleLockAndLeaveOnlyADiagnosticRecord` 断言检查点写入成功和写入失败（rename 注入）后 bundle 锁均未被持有，记录仍为 `create-checkpoint`，下一个持有者可以取锁并覆盖记录。
- 限制：在所有操作上统一改为释放时删除需要修改 `VPhoneVMLock` 与 `vm_lock.py`，并处理“解锁与删除之间被其他进程取锁并写入”的顺序问题，不在本轮范围内。

### 缺陷 3：运行中状态显示为 interrupted

- 原因：`VPhoneCreateStatusReport.make` 直接使用 `checkpoint.overallStatus`；运行中的阶段记录为 `running`，推导结果为 `interrupted`，与 `live.create_run_in_progress` 无关。
- 修复：状态视图在运行锁被持有时将 `overall_status` 报告为 `running`，并新增 `checkpoint_overall_status` 保留推导值；文本输出为 `overall:  running (... stored stages alone read <推导值>)`。`VPhoneCreateOverallStatus` 与 `VPhoneCreateCheckpoint.overallStatus` 未改变，续跑判断不受影响。

### 缺陷 4：bundle 锁占用时的续跑提示

- 原因：`printRecoveryHint` 对除产物变化外的所有错误打印相同的 `Inspect`/`Resume` 两行，且只显示检查点中已记录的 `recovery_required`；续跑前的拒绝不写入，因此提示不包含拒绝原因。stdout 被重定向时为块缓冲，提示在进程退出时才写出，位于 stderr 的 `Error:` 行之后。
- 修复：提示内容由 `recoveryHintLines` 生成。`bundleBusy`：首行说明拒绝与检查点未改变（含推导状态），如运行记录指向存活进程则列出该进程和操作，然后是等待子进程退出或 `vphone-cli vm stop <name>` 的操作说明、用 `create-status --json` 确认 `live.bundle_lock_held = false`，最后是续跑命令。`runInProgress`：说明等待另一运行结束。续跑前抛出的 `recoveryRequired`（C4 事务或实时状态探测）：首行列出 kind 与 stage，随后 detail、action，最后是 `Inspect`/`Resume`。打印后调用 `fflush(stdout)`，使提示先于 `Error:` 行。
- 与设计的差异：原验收步骤 1.3 预期子进程存在时续跑报告 `recovery_required (live_state, stage restore)`。实机中该拒绝来自续跑第 1 步的 bundle 锁检查（`bundleBusy`），探测器未被调用。探测器中的锁检查只在第 1 步之后锁才被取得时生效。
- 决定：bundle 锁占用的拒绝不写入 `recovery_required`，提示也不把它表述为 `recovery_required`。依据：(1) 拒绝时检查点字节不变是续跑前检查的约束；(2) 第 1 步在加载与结构校验之前执行，此时没有可信的阶段信息用于填写 `stage`；(3) `recovery_required` 是持久化字段，只打印不写入会使提示与 `create-status` 的整体状态不一致。提示改为明确说明拒绝原因、检查点未改变及其推导状态。验收步骤 1.3 已按此更新。

### 未验证内容

- 修复后的构建未重新执行真实 restore 中断与续跑；子进程等待与验证器等待在实机中的耗时未测量。
- `awaitExit` 在输出量较大的 DFU 子进程上每次轮询都对全部已捕获输出做一次正则匹配；子进程及时退出时只执行一次，长时间不退出时的 CPU 开销未测量。

## 待执行的真实 VM 验收

前置条件：专用、未被其他任务占用的库根与 VM 名称（不使用 `vm`、`vm-2607`、`vm-new`、`vm.backups`）；可重新准备的固件输入；空间预算至少覆盖一个 restore 目录、一个 Disk.img 及 C4 暂存；当前工作树构建并签名的应用（`make build`）；amfidont 允许该构建。

1. restore 中断
   1. `vphone-cli vm create d4-acc -V regular -l <专用库根> ...`，在输出 `Restoring...` 之后、restore-update 结束之前向 vphone-cli 主进程发送 SIGKILL（不向子进程发信号）。
   2. 立即执行 `vm create-status d4-acc --json`，记录：restore 为 `running`；`live.bundle_lock_held` 的值；`ps -axo pid=,command=` 中 DFU 子进程与 `pymobiledevice3_bridge.py restore-update` 进程是否存在。
   3. 子进程仍存在时执行 `vm create --resume d4-acc`，必须被拒绝且检查点字节不变（对 checkpoint.json 做 `shasum -a 256` 前后比较）。子进程持有 bundle 锁时，拒绝来自续跑第 1 步的 `bundleBusy`，提示首行为 `vm create --resume refused: the bundle is in use`；bundle 锁已释放但 restore 桥接进程、设备端点或该 bundle 的启动进程仍存在时，拒绝来自探测器的 `recovery required (live_state, stage restore)`。两种拒绝都不写入检查点。
   4. 手动终止残留子进程，确认 bundle 锁释放、`recovery-probe --ecid` 无应答，再次续跑。必须记录：新尝试的 `checks["probe.restore"]` 内容；restore 从 DFU 启动重新开始；restore 成功后 cfw、first_boot、verification 依次执行；`attempts/` 下存在上一份检查点归档。
   5. 同一流程再做一次“子进程先退出、主进程后被杀”的顺序，确认 idle 探测与重跑。
2. cfw 中断：在 CFW 挂载期间终止主进程；续跑必须因 bundle 锁或 bundle 内挂载镜像返回 busy；清理挂载后续跑，cfw 重复安装成功，D3 的重复安装结论适用。
3. patch 中断：在 C4 事务 publishing 阶段终止；续跑必须提示 `fw patch --recover`；恢复后续跑，patch 从头执行并提交。另做一次“事务已提交、检查点未写入”（在 archive 之后、成功记录写入之前终止）：续跑必须以 restore_tree 变化拒绝，`--restart-from prepare` 完成。
4. first_boot/verification 断开：终止启动子进程；续跑重跑该阶段；restore_tree 在 verification 完成前保持存在。
5. 每个场景记录：命令、时间、终止信号与目标 pid、`create-status --json` 输出、检查点文件摘要、最终整体状态、产物是否保留。整体状态为 `failed`、`interrupted`、`recovery_required` 或 `incomplete` 时不得报告为创建成功。

## 真实验收记录：场景 1 restore 中断（2026-09-17）

实验设置：签名应用从独立工作树 `.build/d4acc/src` 构建，未替换 `vm-2607` 使用的 `.build/vphone-cli.app`；运行中的 amfidont 以仓库路径前缀放行。库根 `.build/d4acc/lib`，VM `d4-acc`，regular，本地 26.1 / 23B85 iPhone IPSW 与 cloudOS IPSW，`--root-popup`。证据位于 `.build/d4acc/logs/`（受 Git 忽略）。

| 步骤 | 构建 | 结果 |
| --- | --- | --- |
| 首次创建，restore 阶段 `restore-update` 运行约 20 秒后对主进程发送 SIGKILL（09:53:04Z） | `ec9a20f` | 检查点 restore 为 `running`；DFU 宿主与 restore bridge 子进程在 2 秒内自行退出（`s1-ps-before-kill.txt`、`s1-ps-after-kill.txt`） |
| 手动启动该 bundle 的 DFU 宿主后续跑 | `ec9a20f` | 退出码 1，`bundle is busy`；检查点 SHA-256 前后均为 `3d947ec9…`。拒绝来自 bundle 锁检查，未进入实时探测 |
| 停止 DFU 宿主后续跑 | `ec9a20f` | 续跑前检查：prepare/patch 验证通过，AVPBooter 与 restore 树与 patch 记录一致，`probe.restore` 无锁、无启动进程、无 bridge、无 DFU/recovery 端点；上一份检查点归档。restore 从 DFU 重新执行并完成，但验证器在 DFU 子进程退出前检查锁，误判失败并记录 `recovery_required (live_state)`。该缺陷由 `99da011` 修复 |
| 修复后构建，不带 `--accept-tool-change` 续跑 | `c2fac55` | 退出码 1，报告可执行文件 SHA-256 变化；检查点字节不变。拒绝前提示仍输出旧的 recovery_required 内容，提示与本次拒绝原因不一致；该构建上未修复，后续修复见“真实验收发现与修复：restart-from、拒绝提示与启动进程路径” |
| `doctor d4-acc`（签名应用） | `c2fac55` | 签名权益 OK；识别运行中的 vm-2607；`d4-acc` 运行记录为已退出进程；报告检查点中的 recovery_required；退出码 5 |
| 带 `--accept-tool-change` 续跑（10:10:00Z–11:17:28Z） | `c2fac55` | 退出码 0，整体 `succeeded`。restore 10:10:04–10:11:56；cfw 10:11:56–11:17:16（包含管理员认证等待，未单独计时）；first_boot 11:17:16–11:17:25（prompt matched，7 条命令）；verification 11:17:25–11:17:28（prompt_detected）。`attempts/` 保存两份历史检查点；restore 树在 verification 完成后删除并记录为 removed；`restore-info.json` 记录 variant regular |

结论：restore 中断后，续跑在确认无活动子进程和设备端点后从 DFU 重新执行 restore，并依次完成后续阶段；忙碌状态与工具变化均在不修改检查点的前提下拒绝。未覆盖：主进程被杀后子进程仍长时间存活的情况（本次子进程自行退出，改用手动 DFU 宿主模拟）；restore bridge 进程或 DFU 端点仍存在但锁未被持有的实时探测拒绝路径。场景 2–4（cfw、patch、启动阶段中断）尚未执行，D4 真实验收仍在进行。

## 真实验收发现与修复：restart-from、拒绝提示与启动进程路径（2026-09-17）

### 实验设置

- 状态：场景 1 结束后 `d4-acc`（regular）整体 `succeeded`；`restore_tree` 在 verification 完成后被默认清理删除，`prepare` 与 `patch` 两条记录均为 `removed`，`retain_until` 为 patch、restore、cfw、first_boot、verification，`rebuild` 为 `vphone-cli vm create --resume d4-acc --restart-from prepare`（`.build/d4acc/lib/d4-acc/.create-checkpoint/checkpoint.json`）。
- 命令与证据：`vm create --resume d4-acc --restart-from cfw`（`logs/s2a-restart-cfw-refused.log`）；`vm create --resume d4-acc --restart-from prepare --keep-artifacts`（`logs/s2-resume.log`）；场景 1 中不带 `--accept-tool-change` 的续跑（`logs/s1-resume-toolchange.log`）；D5 诊断开发中观察到的 `vm-2607` 启动命令行。
- 本轮只修改代码与测试，未操作任何 VM，未重新执行上述命令。

### 缺陷 5：`--restart-from prepare` 无法重建已删除的 restore 树

- 现象：`--restart-from cfw` 以 `artifact restore_tree needed by cfw was removed; rebuild with: ... --restart-from prepare` 拒绝，符合设计。按提示执行 `--restart-from prepare --keep-artifacts` 后以 `artifact restore_tree needed by patch was removed` 拒绝，提示的恢复命令本身不可执行。
- 原因：`VPhoneCreateRunner.resume` 第 5 步对任一记录为 `removed` 的产物，只要 `retain_until` 中存在不早于重跑起点的阶段就抛出 `artifactUnavailable`，不考虑该产物会由重跑中更早的阶段重新生成。真实执行器已在 `artifactsRewrittenOnRerun(.prepare)` 中声明 `restore_tree`，第 5 步只在可用产物的指纹比较中使用该声明。
- 修复（`sources/VPhoneCore/VPhoneCreateRunner.swift`）：对已删除产物，取重跑阶段中第一个声明重写该产物的阶段作为重新生成阶段；只有 `retain_until` 中不早于重跑起点、且不晚于重新生成阶段的阶段需要已删除的副本。同时重写并使用该产物的阶段（例如声明重写 disk 的 cfw 本身需要 disk）仍被拒绝。未拒绝时写入 `checks["artifact.<name>"]`。`--restart-from patch/restore/cfw/first_boot/verification` 在 restore 树已删除时仍被拒绝，因为 prepare 不重跑。
- 重跑后的状态：第 6 步删除重跑阶段此前记录的全部产物记录，`restore_tree` 的 `removed` 记录随之删除；prepare 验证器重新测量目录并记录为 `available`，patch 执行时从检查点读到 `available` 且目录存在。`VPhoneCreateCheckpoint.artifact(_:)` 由返回第一条同名记录改为返回最晚阶段写入的记录，使真实验证器的 `treeRemoved` 判断基于后续阶段实际使用的记录。
- 真实 prepare 是否重新生成目录（代码阅读结论，未实测）：`VPhoneCreateLiveStages.execute(.prepare)` 调用 `refreshBootROM` 与 `runFWPrepare`；`scripts/fw_prepare.sh` 的 `extract` 在复用或重新解压 IPSW 缓存后执行 `rm -rf "$out"` 与 `cp -R "$cache" "$out"`，即无论 bundle 中目录是否存在都重新生成 restore 目录；`.ipsw` 源文件不被默认清理删除。
- `--keep-artifacts`：续跑时由 `VPhoneVMCreateCLI` 传入 `ResumeOptions.keepArtifacts`，再传给 `VPhoneCreateRuntime` 与 `VPhoneCreateRunner.keepArtifacts`，作用于本次尝试的 `reclaimArtifacts`、真实执行器的 `removeArtifact` 与 `fw prepare` 的 `VPHONE_KEEP_ARTIFACTS`。该选项不写入检查点，每次续跑重新指定；不指定时本次尝试在 verification 完成后再次删除 restore 树。

### 缺陷 6：拒绝提示文本

- 现象 1：缺陷 5 的两次拒绝均输出 `[-] vm create stopped (overall: succeeded); recovery inputs are kept.`。拒绝发生在第一次写入之前，检查点未改变，但提示表述为运行已停止。
- 现象 2：可执行文件变化的拒绝（`s1-resume-toolchange.log`）先输出检查点中上一次尝试记录的 `recovery required: the bundle lock is held ...` 与对应 action，再输出通用 `Inspect`/`Resume`；拒绝原因 `--accept-tool-change` 只出现在 stderr 的 `Error:` 行。
- 原因：`VPhoneCreateOrchestrator.recoveryHintLines` 只对 `bundleBusy`、`runInProgress`、`recoveryRequired` 使用拒绝措辞；其余错误一律输出 "stopped" 首行和检查点中已记录的 `recovery_required`，不区分拒绝是否发生在写入之前。
- 审计结果：`VPhoneCreateRunError` 中在续跑第一次写入之前抛出的为 `runInProgress`、`bundleBusy`、`identityMismatch`、`artifactChanged`、`artifactUnavailable`、`verificationFailed`、`recoveryRequired`、`optionsChanged`、`toolChanged`、`contractChanged`、`invalidRestart`、`sourceRequired`；`io`、`artifactMissing`（运行中被转换为 `stageFailed`）、`stageFailed`、`stageCancelled`、`checkpointWriteFailed` 可能发生在写入之后。修复前只有前三种使用拒绝措辞。
- 修复：
  - `VPhoneCreateRunError.isRefusalBeforeWrite` 按上述分类返回布尔值。
  - `recoveryHintLines`：写入前拒绝的首行为 `[-] vm create --resume refused: <原因>; the checkpoint was not changed (overall: <推导状态>).`，随后是该原因对应的 `action` 行（`refusalGuidance`）：已删除产物给出记录的重建命令；产物变化给出从重写该产物的阶段重跑；工具变化给出 `--accept-tool-change`；契约变化、身份不一致、选项变化、验证失败、无效重跑起点、需要重新提供来源各自给出操作。检查点中已有的 `recovery_required` 仅在 action 之后以 `recorded earlier by attempt <id> (not the cause of this refusal)` 标注输出；续跑前 `recoveryRequired` 拒绝在记录内容与本次不同时同样标注输出。`bundleBusy`、`runInProgress` 提示保持 `99da011` 的内容。
  - "stopped" 首行只用于写入之后的失败，其中的 `recovery_required` 由本次尝试的失败记录写入。

### 缺陷 7：启动进程路径匹配不处理 `..`

- 现象：`vm-2607` 以 `--config /Users/kolar/github/autophone/../vphone-cli/vm-2607/config.plist` 启动。`VPhoneBootProcessLocator.parsePIDs` 只比较 `configPathVariants` 生成的若干种目标路径拼写与命令行参数原文，参数中含 `..` 时不匹配。D5 诊断在 `VPhoneDiagnostics.bootPIDs` 中另行规范化两侧；`VPhoneBundleGuard` 的默认 `bootPIDs`（`requireDFUOwner` 使用）、`VPhoneVMStopper` 与 D4 `VPhoneCreateLiveProber` 直接调用 `parsePIDs`，不匹配该进程。
- 修复（`sources/VPhoneCore/VPhoneLaunchLayout.swift`）：新增 `VPhoneBootProcessLocator.canonicalConfigPath`：绝对路径的父目录存在时用 `realpath(3)` 解析（`.`、`..` 与符号链接按内核方式解析），否则做词法规范化；相对路径原样返回。`parsePIDs(_:configPaths:)` 对目标路径与命令行参数两侧都计算规范路径，原文相等或规范路径相等即匹配。比较对象是完整路径字符串，`vm-2607` 与 `vm-2607-rig2`、`config.plist` 与 `config.plist.bak` 不匹配。`VPhoneDiagnostics.bootPIDs` 改为直接调用 `parsePIDs(_:configURL:)`。
- 限制：`ps` 输出按空白分词，含空格的路径仍不匹配（修复前已存在）；相对 `--config` 路径只做原文比较。

### 测试

| 测试 | 断言 |
| --- | --- |
| `CreateCheckpointTests.restartFromPrepareRegeneratesARemovedRestoreTree` | 完成的创建删除 restore 树后，`--restart-from prepare` 被接受；执行序列为全部 regular 阶段；prepare 执行时检查点无 restore_tree 记录且目录不存在，patch、restore 执行时记录为 `available` 且目录存在；整体 `succeeded`；两条 restore_tree 记录均为 `available` 且无删除原因；`keepArtifacts` 时本次尝试不再删除目录；检查结果含 `regenerated by prepare`；落盘产物记录与返回值一致 |
| `restartFromPrepareWithoutKeepArtifactsRemovesTheTreeAgain` | 不带 `keepArtifacts` 时 patch 仍读到可用目录，完成后再次删除 |
| `restartAfterPrepareWithRemovedTreeIsRefusedWithoutWriting`（patch、restore、cfw、first_boot、verification 共 5 例） | 抛出 `artifactUnavailable(restore_tree, neededBy: 重跑起点, rebuild: --restart-from prepare)`；执行器未运行；检查点字节不变 |
| `removedArtifactStillRefusedWhenTheRegeneratingStageRunsAfterAConsumer` | 已删除产物的重新生成阶段本身也是使用阶段时仍拒绝 |
| `keptStageArtifactsAreStillValidatedWhenARemovedArtifactIsRegenerated` | 已删除产物由重跑阶段重新生成时，被跳过阶段的可用产物被修改后仍以 `artifactChanged` 拒绝且不写入；恢复原内容后续跑执行，检查结果记录两项 |
| `artifactLookupReturnsTheLatestRecord` | `artifact(_:)` 返回最晚阶段的记录 |
| `CreateLiveStagesTests.removedArtifactRefusalLeadsWithItsCauseNotStopped` | 首行为拒绝原因与检查点未改变，第二行为重建命令；不含 "stopped" 与 `Resume:` 行；检查点字节不变 |
| `toolChangeRefusalLeadsWithItsCauseAndLabelsTheRecordedRequirement` | 首行为工具变化与未改变状态，第二行为 `--accept-tool-change` 命令；已记录的 recovery_required 只以 "recorded earlier ... not the cause of this refusal" 出现在 action 之后；检查点字节不变 |
| `everyRefusalBeforeWriteSaysRefusedAndUnchanged` | 12 种写入前拒绝的首行均以 `vm create --resume refused:` 开头并包含原因与 `the checkpoint was not changed`，第二行为 action/detail，不含 "vm create stopped" 与未标注的 recovery_required；`stageFailed`、`stageCancelled`、`checkpointWriteFailed` 保持 "stopped" 首行 |
| `LaunchLayoutTests.matchesConfigPathWithDotDotAndSymlinksButNotPrefixCollisions` | 临时目录中 `autophone/../vphone-cli/vm-2607`、符号链接库根、`./` 拼写匹配 `vm-2607`；`vm-2607-rig2` 的各种拼写（含 `vm-2607/../vm-2607-rig2`）、`config.plist.bak`、相对路径、非 vphone-cli 进程不匹配；目标路径经符号链接或 `..` 给出时结果相同；不存在的路径按词法规范化比较 |

复现：在未修改的 `sources/` 上运行新的 `CreateCheckpointTests`，`restartFromPrepareRegeneratesARemovedRestoreTree`、`restartFromPrepareWithoutKeepArtifactsRemovesTheTreeAgain`、`keptStageArtifactsAreStillValidatedWhenARemovedArtifactIsRegenerated` 3 项失败，其余通过；修复后全部通过。路径匹配测试引用新增的 `canonicalConfigPath`，未在修复前的代码上单独运行。

### 验证记录

工作树 `codex/autophone-location-multivm-integration`，HEAD `b728eb8` 加未提交修改：

| 命令 | 结果 |
| --- | --- |
| `swift build --build-tests` | 构建完成，无错误 |
| `swift test --filter CreateCheckpointTests` | 47 个测试通过 |
| `swift test --filter CreateLiveStagesTests` | 25 个测试通过 |
| `swift test --filter LaunchLayoutTests` | 13 个测试通过 |
| `swift test --filter "DiagnosticsTests\|DoctorCLITests"` | 39 个测试、6 个 suite 通过 |
| `swift test --filter "BundleGuardTests\|VMStopTests"` | 24 个测试、2 个 suite 通过 |
| `make test_swift` | 退出码 0；Swift Testing 462 个测试、63 个 suite 通过；XCTest 143 项、3 项跳过、0 失败 |

`make test_python` 未运行，本轮未修改 Python 或脚本。

### 未验证内容

- （2026-09-17 后续已实测，见“真实验收记录：`8b6365f` 构建”）`--restart-from prepare` 重建目录、patch 提交与 restore 重新执行；修改后的提示文本；`doctor` 对 `vm-2607` 的路径匹配。
- `VPhoneVMStopper` 与 `requireDFUOwner` 在含 `..` 拼写下的行为变化仍只由单元测试覆盖。

## 真实验收记录：`8b6365f` 构建（2026-09-17）

### 实验设置

- 构建：独立工作树 `.build/d4acc/src`，HEAD `8b6365f`，无未提交修改；`make build` 签名应用，运行中的 amfidont 以仓库路径前缀放行。未替换 `vm-2607` 使用的 `.build/vphone-cli.app`，未操作 `vm-2607`（仅执行一次只读 `doctor`）。
- VM：库根 `.build/d4acc/lib`，`d4-acc`，regular，本地 26.1 / 23B85 iPhone IPSW 与 cloudOS IPSW，`--root-popup`。
- 证据：`.build/d4acc/logs/`（受 Git 忽略）。脚本：`s2-run.zsh`、`s2c-watch.zsh`、`s3_freeze.py`、`s3-run.zsh`、`s4-run.zsh`（同目录）。
- 场景 3 的中断点：patch 在 vm create 主进程内执行。`s3_freeze.py` 以 kqueue 监视 `.firmware-transaction`（或 `.firmware-history`），条件满足时先对主进程发送 SIGSTOP、记录目录状态，再发送 SIGKILL。

### 结果

| 场景 | 时间（UTC） | 操作 | 结果 |
| --- | --- | --- | --- |
| `--restart-from prepare`（缺陷 5 复验） | 11:33:25– | 场景 1 完成后 restore 树已删除，执行 `vm create --resume d4-acc --restart-from prepare --keep-artifacts --accept-tool-change` | 被接受；prepare 重新生成 restore 树并通过验证（11:33:29–11:34:11），patch 提交事务并通过验证（11:34:11–11:34:34）。restore 阶段挂起，见“问题：restore 桥接进程挂起” |
| 1 补充：主进程被杀后子进程存活 | 11:52:34 | 挂起状态下对主进程 49939 发送 SIGKILL | DFU 宿主 50666 与 restore 桥接进程 50692 均存活，PPID 变为 1；`live.bundle_lock_held = true`，restore 为 `running`，整体 `interrupted`（`s1b-ps-after-kill.txt`、`s1b-status-after-kill.json`） |
| 1 补充：子进程持锁时续跑 | 11:52:34 与 11:53:01 之间 | `vm create --resume d4-acc` | 退出码 1；首行 `vm create --resume refused: the bundle is in use; the checkpoint was not changed (overall: interrupted).`，列出 `pid 50666 running operation "dfu"`，随后为停止、确认锁释放和续跑的操作说明；检查点 SHA-256 前后均为 `4553bff7…`（`s1b-resume-busy.log`） |
| 1 补充：停止子进程后续跑 | 11:53:01–11:55:10 | 对 DFU 宿主发送 SIGINT；桥接进程随设备连接中断退出（`ConnectionTerminatedError`）；续跑 | `probe.restore`：`bundle lock free; no boot process; no restore bridge process for 0xCECF1D19F7EF01FA; no DFU/recovery endpoint for 0xCECF1D19F7EF01FA`；restore 从 DFU 重新执行，11:53:16–11:55:10 succeeded，DFU 结果 `matched` |
| 2 cfw 中断 | 11:56:37 | CFW 挂载出现 15 秒后对主进程 60457 发送 SIGKILL | root 身份的 `cfw_install_host.sh`（62369）继续运行并持有 bundle 锁；cfw 为 `running`。续跑退出码 1，提示 `pid 62369 running operation "cfw"`；检查点 SHA-256 前后均为 `8212cb9a…`（`s2c-*`） |
| 2 残留进程退出后续跑 | 11:57:28–11:59:23 | 残留 CFW 进程 11:57:28 退出（是否完成安装未确认）；之后无 `hdiutil` 挂载、无 `.cfw_mount.*`，锁释放；续跑 | `probe.cfw`：`bundle lock free; no boot process; no attached image inside the bundle`；从 cfw 续跑，cfw 重复安装 succeeded（11:57:53–11:59:10，输出 `no com.apple.os.update-* root snapshot found (already flipped?)`），first_boot、verification succeeded，整体 `succeeded`，restore 树在 verification 后删除 |
| 3a patch publishing 中断 | 12:02:02 | 从 prepare 重跑；journal 为 `publishing` 时冻结并杀主进程 | 冻结时 `backup/` 为空，`stage/` 含 AVPBooter 与 restore 树（`s3a-frozen.json`）。续跑退出码 1：`refused: recovery required (firmware_transaction, stage patch)`，detail `phase publishing`，action `vphone-cli fw patch d4-acc --recover`；检查点 SHA-256 不变（`a1379876…`）。`fw patch --recover -l … d4-acc` 退出码 0，归档 `5ae8f176…`，`.firmware-transaction` 已移除 |
| 3b 事务已提交、检查点未写入 | 12:02:07–12:02:29 | 续跑重新执行 patch；`.firmware-history` 出现新归档 `30ebddbd…` 时冻结并杀主进程 | patch 仍为 `running`。续跑退出码 1：`refused: artifact avpbooter recorded by prepare changed (fingerprint fc94622f710a -> 8200ba0d93b0)`，action 为 `--restart-from prepare` 或删除重建；检查点 SHA-256 不变（`df557aaf…`）。与“待执行的真实 VM 验收”第 3 项的差异：拒绝由 avpbooter 指纹变化触发，未报告 restore_tree；两者均为已提交 patch 改写的产物，产物按记录顺序比较，首个不一致即拒绝 |
| 3 完成 | 12:02:30–12:06:50 | `--restart-from prepare` | 退出码 0；prepare、patch（新事务 `f1e207e4…`，58 条记录）、restore、cfw、first_boot、verification 均 succeeded，整体 `succeeded` |
| 4a first_boot 断开 | 12:07:46–12:11:53 | 从 prepare 重跑；first_boot 启动子进程出现 1 秒后发送 SIGKILL | 主进程退出码 1：`stage first_boot failed: first boot exited before command injection (exit 9)`；整体 `failed`；restore 树保留 |
| 4b 续跑与 verification 断开 | 12:11:53–12:12:03 | 续跑；first_boot 子进程退出后，对 verification 启动子进程发送 SIGKILL | 续跑从 first_boot 开始，first_boot succeeded（prompt matched）；verification failed：`boot analysis: process exited before success marker (exit 9)`；整体 `failed`；restore 树保留 |
| 4c 续跑 | 12:12:03–12:12:07 | 续跑 | 只执行 verification，succeeded（prompt_detected）；整体 `succeeded`；restore 树删除并记录 |

检查点 `attempts/` 在本轮结束时保存 12 次尝试（`doctor` 报告 `attempts: 12`）。

### 其他确认

- 缺陷 6 的拒绝提示在真实输出中确认：bundle 占用、C4 事务、产物变化三类拒绝的首行均为 `vm create --resume refused: …; the checkpoint was not changed (…)`，未出现 "stopped" 首行。
- 缺陷 7：`doctor vm-2607 -l ~/github/vphone-cli --json`（本构建）报告 `vm_running` 的 `boot_pids: 41303`、`record_pid_is_boot_process: true`；该 VM 以含 `..` 的 `--config` 路径启动，`VPhoneDiagnostics.bootPIDs` 现直接调用 `parsePIDs`（`d5-doctor-vm2607-8b6365f.json`）。

### 问题：restore 桥接进程挂起

- 现象（事实）：11:34:57 后，`pymobiledevice3_bridge.py restore-update` 经本机 HTTP 代理 127.0.0.1:10808 请求 `fcs-keys-pub-prod.cdn-apple.com` 时出现 `requests.exceptions.SSLError … UNEXPECTED_EOF_WHILE_READING`；之后约 17 分钟无输出，进程 CPU 0%，唯一 TCP 连接为 CLOSED，未退出；vm create 主进程持续等待。约 11:51 手动以 curl 经代理与直连请求同一 URL，均返回 200。
- 代码分析（只读，pymobiledevice3 11.9.2，路径相对 site-packages）：
  - 请求在 `pymobiledevice3/restore/restore.py:1443` 的 `send_url_asset` 中经线程池执行，所在任务由 `handle_async_data_request_msg`（`restore.py:182-188`）以 `asyncio.create_task` 创建；`self._tasks` 只追加，不 await、不检查，任务异常不传到主协程。
  - 异常路径跳过向设备回复与关闭该数据连接（`restore.py:1446-1463`）；主协程停在无超时的 `await self._restored.recv()`（`restore.py:1680`）。
  - vphone-cli 侧 `VPhoneProcessRunner.runStreaming`（`sources/VPhoneCore/VPhoneProcessRunner.swift:204-227`）只调用 `waitUntilExit()`，对 restore-update 无超时或无输出检测。
- 推断：设备端在等待密钥响应，因而停止读取 ASR 数据；requests 默认不重试，一次代理连接中断即导致挂起。原因中“代理连接中断的来源”未查明。
- 影响：vm create 在 restore 阶段无限等待。恢复路径已由本轮场景 1 补充确认：终止主进程与子进程后续跑，restore 重新执行。
- 可选方向（未实现、未验证）：桥接脚本对后台任务异常以非零退出；对 URL 资源请求增加超时与重试；vphone-cli 对 restore-update 增加无输出或总时长上限；主进程收到 SIGINT/SIGTERM 时回收子进程。

#### 修复

版本依据：`requirements.txt` 为 `pymobiledevice3>=9.5.0`；D2 锁文件 `dependencies/python-darwin-arm64-3.13.lock` 锁定 `pymobiledevice3==11.9.2`、`requests==2.34.2`。`~/.vphone/venv`（Python 3.13.13）与项目 `.venv`（Python 3.14.5）安装的均为 11.9.2。以下兼容性判断以 11.9.2 为准。

改动（只涉及 `scripts/pymobiledevice3_bridge.py`，Swift 未改）：

- URL 资源请求：`restore-update` 使用 `Restore` 的子类，覆盖 `send_url_asset`。回复内容照搬 11.9.2：`ResponseBody`、`ResponseBodyDone`、`ResponseHeaders`、`ResponseStatus`，`FMT_BINARY`，之后 `service.close()`；缓存命中逻辑不变。网络获取 `fetch_url_asset` 改为：超时 (连接 15 秒, 读取 60 秒)，最多 4 次尝试，间隔 2/4/8 秒。只对 `requests` 的 `ConnectionError`（含 `SSLError`、`ProxyError`）、`Timeout`、`ChunkedEncodingError` 与 HTTP 5xx 重试。其他异常立即抛出。异常类错误重试耗尽时抛出 `URLAssetFetchError`，不向设备回复；5xx 重试耗尽时与上游一致，将最后的响应转发给设备，但不写入缓存。任务被取消时通过 `threading.Event` 停止后续重试。
- 结构检测：启动时检查 `Restore.send_url_asset` 存在、为协程、参数为 `(self, message)`，源码包含上述回复字段、`_get_service_for_data_request`、`_url_assets_cache`、`requests.get`、`service.close()`。任一不符时打印 `[!] warning: URLAsset retry disabled; …`，使用原 `Restore`。构造后检查 `_data_request_handlers["URLAsset"]` 是否指向子类方法，不符时警告。
- 后台任务：`restore.update()` 以任务运行，每 0.5 秒检查 `Restore._tasks`。任一任务以非 `CancelledError` 异常结束时，取消 update 与其他未完成任务（各等待不超过 5 秒），打印 `[-] restore-update failed: background task '<名称>' raised <异常类型>: <内容>`，退出码 1。正常返回或被取消的任务不计为失败。`update()` 返回后不再检查任务，以避免设备重启时 FDR 连接断开被计为失败。`_tasks` 不是列表时打印警告并按原方式运行。
- 故障注入（仅用于验收）：环境变量 `VPHONE_BRIDGE_FAULT_URL_ASSET=<N>` 使本进程前 N 次 URL 资源获取尝试在访问网络前抛出 `requests.exceptions.SSLError`；`always` 使每次尝试都失败；未设置或 `0` 时无行为变化；其他值退出码 2。启用时打印警告。

测试：新增 `tests/test_pymobiledevice3_bridge.py`（27 项，不连设备）。其中 `test_background_task_failure_exits_nonzero_instead_of_hanging` 以子进程运行脚本入口并替换 Restore/usbmux/IPSW；修复前该测试在 45 秒超时处失败，修复后约 1 秒以非零退出。其余覆盖：暂态失败后重试成功并按原协议回复与关闭、重试耗尽、非暂态错误与 4xx 不重试、5xx 重试与不缓存、退避间隔、故障注入计数与取值解析、结构不符时退回并警告、锁定版本 `Restore` 通过结构检测、正常/取消任务不触发失败、update 返回后的任务失败不报告、子类 + 故障注入 + 监视的组合（N=1 完成，`always` 3 秒内失败）。`make test_python`：153 项通过。

#### 实机验收（2026-09-17）

实验设置：`.build/d4acc/src`（HEAD `8b6365f`）应用本修复的 bridge 改动后 `make build` 签名；`d4-acc`，regular 26.1 / 23B85，`--root-popup -v`。上一轮 CFW 以 root 运行后在应用包 `Contents/Resources/scripts/patchers/__pycache__` 留下 root 属主文件，`make build` 删除旧包失败；将旧包移至 `.build/d4acc/stale/` 后构建成功（见“其他发现”）。脚本 `.build/d4acc/s5-run.zsh`，证据 `.build/d4acc/logs/s5*`。

| 步骤 | 时间（UTC） | 结果 |
| --- | --- | --- |
| `VPHONE_BRIDGE_FAULT_URL_ASSET=1`，`--restart-from prepare --keep-artifacts --accept-tool-change` | 12:29:38–12:34:12 | 启动时打印注入警告。URLAsset `https://wkms-public.apple.com/fcs-keys/…` 第 1 次为注入的 SSLError（12:31:09）；第 2 次为真实的经代理 `SSLEOFError UNEXPECTED_EOF_WHILE_READING`（12:31:13，非注入）；第 3 次成功，restore 继续并通过验证。全部阶段 succeeded，退出码 0 |
| `VPHONE_BRIDGE_FAULT_URL_ASSET=always`，`--restart-from restore --keep-artifacts` | 12:34:12–12:34:58 | 4 次尝试（间隔 2/4/8 秒）后打印 `[-] restore-update failed: background task 'AsyncDataRequestMsg-URLAsset' raised URLAssetFetchError: … 4 attempts failed …`；vm create 输出 `Error: stage restore failed: restore-update failed (exit 1)`，退出码 1。检查点 restore 为 failed，整体 `failed`；无桥接或 DFU 残留进程，bundle 锁已释放（`s5b-status.json`、`s5b-ps.txt`） |
| 不设变量续跑 | 12:35:00–12:38:27 | 从 restore 续跑；restore 12:35:04–12:36:56 succeeded，cfw、first_boot、verification succeeded，整体 `succeeded`，restore 树删除；无残留进程 |

结论：真实 restore 中，URL 资源请求失败后的重试结果被设备接受并完成 restore；重试耗尽时 restore-update 在约 14 秒重试窗口后以非零退出，vm create 将 restore 记为 failed 并可续跑。第 2 次尝试出现的真实 SSL EOF 表明该代理路径上的连接中断会重复出现（事实）；中断来源仍未查明。

未验证内容：

- 单次尝试读取超时（60 秒）与总重试时长（最长约 4×75+14 秒）是否在设备端等待上限之内；本轮失败均为立即抛出的连接错误。
- 本轮均使用 `-v`；默认输出级别下桥接警告与失败原因是否可见未确认。
- FDR 等其他后台任务在 restore 期间以非 `ConnectionTerminatedError` 异常结束时现在会使 restore 失败；本轮三次 restore 未出现该情况。
- 若运行环境只含 `.pyc` 而无源码，结构检测会退回原实现（有警告）。

#### 其他发现：root CFW 安装在应用包内写入字节码缓存

- 现象（事实）：`--root-popup` 的 CFW 安装后，`.build/d4acc/src/.build/vphone-cli.app/Contents/Resources/scripts/patchers/__pycache__/*.cpython-313.pyc` 属主为 root；随后以普通用户 `make build` 在删除旧应用包时报 `Directory not empty` 失败。`.build/d4acc/stale/vphone-cli.app-pycache-193301` 为较早一次同类残留。
- 推断：root 身份的 Python 从应用包内导入 `patchers` 模块并写入 `__pycache__`；`scripts/build.sh` 打包时排除 `__pycache__`，但不阻止运行时写入。是否影响应用包签名校验未验证。
- 未修复；可选方向：CFW 安装以 `PYTHONDONTWRITEBYTECODE=1` 运行 Python，或设置 `PYTHONPYCACHEPREFIX` 到应用包外。

### 仍未覆盖

- 桥接进程或设备端点仍存在、但 bundle 锁已释放时的实时探测拒绝（`recovery required (live_state, stage restore)`）：本轮停止 DFU 宿主后桥接进程随即退出，未形成该状态；该路径只由无 VM 测试覆盖。
- first_boot/verification 阶段主进程（而非启动子进程）被杀的情况；jb、exp、dev、less 变体的真实中断续跑。
- 场景 2 中残留 CFW 进程退出前是否完成安装未确认；续跑的 cfw 按重复安装处理，D3 的重复安装结论适用。
- 生产等待上限（锁 30 秒、子进程 60 秒）的实际余量未测量；本轮子进程均在上限内退出。
