# 上游与当前工作分支差异评估（2026-09-24）

评估结论：上游最近的主要变化有五项：

- 原生化固件准备、恢复和 CFW 安装；
- 拆分出持有私有权限的 VM 进程；
- 客户机控制改为 HTTP/WebSocket；
- 公开流程收敛为 JB，默认客户机环境不再安装 bootstrap、SSH、VNC 和 tweak 组件；
- 版本升到 2.0.0，只启动 `schemaVersion=2` 的 VM。

本仓库保留多变体、研究用补丁基础设施和较完整的自动化状态管理。整合需要同时处理四类工作：架构迁移、协议迁移、VM 格式迁移和本地功能保留。

本报告中的“上游没有”，指固定上游版本中未发现对应实现，不表示上游删除过本仓库的独有功能。直接比较两个分支时显示的删除，不能全部解释为上游删除。

修订记录：初版以上游 `3f70114` 为基线。同日复核后改为以 `4bab3b7` 为基线，修正 §3.1、§3.3、§3.8 和 §4 的表述，并补充 §3.9 以及 §3.5、§4、§5、§6 中遗漏的内容。

## 1. 比较基线与证据范围

| 对象 | 版本 / 结果 |
| --- | --- |
| 本仓库比较分支 | `codex/autophone-location-multivm-integration`，不是本地 `main` |
| 本仓库比较版本 | `6288a02ad295889d31b4bdd024fa85bcbd0f22f1`，2026-09-22。其后的提交只增加或修改本报告，`sources`、`scripts`、`tests` 无变化 |
| 上游 `Lakr233/vphone-cli` 的 `main` | `4bab3b76b3a2b6c5d68fecd292348176dbc18c4e`，2026-09-24 |
| 共同祖先 | `87f796c62a7cb385cd37afce121f6e222d83e5b5`，2026-09-01 |
| 上游独有提交 | 114 个，其中 106 个非合并提交 |
| 本仓库独有提交 | 178 个；提交数不等于独有功能数 |
| 上游相对共同祖先的文本统计 | 649 个文件，新增 87,348 行、删除 26,915 行 |
| 两个最终目录树的文本统计 | 900 个文件，新增 90,244 行、删除 98,285 行；方向为本仓库 → 上游 |

统计排除仓库根目录 `TODO.md`。上游独有提交中，109 个集中在 9 月 22—24 日。按 Git 默认相似度检测，上游相对共同祖先有 207 个文件被标为重命名；这个计数不能覆盖所有拆分、改名和格式化。

初版基线 `3f70114` 之后，上游又有 9 个提交：

- `7155bbd`：要求 v2 VM manifest，版本号升到 2.0.0，见 §3.9；
- `e3ad481`：移除 `insert_dylib` 子模块，改为测试夹具；
- 其余 7 个为目录改名、文档和构建信息调整。

方法：

1. 将上游提交取到临时仓库，计算共同祖先、提交集合和重命名差异。
2. 核对关键入口和实现，以及双方的研究记录。
3. 按章节分四个方向逐项检查源码；关键结论复核到具体行。

没有修改当前分支、remote 或生产代码，也没有运行上游构建、测试、固件补丁、恢复或 VM。以下运行结果均来自既有研究记录，不是本次重测的结果。标为“待验证假设”的内容只有静态阅读依据。

固定版本入口：[上游代码][upstream]、[本仓库比较版本][local]。

## 2. 功能变化总表

| 模块 | 本仓库当前实现 | 上游当前变化 | 功能影响与整合判断 |
| --- | --- | --- | --- |
| 命令与进程 | 主 CLI 同时包含 VM/UI 和固件编排 | `vphone-cli` 与持有私有 entitlements 的 `vphone-vm` 分离，VM/UI 放入 `VPhoneVirtualMachineKit` | VM 签名权限不满足时，普通 CLI 更容易运行。本地的进程识别、停止、锁和诊断必须适配新进程 |
| VM 格式 | manifest 无版本字段 | 2.0.0 只加载 `schemaVersion=2` 的 manifest，不提供原地升级 | 本地已有 VM 在上游代码下无法启动，必须重建或另行迁移 |
| 固件变体 | regular/dev/jb/exp/less，默认 regular | 公开的创建、补丁和安装入口固定为 JB；pipeline 内部仍保留五个变体的代码分支 | 不能直接替换本地多变体入口；内部代码仍在，不等于仍公开支持 |
| 恢复后环境 | JB 安装 Procursus 等环境，执行 first-boot finalization | 安装必要系统修改和 vphoned/icli，不安装 package manager、SSH、VNC、bootstrap | 原先依赖 SSH、Sileo、tweak 自动部署的工作流，必须显式恢复或另行安装 |
| 固件准备 | Shell/Python 编排与本地缓存工具 | Swift 原生 IPSW 缓存、解包、混合 manifest，暂存目录完成后再发布 | 减少外部依赖；需保留本地准备阶段的检查点、恢复和占用保护 |
| PCC GPU | 使用现有 CFW 资源安装 GPU 组件 | 从所选 cloudOS 的实际恢复结果中提取 GPU bundle，并合入随应用构建的 compiler plugin | 默认 `fw prepare` 增加一次临时 PCC VM 恢复，影响耗时、磁盘、权限和网络条件 |
| DFU/TSS/Restore | `pymobiledevice3_bridge.py` 与 Python 运行时 | `VPhoneRestore` + 内嵌 libirecovery/idevicerestore 后端 | 恢复阶段不再依赖 Python；需要重新验证错误、超时、取消、ECID 选择和资源清理 |
| CFW 补丁 | Swift boot-chain + Python Mach-O/DSC 补丁 | Mach-O/DSC 补丁和 APFS snapshot 操作迁到 Swift | 多数是已有功能的语言迁移；需要逐项比较输入、输出、幂等和失败行为 |
| 签名、归档 | 依赖 ldid、tar/zstd 等外部工具 | `VPhoneSign`、`VPhoneArchive`、`vphone-archive` | 有利于分发；归档权限、硬链接、稀疏文件和导入保护不能仅凭能解包判定等价 |
| 客户机协议 | VSOCK 1337，长度前缀 JSON | VSOCK 1339，HTTP/WebSocket；SwiftNIO + IcliKit | 明确不兼容；新宿主不能直接控制旧 daemon，客户机需要配套升级 |
| 对外 API | 增强的宿主 Unix socket | 新增可选 TCP 代理、OpenAPI 和 Swift API 客户端，无认证层 | 第三方接入更方便；本地命令参数、状态模型和回执不能自动迁移；监听非 loopback 地址时有安全风险 |
| 自动化 | 无窗口控制、能力发现、定位所有权/持久化、相机消费回执 | 保留基础控制、定位和 1338 相机流；没有本地增强的状态机制 | 需要保留本地业务语义，并适配新传输层与客户机实现 |
| 构建与目录 | 根 Makefile、vendor、scripts/sources/tests | 根 Makefile 移除，改用 `Scripts/build.sh`；SwiftPM URL 依赖；目录名改为 PascalCase；无 git 子模块 | CI、脚本、路径、测试筛选和打包清单需要整体更新 |

