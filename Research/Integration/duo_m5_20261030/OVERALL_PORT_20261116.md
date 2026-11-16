# 剩余功能整体接入

固定上游：`13169405`。工作分支：`duo-integration-20261030`。已验证的上一批接入保存为本地提交 `119f1529`。本记录区分生产实现、静态回归和运行验收；未推送、发布或修改生产环境。

## 第一组：旧固件与 PCC GPU

生产接入包含 #909 `b41ad87c`、#911 `12378954`，以及必要依赖 `8fadd384`（SE 3）、`24fd20d7`（iOS 18 GPU transport）、`89f325c7`（Home 按钮）。未整体替换 Duo 共享文件。

- SE 3 登记为 iPhone14,6／D49AP，保留本地 Duo 设备定义。安装树从实体板树读取具体的 32 位 `home-button-type`；恢复树继续使用既有虚拟属性。缺失、占位符或长度错误时拒绝。
- `system-systemhook-cfw-ios18_gpu_transport` 限于 iOS 18.6 + cloudOS 26.1。准备阶段选择 iOS 同发行版 cloudOS 的 GPU，安装阶段再次核对实际驱动版本。TV／HomePod／HomeView 预设关闭该项。
- PCC OS image 支持只读提取 GPU。AEA 内嵌密钥必须为 32 字节；没有内嵌密钥时回退临时恢复。挂载失败且无法确认卸载时保留工作目录。
- 仅临时 PCC 恢复 VM 在 cloudOS 主版本小于 26 时使用 1 vCPU，其余或无法解析的版本使用 8 vCPU。普通 Duo VM 配置不变。

验证证据保存在 `.build/overall-port-20261116/`。`make -C VPhoneGuestComponents OUT="$PWD/.build/overall-port-20261116/guest-tests" test-ios18-gpu` 通过（ASan／UBSan）；CoreKit 的 `PCCGPUDriverTests`、`FirmwareCatalogReportTests`、`GuestDeviceTests` 共 45 项通过。`Regression/pcc-recovery-policy.zsh` 编译实际生产恢复源码，8 项策略断言通过。

DeviceTree 首轮新增测试将既有恢复树值误写为 0；代码中 `DeviceTreePropertyPatches` 的既有值为 2。测试改为安装源值 1／恢复值 2，直接区分两条路径；保留首轮失败日志。DeviceTree／目录 65 项随后通过（`group1-patcher-tests-fixed.log`）。完整 Bundle 构建与后续组集中进行。

限制：本轮未启动旧固件 VM，未执行新的恢复、GPU 运行验收或 Duo 组合运行验收。旧固件的具体兼容范围仍需对应镜像验证。

## 第二组：SPTM

接入 #921 `bb82a72a` 的生产差异：独立 `SPTM` firmware target、`SPTMSecondaryCPUPatcher`、boot-chain 声明、pipeline、恢复收据／drift、minimal／watchos 预设和 Launchpad 组件分类。只有 cloudOS 18 构造 SPTM pipeline 组件；其他 cloudOS 保持原始 SPTM。IM4P 重封装为 `sptm` 保留 PAYP 尾部。

发现过程：在 `__TEXT_EXEC,__text` 解码 `mrs MIDR_EL1` → `and #0xfff0` → `cmp #0`，核对条件分支与紧随跳转的目标关系，再要求目标块中的寄存器索引 `ldr`／`str` 使用相同内存操作数。唯一匹配时将 `b.eq` 替换为 `ARM64.nop`；多匹配拒绝，零匹配不写入。没有硬编码补丁地址或替换指令字。

上游比较记录将该路径关联到 cloudOS 18 次 CPU reset 中未实现的核心寄存器访问，并报告旧固件多 vCPU 启动结果。本轮未独立重现该运行结果，不将上游运行证据计为本地验收。当前仓库 `ipsws/` 未提供该 suite 自动读取的 IPSW；实际镜像／PAYP 回归和多 vCPU 恢复仍需独立输入。本轮先执行语义 fixture、版本门槛、目录和 drift 回归。

