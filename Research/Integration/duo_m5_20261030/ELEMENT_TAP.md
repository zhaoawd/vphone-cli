# Duo ui.tap_element，2026-11-02

基线为 `duo-integration-20261030` 的 `2bf30031`。上下文点击提交为 `f9489f2a`，
窗口画布修复为 `e2d1905f`；
前序提交记录显示枚举、权限和共享比例的修复。本次改动保留在 Duo 分支。

## 问题与证据

历史现象见 `WINDOWED.md` 的 F2 keyboard modes：内屏元素中心 y=124，
注入后约为 174，未命中 y=102–146 的输入框。固定依赖为 icli 0.10.0，
提交 `2fbdb5ee61d8c320732deb9768b22506f5e3d411`。

| 问题 | 证据 | 修复 |
| --- | --- | --- |
| 激活点按 Main 尺寸归一化 | icli `tapElement` 把 AX 点交给 `tap`；其 digitizer 转换使用 Main 截图尺寸。Duo 外屏为 466×678 pt，内屏为 669×951 pt | 在元素所属的 AX 窗口上下文中发送点击 |
| 内屏边缘元素提前被过滤 | icli 默认可见性判断使用 Main 范围 | Duo 查询未过滤的元素，按活动显示屏或 App AX 画布判断可见性 |
| SpringBoard 坐标经过 Main 方向转换 | icli 对 SpringBoard 固定坐标先应用 Main 的旋转尺寸；普通 App 保留自身 AX 坐标 | SpringBoard 点击前撤销该转换，恢复原始 AX 点和 frame |
| daemon 无法读取实际内屏状态 | 本机 VM 中，缺少 `com.apple.QuartzCore.display-state` 时 `stateControl` 为 nil；加入后可读关闭 0、开启 1 | 加入该权限；使用实际 CADisplay 状态，不以铰链请求值推定屏幕 |
| 内屏枚举和比例与普通 client 不同 | 内屏可在首次枚举后注册；普通 CADisplay client 报 pointScale=1，FoldDisplay 的既有配置为 3 | 每次读取先 `updateDisplays`；将既有比例提取为共享常量 `VPhoneDuoInnerPointScale` |
| 兼容布局还包含场景宿主变换 | SDK 26.4 声明的探针在内屏保持 375×667 画布；手工映射通过平展场景后，在半折叠横向场景未产生目标按钮事件 | 移除兼容布局比例和居中拟合，使用 AXElement 的上下文点击 |
| UIApplication frame 与实际窗口方向不同 | 原生内屏横向场景中，UIApplication AX frame 为 669×951，UIWindow 和按钮坐标为 951×669，基于前者的校验拒绝右侧按钮 | 从 AX immediate children 读取实际窗口画布，不再用 UIApplication root frame 确定坐标范围 |

最后一项通过隔离探针复核：半折叠、landscape-left、375×667 画布中，
`simulateTapWithFingerIndex:withPoint:` 接收 AX 点
`{187.66666666666669,331.5}`，App 收到相同的结束触摸点，`tap-4` 计数增加。
证据为 `.build/duo-element-tap/ax-context3{,-counts,-touch}.json`。
这是实际触摸验证，没有采用 AXPress 替代按钮事件。

## 实现

`GuestAPI+Input.swift` 保留 text、identifier、role、match、index 选择规则。
查询前后核对前台 App、显示屏、尺寸、方向和 AX 窗口画布；状态变化时拒绝
点击。非 Duo 设备继续使用原 icli 路径。

`vphoned_element_tap.m` 重新查询原始 AX 元素，以 frame、identifier、label
核对所选元素。相同 CF 身份的重复项去重；不同身份具有相同匹配字段时拒绝
点击。查询超时、元素变化、无效几何或发送失败均返回错误。

发送前检查运行时方法 ABI。包装器使用接收原始 AX 指针的
`elementWithAXUIElement:`，随后调用
`simulateTapWithFingerIndex:withPoint:`。系统据元素上下文处理场景缩放、
位置和半折叠投影。实现不再拟合兼容布局偏移。

