# D5：统一环境与 VM 诊断输出

日期：2026-09-17。基线：`ec9a20f`。

状态（2026-09-17 更新）：签名应用运行、E2 之后构建启动的 VM 上的客户机连接探测、D4 完成后的创建状态报告已实测，D5 完成；见“签名应用与客户机连接验收”。

原状态：`vphone-cli doctor` 只读诊断命令、文本与 JSON 输出、稳定类别与代码、脱敏规则和无 VM 测试已实现。已对真实宿主、运行中的 `vm-2607`（只读）和 `.build/c5` 记录执行命令并保存样例。未执行任何修复动作；清单未修改。

## 代码位置

| 路径 | 内容 |
| --- | --- |
| `sources/VPhoneCore/VPhoneDiagnostics.swift` | 类别、严重级别、代码、finding、脱敏器、报告（文本/JSON、退出码） |
| `sources/VPhoneCore/VPhoneDiagnosticChecks.swift` | 可注入探测（`VPhoneDiagnosticProbes`）与全部检查（`VPhoneDiagnostics`） |
| `sources/vphone-cli/VPhoneDoctorCLI.swift` | `doctor` 命令；`--patch-record` 读取 C5 实验记录 |
| `sources/VPhoneCore/VPhoneProcessRunner.swift` | `runCapturing` 新增可选 `timeout`；设置时 stdin 为 `/dev/null`，到期终止子进程并标记 `timedOut` |
| `sources/VPhoneCore/VPhoneResources.swift` | 新增 `pythonCandidates`（`pythonExecutable()` 改为使用同一候选顺序）、`coreRuntimeResources`、`runtimeResources`、`pythonRuntimeCheckScript` |
| `sources/vphone-cli/VPhoneResourcesCLI.swift` | 改用 `coreRuntimeResources`，检查的 4 个文件不变 |
| `sources/FirmwarePatcher/Pipeline/PatchExperimentRecord.swift` | 新增只读公开访问器（run id、variant、失败阶段/组件、错误、失败的必需补丁、事务状态） |
| `tests/VPhoneCoreTests/DiagnosticsTests.swift`、`tests/VPhoneCLITests/DoctorCLITests.swift` | D5 测试 |

## 命令

```text
vphone-cli doctor [<vm-name>] [--json] [-l <library-root>] [--patch-record <record.json>] [-p <resource-base>]
```

- 不给 VM 名称：宿主检查，加库摘要。库摘要对每个 bundle 执行 VM 检查（不含客户机探测），只列出非 ok 结果。
- 给 VM 名称：宿主检查，加该 VM 的全部检查，包括主机控制 socket 探测。
- `--patch-record`：追加一条 C5 实验记录的检查。没有默认记录路径，未传入时不报告补丁运行记录。
- 命令不执行修复。`suggested_action` 只是文本，不会被执行。

### 退出码

| 退出码 | 条件 |
| --- | --- |
| 0 | 所有 finding 为 ok |
| 3 | 最严重为 warning |
| 4 | 最严重为 unknown（检查无法运行，可能掩盖错误，因此排在 warning 之上） |
| 5 | 最严重为 error |
| 64 | 参数错误（ArgumentParser） |
| 1 | 命令自身抛错（例如 JSON 编码失败） |

VM 不存在不抛错，报告为 `input/vm_not_found`（error，退出码 5）。

## JSON 结构（schema `vphone.diagnostics`，版本 1）

顶层键固定为 `schema`、`schema_version`、`generated_at`、`read_only`（恒为 true）、`scope`（`vm`、`library_root`）、`tool_commit`、`summary`（`worst_severity`、`exit_code`、`counts`）、`findings`。

每个 finding 固定含 `category`、`code`、`severity`、`message`、`evidence`（字符串到字符串）、`suggested_action`、`vm`；缺值编码为 `null`。finding 按类别顺序分组：environment、dependency、occupancy、input、patch、restore、guest_runtime、internal；组内保持检查顺序。

兼容规则：新增代码兼容；改名或删除代码、类别、严重级别不兼容。测试 `vocabularyIsStable` 与 `jsonSchemaIsStable` 固定当前词表和键集合。

## 类别与代码

