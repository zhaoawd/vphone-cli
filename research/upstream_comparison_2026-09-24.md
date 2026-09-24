# 上游与当前工作分支差异评估（2026-09-24）

评估结论：上游最近的主要变化是原生化固件准备、恢复和 CFW 安装，拆分有私有权限的 VM 进程，以及将客户机控制改为 HTTP/WebSocket。与此同时，公开流程收敛为 JB，默认客户机环境不再安装 bootstrap、SSH、VNC 和 tweak 组件。本仓库则保留多变体、研究用补丁基础设施和较完整的自动化状态管理。整合需要同时处理架构迁移、协议迁移和本地功能保留。

本报告的“上游没有”指固定上游版本中未发现对应实现，不表示上游曾删除本仓库的独有功能。直接比较两个分支时显示的删除，不能全部解释为上游删除。

## 1. 比较基线与证据范围

| 对象 | 版本 / 结果 |
| --- | --- |
| 本仓库比较分支 | `codex/autophone-location-multivm-integration`，不是本地 `main` |
| 本仓库 HEAD | `6288a02ad295889d31b4bdd024fa85bcbd0f22f1`，2026-09-22 |
| 上游 `Lakr233/vphone-cli` 的 `main` | `3f7011406722576fb19bffbc8c30d8aa4c4916af`，2026-09-24 |
| 共同祖先 | `87f796c62a7cb385cd37afce121f6e222d83e5b5`，2026-09-01 |
| 上游独有提交 | 105 个，其中 97 个非合并提交 |
| 本仓库独有提交 | 178 个；提交数不等于独有功能数 |
| 上游相对共同祖先的文本统计 | 639 个文件，新增 87,056 行、删除 26,744 行 |
| 两个最终目录树的文本统计 | 890 个文件，新增 89,990 行、删除 98,152 行；方向为本仓库 → 上游 |

统计排除仓库根目录 `TODO.md`。上游新增提交中，100 个集中在 9 月 22—24 日。Git 默认相似度检测将上游相对共同祖先的 204 个文件标为重命名；该计数不能覆盖所有拆分、改名和格式化。

方法：读取上游实时 ref，将提交取到临时裸仓库，计算共同祖先、提交集合和重命名差异，再核对关键入口、实现及双方研究记录。没有修改当前分支、remote 或生产代码。没有运行上游构建、测试、固件补丁、恢复或 VM。以下运行结果均明确归属为既有研究记录，不是本次重测结果。

固定版本入口：[上游代码][upstream]、[本仓库比较版本][local]。

## 2. 功能变化总表

