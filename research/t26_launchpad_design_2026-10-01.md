# T26 Launchpad 引入设计与分批计划

日期：2026-10-01。执行清单 T26（P7）的设计阶段。本文只给出设计、探测证据和分批计划，不含产品代码。用户已决定在本地引入上游 Launchpad 应用。

## 0. 输入与范围

| 对象 | 值 |
| --- | --- |
| 本地起点 | `6c7cb3f`（分支 `codex/upstream-4bab3b7-integration` 的提交，本 worktree 快进到该提交） |
| 上游目标 | 本地 tag `upstream-2.2.3` → `a969cd5d9206932dc1a2797348027fbc7d0ee347` |
| 上游基线 | 本地 tag `upstream-2.0.8` → `9d218dedf58d4b19db5e51c8b584c1f14a96eee3` |
| 读取方式 | `git show`、`git ls-tree`、`git archive` 解出到会话 scratchpad；未 checkout、merge 或 cherry-pick |
| 宿主与工具链 | macOS 27.0（26A428）；Xcode 27.1（27A9269）；Apple Swift 6.4 |
| 已读本地文档 | CLAUDE.md、Package.swift、Makefile、`scripts/build.sh`、执行清单 T24–T27/T29、实施计划第 2 节/P3/P7/P8、`p3_core_bundle_store_2026-09-29.md`、`p3_helper_xpc_2026-09-29.md`、`t24_host_policy_2026-10-01.md`、`p3_vm_process_integration_2026-09-29.md`、`host_control_protocol_e1_2026-09-11.md` |
| 已读上游 | `VPhoneLaunchpad/` 全部源码与配置、`Documents/Guides/launchpad-cli.md`、提交 `be7f061`、`ded81cb`、`0b46343`、`f57adf6`、`caebc24`，以及 `0cafa79`、`6fb0636` 的说明 |

本阶段未修改 `sources/`、`tests/`，未操作 VM，未注册 helper，未写系统目录。探测用的临时 SwiftPM 包和脚本只在会话 scratchpad，未提交。

## 1. 上游 Launchpad 结构与调用关系（事实）

### 1.1 规模

| 统计 | 结果 | 命令 |
| --- | --- | --- |
| Swift 文件数 | 53 | `git ls-tree -r --name-only upstream-2.2.3 VPhoneLaunchpad \| grep -c '\.swift$'` |
| Swift 行数 | 10,475 | `git archive upstream-2.2.3 VPhoneLaunchpad \| tar -xOf - '*.swift' \| wc -l` |
| `Localizable.xcstrings` 字节数 | 326,504 | `git cat-file -s upstream-2.2.3:VPhoneLaunchpad/VPhoneLaunchpad/Localizable.xcstrings` |
| 2.0.8→2.2.3 Launchpad 差异 | 56 个文件，+9,746/−2,482 | `git diff --stat upstream-2.0.8 upstream-2.2.3 -- VPhoneLaunchpad` |
| 字符串目录 | 372 个 key；源语言 en；en/ja/ko/vi/zh-Hans 各 371 条；5 条 `stale` | scratchpad `xcstrings_stats.py`（读取 JSON 的 `strings`、`localizations`、`extractionState`） |
| `InfoPlist.xcstrings` | 5 个 key，5 种语言 | 同上 |

Xcode 工程有 3 个 target：`VPhoneLaunchpad`（app）、`VPhoneLaunchpadHelper`（SMJobBless helper，`com.vphone.launchpad.helper`）、`VPhoneLaunchpadCLI`（`vphone-launchpad-cli`）。远程包依赖 `libghostty-spm`（`GhosttyTerminal`）；`Package.resolved` 另列 `MSDisplayLink`。系统框架：AppKit、SwiftUI、Observation、ExecutionPolicy、ServiceManagement、Security、CryptoKit。

构建设置（`Configuration/Base.xcconfig`）：`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`、`SWIFT_APPROACHABLE_CONCURRENCY = YES`、`MACOSX_DEPLOYMENT_TARGET = 15.0`、`ARCHS = arm64`、`CODE_SIGNING_ALLOWED = NO`；签名由 `Build/SignLaunchpad.sh` 单独执行，三者均不带 entitlements。

### 1.2 调用关系

- `VPhoneLaunchpadModel` 持有 `VPhoneLaunchpadHostSetup`、`VPhoneLaunchpadCoreBundle`、`VPhoneLaunchpadMachineLibrary`、`VPhoneLaunchpadHelperClient` 和 `VPhoneLaunchpadControlServer`。
- 所有 VM 操作经 `VPhoneLaunchpadCommandLine` 执行“当前选用 Core Bundle”的 `vphone-cli`，路径为 `/Library/Application Support/vphone-launchpad/Bundles/<version>/VPhone.bundle/.../vphone-cli`（`VPhoneLaunchpadBundleStore.executable`）。不经 shell 或 `$PATH`。
- 使用的 CLI 子命令：`vm list --json`、`vm launch [--headless|--dfu]`、`vm stop [--timeout]`、`vm config`、`vm rename`、`vm clone`、`vm delete --force`、`vm export`、`vm import`、`vm new`、`fw catalog --json`、`fw prepare`、`fw patch --preset`、`fw patches`、`fw set-patches`、`restore`、`recovery-probe`、`host preflight --quiet`。
- helper XPC 动词：`installBundle`、`removeBundle`、`allowVirtualMachine`（AMFI）、`installCustomFirmware`、`updateGuestEnvironment`、取消 CFW。`VPhoneLaunchpadCoreBundle.verify` 依次调用 `EPExecutionPolicy().addException`、`host preflight`，遇到 AMFI 拒绝时调用 `helper.allowVirtualMachine` 后重跑。
- VM 进程：`vm launch` 以 `posix_spawn` + `POSIX_SPAWN_SETSID` 分离启动，dlsym 调用 `responsibility_spawnattrs_setdisclaim`，stdout/stderr 追加到 `~/Library/Logs/vphone-launchpad/<name>[-<digest8>].log`。Launchpad 退出后 VM 继续运行。
- 运行判定：`lsof -F n -- <Disk.img...>` 找到持有磁盘镜像的进程即视为运行。
- 创建流程：`VPhoneLaunchpadCreationPipeline` 在 app 内按 9 步逐条调用 CLI；CFW 一步经 helper 以 root 执行；首启后通过 `<bundle>/vphone.sock` 发送 `{"t":"ping"}` 等待 vphoned。
- 控制面：app 在 `~/Library/Application Support/vphone-launchpad/control.sock`（0600，`getpeereid` 同 UID）上提供 `status`、`bundle.*`、`vm.*`、`cfw.*`、`guest.send`、`guest.rpc`、`exec` 共 19 个命令；`guest.*` 转发到各 VM 的 `vphone.sock`；`exec` 以任意参数运行当前 Core Bundle 的 `vphone-cli`。

### 1.3 本地 CLI 对应情况（事实）

