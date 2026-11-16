# X1、TXM、DriverKit 与 local pairing 生产移植（2026-11-16）

生产移植和隔离副本的 guest 安装、冷启动检查已完成。36 项 AX 文件与签名候选逐字节相同，12 项调试库无剩余 X1，DriverKit dext 运行，两面板原生 VZ 触摸 6/6、既有 AX 命中 15/15 通过。随后按用户批准对独立 TXM 副本执行擦除恢复及 CFW 安装，两次冷启动通过；每轮主程序／framework 的 20 项 remap、80 个 alias 及两种 dylib 加载通过，移除 custom-trust 后结果保持。两种独立进程的受控注入也通过，实际 Preboot TXM 与候选字节完全相同。内屏 AX 可见性过滤、App 直接 posix_spawn 的限制及失败断言保留；LLDB、CMS 热重载和 local pairing 协议连接仍未验收。

起点为 `c07ee974`，固定上游仍为 `1316940501398ea279f960ee7d838f93885730d4`。本轮修改工作树，未推送或发布。用户已批准并认证新 VM 签名的 AMFI 准入、新副本环境更新和冷启动验收；实际准入及安装均成功。新补丁及选择规则使用仓库的 `Skills/authoring-patch-sets/SKILL.md`。证据位于 `.build/upstream-port-20261116/`。

## 实现与选择

| 项目 | 修改 | 兼容与撤销 |
| --- | --- | --- |
| DriverKit，#867／#877 | 接入 `devicetree-cfw-virtual_usb_driverkit` 和 `preboot-cfw-devicetree_virtual_usb_driverkit`；iPhone／iPad 运行树启用 `/product/supports-driverkit` | restore 树及其他设备族排除；Preboot 保留 IMG4 个性化信息，使用现有共享修复备份；TV 系列预设关闭 Preboot 修复 |
| local pairing，#910 及前置提交 | 按导入函数、拒绝日志引用及控制流发现 `remotepairingdeviced` 的本机连接拒绝调用；普通 arm64e 和 X1 函数入口均可识别 | 声明 `system-remotepairingdeviced-cfw-local_connections`；使用现有 Mach-O 安装／签名／备份撤销；TV 系列预设关闭此项 |
| X1，#895／#924 及 HomePop 前置实现 | 35 项 AX 独立声明、HomePop、12 项 debug-library 声明、完整转换、可选安装器及只读审计 | 缺失或无需转换时不创建备份、不重签；不完整转换拒绝发布字节；签名失败恢复 executable、备份及资源 seal；回滚失败中止安装 |
| TXM，#831／profile／#919／#923 | 保留 native classification 的 remap 路径及缺失 profile 出口；precheck 优先，二者同时选择时不生成 remap 记录 | `txm-boot-precheck_admission` 选择和收据映射到 `txm-exp-precheck_admission`；工作树 standard 候选选 remap、关闭 precheck。仅切换 TXM 的独立副本已完成下文所列运行检查；不等于完整 standard 或所有签名条件通过 |

补丁目录和选择输出发生变化。按仓库系列兼容规则，Bundle 与 Launchpad 候选升为 `2.16.0`，Launchpad 最低 Bundle 为 `2.16.0`。这是本地候选版本，不是发布记录。其余设备／旧固件、SPTM、鼠标／framebuffer 和 trusted darwinOS 项目仍按 [差异清单](UPSTREAM_REMAINDER_20261115.md) 独立跟踪；本轮没有将 trusted darwinOS 加入 Duo 默认方案。

## X1 选择与收据迁移

旧 ID `system-accessibilitybundles-cfw-arm64e_x1` 仅作为迁移输入保留。新的清单外文件由 `system-accessibilitybundles-cfw-arm64e_x1_remaining` 管理，仍限 iOS 27.1。旧聚合选择展开到 35 项 AX、HomePop 和 remaining；显式单项选择优先，显式 block 与 allow 冲突时 block 优先。新的 remaining 开关只控制清单外文件。

