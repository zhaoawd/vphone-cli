# T24 宿主策略与权限边界

日期：2026-10-01。执行清单 T24（P3/P7）。本任务在独立 worktree 完成，起点为本地提交 `80c91c8`（T08）。上游固定目标为本地 tag `upstream-2.2.3`（`a969cd5d9206932dc1a2797348027fbc7d0ee347`），基线为 `upstream-2.0.8`（`03b6bbe7`，tag 对象；指向 `9d218de`）。只用 `git log`/`git show`/`git diff` 读取上游，未 checkout、merge 或 cherry-pick。

## 1. 来源提交与路径

| 提交 | 主题 | 上游路径 |
| --- | --- | --- |
| `a23a765` | 多系统 Mac 的宿主策略检查 | `VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadHostPolicy.swift`、`VPhoneLaunchpad/Tests/HostPolicyTests.{sh,swift}` |
| `7a9b4f7` | arm64e.x1 宿主上的 AMFI escalator | `Research/Host/macos27_m6_amfi.md`、`VPhoneExecutable/VPhoneEscalator/VPhoneEscalator/VPhoneEscalator.c`、`VPhoneExecutable/VPhoneVirtualization/Build/StageBundle.sh` |
| `bd36b5e`、`ae5e453` | Core Bundle 最低版本 2.0.8 → 2.1.0 → 2.2.0 | `VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift` |
| `dae9345` | 存储名 `-ci.<commit>` 后缀、`bundleVersion(of:)`；安装器按其比对 Info.plist | 同上，及 `VPhoneLaunchpad/VPhoneLaunchpadHelper/VPhoneLaunchpadHelperBundleInstaller.swift` |
| `3774569`、`d930e50` | helper 增加 `updateGuestEnvironment`；删除 `forceDyldSharedCacheMaxSlide` | `VPhoneLaunchpadHelperService.swift`、`VPhoneLaunchpadHelperFirmwareRequest.swift`、`VPhoneLaunchpadHelperProtocol.swift` |
| `090df08` | helper/AMFI 错误文案改写 | `VPhoneLaunchpadHelperAMFI.swift` |
| `6615c8b`、`dae9345` 等 | Launchpad 宿主检查：初始化即检查、可跳过项 | `VPhoneLaunchpad/VPhoneLaunchpad/HostSetup/VPhoneLaunchpadHostSetup.swift` |
| `f3cac9d`、`5b0b16d` | 未完成 CFW 的 VM 拒绝启动；`BundleStateError` 不打印用法 | `VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneBootCommand.swift`、`Restore/VPhoneRestoreInfo.swift`、`Bundle/VPhoneBundleReport.swift` |
| （无变化） | `VPhoneHostFilePermissions` 在 2.0.8 与 2.2.3 之间无差异 | `VPhoneKit/VPhoneCoreKit/Process/VPhoneHostFilePermissions.swift` |
| `85a4da0`…`e8b16de` 等 release 提交 | `VPhoneRuntimeVersion.unbundledVersion` 2.0.8 → 2.2.0；manifest 其余部分无变化 | `VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneVirtualMachineManifest.swift` |

定位命令：`git log --oneline upstream-2.0.8..upstream-2.2.3 -- VPhoneLaunchpad VPhoneKit/VPhoneCoreKit VPhoneExecutable/VPhoneVirtualization Research/Host`，以及 `git diff --stat upstream-2.0.8 upstream-2.2.3 -- VPhoneLaunchpad` 和 `-- VPhoneKit/VPhoneCoreKit`。Launchpad CLI、并发 socket、UI 和翻译提交属于 T25–T27，本文不展开。

## 2. 对照表

状态取值：已等价、缺失（本次迁入）、缺失（未迁入）、本地有意不同、不适用。行号为本次提交后的位置。