SPTM／目录／drift 共 52 项通过（`group2-sptm-tests.log`），真实 IPSW 测试明确跳过。生产实现保存为本地提交 `4ba8aad6`。

## 第三组：鼠标模式

接入 #920 `1518293c`：iPad 的 Guest Pointer／Touch 选择、`guestMouseMode` 用户偏好、菜单和工具提示、捕获状态副标题、断连释放，以及相同时间戳移动事件去重。iPhone 的非捕获输入继续使用触摸；显式捕获仍单独控制且不持久化。

资源冲突按该提交实际变化的九个字符串合并，保留既有 Duo 本地化；没有引入冲突块中不属于本组的 Cryptex 字符串。JSON 解析往返通过。共享输入中的 `interfacePoint` 仍经过 active-panel/backing 比例及 `screenOrientation` 转换，未用上游版本覆盖。菜单和窗口的本地差异也保留。

本组不新增固件补丁。`xcodebuild -workspace VPhone.xcworkspace -scheme vphone-vm -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/duo-sync-20261113/XcodeBundle -disableAutomaticPackageResolution -jobs 4 build` 通过（`group3-vm-build.log`）。实际 iPad 指针／滚轮、跨窗口偏好和 Duo 两面板／旋转点击仍属于集中运行验收。

## 第四组：QuartzCore framebuffer

接入 #926 `69d45fb7` 的 planner、iOS 27 声明、`patch-quartzcore-unrotated-framebuffer`、安装列表及 TV／HomePod／HomeView block。当前分支没有 visionos 平台／预设，该缺失不通过新增孤立预设补齐。上游研究记录另存并明确来源，未将其中运行结果算为本地验收。

发现过程以 QuartzCore `get_surface` 和 framebuffer-compression 查询符号为锚点，核对查询后表面标志的 `ldrb`／`tbnz #2`，以及跳转目标的 landscape orientation 检查。唯一匹配时将分支写为 `ARM64.nop`，随后重新验证代码页签名；已修改形态可重复发现。缺失／歧义均拒绝。

安装器通过原有 `applyDyldPatches` 路径传入独立 undo ID，共享页归属和签名重计算沿用 Duo 已有实现。未覆盖 `DyldSharedCacheUndoLog`、FoldDisplay、Snapshot 或输入方向转换。默认声明适用于 iOS 27 的候选；实际已有 VM 不因编译自动修改，Duo 选择结果仍需组合候选验收。

`DyldSharedCacheQuartzCoreUnrotatedFramebufferTests`、`DyldSharedCacheUndoLogTests`、`DyldSharedCacheUndoWordsTests`、`FirmwarePatchSetCatalogTests`、`FirmwareGuestPatchResolutionTests` 共 92 项通过（`group4-framebuffer-tests.log`）。iPad 27 DSC fixture 未提供，实际 cache dry-run／重复应用／撤销测试跳过。当前没有新增恢复或 guest 安装。

## 前四组组合检查

完整 `VPhone` scheme 构建通过（`first-four-bundle-build.log`），Bundle 深度严格签名通过。实际 Bundle CLI 的 `fw patches --json` 和 framebuffer verb 的 `--help` 通过，产物保存为 `first-four-catalog.json`。该次 Bundle 仍为调整前的 2.16 标记；最终版本会再次完整构建。

SPTM 新组件改变 Launchpad 的目录契约。固定上游已使用 2.17 系列，本地组合候选采用 2.18.0，并提高 `minimumBundleComponents` 为 `(2, 18, 0)`；helper build 提高为 22。Launchpad 完整构建及 15 个 store-name／机器绑定契约测试通过（`first-four-launchpad-build.log`、`version-contract-tests.log`）。相关 CoreKit／SPTM／framebuffer／drift suite 已纳入已有 CI。

本地 `main` 从 `6f57024a` 快进到固定的 `13169405`，未访问远端、未推送。当前 Duo 分支尚未归并该祖先；额外上游平台差异需要在最终归并时逐项核对，不能以功能组移植提交代替完整同步。