新旧 ID 必须分开，否则导出的 block 预设再次归一化时，会重新关闭先前允许的单个插件。本轮统一了 pipeline、安装时重新解析、目录状态报告、`fw set-patches` 与 `fw export-preset` 的规则。旧计划可以展开选择；旧 Guest 收据不在解码时展开。

安装器按实际文件逐项转移归属。独立目标从目录枚举中排除，每个路径只处理一次。已有 `.bak` 交给该文件的新声明继续使用；没有可靠备份时保留不可撤销状态。失败或不可撤销的迁移保留旧聚合收据；回滚失败中止安装，不能写入迁移完成的收据。HomePop 走同一可选安装器。审计对独立目标报告精确声明，对清单外 AX 目标报告 remaining 目录声明。

本轮未修改 Duo `31933ff2` 的共享缓存逐指令撤销归属代码；对应 undo words 回归继续执行。

## 验证与证据

已保存的 `Regression/upstream-patch-port.zsh` 编译生产 TXM 源码并运行回归，不再把历史独立上游预检当作当前生产实现的验证。2026-11-15 的预检记录保留其当时含义；本轮静态与运行结果分别记录如下。

从停机的 `duo-cfw-followup-20261115/Disk.img` 只读挂载，提取 36 项 AX bundle 和 `remotepairingdeviced`。36 项均有原始 `.bak`。所有改写、签名、重复应用和撤销发生在测试临时副本，未写入源磁盘。`source-attach.plist`、`source-detach.log` 和挂载前后清单保存挂载过程；本轮 disk14 已卸载。保存的 `Regression/copy-standalone-inputs.mjs` 可以从同类只读 System 根目录复制测试输入到新的 `.build` 目录。

36 项真实 AX 原始备份共转换 3,168 条指令，未遍历候选为 0；严格签名、identifier 保持、重复应用的字节相同、撤销后指令区恢复和再次严格签名通过。真实 pairing 镜像恰好修改 3 个调用点，签名后再次运行无修改。结果为 `real-accessibility.json`、`real-pairing.json`；这些是文件级验证，不是应用启动或配对协议验收。

TXM 使用原始容器 SHA-256 `eda4261548a786998b35f0165d51c05b262727ef4160e7eb1bc4e3c3b9900192`，payload 为 `819861b6b534b6dc53287b010e822b9d93633d07a29b6e5b968c076929ebfbc1`。8 个生产策略组合验证 precheck 优先级；显式 precheck 输出摘要 `8b126bd60162f4c8bf58c8c205ce92515ca94a84fdb08782f370a07f11a042cf`，与移植前标准输出相同。`txm-remapfalse.raw`、`txm-remaptrue.raw`、`txm-prechecktrue.raw` 准备时为两条路径及 AMFI 组合的静态候选；后续部署了与 remaptrue 完全相同的 payload，结果见 TXM 运行记录。

首次导入的 profile 负例在完整镜像上失败：该测试未限制 gate，precheck 优先导致 `findAll/apply` 没有执行 remap。已显式使用 standard native-remap 计划，保留全部拒绝、空记录和字节不变断言后重跑。首次 pairing 重复字符串夹具因截断未形成完整重复；已修正夹具，保留拒绝及文件不变断言。失败日志留存，均未作为产品通过证据。

## 运行条件与未覆盖范围

