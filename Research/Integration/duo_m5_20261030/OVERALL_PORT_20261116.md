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
