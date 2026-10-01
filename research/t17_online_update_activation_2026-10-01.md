# T17 在线替换与进程激活

日期：2026-10-01。基线提交 `f524a0f`。范围：上游整合清单 T17 的代码与无 VM 测试。用户决定的范围：只覆盖本地已有的环境库（`scripts/guest_environment.json` 的 5 项，含本地保留的 `libvlocation.dylib`）；`libmisfix.dylib` 与“更新后重启 MIS 守护进程”留给 T18，本项不实现、不模拟。

本项没有在任何真实 VM 上安装、激活或更新内容；没有读写 `~/.vphone/VMs`、`~/vphone-b4-accept`、`/Volumes/vphone-t03-restore`；没有对 `vm-2607`（pid 15663）、`vm-new`（pid 11275）执行命令或发信号；没有使用 sudo；没有联网；没有发送合成键鼠事件。日志位于 `research/artifacts/t17-online-update-2026-10-01/`（Git 忽略）。

## 1. 对照表

“上游 daemon”指 `upstream-2.2.3:VPhoneDaemon/Daemon/GuestAPI+Environment.swift`；“上游宿主”指 `upstream-2.2.3:VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControlEnvironment.swift`；“上游连接”指同目录 `VPhoneGuestControl.swift`。定位命令：`git log upstream-2.0.8..upstream-2.2.3 -- '*Environment*'`（8 个提交，与本项相关的是 `ce7b42d`、`1c19bb4`、`d44a0e9`、`2352726`）。本地行号为本项提交后的位置。

