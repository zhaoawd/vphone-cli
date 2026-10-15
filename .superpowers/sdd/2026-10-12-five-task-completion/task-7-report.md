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

## Fix1：独立审查 Important 1–4

本轮 BASE 为 `379bb75b96ea88620f8e82c85b5e118e8f18d634`。四项 Important 已逐项实施和验证，仍待独立 scoped review；本节不将原 Task7、Task6 或五项整体验收标为完成。提交 subject 延用 `fix: coordinate and verify guest environment transactions`，标识以本节所在提交及最终交付消息为准。

### 修复和实际调用方

1. **旧恢复读回不能释放新 writer 的锁。** coordinator 每次保留 recovery 时生成独立标识，await 后重新检查同一 recovery、pending 状态和 `!active`。确定性交错测试启动两次实际 status 读回，先完成一次、插入持有真实 online-operation fd 的新 writer，再完成旧读回；normal/force Stop 均不发信号。原 RED 记录旧实现发送三次模拟信号并可取得该锁；新 writer 退出后锁可正常取得。
2. **部分和重复回退的完整集合。** recovery 保存原 journal 的全部行，以及本次 `replaced` 子集。逐行比较名称、安装摘要、前置摘要、backup 和状态；本次回退行遵循顺序及停止规则，其他行保持原状态。测试使用实际 `EnvironmentTransaction.prepare/apply/prepareRestore/bindRestore/applyRestore/finalize/journal`、真实临时旧/新文件和持久 journal，覆盖 partial install 的 failed/not_attempted 行、以前 restored/restore_failed 行，以及本次剩余 replaced 行。只在受控 transport 映射中把临时 backup 根路径投影为协议固定根路径；摘要和状态均来自实际 journal。回退回复丢失时不重发，完整读回后释放锁。
3. **原始和回复证据。** restore 先验证完整五库 before_files/after_files、摘要格式、context 标识与摘要字段、operation/id、冻结计划/VM/mode，并核对原 journal 状态推导的完整输出及实际安装摘要。回复必须保留同一 before_files 和原 context；after_files 必须与实际读回一致。reconciliation 同样要求原 context/before_files。缺失、篡改请求组件或未请求组件的证据均拒绝；原始证据错误在发送 restore 前拒绝。旧成功 fixture 改为由真实临时文件经过生产 journal 生成，不补写假定的 before_files。若原事务之后完整安装集合发生变化，本次回退失败关闭，要求先检查安装状态。
4. **外部 proxy 维护入口。** 按 Ruling25/26，原用户 token 固定为 external；内部 `VPhoneAPISession` 使用同一 proxy 生成的随机进程内 internalToken，未写日志、环境、文件或用户输出。初始认证删除所有大小写变体/重复的客户端分类头和 nonce 头。external 连接在同一 guest socket 执行 `/v1/proxy-admission`，核对新 capability、daemon instance UUID、完整 binary hash、external 分类及新 nonce，然后仅转发一个原 HTTP 请求或 WS upgrade。旧、缺失、畸形、错误 nonce 或断连均不转发，并返回 `proxy_maintenance_unavailable` 及使用 host RPC/CLI 或停机更新 daemon 的诊断。

`GuestProxyAdmission` 固定连接分类并只允许消费一次原请求；HTTP job 和 WS job 把固定分类传到 `APIWire.execute`、`GuestAPI.execute`、`GuestMaintenanceGate.run`。既定九个维护方法在执行 body 前拒绝 external，提示使用受协调的 host RPC/CLI。普通查询与媒体继续转发。内部实际 `VPhoneAPISession → HostCommandExecutor → coordinator → proxy → gate` 的 bootstrap 测试保持真实 online fd，normal/force Stop 均 busy 且不 signal；并发 external shutdown 被拒绝，普通 read 可完成。没有改变原 Store/VM/online-operation 锁顺序，没有全局串行 API，也没有新增自动环境更新。

自审发现固定 NIO 的 `HTTPServerUpgradeHandler` 会在首个非 upgrade 请求后移除自己。若 admission 由普通 HTTP handler 处理，随后 WS upgrade 会失败。专用 `GuestProxyAdmissionHandler` 因此放在 HTTP decoder 之后、upgrade handler 之前，消费一次预检后移除自身，使原请求仍能升级。既有单请求 HTTP 关闭和 WS 生命周期保留。独立小 harness 使用同一生产 handler/class 与固定本地 NIO，验证真实 pipeline；不添加主 Package 的 NIO 依赖。

