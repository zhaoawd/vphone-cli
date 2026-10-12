# Task7 实施报告

状态：实现和受影响离线验证完成，待 root 独立审查。原 T17 的真实 VM 验收仍由 Task12 执行。Task6/C2、Task10 的在线 same-journal origin 发布与恢复未完成，本任务不宣称原五项已验收。

工作分支：`codex/upstream-2d21d21-integration`。BASE：`001eef93f7c59cfd1a809d87ca5c3a24029943f1`。提交 subject：`fix: coordinate and verify guest environment transactions`；提交标识以本报告所在提交及最终交付消息为准。

## 实现与接口

保留 `environment.status/install/restore/loaded`、host `environment_status/update/rollback` 及 CLI 名称。增加 daemon 实际声明的 `environment_transaction_v2`。只有旧 `environment_update`/`environment_transaction` 的 daemon 不获写入资格；普通 status 仍可读。写入拒绝返回 capability/source/mode 的明确诊断，模式不合格时要求停机检查安装。

`VPhoneGuestEnvironmentSource` 从实际运行 `.vm` 的 VM lifetime lease 进入 Store async 作用域：核对 launchpad binding、实际 executable 路径、Store receipt/signature、frozen regular/v2 plan、generation、desired/plan SHA、完整候选集以及 `.build/daemon-api-v2/candidate-v2/vphoned` 实际字节。候选必须来自该 Bundle 固定目录；manifest、候选父路径或目标符号链接不获资格。每次异步写入前及读回后复验 runtime、binding、plan/generation、daemon/候选/可执行文件摘要，退出或取消后捕获的 verify 失效。这里的 source 仅授权本次在线替换，不发布 installed origin。

操作 context 含 `operation`、API `generation`、`daemon_instance`、`vm_instance`、`mode=regular-v2`、`firmware_generation`、`plan_sha256`、`desired_sha256`、`bundle_version`、`executable_sha256`、`daemon_sha256`。实际 host writer 的 coordinator operation ID 传入 updater。daemon 拒绝缺项、未知 mode、非完整 SHA、错误 daemon hash/instance 和无效标识。

`EnvironmentEligibility` 对固定实际 guest 路径执行只读检查：launchd Mach-O `/vh` 加载命令与 code-signature blob 边界；拒绝 `/b` 或其他未知加载命令；核对 `/vh` 目标、completed CFW marker、5 个现有库的 regular-file/摘要/签名结构、`/usr/bin/vphoned-api` 实际摘要与运行 daemon 摘要、job 的 Label/ProgramArguments/VCAM 及 launchd key；pending 或未知/旧 cache marker 拒绝。`apiOnly`、alias 或 marker 单项不能给资格。`signature_evidence=load_command_and_blob_bounds_only` 明确不表示 CodeDirectory 密码学验证或系统签名验证。保留 `libmisfix` upstream_only/reserved；未新增 payload，也不宣称 T16 整机 modern 迁移完成。

journal 的每次保存错误均抛出并停止下一次替换。备份 fsync；临时 journal 独占创建、禁止跟随最终符号链接，写完 fsync 后 rename，再 fsync 目录。替换/恢复前重验输入与当前目标，替换后读取实际输出摘要。prepared、损坏 journal 或失败时未知输出阻止后续 install。按 created 排序兼容 host UUID operation。原 journal 保存 context、完整 `before_files/after_files`、请求组件的前后摘要及状态；只读 remount 收敛后再持久化 `root_read_only`。没有独立成功账本。

host 严格验证 install/restore 的组件集合、顺序、去重、状态、前后摘要和精确 backup 路径；对全部 5 个文件读回，包含未替换文件。restore 还要求原 journal 与当前 VM/mode/frozen generation 一致，并核对新 `restore_context`。安装成功丢回复时，只按本次 operation/context 查询同 journal 和实际文件；不重发 install。读回缺失、busy、断连、实例变化、未知输出或挂载未恢复时保留 `pending_recovery`。

`files`、`load`、`activation`、`application` 分开报告。文件安装成功不表示 mapped copy 或相机/定位行为已验证；返回 `pending_activation`，业务 `not_verified`。回退文件完成仍保留 `pending_recovery` 的激活/行为边界。进程重启仍限显式 `cameracaptured`；没有新增自动 respring/reboot。所有在线结果的来源发布状态为 `unpublished`。