## 3. 上游主要改动的具体内容

### 3.1 进程拆分与宿主权限

`8e4e75c` 将私有虚拟化 entitlements 从顶层 CLI 移到 `vphone-vm`。该提交中的库名为 `VPhoneVMKit`，当时尚未作为 library 产品公开。后续提交 `2b8e1ef` 将其改名为 `VPhoneVirtualMachineKit`。当前上游 `Package.swift` 公开该库和 `VPhoneAPIKit`。命令行通过 `VPhoneGuestLauncher` 以前台子进程方式启动 `vphone-vm`，并等待其结束。

宿主准备新增 `host preflight`、`vphone-amfi-allow` 和 GUI 密码输入辅助程序 `vphone-ask-for-permission`。后者是 SUDO_ASKPASS 程序，本身不持有权限。当前文档给出两种宿主配置，其中一种保留 SIP、放宽调试限制，再允许当前已签名的 VM 二进制。allowlist 基于 cdhash，重新构建后需要重新应用。

`8e4e75c` 最初引入的 `vphone-letmein` 在 `vm.cs_system_enforcement=1` 的宿主上不可用，已被 `vphone-amfi-allow` 替换（`5532dd0`，见上游 `Package.swift` 注释）。**这不表示可以在未经宿主配置的普通 Mac 上直接启动研究 VM。**

本地影响：

- 本地 VM 锁由启动进程自己持有。上游没有同等的锁，因此“由 `vphone-vm` 持锁”只是把本地锁迁入 `vphone-vm` 之后的设计目标，上游目前不具备这一点。
- 本地 `VPhoneBootProcessLocator` 只匹配 argv[0] 为 `vphone-cli` 的进程（`sources/VPhoneCore/VPhoneLaunchLayout.swift:131-133`）。按上游进程布局，它匹配不到 `vphone-vm`，反而会把上游 `vphone-cli boot --config` 的父进程当作 VM 进程。
- 本地诊断（`sources/VPhoneCore/VPhoneDiagnosticChecks.swift:338`）会把“`vphone-cli` 缺少私有 entitlements”报告为错误。上游有意不给 `vphone-cli` 签这些 entitlements，因此该检查在上游布局下会误报。
- 仅修改可执行文件名，不足以确认生命周期等价。

证据：[上游 Package.swift][package]、[宿主设置][host-setup]；本地 [停止控制实现](../sources/VPhoneCore/VPhoneVMStopper.swift)、[占用保护](../sources/VPhoneCore/VPhoneBundleGuard.swift)、[进程定位](../sources/VPhoneCore/VPhoneLaunchLayout.swift)。

### 3.2 原生恢复与运行依赖收敛

`853d63d`、`a779f4e`、`124217d`、`356bec6` 等提交完成以下迁移：

- `MobileRecoveryCore` 内嵌 libirecovery；`MobileRestoreCore` 内嵌 idevicerestore，并提供项目自己的 bridge。
- `VPhoneRestore` 提供恢复探测、ticket 和恢复调用，替代 Python bridge。
- `VPhoneSign` 替代宿主端的 ldid 签名调用。
- `VPhoneArchive` 替代项目中的多种外部归档程序，并区分宿主目录与客户机卷的权限/所有权策略。
- SwiftPM 从 URL 和版本解析依赖，并提交 `Package.resolved`；构建时编译并打包客户机工具。

上游仓库中已没有 `.py` 文件。Swift 代码调用的外部程序只剩 `/usr/bin`、`/usr/sbin` 下的系统工具，包括 sudo、lsof、hdiutil、codesign、aea、osascript 和 sysctl。