| 上游调用 | 本地 `vphone-cli` | 说明 |
| --- | --- | --- |
| `vm list/info/new/config/rename/delete/clone/export/import/launch/stop --library-root` | 有 | `VPhoneBundleReport` JSON 字段与上游 `VPhoneLaunchpadMachine` 解码字段一致，缺 `customFirmwareInstalled`（上游可选字段，解码为 nil） |
| 默认库根 | `~/.vphone/VMs` 或 `VPHONE_LIBRARY_ROOT` | 上游为 `~/.vphone/machines` |
| `vm config --network` | `nat`、`bridged`、`none` | 与上游设置面板取值一致；`hostOnly` 本地拒绝，上游 UI 也映射为 `none` |
| `fw catalog --json` | 有 | `VPhoneFirmwareCatalogReport` 字段（`device`、`pairings[].ios/recommendedCloudOS{name,url}`）一致 |
| `fw patch --preset`、`fw patches`、`fw set-patches` | 无 | 本地用 `--variant regular|dev|jb|exp|less`；`fw plan --json` 为只读计划 |
| `host preflight` | 无 | 本地为 `doctor --json`（schema `vphone.diagnostics` v1）和 `scripts/boot_host_preflight.sh` |
| `recovery-probe`、分步 DFU/restore/stop | 无独立命令 | 本地 `vm create` 的 `restore` 阶段内部完成 |
| `cfw update-environment` | 无 | |
| `VPHONE_PROGRESS=lines` 进度行 | 无 | 本地 `VPhoneProgressBar` 只在 stderr 为 TTY 时输出 |
| 一体创建 | `vm create`、`--resume`、`--restart-from`、`--accept-tool-change`、`vm create-status --json` | 上游 Launchpad 不使用 `vm create`，原因写在其源码注释：一体命令中途要求 sudo |

## 2. 模块映射

### 2.1 本地已有实现（以本地为准）

| 本地模块 | 位置 | 行数 | 覆盖的上游部分 |
| --- | --- | --- | --- |
| `VPhoneHelperKit`、`VPhoneHelperEntry` | `sources/VPhoneHelperKit/`、`sources/VPhoneHelperEntry/` | 与 `VPhoneBundleStore` 合计 1,011（`wc -l sources/VPhoneHelperKit/*.swift sources/VPhoneHelperEntry/*.swift sources/VPhoneBundleStore/*.swift`） | helper XPC、授权规则、调用者复核；只含 `helperVersion`、`installBundle`、`verifyBundle`，标识 `com.vphone.cli.helper`，允许客户端 `com.vphone.cli`、`com.vphone.launchpad` |
| `VPhoneBundleStore` | `sources/VPhoneBundleStore/` | 同上 | 存储根、收据、cdhash 复核、`withVerifiedExecutable`（只接受枚举 `vphone-cli`/`vphone-vm`） |
| `VPhoneCore` 宿主策略与诊断 | `VPhoneHostSecurityPolicy.swift`、`VPhoneDiagnosticChecks.swift`、`VPhoneDiagnostics.swift` | 与下列锁/检查点文件合计 3,438（命令见 2.4） | 上游 `VPhoneLaunchpadHostPolicy`、Host Setup 的架构/系统/非虚拟机/空间检查 |
| `VPhoneCore` 锁与运行记录 | `VPhoneVMLock.swift`、`VPhoneVMRuntimeState.swift`、`VPhoneVMStopper.swift`、`VPhoneLaunchLayout.swift`（`VPhoneBootProcessLocator`）、`VPhoneProcessIdentity.swift` | 同上 | 上游 lsof 运行判定、`vm stop` 目标确认 |
| 创建检查点 | `VPhoneCreateRunner.swift`、`VPhoneCreateCheckpoint.swift`、`VPhoneCreateCheckpointStore.swift`；CLI `VPhoneVMCreateCLI.swift`、`VPhoneCreateOrchestrator.swift` | 同上 | 上游 `VPhoneLaunchpadCreationPipeline` |
| VM 进程 | `vphone-cli`（管理命令）、`vphone-vm`（运行，持 VM 锁） | — | 上游 VPhone.bundle 中的同名程序 |
| 主机控制 socket | `sources/vphone-cli/VPhoneHostControl.swift`，路径 `<bundle>/vphone.sock` | — | 上游 VM 侧 automation socket；T25 正在补并发、headless、方法转发 |

### 2.2 上游文件逐项映射

处理方式取值：直接迁入、改写迁入（保留结构，替换本地接口）、改用本地（上游文件不迁入，由本地实现提供同一功能）、本地已有（不迁入）、不迁入、T25（归 T25 决定）。“批次”见第 9 节。

