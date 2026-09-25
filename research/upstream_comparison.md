# 上游与本地仓库对比分析

更新日期：2026-09-25。本文持续维护当前基线、整体差异、增量分析和验证状态；历史全文保留在 Git 中。

结论：继续选择性迁移，但将目标从 `4bab3b7` 更新为 `08db376`。新增 57 个提交改变了构建产物、权限边界、客户机依赖、API 范围及 bootstrap/注入流程。旧计划的本地功能保留原则仍适用；构建与资源适配需要提前，bootstrap 与相机需要单独验收。

版本线：共同祖先是上游 tag `1.0.13`。上游 1.x 稳定 tag `1.0.14` 只多 2 个提交，其中 catalog 提交可直接 cherry-pick。`08db376` 是 tag `2.0.0`（pre-release）之后仅修改 CI workflow 的 1 个提交；上游 README 将 2.0 标为 under construction，并将 1.0.14 列为稳定版本。详见 1.1 节。

本报告合并原整体评估与 `4bab3b7 → 08db376` 增量分析，保留仍有效的本地功能约束。执行以 [融合实施计划](upstream_implementation_plan.md) 为准；实验详情见[历史复核记录](upstream_review_2d76f81_2026-09-24.md)。当前交付范围为分析与计划，不迁入生产代码。

## 1. 固定基线与证据范围

| 对象 | 版本 / 结果 |
| --- | --- |
| 当前分支 | `codex/upstream-4bab3b7-integration`；保留分支名称，名称中的 SHA 不再代表实施目标 |
| 本地版本 | `9489ab296e3c1d345f936135b370d51da7a3c65d` |
| 上一版上游 | `4bab3b76b3a2b6c5d68fecd292348176dbc18c4e` |
| 本次上游 | `08db376d9417a7ec0779967d6b2e748e3638d3c6`，本次开始与交付前两次 `ls-remote` 的 `main`/HEAD 一致 |
| 共同祖先 | `87f796c62a7cb385cd37afce121f6e222d83e5b5`，未变化；即上游 tag `1.0.13` |
| 上游 1.x 稳定 tag | `1.0.14` → `9c23c8adcd4b362120988ab9d228b959bcc23ae3`（轻量 tag） |
| 上游 2.x tag | `2.0.0`（带注释 tag 对象 `8b5886e6d3687c4b1fae8cf0792c66b5f1fa2f5c`）→ `3aa5561eaec23b3a06c4e02b48e72187a85fc18b` |
| 上游新增提交 | 57 个，其中 54 个非合并提交 |
| 当前双方独有提交 | 上游 171 个（160 个非合并提交）；本地 187 个 |
| 上游增量目录树差异 | 571 文件，新增 51,965 行、删除 9,962 行；Git 检测到 398 项重命名 |
| 上游相对共同祖先 | 764 文件，新增 135,635 行、删除 33,199 行 |
| 本地最终树 → 上游最终树 | 1,020 文件，新增 138,397 行、删除 106,804 行 |

统计使用 Git 2.53.0 默认重命名检测，并排除仓库根目录 `TODO.md`。上述四个提交均未跟踪该文件，未读取其内容。目录树差异包含移动、拆分、格式化、资源及依赖代码，不能换算为功能数或工时；本地独有文件也不能全部解释为“上游删除”。

本地从上一版计划起点 `2fd54ee` 到当前 `9489ab2` 只新增计划文档，生产代码未变；旧计划 P1–P6 及当前计划 P1–P8 均未实施。此前已完成的导入 staging 校验、APFS clone 和 postValidation 幂等处理继续保留，不再次列为待移植改动。

方法：在独立临时仓库取得固定上游对象，导出两版源码时排除根目录 `TODO.md`；核对增量提交、重命名后的实际代码、构建配置和研究记录；对同一本地版本分别模拟旧、新上游合并。未修改当前仓库的 remote、分支、索引和生产代码，也未构建上游或运行 VM。

### 1.1 上游 tag 与版本线

tag 信息来自 `git ls-remote --tags upstream` 及临时仓库中获取的 tag 对象。

| tag | 指向 | 与本文基线的关系 |
| --- | --- | --- |
| `1.0.13` | `87f796c` | 即共同祖先 |
| `1.0.14` | `9c23c8a` | `1.0.13` 之后 2 个提交，仍使用本地旧目录布局；均包含在 `08db376` 历史中，属于上游 171 个独有提交 |
| `2.0.0` | `3aa5561` | tag 说明为 “vphone-cli 2.0.0 pre-release”，tagger 时间 2026-09-25T04:56:06+09:00；`4bab3b7..3aa5561` 为 56 个提交 |

`1.0.14` 的 2 个提交：

- `b86dcaf`：导入 VM 前校验 manifest。本地 `002ef63` 已完成导入 manifest 校验前移（见 2.3 节）；该提交与本地在 `VPhoneBundleOps.swift`、`BundleOpsTests.swift` 发生内容冲突，不再移植。二者逐行对应关系本次未核对。
- `9c23c8a`：catalog 增加 26.6.2/23G90、27.0 RC/24A435，配对 cloudOS 26.4，并将 `FirmwarePickerTests` 计数 23 改为 25；同时修改 README 及 ja/ko/zh 译文的 Tested Environments 表。`git merge-tree --merge-base=9c23c8a^ 71bbf60 9c23c8a` 退出 0，可干净应用到本地 `71bbf60`。