上游所说“运行时不需要 Homebrew/Python/Xcode”，是分发目标和静态检查的覆盖范围。从源码构建仍需要 Xcode/iPhoneOS SDK。`Scripts/check_aux.sh:30` 明确记录：还没有在完全不装 Homebrew 的机器上做过真实的工作矩阵验证，现有检查不等于跨机器的完整验收。

本地 D1/D2 的依赖锁定、托管 Python 环境和资源检查，不能照旧保留全部假设。建议保留诊断与清单机制，按新依赖结构改写检查项。运行时原生化并不意味着测试工具也要删除。

证据：[包结构][package]、[归档实现][archive]、[分发检查][checks]。

### 3.3 固件准备、GPU 来源与显示

`8900325` 把准备流程迁到 `VPhoneFirmwarePreparer`。具体行为如下：

- **下载**：IPSW 下载完成后，检查 BuildManifest 是否可读。只有服务器返回 Content-Length 时，才检查传输大小（`VPhoneIPSWCache.swift:66,86`）。
- **暂存**：解包、混合和组件准备在 VM bundle 内的 `.firmware-prepare-<UUID>` 目录中进行，完成后通过一次移动操作发布为最终的 Restore 目录（`VPhoneFirmwarePreparer.swift:60,111`）。
- **拒绝重复准备**：bundle 中已存在 `*Restore` 目录时拒绝执行（`VPhoneFirmwarePreparer.swift:41-43`）。

GPU 工作经过多轮调整，本评估以最终实现为准：

1. 默认创建一个临时 PV=3 VM，配置固定为 8 CPU、8 GB 内存、64 GB 稀疏磁盘，位于 `.pcc-restoration`（`VPhonePCCGPURecovery.swift:32-39`）。
2. 在临时 VM 中恢复所选 cloudOS，以只读方式挂载 System 卷，提取 `AppleParavirtGPUMetalIOGPUFamily.bundle`。
3. 可以用 `--gpu-driver-bundle` 提供本地 bundle，跳过这一步。

构建流程另外编译并打包 `libAppleParavirtCompilerPluginIOGPUFamily.dylib`，准备固件时合入 GPU bundle。缺少该插件归档时，准备失败（`VPhoneFirmwarePreparer.swift:93-94`）。

影响：

- GPU 驱动默认随所选 PCC 固件来源变化，减少对既有外部二进制资源的依赖。
- 上游记录显示，从 cloudOS 26.4 提取的 bundle 缺少 compiler plugin，会导致 Metal 编译服务退出和黑屏；新插件用于补全这一路径。这是上游的记录，本次未复测。
- compiler plugin 由上游按第三方代码（0xjohnnydev 的 `main.mm`）重新实现，不是 Apple 的二进制（[GPU 来源记录][gpu]）。显式传入 `--gpu-driver-bundle` 时，bundle 内已有的插件同样会被这个版本覆盖（`VPhoneFirmwarePreparer.swift:103-106`）。
- 默认准备阶段现在包含一次真实 VM 恢复，不能再视为只需文件输入的离线准备。临时 VM 需要与启动 VM 相同的 PV=3 宿主权限。每次恢复都要在线获取 TSS ticket。上游记录显示 PCC AEA 密钥 URL 在 2026-09-24 返回 HTTP 403（[补丁对照记录][patch-comparison]），因此默认路径依赖 Apple 仍在为所选 cloudOS 签名。临时 VM、TSS 网络和系统卷挂载都会增加失败点。实际耗时和空间增量未测量。
- 显式 GPU bundle 的校验包括两部分：二进制、`Info.plist`、`_CodeSignature/CodeResources` 三个文件必须存在，且 bundle 标识和 `DTPlatformVersion` 必须一致（`VPhonePCCGPUDriver.swift:51-67`）。版本相同不能单独证明来自同一 build，外部 bundle 的来源还需另行核对。
- GPU 修复不代表定位、相机或所有应用的图形功能均已通过。

代表提交：`9fc1b46`、`8758b41`、`bc79586`、`b06496e`、`f9e7abb`。证据：[准备实现][prepare]、[PCC GPU 恢复][gpu-recovery]、[GPU 驱动校验][gpu-driver]、[GPU 来源记录][gpu]。

### 3.4 JB-only 与默认客户机环境变化

`b04425d`、`f88d667`、`f4a60c4` 收敛了公开流程，并移除旧的安装和首次启动环境。当前 `patch-firmware`、`fw patch` 和创建流程都固定构造 `.jb`，且 `noBinpack: true`；`vm create` 不再提供本地的 `--variant` 选项。上游 `FirmwarePipeline.Variant` 仍保留 less/regular/dev/jb/exp 五个值及其代码分支（`FirmwarePipeline.swift:33-37`）。删除的是选择入口，以及非 JB 变体的 CFW 安装器。

需要区分两层变化：

1. **JB 系统补丁仍在。** 上游仍实施内核补丁、系统卷修改和 iOS 27 用户态适配。
2. **JB 附带的用户环境发生变化。** 当前默认流程不再部署包管理器、SSH/VNC、bootstrap、TweakLoader，也不再自动安装相机 hook。

`Siblings` 可以单独构建 CamFix、VCamCaptured、TweakLoader、VPRegister 的归档，但正常的 JB 安装不会自动安装这四个组件。GPU 的处理路径与这些可选归档无关。VPRegister 原先负责 iOS 27 的应用注册；上游对 27.x 改为施加 `patch-lsd-embedded-reg` 和 `patch-diskimagesiod`（`VPhoneCustomFirmwareInstaller.swift:150,169-170`）。