| 模块 | 本仓库当前实现 | 上游当前变化 | 功能影响与整合判断 |
| --- | --- | --- | --- |
| 命令与进程 | 主 CLI 同时包含 VM/UI 和固件编排 | `vphone-cli` 与持有私有 entitlements 的 `vphone-vm` 分离，VM/UI 放入 `VPhoneVirtualMachineKit` | 改善普通 CLI 在 VM 签名权限不满足时的可运行性；本地进程识别、停止、锁和诊断必须适配新进程 |
| 固件变体 | regular/dev/jb/exp/less | 公开创建、补丁、安装流程固定为 JB | 不能直接替换本地多变体入口；内部仍有其他变体代码，不等于公开支持仍保留 |
| 恢复后环境 | JB 安装 Procursus 等环境，执行 first-boot finalization | 安装必要系统修改和 vphoned/icli，不安装 package manager、SSH、VNC、bootstrap | 原先依赖 SSH、Sileo、tweak 自动部署的工作流必须显式恢复或另行安装 |
| 固件准备 | Shell/Python 编排与本地缓存工具 | Swift 原生 IPSW 缓存、解包、混合 manifest、暂存目录发布 | 减少外部依赖；需保留本地准备阶段的检查点、恢复和占用保护 |
| PCC GPU | 使用现有 CFW 资源安装 GPU 组件 | 从所选 cloudOS 的真实恢复结果提取 GPU bundle，并合并随应用构建的 compiler plugin | 默认 `fw prepare` 增加临时 PCC VM 恢复；影响耗时、磁盘、权限和网络条件 |
| DFU/TSS/Restore | `pymobiledevice3_bridge.py` 与 Python 运行时 | `VPhoneRestore` + 内嵌 libirecovery/idevicerestore 后端 | 消除 Python 恢复运行依赖；需要重新验证错误、超时、取消、ECID 选择和资源清理 |
| CFW 补丁 | Swift boot-chain + Python Mach-O/DSC 补丁 | Mach-O/DSC 补丁、APFS snapshot 操作迁到 Swift | 多数是已有功能的语言迁移；需要逐项比较输入、输出、幂等和失败行为 |
| 签名、归档 | 依赖 ldid、tar/zstd 等外部工具 | `VPhoneSign`、`VPhoneArchive`、`vphone-archive` | 有利于分发；归档权限、硬链接、稀疏文件、导入保护不能仅凭能解包判定等价 |
| 客户机协议 | VSOCK 1337，长度前缀 JSON | VSOCK 1339，HTTP/WebSocket；SwiftNIO + IcliKit | 明确不兼容；新主机不能直接控制旧 daemon，需要配套升级客户机 |
| 对外 API | 增强的宿主 Unix socket | 新增可选 TCP 代理、OpenAPI、Swift API 客户端 | 第三方接入更方便；本地命令参数、状态模型和回执不能自动迁移 |
| 自动化 | 无窗口控制、能力发现、定位所有权/持久化、相机消费回执 | 保留基础控制、定位和 1338 相机流；缺少本地增强状态机制 | 需要保留本地业务语义，并适配新传输层与客户机实现 |
| 构建与目录 | 根 Makefile、vendor、scripts/sources/tests | 根 Makefile 移除，`Scripts/build.sh`；SwiftPM URL 依赖；PascalCase 目录 | CI、脚本、路径、测试筛选及打包清单需要整体更新 |

## 3. 上游主要改动的具体内容

### 3.1 进程拆分与宿主权限

`8e4e75c` 将私有虚拟化 entitlements 从顶层 CLI 移到 `vphone-vm`。上游 `Package.swift` 新增 `VPhoneVirtualMachineKit`，并公开该库以及 `VPhoneAPIKit`。命令行通过 launcher 启动伴随进程。

宿主准备新增 `host preflight`、`vphone-amfi-allow` 和 GUI 提权辅助程序。当前文档给出两种宿主配置，其中一种是保留 SIP、放宽调试限制，再允许当前已签名的 VM 二进制。allowlist 依赖 cdhash，重新构建后需要重新应用。**这不表示可以在未经宿主配置的普通 Mac 上直接启动研究 VM。**

本地影响：`VPhoneProcessIdentity`、`VPhoneVMStopper`、`VPhoneBundleGuard`、诊断中的 entitlement 探测目前围绕本地进程布局设计；迁移后必须识别真正持锁和运行 VM 的 `vphone-vm`。仅改可执行文件名不足以确认生命周期等价。

证据：[上游 Package.swift][package]、[宿主设置][host-setup]；本地 [停止控制实现](../sources/VPhoneCore/VPhoneVMStopper.swift)、[占用保护](../sources/VPhoneCore/VPhoneBundleGuard.swift)。

### 3.2 原生恢复与运行依赖收敛

`853d63d`、`a779f4e`、`124217d`、`356bec6` 等提交完成以下迁移：

- `MobileRecoveryCore` 内嵌 libirecovery；`MobileRestoreCore` 内嵌 idevicerestore，并提供项目自己的 bridge。
- `VPhoneRestore` 提供恢复探测、ticket 和恢复调用，替代 Python bridge。
- `VPhoneSign` 替代宿主端 ldid 签名调用。
- `VPhoneArchive` 替代项目中的多种归档外部程序，区分宿主目录与客户机卷的权限/所有权策略。
- SwiftPM 从 URL 和版本解析依赖，提交 `Package.resolved`；构建时编译并打包客户机工具。