| 上游变化 | 状态 | 本地位置 | 说明 |
| --- | --- | --- | --- |
| SIP 与研究客体检查改用 `csr_get_active_config`，按位 `1<<2`、`1<<12` 判定；缺符号或调用失败时拒绝并给出原因（`a23a765`） | 缺失（本次迁入） | `sources/VPhoneCore/VPhoneHostSecurityPolicy.swift:9`；`sources/VPhoneCore/VPhoneDiagnosticChecks.swift:315`、`:343` | doctor `research_guests` 以 `CSR_ALLOW_RESEARCH_GUESTS` 位为准；查询不可用时回退 `csrutil` 并在证据 `csr_query` 写明原因。`sip_status` 仍按 `csrutil status` 文本定级，只增加 CSR 证据。 |
| helper 在准入 VM 二进制前调用同一宿主策略（`requireReady`） | 不适用 | `sources/VPhoneHelperKit/VPhoneHelperProtocol.swift:18` | 本地 helper 只有安装/验证 Core Bundle，没有 AMFI 放行或 VM 准入操作，无调用点。 |
| 宿主检查：Apple silicon（`hw.optional.arm64`） | 缺失（本次迁入） | `sources/VPhoneCore/VPhoneDiagnosticChecks.swift:273` | 新增 doctor 代码 `host_architecture`；值为 1 通过，0 或不存在均为 error 并写明原因。 |
| 宿主检查：macOS 15+ | 已等价 | `sources/VPhoneCore/VPhoneDiagnosticChecks.swift:261` | |
| 宿主检查：非虚拟机（`kern.hv_vmm_present`） | 已等价 | `sources/VPhoneCore/VPhoneDiagnosticChecks.swift:293` | |
| 宿主检查：剩余空间（上游 100 GB 警告） | 本地有意不同 | `sources/VPhoneCore/VPhoneDiagnosticChecks.swift:398` | 本地阈值 50 GiB，未改。 |
| 宿主检查：库卷为 APFS | 缺失（未迁入） | — | 本地 clone 有 APFS 优先与普通复制回退；非 APFS 库卷的实际影响未取证。 |
| 宿主检查：Developer Tools 授权、网络、CPU/内存、helper 状态 | 不适用 | — | 属 Launchpad 应用 UI；本地 CLI 无对应入口。 |
| 宿主检查可跳过项（UserDefaults 记录） | 不适用 | — | 本地 doctor 只报告不阻断；UI 行为归 T26。 |
| arm64e.x1：escalator 双切片构建、剥离 PAC 位（`7a9b4f7`） | 本地有意不同 | `sources/VPhoneBundleStore/VPhoneCoreBundleStore.swift:169` | 本地未迁入 `VPhoneEscalator` 源码与构建，AMFI 放行使用 amfidont；本地存储只要求 `vphone-escalator` 存在、可执行、签名有效。本次新增三项可执行文件必须含 arm64 切片的检查（`VPhoneMachOArchitectures.swift`），不要求特定子类型。该检查是本地补充，上游存储无此检查。 |
| Core Bundle 最低版本 2.2.0（`ae5e453`） | 缺失（本次迁入） | `sources/VPhoneBundleStore/VPhoneBundleReceipt.swift:41` | 原本地最低 2.0.8。拒绝信息写明请求版本与最低版本。 |
| 存储名 `X.Y.Z-ci.<7–40 位十六进制>`；Info.plist 以去后缀版本比对（`dae9345`） | 缺失（本次迁入） | `sources/VPhoneBundleStore/VPhoneBundleReceipt.swift:58`；`VPhoneCoreBundleStore.swift:150` | 上游 `isValidVersion` 接受更宽的字符集；本地仍只接受 `X.Y.Z`、`-local`、`-ci.<hex>` 三种形式（本地有意不同）。 |
| 收据字段 `version/sha256/installedAt/cdhashes` | 已等价 | `sources/VPhoneBundleStore/VPhoneBundleReceipt.swift:10` | 2.0.8→2.2.3 字段无变化。本次把收据错误拆为 JSON 结构、版本、cdhash 键集合、sha256 格式、cdhash 格式五种原因（`VPhoneCoreBundleStore.swift:134`）。 |
| 使用前 cdhash 复核（`VPhoneLaunchpadHelperCodeCheck`） | 已等价 | `sources/VPhoneBundleStore/VPhoneCoreBundleStore.swift:97`、`:107` | 2.0.8→2.2.3 无变化；`withVerifiedExecutable` 只接受枚举 `vphone-cli`/`vphone-vm`，无任意路径参数。 |
| helper 连接要求 `SMAuthorizedClients` 首项 | 已等价 | `sources/VPhoneHelperKit/VPhoneHelperService.swift:68` | 本地要求同团队 `com.vphone.cli` 或 `com.vphone.launchpad`。 |
| helper 记录调用者 `effectiveUserIdentifier/GroupIdentifier` 用于 CFW 机器所有权与取消 | 本地有意不同 | `sources/VPhoneHelperKit/VPhoneHelperService.swift:79` | 本地无 CFW verb，无消费者。本次新增接受连接时按 audit token 复核调用者代码身份，拒绝时向 helper stderr 写出 pid、uid 与 OSStatus；逐消息 `setCodeSigningRequirement` 保留。 |
| helper `updateGuestEnvironment`、`installCustomFirmware`、`removeBundle`、`allowVirtualMachine` | 本地有意不同 | `sources/VPhoneHelperKit/VPhoneHelperProtocol.swift:18` | helper 注册与生产安装暂缓；不新增任意命令、CFW、AMFI 或删除 verb。 |
| 授权规则（admin、认证用户、非共享、300 秒） | 已等价 | `sources/VPhoneHelperKit/VPhoneHelperAuthorization.swift:8` | 2.0.8→2.2.3 无变化；本地另要求 `allow-root` 为 false。 |
| `VPhoneHostFilePermissions.makeAccessible` 递归 `fchmod 0777` | 本地有意不同 | — | 不吸收。2.0.8→2.2.3 该文件无变化。 |
| 同一文件的描述符遍历：单设备、不跟随链接、跳过多链接普通文件、root 下跳过第三方账户条目 | 缺失（本次迁入） | `scripts/cfw_install_host.sh:226` | 本地所有权恢复原为逐名 `chown -Rx`（不跟随链接、单设备，但会修改硬链接和第三方条目）。改为 `find -x` 只对 root 或调用者所有的目录和单链接普通文件执行 `chown -h`，第三方目录不进入；不修改 mode。 |
| manifest schema 2 诊断与 `requireVersion2` | 本地有意不同 | `sources/VPhoneCore/VPhoneVirtualMachineManifest.swift:10`、`:19` | 本地对带 `schemaVersion` 的 manifest 显式拒绝且不升级（计划第 2 节）。上游本区间只改 `unbundledVersion`。 |
| CFW 未完成的 VM 拒绝启动、`customFirmwareInstalled`、`BundleStateError`（`f3cac9d`、`5b0b16d`） | 缺失（未迁入） | — | 依赖 restore-info `variant` 的写入语义，归 T15/T16。 |
| helper/AMFI 错误文案（`090df08`） | 不适用 | — | 本地无 AMFI helper 路径。 |