共享比例只提取 FoldDisplay 已有的值 3，没有新增固件指令补丁、预设或
启动链补丁。补丁范围同步记录在 `Research/0_binary_patch_comparison.md`。

## 离线验证

```zsh
zsh VPhoneDaemon/Tests/run-element-tap-tests.sh
zsh VPhoneDaemon/Tests/run-logic-tests.sh
zsh VPhoneDaemon/Tests/run-hierarchy-tests.sh
```

- 初版 API 边界回归编译基线真实 `GuestAPI+Input.swift`：199 项检查、53 项
  失败，复现内屏主屏归一化及可见性问题。
- 最终元素点击回归：原生显示读取检查、AX 上下文 ABI / 身份 / 歧义 / 发送
  失败检查通过；31 项几何检查、218 项 API 检查通过。
- 原有 daemon logic：394 项检查通过；hierarchy 检查通过。
- 完整 `VPhone` bundle 构建通过，涵盖 iOS / tvOS daemon、宿主和 guest
  组件；完成 `StageBundle.sh` 后，bundle admission 及 deep / strict
  签名检查通过。

日志位于 `.build/duo-element-tap/`：`baseline-tests.log`、
`window-canvas-red.log`、`window-canvas-green.log`、`logic-tests.log`、
`hierarchy-tests.log`、`build-window-canvas.log`、`restage-window-canvas.log`。
窗口画布回归在修复前的 951 pt 宽度断言失败，修复后通过。
增量构建曾在签名后重写 Info.plist，
本次使用仓库现有 StageBundle 流程重新部署并验签，没有改动构建脚本。

## VM 与实验设置

本次新建独立 VM `duo-tap-20261102`，库路径为当前 worktree 的
`.build/duo-element-tap/machines`。配置为 `vresearch101`、iPhone19,4，
外屏 1398×2034 @3，8 CPUs、8 GiB RAM。固件为 iOS 27.1 `24A94425`，
配套 cloudOS 26.4 beta `23E5207q`。DFU restore、CFW 安装、首次设置和
数据迁移均已完成。安装日志为 `cfw-install-final.log`；补丁收据保留在 VM。

候选包为 `.build/XcodeElementTap/Build/Products/Debug/VPhone.bundle`，
`VPhoneBuildHash=e2d1905f-dirty`。签名时的未提交改动仅为研究文档。
实际运行 daemon 的摘要由 `device.info.agent.binary_hash` 回读核对。

| 对象 | SHA-256 |
| --- | --- |
| vphone-cli | `ab47ea426755d3e91adc22c6aced102684321ae92beebea91b4422afb1b26f98` |
| vphone-vm | `2bc186ad3099cd896bc3df67fbd55730ef684019c75581969a4d534108c1d9e7` |
| vphoned | `01a91633d38dfba795ec966879f158835fe794e12c24a21dc094ae32165b5562` |
| 兼容布局 TapProbe.ipa | `703b55d06658c03a918ad45531ae3ee81b0b0a317453bc0f558a22e2c76798fd` |
| 原生布局 TapProbe.ipa | `54fb82d017dd082dad9e7994d4d720e8ba8d41743ec0038324d7952bc565893a` |

AMFI 放行仅针对本次捆绑 `vphone-vm` 的 CDHash
`ab062006f60c1d8c16b47c23af45bc5be9796909`，使用捆绑 escalator 执行。
未修改 SIP 设置。VM 保留供复查。

两份 TapProbe 使用同一源码，均由本机 Xcode 26.4 的编译器及 SDK 头文件
构建。第一份保持 SDK 26.4 声明，形成 375×667 兼容画布；第二份签名前将
`LC_BUILD_VERSION` 的 SDK 声明改为 27.1，触发原生面板布局。
该设置验证 UIKit 的 SDK 兼容策略，不证明已使用 SDK 27.1 头文件或新 API。
构建方法及限制见 `Probes/README.md`。