| # | 上游行为 | 上游位置 | 本地结论 | 本地位置 |
| --- | --- | --- | --- | --- |
| 1 | daemon `environment.status`：各库 SHA-256、staging 路径、`root_read_only` | 上游 daemon `:23-36` | 已等价，并增加字段：`staged_sha256`、`device`/`inode`、`load_alias`（`/vh` 的目标）、`transactions`（最近 10 个事务） | `sources/VPhoneDaemon/Daemon/GuestAPI+Environment.swift:37-49`；`Wire/EnvironmentTransaction.swift:57-68` |
| 2 | daemon `environment.install`：名称在清单内、staging 摘要匹配、可写重挂 `/`、同卷临时文件后 rename、恢复只读、删除 staging | 上游 daemon `:44-71`、`:101-158` | 已等价，并有本地差异：(a) 只替换已安装的库，目标不存在即拒绝；(b) 替换前把旧文件复制到 `<staging>/transactions/<id>/backup/`，写 `journal.json`；(c) 逐个替换，第一个失败即停止，其余记 `not_attempted`，以结果（`complete: false`）返回而不是抛错；(d) 名称重复、SHA-256 格式错误在写入前拒绝 | `GuestAPI+Environment.swift:69-101`；`EnvironmentTransaction.swift:81-180` |
| 3 | 替换 libvcamcaptured 或 SystemHook 后 SIGTERM `cameracaptured` | 上游 daemon `:73-78` | 本地有意不同（设计决定 2“重启行为显式”）：daemon 不重启任何进程，`restarted_pids` 恒为空；宿主 `--restart cameracaptured` 显式执行，经现有 `processes.list` + `processes.kill`（`TERM`、`force: true`） | `GuestAPI+Environment.swift:93-95`；`sources/vphone-cli/VPhoneGuestEnvironment.swift:400-447` |
| 4 | 替换 libmisfix 或 SystemHook 后结束 `misagent`、`installd`、`lockdownd`、`remoted` | 上游 daemon `:79-88`；`GuestAPI+DeviceIdentity.swift:53` | 归 T18。本地无 libmisfix；这 4 个进程不在 `--restart` 白名单内，请求即拒绝（`restart_not_allowed`） | `VPhoneGuestEnvironment.swift:147`、`:205-216` |
| 5 | 不重启 SpringBoard（respring 由 `system.respring` 另行请求） | 上游 daemon `:82-85`（注释） | 已等价。宿主只输出 `respring` 动作（`executed: false`），`--restart SpringBoard` 拒绝 | `VPhoneGuestEnvironment.swift:638-707` |
| 6 | `reboot_required`：`/` 未恢复只读，或替换了 launchdhook | 上游 daemon `:93` | 已等价。宿主原样记入 `activation.daemon_reboot_required`，并附说明：`false` 不表示运行中的进程已加载新文件 | `GuestAPI+Environment.swift:96-98`；`VPhoneGuestEnvironment.swift:151-152` |
| 7 | 宿主 `updateEnvironment`：要求 `environment_update`，读状态，上传摘要不同的库，调用 `environment.install` | 上游宿主 `:17-56` | 已等价，并有本地差异：显式命令触发；要求 `environment_transaction`；候选来自 guest 组件 stage 并逐项核对 stage `manifest.json`、普通文件与 `LC_CODE_SIGNATURE`；上传后重新读 `staged_sha256`，与候选不符即拒绝，不调用 install；任一库缺失或 `/vh` 目标不符时拒绝（`full_migration_required`）；替换后再读状态逐项核对；读取映射状态；输出激活动作 | `VPhoneGuestEnvironment.swift:277-398` |
| 8 | 每次连接自动执行 `syncEnvironment` 并打印重启提示 | 上游连接 `:189-190`；上游宿主 `:60-71` | 本地有意不同（设计决定 4）：不自动同步。在线更新只经 `vphone-cli guest env update` → host-control `environment_update` | `sources/vphone-cli/VPhoneGuestEnvironmentCLI.swift`；`VPhoneHostCommandExecutor.swift:79-86` |
| 9 | 宿主与 daemon 清单一致（注释约定） | 上游 daemon `:11`；`VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestEnvironment.swift:8-15` | 已等价并由测试约束：宿主读 `scripts/guest_environment.json`；daemon 列表由 `tests/test_cfw_env_update.py` 比对；宿主在更新前比对 daemon 返回的名称列表，不一致即 `environment_mismatch` | `VPhoneGuestEnvironment.swift:9-38`、`:288-293` |
| 10 | 部分替换失败：抛出错误，已替换的文件无记录，旧文件不保留 | 上游 daemon `:64-68`、`:150-158` | 本地有意不同（设计决定 3）：journal 与备份；宿主返回 `ok: false`、`code: partial_failure` 与 `recovery`（事务 id、journal 路径、已替换项的 `previous_sha256` 与备份路径、失败项、未尝试项、前进与回退两种步骤）；`environment.restore` + `guest env rollback` 回退 | `EnvironmentTransaction.swift:146-215`；`VPhoneGuestEnvironment.swift:366-395`、`:449-485` |
| 11 | 进程实际加载状态 | 上游无 | 新增 `environment.loaded`（能力 `environment_activation`）：逐进程以 `proc_pidinfo` 区域路径信息列出 vnode 映射，按 (device, inode) 判定 `current`（映射当前文件）或 `stale`（映射被事务替换的旧副本，或同路径的其他文件）；无法检查的进程列入 `uninspected` 及 errno | `GuestAPI+Environment.swift:117-165`；`sources/VPhoneDaemon/Native/vphoned_mappings.c`；`EnvironmentTransaction.swift:300-335` |
| 12 | 应用行为 | 上游无 | 本项不验证。输出固定 `application.state: not_verified` | `VPhoneGuestEnvironment.swift:149-150` |
| 13 | `rpc` 转发 | 上游 `rpc` 转发任意方法 | 保留 T25：`environment.install` 与新增 `environment.restore` 在阻止表；只读的 `environment.status`、新增 `environment.loaded` 可转发 | `sources/vphone-cli/VPhoneHostRPC.swift:68-81` |
| 14 | 能力协商 | `environment_update` | 已等价并扩展：`api_version` 仍为 1；新增 `environment_transaction`（journal、`environment.restore`）、`environment_activation`（`environment.loaded`）。宿主按能力启用命令：update 需要前者，缺失即 `capability_unavailable`；缺少后者时加载状态记为 `unknown` | `sources/VPhoneDaemon/Daemon/GuestAPI.swift:87-91`；`VPhoneGuestEnvironment.swift:163-171` |

结论：14 项中已等价 5 项（1、5、6、9、14 的基础部分；其中 1、9、14 有扩展），已等价但带本地差异 2 项（2、7），本地有意不同 3 项（3、8、10），归 T18 1 项（4），上游没有、本地新增 2 项（11、12），保留 T25 限制 1 项（13）。T16 记录的在线更新“缺失 3 项”（17 宿主更新、18 连接自动同步、22 MIS 进程重启）现状：17 已实现（表中 7）；18 按设计决定 4 不实现自动同步（表中 8）；22 归 T18（表中 4）。

## 2. 现有客户机守护进程

事实（来自代码与既有记录，本项未连接任何 VM）：