`08db376` 相对 `3aa5561` 只修改 `.github/workflows/build.yml`、`release.yml`（新增 62 行、删除 14 行）。本地 `9489ab2` 对 `3aa5561` 的 merge-tree 结果与对 `08db376` 相同（277 个未合并路径，事件计数相同）。因此第 2、4 节的源码结论同样适用于 `2.0.0`；第 3 节 CI 行中的 push/PR build workflow 属于 `08db376`，不属于 `2.0.0`。

`3aa5561` 的 README 标注 2.0 “under construction”，并将 `1.0.14` 列为稳定版本。版本锚点规则：

1. 1.x 版本线上的修复从 1.x tag 取提交，优先 cherry-pick（`-x` 记录来源）。
2. 2.x 结构对比以 `2.0.0` 或之后的 tag 为锚点；`main` 上 tag 之后的提交单独列出，不作为独立基线。
3. 本文固定 SHA 仍为 `08db376`，文中源码链接继续指向该提交。

## 2. 当前整体差异与本地保留范围

本节合并前一轮已确认且仍适用的结论；具体变更和证据补充见后续章节。原生化、进程拆分、协议迁移、VM 格式迁移及本地状态合约需要共同处理。

| 模块 | 本地实现 | 固定上游结果 | 影响与保留要求 |
| --- | --- | --- | --- |
| 进程与权限 | CLI 同时包含 VM/UI 和固件编排，诊断检查当前 CLI | CLI 启动持私有权限的 `vphone-vm`；新 bundle 分开签名 | 进程识别、锁、停止和 doctor 必须一起适配，不能只改程序名 |
| VM 格式 | manifest 没有 `schemaVersion` | 2.x 只加载 `schemaVersion=2`，要求重建旧 VM | 首条路径为新建 v2；保留旧路径及显式不兼容诊断，不原地补字段 |
| 固件变体 | regular/dev/jb/exp/less，默认 regular | 公开创建/补丁/CFW 流程只支持 JB；pipeline 内仍保留五个值 | 保留多变体入口、默认值及 EXP 作用域；内部枚举不等于公开支持 |
| 创建状态 | 七阶段 runner、检查点、resume/restart-from/status、产物指纹与保留规则 | 顺序执行，已有目标 bundle 直接拒绝 | 只替换阶段后端，保留中断续跑、错误证据和产物生命周期 |
| 固件准备/GPU | Shell/Python 编排、缓存与 APFS clone | Swift 缓存/解包/混合；默认额外恢复临时 PCC VM 提取 GPU | 保留占用保护与续跑；临时恢复、TSS、挂载、driver/plugin 来源单独验收 |
| 原生模块 | Python 恢复桥接及外部签名/归档工具 | VPhoneRestore、Sign、ArchiveKit 和 C 恢复后端 | 核对 ECID、错误/取消、归档元数据、签名、依赖及许可证，逐模块接入 |
| VM/库锁 | VPhoneVMLock、VPhoneLibraryLock、BundleGuard | 没有本地同等排他保护；stop/CFW 使用 lsof | 保留运行中离线操作拒绝、库内原子发布和实例互斥 |
| 停止身份 | PID+启动时间，等待退出和锁释放 | 根据 lsof Disk.img 的 PID 发 SIGINT，超时发 SIGKILL | 保留本地身份校验；不得把磁盘占用 PID 当作已确认的 VM 进程 |
| 补丁与实验 | PatchOutcome、必需步骤、消融、事务、fw record | Swift 移植和 PatchRecord；逐组件写回 | 保留缺失/歧义拒绝、事务恢复与实验记录；同输入对照后才调整匹配器 |
| 客户机协议 | 1337 长度前缀 JSON、Objective-C daemon | 1339 HTTP/WS、SwiftNIO、IcliKit 0.6.9 | 宿主与客户机配套迁移，旧协议保留独立路径；不假设新客户端回退 |
| 自动化 | headless Unix socket、同用户检查、shell、期限/取消、定位所有权、相机回执 | 基础 Unix socket 加可选 TCP API，扩展方法增多 | 保留本地对外合约和状态模型；扩展方法不自动提供这些语义 |
| 客户机环境 | 各变体安装资源，JB/EXP 的 Procursus、SSH/tweak、first-boot finalization | 默认系统安装含新 hook；Irisin bootstrap 通过显式 API/菜单安装 | 保留既有环境；新 bootstrap/注入独立验收，不接管未知安装 |
| 诊断与验收 | doctor 分类/代码/脱敏、F1/F2/F3、fast/firmware 分层 | host preflight、bundle 校验和上游研究记录 | 迁移诊断检查对象，保留本地测试及应用/并发验收；不扩大旧证据范围 |

### 2.1 VM 格式、变体与创建

上游 manifest 加载先检查 `schemaVersion == 2`，再检查应用主版本为 2；现有旧 VM 没有原地升级入口。本地旧 bundle 不能直接交给新加载器。库扫描、导入、克隆和启动都需明确报告版本，不能静默丢失旧 VM 列表项。

本地进程定位目前匹配 `vphone-cli`，迁入上游布局后可能识别 CLI 父进程而遗漏 `vphone-vm`。doctor 也需要检查实际 VM 子程序的 entitlements。上游基于 lsof 的 stop 是否向 VZ 辅助进程发送信号，仍是待验证假设；本地 PID+启动时间校验与锁释放条件必须保留。