上游的“运行时不需要 Homebrew/Python/Xcode”是分发目标和静态检查覆盖范围。源码构建仍需要 Xcode/iPhoneOS SDK。`Scripts/check_aux.sh` 明确记录：尚缺完全没有 Homebrew 的机器上的真实工作矩阵，现有检查不等于跨机器完整验收。

本地 D1/D2 的依赖锁定、托管 Python 环境和资源检查不能照旧保留全部假设。建议保留诊断与清单机制，按新依赖结构改写检查项；不要将运行时原生化解释为测试工具也必须删除。

证据：[包结构][package]、[归档实现][archive]、[分发检查][checks]。

### 3.3 固件准备、GPU 来源与显示

`8900325` 把准备流程迁到 `VPhoneFirmwarePreparer`。IPSW 下载完成后检查 manifest 和传输大小；解包、混合和组件准备在临时目录进行，完成后才移动到最终 Restore 目录。

随后 GPU 工作有多轮调整。评估采用最终实现：默认创建临时 PV=3 VM、恢复所选 cloudOS、只读挂载 System 卷，提取 `AppleParavirtGPUMetalIOGPUFamily.bundle`。`--gpu-driver-bundle` 可以提供本地 bundle 绕过这一步。构建流程另外编译并打包 `libAppleParavirtCompilerPluginIOGPUFamily.dylib`，准备固件时合入 GPU bundle。

影响：

- GPU 驱动默认随所选 PCC 固件来源变化，减少对既有外部二进制资源的依赖。
- 上游记录 cloudOS 26.4 提取的 bundle 缺少 compiler plugin，会导致 Metal 编译服务退出和黑屏；新插件用于补全该路径。此处是上游记录，本次未复测。
- 默认准备阶段现在包含真实 VM 恢复，不能继续将其视为只需文件输入的离线准备。临时 VM、TSS 网络和系统卷挂载会增加失败点；未测量实际耗时和空间增量。
- 显式本地 GPU bundle 校验当前检查 bundle 身份和 `DTPlatformVersion`。版本相同不能单独证明来自同一 build；外部 bundle 的来源还需另行核对。
- 不应把 GPU 修复解释为定位、相机或所有应用图形功能均已通过。

代表提交：`9fc1b46`、`8758b41`、`bc79586`、`b06496e`、`f9e7abb`。证据：[准备实现][prepare]、[PCC GPU 恢复][gpu-recovery]、[GPU 来源记录][gpu]。

### 3.4 JB-only 与默认客户机环境变化

`b04425d`、`f88d667`、`f4a60c4` 收敛公开流程，移除旧安装/首次启动环境。当前 `patch-firmware` 明确构造 `.jb`，且 `noBinpack: true`；`vm create` 不再提供本地的 `--variant` 选择。

需要区分两层变化：

1. **JB 系统补丁仍在。** 上游仍实施内核、系统卷和 iOS 27 用户态适配。
2. **JB 附带用户环境发生变化。** 当前默认流程不再部署包管理器、SSH/VNC、bootstrap、TweakLoader，以及相机 hook 的自动安装链路。

`Siblings` 可以单独构建 CamFix、VCamCaptured、TweakLoader、VPRegister 的归档，但正常 JB 安装不会自动安装这四个组件。GPU 的处理路径独立于该可选归档。

本地影响：`/cores/vphone_jb_setup.sh`、`jb_finalize` 阶段、Sileo/tweak/SSH 相关验收，以及依赖这些组件的自动化，均需明确保留策略。底层相机传输还存在，不能据此推断应用中的虚拟摄像头在默认新镜像中可用。

证据：[公开 CLI][cli]、[CFW 安装器][installer]、[可选客户机组件][siblings]；本地 [JB 安装脚本](../scripts/cfw_install_jb.sh)。