### RED/GREEN 与精确证据

证据目录为 `research/evidence/2026-10-13-task7-fix1/`。26 次运行均保存完整 `.log`、`.log.gz`、精确 argv/exit 的 `.command.json` 和运行前 `.source.json`；manifest 记录所有 raw/gzip SHA-256。Swift 命令共同前缀为：

```text
swift test --scratch-path /private/tmp/vphone-five-tasks-swift-20261012 --force-resolved-versions --filter
```

下表 selector 是紧接前缀的一个完整参数；各 run 由 `.venv/bin/python3 research/evidence/2026-10-13-task7-fix1/run.py <run> <argv...>` 执行。

| 问题 | selector | RED | GREEN |
| --- | --- | --- | --- |
| 并发恢复 | `GuestEnvironmentUpdateTests/testConcurrentOldReconciliationCannotReleaseNewWriterLease` | reconcile-red：exit1，2 failures，Stop signal=3 | reconcile-green：exit0 |
| 完整回退集合 | `GuestEnvironmentUpdateTests/testActualPartialAndRepeatedRestoreLostReplyReleaseLeaseAfterFullReadback` | partial-restore-red3：exit1，4 failures，两个分支均保留已完成操作的锁 | partial-restore-green：exit0 |
| 原始/回复证据 | `GuestEnvironmentUpdateTests/testRestoreRejectsMissingOrTamperedOriginalAndReplyEvidence` | restore-evidence-red：exit1，22 failures | restore-evidence-green：exit0，含相关5 tests |
| 恢复读回证据 | `GuestEnvironmentUpdateTests/testActualPartialAndRepeatedRestoreLostReplyReleaseLeaseAfterFullReadback` | recovery-evidence-red：exit1，4 failures，缺失 before_files/context 仍释放 | restore-evidence-green：exit0 |
| 未请求组件完整摘要 | `GuestEnvironmentUpdateTests/testRestoreRejectsOriginalAfterFilesAndUnrequestedBeforeHashTampering` | original-fullset-red：exit1，4 failures | original-fullset-green：exit0，含实际部分/重复回退共2 tests |
| proxy 预检 | `GuestProxyMaintenanceTests` | proxy-admission-red：exit1，2 failures，实际转发 POST 而非 admission | proxy-admission-green：exit0；proxy-callers-green2：5 tests通过 |
| daemon gate | `EnvironmentOperationTests/externalProxyMaintenanceRefusesBeforeAnyMutationWhileReadsProceed` | proxy-gate-red2：exit1，九个维护方法共18 issues | proxy-gate-green：exit0 |

中间失败全部保留：partial-restore-red 为测试局部函数 MainActor 声明错误；red2 在首个锁取得错误后提前结束，red3 改为两分支完整断言。proxy-callers-green 为测试泛型推断、semaphore async 和 await/autoclosure 编译错误，修正测试声明后 green2 通过。proxy-gate-red 使用共享 gate 被 shutdown seal 干扰，red2 每方法独立 gate 得到完整行为失败。gate 的新增默认参数声明本身没有改变行为，18-issue RED 在实现拒绝逻辑前运行。

NIO 的精确命令：

```text
env SWIFTCI_USE_LOCAL_DEPS=1 swift test --package-path /private/tmp/vphone-task7-fix1-nio-harness --scratch-path /private/tmp/vphone-task7-fix1-nio-scratch --force-resolved-versions
```

nio-upgrade-red 在 pass-through 声明阶段运行，预检经普通 handler 后实际得到 `200 OK` 而非 WS `101`，exit1/2 failures。消费预检后 nio-upgrade-green 仍 exit1：EmbeddedEventLoop 中升级回调尚未执行；显式驱动该测试事件循环后 green2 exit0。`nio-harness-red/`、`nio-harness-green1/`、`nio-harness/` 保存对应 Package、测试和生产源拷贝及摘要，manifest 对应各 run。依赖全部来自此前固定的 `/private/tmp/vphone-task7-daemon-packages/checkouts/`，包括 swift-nio/atomics/collections/system；没有 fetch 或修改主 Package.resolved。

### 最终冻结验证