上游 creator 无本地等价的检查点续跑，CFW 后的清理时机也不同。本地七阶段中的 `jb_finalize`、最终 verification 和 restore tree 保留规则不能被“daemon 已连接”替代。各变体、GUI/headless、双 VM 的历史运行证据仍以对应研究记录的版本和限制为准。

证据：[上游 manifest][manifest-current]、[上游启动与停止][launch-current]、[创建流程][creator]、[本地进程定位](../sources/VPhoneCore/VPhoneLaunchLayout.swift)、[本地停止控制](../sources/VPhoneCore/VPhoneVMStopper.swift)、[本地占用保护](../sources/VPhoneCore/VPhoneBundleGuard.swift)、[D4 创建检查点](d4_create_checkpoint_resume_2026-09-17.md)。

### 2.2 GPU、CFW 与兼容性证据

默认 prepare 在临时 PV=3 VM 中恢复所选 cloudOS，再只读挂载系统卷提取 GPU bundle；可用 `--gpu-driver-bundle` 跳过这一步。该路径需要虚拟化宿主权限、TSS 网络及磁盘/挂载条件，不能作为纯文件离线步骤。准备流程还会覆盖 GPU bundle 内的 compiler plugin，改用随工具构建的版本；驱动和 plugin 的来源与摘要均需记录。

显式 GPU bundle 的文件完整性、标识和平台版本检查不能单独证明来自相同 build。上游历史记录中的 compiler plugin 缺失与黑屏现象，仅是对应组合的证据；最终 GPU、daemon、manifest 和本地补丁组合仍需验证持续显示、Metal、重启和应用行为。

CFW 需要 root、空闲磁盘和大于 50 GiB 可用空间；这些检查不代替本地持锁安装。iOS 27 的用户态补丁、应用注册及本地 first-boot finalization 需要按最终组合验证。目录新增的 26.6.2/23G90、27.0/24A435 配对不能视为本地全部变体已支持，旧上游 PR #486 的锁屏/ping 记录也不能覆盖其后的协议、GPU 和格式变更。

证据：[GPU 恢复][gpu-recovery-current]、[GPU 驱动校验][gpu-driver-current]、[固件准备][prepare]、[CFW 安装器][installer]、[上游兼容性记录][compatibility-current]、[本地支持矩阵](f1_support_matrix_2026-09-17.md)。

### 2.3 补丁取舍与已完成修正

前一轮上游的 DSC/Mach-O Swift 文件多为本地已有 Python 功能的移植。语言或目录变化不能作为新增补丁数量，也不能证明必需步骤、失败行为、幂等和输出相同。上游组件级记录非空检查不等价于本地每个必需步骤均满足。

本地已经具有 vm_map_protect 的语义定位和已补丁分支识别，以及 postValidation 的唯一候选校验与结构化幂等结果；保留现有实现，不替换成上游较弱的返回合约。相关判断沿用既有源码/研究对照，本次未新增 kernelcache 指令或运行证据。

| 项目 | 当前状态 | 证据与限制 |
| --- | --- | --- |
| 导入 manifest 校验前移 | `002ef63` 已完成 | staging 内校验后持库锁发布，有无效 manifest 回归测试 |
| APFS clone | `002ef63` 已改为 `cp -Rc` | 已有 200 MB 目录复制实验；完整 IPSW 准备仍未验收 |
| postValidation 已补丁识别 | 本地原已具备 | 不重复移植上游 Bool 返回版本 |
| EXP 相机 DSC | 待修正 | 内存模拟显示部分输入可能提前退出，或先写后失败而未调用页面哈希重算；不代表已验证真实签名 |
| 固件 catalog 两项 | 待 cherry-pick | 取 `1.0.14` 的 `9c23c8a`，可干净应用；需同步本地兼容性清单（见计划 P1a），增加条目后另做组合验收 |

证据：[历史复核与相机内存实验](upstream_review_2d76f81_2026-09-24.md)、[本地内核重新定位记录](c3_kernel_retarget_2026-09-09.md)、[本地补丁比较](0_binary_patch_comparison.md)。

### 2.4 客户机升级与自动化合约

新宿主先探测 1339 的 `/v1/health`，自身更新也使用 HTTP。旧 1337 daemon 无法仅靠替换宿主得到新协议。历史上提出的“通过旧缓存更新握手推送新 daemon”仍是待验证假设；运行库、签名和 launchd 配置需要配套，less 不能复用这一路径假设。当前实施决定采用新建配套 v2 镜像，并保留旧协议路径。

定位需保留 owner/generation/sequence、持久化与暂停恢复；相机需保留发布/消费身份与应用验证；输入需保留整次手势路由和会话代际。GUI 在 iOS 26 及以上的 VZ 路径与客户机 API 注入路径分别验收，不能因二者最终都能产生输入而视为等价。

证据：[宿主控制客户端][control]、[本地 E1](host_control_protocol_e1_2026-09-11.md)、[E2 生命周期](host_control_e2_2026-09-12.md)、[相机回执](camera_receipt_e6_2026-09-14.md)。

## 3. 相对上一基线的结论修订