- 新副本为 `.build/duo-runtime-84e3ce54/machines/duo-patches-20261116`，由已停机的 CFW 副本 `vm clone --new-identity` 创建。用户批准后已运行 `cfw update-environment` 和冷启动检查；未运行 `fw patch`、擦除性 CFW 安装或恢复。来源和原始 `duo-rpc-accept-205443` 未启动。
- 初始 `host preflight` 被 AMFI 拒绝，见 `host-preflight.log`。本轮用户明确批准的新 CDHash 为 `a91b9e15f38c734d76d3d92a2c8e58ff83782ed8`；认证后准入成功，`host-preflight-approved.log` 通过。
- AX 文件级安装、签名、重复应用和撤销已验证；新副本保留安装结果用于后续检查，没有执行 guest AX 补丁撤销。DriverKit 的进程、枚举和原生触摸已实测。
- guest environment update 不替换 TXM。旧 precheck 副本与 native remap 副本分别验证；后者已按独立批准执行擦除恢复及下文运行检查，没有擦除来源或已验收的旧 precheck 副本。
- 本轮真实 pairing 输入为 Duo 27.1；普通 arm64e 的发现由合成回归覆盖，未取得 iOS 18 原始镜像，也未进行本机配对协议连接。
- 12 项 debug-library 已从实际 guest 逐项读取并核对备份，原始备份共 31,013 条待转换指令，转换后的实际文件无剩余 X1。LLDB 工作流未验收。TXM 的 cloudOS 26.1–26.3 完整镜像及带 CMS 的受控应用输入未提供，对应条件测试跳过。

## 最终执行结果

| 命令／范围 | 结果 | 证据 |
| --- | --- | --- |
| `zsh Regression/upstream-patch-port.zsh <原始 TXM IM4P> <镜像副本根目录>` | 15 个 suite、164 项测试通过；8 个生产 TXM 组合通过 | `saved-run.a1thV043/tests.log`、`txm-policies.log`、`txm-production-policies.json` |
| `node Regression/test-patch-selection-cli.mjs <CLI> <新输出目录>` | 聚合单项例外、导出往返、remaining 独立关闭、旧 TXM ID 和 VM 选择存盘通过 | `cli-selection-verified.log`、`cli-selection-verified/reports.json` |
| `xcodebuild -workspace VPhone.xcworkspace -scheme VPhone -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/duo-sync-20261113/XcodeBundle -disableAutomaticPackageResolution -jobs 4 build` | 完整 Bundle 构建和 admission 通过 | `bundle-verified-build.log` |
| `codesign --verify --deep --strict <VPhone.bundle>` | 退出 0 | `bundle-signature-final.log` |
| Launchpad Debug 完整构建；`zsh VPhoneLaunchpad/Tests/BundleNamesTests.sh` | 构建通过；15 项 store name 与 binding 检查通过 | `launchpad-build.log`、`launchpad-bundle-names.log` |
| 挂载前后镜像清单 | 完全相同，无本轮挂载残留 | `mount-cleanup.json` |
| `git diff --check`、`git ls-files '*.py'` | 差异检查通过；无已跟踪 Python 文件 | 本轮命令输出 |

CLI 存盘补充回归另复现了本轮归一化中的问题：`AllowedPatches` 会包含当前 standard 未选用的 11 项 restore-image 声明。修复后仅在当前预设包含的 patch sets 内计算差异；保留失败断言及 `cli-selection-repro.log`，新副本记录已重新写入，恰为 1 项 block 和 1 项 allow。

新副本显式 **allow `txm-exp-precheck_admission`、block `txm-cfw-executable_remap`**，保留来源的实际 TXM 策略。`candidate-patches-verified.json` 核对 precheck 为 enabled/planned/applied，remap 三者均为 false。该副本首先用于 AX／DriverKit／pairing guest 更新与冷启动，不能计为 native remap 验收。

最终 VM CDHash 为 `a91b9e15f38c734d76d3d92a2c8e58ff83782ed8`。用户批准并完成两次系统管理员认证后，以下命令成功执行；第二条仅操作新副本。未对 TXM 执行擦除性恢复。

```zsh
bundle="$PWD/.build/duo-sync-20261113/XcodeBundle/Build/Products/Debug/VPhone.bundle"
library="$PWD/.build/duo-runtime-84e3ce54/machines"
sudo "$bundle/Contents/MacOS/vphone-escalator" allow "$bundle/Contents/MacOS/vphone-vm"
sudo "$bundle/Contents/MacOS/vphone-cli" cfw update-environment duo-patches-20261116 -l "$library"
```