实际 Duo framebuffer／输入组合验收仍待新的可审阅候选。此前的两轮 native TXM 运行证据不替代本次显示候选验收。无依赖的 Cryptex 生产接入继续执行；不会在 Duo 27.1 启用 trusted darwinOS。

## 最后一组：trusted darwinOS／persistent Cryptex

接入 #900 `6f57024a` 的依赖组：`filesystem-exp-trusted_darwinos`、`Ap,OSEnvironment` 的 manifest／TSS 传递、REM 两阶段信任缓存标志、cloudOS cryptexctl 提取／缓存／临时恢复回退、NRDUpdated 排除、三个 Cryptex RPC、能力声明、宿主菜单及串行持久化重装。四语手册与研究资料一起移植；研究中的实际运行结果明确归属于上游，翻译尚未执行本轮发布审阅。

冲突处理保留 Duo 已有的 `runProgram`、`process.spawn` 分页和 spool，Cryptex 直接复用其兼容签名。启动过程继续执行 spool 清理、USB serial、静态名称及 watchdog，再调用有能力门槛的 Cryptex 重装。仅按本次提交的六个字符串合并资源。

本地改进：cryptexctl OS image 提取沿用 GPU 的挂载清理约束。通过 `hdiutil -plist` 识别整盘设备；卸载不确定或失败时保留 `.pcc-system-cryptexctl-*`，外层 staging 也保留。未增加解释器或运行时第三方工具。

`trustedDarwinOSRefusal` 保留 iOS 27 及以后拒绝，standard／minimal 都不默认选择该实验。普通 Duo 27.1 不启用 trusted darwinOS。未执行新固件下载、恢复或 Cryptex guest 安装。

本轮方法目录检查为 200 个方法／0 失败；`run-process-output-tests.sh`、live stub 和 Cryptex result-schema check 均通过。CoreKit 的 cryptexctl 发现／缓存、PCC GPU 和固件目录共 27 项通过。恢复环境选择、NRDUpdated、信任缓存、默认隔离及目录共 95 项通过（`cryptex-patcher-tests.log`）。实际恢复源码 vCPU 策略 8 项再次通过。

包含本组的完整 2.18 Bundle／Launchpad 构建、Bundle 深度严格签名及 CLI 目录读取均通过（`cryptex-bundle-build.log`、`cryptex-launchpad-build.log`、`cryptex-catalog.json`）。集中回归入口为 `Regression/overall-production.zsh`。实际 trusted darwinOS／持久化重启验收未执行。

## 固定 main 的完整归并

以 `6b60c43e` 为已实现基线，归并本地 `main=13169405`。该步骤包含前述功能组以外的上游差异，包括 visionOS、截图裁剪／缩放、location services、GLES depth clipping、文本识别资源、iOS 18 多缓冲区 GPU submit 与图标缓存。文本冲突逐项核对；本记录随本地合并提交保存，未推送或发布。

本地保留：Duo 的 AX 元素上下文点击、`GuestAPI+Gestures`、active-panel 坐标、`display.metrics`、Auto-Lock `never` 兼容参数、旧 X1 聚合收据迁移和残余目录、严格完整转换、DSC 撤销归属、macOS mapping 生命周期测试、RPC 布尔值检查／完整目录声明、process spool、连接代次与取消保护、模板重启竞态修复、`innerScreen`／`VPhoneFoldableDisplayChoice`、FoldDisplay 和 Snapshot。新增 visionOS 预设同步关闭 Duo 的残余 X1 和 inner-cutout 选择；2.18 系列契约保持。

上游新增的无强制执行副作用的 stub 负例继续使用现有 Swift server，未引入 Python。该 fixture 补齐顺序回复、断连和指定 HTTP 状态，136 项 stub 通过。目录 203 个方法／0 失败，逻辑 1,262 项／0 失败，point geometry 回归通过。新 guest 的 transport、X1 task exception、Flutter、visionOS IPC／preference journal、hinge 及 GLES AIR 测试通过。