## 3. 改动

- `sources/VPhoneCore/VPhoneHostSecurityPolicy.swift`（新）：只读 `csr_get_active_config`，查询函数可注入；失败调用即使写出数值也不返回配置。
- `sources/VPhoneCore/VPhoneDiagnosticChecks.swift`、`VPhoneDiagnostics.swift`：probe 增加 `csrActiveConfig`（初始化参数带默认值，默认 `not probed`，既有注入测试行为不变）；新增 `host_architecture`；`research_guests`/`sip_status` 增加 CSR 证据。
- `sources/VPhoneBundleStore/VPhoneBundleReceipt.swift`：最低版本 2.2.0，`-ci.<hex>` 后缀，`release(of:)`，格式错误与版本过低分开报告。
- `sources/VPhoneBundleStore/VPhoneCoreBundleStore.swift`：收据逐项原因；`requireEntry` 与目录树检查写出失败的具体属性（类型、owner uid、mode、链接数）；Info.plist 比对使用 `release(of:)`；可执行文件架构检查。
- `sources/VPhoneBundleStore/VPhoneMachOArchitectures.swift`（新）：读取 fat/thin Mach-O 头中的 cputype，不加载、不执行。
- `sources/VPhoneHelperKit/VPhoneHelperService.swift`：`callerRejection(auditToken:pid:uid:requirement:)` 与接受时复核。
- `sources/vphone-cli/VPhoneCoreBundleCLI.swift`：`--version` 帮助文本。
- `scripts/cfw_install_host.sh`：`restore_invoker_ownership`；缺少或非数字 `SUDO_UID` 时不改所有权并报告。
- 测试：`tests/VPhoneBundleStoreTests/CoreBundleStoreTests.swift`、`tests/VPhoneCoreTests/DiagnosticsTests.swift`、`tests/VPhoneCLITests/DoctorCLITests.swift`、`tests/VPhoneHelperKitTests/HelperTests.swift`、`tests/test_cfw_host_isolation.py`。