## 批准后的执行结果

执行前核对上述 CDHash 和新副本状态文件无句柄。`amfi-authorized-dialog.log` 记录新 cdhash 加入及 amfid 接收要求；`host-preflight-approved.log` 通过。环境更新显式设置 `SUDO_UID=501 SUDO_GID=20`，`cfw-environment-approved.log` 成功结束，没有 `[!]` 或补丁失败记录；System 工作镜像已卸载。`patches-after-update.json`、`guest-receipt-patches.json` 和 `hdi-after-update.plist` 保存收据与挂载状态。

保存的 `Regression/patch-port-runtime.zsh` 仅启动新副本，关闭宿主自动组件更新，等待 RPC 后执行 `patch-port-runtime-check.mjs`，收到 stop 文件后通过 guest RPC 正常关机。首轮证据为 `cold-run.acMbD9pf/`，持久化复核为 `cold-run.jM0hDUCb/`。

| 范围 | 结果 | 证据 |
| --- | --- | --- |
| 实际组件与文件 | vphoned 摘要 `c04e362ae02b6b521bac06d1f2833850935e8e88ea121b8d7fd8fb139dd48593`；21 项环境库匹配候选，根只读 | 两次启动的 `summary.json`、`environment.json` |
| AX 安装与审计 | 36/36 实际文件匹配签名夹具，备份摘要均不变；生产审计器报告 36 项无剩余 X1，无扫描错误 | `installed-accessibility.json`、`installed-audit.json` |
| 收据迁移 | 35 项 AX＋HomePop 独立收据均 applied、pending=0；旧聚合收据已退役，remaining 保留独立归属 | `guest-receipt-patches.json`、`patches-after-update.json` |
| DriverKit | `driverkitd` 和 HID dext 运行，枚举到 Virtual USB Touch Screen；串口记录两项 HID driver `::start ... ok`，HID driver 崩溃数为 0 | `hid-driver-processes.json`、`driverkit-processes.json`、`input-devices.json`、`boot.log` |
| local pairing | 实际 `remotepairingdeviced` 摘要匹配签名候选；收据 applied | `summary.json`、`installed-remotepairingdeviced`；协议连接未覆盖 |
| 原生 VZ 触摸 | windowed 路径下合盖／展平各点左上、中央、右下按钮，共 6/6；App 计数、标识及 native touch 收据均匹配 | `native-input-app-geometry/summary.json`、`touches.json`；入口 `patch-port-native-input.mjs` |
| 原生 AX 命中 | Home／Settings、两面板及内屏旋转共 15/15；锁屏拒绝通过 | `ax-check-home-ready.log`、`ax-check-home-ready/hits.json`；入口 `three-issues-ax.mjs` |
| 应用观察 | KFC 15 秒内 PID 保持 877 且前台 verified；Food AI 返回 7 个 AX 元素；检查前后各 136 项崩溃报告，无新增或变更 | `app-check.log`、`app-check/`；不含登录、会员点击或下单验收 |

12 项调试库的读取、备份和生产审计由 `Regression/patch-port-debug-images.mjs` 保存为回归入口。首轮 `debug-images-authorized/` 证明每项实际文件已转换且备份可完整转换；严格签名的 framework 检查需要额外复制 Info.plist 和封装资源。仅复制 executable 的试验使三项 framework 报告 `invalid Info.plist`；这份不完整检查副本不能作为 guest 签名失败证据。第二轮补齐实际签名资源后，`debug-images-complete/` 的 12/12 严格签名及生产审计全部通过。原始 CodeResources 含 Data，`plutil` 直接转 JSON 的试验失败；脚本改用 Foundation 仅提取资源文件名，保留原签名断言。

### 保留的失败与验证限制