| 问题 | `4bab3b7` 时的结论 | `08db376` 的结果 | 计划调整 |
| --- | --- | --- | --- |
| 构建与分发 | 根 SwiftPM + `Scripts/build.sh`，目录最后统一 | 根 `Package.swift` 和该脚本已移除；Xcode workspace 构建自包含 `VPhone.bundle` | 先建立构建、资源与测试适配，再迁入原生模块；纯目录改名仍独立提交 |
| 权限辅助程序 | `vphone-amfi-allow`、SUDO_ASKPASS/GUI 密码辅助 | `VPhoneEscalator` 负责 AMFI allowlist；bundle 不负责提权；CFW 非 root 调用直接失败 | 保留本地受控 sudo 重执行入口，单列 root 边界和所有权恢复 |
| 外部 API 产品 | OpenAPI 文档、`VPhoneAPIKit` 和 `VPhoneVirtualMachineKit` SwiftPM 产品 | OpenAPI 实现已移除；客户端为 Xcode 静态库 `VPhoneExternalAccessKit`，VM/UI 在 `VPhoneVirtualization` | 重新定义依赖接入与 API 合约，不按旧产品名复制 Package 声明 |
| 客户机运行依赖 | `icli.execute` 调用独立 icli 程序 | 直接链接 IcliKit/IcliSystem 0.6.9；无 `icli.execute`，bundle 不含 icli 可执行文件 | 删除计划中的必装 icli 二进制要求；任意 shell 仍需本地 handler 和可执行文件来源 |
| bootstrap 与注入 | 默认不装 bootstrap/SSH/VNC/tweak 环境 | CFW 仍不自动装 package bootstrap，但安装 launchd/SystemHook；另有 Irisin rootless/RootHide 安装、检查、卸载 API | bootstrap 增加独立阶段；不直接替换已有 Procursus/finalization |
| 并发与控制 | 基础 HTTP/WS 控制 | 并发请求、更多 API、端口隧道、输入串行、定位旧任务过滤 | 吸收传输改进，保留本地期限、取消、所有权及回执语义 |
| 相机 | 1338 数据流与本地回执有差异 | 共享协议头集中管理，路径移至 mobile Media，但仍是 64 字节头 | 与本地 256 字节头和消费回执一起设计兼容路径，不能单独替换 daemon 或 hook |
| CI | release 构建不跑测试 | 新增 push(main)/PR build + bundle 校验；release 上传 ZIP | 上游仍没有在这些 workflow 执行测试套件；保留本地 fast/firmware 测试 |

## 4. 新增变化与本地影响

### 4.1 Xcode、bundle 与依赖

代表提交：`ea082eb`、`2b58537`、`456511f`、`e5460ff`、`08db376`。

上游现在使用 `VPhone.xcworkspace` 的 `VPhone` scheme。`VPhone.bundle` 是 `BNDL` 容器，没有 `CFBundleExecutable`；入口仍为 `Contents/MacOS/vphone-cli`，其启动同目录的 `vphone-vm`。VM 私有 entitlements、客户机 daemon entitlements 和普通宿主 CLI 的签名分开。`VPhoneEscalator` 替代此前的 AMFI 辅助程序；归档入口变成 `vphone-cli archive`。

`StageBundle.sh` 嵌套构建恢复模块、CLI、iOS daemon、AMFI 辅助程序及 guest components，然后复制、签名和校验。它还为宿主 VM 处理 `libswiftCompatibilitySpan.vphone.dylib`，并拒绝依赖 `_swift_initBorrow` 的 daemon。daemon 工程固定 Swift Collections 1.6.0；workspace 与 daemon 的 lockfile 固定 icli 0.6.9、SwiftNIO 2.83.0。归档依赖升级为提供 `ArchiveKit` 的 `libarchive.xcframework` 1.0.0。不同子工程有自己的 lockfile，不能只迁移根 workspace 的一份。

`ValidateBundle.sh` 检查二进制、签名、entitlements 隔离、资源、部分动态依赖和最小归档往返；这些检查不证明 VM、真实恢复或客户机 API 可用。新 build/release workflow 运行构建和该脚本，没有运行 Xcode test 或本地 firmware-free 套件。

本地应保留 Makefile 与 `scripts/run_tests.py`，先提供可构建的目标和资源映射。完整 Xcode 目录布局可逐模块引入；不要求为取一个原生模块先整体重排仓库。纯目录改名仍应与业务改动分开。

证据：[bundle 构建脚本][stage]、[bundle 校验脚本][validate]、[工程集成说明][bundle-guide]、[build workflow][build-ci]、[release workflow][release-ci]、[daemon 工程][daemon-project]。

### 4.2 提权与宿主文件权限

`VPhoneCustomFirmwareInstaller.elevate` 在非 root 调用时抛错，要求调用方使用 sudo。恢复 C 后端管理系统 `deviceinterfaced` 时也不再内部调用 sudo，非 root 的特权操作返回 `-EPERM`。这改变了本地“在特定阶段提权”的控制流，必须同时适配错误、取消、环境传递和调用用户身份。

新增 `VPhoneInvokingUser` 用 `SUDO_UID/GID` 恢复 root 生成文件的所有者，保留 mode；但 `VPhoneHostFilePermissions` 又对普通文件和目录执行 `fchmod(..., 0o777)`。后者接入创建、克隆、固件缓存、CFW 和部分发布操作。因此“恢复了所有者”不表示保留了访问限制。权限函数本身跳过符号链接和特殊文件；仍会扩大其处理的普通文件权限。

整合决定：可吸收调用用户识别和所有权恢复；不迁入递归 `0777` 策略。保留本地 socket `0600`、同用户校验和锁。跨进程使用 bundle 通过明确的同用户/所有权约定实现。验收需覆盖成功及失败退出，尤其是对已存在 bundle 的拒绝路径不得顺带修改权限。

证据：[宿主权限函数][permissions]、[调用用户与所有权][invoking-user]、[创建流程][creator]、[CFW 安装器][installer]、[恢复特权调用][restore-privilege]。