| 上游文件（相对 `VPhoneLaunchpad/`） | 行数 | 处理 | 本地对应或原因 | 批次 |
| --- | --- | --- | --- | --- |
| `VPhoneLaunchpad/Application/VPhoneLaunchpadApp.swift` | 71 | 改写迁入 | 去掉 Core Bundle 菜单项的安装入口；保留退出前创建确认 | B1 |
| `.../Application/VPhoneLaunchpadModel.swift` | 196 | 改写迁入 | 去掉 helper 安装、发布下载、控制服务器启动；`ded81cb` 的面板时序在 B5 迁入 | B1 |
| `.../Application/VPhoneLaunchpadRootView.swift` | 78 | 改写迁入 | | B1 |
| `.../Application/VPhoneLaunchpadSearchField.swift` | 52 | 直接迁入 | | B1 |
| `.../Application/VPhoneLaunchpadStatus.swift` | 57 | 直接迁入 | 颜色改用本地主题 | B1 |
| `.../Command/VPhoneLaunchpadChildProcess.swift` | 205 | 直接迁入 | | B1 |
| `.../Command/VPhoneLaunchpadCommandLine.swift` | 211 | 改写迁入 | 可执行文件只来自内嵌工具链（第 4 节） | B1 |
| `VPhoneLaunchpadShared/VPhoneLaunchpadLineReader.swift` | 44 | 直接迁入 | | B1 |
| `.../Machines/VPhoneLaunchpadMachine.swift` | 142 | 改写迁入 | 解码 `VPhoneBundleReport`；`firmwareName` 改为本地五变体名称 | B1 |
| `.../Machines/VPhoneLaunchpadMachineLibrary.swift` | 589 | 改写迁入 | 运行判定改用 `VPhoneBootProcessLocator` + 运行记录；去掉 helper CFW/环境更新 | B1 |
| `.../Machines/VPhoneLaunchpadMachineLocations.swift` | 100 | 改写迁入 | 默认根改用 `VPhoneLibrary.defaultRoot()` | B1 |
| `.../Machines/VPhoneLaunchpadMachinesView.swift` | 473 | 改写迁入 | 去掉“Install Custom Firmware”“Update Guest Environment” | B1 |
| `.../Application/VPhoneLaunchpadTerminal.swift` | 201 | 改写迁入 | 保留 `LogWriter`/`LogTail`/换行转换；Ghostty 视图换为只读 `NSTextView` | B2 |
| `.../Machines/VPhoneLaunchpadConsoleView.swift` | 20 | 改写迁入 | | B2 |
| `.../Machines/VPhoneLaunchpadMachineInspector.swift` | 146 | 改写迁入 | 增加创建检查点摘要 | B2 |
| `.../Application/VPhoneLaunchpadFilePanel.swift` | 20 | 直接迁入 | | B3 |
| `.../Application/VPhoneLaunchpadSheet.swift` | 64 | 直接迁入 | | B3 |
| `.../Command/VPhoneLaunchpadCommandHistoryView.swift` | 71 | 直接迁入 | | B3 |
| `.../Command/VPhoneLaunchpadCommandInfoButton.swift` | 35 | 直接迁入 | | B3 |
| `.../Machines/VPhoneLaunchpadMachineSheets.swift` | 225 | 直接迁入 | 设置/改名/克隆/导出参数与本地 CLI 一致 | B3 |
| `.../Machines/VPhoneLaunchpadNewMachineView.swift` | 473 | 改写迁入 | preset 改为 `--variant`；固件来源沿用 `fw catalog --json` | B4 |
| `.../Machines/VPhoneLaunchpadNewMachineAdvancedView.swift` | 125 | 改写迁入 | | B4 |
| `.../Machines/VPhoneLaunchpadCreationPipeline.swift` | 518 | 改用本地 | `vm create`/`--resume`/`--restart-from` 子进程 + 检查点文件 | B4 |
| `.../HostSetup/VPhoneLaunchpadHostSetup.swift` | 370 | 改用本地 | `doctor --json` 结果 | B5 |
| `.../HostSetup/VPhoneLaunchpadHostSetupView.swift` | 138 | 改写迁入 | | B5 |
| `.../HostSetup/VPhoneLaunchpadHelperClient.swift` | 501 | 改用本地 | 只显示 `vphone-cli helper status` 输出；注册暂缓 | B5 |
| `.../CoreBundle/VPhoneLaunchpadCoreBundle.swift` | 708 | 改用本地 | 内嵌工具链状态 + `core-bundle verify` 只读结果 | B5 |
| `.../CoreBundle/VPhoneLaunchpadCoreBundleView.swift` | 358 | 改用本地 | 只读面板，安装入口禁用并写明原因 | B5 |
| `.../Application/VPhoneLaunchpadMenuBar.swift` | 106 | 直接迁入 | 含 Dock 策略 | B6 |
| `.../Application/VPhoneLaunchpadPreview.swift` | 348 | 不迁入 | DEBUG 截图夹具，依赖全部上游类型 | — |
| `.../CoreBundle/VPhoneLaunchpadArtifact.swift` | 189 | 不迁入 | GitHub Actions 产物下载与钥匙串 token；生产安装暂缓 | — |
| `.../CoreBundle/VPhoneLaunchpadDownload.swift` | 73 | 不迁入 | 同上 | — |
| `.../CoreBundle/VPhoneLaunchpadInstallView.swift` | 128 | 不迁入 | 安装进度面板；生产安装暂缓 | — |
| `.../CoreBundle/VPhoneLaunchpadLocalBundle.swift` | 178 | 不迁入 | 本地构建安装经 helper；暂缓 | — |
| `.../CoreBundle/VPhoneLaunchpadRelease.swift` | 88 | 不迁入 | 上游 GitHub 发布列表；本地不安装上游发布包 | — |
| `.../Machines/VPhoneLaunchpadPatchCatalog.swift` | 252 | 不迁入 | 上游 patch set/preset；本地五变体，T09 映射仅文档 | — |
| `.../Machines/VPhoneLaunchpadPatchSettingsView.swift` | 329 | 不迁入 | 同上 | — |
| `VPhoneLaunchpadHelper/VPhoneLaunchpadHelperAMFI.swift` | 56 | 不迁入 | 本地 AMFI 路径为 amfidont，helper 无 AMFI 动词 | — |
| `VPhoneLaunchpadHelper/VPhoneLaunchpadHelperFirmwareRequest.swift` | 150 | 不迁入 | helper 无 CFW 动词（T24 决定） | — |
| `VPhoneLaunchpadHelper/VPhoneLaunchpadHelperAuthorization.swift` | 101 | 本地已有 | `VPhoneHelperAuthorization.swift` | — |
| `VPhoneLaunchpadHelper/VPhoneLaunchpadHelperBundleInstaller.swift` | 259 | 本地已有 | `VPhoneCoreBundleStore.install` | — |
| `VPhoneLaunchpadHelper/VPhoneLaunchpadHelperCodeCheck.swift` | 71 | 本地已有 | `VPhoneCoreBundleStore.verify`/`withVerifiedExecutable` | — |
| `VPhoneLaunchpadHelper/VPhoneLaunchpadHelperListenerDelegate.swift` | 25 | 本地已有 | `VPhoneHelperService.swift` | — |
| `VPhoneLaunchpadHelper/VPhoneLaunchpadHelperService.swift` | 234 | 本地已有 | `VPhoneHelperService.swift` | — |
| `VPhoneLaunchpadHelper/main.swift` | 14 | 本地已有 | `sources/VPhoneHelperEntry/main.swift` | — |
| `VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift` | 114 | 本地已有 | `VPhoneBundleStore` | — |
| `VPhoneLaunchpadShared/VPhoneLaunchpadHelperProtocol.swift` | 87 | 本地已有 | `VPhoneHelperProtocol.swift` | — |
| `VPhoneLaunchpadShared/VPhoneLaunchpadHostPolicy.swift` | 69 | 本地已有 | `VPhoneHostSecurityPolicy.swift`（T24） | — |
| `Tests/HostPolicyTests.swift` | 68 | 本地已有 | T24 的 `DiagnosticsTests` | — |
| `.../Control/VPhoneLaunchpadControlCommands.swift` | 741 | T25 | 第 6 节 | — |
| `.../Control/VPhoneLaunchpadControlServer.swift` | 202 | T25 | 第 6 节 | — |
| `VPhoneLaunchpadShared/VPhoneLaunchpadControl.swift` | 189 | T25 | 第 6 节 | — |
| `VPhoneLaunchpadCLI/main.swift` | 213 | T25 | 第 6 节 | — |

### 2.3 汇总

| 处理方式 | 文件数 | 上游行数 |
| --- | --- | --- |
| 直接迁入 | 10 | 879 |
| 改写迁入 | 14 | 2,963 |
| 改用本地 | 5 | 2,455 |
| 本地已有（不迁入） | 10 | 1,042 |
| 不迁入 | 10 | 1,791 |
| T25 | 4 | 1,345 |
| 合计 | 53 | 10,475 |

| 批次 | 文件数 | 上游行数 |
| --- | --- | --- |
| B1 | 12 | 2,218 |
| B2 | 3 | 367 |
| B3 | 5 | 415 |
| B4 | 3 | 1,116 |
| B5 | 5 | 2,075 |
| B6 | 1 | 106 |

统计方法：上表逐行行数取自 `wc -l`；分类合计由 scratchpad `mapping_stats.py` 对映射表求和，两种合计一致（10,475）。“改用本地”的行数是上游原文件行数，本地替代代码行数会小于该值。

### 2.4 本地行数命令

`wc -l sources/VPhoneCore/VPhoneHostSecurityPolicy.swift sources/VPhoneCore/VPhoneDiagnosticChecks.swift sources/VPhoneCore/VPhoneDiagnostics.swift sources/VPhoneCore/VPhoneVMLock.swift sources/VPhoneCore/VPhoneVMRuntimeState.swift sources/VPhoneCore/VPhoneVMStopper.swift sources/VPhoneCore/VPhoneCreateRunner.swift sources/VPhoneCore/VPhoneCreateCheckpoint.swift sources/VPhoneCore/VPhoneCreateCheckpointStore.swift sources/vphone-cli/VPhoneHostControl.swift` 合计 3,438 行。

## 3. 构建方式

### 3.1 探测记录（事实）

探测包位于会话 scratchpad（`probe/`、`port60/`、`port62/`），未提交。