| 类别 | 含义 | 代码 |
| --- | --- | --- |
| environment | 宿主 OS、虚拟化支持、SIP/research guests、签名权益、磁盘空间 | `macos_version`、`hypervisor_support`、`nested_virtualization`、`sip_status`、`research_guests`、`signing_entitlements`、`disk_space` |
| dependency | Python 运行时、运行资源、宿主工具 | `python_runtime`、`runtime_resources`、`host_tools` |
| occupancy | 锁、运行进程、已挂载镜像、挂载残留 | `library_lock`、`running_vm_processes`、`vm_running`、`vm_idle`、`vm_operation_in_progress`、`vm_lock_holder_unknown`、`vm_boot_process_without_lock`、`create_run_in_progress`、`attached_images`、`cfw_mount_residue` |
| input | 库、bundle、manifest、文件、检查点文件 | `library_root`、`bundle_unreadable`、`vm_not_found`、`vm_manifest_invalid`、`vm_files`、`create_checkpoint_absent`、`create_checkpoint_invalid` |
| patch | 固件事务、事务历史、补丁实验记录 | `firmware_transaction_pending`、`firmware_history`、`patch_record`、`patch_record_failed`、`patch_record_running`、`patch_record_invalid` |
| restore | 恢复后记录的版本和机器标识 | `restore_state` |
| guest_runtime | 主机控制 socket 与客户机 vphoned 连接 | `guest_not_running`、`guest_connected`、`guest_disconnected`、`host_control_socket_missing`、`host_control_unreachable`、`host_control_capabilities_unavailable` |
| internal | 检查本身失败 | `check_failed` |

创建状态代码 `create_succeeded`、`create_incomplete`、`create_interrupted`、`create_stage_failed`、`create_cancelled`、`create_completed_unverified`、`create_recovery_required` 的类别由阶段决定：

| D4 阶段 | 类别 |
| --- | --- |
| prepare | input |
| patch、cfw | patch |
| restore | restore |
| first_boot、jb_finalize、verification | guest_runtime |

`create_recovery_required` 的类别按 `kind`：`firmware_transaction` → patch，`live_state` → occupancy，其他按阶段。`create_succeeded` 归入 guest_runtime（最后阶段为 verification）。create/resume 运行锁被持有时，存储状态中的 `running` 阶段表示正在执行，报告为 `occupancy/create_run_in_progress`（ok），不报告 `create_interrupted`。

`patch_record_failed` 的类别：存在失败的必需补丁时为 patch；否则按记录的失败阶段，`notStarted`、`preflight`、`prepare`、`stageInputs` 为 input，其余为 patch。

## 检查内容与判定