### 4.3 固件工作目录、缓存与清理

代表提交：`ea6cfb1`、`f09ed9c`、`cb518e6`。

下载缓存移到每个 VM 的 `.ipsw-cache`，本地 IPSW 直接读取。远程输入使用流式写入同目录 `.partial`，检查长度和 manifest 后发布。prepare、PCC 恢复、Cryptex 和 CFW 工作目录向 VM 目录收敛；失败清理增加挂载检查，不能卸载时保留工作目录。GPU compiler plugin 改为从 bundle 中直接复制 dylib，不再解包之前的归档资源。

共享 restore 目录的符号链接兼容被移除；`VPhoneRestoreLayout` 改用目录 resource value 发现 restore tree。`VPhoneFirmwareIndex` 还删除了 AppleDB 持久缓存和旧缓存回退，改为 ephemeral 网络请求。这些是缓存位置、离线行为和磁盘占用的变化，不能只按文件搬迁处理。

本地已有检查点和产物保留合约：restore tree 的 `retain_until` 包含 `first_boot`、`verification`。上游 creator 在 CFW 后、first boot 前清理 restore tree，不能原样迁入。本地应吸收 VM 内 staging 和挂载失败保留逻辑，继续由检查点决定产物删除时机，并明确共享只读输入、每 VM 可写产物和缓存管理的边界。

证据：[固件准备][prepare]、[IPSW 缓存][cache]、[固件索引][index]、[恢复布局][restore-layout]、[本地 D4 合约](d4_create_checkpoint_resume_2026-09-17.md)。

### 4.4 IcliKit 与扩展 API

代表提交：`3000394`、`0394ee6`、`0e8946f`、`9e7d820`、`a624c63`、`ce3e8fc`、`f5718d8`。

新 daemon 直接调用 IcliKit 0.6.9。新增设备/网络信息、显示/音频、复合手势、UI tree/OCR、进程和内存、launchd 服务、日志与崩溃、应用细节、文件工具及只读 package 查询等方法。部分新方法只有 RPC/WS 入口，不能假设都有 REST route。`/v1/health` 的 capability 列表扩展，但协议仍报告 `api_version=1`，不能只按版本号推断具体方法存在。

IPA/TIPA 安装改由 IcliKit 处理解包、容器、注册和回滚，vphone 提供签名回调。`apps.launch` 区分已启动进程和已确认前台状态，返回 `frontmost_verified`；调用方不能把 PID 存在解释为前台切换成功。设备、签名和新 entitlements 需要成套迁移。

当前源码没有 `icli.execute` 或任意 shell RPC。已有 `system.reboot`、服务、文件等专用 API 可以承接部分内部调用；本地公开的 shell 合约（cwd、timeout、stdout/stderr、退出码、截断状态）仍需独立保留。没有新增 shell 运行验收证据。

OpenAPI 实现已移除。上游 API 文档仍有旧 SwiftPM 产品名和 0.6.8 表述，实际依赖以工程配置、lockfile 和 dispatch 源码为准。整合时应维护 capability/方法清单和合约测试，不能把旧 OpenAPI 当成当前 schema。

证据：[主 API dispatch][api]、[扩展 dispatch][api-extended]、[手势与 UI 方法][api-input]、[外部客户端][external-client]、[API 文档][api-doc]。

### 4.5 并发、排序、隧道与断线

请求工作队列改为 concurrent，WS 响应可乱序并通过 `id` 关联。宿主 `orderedInput` 顺序执行自身发送的触摸/HID；`orderedLocation` 用本地计数过滤尚未执行的旧定位任务。这些实现值得参考，但该计数不是客户机可验证的 owner/generation/sequence 协议，单个客户端的输入队列也不提供多个 API 客户端之间的手势互斥。

新增 `/v1/ports/<port>` WebSocket 隧道，连接客户机 `127.0.0.1` TCP 端口。它只提供字节流转发，不安装 SSH/VNC 服务；普通 SSH 客户端仍需 TCP/WS 适配。隧道及宿主代理断线时最多等待 5 秒排空待写数据。文件上传增加写入时暂停读取及断线临时文件清理；客户端增加 socket 超时与 `F_SETNOSIGPIPE`。

本地 E1–E4 的期限、取消、迟到响应、会话代际和操作状态仍需迁移。关闭 HTTP/WS 通道不证明客户机操作已停止。上游 Unix socket 仍在 GUI 分支启动；headless 的直接 HTTP 控制不能代替本地 headless Unix socket 合约。

TCP 监听仍默认关闭，启用后没有认证层。新增文件、服务、进程和 bootstrap 操作使访问控制成为启用该入口的必要集成工作。保留默认 loopback；`force=true` 是操作确认字段，不是身份认证。

证据：[客户机队列][api]、[宿主控制客户端][control]、[端口隧道][tunnel]、[上传实现][upload]、[宿主接线][delegate]、[本地 E1](host_control_protocol_e1_2026-09-11.md)。

### 4.6 相机数据与消费回执

`0394ee6` 将 daemon 和相机 hook 的协议头集中到 `VCamFrameProtocol.h`，运行路径改为 `/var/mobile/Media/SimulatedCamera`。daemon 等待 mobile home、创建目录并在早期启动失败后重试。宿主发送使用复制的 descriptor，避免直接关闭 `VZVirtioSocketConnection` 持有的 descriptor，并设定发送超时。