整组回归保存于 `saved-run.Ux48Ye1J`（首轮自动归并重复 X1 表导致编译失败）和 `saved-run.dJUOw0MP`（去重后 49 项 CoreKit、188 项补丁／目录／撤销通过；完整 Bundle 编译发现安装器 `notApplicable` 参数重复）。相同 X1 表在逐字一致性检查后去重；安装器保留既有参数位置和所有调用归属。修正后完整 Bundle 构建通过（`merged-bundle-fixed-build.log`），严格签名、实际 CLI 选择迁移／导出往返和 Launchpad 完整构建通过。补充 166 项／22 suite 通过；真实 kernel、wakeboardd 和 reference cache fixture 缺失的项目明确跳过。模板／ProcessRunner 56 项、方向保持 10/10、元素点击 API 240 项及原生 AX／几何检查通过。未删除或弱化原有失败断言。

内核参考核对仅针对 `kernelcache.release.vphone600` 范围的 EXC_GUARD 语义。`kernel_symbols.db` 存在两个 kernel 名称，但其 JSON 导出未在 `Research/KernelSymbols/json/` 提供，因此本轮没有独立符号地址证据。按本地 kernel skill 将 XNU 浅克隆至忽略目录 `Research/Reference/xnu`，提交 `f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`；`osfmk/mach/port.h` 定义 `GUARD_TYPE_MACH_PORT=0x1`，`osfmk/kern/exc_guard.h` 的类型字段位于 bit 61–63，与移植的 `movk ... lsl #48` 类型判别一致。该源代码相关性不替代实际固件发现与启动验收。

## 实际 Duo DSC 候选

新的 `duo-overall-20261116` 从已停止的 `duo-txm-remap-20261116` 克隆，使用 `--new-identity`，未启动。其 System 卷以 readonly 连接／挂载，`Writable`、`WritableMedia`、`WritableVolume` 均 false。复制实际 DSC 与现有 undo 后，System 卷和 disk14 连接已卸载；不再保留挂载。

`Regression/framebuffer-cache.mjs` 在宿主工作副本调用实际 Bundle CLI。Duo 27.1 QuartzCore 唯一分支为 `0x1843c4c44`，`88101037` → `1f2003d5`；这些是发现结果，不是补丁中的固定地址。试运行不改变 cache／undo，应用只改变 `.01` 一个 chunk，重复应用不改变字节／收据，撤销后所有 cache 文件（含签名）与输入逐字节哈希相同。

首轮收据断言要求 JSON 表示完全不变，失败原因是原有 `patch-dsc-revert` 会把一个旧 X1 bootstrap 的 32 字节 run 转入 word store。失败日志保留在 `framebuffer-cache-regression.log`。核对表明 bootstrap 原有 228,314 个 word 保留，新增 8 个来自该旧 run；cache-X1 的 24,606,083 个 word 字节哈希不变。保存的回归现在逐项核对旧 word 和这 8 个原始指令、保留其他 JSON 记录及所有 owner，未取消归属断言。修正版 `framebuffer-cache-regression-fixed/report.json` 全部通过；来源 fixture 的 cache 和 undo 哈希也未变化。应用态副本保存在同目录 `cache-applied`。

候选当前报告有 9 项 `update-environment` 待办，涉及 framebuffer、GLES／compiler-cache 和文本识别；逐项列于 `combined-patch-report.json`。继承的 boot-chain DriverKit 收据漂移另列，不通过本次 environment update 改写。trusted darwinOS 仍关闭；SPTM 不适用于此 cloudOS。新的环境安装与两次冷启动组合验收尚未执行，需要为最终 VM 二进制准备新的宿主 AMFI 准入批准。

## 已批准的组合运行验收

用户随后批准 `REVIEWED/REVIEW.md` 中的最终候选：源码 `7e18551b`、版本 2.18.0、VM CDHash `5f3f79e7c4eaf331b1f0a438fcddf9042835ce19`。授权范围为该哈希准入、仅 `duo-overall-20261116` 一次环境更新、两次冷启动检查、恢复原设置与正常关机；没有擦除恢复或来源副本操作。

