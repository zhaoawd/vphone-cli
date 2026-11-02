# Duo ui.tap_element，2026-11-02

基线：`duo-integration-20261030`，`2bf30031`。本次改动仅保留在该分支。
历史现象见 `WINDOWED.md` 的 F2 keyboard modes：内屏元素中心 y=124，
注入后约为 174，未命中 y=102–146 的输入框。

## 原因与修复

固定依赖为 icli 0.10.0，提交 `2fbdb5ee61d8c320732deb9768b22506f5e3d411`。

1. `tapElement` 把 AX 激活点直接交给 `tap`。`icli_screen_point_to_digitizer`
   用主屏截图的固定尺寸归一化。Duo 内屏有独立的点尺寸；FoldDisplayBackboard
   把同一归一化 digitizer 的事件路由到已点亮的内屏。因此，内屏 AX 点按主屏
   尺寸归一化后，在内屏产生偏移。
2. `selectedElements` 调用默认 `visibleOnly=true` 的 `uiElements`。
   `Accessibility.m::serializeElement` 用同一主屏尺寸判断 frame 可见性。
   内屏超出主屏范围的元素可能在选择前被过滤。
3. SpringBoard AX 使用固定坐标。icli 先按主屏尺寸把它转换为界面坐标。
   普通 App AX 已使用界面坐标。两者需要分别转换。

修复读取 `CADisplay` 中 `VPhone Duo Inner` 的实际 `displayState` 和 bounds /
pointScale。内屏状态为 1 时使用内屏尺寸，为 0 时使用 Main 尺寸。
该状态来源与 `FoldDisplayPanel.m` 一致，不使用铰链请求值推定当前显示屏。
每次枚举前按 `vp_display_modes` 的流程调用 `updateDisplays`。新增的原生
测试模拟首次枚举没有内屏、刷新后才出现内屏；缺少该调用时测试失败。
没有该内屏的设备沿用原路径。

Duo 路径读取未过滤的 AX 元素，在活动显示屏范围内判断 frame 可见性，保留
icli 0.10.0 的 text / identifier / role / match / index 选择规则。SpringBoard
坐标先撤销 icli 的主屏转换，再按活动显示屏转换。激活点最终转换为固定、
归一化 HID 坐标，通过一次 `touchSequence` 发送 down / up。
查询前后核对显示屏、尺寸、方向和前台 App；变化时拒绝点击。实现没有缓存
显示屏尺寸，也没有固定的内外屏缩放比例。

## 离线验证

```zsh
zsh VPhoneDaemon/Tests/run-element-tap-tests.sh
zsh VPhoneDaemon/Tests/run-logic-tests.sh
zsh VPhoneDaemon/Tests/run-hierarchy-tests.sh
```

- 使用基线的真实 `GuestAPI+Input.swift` 编译 API 边界测试，初版测试为
  199 项检查、53 项失败。依赖替身复现 icli 的主屏归一化，未运行 iOS。
- 修复后：原生显示读取检查通过；31 项几何检查通过；206 项 API 检查通过。
  API 检查执行修改后的实际 `GuestAPI.executeInterface`，覆盖内外屏、四个
  旋转方向、同一进程中的折叠往返、App / SpringBoard、主屏范围之外的元素、
  选择规则、查询期间状态变化、查询截断及 HID 失败。
- 原有 daemon logic：394 项检查通过。原有 hierarchy 检查通过。
- 修改后的真实 iOS daemon 已使用固定依赖构建通过。
- 完整 `VPhone` bundle 构建通过，`codesign --verify --deep --strict` 通过；
  iOS / tvOS daemon、宿主程序、guest 组件和 bundle admission 均经过构建流程。
- TapProbe 的独立 device 构建通过。原有全量 probe 构建在本机 Xcode 26.4
  缺少 `UIViewReservedRegion` 等 API；本次没有修改这些已有 probe。

构建及完整测试日志保存在 `.build/duo-element-tap/`。离线替身不能证明实际
CADisplay / AX 坐标行为，也不能替代真实 VM 点击验收。

## 真实 VM 验收

用户已授权在本机创建独立 Duo VM。当前本机测试 VM 为 iOS 26.1 单屏，历史
`/Users/kolar` 的 Duo VM 不在本机。仓库登记的 Duo 固件 URL 已返回 HTTP 200，
大小 12,724,731,538 字节。候选 bundle 已构建通过；原生创建流程已建立
`duo-tap-20261102` 的测试目录，正在准备固件。

候选位于 `.build/XcodeElementTap/Build/Products/Debug/VPhone.bundle`。
构建开始于提交前，`VPhoneBuildHash` 为 `2bf30031-dirty`；本次 daemon 源码已
提交为 `58b0ac25`，文件摘要保存在 `.build/duo-element-tap/daemon-sources.sha256`。
候选二进制的 SHA-256：

| 对象 | SHA-256 |
| --- | --- |
| vphone-cli | `ab47ea426755d3e91adc22c6aced102684321ae92beebea91b4422afb1b26f98` |
| vphone-vm | `2bc186ad3099cd896bc3df67fbd55730ef684019c75581969a4d534108c1d9e7` |
| guest-resources/vphoned | `da25f357917c4b354b886cc32fd6abb1ce2285e5c8cc134803783bd74431f1ff` |

首次创建在 AMFI 预检被拒绝，沙箱外复验相同。使用捆绑 `vphone-escalator`
放行该 VM 的 CDHash `ab062006f60c1d8c16b47c23af45bc5be9796909` 后通过。
版本发现请求超时，后续改用上述明确的 iPhone URL 和配套 cloudOS 26.4 beta URL。

探针与命令：

```zsh
zsh Research/Integration/duo_m5_20261030/Probes/build.zsh device \
  .build/duo-element-tap/tap-probe-new tap
# 在独立 Duo VM 安装生成的 TapProbe.ipa 并启动同版候选后：
zsh Research/Integration/duo_m5_20261030/Regression/element-tap.zsh \
  <独立测试VM目录>/vphone.sock <新的证据目录>
```

脚本在同一次 App 进程中执行 closed / open-flat / closed / open-flat /
partially-open / closed；每个阶段请求四个旋转方向，点击分布于屏幕的九个
按钮。每次比较 App 持久化的 `last_identifier`、总事件计数和对应按钮计数。
RPC 成功不能替代这些 App 后置条件。已有上游限制拒绝的旋转方向单独记录，
不计为通过；其他错误使脚本失败。最终要求至少两组不同的 App 场景尺寸。

状态：真实 VM 内外屏、旋转及折叠后的元素点击仍待验证。本节需要补充 VM
创建、候选二进制摘要、guest receipt 和运行结果后才能关闭。