```zsh
zsh Research/Integration/duo_m5_20261030/Probes/build.zsh device <新目录1> tap
zsh Research/Integration/duo_m5_20261030/Probes/build.zsh device <新目录2> tap 27.1
# 分别安装对应 IPA，再运行：
zsh Research/Integration/duo_m5_20261030/Regression/element-tap.zsh \
  <VM目录>/vphone.sock <新证据目录> compatibility
zsh Research/Integration/duo_m5_20261030/Regression/element-tap.zsh \
  <VM目录>/vphone.sock <新证据目录> native
```

探针通过 `apps.install` 安装；本次不构成 installd 安装路径验收。

## 点击验收方法与结果

每轮在同一 App 进程内执行 closed / open-flat / closed / open-flat /
partially-open / closed。每个阶段请求四个方向，对支持的方向点击九个按钮。
每次必须满足同一 PID、目标按钮计数增加 1、总计数增加 1、最后按钮身份
一致，且 App 收到的结束触摸与 AX 激活点在各轴上的误差均不超过 1 pt。

脚本回读 CADisplay 的实际内屏状态，轮询 SpringBoard 的实际界面方向，
并记录 App 场景方向和尺寸。兼容 App 在旋转内屏上可以保持自身纵向画布。
旋转命令回执中的截图度量曾保留上一次方向，故验收使用
`display.orientation` 的 `source=springboard` 回读，而非仅检查该回执。

上游宿主控制明确拒绝物理 upside-down orientation：外屏对应请求
`upside-down`，内屏对应 `landscape-right`。这些拒绝单独记录，不计为点击
通过。其他错误会终止验收。

最终候选 `e2d1905f` 的两轮矩阵均通过；同一 daemon 摘要在每轮前后保持
一致。每轮 PID 不变，每个按钮增加 18 次动作，总计增加 162 次。

| 实验设置 | PID | 外屏纵向场景 / pt | 内屏纵向场景 / pt | 点击结果 |
| --- | --- | --- | --- | --- |
| SDK 27.1 声明、原生布局 | 498 | 466×678 | 669×951 | 162/162 |
| SDK 26.4 声明、兼容布局 | 627 | 375×667 | 375×667 | 162/162 |

共 324 次按钮动作和 324 份结束触摸收据。报告的触摸坐标与 AX 激活点的
最大各轴数值误差为 `5.684341886080802e-14 pt`，满足各轴不超过 1 pt 的
验收条件。两轮分别有 6 次明确的方向拒绝，共 12 次，未计入通过数。
内屏旋转后的原生窗口画布、保持纵向的兼容画布、半折叠横向和折叠返回均
经过上述按钮事件和坐标校验。

完整原始证据分别位于 `.build/duo-element-tap/window-native-final/` 和
`window-compatibility-final/`。每个目录保存请求回执、点击前后计数、触摸
收据、实际方向、显示状态、驱动脚本、`summary.json` 和 `evidence.sha256`。
[结构化结果](element-tap-results-20261102.json) 保存候选摘要、探针摘要、
两轮结果及原始证据清单摘要。早期失败或不同候选的运行没有计入最终结果。

## 未验收范围

此前 SpringBoard 图标补充验收未通过前台识别前置条件，未完成图标点击。当时 VM
主页的原始 `frontmostApp` 回报 `verified=false`、`source=unavailable`，
RunningBoard 为 `reason=no_focal_app`、16 handles、5 states，并有隐藏的
`com.apple.DocumentManager.DockFolderViewService` focal 服务。

固定依赖的原有 `frontmostPID()` 要求 `verified=true`。未修改的 `ui.tree`
因此同样报 `frontmost application could not be verified`。本次点击入口的
前台校验也拒绝该状态，没有将该结果计为坐标转换通过。证据为
`springboard-description.json`、`springboard-tree-refusal.json`、
`springboard-tap-refusal.json` 和 `springboard-final/`。主页前台识别需要
单独处理；下文记录后续代码修改及本地测试，尚未完成该修改的 VM 验收。

本次真实验收使用一台独立 Duo VM 与 TapProbe，不构成所有第三方 App 的
兼容性验收。VM 验收后正常停止，磁盘、补丁收据及本地证据保留。

## 主页前台识别与自动锁屏修改（2026-11-02，本地测试通过，VM 验收待完成）