| 编号 | 探测 | 结果 |
| --- | --- | --- |
| E1 | tools 6.0 包，`defaultLocalization: "en"`，`executableTarget` 带 `resources: [.process("Localizable.xcstrings")]`，入口为 SwiftUI `@main struct ... : App` | `swift build` 成功。资源包 `launchpad-probe_LaunchpadProbe.bundle/Contents/Resources/` 下生成 en/ja/ko/vi/zh-Hans 五个 `.lproj/Localizable.strings`，en 另有 `Localizable.stringsdict`；zh-Hans 中 `Machines` → `虚拟机` |
| E2 | 同包加入 `InfoPlist.xcstrings`（`swift build -c release`） | 各 `.lproj` 生成 `InfoPlist.strings`，zh-Hans 含 3 条位置权限说明及 `CFBundleName`/`CFBundleDisplayName` |
| E3 | 裸可执行文件（不在 .app 内）运行 `--probe -AppleLanguages '(zh-Hans)'` | `Bundle.main.localizations` 为空；`String(localized:)` 与 `String(localized:bundle: .module)` 都返回英文 |
| E4 | 脚本组装 .app：可执行文件放 `Contents/MacOS`，`.lproj` 复制到 `Contents/Resources`，资源包复制到 `Contents/Resources/<pkg>_<target>.bundle`，Info.plist 含 `CFBundleLocalizations` | `-AppleLanguages '(zh-Hans)'` 下主 bundle 与 `.module` 查找均返回 `虚拟机`、`要停止创建虚拟机吗？`、插值 `无法启动 demo`；`(ja)` 返回 `マシン`；未指定时按系统语言 zh-Hans-CN 返回中文 |
| E5 | 生成的 `resource_bundle_accessor.swift` | 依次查找 `Bundle.main.resourceURL`、`Bundle(for:).resourceURL`、`Bundle.main.bundleURL` 下的 `<pkg>_<target>.bundle` |
| E6 | `xcrun actool <上游 AppIcon.icon> --compile ... --platform macosx --minimum-deployment-target 15.0 --app-icon AppIcon` | 生成 `Assets.car`（1.9 MB）、`AppIcon.icns`（56 KB）及 partial plist（`CFBundleIconFile`、`CFBundleIconName` = `AppIcon`） |
| E7 | 先签资源包，再 `codesign --force --sign -` 外层 app（ad hoc，无 entitlements） | `codesign --verify --strict --deep` 通过 |
| E8 | `NSWorkspace.openApplication` 启动组装的 app；另以 `Process` 直接执行 `Contents/MacOS/vphone-launchpad` | 两种方式都在 10 秒内出现名为 `vphone-launchpad` 的屏上窗口（`CGWindowListCopyWindowInfo`，不需额外权限） |
| E9 | 把主 checkout 已构建的 `.build/vphone-cli.app`（146 MB）以 `cp -cR` 放入 `Contents/Helpers/vphone-cli.app`，只重签外层 | 嵌套前后 `vphone-cli` cdhash 均为 `9daf6667d2e8ed1c0bce49f64cf2532eedd8b9f7`，`vphone-vm` 均为 `c2edf20e5e968cf9d1d0f422e62eef1fcae5a116`；外层 `--deep` 校验通过；`vphone-vm` 仍含 `com.apple.private.virtualization`；外层 app 148 MB |
| E10 | 运行嵌套 CLI：`vm list --json --library-root <空目录>`、`resources --json` | 输出 `[]`、退出 0；资源根解析为嵌套 app 的 `Contents/Resources`。未执行任何 VM 操作 |
| E11 | 上游 app + Shared 共 44 个 Swift 文件（不含 `VPhoneLaunchpadTerminal.swift`，另加 Ghostty 视图替身和 `VPhoneLaunchpadLogWriter` 副本），tools 6.2 + `.defaultIsolation(MainActor.self)` + `NonisolatedNonsendingByDefault` + `InferIsolatedConformances` | Swift 6 模式 debug 构建成功，0 个 error |
| E12 | 同样文件，tools 6.0，无默认隔离 | release 构建 0 个 error；debug 构建 1 个 error，位于 `VPhoneLaunchpadPreview.swift`（DEBUG 文件，`static var` 全局可变状态） |
| E13 | `xcodebuild -project VPhoneLaunchpad.xcodeproj -scheme VPhoneLaunchpad -configuration Release` | 从 GitHub 拉取 `libghostty-spm`、`MSDisplayLink` 后 `BUILD SUCCEEDED`；产物 17 MB，含 `Contents/Library/LaunchServices/com.vphone.launchpad.helper`、`Contents/MacOS/vphone-launchpad-cli`、`GhosttyKit_GhosttyTerminal.bundle`、五种语言的 `Localizable.strings`/`InfoPlist.strings`、`Assets.car`、`AppIcon.icns`；外层为 linker ad hoc 签名 |

### 3.2 方案比较

| 项目 | (a) SwiftPM target + Makefile 组装 | (b) 上游 Xcode 工程 + Makefile 包装 |
| --- | --- | --- |
| SwiftUI App 生命周期 | E1、E8 已验证 | E13 已验证 |
| `.xcstrings` 编译 | 编译进资源包（E1、E2）；需脚本把 `.lproj` 复制进主 bundle（E3、E4） | Xcode 直接放入主 bundle；`SWIFT_EMIT_LOC_STRINGS` 可抽取并标记 stale |
| 字符串抽取 | SwiftPM 不抽取；需本地检查脚本（第 8 节） | Xcode 抽取 |
| AppIcon | `actool` 编译 `.icon`（E6）或复用 `sources/AppIcon.icns` | Xcode 处理 |
| Info.plist / entitlements | 脚本写入；Launchpad 不需 entitlements | xcconfig + `SignLaunchpad.sh`；同样无 entitlements |
| 链接本地模块（`VPhoneCore`、`VPhoneBundleStore`） | 同一包图，直接依赖 | 需在 xcodeproj 中引用仓库根 Package.swift 作为本地包，再在 Xcode 中构建 C 目标与 vendor 子模块；未探测 |
| 上游 helper target | 不存在 | 默认构建 `com.vphone.launchpad.helper`（含 AMFI/CFW 动词），需改工程删除 |
| 第三方依赖 | 不新增 | 新增 `libghostty-spm`（二进制）、`MSDisplayLink` 远程依赖，另一份 `Package.resolved` |
| 测试 | `swift test --skip FirmwareIntegrationTests`（`scripts/run_tests.py`）自动包含新 test target | 需在 runner 中显式选择 scheme（实施计划 P8 第 1 条） |
| 签名衔接 | 同 `scripts/build.sh` 的 ad hoc 方式；嵌套 app 不重签（E9） | Xcode 不签（`CODE_SIGNING_ALLOWED = NO`），仍需脚本签名 |

### 3.3 推荐

采用方案 (a)。依据：E1–E12 覆盖了 SwiftUI 生命周期、字符串目录、图标、签名与嵌套工具链；方案 (b) 需要删除上游 helper target、增加两个远程依赖，并在 Xcode 中重新接入本地 SwiftPM 模块，且测试不在现有 runner 内。

目标布局：

- `VPhoneLaunchpadKit`（library，`sources/VPhoneLaunchpadKit/`）：子进程、行读取、命令历史、机器解码、库位置、运行状态读取、工具链定位、日志写入与跟随、创建检查点映射、诊断映射。依赖 `VPhoneCore`，只用于只读数据与类型。
- `VPhoneLaunchpad`（executableTarget，`sources/VPhoneLaunchpad/`）：SwiftUI 视图、`@main` App、`Localizable.xcstrings`、`InfoPlist.xcstrings`。product 名 `vphone-launchpad`。
- `VPhoneLaunchpadKitTests`（`tests/VPhoneLaunchpadKitTests/`）。
- Package 级 `defaultLocalization: "en"`。现有 target 无资源，不受影响（推断，B1 以 `make test`、`make build` 验证）。

Swift 版本：保留 `swift-tools-version:6.0`，Launchpad target 不使用 `defaultIsolation`，迁入代码对 UI 类型显式标注 `@MainActor`（与本地约定一致）。依据 E12：上游 44 个文件在该设置下 release 0 error，唯一 debug error 位于不迁入的 `VPhoneLaunchpadPreview.swift`。上游源码使用类型级 `nonisolated`，需要较新的编译器（推断：Swift 6.1 起）；CI `macos-26` 默认 Xcode 的版本在 B1 的 CI 日志中记录。E11 证明 tools 6.2 + 默认 MainActor 也可行；该方案需要整个 Package.swift 升级 tools 版本，不作为默认方案。

app 布局（`.build/vphone-launchpad.app`）：