## 锁顺序、生命周期和实际 caller

| 对象 | 实际 caller | 获取与释放 |
| --- | --- | --- |
| VM lifetime lease | AppDelegate 启动路径 | 原 VM 生命周期持有；本任务不重取或释放 |
| per-VM FIFO coordinator | AppDelegate 共享给 control 与 HostCommandExecutor | 仅维护写操作串行；普通 API 查询继续执行 |
| `.vphone-online-operation.lock` | coordinator、生产 `VPhoneVMStopper` | openat/no-follow/regular/owner/mode/nlink/inode 核验，`flock(EX|NB)`；Stop 包括 force 竞争失败不 signal |
| Store shared lease | `withCurrentBundle` → `withRevalidatedExecutableAsync(.vm)` | 已持 VM 与 online lease 内只 `LOCK_SH|LOCK_NB`；完整异步读回结束后释放；不等待离线 Store→VM 路径 |
| guest maintenance gate | `GuestAPI.execute` | install/restore/bootstrap.install/uninstall/firmware/shutdown/reboot/respring/apply_update 排他，status 在同 gate 下获取一致读回；其他 API 不串行 |

实际 classic auto-update 仍由 hello `need_update` 触发，`pushUpdate` 等待对应 ACK，检查 `t=ok`；enqueue 完成不释放 writer。断连/超时返回未知并保留 lease，不宣称升级成功。原 mixed/bound boot 关闭 classic auto-update 的规则未改，`StartupUnlockCLITests` 覆盖该选择；没有新增 ready-trigger 环境库自动更新。

手动 env update/rollback、既有 classic 更新、RPC bootstrap 写入与 system shutdown 共用实例 coordinator。成功 shutdown/reboot 封闭新 writer。GUI Stop/SIGINT 先 seal 新操作及排队操作，等待当前 writer；CLI Stop 含 force 在活动/未决 writer 时 busy 且不发信号。独立 VM 不互相等待。

依据 Ruling24：host 请求返回 pending 并不释放 online fd。普通 environment status 和 ready 事件可以进行有界只读 reconciliation；只用历史 context/hash 作比对，不保留旧 Source 授权。要求同 VM/daemon instance/full daemon hash、原 operation/generation/mode、journal 完整终态、完整实际文件摘要、guest gate 确认 worker idle、journal 及当前 root readonly 才释放。仅 transport generation 更新或新 daemon instance 不足以释放。任何后续 mutation 重新获取 live Store/source 资格。

classic、上传或普通 bootstrap/shutdown RPC 在断连后缺少可核对的 environment journal 时，coordinator 保守保留锁至宿主进程退出；不能由当前泛用 status 自动解锁。该限制明确保留为 unknown/pending，不伪造终态。外部直接 SIGKILL 不能由 advisory lock 阻止。

## RED / GREEN 证据

目录：`research/evidence/2026-10-13-task7/`。`manifest.json` 索引 43 次执行，逐次包含完整原始日志与 gzip 的 SHA256、精确 argv、exit、耗时；失败日志、编译失败和环境失败均保留。

开发 Swift 命令统一使用 `swift test --scratch-path /private/tmp/vphone-five-tasks-swift-20261012 --force-resolved-versions --filter <selector>`，通过 `run.py <name>` 保存输出。每项精确 selector 与完整命令在同名 `.command.json`，原文输出在 `.log`/`.log.gz`。