- 本地 CFW 安装把经典 Objective-C `vphoned`（`scripts/vphoned/`，VSOCK 1337，长度前缀 JSON）装到 `/usr/bin/vphoned`，launchd 标签 `com.vphone.vphoned`（`scripts/lib/cfw_common.sh:162-167`；`scripts/cfw_install.sh:392-408`；`scripts/cfw_install_dev.sh:348-364`；`scripts/vphoned/vphoned.plist`）。宿主经 1337 握手按哈希把新二进制推到 `/var/root/Library/Caches/vphoned`，经典引导在启动时 exec 该缓存（`scripts/vphoned/vphoned.m:82`、`:635-647`）。
- 经典 `vphoned` 不含 `environment.*`：能力列表（`vphoned.m:509-536`）没有 `environment_update`，源码没有该方法。
- `environment.*` 只存在于候选 API daemon（`sources/VPhoneDaemon`，VSOCK 1339 HTTP/WebSocket）。该 daemon 只由 `make daemon_api_build` 产出到 `.build/daemon-api-v2/candidate`，`manifest.json` 记录 `activated: false`；默认构建、CFW 安装和宿主自动更新都不安装它（`research/p2_daemon_api_integration_2026-09-28.md`）。
- 既有观测：`vm-new` 客户机中与 vphone 相关的进程只有 `/var/root/Library/Caches/vphoned`（经典，2026-10-01 15:20 只读探测）；`lp-b2-accept` 以 `--api-listen` 启动后 `api_session` 一直为 `reconnecting`/`transport`（`research/guest_cli_2026-10-01.md`）；`rig-baseline` 在 2026-09-09 由宿主推送经典 `vphoned` 到缓存路径（`research/review_fixes_2026-09-08.md:66`）。
- T16 结论：本地 regular/dev/jb/exp 安装都不在 `/usr/lib` 放置这 5 个库，也不建 `/vh`（`research/t16_offline_update_eligibility_2026-10-01.md` 2.2 节）。

推断（未在 VM 上验证）：本地现有 VM 都运行经典 1337 daemon，没有 1339 API daemon；即使激活 API daemon，`guest env update` 在这些 VM 上也会返回 `full_migration_required`（5 个库缺失、`/vh` 不存在）。在线更新在现有 VM 上有两个前提：(1) API daemon 在 1339 运行；(2) 客户机已有 v2 环境（`/usr/lib` 5 个库、`/vh`、launchd 的 `/vh` 加载命令）。前提 (2) 目前没有本地建立流程（P4 v2 创建未接入）。

### 2.1 候选 API daemon 激活方案（未执行）

两个 daemon 的冲突点（事实，来自源码）：

| 项 | 经典 vphoned | 候选 API daemon |
| --- | --- | --- |
| launchd 标签与程序 | `com.vphone.vphoned`、`/usr/bin/vphoned` | 相同（`sources/VPhoneDaemon/Configuration/vphoned.plist`） |
| 缓存二进制 | `/var/root/Library/Caches/vphoned`，存在且可执行即 exec，不校验 | 同一路径；只有 `vphoned.api-v2` 标记与内容 SHA-256 一致且属主为 root 时才 exec（`sources/VPhoneDaemon/Native/vphoned_native.m:67-104`），否则运行已安装的二进制 |
| 自更新 | 宿主经 1337 推送 | `agent.apply_update` 写同一缓存路径与标记；宿主从不调用，`rpc` 阻止 |

方案 A（替换）：用候选替换 `/usr/bin/vphoned`。结果是 1337 消失，依赖经典通道的宿主功能（客户机触控、`location_owned`、相机 `vcam_receipt_v3`、`shell`、经典文件传输等）不可用。不建议在宿主 API 通道覆盖这些功能前采用。

方案 B（并存，不持久，建议）：保留经典 daemon，另起一个 launchd 任务运行候选，重启客户机后消失。

1. 宿主：`make daemon_api_build`（本项产物 `vphoned` SHA-256 `09f96b45181ae7e1b7fee13d88a6fd0e94373f0d1aa5cca8009eedf01c2cf831`）。
2. 经经典 `file_put` 上传到 `/var/root/vphoned-api/vphoned`（权限 755），不得使用 `/var/root/Library/Caches/vphoned`。
3. 上传一个改写的 plist 到 `/var/root/vphoned-api/com.vphone.vphoned.api.plist`：`Label` 为 `com.vphone.vphoned.api`，`ProgramArguments` 为上一步路径，日志 `/var/log/vphoned-api.log`。
4. 经经典 `shell`：`launchctl bootstrap system /var/root/vphoned-api/com.vphone.vphoned.api.plist`。
5. 回退：`launchctl bootout system/com.vphone.vphoned.api`，删除 `/var/root/vphoned-api`；客户机重启后该任务不再加载。

风险与未知项（待验证假设）：

- 候选在客户机上能否运行（签名、AMFI、Swift 运行库）没有记录；经典二进制能从 `/var` 运行是已观测事实，候选尚未运行过。
- 并存时绝不能调用 `agent.apply_update`：它写入的缓存会在下次启动时被经典 `/usr/bin/vphoned` 的引导 exec，结果是两个任务都运行 API daemon。
- `environment.loaded` 依赖 `proc_pidinfo`（`PROC_PIDREGIONPATHINFO2`，不支持时退回 `PROC_PIDREGIONPATHINFO`）检查其他进程。macOS 上以普通用户检查同用户进程成功、检查 pid 1 返回 EPERM（第 4.2 节）。iOS 上 root、非沙盒、`platform-application` 的进程能否检查 launchd、SpringBoard 等未验证；失败的进程进入 `uninspected`，`load.complete` 为 `false`。
- 两个 daemon 都在启动时 SIGTERM 处理、Jetsam 优先级等方面的相互影响未知。