```
Contents/Info.plist                      CFBundleExecutable=vphone-launchpad, LSMinimumSystemVersion=15.0, CFBundleLocalizations
Contents/MacOS/vphone-launchpad
Contents/Helpers/vphone-cli.app          已通过 check_bundle.py 的 .build/vphone-cli.app 的 APFS clone，不重签
Contents/Resources/<lang>.lproj/         Localizable.strings、InfoPlist.strings（及 en 的 stringsdict）
Contents/Resources/AppIcon.icns
Contents/Resources/embedded-toolchain.json  构建时记录的 git 短哈希、vphone-cli 与 vphone-vm 的 cdhash
```

构建入口：新增 `scripts/build_launchpad.sh` 与 Makefile 目标 `launchpad`（依赖 `bundle`）。脚本步骤：读取 `swift build -c release` 产物；校验 `.build/vphone-cli.app`（`check_bundle.py`）；`cp -cR` 嵌入；写 `embedded-toolchain.json`；复制 `.lproj`；签外层（ad hoc，无 entitlements，不加 `--deep`）；运行 `scripts/check_launchpad_bundle.py`。`make build` 在 B1 不变。

amfidont：`scripts/start_amfidont_for_vphone.sh` 以 `--path "$PROJECT_ROOT"` 前缀和 cdhash 放行（脚本第 69–78 行）。嵌套 `vphone-vm` 位于项目路径下且 cdhash 不变（E9），推断无需新的放行步骤；待 B2 真实启动验证。

窗口：Launchpad 使用 SwiftUI `Window` 场景和 sheet，不创建由 `NSWindowController` 管理的窗口。若后续加入独立 AppKit 窗口（例如分离的控制台窗口），设置 `isReleasedWhenClosed = false`，并纳入 B 批次检查。

## 4. 暂缓边界在 UI 中的处理

约束来源：9 月 30 日决定（helper 注册与生产 Core Bundle 安装暂缓）、T24（不递归 0777、不新增任意特权 command）、实施计划 P3（不允许 UI 传入任意可执行文件、不以手工替换二进制绕过校验）。

| 上游入口 | 本地处理 | 显示 |
| --- | --- | --- |
| Host Setup → Install Helper / 自动更新 helper | 不迁入，无按钮 | “特权 helper：暂缓注册”，下方显示 `vphone-cli helper status` 原文输出（只读） |
| Developer Tools 授权（`EPDeveloperTool`/`EPExecutionPolicy`） | 不迁入 | 不显示该检查；本地执行准入由 amfidont 与 `boot_host_preflight.sh` 判定 |
| Core Bundle → Install Release / Artifact / Local Build / Remove / Use / Accept | 不迁入安装与切换逻辑 | Core Bundle 面板列出存储中的版本及 `vphone-cli core-bundle verify --version` 只读结果；安装类按钮禁用，说明文字“生产 Core Bundle 安装暂缓（2026-09-30 决定）”；不提供 sudo 命令提示 |
| 当前工具链来源 | 只用内嵌工具链 | 面板第一行显示内嵌 `vphone-cli.app` 路径、签名状态、两项 cdhash 与构建哈希 |
| AMFI 放行（`allowVirtualMachine`） | 不迁入 | Host Setup 显示 `doctor` 结论；可复制文本 `make amfidont_allow_vphone`，Launchpad 不执行 |
| Install Custom Firmware / Update Guest Environment（helper root） | 不迁入 | 菜单不出现；CFW 未完成的机器显示“Resume Creation”（B4，走 `vm create --resume`） |
| `exec <任意 vphone-cli 参数>`、`guest.send/rpc` | 不迁入（第 6 节） | — |

可执行文件定位规则（B1 `VPhoneLaunchpadToolchain`）：

1. 路径固定为 `Bundle.main.bundleURL/Contents/Helpers/vphone-cli.app/Contents/MacOS/vphone-cli`。不读取环境变量、UserDefaults 或参数中的路径覆盖。
2. 对嵌套 app 内各路径组件 `lstat`，拒绝符号链接和非普通文件。
3. `SecStaticCodeCheckValidity` 严格校验嵌套 app（含嵌套代码与资源）。
4. 读取 `vphone-cli`、`vphone-vm` 的 cdhash，与外层签名封存的 `embedded-toolchain.json` 比较，不一致即拒绝。
5. 任何一步失败时，所有动作按钮禁用，面板写出失败步骤与原因。
6. 不在 Launchpad 进程中修改任何文件权限或所有者。`MachineLocations.problem` 只读检查 APFS、`MNT_IGNORE_OWNERSHIP`、所有者 UID 与可写性。

特权操作只有一条现有本地路径：`vm create` 的 CFW 阶段使用 `--root-popup`（`VPhoneProcessRunner.runWithAdminPrivileges`，系统授权对话框）。Launchpad 不处理密码，不传 `--sudo-password`。

## 5. VM 生命周期

### 5.1 启动与停止

- 启动：`vphone-cli vm launch <name> --library-root <root> [--headless]`，按上游方式分离启动（setsid、disclaim、stdin `/dev/null`、输出追加到控制台日志）。本地 `vm launch` 先运行 `boot_host_preflight.sh --assert-bootable`，在 `stage-vphoned` 锁内放置 vphoned，再以子进程启动 `vphone-vm --config ... --vphoned-bin ...`；VM 锁由 `vphone-vm` 获取（`VPhoneAppDelegate`）。Launchpad 不持有 VM 锁。
- 停止：`vphone-cli vm stop <name> --library-root <root>`。目标由 `VPhoneVMStopper` 用 `ps` + `VPhoneBootProcessLocator` + 运行记录 + 启动时间确认。Launchpad 只对自己仍持有的 `vm launch` 子进程句柄发送 SIGINT，且仅在 `vm stop` 返回后、该子进程仍未退出时执行；不对其他 PID 发信号。
- DFU 启动不在 UI 中提供；DFU 由 `vm create` 内部使用。

### 5.2 运行状态判定

事实：

- `VPhoneVMLock` 与 `VPhoneBundleGuard.withBundleLock` 以 `LOCK_EX | LOCK_NB` 获取目录 flock；`VPhoneVMLockProbe.isLockHeld` 与 `VPhoneCreateCheckpointStore.isRunLockHeld` 也以 `LOCK_EX | LOCK_NB` 短暂获取再释放。
- `vm create-status` 与 `doctor` 调用上述探测。
- `VPhoneVMStopper` 注释说明 `lsof Disk.img` 返回的是 Virtualization.framework 辅助进程，不是持有 VM 生命周期的进程。

推断：探测与真实操作同时尝试获取同一 flock 时，真实操作可能以 busy 失败。周期轮询会增加这种重叠的次数。

设计：

- 每 5 秒执行一次 `ps -axo pid=,command=`，对每台机器用 `VPhoneBootProcessLocator.parsePIDs(_:configURL:)` 找出运行进程；读取 `VPhoneVMRuntimeState.read(in:)`，`isBootOperation` 且 PID 在快照中时记录 instance ID；`operation == dfu` 显示 DFU。
- 运行记录为非 VM 生命周期操作、PID 存活且 `VPhoneProcessInfo.identity` 的启动时间不晚于记录时间时，显示 busy（操作名），仅作提示；实际拒绝由 CLI 持锁时给出。
- Launchpad 不调用 `VPhoneVMLockProbe`、`isRunLockHeld`、`lsof`，周期刷新不调用 `vm create-status` 或 `doctor`。

### 5.3 创建流程