同一管理员会话 `42115` 已通过 `run-approved-root.applescript` 启动。检查时系统认证进程存在，`REVIEWED/root-approved.log` 尚不存在，不能认定准入或安装已执行；没有启动第二个安装会话。系统认证仍需用户在现有窗口完成。

保存的 `Regression/overall-runtime.zsh` 固定审核 Bundle 和目标，隔离宿主偏好并禁用宿主自动更新 daemon。`overall-candidate.mjs` 校验全部 197 个固定文件／符号链接、CDHash、严格签名，不再要求环境更新后的目标元数据等于更新前。该校验已通过。`overall-checks.zsh` 顺序执行既有原生输入、AX 上下文、方向、AX 发现、native remap、受控 exec 和原设置恢复，保存每项退出码；原失败断言未删改。恢复失败时保留运行状态供取证和恢复，不自动开始第二轮。脚本语法检查通过，实际运行结果待记录。

## 本轮执行结果

上段认证等待为历史记录。用户随后确认完成系统认证，同一会话 `42115` 于 08:17:07–08:18:16 UTC 完成准入和一次环境更新，退出 0。`REVIEWED/root-approved.log` 没有 `[!]`／failed／Error；记录 QuartzCore 的实际分支修改及 GLES、Metal、TextRecognition、compiler-cache 的应用过程。没有第二个安装会话。

`Regression/overall-environment.mjs combined-patch-report.json post-update-patches.json environment-receipt-check.json` 核对九项新增环境补丁全部 enabled=true、applied=true、pending=false。原 plan 未新增这些标识符，故 planned=false 仍保留；不能把它解释为未应用。所有非 Guest 补丁的 enabled／planned／applied／pending 均与更新前相同。唯一剩余 pending 是继承的 `devicetree-cfw-virtual_usb_driverkit`，delivery=restore；本轮没有通过恢复改变它。实际 DriverKit 另由两轮运行检查证明。trusted darwinOS 仍关闭。

两次实际冷启动目录分别为 `.build/overall-port-20261116/cold-run.7fsGjEjo/` 和 `cold-run.1q6rKAtH/`。均运行冻结的 2.18.0 Bundle，关闭宿主 daemon 自动更新；基础检查均通过：daemon SHA-256 `612828f62fd75b5f8901c04c47228a18119295849a352c0a1ff08bf41cc13933`、21 项环境库、DriverKit／HID dext／Virtual USB Touch Screen、根只读、36 项 AX 实际文件与 fixture 完全匹配、原备份不变、严格 X1 审计和 pairing 文件匹配。

| 检查 | 第一轮 | 第二轮 |
| --- | --- | --- |
| 原生 VZ 触摸 | 缺少 TapProbe，前提失败 | 两面板 6/6 实际按钮回执通过 |
| AX 上下文命中 | 实际 Trust 提示阻断 Home，前提失败 | 15/15，锁屏拒绝通过 |
| 方向与原生来源 | 前台／恢复前提失败 | 外屏 0°／90°／270°、内屏 0°／90°／180°及两项明确拒绝，8/8 通过 |
| 默认 AX 发现 | 缺少 TapProbe，前提失败 | 内屏 tap-8 未被发现，原断言失败 |
| native remap | 20/20，80 个 alias | 20/20，80 个 alias |
| 外部 dylib | 两种签名构造器=1／返回 73 | 两种签名构造器=1／返回 73 |
| App 直接 posix_spawn | 两种签名 EPERM，aggregate 失败 | 两种签名 EPERM，aggregate 失败 |
| 独立受控 exec | 两种签名通过，临时作业均卸载 | 两种签名通过，临时作业均卸载 |
| 原设置恢复／关机 | 通过，VM exit=0、无句柄 | 通过，VM exit=0、无句柄 |