## 3. 设计与实现

### 3.1 流程（`guest env update`）

CLI 进程向 `<bundle>/vphone.sock` 发送 `{"t":"environment_update","components":<绝对路径>,"restart":[...]}`；VM 进程的 host-control 执行器经其 API 会话完成：

1. 请求校验：`components` 为绝对路径；`restart` 为字符串数组，元素必须在白名单 `["cameracaptured"]` 内，否则 `restart_not_allowed`，此时不联系客户机。
2. 会话就绪；能力 `environment_update`、`environment_transaction`、`files`、`file_upload_identity`（有 `restart` 时另需 `processes`）。
3. 读清单 `scripts/guest_environment.json`；核对候选 stage（`manifest.json` 的 `files_sha256`、普通文件、`LC_CODE_SIGNATURE`）。失败为 `candidate_invalid`，不联系客户机。
4. `environment.status`：名称列表与清单不同 → `environment_mismatch`；任一库缺失或 `/vh` 目标不是 `/usr/lib/launchdhook-vphone.dylib` → `full_migration_required`（与 T16 一致：在线更新不安装缺失的库）。
5. 计算需替换集合（客户机摘要 ≠ 候选摘要）。为空时 `outcome: already_current`，不上传、不安装。
6. 逐个上传到 `/var/root/Library/Caches/vphone-environment/<name>`；失败为 `upload_failed`，没有库被替换。
7. 再读 `environment.status`，逐个比较 `staged_sha256` 与候选；不符为 `staged_digest_mismatch`，不调用 install。
8. `environment.install`（daemon 内部再次校验 staging 摘要）。返回 journal。调用本身失败（传输、超时）为 `install_failed`，附重新读取的文件状态与事务列表。
9. 再读 `environment.status`，逐项输出 `guest_before`、`candidate`、`guest_after`、`result`（`replaced`/`unchanged`/`failed`/`not_attempted`）、`verified`。
10. `environment.loaded`（有 `environment_activation` 时），否则加载状态为 `unknown`。
11. 激活动作：有映射数据时按映射旧副本的进程归类；没有时按清单的加载者推定（`basis: manifest`）。只有 `restart` 可由本命令执行。
12. `journal` 不完整时：`ok: false`、`code: partial_failure`、`recovery`，不执行 `--restart`。
13. 执行 `--restart` 指定的进程重启，有映射能力时再读一次 `load_after_restart`。

### 3.2 三类结果分开记录

| 字段 | 内容 | 能证明 | 不能证明 |
| --- | --- | --- | --- |
| `files` | 替换前后的客户机 SHA-256 与候选 SHA-256 | `/usr/lib/<name>` 的字节等于候选 | 任何进程已加载它 |
| `load` | 每个库：映射当前文件的 pid、映射旧副本的进程；`complete`、`uninspected` | 被检查的进程映射的是哪个文件身份 | 库内 hook 已安装、功能正常；未检查进程的状态 |
| `application` | 固定 `not_verified` | — | 相机、定位等应用行为 |
| `activation` | 动作列表、`daemon_reboot_required`、`root_read_only`、已执行的重启 | 需要的动作与原因 | `reboot_required=false` 不表示进程已加载新库 |

### 3.3 激活动作

| 条件 | 动作 | 本命令是否执行 |
| --- | --- | --- |
| pid 1（launchd）映射旧副本；或无映射数据且替换了 launchdhook；或 daemon 报告 `reboot_required` | `reboot` | 否 |
| SpringBoard 映射旧副本；或无映射数据且替换了 SystemHook 或 libvlocation（SpringBoard 路径含 `.app/`，是 SystemHook 注入目标并在启动时加载定位库，`SystemHook-vphone.c:28-45`、`:193-200`） | `respring` | 否 |
| cameracaptured 映射旧副本；或无映射数据且替换了 SystemHook 或 libvcamcaptured | `restart` | 仅 `--restart cameracaptured` |
| 其他进程映射旧副本；或无映射数据且替换了 SystemHook、libcamfix、libvlocation | `relaunch` | 否 |

白名单只有 `cameracaptured`。依据：上游在替换相机库后 SIGTERM 该进程，注释称 launchd 会为下一个相机客户端重新启动它（未在本地客户机验证）。相机 App、KFCKnight 被结束后不会自动重启，需要显式 `app_launch`（本地既有经验），因此不放入白名单，只输出 `relaunch`。

### 3.4 daemon 侧