首次触摸最小复现中，宿主返回成功但按钮计数不变。截图确认前台出现 `Trust This Computer?`；AX 仍返回被遮挡 App 的按钮。通过原生宿主点击拒绝 Trust 后，同一中心按钮复现通过，未建立计算机信任关系。`trust/`、`tap-repro-host-1/`、`tap-repro-host-2/` 和 `tap-repro-after-deny/` 保留前后证据；可复现入口为 `patch-port-tap-repro.mjs`。

原触摸脚本把 AX 点乘 `UIScreen.scale=3`。展平后 App 为 669×951 点、native 2007×2853 像素，宿主截图／VZ backing 仍为 1398×2034。脚本已按宿主截图宽高与 App canvas 宽高的比例换算，保留 `native-touch-final/` 和 `native-touch-pixel-mapping/` 的失败。生产输入实现未修改。TapProbe 新增 UIKit `convertPoint` 测量的按钮窗口坐标；使用这些坐标的独立测试通过，不替代 AX 发现检查。

`patch-port-touch.mjs` 的 AX 发现断言仍失败：展平内屏的默认 `ui.tree` 连续 20 次只返回 `tap-0`、`tap-1`、`tap-3`、`tap-4`，缺少右列和底行；`native-touch-ready/` 保留失败。对照查询 `visible_only:false` 返回全部 9 个按钮，见 `ax-filter/`。代码事实：`GuestAPI+Input.swift` 的普通 App 查询转发至 IcliKit 可见性过滤；现有 `tapInterfaceElement` 已因 Main bounds 问题使用未过滤查询。该结果将遗漏限定到可见性过滤阶段；具体错误边界的原因仍待验证，本轮未修改 daemon，也未删除或弱化原断言。

首次广义 AX 回归停在 Home 第 3 页只有两个 App 图标，未满足三个目标的前提，见 `ax-check/ax-precondition.json`。切回第一页后原脚本和断言不变，15/15 及锁屏拒绝通过。TapProbe 通过 `apps.install` 安装及原数据容器内更新，仅证明输入与按钮行为，不计为 installd 验收；测试 App 和数据留在新副本。

两轮结束均使用 `patch-port-runtime-restore.mjs` 从首轮原始快照恢复合盖纵向、Auto-Lock 120 秒、锁屏和熄屏状态，核对低电量原值不变。首轮关机前还重新核对根只读、21 项库、AX／pairing 文件。两轮 `final-settings.log`、`shutdown.json`、`vm-exit-code.txt=0` 和空 `final-handles.txt` 保存正常关机结果；首轮补查为 `final-verification.log`。原副本未启动，新副本保留候选安装及 TapProbe，未推送或发布。

## TXM 独立恢复候选与批准门

准备阶段从停机的 `duo-patches-20261116` 创建新身份副本 `duo-txm-remap-20261116`，先仅修改其宿主固件文件和选择／计划。初次沙箱内 clone 报告 source running；提权重试后成功，当时未对任何 VM 发送信号。该信息与沙箱内 `ps` 权限拒绝同时出现，不能据此证明源 VM 在正常关机后仍运行。用户随后批准了该新副本的恢复及运行步骤，结果见下文。

候选启用 `txm-cfw-executable_remap`、关闭 `txm-exp-precheck_admission`。为匹配来源的实际启动链，另外关闭 `kernel-cfw-paravirt_gles_renderer`、`devicetree-cfw-homeview_touch` 和 `devicetree-cfw-virtual_usb_driverkit`；guest 的 Preboot DriverKit 修复仍在选择内。这是限定 TXM 差异的验收候选，不代表完整 standard 的运行验收。

离线 `fw patch` 成功。初次使用完整 standard 发现三个额外启动链选择，随后按来源关闭。第一次完整比较发现重新生成的 RestoreRamDisk 字节也有差异；原因未查明，产物保留为 `txm-candidate-reviewed/regenerated-RestoreRamDisk.dmg`，失败断言保留。为限定差异，将新候选的 RestoreRamDisk 换回来源副本中已存在的文件，没有修改来源文件。`Regression/review-txm-candidate.mjs` 的原断言随后通过：比较全部 125 项 IM4P／kernelcache／trustcache 加 RestoreRamDisk，共 126 个文件，只有 TXM 不同；启动链选择仅增加 native remap、删除旧 precheck。结果见 `txm-candidate-final/{artifacts,plan,summary}.json`。新 TXM 解包后与八组合测试中的 `txm-remaptrue.raw` 逐字节相同。