| 代码 | 数据来源 | 判定 |
| --- | --- | --- |
| `macos_version` | `ProcessInfo.operatingSystemVersion` | 主版本 < 15 为 error |
| `hypervisor_support` / `nested_virtualization` | `sysctl kern.hv_support` / `kern.hv_vmm_present` | 读不到为 unknown |
| `sip_status` | `csrutil status`（5 秒超时） | disabled 为 ok；enabled 或 Custom Configuration 为 warning，并列出各项开关；无法运行或无法识别为 unknown |
| `research_guests` | `csrutil allow-research-guests status`（stdin 为 `/dev/null`，5 秒超时） | enabled 为 ok，disabled 为 error；多个 macOS 安装需要选择时为 unknown |
| `signing_entitlements` | `SecTaskCopyValueForEntitlement`（当前进程） | 缺少 `com.apple.security.virtualization`、`com.apple.private.virtualization`、`com.apple.private.virtualization.security-research` 任一项为 error；无法读取为 unknown。证据含 `amfidont_running`（进程列表中是否出现 amfidont） |
| `disk_space` | 库根目录（或最近的已存在上级）所在卷的可用容量 | < 50 GiB 为 warning。该阈值为经验值，未经创建流程实测 |
| `python_runtime` | 与 `pythonExecutable()` 相同的候选顺序（`VPHONE_PYTHON` 或 dev `.venv`、托管 venv），对每个可执行候选运行 `check_python_runtime.py --locked --json`（60 秒超时，`PYTHONDONTWRITEBYTECODE=1`） | 第一个通过者为 ok；`VPHONE_PYTHON` 设置但未通过时不再尝试其他候选；全部失败为 error；检查脚本缺失为 unknown。不创建或修复 venv |
| `runtime_resources` | `VPhoneResources.runtimeResources`（15 个文件） | 缺失或为空为 error。完整应用包清单仍由 `scripts/check_bundle.py` 检查 |
| `host_tools` | 在本进程 PATH 与可执行文件目录中查找 | `ipsw`、`aea`、`ldid`、`gtar` 任一缺失，或 `aria2c`、`curl`、`wget` 全部缺失，为 error；只被 jb/exp 使用的 `zstd`、`xcrun` 缺失为 warning |
| `library_lock` | 库根目录非阻塞 flock 探测 | 始终 ok，证据为是否被持有 |
| `running_vm_processes` | `ps -axo pid=,command=` | 列出 `vphone-cli ... --config` 进程；读不到为 unknown |
| `vm_running` / `vm_operation_in_progress` / `vm_lock_holder_unknown` / `vm_idle` / `vm_boot_process_without_lock` | bundle 目录非阻塞 flock 探测、`.vphone-runtime.json`、`VPhoneProcessInfo`、进程列表 | 锁被持有且记录的 pid 存活：boot/dfu 为 ok，其他操作为 warning；锁被持有但记录缺失或 pid 已退出为 warning；锁空闲但有进程使用该 config.plist 为 error；锁空闲为 ok，旧记录只作为证据 |
| `attached_images` | `hdiutil info -plist` | bundle 内镜像在无持有者时为 warning；读不到为 unknown |
| `cfw_mount_residue` | bundle 下 `.cfw_mount.*` | 无持有者时为 warning |
| `firmware_transaction_pending` | `.firmware-transaction/journal.json` | 存在即 error，建议 `vphone-cli fw patch <name> --recover`；持有者为 `fw-patch` 时为 ok |
| `firmware_history` | `.firmware-history/*/journal.json` 中最新一项 | committed 为 ok，其他或不可读为 warning |
| `restore_state` | `VPhoneRestoreInfo.load`、manifest `machineIdentifier` | 版本不可得为 warning；有版本但无机器标识为 warning |
| `create_*` | `VPhoneCreateCheckpointStore.load`（不取锁） | 见上文类别表；检查点损坏或 schema 不支持为 `input/create_checkpoint_invalid` error |
| `guest_*` / `host_control_*` | 仅在持有者为 boot 时，向 `<bundle>/vphone.sock` 发送一次 `{"t":"capabilities"}`（3 秒收发超时） | socket 不存在或无法应答为 error；返回 `ok:false` 为 unknown；`guest_connected=false` 为 warning |

## 只读性

- 不启动、停止、恢复、挂载，不执行 CFW，不使用 sudo，不写文件。
- 锁探测沿用 `vm create-status` 的做法：`flock(LOCK_EX|LOCK_NB)` 成功后立即释放，不写运行记录，不等待。已知限制：锁空闲时探测会短暂持有锁；若另一个进程恰在该时刻非阻塞取锁，该进程会失败。该竞争窗口未测量。
- 主机控制探测只发送 `capabilities`。该命令在 E2 中定义为不需要客户机连接的状态查询。该请求会在 VM 进程中占用一个连接名额直到应答。
- Python 检查会执行 Python 解释器并导入依赖包；已设置 `PYTHONDONTWRITEBYTECODE=1`。
- 不读取客户机文件、串口日志或 `/var/log/vphone_jb_setup.log`。

## 脱敏规则

所有 message、evidence 值和 suggested_action 在生成报告时经过 `VPhoneDiagnosticRedactor`：

| 输入 | 输出 |
| --- | --- |
| URL 用户信息、查询、片段 | `https://<redacted>@host/path?<redacted>#<redacted>` |
| 名称含 password/passwd/token/secret/api-key 的命令行参数值 | `--sudo-password <redacted>` |
| `*_TOKEN=`、`password:` 等赋值 | 值替换为 `<redacted>` |
| `Bearer`/`Basic` 凭据 | `Bearer <redacted>` |
| 名称含 password、token、secret、askpass、api_key、authorization、cookie、credential 的 evidence 键 | 整个值替换为 `<redacted>` |
| 当前用户主目录前缀 | `~` |

检查实现不收集环境变量值：`VPHONE_PYTHON` 设置时只输出 `(from VPHONE_PYTHON)`。Python 检查只报告版本、锁文件名和不一致的包名，不输出包列表。创建检查点中的来源 URL 在 D4 写入时已经去除凭据，doctor 输出前再次脱敏。