- `Wire/EnvironmentTransaction.swift`（新）：状态、校验、备份与 journal、逐个替换、回退、事务列表与保留（保留全部未完成事务和最新 5 个完成事务）、映射分类。目录可注入，由 SwiftPM 的 `VPhoneDaemonWire` 目标在 macOS 上测试；Xcode 工程的 `Daemon` 同步组自动包含该文件。
- `Native/vphoned_mappings.c`（新）：`vp_process_mapped_files`。iOS SDK 没有 `<sys/proc_info.h>`，文件内按 macOS SDK 头复写结构；测试在 macOS 上用真头比较尺寸与偏移。
- `GuestAPI+Environment.swift`：`environment.status` 增加字段；`environment.install` 使用事务；新增 `environment.restore`、`environment.loaded`；去掉自动 SIGTERM `cameracaptured`。
- `GuestAPI.swift`：声明 `environment_transaction`、`environment_activation`。

### 3.5 命令用法

```
vphone-cli guest env status   <vm> [--components DIR] [--library-root R] [--timeout S]
vphone-cli guest env update   <vm> [--components DIR] [--restart cameracaptured] [--library-root R] [--timeout S]
vphone-cli guest env rollback <vm> <transaction-id> [--library-root R] [--timeout S]
```

`--components` 默认 `VPhoneResources.resolve().guestComponentsStage`（`.build/guest-components-v2/stage`），相对路径按当前目录展开。stdout 为响应 JSON 原文；stderr 为摘要行；退出码同 `guest send`（0 为 `ok:true`，1 为其他响应，2 为无有效响应，64 为参数错误）。VM 需以 `--api-listen` 启动，客户机需运行 API daemon。

输出示例见第 4.3 节。

## 4. 测试

### 4.1 修改前

| 命令 | 结果 |
| --- | --- |
| `swift test --filter 'EnvironmentTransactionTests\|GuestEnvironmentUpdateTests'`（新测试，实现前） | 编译失败：`cannot find type 'EnvironmentTransaction' in scope`（`pre-change-swift.log`） |
| 同上，暂时移出 Wire 测试，仅 `GuestEnvironmentUpdateTests` | 编译失败：`VPhoneGuestEnvUpdateCommand`、`VPhoneGuestEnvironmentSummary`、`VPhoneGuestEnvironmentManifest` 等未定义，`extra argument 'environmentManifest'`（`pre-change-swift-host.log`） |
| `python3 -B -m unittest tests.test_daemon_env_mappings`（实现前） | 错误：harness 编译失败，`vphoned_mappings.c` 不存在（`pre-change-python.log`） |

变异检查（实现后，逐项改源码再恢复，日志 `mutation-*.log`）：

| 变异 | 失败的用例 |
| --- | --- |
| 取消 `restart` 白名单检查 | `testRestartOutsideTheWhitelistIsRefusedBeforeGuestContact`（SpringBoard、launchd、installd 等全部放行）、`testCLIRequestsAndRestartValidation` |
| 忽略 journal 的 `complete`（视为完成） | `testFailedReplacementReturnsRecoveryRecordAndNoOverallSuccess`：`ok` 为 true、`outcome` 为 `updated`、无 `recovery` |
| 跳过 `staged_sha256` 核对 | `testStagedDigestMismatchIsRefusedBeforeInstall`：调用了 install，替身替换了 libcamfix |
| daemon `apply` 遇到失败后继续 | `failedReplacementStopsAndRecordsRecovery`（7 处）、`retentionKeepsIncompleteTransactions` |
| daemon `prepare` 不做备份 | Wire 5 项用例失败（`changed while it was backed up`） |

### 4.2 新增测试

| 文件 | 用例 | 覆盖 |
| --- | --- | --- |
| `tests/VPhoneDaemonWireTests/EnvironmentTransactionTests.swift`（Swift Testing，7 项） | 状态与 staging 摘要；写入前校验（未知名称、重复、摘要不符、未上传、未安装、缺字段）；完整替换的备份与 journal；第二个替换失败时停止、记录与回退；目标在事务后被改动时拒绝回退、非法 id；映射按文件身份判为 `current`/`stale`（含空路径的旧 inode、同路径不同 inode）；保留策略 | daemon 文件事务（临时目录） |
| `tests/test_daemon_env_mappings.py`（5 项） | 结构布局与 macOS `<sys/proc_info.h>` 一致；dlopen 的测试 dylib 为 `current`，rename 覆盖后进程仍映射旧 inode；缓冲不足返回 `ENOBUFS`；同用户另一进程可检查；pid 1 返回 errno（非 root） | `vp_process_mapped_files` 在 macOS 内核上的行为 |
| `tests/VPhoneCLITests/GuestEnvironmentUpdateTests.swift`（XCTest，17 项） | 替身 API daemon（`EnvironmentDaemonFake`，内存中实现 `environment.*`、`processes.*`、上传）经 `VPhoneHostCommandExecutor`：全部已是最新；只上传与替换差异库并逐项核对；上传摘要不符拒绝；替换中途失败的恢复记录；缺库/`/vh` 不符/清单不一致；候选未签名或被改动；加载状态未知时按清单输出动作；`reboot_required=false` 不被当作已加载；SpringBoard 映射旧副本时只提示 respring、白名单重启执行；白名单外进程拒绝；未检查进程使状态不完整；无候选的状态；能力门控与 `capabilities.commands`；回退；`rpc` 仍阻止 install/restore；CLI 请求与参数校验；stderr 摘要 | 宿主流程 |
| `HostRPCTests.testMethodTableMatchesLocalDaemonSourcesAndDeclaredCapabilities`（既有） | 新增的两个 daemon 方法分别进入转发表与阻止表，能力已声明 | 方法表一致性 |