| 对象 | SHA-256 |
| --- | --- |
| 来源 TXM IM4P | `4cf7a717d3218be3c9c6abd19e7e069f6ef5cbe9ecced7498b77f9ddefc79c9b` |
| 新候选 TXM IM4P | `8242fca7d961da0116a99459dd5e4a0da455b2277c0f4aa77de79167eeaf13fd` |
| 新候选 TXM payload | `b47c65ba490ab28aaa2ef16d28d7cd75f3eb4181025572b28e92c796b480b761` |

当时提交的批准范围仅为 `duo-txm-remap-20261116`：DFU 启动、擦除恢复、停止该 DFU 进程、CFW 安装及之后的 native remap 运行验收。`restore` 会擦除这个新副本的数据；原始 VM、来源和已完成验收的 `duo-patches-20261116` 均不在目标内。该擦除动作按用户提供的 AGENTS.md 独立确认，用户随后已批准。

以下是提交审阅并在批准后执行的命令。第一条在独立终端运行，恢复完成后才停止该 VM 并安装 CFW；运行验收使用同一 Bundle，同一签名的重新准入仍在原授权范围内。

```zsh
bundle="$PWD/.build/duo-sync-20261113/XcodeBundle/Build/Products/Debug/VPhone.bundle"
library="$PWD/.build/duo-runtime-84e3ce54/machines"
"$bundle/Contents/MacOS/vphone-cli" vm launch duo-txm-remap-20261116 -l "$library" --dfu
# 另一个终端，等待 DFU 就绪后：
"$bundle/Contents/MacOS/vphone-cli" restore duo-txm-remap-20261116 -l "$library"
"$bundle/Contents/MacOS/vphone-cli" vm stop duo-txm-remap-20261116 -l "$library"
sudo "$bundle/Contents/MacOS/vphone-cli" cfw install duo-txm-remap-20261116 -l "$library" --keep-artifacts
```

### TXM 批准后的执行记录

用户已在审阅上述独立副本、擦除范围和命令后回复“批准”。本次批准持续覆盖该副本的 DFU／擦除恢复、停止、CFW 安装和 native remap 运行验收。此前未批准说明保留为当时状态，同范围不再请求授权。执行前 `txm-approved-review.log` 再次通过 126 项差异检查；宿主可用空间约 139 GiB。以下执行结果随实际进展更新。

DFU 启动生成新 ECID `0x0C5CF189506BC959`，`recovery-probe --ecid` 核对该端点后，恢复显式绑定同一 ECID。`txm-restore.log` 记录 `Restore Finished`、iOS 27.1 (24A94425)／cloudOS 26.4 (23E5207q) 和 102 项启动链补丁，命令退出 0；`txm-restored-patches.json` 含 `txm-cfw-executable_remap`，不含 precheck。随后按批准范围执行该副本的 `vm stop`，只发送 SIGINT，退出 0，见 `txm-stop-dfu.log`。

CFW 的 `sudo -n` 因缺少密码凭据退出，未开始安装；随后用 `txm-cfw-install.applescript` 调用系统管理员认证，同一命令显式设置 `SUDO_UID=501 SUDO_GID=20`。用户完成认证后继续同一会话，未重复启动安装。

已保存 `Probes/remap-probe/` 和 `Regression/txm-remap-runtime.mjs`。首次构建因 iPhoneOS SDK 的 `mach_vm.h unsupported` 失败；改用仓库既有探针采用的 `vm_remap`／`vm_region_64` API 后构建通过，格式告警已修正，App 产物为 `remap-probe-final/`。探针分别检查主 executable 和 embedded framework 的部分／完整 __TEXT、private／shared、anywhere／fixed overwrite 及 16 个保留 alias；每项同时读取实际 current／maximum、比较字节和执行目标函数，不使用权限修复来替代原结果。后续独立进程产物补充了 exec 启动和自身 executable 路径，最终为 `remap-probe-exec-identity/`。