限制：正则规则只覆盖上表形式；其他格式的秘密（例如没有键名的裸令牌）不会被识别。主目录以外的路径（例如 `/private/tmp/...`）原样输出。

## 测试

命令与结果（本机 macOS 26.5 / 25F71，Swift 6.3）：

| 命令 | 结果 |
| --- | --- |
| `swift test --disable-sandbox --filter "Diagnostics\|DoctorCLITests"` | 39 项测试、6 个 suite 通过 |
| `make test_swift` | 退出码 0；Swift Testing 452 项、63 个 suite 通过；XCTest 143 项执行，3 项跳过，0 失败 |

未运行 `make test_python`：本次没有修改 Python 代码或脚本。

运行 `make test_swift` 时，工作区中还有其他任务对 D4 文件（`VPhoneCreateCheckpointStore.swift`、`VPhoneCreateLiveStages.swift`、`VPhoneCreateOrchestrator.swift`、`VPhoneVMCreateCLI.swift` 及其测试）的未提交修改；上述计数包含这些修改。

D5 测试覆盖（`DiagnosticsTests.swift` 5 个 suite，`DoctorCLITests.swift` 1 个 suite）：

| 要求 | 测试 |
| --- | --- |
| 严重级别到退出码 | `severityMapsToExitCodeAndUnknownOutranksWarning`、`reportExitCodeFollowsWorstFindingAndCommandParses` |
| JSON 结构与词表稳定 | `jsonSchemaIsStable`、`vocabularyIsStable` |
| 脱敏 | `redactsCredentialsQueriesSecretsAndHome`、`reportRedactsEvidenceMessagesAndActions`、`checkpointErrorWithCredentialsIsRedactedEndToEnd`、`environmentOverrideValueIsNeverReported`、`pythonLockMismatchNamesPackagesOnly` |
| 缺少 Python 运行时 | `missingPythonRuntimeIsDependencyError`、`missingRuntimeCheckScriptMakesPythonUnknown` |
| 缺少资源 | `missingResourcesAreDependencyError` |
| 缺少签名权益 | `environmentProblemsAreEnvironmentCategory`、`unreadableEntitlementsAreUnknownAndCustomSIPIsWarning` |
| 缺少工具 | `missingToolsAreDependencyErrorOrWarning` |
| 检查点损坏 | `corruptCheckpointIsInputError` |
| 未恢复的固件事务 | `pendingFirmwareTransactionIsPatchError` |
| 过期锁与运行记录 | `staleRuntimeRecordWithFreeLockIsIdle`、`heldLockWithDeadRecordIsHolderUnknown`、`bootProcessWithoutLockIsOccupancyError` |
| environment/dependency/input/patch/restore/guest_runtime 区分 | `environmentProblemsAreEnvironmentCategory`、`missing*`、`missingVMAndFilesAreInputErrors`、`failedCreateStageCategoryFollowsStage`、`failedPatchRunRecordIsPatchError`、`unrestoredBundleIsRestoreWarning`、`guestRuntimeFindingsForRunningVM` |
| 真实 socket 与超时 | `capabilitiesQueryParsesAnswersFromARealSocket`、`boundedRunnerTimesOutAndClosesStdin` |

`capabilitiesQueryParsesAnswersFromARealSocket` 曾在一次完整并行运行中失败：假服务端使用 GCD 全局队列，3 秒内未被调度，客户端读超时。改为独立线程并在测试中使用 30 秒超时后通过。该失败由测试负载引起，与生产超时值无直接对应关系。

## 真实只读样例

宿主与运行中的 `vm-2607` 使用 `swift build` 生成的未签名调试二进制 `.build/debug/vphone-cli` 执行，因此 `signing_entitlements` 为 error。未运行 `make build`，因为 `vm-2607` 正在使用 `.build/vphone-cli.app`。

### 宿主（默认库），退出码 5