| 行为 | RED 证据与结果 | 后续 GREEN |
| --- | --- | --- |
| journal save 错误停止写入、restore 缺项拒绝 | `journal-restore-red-escalated` exit1，原 try? save 继续下一次替换；宽松 restore 返回成功 | `journal-restore-green` exit0；最终完整套件通过 |
| journal 输出读回、未决批次和 corrupt set | `journal-integrity-red` exit1，3 类实际行为失败 | `journal-integrity-green` exit0 |
| install previous hash 与完整未改文件读回 | `install-integrity-red` exit1 | `install-integrity-green` exit0 |
| 两次在线更新互斥 | `coordination-red` exit1，两个实际 updater 同时上传/install | `coordination-green2` exit0 |
| 缺少 live runtime 的实际 executor 拒绝写入 | `source-route-red2` exit1，原路由仍允许写入 | `source-green3` exit0 |
| daemon 实际构建布局 | `source-layout-red` exit1，候选 fixture 使用实际 candidate-v2/vphoned 路径 | `source-green3` exit0 |
| unknown mode、上传后 mode 变化 | `mode-red` exit1，仍上传或 install | `mode-green` exit0；guest reader 10 类异常通过 |
| 安装成功回复丢失 | `lostreply-red2` exit1，4 个断言失败：未恢复、缺 operation/context | `recovery-green` exit0；单次 install 后同 journal 完整读回 |
| classic ACK/断连与实际 bootstrap.firmware FIFO | `callers-red` exit1，descriptor 入口未加载 binary；firmware RPC 越过 writer | `journal-safety-green` 中对应 2 个 XCTest 通过；最终全部通过 |
| journal 临时 symlink、未知输出后继续安装 | `journal-safety-red` exit1，2 个行为失败 | `recovery-green` exit0 |
| linked candidate 父路径、未知 RPC 释放锁 | `source-rpc-red3` exit1，来源被接受；未决 RPC 未封闭 writer | `source-rpc-green` exit0 |

`journal-restore-red` 是 sandbox compiler-cache 失败。`coordination-scaffold-red`、`async-store-scaffold-red`、`source-route-red`、`lostreply-red`、`callers-green/green2`、`callers-recovery-green`、`source-rpc-red/red2` 含新增 API、Swift concurrency、tuple 或测试宏编译错误，不作为行为 RED。`source-green` 是 fixture 的目录规范化错误；`source-green2` 是只读 status 被错误施加写入资格，均已修正。`journal-safety-green` 的旧保留策略测试失败促使检查失败事务当时保存的 afterFiles，而非将后来合法更新的当前文件误当未知输出。

流程偏差：source scope helper 在其独立 fixture RED 前已起草；Ruling24 的 retained-lease 扩展先实现后补独立回归。没有用其他 RED 替代这些接口的 test-first 证明。早期开发命令保留 BASE、argv/exit/raw，但未逐次归档 dirty working-tree 源码快照；这些运行的 manifest `sourceSnapshotAvailable=false`，不能归属于最终 sourceSHA。最终验证已保存逐文件 SHA 和可重建 source overlay。

## 最终受影响验证

最终源码摘要：`444dfe5f05a7a55b677ef259ce522196cc75fd71252607ffd922c67f122d444e`。该值为 `baseGitSHA + modifiedSourceSHA256` 的 canonical JSON SHA256，具体映射见 `final-swift-affected.source.json`。`final-source-overlay.tar.gz` 保存 24 个修改/新增 source/test 文件，`final-source.patch` 保存 tracked diff。最终运行均有 `.source.json`。

```sh
.venv/bin/python3 research/evidence/2026-10-13-task7/run.py final-swift-affected swift test --scratch-path /private/tmp/vphone-five-tasks-swift-20261012 --force-resolved-versions --filter 'VPhoneDaemonWireTests|GuestEnvironment|GuestTransportTests|GuestWriteCoordinationTests|HostRPCTests|HostControl|VMStopTests|CoreBundleStoreTests|CoreBundleTests|StartupUnlockCLITests|Shutdown'
```

exit0：`Executed 114 tests, with 0 failures`；`Test run with 103 tests in 18 suites passed`。包含实际 socketpair ACK/断连、RPC FIFO/ordinary read、queued Stop seal、真实跨进程 flock、force Stop 不 signal、Store async 取消/失效、VM runtime/frozen source、guest operation 全字段和实际 guest gate 并发。

```sh
.venv/bin/python3 research/evidence/2026-10-13-task7/run.py final-python-environment-escalated .venv/bin/python3 -m unittest discover -s tests -p test_cfw_env_update.py
.venv/bin/python3 research/evidence/2026-10-13-task7/run.py final-python-daemon-build .venv/bin/python3 -m unittest discover -s tests -p test_daemon_api_build.py
```

分别 exit0，48 tests OK、9 tests OK。前次 `final-python-environment` exit1：15 failures/1 error，实际输出含 sandbox `ps: Operation not permitted`；未削弱测试，允许只读进程查询后复验通过。driver 的 Disk.img 为临时目录夹具/tar，不是真实 VM 磁盘；没有真实 mount。