### 4.3 输出示例

来源：替身 daemon（`EnvironmentDaemonFake`）经 `VPhoneHostCommandExecutor`，由一个未提交的临时测试打印。不是客户机输出。

场景 1：libvlocation 与候选不同，SpringBoard（pid 55）映射其旧副本，`--restart cameracaptured`。stderr 摘要（本节记录后修正了 `restart` 行的格式，修正后的格式由 `testSummaryNamesRequiredActionsAndRecovery` 断言）：

```
outcome: updated
files: 1 replaced, 4 unchanged; 1 replaced file(s) match the candidate
load: libvlocation.dylib replaced copy still mapped by SpringBoard (55)
application behavior: not verified
action required: respring SpringBoard pid 55: SpringBoard maps a replaced copy of libvlocation.dylib; not performed; respring explicitly when the screen state allows (rpc system.respring)
restart: cameracaptured SIGTERM sent to pid(s) 310
```

stdout JSON 节选（`activation`）：

```json
"activation": {
  "actions": [{"action": "respring", "executed": false, "libraries": ["libvlocation.dylib"], "pid": 55,
               "process": "SpringBoard", "reason": "SpringBoard maps a replaced copy of libvlocation.dylib",
               "how": "not performed; respring explicitly when the screen state allows (rpc system.respring)"}],
  "automatic_restart": false, "basis": "mappings", "daemon_reboot_required": false, "root_read_only": true,
  "executed": [{"process": "cameracaptured", "pids": [310], "signal": "TERM",
                "note": "launchd starts it again for the next client (not verified locally)"}],
  "note": "reboot_required=false only means the daemon saw no reason to reboot; it does not mean that running processes loaded the new files"
}
```

场景 2：SystemHook 与 libcamfix 需替换，第二个替换失败，daemon 未声明 `environment_activation`。退出码按 `guest send` 规则为 1。stderr 摘要：

```
error: partial_failure: the environment update replaced only part of the requested libraries
outcome: partial_failure
files: 1 failed, 1 replaced, 3 unchanged; 1 replaced file(s) match the candidate
load: unknown (the guest API daemon does not declare environment_activation)
application behavior: not verified
action required: respring SpringBoard: SpringBoard is an injection target and keeps the copy it mapped; not performed; respring explicitly when the screen state allows (rpc system.respring)
action required: restart cameracaptured: cameracaptured is an injection target; pass --restart cameracaptured to run it
action required: relaunch running apps and bootstrap processes: processes started before the update keep the copy they mapped; not performed; terminate and start this process or app explicitly
recovery: forward: rerun `vphone-cli guest env update <vm>`; it uploads and replaces only the libraries that still differ
recovery: backward: `vphone-cli guest env rollback <vm> T1` copies each backup listed in replaced back to /usr/lib
```

`recovery` 节选（替身的事务 id 为 `T1`；真实 daemon 的 id 形如 `0000018f2a3b4c5d-1a2b3c4d`）：

```json
"recovery": {
  "transaction": "T1",
  "journal": "/var/root/Library/Caches/vphone-environment/transactions/T1/journal.json",
  "replaced": [{"name": "SystemHook-vphone.dylib", "sha256": "b349…128f", "previous_sha256": "old-SystemHook-vphone.dylib",
                "backup": "/var/root/Library/Caches/vphone-environment/transactions/T1/backup/SystemHook-vphone.dylib"}],
  "failed": {"name": "libcamfix.dylib", "error": "Could not install /usr/lib/libcamfix.dylib: Input/output error"},
  "not_attempted": [],
  "steps": ["forward: …", "backward: …"]
}
```

## 5. 命令与结果