CFW 安装新增了几项前置检查：

- 可用空间必须大于 50 GiB（`VPhoneCustomFirmwareInstaller.swift:83`）；
- 需要 root 权限；
- 用 `lsof` 确认磁盘未被占用。

本地影响：

- `/cores/vphone_jb_setup.sh`、`jb_finalize` 阶段、Sileo/tweak/SSH 相关验收，以及依赖这些组件的自动化，都需要明确保留策略。
- 底层相机传输仍然存在，但不能据此推断默认新镜像中的应用可以使用虚拟摄像头。
- 本地 iOS 27 的应用注册验收需要按上游的新补丁组合重新核对。
- 本地 `vm create` 默认使用 regular 变体（`sources/vphone-cli/VPhoneVMCreateCLI.swift:71`）。直接改用上游入口后，依赖默认值的调用方会得到 JB 补丁。

证据：[公开 CLI][cli]、[CFW 安装器][installer]、[可选客户机组件][siblings]、[上游 pipeline][pipeline]；本地 [JB 安装脚本](../scripts/cfw_install_jb.sh)。

### 3.5 客户机 HTTP/WebSocket API 与 icli

这是最明确的协议兼容性变化：

| 对象 | 本仓库 | 上游 |
| --- | --- | --- |
| 普通客户机控制 | VSOCK 1337，长度前缀 JSON | VSOCK 1339，HTTP/1.1 与 WebSocket |
| 客户机实现 | Objective-C daemon 与项目内命令 handler | SwiftNIO daemon、IcliKit 0.6.1，保留 IPA/Keychain/相机等专用原生模块 |
| GUI 控制 | 本地 `VPhoneControl` | 通过 VSOCK 上的 HTTP 调用新 `VPhoneGuestControl` |
| 宿主 TCP 入口 | 以本地增强 Unix socket 为主要自动化入口 | `--api-listen host:port` 可选代理；默认不监听 TCP |
| 接口描述 | 本地 capabilities / 文档 | `/openapi.json`、`/v1/rpc`、`/v1/events` 与资源路由 |
| 通用命令扩展 | 项目内命令实现 | `icli.execute` 直接调用 icli 命令树 |
| 文件内容 | 本地命令及附带数据传输 | HTTP 二进制流；上传完成后 rename 发布 |
| 相机流 | 1338，加本地 generation/presentation/消费回执 | 1338 保留，没有本地增强的回执协议 |
| 取消与期限 | E1–E4 的期限、取消和迟到响应处理 | 无取消方法；宿主客户端 socket 超时 120 s，`icli.execute` 上限 120 s；WebSocket 响应按 id 关联，可乱序返回 |

新 API 提供设备状态、应用、输入、定位、剪贴板、文件、Keychain、Developer Mode、settings 和 accessibility tree 等操作。WebSocket 响应按 id 关联，并附带状态/操作事件。JSON 消息上限为 1 MiB，文件内容走单独的二进制通道。

**旧 daemon 无法直接兼容。** 上游宿主不回退到 1337：它先探测 `/v1/health`，只接受 `api_version == 1`（`VPhoneGuestControl.swift:74-77`）。客户机 daemon 的更新也走 HTTP：先上传 `vphoned.next`，再调用 `agent.apply_update`（`VPhoneGuestControl.swift:88-89`）。上游文档说明这次不兼容是有意设计。

迁移路径的候选方案（待验证假设）：本地旧 daemon 启动时，会执行 `/var/root/Library/Caches/vphoned` 中缓存的二进制（`scripts/vphoned/vphoned.m:640-645`）。上游新 daemon 从该缓存路径启动时，会跳过自身的 bootstrap，直接绑定 1339。因此，理论上可以通过现有的 1337 更新握手推送新 daemon，一次完成协议切换。这条路径有三个未解决的问题：

- `/usr/bin/icli`、Swift 运行时依赖和 launchd plist 需要另行安装；
- `less` 变体不执行缓存中的二进制；
- 未实测。

另一个候选方案是在新镜像中直接安装配套 daemon。

宿主原有的 `vphone.sock` 并未完全消失。上游仍有 `VPhoneHostAutomationServer`，但有以下限制：

- 命令只有 ping、screenshot、tap、swipe、key、type；
- 只在图形界面分支中创建（`VPhoneVirtualMachineAppDelegate.swift:111`），headless 模式下没有 Unix socket，只能用 `--api-listen`；
- 没有 `getpeereid` 或权限校验。本地对 socket 调用方做同用户校验（`sources/vphone-cli/VPhoneHostControl.swift:171`）。

本地的能力发现、shell、文件、应用、定位源和相机命令，不能继续原样调用。

上游文档说明新 API 暂无认证层。如果使用非 loopback 地址监听，以下能力会在无认证的情况下暴露给网络：

- `PUT /v1/files/content`：以 root 写入任意客户机路径；
- `icli.execute`：执行完整的 icli 命令树；
- `agent.apply_update`：上传二进制，并以 root 替换 daemon 后执行。

非 loopback 部署必须在部署层提供访问控制。

上游已有的组件可以减少本地自研的范围：`VPhoneAPIKit`（含 WebSocket 客户端）、`/openapi.json`、`icli.execute` 和流式文件传输，能覆盖本地的文件、应用和 shell 命令。本地需要保留的，主要是 E1–E4 的期限、取消和迟到响应语义，以及定位所有权和相机回执。