### 3.5 客户机 HTTP/WebSocket API 与 icli

这是最明确的协议兼容性变化：

| 对象 | 本仓库 | 上游 |
| --- | --- | --- |
| 普通客户机控制 | VSOCK 1337，长度前缀 JSON | VSOCK 1339，HTTP/1.1 与 WebSocket |
| 客户机实现 | Objective-C daemon 与项目内命令 handler | SwiftNIO daemon、IcliKit 0.6.1，保留 IPA/Keychain/相机等专用原生模块 |
| GUI 控制 | 本地 `VPhoneControl` | HTTP over VSOCK，调用新 `VPhoneGuestControl` |
| 宿主 TCP 入口 | 本地增强 Unix socket 为主要自动化入口 | `--api-listen host:port` 可选代理；默认不监听 TCP |
| 接口描述 | 本地 capabilities / 文档 | `/openapi.json`、`/v1/rpc`、`/v1/events` 与资源路由 |
| 通用命令扩展 | 项目内命令实现 | `icli.execute` 直接调用 icli 命令树 |
| 文件内容 | 本地命令及附带数据传输 | HTTP 二进制流；上传完成后 rename 发布 |
| 相机流 | 1338，加本地 generation/presentation/消费回执 | 1338 保留，但没有本地增强回执协议 |

新 API 提供设备状态、应用、输入、定位、剪贴板、文件、Keychain、Developer Mode、settings 和 accessibility tree 等操作。WebSocket 响应按 id 关联，附带状态/操作事件。JSON 消息有 1 MiB 上限；文件内容走单独二进制通道。

**旧 daemon 无法直接兼容。** 新客户端首先依赖新 HTTP health/update 路径，因此不能假定原有 1337 自动更新握手能完成这次跨协议升级。应设计配套镜像安装或一次性迁移路径。

宿主原有 `vphone.sock` 并未完全消失，上游仍有 `VPhoneHostAutomationServer`，但其命令限于 ping、screenshot、tap、swipe、key、type，且在图形界面分支中创建。本地的能力发现、shell、文件、应用、定位源和相机命令不能继续原样调用。上游 headless 可以使用新 API；这不等于本地 headless Unix socket 合约仍被保留。

上游文档说明新 API 暂无认证层；若使用非 loopback 监听地址，需要在部署层提供访问控制。这是新增 TCP 控制入口的实际约束。

代表提交：`11f9dc4`、`c8d155e`、`8eecc0d`。证据：[API 合约][api]、[宿主基本自动化入口][automation]、[客户机命令实现][guest-api]；本地 [E1 合约](host_control_protocol_e1_2026-09-11.md)、[E2 生命周期](host_control_e2_2026-09-12.md)。

### 3.6 内核与 CFW 补丁：新增行为和迁移需要分别判断

上游大量新增 Swift 文件来自 Python 移植：8 个 DSC patcher、6 个 Mach-O patcher，以及签名、daemon plist、dylib 注入和 DeviceTree 等操作。相关功能在本仓库已有 Python 或 Swift 实现，不能按新文件数量计为新补丁数量。

上游近期内核功能提交中值得核对的是 `05b4181`：新增 cloudOS 26.4 `vm_map_protect` 的 BIC/CMP/CCMP 形态（Shape C）匹配。**本仓库已经在 2026-09-09 实现同一分支门控的修正。**

| 比较项 | 本仓库 | 上游 |
| --- | --- | --- |
| 26.4 gate 定位 | 从主函数的 `ADRP + ADD + PACIA + STR` 恢复认证回调，在回调内验证门控与回写 | Shape A 失败后扫描代码范围，用指令序列和唯一候选定位 Shape C |
| 研究记录目标 | `kernelcache.research.vphone600`，cloudOS 26.4 / `23E5207q`，VA `0xfffffe0008dcaea0` | 同一 kernel/build 的记录指向同一 VA |
| 修改目标 | 条件分支改为相同目标的无条件分支 | 相同 |
| COW WRITE mask | 保留，不恢复已停用 Shape B | 同样保留 Shape B 停用 |
| 本次验证范围 | 核对代码与既有研究记录 | 核对代码与既有研究记录 |