| 对象 | 本地 | 新上游 |
| --- | --- | --- |
| VSOCK 端口 | 1338 | 1338 |
| 共享帧头预留空间 | 256 字节 | 64 字节 |
| 帧身份 | generation、presentation_id、发布时间 | 帧序号和时间；没有本地身份扩展 |
| 消费回执 | 独立 observe shm；daemon 返回消费状态 | 检查范围内没有对应 observe 协议 |
| 默认共享文件路径 | `/var/jb/var/mobile/Library/…` | `/var/mobile/Media/SimulatedCamera/…` |

相同端口不表示共享内存 ABI 兼容。必须同时处理宿主 wire、daemon publish header、hook pixel offset、observe header 和查询接口。路径迁移也要验证 cameracaptured/App 的实际读取权限，不用连接状态代替消费状态。

上游研究记录验证了测试图/视频文件的传输、共享帧发布及停止；记录明确说明该次没有安装/加载 camera hooks，Camera.app 预览、拍照和视频录制未验收。本地已有相机回执也只证明对应消费步骤；应用识别仍需独立验证。

相机 DSC 在这 57 个提交中只有两处 `CLI` → `Command` 注释变化，算法未变。旧计划 P1b 的全部目标预检查、混合输入补齐与哈希验证仍需实施。

证据：[上游帧头][camera-header]、[上游传输记录][camera-research]、[本地帧头](../scripts/vphoned/vphoned_vcam.h)、[本地 E6 记录](camera_receipt_e6_2026-09-14.md)、[相机 DSC][camera-dsc]。

### 4.7 Irisin、launchd hook 与 SystemHook

代表提交：`9efcaa6`/`4e1770f` 后撤销，`6b86731`/`831f842` 重新应用；随后 `415caff`、`6b334a0`、`969c913`、`25041f4` 继续修改。不能只挑最早两次提交，最终状态需以固定目标源码为准。

CFW 安装 `launchdhook-vphone.dylib`、`SystemHook-vphone.dylib`，创建 `/vh`，向 launchd 加入 weak dylib load 并重签名。launchd hook 扩展 bootstrap daemon 发现并拦截 `posix_spawn`；SystemHook 将注入传递到最终进程和子进程，在 App/bootstrap 进程中加载选定 root 的 `usr/lib/TweakLoader.dylib`。PID 1 和 xpcproxy 不加载 TweakLoader；注入桥接本身不依赖 ElleKit。最终 SystemHook 已超出早期提交中的“诊断探针”范围。

另一路径是 `bootstrap.install/status/inspect/uninstall/firmware`：由 daemon 获取最新 Irisin release，验证资产 SHA-256 与 deb metadata，支持 rootless 和 RootHide，注册应用、加载服务、维护 firmware dpkg 记录及完成标记。菜单默认选择 RootHide。安装不执行 maintainer scripts；服务启动失败可作为 `service_start_warning` 返回，不能将 payload 安装成功解释为服务运行成功。首次 apt/bash 初始化仍是后续 package 操作。

卸载要求完成标记、精确 jbroot 和 `force`，删除后调度客户机重启。这不等价于识别或接管本地既有 Procursus 安装。迁移应先作为新建 JB 测试路径的可选能力，不静默更换本地布局、包管理器或 finalization；EXP 相机 tweak 需要单独检查是否会被新加载路径覆盖。

上游记录含 iOS 26.6.2 隔离 VM 的 daemon/App/SystemHook 探针与启动证据，不能扩展为本地 iOS 18/26/27、全部变体或真实 tweak 包兼容性结论。最新 Irisin release 是浮动外部输入；实施验收需记录实际 tag、架构、下载 URL 和摘要，固定主仓库 SHA 不能单独保证 bootstrap 可复现。

证据：[CFW 安装器][installer]、[launchd hook][launch-hook]、[SystemHook][system-hook]、[Irisin 安装/卸载][irisin]、[上游补丁研究记录][patch-research]。

### 4.8 UI、检查面板与截图

新增剪贴板/Preferences 窗口、设备信息、进程、服务、Console、崩溃、控制、UI Inspector 等面板，依赖新增 API capabilities；菜单和字符串资源本地化。窗口状态按 VM 路径保存，菜单快捷键优先于 VM view。截图使用客户机 IcliKit 捕获，省略宿主绘制的边框/开孔。

这些功能可在协议稳定后选择性吸收。本地已有 screenshot、坐标系、手势路由与多 VM 隔离要求，不能因 UI 可用就替换其语义。需测试截图尺寸/方向、UI/OCR point 坐标与宿主像素/归一化坐标转换，并继续设置 `isReleasedWhenClosed = false`。

证据：[窗口实现][window]、[宿主接线][delegate]、[截图及能力协商][control]、[API 手势坐标][api-input]。

### 4.9 未发生的新内核变更

将旧 `Sources/FirmwarePatcher/Kernel` 和新 `VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel` 的 Swift 文件按文件名一一对应：各 50 个，集合相同，文件内容逐字节相同。本次增量没有这些内核文件的算法变更。固件 catalog 内容也未变，因此此前缺少的 26.6.2/23G90 与 27.0/24A435 仍是待移植条目；本地可直接 cherry-pick `1.0.14` 的 `9c23c8a`（见 1.1 节）。

已阅读项目 `kernel-analysis-vphone600` 技能以确认取证边界。本次没有分析目标 kernelcache 的指令或符号，不新增补丁可用性结论。本地 PatchOutcome、事务、必需步骤、消融、vm_map_protect/postValidation 和多变体约束继续保留。