代表提交：`11f9dc4`、`c8d155e`、`8eecc0d`。证据：[API 合约][api]、[宿主基本自动化入口][automation]、[宿主客户机控制][guest-control]、[客户机命令实现][guest-api]；本地 [E1 合约](host_control_protocol_e1_2026-09-11.md)、[E2 生命周期](host_control_e2_2026-09-12.md)。

### 3.6 内核与 CFW 补丁：新增行为和迁移需要分别判断

上游新增的大量 Swift 文件来自 Python 移植：8 个 DSC patcher（`85ebd7b`）、6 个 Mach-O patcher（`78cbeea`），以及签名、daemon plist、dylib 注入和 DeviceTree 等操作。本仓库对这些功能已有 Python 或 Swift 实现，不能按新增文件数计为新增补丁数。

上游 FirmwarePatcher 目录下的提交大多是移植、改名或重构。涉及补丁行为的有两个：

- `05b4181`：新增 cloudOS 26.4 `vm_map_protect` 的 BIC/CMP/CCMP 形态（Shape C）匹配。**本仓库已在 2026-09-09 实现了针对同一分支门控的修正。**
- `8c2cf10`：`patchPostValidationAdditional` 在同一站点已被基础层第 9 项修改时，改为识别为已施加，不再输出“找到 0 个站点”的错误日志。补丁目标和总数（164）不变。该提交还有一处非补丁修改：把 `fw_prepare.sh` 的 `cp -R` 改为 `cp -Rc`（APFS clone）。按提交记录，这样可以省去 iPhone 恢复目录约 11.5 GB 的重复写入。本地 `scripts/fw_prepare.sh:411` 仍是 `cp -R`。

| 比较项 | 本仓库 | 上游 |
| --- | --- | --- |
| 26.4 gate 定位 | 从主函数的 `ADRP + ADD + PACIA + STR` 恢复认证回调，在回调内验证门控与回写 | Shape A 失败后扫描代码范围，按指令序列和唯一候选定位 Shape C |
| 研究记录目标 | `kernelcache.research.vphone600`，cloudOS 26.4 / `23E5207q`，VA `0xfffffe0008dcaea0` | 同一 kernel/build 的记录指向同一 VA |
| 修改目标 | 把条件分支改为指向相同目标的无条件分支 | 相同 |
| 已补丁输入 | 接受 `b.ne` 或 `b`，后者按已施加处理（幂等） | Shape C 只接受 `b.ne`，不能识别已补丁的 kernel |
| COW WRITE mask | 保留，不恢复已停用的 Shape B | 同样保持 Shape B 停用 |
| 本次验证范围 | 核对代码与既有研究记录 | 核对代码与既有研究记录 |

不建议用上游扫描器覆盖本地算法。应先对相同哈希的输入，比较两边的候选、修改地址、指令和输出，再判断是否需要增加兼容分支。地址只用于证据对照，不应写入补丁逻辑。

DSC 补丁的幂等处理同样存在差异。上游 Swift 版能识别已补丁的 prologue，并按成功处理。本地 `scripts/patchers/cfw_patch_camera_dsc.py:111-114` 要求 prologue 必须是 `pacibsp`，否则报错（除非加 `--force`），因此对已补丁的输入会失败。本地的 maxslide、hv_vmm_dsc 和 dsc_codesign 已有幂等处理。

上游 `6d5ce7d` 记录了 26.4 用户态 + cloudOS 26.4 的启动情况，以及 SpringBoard、Safari、Sileo 的观察结果，但明确说明没有专门验证 debugger attach 和 tweak RWX 写入。这条记录早于当前移除默认 bootstrap 的流程，不能作为当前默认镜像包含 Sileo 的证据。

本仓库的 `PatchOutcome`、必需补丁检查、`--ablate`、事务恢复和实验记录，在上游当前 pipeline 中没有对应实现。上游 `patchAll()` 按组件写回；`patchData()` 只检查发现的记录是否非空。这个条件不等价于本地“每个必需步骤都已满足”的约束。

证据：[本地 26.4 重新定位记录](c3_kernel_retarget_2026-09-09.md)、[本地匹配器](../sources/FirmwarePatcher/Kernel/JBPatches/KernelJBPatchVmProtect.swift)、[上游匹配器][vmprotect]、[上游 pipeline][pipeline]、本地 [相机 DSC 补丁](../scripts/patchers/cfw_patch_camera_dsc.py)。

### 3.7 固件目录、创建验收和界面

上游新增了两个配对目录条目：iOS 26.6.2 `23G90`，以及 iOS 27.0 `24A435`（目录中标为 RC）。本地 `VPhoneFirmwareCatalog` 还没有这两个条目。上游目录没有删除本地已有的条目。新增目录条目本身不能证明本地全部变体可用。

上游兼容性文档记录：这两个 iPhone17,3 用户态版本各自搭配 cloudOS 26.4 `23E5207q`，在 PR #486 的范围内到达锁屏，并响应 vphoned ping；26.6.2 有一次完整的全新 `vm create` 成功记录。当前创建流程会实际探测 daemon（上限 300 s），验证启动结束后停止 VM 并返回。

兼容性文档还把早期组合归为研究历史，不再作为当前的支持矩阵，包括 iOS 18.6.2、26.0–26.6.1、27 beta，以及 cloudOS 26.1/26.3。因此，版本出现在目录中不再等于受支持。