不建议用上游扫描器覆盖本地算法。先对相同哈希输入比较候选、修改地址、指令及输出，再判断是否有必要增加兼容分支。地址仅用于证据对照，不应写入补丁逻辑。

上游 `6d5ce7d` 记录 26.4 用户态 + cloudOS 26.4 的启动、SpringBoard、Safari/Sileo 观察，但明确没有专门验证 debugger attach 或 tweak RWX 写入。该历史记录也早于当前移除默认 bootstrap 的流程，不能作为最终默认镜像包含 Sileo 的证据。

此外，本仓库的 `PatchOutcome`、必需补丁检查、`--ablate`、事务恢复和实验记录，在上游当前 pipeline 中没有对应实现。上游 `patchAll()` 按组件写回；`patchData()` 检查发现的记录非空。该条件不等价于本地逐个必需步骤均满足。

证据：[本地 26.4 重新定位记录](c3_kernel_retarget_2026-09-09.md)、[本地匹配器](../sources/FirmwarePatcher/Kernel/JBPatches/KernelJBPatchVmProtect.swift)、[上游匹配器][vmprotect]、[上游 pipeline][pipeline]。

### 3.7 固件目录、创建验收和界面

上游新增 iOS 26.6.2 `23G90` 与 iOS 27.0 `24A435` 配对目录数据。本地 `VPhoneFirmwareCatalog` 尚未包含这两个精确条目。目录增加本身不证明本地全部变体可用。

上游兼容性文档记录：这两个 iPhone17,3 用户态分别搭配 cloudOS 26.4 `23E5207q`，在 PR #486 范围内到达锁屏并响应 vphoned ping；26.6.2 有完整 fresh `vm create` 成功记录。当前创建流程会真实探测 daemon，并结束验证启动后返回。

限制：PR #486 的记录不能自动覆盖其后合入的 HTTP daemon 和最新 GPU compiler plugin。固定 tip 的完整组合仍需要验收。

GUI 文件、应用、Keychain 浏览器、录屏、菜单、位置预设/回放等主体仍存在，主要变化是目录/类型拆分与新 guest control 接入。没有证据表明这些现有 GUI 功能都属于此次新增。本地手势串行化、整次手势固定路由和事件日志需要独立保留，不能只按窗口源码重命名进行迁移。

证据：[上游兼容性记录][compatibility]、[创建流程][creator]、[界面和运行接线][app-delegate]。

### 3.8 目录、构建与测试

- `sources` → `Sources`，`scripts` → `Scripts`，`tests` → `Tests`，以及多轮模块、文件和类型改名。Swift 格式化与文件拆分显著增加文本差异。
- 根 Makefile 已被移除。固定版本实际构建入口为 `zsh Scripts/build.sh`；上游根 README 仍残留部分 `make build`/`make amfi_allow` 文案，不能直接作为当前命令依据。
- SwiftPM URL 依赖替换部分 vendor 子模块；libirecovery/idevicerestore 的 C 源码进入工程，也贡献了大量新增行。
- 上游新增归档、签名、恢复等 Swift 测试。按 `Tests/` 下 `.swift` 文件统计，上游 63 个、本地 57 个；这些是文件数，不能比较覆盖率。
- 上游不含本地 F1/F2/F3 Python 验收及性能工具，也不含本地创建恢复、诊断、位置状态、固件事务等专用测试。不能将“删除 Python 运行依赖”扩大为这些验收不再需要。
- 上游 release workflow 执行构建、签名/资源及分发检查；本地 `checks.yml`、`firmware-checks.yml` 需要在整合时明确迁移，避免只剩打包成功信号。