```text
[environment]
  OK      macos_version: macOS 26.5.0
  OK      hypervisor_support: Hypervisor support is available
  OK      nested_virtualization: host is not itself a VM
  WARNING sip_status: SIP is partially enabled; launching the signed binary depends on an AMFI bypass such as amfidont
  OK      research_guests: research guests are allowed
  ERROR   signing_entitlements: this vphone-cli binary lacks the private virtualization entitlements; it can diagnose but not boot
            amfidont_running: true
            executable: ~/github/vphone-cli/.build/arm64-apple-macosx/debug/vphone-cli
            missing: com.apple.security.virtualization, com.apple.private.virtualization, com.apple.private.virtualization.security-research
            suggested (not run): make build (then run .build/vphone-cli.app/Contents/MacOS/vphone-cli)
  OK      disk_space: free space on the library volume
[dependency]
  OK      python_runtime: locked Python runtime verified
            lock: python-darwin-arm64-3.14.lock
            python: ~/github/vphone-cli/.venv/bin/python3
            source: dev_venv
            version: 3.14.5
  OK      runtime_resources: runtime resources are present
  OK      host_tools: host tools are present
[occupancy]
  OK      library_lock: library lock is free
  OK      running_vm_processes: 1 vphone-cli VM process(es) running
[input]
  OK      library_root: 1 VM bundle(s), 0 unreadable
summary: worst=error exit=5 ok=11 warning=1 unknown=0 error=1
```

（证据行部分省略。）

### 运行中的 `vm-2607`（`-l ~/github/vphone-cli --json`），退出码 5

```json
{"summary": {"counts": {"error": 1, "ok": 14, "unknown": 1, "warning": 1}, "exit_code": 5, "worst_severity": "error"}}
```

VM 相关 finding：`occupancy/vm_running` ok（`record_pid_is_boot_process: true`），`input/vm_files` ok，`input/create_checkpoint_absent` ok，`restore/restore_state` ok（iOS 与 cloudOS 26.1 (23B85)，`variant: unrecorded`），以及：

```json
{
  "category": "guest_runtime",
  "code": "host_control_capabilities_unavailable",
  "evidence": {"reason": "unknown command: capabilities", "socket": "~/github/vphone-cli/vm-2607/vphone.sock"},
  "message": "host control answers but rejected the capabilities request (a VM started from an older build?); guest connection not determined",
  "severity": "unknown",
  "suggested_action": null,
  "vm": "vm-2607"
}
```

事实：该 VM 于 2026-09-16 由 `~/github/autophone/../vphone-cli/.build/vphone-cli.app` 启动，其主机控制返回 `unknown command: capabilities`。推断：该进程加载的是 E2 之前的构建；未核对其二进制版本。

该 VM 的 `--config` 路径含 `..`。`VPhoneBootProcessLocator.parsePIDs` 不对 ps 中的路径做规范化，第一次运行时未匹配到该进程（`boot_pids` 为空）。doctor 另外对两侧路径做 `standardized` 与符号链接解析后匹配成功。`VPhoneBundleGuard.requireDFUOwner` 与 D4 `VPhoneCreateLiveProber` 仍直接使用 `parsePIDs`，对这种路径写法可能判断为“没有启动进程”；该影响为待验证假设，本次未修改这两处。

### 组件缺失与状态损坏（临时目录）

临时库 `broken` 含截断的 `checkpoint.json`、`phase: publishing` 的 `.firmware-transaction`（failure 文本含带凭据和 query 的 URL）、`.cfw_mount.AbCd1234`、pid 999999 的旧 boot 运行记录，无 Disk.img 与 ROM；`--project-root` 指向空目录。退出码 5，`ok=10 warning=3 unknown=0 error=6`。节选：

```text
[dependency]
  ERROR   python_runtime: no Python runtime passes the locked capability check
  ERROR   runtime_resources: 15 runtime resource(s) are missing or empty
[occupancy]
  OK      vm_idle (broken): VM is not running; the runtime record is from an earlier holder and is diagnostic only
            record_pid: 999999
            record_pid_alive: false
  WARNING cfw_mount_residue (broken): CFW mount directories remain from an earlier install
[input]
  ERROR   vm_files (broken): files named by config.plist are missing
            missing: Disk.img, AVPBooter.vresearch1.bin, AVPSEPBooter.vresearch1.bin
  ERROR   create_checkpoint_invalid (broken): the create checkpoint is corrupt or unsupported
            suggested (not run): vphone-cli vm create-status broken
[patch]
  ERROR   firmware_transaction_pending (broken): an uncommitted firmware transaction blocks every other bundle operation
            failure: write https://<redacted>@example.com/x?<redacted> failed
            phase: publishing
            suggested (not run): vphone-cli fw patch broken --recover
[restore]
  WARNING restore_state (broken): no restored iOS/cloudOS versions are recorded or derivable; the VM may not have completed a restore
```