限制：PR #486 的记录不能覆盖其后才合入的 HTTP daemon、最新 GPU compiler plugin 和 v2 VM 格式。当前 tip 下的完整组合仍需要验收。

上游 `vm create` 的其他行为：

- 目标 bundle 已存在时直接拒绝；
- 在嵌套虚拟化的宿主上直接失败；
- 非交互会话需要 `--root-popup`、`--sudo-password` 或无密码 sudo；
- 安装完成后默认删除 Restore 目录，用 `--keep-artifacts` 可以保留。

`--sudo-password` 仍然通过临时 askpass 脚本和环境变量 `SUDO_PASSWORD` 传递密码（`VPhoneVirtualMachineCreator.swift:125-127`），与 `vphone-ask-for-permission` 要替代的方式并存。

GUI 中的文件、应用、Keychain 浏览器、录屏、菜单、位置预设/回放等主体功能仍在，主要变化是目录/类型拆分，以及接入新的 guest control。没有证据表明这些 GUI 功能是本次新增的。本地的手势串行化、整次手势固定路由和事件日志需要单独保留，不能只按窗口源码的重命名进行迁移。

证据：[上游兼容性记录][compatibility]、[创建流程][creator]、[界面和运行接线][app-delegate]。

### 3.8 目录、构建与测试

- **目录改名**：`sources` → `Sources`，`scripts` → `Scripts`，`tests` → `Tests`，`docs` → `Documents`，`research` → `Research`，`Siblings/gpu` → `Siblings/GraphicLoader`，另有多轮模块、文件和类型改名。Swift 格式化与文件拆分使文本差异明显增加。
- **构建入口**：根 Makefile 已移除，当前构建入口为 `zsh Scripts/build.sh`。上游根 README 和 `Documents/README*.md` 中已没有 `make` 命令。`make build`、`make amfi_allow` 只残留在 `Research/` 下的历史研究文档中，例如 `Research/Host/host_binary_split.md`、`Research/Restore/native_restore_architecture.md`，这些不能作为当前命令的依据。
- **依赖**：SwiftPM URL 依赖替换了部分 vendor 子模块，上游已删除 `.gitmodules`。libirecovery/idevicerestore 的 C 源码并入工程，这也贡献了大量新增行数。
- **测试文件数**：上游新增了归档、签名、恢复等 Swift 测试。按 `Tests/` 下的 `.swift` 文件统计，上游 63 个（FirmwarePatcher 25、Core 22、Restore 6、Archive 5、Sign 5），本地 57 个。本地另有 29 个 `.py`、2 个 `.sh`、3 个 `.m` 测试。这些是文件数，不能用来比较覆盖率。
- **验收工具**：上游没有本地的 F1/F2/F3 Python 验收和性能工具，也没有本地针对创建恢复、诊断、位置状态、固件事务的专用测试。不能把“去掉 Python 运行依赖”扩大理解为这些验收不再需要。
- **CI**：上游只有 `release.yml`，只在 release 发布时触发，内容是构建、`codesign --verify` 和 `check_aux.sh`，不执行 `swift test`。上游没有 push/PR 触发的回归。本地 `checks.yml`（push/PR 触发）和 `firmware-checks.yml`（自托管 runner）需要在整合时明确迁移，避免最后只剩打包成功这一个信号。

证据：[构建脚本][build]、[上游 release workflow][release]。

### 3.9 VM 格式 v2 与 2.0.0

`7155bbd` 把应用版本升到 2.0.0，并给 manifest 增加 `schemaVersion`：

- 加载 manifest 时，先检查 `schemaVersion == 2`，不满足则抛出 `unsupportedSchema`（`VPhoneVirtualMachineManifest.swift:255-258`）；
- 再检查运行中的程序版本主号是否为 2。未打包的 `swift build` 产物视为 2.0.0（`VPhoneVirtualMachineManifest.swift:38,54`）；
- `vm write-manifest` 拒绝把已有的旧 VM 改写为 v2（`VPhoneVirtualMachineCLI.swift:77`）；
- 库扫描会跳过不兼容的 bundle；不指定名称启动时，报 “cannot launch” 并给出原因（`VPhoneVirtualMachineLaunchCLI.swift:35`）。

上游 README 和兼容性文档写明：旧版本创建的 VM 必须用 `vm create` 重建，没有原地升级。

本地影响：本地 `VPhoneVirtualMachineManifest` 没有 `schemaVersion` 字段。整合上游代码后，本地已有的所有 VM（包括 F2 双 VM 验收使用的 bundle）都无法启动。需要在两种方案中选择：一是重建 VM，重建期间创建检查点和固件变体都要能用；二是在本地增加迁移工具，写入 `schemaVersion`，并核对 v2 格式的其他字段和目录布局是否一致。第二种方案需要先确认 v2 格式除版本标记外，是否还有其他布局变化；本次只核对了版本标记相关代码。

证据：[上游 manifest][manifest]、[上游兼容性记录][compatibility]。

## 4. 本地必须保留或显式迁移的功能