## 5. 新旧职责映射

路径用于定位源码，不表示同名目录可以整体替换。

| 本地入口 | `4bab3b7` 入口 | `08db376` 入口 / 保留要求 |
| --- | --- | --- |
| `Package.swift`、Makefile | 根 Package、`Scripts/build.sh` | `VPhone.xcworkspace` + 各 xcodeproj；保留本地测试和兼容命令 |
| `sources/VPhoneCore` | `Sources/VPhoneCore` | `VPhoneKit/VPhoneCoreKit`；保留锁、检查点、停止身份、诊断 |
| `sources/vphone-cli` CLI | `Sources/VPhoneCLI` | `VPhoneExecutable/VPhoneCommand/VPhoneCommand`；保留多变体、resume/status |
| `sources/vphone-cli` VM/UI | `Sources/VPhoneVirtualMachineKit` | `VPhoneExecutable/VPhoneVirtualization/UI`；实际 VM 持锁，保留 headless 合约 |
| `sources/FirmwarePatcher` | `Sources/FirmwarePatcher` | `VPhoneExecutable/VPhoneCommand/FirmwarePatcher`；保留结构化结果与事务 |
| Python restore bridge | `Sources/VPhoneRestore`、`MobileRestoreCore` | `VPhoneExecutable/VPhoneCommand/VPhoneRestore`；适配 root/错误/取消和 DFU owner |
| tar/签名工具调用 | `Sources/VPhoneArchive`、`VPhoneSign` | `VPhoneKit/VPhoneArchiveKit`、`VPhoneExecutable/VPhoneCommand/VPhoneSign` |
| `scripts/vphoned` | `Scripts/VPhoned` | `VPhoneDaemon/Daemon`、`Native`、`Configuration`；新传输下保留本地扩展 |
| 本地宿主 Unix socket 客户端 | `Sources/VPhoneAPIKit` | `VPhoneKit/VPhoneExternalAccessKit` 可并存；不替换本地命令合约 |
| `scripts` / `Siblings` 客户机资源 | `Siblings` | `VPhoneGuestComponents`；区分“已构建/已打包”和“已安装/已加载” |

## 6. 合并模拟

两次都使用同一个本地版本 `9489ab2`，消除本地文档提交差异对计数的影响。

| 结果 | 旧上游 `4bab3b7` | 新上游 `08db376` |
| --- | ---: | ---: |
| 未合并路径 | 318 | 277 |
| 内容冲突事件 | 54（含 1 项 add/add） | 48（无 add/add） |
| 修改/删除冲突事件 | 57 | 66 |
| 目录迁移提示事件 | 203 | 157 |
| 重命名/重命名事件 | 2 | 2 |

旧报告的 315 路径来自本地 `2c604ea`，与本次 318 的本地输入不同。新上游路径数减少，但修改/删除事件增加；目录重排改变了 Git 的匹配结果，不能据此推断业务冲突减少或迁移成本下降。

重点仍是构建/测试目标、pipeline 和 CLI 旧入口、VM/UI/宿主自动化、客户机 handlers、研究与测试目录的归属。不得接受“修改/删除”作为删除本地能力的理由，也不得批量接受把本地研究文档迁到 `Research/Kernel` 的建议。

完整固定 SHA、57 个提交及新上游冲突路径/消息见 [冲突与提交清单](upstream_review_08db376_conflicts_2026-09-25.txt)。以下命令在含双方对象的临时仓库重现原始 NUL 输出；退出 1 表示存在冲突，不表示没有结果：

```sh
git merge-tree --write-tree --messages -z \
  9489ab296e3c1d345f936135b370d51da7a3c65d \
  08db376d9417a7ec0779967d6b2e748e3638d3c6 \
  > /tmp/vphone-merge-9489ab2-08db376.bin
```

对照旧目标时仅替换第二个 SHA，输出到另一文件。清单中路径按 index stage 记录去重，事件按消息类型统计，未把原始输出标为 JSON。

## 7. 保留决定与优先级

1. 先完成独立的 catalog 和 EXP 相机 DSC 修正；这两项未因本次增量失效。catalog 通过 cherry-pick `9c23c8a` 完成，不从 2.x 路径手工抄写。
2. 提前确定 bundle 资源、依赖、签名、提权、文件权限和测试入口，再逐模块迁入 Sign/Archive/Restore 与 VM 进程。
3. 将 HTTP/WS + IcliKit 的传输改进与本地协议适配成套交付；shell、定位所有权、相机身份/回执、headless、取消语义均保留。
4. 原生准备/CFW 接入既有 checkpoint runner；新建 v2 bundle 为首条路径。保留旧 VM 可启动路径，不通过添加版本字段宣称升级完成。
5. Irisin/bootstrap 与新 launchd/SystemHook 单列可选阶段，在新测试镜像中验证，不默认替换本地 Procursus/SSH/tweak/finalization。
6. 检查面板、本地化和完整分发在核心合约稳定后引入；保持 fast/firmware/VM 三层验收分离。

## 8. 本次验证与未验证范围