第一轮的生成探针缺失是对来源副本状态的准备判断不正确，不能计为产品输入失败。第二轮新增保存入口 `overall-prepare.mjs`：只在指定副本缺少 TapProbe 时安装已有 `tap-probe-measured` 产物；安装走 `apps.install`，不计为 installd 验收。出现两个精确 lockdown AX 标识符时点击 Don’t Trust，并验证 20 次提示消失。随后使用同一输入、AX、方向断言。原失败日志和目录均保留，没有将 native 输入通过计为 AX 发现通过。两轮 TXM 实际 App 签名均没有 custom-trust；不将本轮表述为默认 custom-trust 或 CMS 验收。

### 实际字节与撤销归属

第二轮运行中通过 `overall-installed-cache.mjs` 读取实际 QuartzCore 分支和 undo，并 pull 284 MiB word store。实际分支 `0x1843c4c44` 为 `1f2003d5`，等于离线已验证候选。第一次比较误用了尚含旧 X1 JSON run 的 `cache-applied` 表示，原失败保留；安装器先规范化 X1 记录，因此最终比较采用离线撤销流程已逐条验证的 `cache` 规范化基线，并加入新 framebuffer 记录。23 条 JSON 记录保持，整个 word store SHA-256 为 `0dc6df399ee17839d58e4964de360a2ee01978b0f0e9bef741f12bea3efdc998`，与该基线完全相同，包含已验证的 8 条迁移原始指令。结果为 `cold-run.1q6rKAtH/installed-cache-normalized/`。这保留了全部原始字节断言，仅修正预期表示。

两轮停止后，目标磁盘重新以 readonly 连接并挂载 System，`Writable`／`WritableMedia`／`WritableVolume` 均 false。`overall-installed-writes.mjs` 核对七项新 DSC 补丁的全部 14 条写入：每条 undo 原始值均等于更新前 `duo-cache-original` 的对应字节，实际字节已改变；GLES upper-left 标记为 `1\n`。复制实际 GPU driver／compiler plugin 到宿主工作目录后，实际 CLI 重复应用 compiler identity 没有改变 driver 哈希，两条 seed 均报告原值等于新值。

第一次对脱离 bundle 的 driver 副本执行严格签名检查，因缺少它签入的 Info.plist 布局失败，原日志保留为 `installed-writes-readonly.log`；最终在只读实际 `.bundle` 布局上执行 `codesign --verify --strict` 通过，没有重签或修改 guest。结果为 `installed-writes-bundle-layout/summary.json`，driver SHA-256 `2c3efa4c3ede82457e3afb2cc542cf873e02f6fe7efd4b34de2b59994fe993d8`。先前在线读取尝试发生在正常关机完成后，ECONNREFUSED 另存于第二轮 `installed-writes.log`，不计为文件检查结果。

命令入口（相对于仓库根目录；socket 和输出目录需使用绝对路径）：

```zsh
zsh Research/Integration/duo_m5_20261030/Regression/overall-runtime.zsh
zsh Research/Integration/duo_m5_20261030/Regression/overall-checks.zsh <ready-cold-run-directory>
node Research/Integration/duo_m5_20261030/Regression/overall-installed-cache.mjs <socket> <new-output> <daemon-sha256>
node Research/Integration/duo_m5_20261030/Regression/overall-installed-writes.mjs - <new-output> <daemon-sha256> <readonly-system-mount>
```

两轮均恢复合盖纵向、Auto-Lock 300 秒、锁屏／熄屏及低电量原值，随后正常关机。最终只读 System 卷和磁盘连接均卸载；`final-images.plist` 与 `post-update-images.plist` 的连接镜像路径列表相同，`final-state-handles.txt` 为空。来源与原始副本未启动或更新；没有擦除恢复、推送或发布。

本轮完成生产整体接入及上述范围的组合验收。内屏 AX 可见性过滤、App 直接 posix_spawn、内容方向像素验证、鼠标菜单模式／iPad pointer 外观、LLDB、CMS／真实 profile、local pairing 协议、trusted darwinOS、旧固件矩阵及其他独立环境继续后置。实际字节与启动通过不能替代这些未执行的工作流，也不证明此前显示交接异常已修复。