| 功能 | 本地证据 | 上游差异与风险 |
| --- | --- | --- |
| 已有 VM bundle | 本地 manifest 无 `schemaVersion` | 上游 2.0.0 拒绝加载，没有原地升级；需要重建或自行迁移 |
| 多变体与 less | `VPhoneVMCreateCLI`（默认 regular）、`FirmwarePipeline`、各 CFW 脚本 | 上游 pipeline 仍保留五个变体的代码，但公开入口和 CFW 安装器只支持 JB；EXP 身份修改、regular/dev/less 的入口和安装脚本不能在覆盖时丢失；默认变体会从 regular 变为 JB |
| 创建检查点 | `VPhoneCreateRunner`、`VPhoneCreateCheckpointStore`、`--resume`、`--restart-from`、`create-status` | 上游 creator 是顺序流程，目标 bundle 已存在时直接拒绝；按静态阅读，失败后不清理已创建的 bundle，同名重跑前必须手动删除；没有同等的检查点续跑 |
| VM 与库排他锁 | `VPhoneVMLock`、`VPhoneLibraryLock`、`VPhoneBundleGuard` | 上游 Sources 中未发现 flock 类保护；只有 CFW 安装和 stop 用 `lsof` 检查占用；`launch`、`delete`（直接 `removeItem`）、`rename`、`clone`、`export` 都不检查 VM 是否在运行 |
| 停止身份校验 | `VPhoneVMStopper` 用 PID+启动时间确认目标，并确认进程退出和锁释放 | 上游按 `lsof Disk.img` 得到的 PID 先发 SIGINT，超时后发 SIGKILL。本地注释记录 `Disk.img` 由 Virtualization.framework 辅助进程打开，因此上游的信号可能发给辅助进程而不是 `vphone-vm`（待验证假设） |
| 必需补丁与消融 | `PatchOutcome`、`PatchRequirement`、结构化执行、`--ablate` | 上游主要返回 PatchRecord，组件级的非空检查不能替代本地的必需性约束 |
| 固件事务与实验记录 | `FirmwareTransaction`、`PatchExperimentRecorder`、`fw record` | 上游逐组件保存，没有同等的中断恢复和记录接口 |
| 统一诊断 | `doctor`、类别/代码/退出状态及脱敏 | 上游 `host preflight` 主要检查宿主的启动条件，不能替代 VM/补丁/创建状态诊断；本地 entitlements 检查需要按新进程布局调整 |
| 宿主命令生命周期 | E1–E4、能力发现、期限、取消、迟到响应、同用户 socket 约束 | 新 HTTP 传输没有取消方法，只有固定 120 s 超时；上游 `vphone.sock` 没有同用户校验 |
| 位置源所有权 | `VPhoneSystemLocationController` 的 owner/generation/sequence、持久化、暂停恢复及超时策略 | 上游只有基础的设置/清除/读取和 GUI 回放，没有同等的源控制器；本地脚本需要适配 |
| 相机回执 | generation、presentation_id、客户机发布与消费状态 | 上游保留基础帧流，没有本地的增强回执，也不默认安装 hook；应用级验证需要重做 |
| 输入一致性 | `VPhoneTouchRoute` 与手势串行化、间隔控制、事件日志 | 上游把客户机输入调用串行执行，但不串行化整个手势：路由按单个事件决定，没有按手势或连接代际绑定；注入的 tap/swipe 仍用 `asyncAfter` 调度。上游每个请求建一个 HTTP 连接，没有与本地 `connectionAttemptToken` 对应的机制，迁移时需要基于 health 探测状态重建会话标识。iOS 26 及以上，GUI 走 VZ 宿主路径，而 API 的 `input.touch` 始终由客户机 daemon 注入 |
| 系统验收 | F1 支持矩阵、F2 双 VM、F3 延迟/资源/磁盘统计 | 上游的归档/签名等测试不能替代这些应用和并发行为证据；上游 CI 不运行测试 |

上表不表示“所有本地功能都已全部实机通过”。每项的运行证据以现有研究文档中记录的版本、场景和限制为准。

## 5. 可直接确认的改进与整合优先级

### 第一阶段：小范围修正和事实同步

1. **修复本地导入缺陷。** 本地 `sources/VPhoneCore/VPhoneBundleOps.swift:391` 在库锁内把解包结果移入库中的最终目录，`:393` 在锁外调用 `VPhoneBundle.load`。`:365` 的 `defer` 只清理暂存目录。因此，manifest 无效的归档会留在库中的最终目录，占用该名称，且不会被清理。上游 `b86dcaf` 的做法是先在暂存目录内完成 `VPhoneBundle.load`，验证通过后再移入库（`Sources/VPhoneArchive/VPhoneBundleTransfer.swift`）。修复时保留本地的库锁，只把验证前移，并补充一个无效 manifest 的回归测试。
2. 补充两个精确的固件配对条目，同时保持本地兼容性证据的分级。
3. 核对 Swift DSC 移植中对已补丁形态的识别，与本地 Python 的幂等处理对比，只吸收本地缺失的行为。已确认一处差异：`cfw_patch_camera_dsc.py` 不能识别已补丁的输入。
4. 对 `vm_map_protect` 用相同输入做对照，不重复新增同一补丁。如果需要吸收上游的扫描逻辑，应保留本地对已补丁 `b` 的幂等识别。
5. 把本地 `scripts/fw_prepare.sh:411` 的 `cp -R` 改为 `cp -Rc`（上游 `8c2cf10`）。
6. 决定 VM 格式迁移方案（见 §3.9），并在后续阶段开始前固定下来。

### 第二阶段：原生基础模块

迁入 VPhoneSign、VPhoneArchive 和原生恢复后端，同时保留本地的锁、停止身份校验、诊断和创建检查点。创建阶段的 backend 可以替换，但阶段合约和失败记录应继续保留。