未修改 `VPhoneCreate*`、`VPhoneFWCLI.swift`、`VPhoneVMCreateCLI.swift`、`sources/FirmwarePatcher`、执行清单与实施计划。

## 4. 验收条件对应

| 条件 | 拒绝位置与原因文本 | 测试 |
| --- | --- | --- |
| 错误系统版本 | doctor `macos_version` error（原有）；Core Bundle 版本低于 2.2.0：`older than the minimum supported version 2.2.0` | `invalidVersionRefusedBeforeStoreCreation`、`refusedInstallLeavesExistingStoreUnchanged(old-version)` |
| 错误架构 | doctor `host_architecture` error；Core Bundle 可执行文件 `has no arm64 slice (found: x86_64)` | `hostArchitectureRequiresArm64`、`refusedInstallLeavesExistingStoreUnchanged(x86_64)` |
| 宿主安全策略 | `CSR_ALLOW_RESEARCH_GUESTS is clear in the active kernel configuration`；查询失败 `csr_get_active_config failed (status -1, errno 5)` | `researchGuestsFollowActiveKernelConfigurationOnMultiOSHosts`、`csrQueryFailuresAreReportedNotGuessed` |
| 错误签名 | `Invalid code signature at …`；`Installed vphone-cli cdhash … differs from its receipt (…)` | `refusesModifiedInstallation(resource/binary/cdhash/resigned)` |
| 无效收据 | 五种原因，见第 2 节 | `receiptFieldsAreRefusedWithSeparateReasons`、`refusesModifiedInstallation(receipt/receipt-version)` |
| 权限不足 | 非 root 安装：`Core Bundle installation requires root (sudo).`；存储条目：`owner uid …`、`mode 666`、`2 hard links, expected 1`、ACL | `productionStoreRefusesNonRootBeforeAnyHostAccess`、`refusesModifiedInstallation(writable/hardlink/acl)`、`rejectsUnsafeStore` |
| 调用者身份不符 | helper：`caller pid P, uid U does not satisfy the client signing requirement (OSStatus …)`；无 audit token 时 `has no audit token` | `callerIdentityMismatchNamesTheCaller`、`callerMatchingItsOwnDesignatedRequirementIsAccepted`、`xpcRejectsClientWithoutConfiguredSigningIdentity` |
| 拒绝路径不改 mode/owner | 存储：拒绝前后对全部条目的 mode/uid/gid/链接数/大小做 lstat 快照比较；CFW：硬链接、符号链接、第三方条目不被 chown | `duplicateInstallPreservesOriginalReceiptAndModes`、`refusedInstallLeavesExistingStoreUnchanged`（5 例）、`refusesModifiedInstallation`（10 例）、`test_ownership_restoration_*`（4 项） |

`productionStoreRefusesNonRootBeforeAnyHostAccess` 只在非 root 时运行，断言 `/Library/Application Support/vphone-launchpad/Bundles` 的存在性、mode 与 owner 不变。测试未调用 sudo、未注册 helper、未写系统目录。

## 5. 命令与结果