环境：worktree 的 `.venv` 为指向主仓库 `.venv` 的符号链接；递归初始化 `vendor/*` 子模块；按 Makefile 格式生成被忽略的 `sources/vphone-cli/VPhoneBuildInfo.swift`；SwiftPM 的 `.build/artifacts`、`checkouts`、`repositories` 从主仓库复制并改写 `workspace-state.json` 中的路径；daemon 的 `.build/daemon-api-v2/Xcode/SourcePackages` 从另一 worktree 复制（icli `9e9a6ca9…`，即 0.7.7）。构建与测试没有访问网络。swift 命令环境同 `scripts/run_tests.py`（`--disable-sandbox --cache-path .build/test-cache`，module cache 在 `.build/test-module-cache`，清除 `VPHONE_TEST_*`）。复制来的 checkouts 使 SwiftPM 改写了 `Package.resolved`（`swift-binary-parse-support` 0.2.1→0.3.0、`swift-fileio` 0.13.0→0.15.1 等）；该改动是环境产物，未提交。

| 命令 | 结果 |
| --- | --- |
| `.venv/bin/python3 -B -m unittest tests.test_daemon_env_mappings -v` | 5 项通过；本机内核使用 flavor 22（`PROC_PIDREGIONPATHINFO2`） |
| `swift test --filter 'EnvironmentTransactionTests\|GuestEnvironmentUpdateTests\|HostRPCTests'`（第一次） | Swift Testing 7 项通过；XCTest 29 项（`GuestEnvironmentUpdateTests` 17、`HostRPCTests` 12）通过（`swift-filter-1.log`） |
| 变异检查 5 组 | 见 4.1 节，全部被测试捕获，源码已恢复（`mutation-*.log`） |
| `make daemon_api_build` | 退出 0；`** BUILD SUCCEEDED **`；pin、checkout、候选检查通过；日志中 0 条 ` error: `、0 条 ` warning: `；候选 `vphoned` SHA-256 `09f96b45181ae7e1b7fee13d88a6fd0e94373f0d1aa5cca8009eedf01c2cf831`，未定义符号含 `_proc_pidinfo`、`_clock_gettime_nsec_np`；`vphoned.plist`、entitlements 摘要与 T08 记录相同（`daemon_api_build.log`） |
| `make test_python` | 534 项通过，0 跳过（`test_python.log`） |
| `make test_swift`（第一次） | 退出 0；Swift Testing 11 次运行共 1012 项通过；XCTest 按各 `.xctest` 汇总行共 234 项执行（VPhoneCoreTests 93、VPhoneCLITests 112、VPhoneAPIKitTests 24、FirmwarePatcherTests 5）、3 项跳过（均在 FirmwarePatcherTests）、0 失败；T16 记录为 217 项，本项新增 `GuestEnvironmentUpdateTests` 17 项；tar pipe 两条 1 GiB 路径峰值 RSS 7,929,856 / 8,126,464 字节；`test_guest_components` 124 项检查 0 失败（`test_swift.log`） |
| `swift test --filter 'EnvironmentTransactionTests\|GuestEnvironmentUpdateTests\|HostRPCTests\|GuestCLITests\|HostCommandExecutorTests\|HostAPICommandTests'`（修正 `restart` 摘要行后） | Swift Testing 7 项通过；XCTest 69 项通过（`swift_filter.log`） |
| `make test_swift`（修正后） | 见 5.1 节 |
| CLI 无 VM 检查（临时库，debug 构建） | `guest env --help`、`guest env update --help` 退出 0；`guest env status ghost` 退出 2（`VM 'ghost' not found`）；`guest env update <vm> --restart SpringBoard` 退出 64；`guest env rollback <vm> ../x` 退出 64（`cli_smoke.log`） |
| 空白检查（`diff --check`） | 通过 |

### 5.1 修正后的全量 Swift 测试

`make test_swift`：退出 0；Swift Testing 11 次运行共 1012 项通过（T16 记录 996 项；本项新增 `EnvironmentTransactionTests` 7 项，其余差值来自 T16 之后的提交，未逐项核对）；XCTest 共 234 项执行、3 项跳过（FirmwarePatcherTests 的 `testProductionArtifacts`、`testChildProcess`、`testNonLessLegacyAndStructuredPayloadsMatch`）、0 失败；tar pipe 峰值 RSS 7,847,936 / 8,093,696 字节；`test_guest_components` 124 项检查 0 失败（`test_swift_final.log`）。

## 6. 真实验收前提与步骤

前提（全部未满足，需用户决定与授权）：

1. 一台有 v2 环境的 VM：`/usr/lib` 5 个库、`/vh` → `/usr/lib/launchdhook-vphone.dylib`、`/sbin/launchd` 含 `/vh` 加载命令。本地没有建立流程；`lp-b4-accept2`（regular）按 T16 推断没有这些文件。
2. 该 VM 运行候选 API daemon（1339），宿主以 `--api-listen` 启动。
3. 在独立 APFS 副本上进行，不使用 `vm-2607`、`vm-new`。

在 `lp-b4-accept2` 上可分两段进行。

第一段（只需前提 2；验证 API daemon 激活、`guest rpc` 往返遗留项、`environment.loaded` 在 iOS 上的权限）：