| 上游 UI 步骤 | 本地 `vm create` |
| --- | --- |
| `create`（`vm new` + `vm config --network`） | 检查点之前的 `vm new`；失败且无检查点时 CLI 删除 bundle。`vm create` 无 `--cpu`/`--memory`/`--network` 选项，B4 只提供磁盘大小；CPU、内存、网络在创建完成后由设置面板修改（B3） |
| `prepare` | `prepare` |
| `patch`（`fw set-patches` + `fw patch --preset`） | `patch`，由 `--variant regular|dev|jb|exp` 决定 |
| `bootDFU`、`waitDFU`、`restore`、`stopDFU` | `restore`（内部完成 DFU 启动、探测、恢复、停止；`--restore-backend` 默认 python） |
| `installCFW`（helper root） | `cfw`（`--root-popup`）；`less` 为 `not_applicable` |
| `firstBoot` | `first_boot` |
| — | `jb_finalize`（jb/exp；其他变体 `not_applicable`） |
| — | `verification` |

- 参数：`vm create <name> --library-root <root> --variant <v> --iphone-source <s> --cloudos-source <s> --disk-size <n> --root-popup [--keep-artifacts] [--frida] [--spoof-build <id>] [--force-dsc-maxslide]`。不传 `--sudo-password`、`--interactive`。两个固件来源必须由 UI 给出：`VPhoneFirmwareSelection.resolve` 在缺省时会交互提示，而子进程 stdin 为 `/dev/null`。
- `less` 变体在 UI 中禁用并说明原因：`vm create` 帮助写明 less 需要整个 create 以 root 运行。
- `--prepare-backend native`、`--restore-backend native` 在 B4 不提供（CLI 帮助标注 experimental）。
- 进度：子进程存活期间每秒调用 `VPhoneCreateCheckpointStore.load(bundleURL:)`（不取锁，写入为临时文件 + rename），显示 7 个阶段的状态和 `overallStatus`。`unverified`、`completed_unverified`、`recovery_required` 按原值显示，不显示为通过。子进程结束后调用一次 `vm create-status --json` 取 `live` 与恢复建议。
- 重试：失败或中断后提供 `vm create --resume <name>`；用户选择阶段时加 `--restart-from <stage>`；CLI 报告工具变化时，弹窗列出检查点记录与当前可执行文件摘要，用户确认后才加 `--accept-tool-change`。
- 取消：向分离会话的进程组发送 SIGINT。事实：`VPhoneCreate*.swift` 中无 SIGINT 处理，`vm create` 进程按默认动作结束。检查点因运行锁释放而读作 `interrupted`。子进程（`fw_prepare.sh`、Python restore、DFU `vphone-vm`、osascript）是否都随之结束为待验证假设。
- 退出确认：沿用上游 `applicationShouldTerminate` 提示；确认后执行上述取消。

### 5.4 关闭管理器、多 VM 与日志隔离

- `vm launch` 分离启动，输出写文件，Launchpad 退出后 VM 继续运行（与上游一致）。重新打开后，运行状态由 5.2 的 `ps` + 运行记录重新得到；控制台视图从日志文件末尾 4 MiB 开始跟随。重新打开前已退出的 VM 不追加“exited with status”行。
- 每台 VM 是独立的 `vphone-vm` 进程，窗口与菜单属于该进程；Launchpad 不嵌入 VM 画面。
- 日志路径：`~/Library/Logs/vphone-launchpad/<name>.log`（默认库）或 `<name>-<sha256(root) 前 8 位>.log`（其他库）；创建日志加 `-create` 后缀。同名机器在不同库中日志不同。改名后旧日志保留在原文件名，新日志从新名称开始。

## 6. 控制服务器与 launchpad-cli 的边界

事实：

- 上游 `be7f061` 的动机写在提交说明中：helper 的 `SMAuthorizedClients` 只认 app，独立程序无法调用 helper，因此 CLI 只能作为运行中 app 的客户端。
- 上游有两层 socket：app 级 `control.sock`（`command`/`arguments`/`options`，流式 `output` 事件 + `done`）与各 VM 的 `vphone.sock`（`{"t":...}`）。`guest.send`、`guest.rpc` 把请求转发到 `vphone.sock`。
- 本地 `vphone-cli` 不依赖 helper 即可执行 `vm list/launch/stop/create/create-status`，各 VM 的 `vphone.sock` 由 `VPhoneHostControl` 提供，T25 正在补并发、headless 与方法转发（对应上游 `0cafa79`、`6fb0636`）。

设计：

- guest 控制只有一种协议：各 VM 的 `<bundle>/vphone.sock`（E1 约束 + T25 扩展）。Launchpad 不实现 `guest.send`、`guest.rpc` 转发。
- T26 各批次不迁入 `VPhoneLaunchpadControlServer`、`VPhoneLaunchpadControlCommands`、`VPhoneLaunchpadControl`、`VPhoneLaunchpadCLI`。远程或脚本调用使用 `vphone-cli` 管理命令和 `scripts/host_control_client.py`。
- 若 T25 决定仍提供 app 级 socket，范围限定为管理命令：`status`、`vm.list`、`vm.start`、`vm.stop`、`vm.log`、`vm.create`/resume/status，均调用 Launchpad 模型中与 UI 相同的方法；不含 `exec`、`bundle.*`、`cfw.*`、`guest.*`。socket 路径与数据目录随第 11 节第 1 项的标识决定。

## 7. 设计系统

| 项目 | 上游 | 本地要求 | 调整 |
| --- | --- | --- | --- |
| 外观 | 跟随系统浅色/深色 | 暗色 `#1a1a1a` | `NSApp.appearance = NSAppearance(named: .darkAqua)`；内容区与表格背景 `#1a1a1a`（`scrollContentBackground(.hidden)` + 背景色） |
| 字体 | 系统比例字体；个别 `.monospaced()` | SF Mono / Menlo | 场景、sheet、inspector 根视图设置 `.fontDesign(.monospaced)` |
| 边框 | 系统控件默认 | 1px `#333333` | 自绘面板（日志视图、状态区）加 1px `#333333` 描边 |
| 阴影 | 系统窗口与 sheet 阴影；无自定义阴影 | 无阴影 | 不加自定义阴影；系统绘制的窗口/sheet 阴影保留（AppKit 行为，记为剩余差异） |
| 状态色 | `VPhoneLaunchpadStatusIcon`：passed `.green`、warning `.yellow`、failed `.red`、pending `.secondary`，running 为 `.secondary` 描边转圈 | 绿/琥珀/红/蓝 | 在 `VPhoneLaunchpadTheme` 中集中定义：passed 绿、warning 琥珀、failed 红、running 蓝，pending 保持次要文字色 |
| 间距 | 系统 Form/Table 默认 | 8/12/16 | 自绘区域使用 8 基数、12 内边距、16 分区间距；系统 Form/Table 保持默认 |
| 终端 | Ghostty，浅/深两套调色板，背景 `#1e1e1e`（深色） | 等宽、暗色 | 只读 `NSTextView`，背景 `#1a1a1a`，去除 ANSI 转义；不新增 `libghostty-spm` |
| macOS 26 工具栏 | 系统 glass，`ToolbarSpacer(.fixed)` | 扁平 | 工具栏由系统绘制，保留上游 `ToolbarSpacer` 分组；记为剩余差异 |
| 图标 | `AppIcon.icon`（Icon Composer） | — | B1 复用 `sources/AppIcon.icns`；`actool` 路径已验证（E6），可替换 |

## 8. 本地化