环境：worktree 的 `.venv` 为指向主仓库 `.venv` 的符号链接；递归初始化 `vendor/*` 子模块；按 Makefile 格式生成被忽略的 `sources/vphone-cli/VPhoneBuildInfo.swift`。日志位于会话 scratchpad，未入库。

| 命令 | 结果 |
| --- | --- |
| `swift test --filter CoreBundleStoreTests` | 18 项通过（首轮 3 项失败：收据 `installedAt` 秒级截断导致整体比较不等、夹具重复写归档、重签 bundle 同时改变 `vphone-cli` cdhash；均为测试写法，已修正断言与夹具，未改产品逻辑） |
| `swift test --filter "DiagnosticsTests\|DoctorCLITests"` | 39 项 / 5 suites 与 4 项 / 1 suite 通过 |
| `swift test --filter "HelperServiceTests\|HelperConfigurationTests"` | 13 项 / 2 suites 通过（首轮测试编译错误：`SecCodeCopyDesignatedRequirement` 需 `SecStaticCode`，已修正） |
| `.venv/bin/python3 -B -m unittest tests.test_cfw_host_isolation` | 18 项通过；同一测试对改动前脚本运行为 4 项失败 |
| `make test_python` | 403 项通过，1 项跳过（T08 记录 400 项；本项新增 3 项） |
| `make test_swift` | 退出 0；Swift Testing 10 次运行共 749 项通过（T08 为 738，本项新增 11 项）；XCTest 共 180 项执行、3 项跳过、0 失败；tar pipe 两条 1 GiB 路径峰值 RSS 10,010,624 / 8,044,544 字节；`test_guest_components` 124 项检查 0 失败 |
| `.build/debug/vphone-cli doctor --json --library-root <空目录>`（只读） | `host_architecture` ok；`research_guests` ok，证据 `csr_active_config=0x00001004`；`sip_status` warning（custom configuration，`Debugging Restrictions: disabled`）。退出码 5 来自 worktree 中缺少运行资源等其他项，与本任务无关 |

`make test_swift` 日志中出现 `vphone-helper: refused connection: caller pid …, uid 501 does not satisfy the client signing requirement (OSStatus -67050 …)`，来自 `xpcRejectsClientWithoutConfiguredSigningIdentity`，说明匿名 listener 在接受阶段拒绝了未签名调用者。

## 6. 事实、推断与未验证

事实：

- 上游 2.0.8→2.2.3 中 `VPhoneHostFilePermissions.swift`、`VPhoneLaunchpadHelperAuthorization.swift`、`VPhoneLaunchpadHelperCodeCheck.swift` 无差异；收据字段无差异。
- 本机 macOS 27.0（26A428）、Apple M5 Pro（Mac17,9）。`csr_get_active_config` 返回 `0x00001004`；`/usr/libexec/amfid` 为 `arm64e`+`arm64e.x1` 双切片（`lipo -info`）；`/usr/bin/true` 为 `x86_64`+`arm64e`+`arm64e.x1`。
- 改动前的 `cfw_install_host.sh` 在新增 4 项所有权测试上失败 4 项，改动后通过。

推断（待验证假设）：

- 上游说明中 M6 的 `amfid` 以 `ARM64E.X1` 运行。本机 `amfid` 实际运行的切片未查（需 `vmmap` 或进程元数据，可能需 root）。本地未使用 escalator，该问题对本地 amfidont 路径的影响原因未查明。
- `csr_get_active_config` 在多系统 Mac 上返回当前运行内核的配置，依据为上游提交说明与 XNU 接口；本机只有单一系统，未在多系统 Mac 上实测。

未验证：

- 多台或多系统宿主上的 doctor 结果。
- 真实 helper 注册、SMJobBless、生产 Core Bundle 安装与跨 UID 读取（按 9 月 30 日决定继续暂缓）。接受时 audit token 复核只在匿名 listener 与自身 token 上测试，未经 launchd 特权 helper 实测。
- 以 sudo 运行的真实 CFW 安装中的所有权恢复（测试使用 chown 替身与非 root 临时目录，未覆盖 root 所有条目）。
- 上游 2.2.x Core Bundle 发布包在本地存储中的安装。