签名条件单独记录：`vphoned_sign.m` 会在 `apps.install` 时为主 executable 加入 `jb.pmap_cs_custom_trust=PMAP_CS_APP_STORE`。运行回归将读取实际签名与 entitlement；另备 `run-no-custom-trust` 模式，只移除生成探针主 executable 的这个 entitlement，保持其余权限，并在新的 PID 中重跑。上游文档所述 CS_ADHOC standalone 注入限制保留为独立断言；本地是否出现及原因均须实际结果证明。该探针使用 `apps.install`，不替代 installd、CMS 热重载或真实配对协议验收。

宿主输入检查已通过：四项 external 产物的 CodeDirectory flags 分别为 ldid 0／Apple ad-hoc 2，构建时 App 不含 custom-trust，构建无告警，见 `remap-probe-final/input-check.json`。运行回归另读取了实际安装后的主 executable、framework 和外部文件签名，结果分轮保存。

用户回复“已认证”后，同一安装会话开始写入 `txm-cfw-install-approved.log`，共享缓存 X1 bootstrap 转换报告 228,314 条指令。`txm-restore.log` 明确记录向目标发送 `Firmware/txm.iphoneos.research.im4p`；实际 Preboot 文件已在运行结束后另行核对。

安装随后成功退出 0，记录 `CFW system install complete`；日志没有 `[!]`、`failed` 或 `Error:`，见 `txm-install-summary.json`。`txm-after-cfw-patches.json` 核对 remap 的 enabled/planned/applied 均 true、precheck 均 false，二者 pending=false。

冷启动入口 `duo-txm-remap-20261116-cold-run.fJ02ZEet/` 在 host preflight 阶段拒绝同一 CDHash `a91b9e15f38c734d76d3d92a2c8e58ff83782ed8`，没有启动 VM，原因未查明。依据原先对同一签名的有效授权调用 `txm-amfi-readmit.applescript`，用户完成系统认证。日志报告 cdhash 已在持久化列表中、未重写该 plist，amfid 重新采用 requirement；随后预检通过。没有重做 CFW 安装，也没有再次请求执行批准。

### TXM 最终运行结果

首轮为 `duo-txm-remap-20261116-cold-run.YLPF1DxY/`，第二轮为 `duo-txm-remap-20261116-cold-run.hl5wJUf9/`，均位于 `.build/upstream-port-20261116/`。

| 范围 | 结果 | 证据 |
| --- | --- | --- |
| 实际启动与环境 | 两次连接 iOS 27.1.0；vphoned 保持 `c04e362a…`，21 项库匹配、根只读，DriverKit dext 和 USB Touch Screen 存在 | 首轮 `ready-verification/`、第二轮 `summary.json` 及环境／进程记录 |
| AX／pairing 安装 | 每轮 36/36 AX executable 匹配候选、原备份不变、生产审计无剩余 X1；pairing executable 摘要匹配 | 两轮文件检查；协议连接不在该项结果内 |
| 默认 App 签名的 remap | PID 745，20/20 case、80 个 alias，实际 current=5、字节相同、调用及保留 alias 再调用通过 | 首轮 `remap-default/{report,summary,installed-signatures}.json` |
| 移除 custom-trust 的 remap | 同一 App 仅移除该 entitlement 后 PID 774；冷启动后 PID 494；两轮各 20/20、80 个 alias，实际 current=5，调用通过 | 两轮 `remap-no-custom-trust/`；main／framework 均 flags=0、无 CMS |
| 外部 dylib 加载 | 每轮 ldid flags=0 与 Apple ad-hoc flags=2 两个库均执行构造器并返回 73，实际 current=5／maximum=7 | 各 App 报告的 `libraries` 与 `external-signatures.json` |
| 独立进程注入 | 经生成的 flags=0 启动程序设置环境并 exec，两种独立签名目标均构造器=1、返回 73、exit=0，自报 executable 路径匹配；两轮通过 | 两轮 `standalone-exec-identity/`；入口 `txm-standalone-runtime.mjs … exec-env` |
| 临时作业清理 | 每次 launchd 检查均卸载全部本次作业，最终 loaded=false | 对应 `results.json` 的 unload／finalStatus |
| 实际 TXM 字节 | Preboot IMG4 中的完整 IM4P 与候选逐字节相同；payload 同为 `b47c65ba490ab28aaa2ef16d28d7cd75f3eb4181025572b28e92c796b480b761` | `installed-txm-verification/report.json`；不是只依据收据判断 |
| 设置与关机 | 两轮按首个稳定快照恢复合盖纵向、Auto-Lock 300 秒、锁屏／熄屏、低电量原值；VM 退出 0，状态句柄为空 | 两轮 `final-settings.log`、`shutdown.json`、`vm-exit-code.txt`、`final-handles.txt` |