- 语言：上游 en（源）、ja、ko、vi、zh-Hans。是否全部保留见第 11 节第 3 项。
- 迁入范围：只迁入迁入代码实际引用的 key。按正则估计（scratchpad `mapping_stats.py`，含插值占位转换），“直接/改写/改用本地”文件引用 333 个 key，仅“直接/改写”文件引用 223 个；只在不迁入文件中出现的 key 为 145 个（仅按“直接/改写”口径）；4 个 key 未被该正则识别。“改用本地”的文件会被重写，实际 key 数在 B5 确定。
- 检查脚本（B1 新增 `scripts/check_launchpad_strings.py` 与 `tests/test_launchpad_strings.py`）：
  1. 目录中每个 key 必须在 Launchpad 源码中出现（否则报 stale，对应上游 `caebc24` 的清理规则）；
  2. 源码中 `Text("…")`、`Button("…")`、`Label("…")`、`String(localized: "…")` 等位置的字面量必须在目录中（否则报 missing）；
  3. 每个 key 具备配置语言的翻译，或在目录中标记为 `needs_review`；
  4. 插值占位符数量与类型在各语言一致。
  SwiftPM 不抽取字符串；脚本为近似检查，结果以批次验收日志记录。编译器 `-emit-localized-strings` 抽取方案未探测。
- `InfoPlist.xcstrings`：迁入 `CFBundleName`、`CFBundleDisplayName`。位置权限说明是否需要取决于 disclaim 是否生效（`vphone-vm` 自负其责时，权限提示归属嵌套 `vphone-cli.app`，其 Info.plist 已有英文说明）；B2 验证后决定，未验证前一并迁入。
- 2.2.3 四个提交：

| 提交 | 内容 | 本地处理 |
| --- | --- | --- |
| `ded81cb` | `panelDidDismiss` 中下一个面板改到下一轮主 actor 再设置 | B5 迁入（Host Setup 与 Core Bundle 两个面板存在时才有队列） |
| `0b46343` | 6 个字符串补 ja/ko/vi/zh-Hans：`Install with administrator access`、`Stored in %@, owned by root and written only by the helper.`、`Install custom firmware`、`Unable to install custom firmware. Check the log for details.`、Standard/Experimental preset 两条说明 | 对应 UI 均不迁入；`Stored in %@ …` 是否在只读 Core Bundle 面板中复用在 B5 决定 |
| `f57adf6` | Core Bundle 面板“Check for Updates”移到“Install Local Build…”之前 | 两个按钮对应功能不迁入（发布检查与本地安装），不适用 |
| `caebc24` | 删除 81 条无代码引用的 key，保留 5 条仍有源码拼写的 stale | 由检查脚本规则 1 覆盖 |

## 9. 分批实施计划

每批一个提交，可独立构建与测试；每批在 `research/` 下新增记录，写明命令、结果与未验证范围。所有批次不改 helper、不写系统目录、不修改 amfidont 状态。

### B1：最小可运行 Launchpad（列表只读）

- 文件：`Package.swift`（`defaultLocalization`、`VPhoneLaunchpadKit`、`VPhoneLaunchpad`、`VPhoneLaunchpadKitTests`）；`sources/VPhoneLaunchpadKit/`（ChildProcess、LineReader、CommandLine、Machine、MachineLocations、MachineLibrary 列表部分、`VPhoneLaunchpadToolchain`、`VPhoneLaunchpadRunState`）；`sources/VPhoneLaunchpad/`（App、Model、RootView、MachinesView 列表/搜索/排序/空状态、Status、SearchField、`VPhoneLaunchpadTheme`、`Localizable.xcstrings`、`InfoPlist.xcstrings`）；`scripts/build_launchpad.sh`、`scripts/check_launchpad_bundle.py`、`scripts/check_launchpad_strings.py`；Makefile 目标 `launchpad`、`check_launchpad`；`tests/VPhoneLaunchpadKitTests/`、`tests/test_launchpad_strings.py`、`tests/test_launchpad_bundle.py`。
- 依赖：T24（已提交 `53edd90`）。不依赖 T25。
- 测试：
  - 单元：`VPhoneBundleReport` 编码 → Launchpad 解码契约（网络三种模式、无 restoreInfo、缺 `customFirmwareInstalled`）；工具链定位（缺失、符号链接、签名失效、cdhash 与清单不符、忽略环境变量）；运行状态（`ps` 文本 + 运行记录组合：运行、陈旧记录 PID 重用、busy、DFU；断言不调用 flock 探测）；库根规范化与追加库持久化（注入 UserDefaults suite）；`jsonData` 在警告行之后取 JSON；日志路径隔离。
  - 契约：`check_launchpad_strings.py` 对夹具目录的 stale/missing/占位符检查。
  - 构建：`make launchpad` + `check_launchpad_bundle.py`（布局、嵌套 cdhash 与 `.build/vphone-cli.app` 相同、`codesign --verify --strict --deep`、`.lproj` 齐全）。
  - UI 冒烟：夹具由内嵌 `vphone-cli vm new --library-root <临时库>` 生成（离线文件操作；`VPhoneLibrary.scan` 只要求有效 `config.plist`）。直接执行 `Contents/MacOS/vphone-launchpad`，环境 `VPHONE_LIBRARY_ROOT=<临时库，2 个夹具 bundle>`，参数域 `-VPhoneLaunchpadLibraryRoots '(<第二个临时库>)'`；检查屏上窗口（E8 方法）与 stdout 中 `[launchpad] listed 3 machines` 诊断行。
- 验收：`make test` 通过；`make build` 产物与校验不变；`make launchpad` 与 `check_launchpad` 通过；冒烟列出 3 台夹具机器；暗色等宽外观截图留档（人工）。
- 不验证：运行中 VM 的状态显示；启动/停止；多语言界面人工检查之外的文案正确性。

### B2：启动、停止、控制台日志与检查面板

- 文件：MachineLibrary 启停部分、Terminal（LogWriter/LogTail/只读日志视图）、ConsoleView、MachineInspector、MachinesView 启停按钮与“Start Headless”。
- 依赖：B1。
- 测试：单元用签名替身脚本（Kit 内 `@testable` 注入可执行路径的内部初始化器，产品路径不暴露）：分离启动、日志追加、父进程退出后子进程存活、SIGINT 只发给自己的子进程、退出状态行；日志跟随在文件替换/截断时重置；panic 行检测。UI 冒烟：两台替身机器同时“运行”，日志文件互不混写。
- 验收：上述测试通过；获得用户批准后，在 amfidont 已运行的宿主上完成一次真实启动、停止和关闭 Launchpad 后 VM 继续运行、重新打开后状态正确（真实 VM 验收需单独授权）。
- 不验证：未授权时的真实 VM 行为；TCC 权限提示归属（disclaim 效果）。

### B3：离线编辑与命令历史

- 文件：MachineSheets（设置、改名、克隆、导出）、Sheet、FilePanel、CommandHistoryView、CommandInfoButton、MachinesView 操作菜单、导入、删除确认。
- 依赖：B1。
- 测试：参数构造单元测试；真实 CLI 对临时库中的夹具 bundle 执行 `vm config/rename/clone/delete/export/import`（离线文件操作，不启动 VM）；运行中拒绝路径用替身锁持有者验证 CLI 报错显示。导出进度：CLI 无进度行时显示不确定进度；`VPHONE_PROGRESS=lines` 支持如需加入，作为独立 CLI 提交另行评审。
- 验收：测试通过；取消导出时删除部分文件的行为与上游一致。
- 不验证：大镜像导出耗时与空间。

### B4：新建机器与创建检查点

- 文件：NewMachineView、NewMachineAdvancedView、创建视图、`VPhoneLaunchpadCreation`（替代 `CreationPipeline`）、App 退出确认。
- 依赖：B2（日志）、B3（设置面板用于 CPU/内存/网络）。
- 测试：参数构造（不含 `--sudo-password`/`--interactive`，非 less 含 `--root-popup`，less 禁用）；检查点 JSON 夹具（由 `VPhoneCreateCheckpoint` 编码生成）到 UI 状态映射，含 `unverified`、`not_applicable`、`recovery_required`；resume/restart-from/accept-tool-change 参数与确认流程；取消向进程组发送 SIGINT（替身进程组）；周期刷新不调用 `create-status`。
- 验收：测试通过。真实创建、取消与 resume 需固件、网络与 VM 运行，按用户授权单独执行。
- 不验证：未授权时的真实创建；取消后子进程清理（5.3 待验证假设）。