| 检查 | 结果 |
| --- | --- |
| 固定对象、共同祖先、增量计数、重命名与关键源码 | 已核对 |
| 上游 tag 与版本线 | `1.0.13`/`1.0.14`/`2.0.0` 指向已核对；`9489ab2` 对 `3aa5561` 的 merge-tree 结果与 `08db376` 相同；`9c23c8a` 对 `71bbf60` 的 merge-tree 退出 0 |
| 文档检查 | 合并后的本地链接、固定上游路径、引用定义和空白已核对 |
| 两次 merge-tree | 均退出 1；冲突已记录，未执行真实合并 |
| 本地工具链 | Xcode 26.4（17E192）、Apple Swift 6.3；未验证能否构建固定上游 |
| `make test_fixtures` | 失败，make 退出 2；默认 `ipsws/patch_refactor_input` 缺少 17 个所需文件，固件测试未执行 |
| `make test` / 上游 Xcode tests | 本次未运行；实施前需记录新的测试基线 |
| 真实固件对照、恢复、启动、多 VM、应用验收 | 本次未运行；上游研究记录与本地既有记录不等于新组合的验收 |

夹具缺失限制真实固件对比，不阻止继续完成构建适配和无固件回归。下一次实施仍使用固定 SHA；若上游继续提交，按 1.1 节的 tag 锚点规则更新增量分析、固定 SHA 和修订记录，并同步实施计划；不在实施途中自动切换 `main`。

## 9. 修订记录

| 日期 | 修订 | 历史证据 |
| --- | --- | --- |
| 2026-09-24 | 完成 `4bab3b7` 基线评估，修正 shell 覆盖结论，补充相机部分应用状态与合并模拟 | [历史评估全文][history-comparison]、[复核记录](upstream_review_2d76f81_2026-09-24.md) |
| 2026-09-25 | 目标更新到 `08db376`，分析新增 57 个提交并调整计划 | 本文固定基线、增量分析和冲突附件 |
| 2026-09-25 | 合并整体评估与增量报告，采用固定文件名；日期和 SHA 在正文维护 | 历史全文保留在 Git，不再按日期创建报告副本 |
| 2026-09-25 | 补充上游 tag 基线（`1.0.13`/`1.0.14`/`2.0.0`）与锚点规则；catalog 改为 cherry-pick `9c23c8a` | 1.1 节、第 8 节核对记录 |

[stage]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneExecutable/VPhoneVirtualization/Build/StageBundle.sh
[validate]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneExecutable/VPhoneVirtualization/Build/ValidateBundle.sh
[bundle-guide]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/Documents/Guides/bundle-integration.md
[build-ci]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/.github/workflows/build.yml
[release-ci]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/.github/workflows/release.yml
[daemon-project]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneDaemon/VPhoneDaemon.xcodeproj/project.pbxproj
[permissions]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneKit/VPhoneCoreKit/Process/VPhoneHostFilePermissions.swift
[invoking-user]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneKit/VPhoneCoreKit/Process/VPhoneInvokingUser.swift
[creator]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneExecutable/VPhoneCommand/VPhoneCommand/VirtualMachine/VPhoneVirtualMachineCreator.swift
[installer]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift
[restore-privilege]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneExecutable/VPhoneCommand/VPhoneRestore/MobileRestoreCore/Core/deviceinterfaced.c
[prepare]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneFirmwarePreparer.swift
[cache]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneKit/VPhoneArchiveKit/Transfer/VPhoneIPSWCache.swift
[index]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneKit/VPhoneCoreKit/Firmware/VPhoneFirmwareIndex.swift
[restore-layout]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneExecutable/VPhoneCommand/VPhoneRestore/VPhoneRestore/Restore/VPhoneRestoreLayout.swift
[api]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneDaemon/Daemon/GuestAPI.swift
[api-extended]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneDaemon/Daemon/GuestAPI+Extended.swift
[api-input]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneDaemon/Daemon/GuestAPI+Input.swift
[external-client]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneKit/VPhoneExternalAccessKit/VPhoneAPIClient.swift
[api-doc]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/Research/vphoned_http_api.md
[control]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControl.swift
[tunnel]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneDaemon/Daemon/GuestPortForwardHandler.swift
[upload]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneDaemon/Daemon/GuestFileTransfer.swift
[delegate]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneExecutable/VPhoneVirtualization/UI/VPhoneVirtualMachineAppDelegate.swift
[camera-header]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneGuestComponents/VCamCaptured/VCamFrameProtocol.h
[camera-research]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/Research/Guest/virtual_camera_transport.md
[camera-dsc]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/DyldSharedCache/Patchers/DyldSharedCacheCameraPatcher.swift
[launch-hook]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneGuestComponents/LaunchHook/launchdhook-vphone.c
[system-hook]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneGuestComponents/SystemHook/SystemHook-vphone.c
[irisin]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneDaemon/Daemon/GuestIrisinInstaller.swift
[patch-research]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/Research/0_binary_patch_comparison.md
[window]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneExecutable/VPhoneVirtualization/UI/UserInterface/VPhoneVirtualMachineWindowController.swift
[manifest-current]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneVirtualMachineManifest.swift
[launch-current]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneExecutable/VPhoneCommand/VPhoneCommand/VirtualMachine/VPhoneVirtualMachineLaunchCommand.swift
[gpu-recovery-current]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Host/VPhonePCCGPURecovery.swift
[gpu-driver-current]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/VPhoneKit/VPhoneCoreKit/Firmware/VPhonePCCGPUDriver.swift
[compatibility-current]: https://github.com/Lakr233/vphone-cli/blob/08db376d9417a7ec0779967d6b2e748e3638d3c6/Documents/Guides/compatibility.md
[history-comparison]: https://github.com/zhaoawd/vphone-cli/blob/9489ab296e3c1d345f936135b370d51da7a3c65d/research/upstream_comparison_2026-09-24.md