证据：[构建脚本][build]、[上游 release workflow][release]。

## 4. 本地必须保留或显式迁移的功能

| 功能 | 本地证据 | 上游差异与风险 |
| --- | --- | --- |
| 多变体与 less | `VPhoneVMCreateCLI`、`FirmwarePipeline`、各 CFW 脚本 | 公开入口 JB-only；EXP 身份修改、regular/dev/less 不能随覆盖丢失 |
| 创建检查点 | `VPhoneCreateRunner`、`VPhoneCreateCheckpointStore`、`--resume`、`--restart-from`、`create-status` | 上游 creator 为顺序流程，已存在 bundle 直接拒绝；无同等检查点续跑 |
| VM 与库排他锁 | `VPhoneVMLock`、`VPhoneLibraryLock`、`VPhoneBundleGuard` | 上游 Sources 未发现对应 flock 保护；局部 `lsof` 检查不等价于全生命周期排他锁 |
| 停止身份校验 | `VPhoneVMStopper` 以 PID+启动时间确认目标，并确认退出/锁释放 | 上游依据打开磁盘的 `lsof` PID 发信号；不具备同一套身份和最终确认机制 |
| 必需补丁与消融 | `PatchOutcome`、`PatchRequirement`、结构化执行、`--ablate` | 上游主要返回 PatchRecord，组件非空检查不能替代本地必需性约束 |
| 固件事务与实验记录 | `FirmwareTransaction`、`PatchExperimentRecorder`、`fw record` | 上游逐组件保存，无同等中断恢复/记录接口 |
| 统一诊断 | `doctor`、类别/代码/退出状态及脱敏 | 上游 `host preflight` 主要检查宿主启动条件，不能替代 VM/补丁/创建状态诊断 |
| 宿主命令生命周期 | E1–E4、能力发现、期限、取消、迟到响应、同用户 socket 约束 | 新 HTTP 传输有新的边界和超时，但不自动保留本地宿主命令合约 |
| 位置源所有权 | `VPhoneSystemLocationController` 的 owner/generation/sequence、持久化、暂停恢复及超时策略 | 上游有基础设置/清除/读取与 GUI 回放，无同等源控制器；本地脚本需适配 |
| 相机回执 | generation、presentation_id、客户机发布与消费状态 | 上游保留基础帧流；没有本地增强回执和默认 hook 安装，应用级验证需要重做 |
| 输入一致性 | `VPhoneTouchRoute` 与手势串行化、间隔控制、事件日志 | 上游注入实现不含本地整套路由和调度修复 |
| 系统验收 | F1 支持矩阵、F2 双 VM、F3 延迟/资源/磁盘统计 | 上游归档/签名等测试不能替代这些应用和并发行为证据 |

上述列表不是“所有本地功能已经全部实机通过”的声明。每项运行证据以现有研究文档中的版本、场景和限制为准。

## 5. 可直接确认的改进与整合优先级

### 第一阶段：小范围修正和事实同步

1. 更新两个精确固件配对条目，同时保持本地兼容性证据分级。
2. 采用上游 `b86dcaf` 的导入原则：在 staging 内完成 `VPhoneBundle.load`，验证成功后才移入库。本地当前在持库锁移动后才 load；无效 manifest 可能已经占据最终目录。应保留本地库锁，仅前移验证。
3. 核对 Swift DSC 移植中的“已补丁形态”与本地 Python 幂等处理；只吸收缺失行为。
4. 对 `vm_map_protect` 做同输入对照，不重复新增同一补丁。

### 第二阶段：原生基础模块

迁入 VPhoneSign、VPhoneArchive 和原生恢复后端，保留本地锁、停止身份、诊断与创建检查点。创建阶段的 backend 可替换，阶段合约和失败记录应持续存在。

先验证归档元数据、签名、恢复 probe/ticket 和错误路径，再进入真实恢复。GPU 默认临时恢复与最终插件属于这一阶段的独立验收项。