主页验收记录确认 `no_focal_app` 阻断了前台校验。`bbc9a40d` 在
`GuestFrontmostApp.swift` 中增加系统外壳回退：原结果指向 SpringBoard/PineBoard、
原因是 `no_focal_app`、RunningBoard 句柄数大于 0、设备未锁屏且屏幕开启、
进程 PID 有效时，返回 `verified: true` 和该 PID。AX 查询与层级查询使用该 PID。
这项判定的真实系统行为尚未验收，不能将此前的 324 次 App 点击结果用于证明它。

`c742a06a` 将自动锁屏设置改为直接更新 `UserSettings.plist` 和
`EffectiveUserSettings.plist`，将 0 映射为 `Int32.max`，按条件移除
`rangeMinimum`，发送 Darwin 通知，并保留 `SBMinimumLockscreenIdleTime` 联动。
此前请求 1800 秒或 Never 后仍回读 300 秒，且观察到一次 300 秒锁屏
（`F6.md`）。原因未查明。旧实现向绝对路径域调用 `writePreference` 并补写
`rangeMinimum: 120`，但现有记录不足以确定 cfprefsd 落盘、profiled 合并或范围限制
中哪个环节造成该现象；这些解释均为待验证假设。不能据此认定 CFPreferences
无法写磁盘文件。

### 评审后修改

- plist 读取或解析错误会向调用方返回错误；仅文件不存在时允许创建空配置。
  同时检查根对象、`restrictedValue` 和 `maxInactivity` 的字典类型。
  两份输入均读取、校验、序列化后才开始写入，避免第二份输入无效时已改写第一份。
  每个文件单独原子写入，两次写入不构成跨文件事务；写入阶段的部分失败仍可能留下不同步状态。
- 单显示 SpringBoard/PineBoard 点击只选择可见元素，保持原选择器的可见性范围。
- `GuestAPI+AutoLock.swift` 承载 `display.auto_lock.set` 的实际请求处理函数，
  支持 `never: true` 与 `seconds: 0`，拒绝布尔值、非整数、字符串及越界秒数。

### 本地回归证据

日志目录为 `.build/review-followup-20261102/`，脚本命令均在仓库根目录执行。

| 命令 | 结果 | 验证范围 |
| --- | --- | --- |
| `zsh VPhoneDaemon/Tests/run-element-tap-tests.sh` | API 236 checks，0 failures；原生显示、AX context 和 31 项几何检查通过 | 新增 3 项断言，先在旧实现复现失败，再验证不可见同名元素不参与选择、不可见目标不注入触摸 |
| `zsh VPhoneDaemon/Tests/run-auto-lock-tests.sh` | 81 checks，0 failures | 真实临时 plist 读写；两份配置中的 `rangeMinimum: 120`；0/60/1800 秒；其他字段保留；读取、解析和类型错误时两份文件不变；实际请求处理函数的 Never、0 和非法参数 |

修复前，新增的自动锁屏回归产生 25 个失败断言，点击回归产生 3 个失败断言；
日志为 `auto-lock-before.log`、`element-tap-before.log`。修复后日志为
`auto-lock-after.log`、`element-tap-after.log`。

SpringBoard 前台识别及 Swift API 测试使用 IcliKit/VphonedNative 替身，
不验证 guest 的 sysctl、进程路径、AX 动态符号或图标点击。自动锁屏测试使用
IcliKit 偏好写入替身，不验证通知送达、SpringBoard 采用设置、profiled 后续合并、
重启持久性或实际计时。`SBMinimumLockscreenIdleTime` 开启 Never 后要到下一次
SpringBoard 启动才作用于锁屏界面，见 `Research/Guest/lock_screen_idle_timer.md`。

### 待完成的 VM 验收

在独立 VM 中部署本轮构建的 daemon，记录二进制摘要和系统版本后，验证主页
`ui.tree`、`ui.element_at`、图标点击及锁屏/熄屏拒绝；验证自动锁屏设置的即时回读、
实际倒计时、Never 超过原 300 秒仍不自动锁屏，以及 profiled 更新和重启后的值。
以上项目在本轮尚未执行。