### B5：宿主检查、helper 状态与 Core Bundle 只读面板

- 文件：HostSetup（`doctor --json` 映射）、HostSetupView、Core Bundle 只读模型与视图、helper 状态显示、Model 面板队列（`ded81cb`）。
- 依赖：B1。
- 测试：`vphone.diagnostics` v1 夹具到检查行映射；面板队列顺序（下一面板在下一轮主 actor 设置）；命令白名单测试：本批调用的 CLI 只包含 `doctor --json`、`helper status`、`core-bundle verify --version`，不出现 `helper register`、`helper install-bundle`、`core-bundle install`。
- 验收：测试通过；安装类入口禁用且显示原因（截图留档）。
- 不验证：多系统宿主上的 doctor 结果；真实 helper 连接。

### B6：菜单栏、Dock 策略与本地化收尾

- 文件：MenuBar（含 `VPhoneLaunchpadDockPolicy`）、字符串目录最终整理、2.2.3 提交处理记录。
- 依赖：B2–B5。
- 测试：菜单栏模式下关闭窗口不退出；`check_launchpad_strings.py` 全量 0 stale/0 missing；五种语言（或第 11 节决定的语言）界面人工截图。
- 验收：测试通过；T26 记录回填执行清单。
- 不验证：翻译质量（需人工审阅）。

## 10. 风险

| 风险 | 依据 | 处理 |
| --- | --- | --- |
| 锁探测与真实操作竞争 | 5.2 事实 | Launchpad 不做 flock 探测；`create-status`、`doctor` 只在用户操作或子进程结束后调用 |
| 与上游 Launchpad 同机共存冲突 | 若沿用 `com.vphone.launchpad`：UserDefaults 域、`~/Library/Logs/vphone-launchpad`、`~/Library/Application Support/vphone-launchpad` 与上游相同 | 第 11 节第 1 项 |
| 默认库根不同 | 本地 `~/.vphone/VMs`，上游 `~/.vphone/machines` | 使用 `VPhoneLibrary.defaultRoot()`；不自动加入上游目录 |
| 创建取消后残留子进程 | `vm create` 无 SIGINT 处理 | B4 用替身验证进程组信号；真实场景待授权验证 |
| `responsibility_spawnattrs_setdisclaim` 为私有符号 | 上游以 dlsym 调用，缺失时继续运行 | 保留上游做法；B2 记录 TCC 提示归属 |
| 内嵌工具链体积 | 146 MB；APFS 上 `cp -c` 为 clone（E9） | 非 APFS 卷上占用翻倍，构建脚本输出提示 |
| 编译器版本 | 类型级 `nonisolated` 需要较新编译器 | B1 在 CI 日志记录 Xcode/Swift 版本 |
| 字符串检查为近似 | SwiftPM 不抽取 | 脚本规则与测试夹具固定；人工截图补充 |
| 系统阴影与 glass 工具栏 | AppKit 绘制 | 记为剩余差异，不自绘替代 |

## 11. 待用户决定

1. Launchpad 的 bundle 标识与数据目录。选项 A：`com.vphone.launchpad`，与本地 helper 允许客户端列表一致，但与上游 Launchpad 共用 UserDefaults 域和日志/支持目录，两者不能在同一宿主共存。选项 B：本地专用标识（例如 `com.vphone.cli.launchpad`）与独立目录，需要同步修改 `VPhoneHelperConfiguration` 的客户端列表（helper 代码改动，注册仍暂缓）。影响 B1 的 Info.plist、日志路径与测试。
2. 是否迁入 `vphone-launchpad-cli` 与 app 级控制 socket。推荐不迁入（第 6 节）；若需要，由 T25 按第 6 节限定的命令集实现。该项与正在进行的 T25 需要一致。
3. 语言范围。选项 A：保留 en/ja/ko/vi/zh-Hans，本地新增字符串的 ja/ko/vi 翻译来源需指定（未翻译时回退英文并标记 `needs_review`）。选项 B：en + zh-Hans。影响 B1 起每批的字符串检查规则。
4. 是否把 Launchpad 纳入 `make build` 与 CI `bundle` 任务。推荐 B1 只提供 `make launchpad`，B6 后再决定。纳入后 `make build` 产物与 CI 时长变化。
5. B2、B4 的真实 VM 验收（启动/停止/关闭管理器后行为；真实创建、取消与 resume）需要运行 VM、下载固件并启用 amfidont，请在对应批次单独授权。

### 11.1 用户决定（2026-10-01）

1. 采用本地专用 bundle 标识与独立数据目录，B1 同步修改 `VPhoneHelperConfiguration` 允许客户端列表；helper 注册仍暂缓。
2. 不迁入 `vphone-launchpad-cli` 与 app 级控制 socket；guest 控制只经各 VM 的 `vphone.sock`。
3. 语言范围为 en 与 zh-Hans。
4. B1 只提供 `make launchpad`；是否并入 `make build` 与 CI bundle 任务在 B6 后决定。
5. B2、B4 的真实 VM 验收在对应批次单独授权。

## 12. 事实、推断与待验证汇总

事实：第 1 节、第 3.1 节 E1–E13、5.2 与 5.3 中标注为事实的内容，均有命令或源码位置。

推断：

- Package 级 `defaultLocalization` 不影响现有无资源 target。
- 嵌套 `vphone-vm` 由现有 amfidont `--path` 前缀放行覆盖。
- 周期 flock 探测会增加真实操作 busy 失败的次数。
- 类型级 `nonisolated` 需要 Swift 6.1 及以上编译器。

待验证假设：

- `vm create` 收到进程组 SIGINT 后，`fw_prepare.sh`、Python restore、DFU `vphone-vm`、osascript 子进程全部结束。
- disclaim 生效后，VM 的位置权限提示归属 `vphone-vm` 所在的嵌套 app。
- 直接执行 app 可执行文件的冒烟方式在 CI `macos-26` 无图形会话时可用（本机有图形会话，E8 已通过）。

## 13. 探测命令摘录

全部在会话 scratchpad 中执行，产物未入库。

```
# E1/E2：SwiftPM 资源与字符串目录
swift build                      # probe/，tools 6.0，defaultLocalization en
swift build -c release           # 加入 InfoPlist.xcstrings 后
find .build/debug/launchpad-probe_LaunchpadProbe.bundle -name '*.strings*'
# E4：组装、语言查找
zsh probe/assemble.sh
out/vphone-launchpad.app/Contents/MacOS/vphone-launchpad --probe -AppleLanguages '(zh-Hans)'
# E6：图标
xcrun actool <upstream>/VPhoneLaunchpad/AppIcon.icon --compile out/icon --platform macosx \
  --minimum-deployment-target 15.0 --app-icon AppIcon --output-partial-info-plist out/icon/partial.plist
# E8：窗口
out/window_check <app>; out/exec_window_check <app>/Contents/MacOS/vphone-launchpad
# E9/E10：嵌套工具链
zsh probe/nest.sh
<app>/Contents/Helpers/vphone-cli.app/Contents/MacOS/vphone-cli vm list --json --library-root <empty>
# E11/E12：上游源码在两种并发设置下编译
(cd port62 && swift build); (cd port60 && swift build -c release); (cd port60 && swift build)
# E13：上游 Xcode 工程
xcodebuild -project VPhoneLaunchpad.xcodeproj -scheme VPhoneLaunchpad -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath ../../xcdd build
```