样例生成时空项目根下的检查脚本缺失，Python 候选报告为 `runtime check failed (exit 2)`；随后改为 `python_runtime` unknown（“check_python_runtime.py is missing”），并补充测试。

### C5 失败记录（`.build/c5/lib vmA --patch-record .build/c5/records/runD.json`）

```text
[patch]
  OK      firmware_history (vmA): last firmware transaction is committed
            latest_phase: committed
            latest_variant: regular
  ERROR   patch_record_failed (vmA): the recorded patch run failed
            failed_component: kernelcache
            failed_stage: patch
            failed_required: kernelcache.KernelPatcher.patchApfsRootSnapshot, ... (8 项)
            transaction: uncommitted
            suggested (not run): vphone-cli fw record show ~/github/vphone-cli/.build/c5/records/runD.json
```

`.build/c5/lib/vmA` 没有 config.plist，同一报告含 `input/vm_manifest_invalid`（“config.plist is missing”）。

## 未覆盖范围与限制

- （2026-09-17 后续已实测，见“签名应用与客户机连接验收”）已签名应用包的 `signing_entitlements` ok 路径；E2 之后构建启动的 VM 上的 `guest_disconnected` 与 `guest_connected`。
- `guest_connected` 只在 regular 变体、headless 启动的 `d4-acc` 上实测；GUI 启动、其他变体未实测。
- JB 首次启动收尾（`/var/log/vphone_jb_setup.log`）不可从宿主只读获得，doctor 不报告该状态；D4 检查点的 `jb_finalize` 始终为 unverified。
- 实验记录没有默认位置，未传入 `--patch-record` 时不报告最后一次补丁运行的失败原因；只能从固件事务日志和创建检查点获得。
- `research_guests` 在多个 macOS 安装时为 unknown；doctor 不交互选择。
- 未覆盖网络可达性（IPSW 下载）、sudo/askpass 可用性和 amfidont 是否允许特定 cdhash。
- 库摘要对每个 bundle 做锁探测；锁探测竞争窗口见“只读性”。
- 修复动作未实现，只输出建议命令。

## 签名应用与客户机连接验收（2026-09-17）

实验设置：独立工作树 `.build/d4acc/src`，HEAD `8b6365f`，`make build` 签名应用；amfidont 运行中。`d4-acc`（库根 `.build/d4acc/lib`，regular，26.1 / 23B85）在 D4 真实验收完成后整体 `succeeded`。证据位于 `.build/d4acc/logs/d5-*`（受 Git 忽略）。

| 步骤 | 命令 | 结果 |
| --- | --- | --- |
| VM 关闭 | `doctor d4-acc -l .build/d4acc/lib --json` | 退出码 3（warning）；ok 17、warning 1。`environment/signing_entitlements` ok（`amfidont_running: true`，可执行文件为签名应用）；`guest_runtime/create_succeeded` ok；唯一 warning 为 `environment/sip_status`（宿主 SIP 为自定义配置） |
| 以本构建 headless 启动 `d4-acc`（12:13:21Z），每 5 秒运行 doctor | `vphone-cli --config …/d4-acc/config.plist --headless`；`doctor d4-acc … --json` | 第 5 秒：`guest_runtime/guest_disconnected` warning；第 10 秒：`guest_runtime/guest_connected` ok，`guest_capability_count: 15`、`protocol_version: 1`、`screen_available: false`；`occupancy/vm_running` ok（`boot_pids: 78373`、`record_pid_is_boot_process: true`）；`occupancy/running_vm_processes` 列出 `vm-2607` 与 `d4-acc` 两个进程 |
| 停止 | `vm stop d4-acc -l .build/d4acc/lib` | 退出码 0，启动进程退出 |
| 运行中的 `vm-2607`（只读） | `doctor vm-2607 -l ~/github/vphone-cli --json` | 退出码 4（unknown）；`occupancy/vm_running` ok，`boot_pids: 41303`（`--config` 含 `..`，由 `8b6365f` 的 `canonicalConfigPath` 匹配）；`host_control_capabilities_unavailable` unknown，与此前记录一致（该 VM 由 E2 之前构建启动，推断） |

主机控制探测为只读的 `capabilities` 请求；本轮未对 `vm-2607` 执行其他操作。