进入真实恢复之前，先验证归档元数据、签名、恢复 probe/ticket 和错误路径。默认的 GPU 临时恢复、最终 compiler plugin，以及它们对宿主权限、网络和磁盘的要求，是这一阶段的独立验收项。

### 第三阶段：API 与客户机协议

把 HTTP/WebSocket 作为独立的迁移项。有两种方案可以比较：

- **A：保留本地 Unix socket 的对外合约**，在其下对接新的 guest API；
- **B：基于 `VPhoneAPIKit` 做一层宿主适配**，复用上游的 API 客户端、OpenAPI、`icli.execute` 和流式文件传输，本地只实现 E1–E4 的期限、取消和迟到响应语义，以及定位所有权和相机回执。

方案 B 需要自研的范围较小，但需要确认上游 API 的超时和乱序响应能否承载 E1–E4 语义。

旧客户机的升级路径需要在两种方式中选择：一是 §3.5 所述的缓存迁移（待验证假设），二是配套安装新镜像。定位所有权、相机回执和取消语义必须同时映射到新 guest API，避免出现传输可用但业务状态缺失的情况。

如果启用 `--api-listen`，默认只允许 loopback。需要非 loopback 访问时，先在部署层补充认证或访问控制，再开放文件写入、`icli.execute` 和 `agent.apply_update`。

### 第四阶段：产品范围、目录与 CI

先确定继续支持哪些固件变体和附带的客户机环境，再修改 CFW 编排。目录/类型重命名可以单独提交，便于核对逻辑变化。最后统一构建命令、资源清单、测试入口和发布检查。上游 CI 不运行测试，本地的回归 workflow 需要保留。

不建议直接用最新上游目录树覆盖本仓库。保留双方历史的整合方式可行，但本次尚未模拟 merge，无法给出准确的冲突文件数和工时。建议下一步在临时仓库中做一次 `git merge --no-commit`，得到冲突清单后再评估。

## 6. 后续验收的最低范围

| 范围 | 需要确认的结果 |
| --- | --- |
| 补丁 | 相同哈希输入下的 PatchRecord、payload、必需步骤、幂等、缺失/歧义拒绝；多变体门控互不混用 |
| VM 格式 | 旧 bundle 被明确拒绝或迁移成功；迁移后启动、克隆、导入导出行为正确 |
| 创建与恢复 | 全新 create、各阶段中断续跑、失败清理、ticket/恢复超时、配套 daemon 的实际 ping |
| 导入 | manifest 无效的归档不占用库中的最终目录；库锁下的名称检查与放置保持原子 |
| 显示 | 最终 GPU 来源 + compiler plugin + HTTP daemon 组合下的锁屏、持续显示、Metal 编译和重启 |
| 生命周期 | 同 VM 互斥、双 VM 隔离、离线操作拒绝、停止目标身份和锁释放；确认 `vphone-vm` 与 Virtualization.framework 辅助进程的关系 |
| API | 旧镜像迁移、GUI/headless、文件流、断线重连、期限和迟到响应、旧脚本兼容；非 loopback 监听的访问控制 |
| 输入 | GUI 与 API 两个入口在 iOS 26 前后各自的注入路径；重连时手势不会被拆到两条路径上 |
| 位置与相机 | owner/序列/持久化、VM 重启边界、真实 CoreLocation 读数、真实帧消费和应用识别；iOS 27 应用注册 |
| 分发 | 在不装开发工具的干净宿主上做实际操作；静态依赖检查和 `--help` smoke 不能替代 |

本次完成了提交图、目录差异和关键功能的静态核对，没有产生新的固件输出或运行验收结论。

[upstream]: https://github.com/Lakr233/vphone-cli/tree/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e
[local]: https://github.com/zhaoawd/vphone-cli/tree/6288a02ad295889d31b4bdd024fa85bcbd0f22f1
[package]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Package.swift
[host-setup]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Documents/Guides/host-setup.md
[archive]: https://github.com/Lakr233/vphone-cli/tree/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneArchive
[checks]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Scripts/check_aux.sh
[prepare]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneCLI/VPhoneFirmwarePreparer.swift
[gpu-recovery]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneCLI/VPhonePCCGPURecovery.swift
[gpu-driver]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneCore/VPhonePCCGPUDriver.swift
[gpu]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Siblings/GraphicLoader/README.md
[patch-comparison]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Research/0_binary_patch_comparison.md
[cli]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneCLI/VPhoneCLI.swift
[installer]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneCLI/VPhoneCustomFirmwareInstaller.swift
[siblings]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Siblings/README.md
[api]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Research/vphoned_http_api.md
[automation]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneVirtualMachineKit/VPhoneHostAutomationServer.swift
[guest-control]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneVirtualMachineKit/GuestCommunication/VPhoneGuestControl.swift
[guest-api]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Scripts/VPhoned/Daemon/GuestAPI.swift
[vmprotect]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/FirmwarePatcher/Kernel/JailbreakPatches/Memory/KernelJailbreakPatchVmProtect.swift
[pipeline]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/FirmwarePatcher/Pipeline/FirmwarePipeline.swift
[compatibility]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Documents/Guides/compatibility.md
[creator]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneCLI/VPhoneVirtualMachineCreator.swift
[app-delegate]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneVirtualMachineKit/VPhoneVirtualMachineAppDelegate.swift
[manifest]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneCore/VPhoneVirtualMachineManifest.swift
[build]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Scripts/build.sh
[release]: https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/.github/workflows/release.yml