### 第三阶段：API 与客户机协议

将 HTTP/WebSocket 定为独立迁移项。为旧客户机明确升级路径；保留本地 Unix socket 对外合约，或提供可核对的兼容适配。定位所有权、相机回执和取消语义必须同时映射到新 guest API，避免只有传输可用而业务状态缺失。

### 第四阶段：产品范围、目录与 CI

先确定继续支持哪些固件变体和附带客户机环境，再改 CFW 编排。目录/类型重命名可以单独提交，便于核对逻辑变化。最后统一构建命令、资源清单、测试入口和发布检查。

不建议直接以最新上游目录树覆盖本仓库。保留双方历史的整合方式可行，但尚未模拟 merge，不能给出准确冲突文件数或工时。

## 6. 后续验收的最低范围

| 范围 | 需要确认的结果 |
| --- | --- |
| 补丁 | 相同哈希输入下的 PatchRecord、payload、必需步骤、幂等、缺失/歧义拒绝；多变体门控不串用 |
| 创建与恢复 | Fresh create、各阶段中断续跑、失败清理、ticket/恢复超时、配套 daemon 的真实 ping |
| 显示 | 最终 GPU 来源+compiler plugin+HTTP daemon 组合下的锁屏、持续显示、Metal 编译和重启 |
| 生命周期 | 同 VM 互斥、双 VM 隔离、离线操作拒绝、停止目标身份和锁释放 |
| API | 旧镜像迁移、GUI/headless、文件流、断线重连、期限和迟到响应、旧脚本兼容 |
| 位置与相机 | owner/序列/持久化、VM 重启边界、真实 CoreLocation 读数、真实帧消费和应用识别 |
| 分发 | 无开发工具的干净宿主上的真实操作；静态依赖检查和 `--help` smoke 不能替代 |

本次已完成提交图、目录差异与关键功能的静态核对。未产生新增固件输出或运行验收结论。

[upstream]: https://github.com/Lakr233/vphone-cli/tree/3f7011406722576fb19bffbc8c30d8aa4c4916af
[local]: https://github.com/zhaoawd/vphone-cli/tree/6288a02ad295889d31b4bdd024fa85bcbd0f22f1
[package]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/Package.swift
[host-setup]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/docs/guides/host-setup.md
[archive]: https://github.com/Lakr233/vphone-cli/tree/3f7011406722576fb19bffbc8c30d8aa4c4916af/Sources/VPhoneArchive
[checks]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/Scripts/check_aux.sh
[prepare]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/Sources/VPhoneCLI/VPhoneFirmwarePreparer.swift
[gpu-recovery]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/Sources/VPhoneCLI/VPhonePCCGPURecovery.swift
[gpu]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/Siblings/gpu/README.md
[cli]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/Sources/VPhoneCLI/VPhoneCLI.swift
[installer]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/Sources/VPhoneCLI/VPhoneCustomFirmwareInstaller.swift
[siblings]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/Siblings/README.md
[api]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/research/vphoned_http_api.md
[automation]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/Sources/VPhoneVirtualMachineKit/VPhoneHostAutomationServer.swift
[guest-api]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/Scripts/VPhoned/Daemon/GuestAPI.swift
[vmprotect]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/Sources/FirmwarePatcher/Kernel/JailbreakPatches/Memory/KernelJailbreakPatchVmProtect.swift
[pipeline]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/Sources/FirmwarePatcher/Pipeline/FirmwarePipeline.swift
[compatibility]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/docs/guides/compatibility.md
[creator]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/Sources/VPhoneCLI/VPhoneVirtualMachineCreator.swift
[app-delegate]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/Sources/VPhoneVirtualMachineKit/VPhoneVirtualMachineAppDelegate.swift
[build]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/Scripts/build.sh
[release]: https://github.com/Lakr233/vphone-cli/blob/3f7011406722576fb19bffbc8c30d8aa4c4916af/.github/workflows/release.yml