App 的 `vm_remap` 符号解析到实际已核对摘要的 `SystemHook-vphone.dylib`。该库现有 repair 只接收同一 App 中的 `App.framework/App` → `Flutter.framework/Flutter`、32 KiB 等完整条件；本探针主 executable／RemapFixture 不满足路径条件。代码选择条件支持这些结果没有使用该 Flutter repair；本轮未修改 SystemHook 或 daemon。

以下失败保留，不能把整个 App 运行脚本的退出码写为通过：

- 首次启动在 uptime 20 秒后的 `display.pose` 请求超时；随后原请求成功，首轮 `ready-verification/` 和第二轮完整检查通过。原因未查明。首轮 driver 因保留的 `check-failed` 返回 1，而实际 VM 正常退出码为 0。
- 新副本当时仍在 Setup Assistant，`data_migration_done=true`。使用项目 `setup.skip` 完成运行准备并重启 SpringBoard，状态变为 pending=false；没有账号登录或建立电脑信任关系。
- App 的直接 `posix_spawn` 对两种目标均返回 EPERM，未创建进程。`txm-remap-runtime.mjs` 的原独立进程断言仍失败，三份完整日志退出 1；原断言没有删除或弱化。该结果不证明 TXM 已拒绝这些目标。
- 第一份直接 launchd plist 的两个目标运行但均找不到注入符号；服务描述中无 DYLD_INSERT_LIBRARIES，未保留该环境输入的位置原因未查明。`standalone-launchd/` 保留失败。改用独立生成的启动程序在 exec 前设置输入后，两个目标均实际注入并完成调用。首次脚本相对路径在 chdir 后解析失败，保留 `standalone-exec-env.log`；修正为 chdir 前解析后运行，原断言通过。

只读文件核对在第二轮正常关机后进行：hdiutil 以 readonly／nomount 连接该新副本，确认其 APFS Preboot 后只读挂载。`mounted-volume.plist` 的 Writable、WritableMedia、WritableVolume 均 false。从 `usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4` 复制输入，`Regression/VerifyInstalledTXM.swift` 使用生产 Img4tool 解包并比较。该卷及本次连接已卸载，前后镜像清单完全相同，见 `installed-txm-verification/cleanup.json`。

本轮通过范围为已记录的原始主程序／framework 代码 remap 和简单构造器／导出注入。没有验证修改后私有代码、inline hook、所有系统映射、CMS／真实 profile 热重载或所有第三方 injector；这些结果不否定上游文档中的其他 standalone 兼容性限制，也不证明 stock-iOS 策略等价。LLDB、真实 local pairing 协议及内屏 AX 可见性过滤问题仍单独保留。新副本保留生成的探针、文件和完成 Setup 的状态；来源及已验收的旧副本未启动，未推送或发布。