最终源码 `sourceSHA256 = 3042e191bb16691287bb34b0cf4958279469cba5fea1993ad7d358e6ad0d511b`。20 个源码/测试/Package 文件逐项摘要见 manifest；`final-source-overlay.tar.gz` 包括新文件，`final-source.patch` 保存 tracked diff。以下五次 final source snapshot 完全一致，且与当前文件和 overlay 核对一致。

```text
swift test --scratch-path /private/tmp/vphone-five-tasks-swift-20261012 --force-resolved-versions --filter 'GuestEnvironment|GuestWriteCoordinationTests|GuestProxyMaintenanceTests|VPhoneAPIKitTests|EnvironmentOperationTests|HostRPCTests|VMStopTests|GuestTransportTests'
```

`final-swift-affected` exit0：105 XCTest 无失败，65 Swift Testing/11 suites 通过。`final-nio` 使用上列 NIO 命令，exit0/1 test。没有重复全标准或固件 suite。

```text
.venv/bin/python3 -m unittest discover -s tests -p test_daemon_api_build.py
.venv/bin/python3 scripts/check_daemon_api.py --checkouts /private/tmp/vphone-task7-daemon-packages/checkouts
xcodebuild -project /private/tmp/vphone-task7-daemon-source.snapshot/sources/VPhoneDaemon/VPhoneDaemon.xcodeproj -scheme vphoned -configuration Release -destination generic/platform=iOS -derivedDataPath /private/tmp/vphone-task7-daemon-build -clonedSourcePackagesDirPath /private/tmp/vphone-task7-daemon-packages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -jobs 4 CODE_SIGNING_ALLOWED=NO build
```

`final-python-daemon` exit0/9 tests；`final-daemon-pins` exit0；`final-daemon-snapshot-build` exit0/BUILD SUCCEEDED。69 个 snapshot 文件包括新增 handler/class、现有 signer 脚本和 shared header，全部有源码 SHA。producer、import、link 的 signer 路径均在 snapshot `.build`；主目录五份 signer 的本轮前后 hash/mtime 一致，见 `main-signer-baseline.json`、`daemon-isolation-verification.json`。这只能证明 Fix1 未再次修改这些文件，不能恢复或撤销初轮已披露的覆盖。iOS 输出仍有既有 deprecated `init(cString:)` 警告，不宣称无警告。

### 文件、自审和边界

新增生产文件为 `GuestProxyAdmissionHandler.swift` 和 `Wire/GuestProxyAdmission.swift`；新增测试为 `GuestProxyMaintenanceTests.swift`。修改 coordinator/recovery/updater、APIProxy/RequestGate、AppDelegate、daemon APIWire/GuestAPI/HTTP/WS/main/gate，以及对应 tests。`Package.swift` 仅为 VPhoneCLITests 增加现有 VPhoneDaemonWire target 的测试依赖，以运行真实 journal/gate；未新增或升级包依赖。`tests/fixtures/host_api/server.py` 为既有 proxy 传输测试实现新 admission 协议；backpressure 测试使用内部凭据独立验证已通过资格检查后的转发，external 拒绝路径由新实际 proxy 测试覆盖。README 更新 external 客户端的兼容限制。纳入 root 授权的计划两段 Ruling25/26 说明，不改其他计划。

源码、测试、Package、README、计划及本报告的定向 `git diff --check` 通过。raw 日志按原字节保存，未清理编译器行尾空白。证据目录的 `.gitattributes` 对 `*.log` 设置 `-text`，防止 Git 对日志内 HTTP CRLF 做换行转换；暂存 blob 与 raw/gzip 再次逐项核对。自动审批曾拒绝从 HEAD 覆盖整个 HTTP handler 的命令，未执行该命令；随后使用定向补丁迁移 admission 代码，保留其他未提交修改，未绕过审批。

自审核对：恢复标识在 await 后复验；实际 partial/repeated journal 和 before/context 缺失不误释放；external 分类不能通过客户端头、后续 HTTP head 或 WS method 改为 internal；每个 external socket 新预检，不复用另一 socket 的 health；真实内部 RPC 仍进入同一 coordinator。没有真实 VM、磁盘写入、mount、系统服务或签名执行验收。Task10/C2 same-journal origin 发布与 Task12 真实 VM、激活和业务验收仍未完成。三份既有 untracked research 保留。