1. 用户授权；`lp-b4-accept2` 停机；以 APFS clone 建副本（例如 `lp-t17-accept`），记录 `Disk.img` 等的 SHA-256。
2. 构建：`make build`、`make daemon_api_build`，记录候选 SHA-256。
3. 启动：`VPHONE_API_TOKEN=<随机值> vphone-cli vm launch lp-t17-accept --headless --api-listen 127.0.0.1:0 --library-root ~/vphone-b4-accept`。
4. 按 2.1 方案 B 激活候选（经典 `file_put` 与 `shell`）。
5. `vphone-cli guest send lp-t17-accept '{"t":"capabilities"}'`：期望 `api_session.state: ready`、`commands.environment_status: true`、`rpc_methods` 非空。
6. `vphone-cli guest rpc lp-t17-accept device.info`（T25/guest CLI 遗留项）；带窗口启动时补 `--screen`。
7. `vphone-cli guest env status lp-t17-accept`：期望 `assessment.state: full_migration_required`（5 个库缺失、`/vh` 无目标），`load.source: environment.loaded`；记录 `scanned`、`uninspected`（是否含 launchd、SpringBoard）与耗时。
8. `vphone-cli guest env update lp-t17-accept`：期望退出 1、`code: full_migration_required`，客户机 `/usr/lib` 不变（用经典 `shell` 的 `ls -l /usr/lib/*vphone* /usr/lib/libv* /usr/lib/libcamfix*` 前后对比）。
9. `vphone-cli guest env update lp-t17-accept --restart SpringBoard`：期望退出 64。
10. 回退方案 B，`vm stop`，记录副本状态。

第二段（需前提 1，待 v2 创建或经用户批准的 v2 环境安装方式确定后）：

1. 在有 v2 环境的副本上记录 `guest env status`（基线摘要、映射）。
2. 准备与客户机不同的候选（例如重建 `make guest_components_build` 后只改 libcamfix），`guest env update`：核对 `files` 中只有差异库 `replaced` 且 `verified: true`；`load` 中运行中的相机客户端为 `stale`；`activation` 动作。
3. `--restart cameracaptured`：核对 `executed` 的 pid，打开相机后 `load_after_restart` 或再次 `status` 中 cameracaptured 映射 `current`。
4. 部分失败与回退：在副本上令某一库替换失败的方法尚无（客户机无故障注入开关），可改用 `guest env rollback <vm> <transaction>` 验证回退路径与 journal。
5. 应用行为（相机出图、定位）单独按 T20/T22 的验收方法记录，不由本命令结果推定。

## 7. 事实、推断与未验证

事实：

- 宿主流程在替身 daemon 上：只替换差异库；上传摘要不符时不调用 install；部分失败时返回 `ok: false` 与恢复记录；SpringBoard、launchd、MIS 守护进程不能经 `--restart` 重启；`reboot_required=false` 时加载状态仍为 `unknown`。
- daemon 文件事务在 macOS 临时目录上：替换前备份、逐步 journal、失败即停、回退前核对目标与备份摘要。
- macOS 上 `proc_pidinfo` 区域路径信息能区分进程映射的当前文件与被 rename 覆盖的旧 inode；`PROC_PIDREGIONPATHINFO2`（22）在本机内核可用；非 root 检查 pid 1 返回 EPERM。
- 候选 API daemon 交叉编译、签名与产物检查通过；未安装、未运行。

推断（待验证假设）：

- iOS 客户机上 API daemon 以 root 运行时能检查大多数进程的映射。
- `cameracaptured` 被 SIGTERM 后由 launchd 按需重新启动（上游注释）。
- 替换 SystemHook 后新启动的进程加载新文件（新进程由 dyld 按路径加载）。

未验证：

- 任何真实客户机上的 `environment.*`、上传、`mount -u -w /` 与恢复只读、rename 替换、`environment.loaded` 的覆盖率与耗时、cameracaptured 重启后的行为、应用行为。
- `install_failed`（传输在 install 期间中断）路径只在宿主侧按设计实现，替身测试未覆盖该分支。
- daemon `environment.restore` 只有 Wire 层测试；`withWritableRoot` 与 `installLibrary` 只在 iOS 构建中编译。

## 8. 需要决定的问题

- 第一段验收是否采用方案 B（并存、不持久）激活候选 API daemon，以及在哪个副本上进行。
- v2 环境在现有 VM 上的建立方式（P4 v2 创建，或另定的停机安装流程）；没有它，第二段验收和在线更新的实际使用都无法进行。
- 是否把 Camera、KFCKnight 等 App 的重新启动加入本命令（目前只输出 `relaunch` 提示）。
- `environment.loaded` 默认扫描全部进程；客户机上耗时过长时是否改为按清单的加载者限定进程。