```sh
.venv/bin/python3 research/evidence/2026-10-13-task7/run.py final-daemon-snapshot-build2 xcodebuild -project /private/tmp/vphone-task7-daemon-source.snapshot/sources/VPhoneDaemon/VPhoneDaemon.xcodeproj -scheme vphoned -configuration Release -destination generic/platform=iOS -derivedDataPath /private/tmp/vphone-task7-daemon-build -clonedSourcePackagesDirPath /private/tmp/vphone-task7-daemon-packages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -jobs 4 CODE_SIGNING_ALLOWED=NO build
```

exit0：`BUILD SUCCEEDED`。依赖来自既有 managed worktree 固定本地副本，`check_daemon_api.py --checkouts` 检查通过；未获取新源码。源码副本 manifest 记录 67 个必要文件（daemon/project、signer、构建脚本及 Native 直接包含的 VCamFrameProtocol.h）。第一次 snapshot build 因漏拷该头失败，完整日志保留。最终 import/link signer 路径全在 snapshot `.build`，未签名、未安装、未启动 daemon/VM。

未重复全标准测试或固件 suite；真实 VM、业务功能、实际 remount/reboot/掉电恢复由 Task12 验收。源码、测试、计划和本报告的 `git diff --cached --check -- sources tests docs .superpowers/sdd/2026-10-12-five-task-completion/task-7-report.md` 通过。完整暂存检查报告原始日志中的行尾空白；原始日志按证据要求保留原字节。

## 构建隔离执行偏差

首次 `daemon-build` 虽指定临时 DerivedData，Xcode 的 `Build Guest Signer` 仍执行真实仓库 `scripts/build_guest_signer.sh`，其第8行输出为 PROJECT_ROOT/.build。由此写入主 `.build/daemon-api-v2/signer-Release` 的 5 个文件：`VPhoneSign.abi.json`、`.swiftmodule`、`.swiftdoc`、`.swiftsourceinfo`、`libVPhoneSign.a`。这是违反保护主 .build 约束的执行偏差，不能报告 main .build untouched。

`main-build-deviation.json` 保存当前路径、大小、mtime_ns、SHA256，并与已知 managed worktree 旧副本比较：abi/module/doc 摘要相同，archive/sourceinfo 不同。旧副本不构成主目录构建前原始字节证据；原状态无法证实，因此未覆盖、删除或声称已恢复。原日志及当前文件均保留。

随后构建改用最小源码 snapshot，没有修改产品构建脚本。`daemon-isolation-verification.json` 证明最终日志不含主目录 signer path，所有 signer import/link 指向临时副本；主目录这5个文件在最终 snapshot 构建前后摘要和 mtime 均未变。

## 文件与自审

产品修改覆盖：BundleStore async lease；VPhoneCore online-operation lock/VMStopper；daemon GuestAPI/Environment caller 与 Wire transaction/eligibility/operation gate；host Source/Recovery/Coordinator、Updater、Control、HostCommandExecutor、AppDelegate 和 force 帮助。

测试修改覆盖：CoreBundleStoreTests、GuestEnvironmentSourceTests、GuestEnvironmentUpdateTests、GuestWriteCoordinationTests、GuestTransportTests、EnvironmentTransactionTests、EnvironmentEligibilityTests、EnvironmentOperationTests。root 已授权将其对 `docs/superpowers/plans/2026-10-12-five-task-completion.md` 的2行 Task7→Task10依赖说明纳入本提交。

自审修正了实际 daemon 文件路径、普通 status 资格误用、父路径符号链接、classic descriptor 入口与 ACK、bootstrap.firmware 漏入口、未决 fd 生命周期、只读 remount 与 journal terminal 的先后关系、未知输出、历史 journal 排序和完整未改文件读回。锁均非阻塞，无 Store/VM 反向等待。没有修改 B 的 host-file installed-origin validator，没有新增来源成功侧账。

尚未验收的边界：真实 guest remount、LC_CODE_SIGNATURE 的密码学/系统有效性、实际进程/相机/定位行为、旧 daemon 的真实停机兼容操作，以及 Task10 的 online same-journal host receipt/origin 发布与恢复。失去完整终止证据时，Stop 可持续 busy，GUI/SIGINT 持续等待；不以超时、transport 换代或未知 JSON 自动放行。

三份既有 untracked research 文档未修改、未 stage；未读取或写入根 TODO.md。没有真实 VM/磁盘写入、mount、sudo、系统服务安装、AMFI/TCC 修改或 push。
