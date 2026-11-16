# AX 可见性修复、App spawn 取证与鼠标模式回归

2026-11-16。用户在组合验收后要求继续推进后续。工作对象仍为 `duo-overall-20261116`，宿主使用冻结 2.18.0 VM；没有新增 AMFI 准入、环境安装、擦除恢复、来源副本操作、推送或发布。

证据目录：`.build/overall-port-20261116/cold-run.qYvDOWMq/`。以下命令相对于仓库根目录；运行入口中的 socket／输出路径使用绝对路径。旧 daemon SHA-256 为 `612828f62fd75b5f8901c04c47228a18119295849a352c0a1ff08bf41cc13933`；候选为 `a4860c0c5b0b630155228d2d53183831b73c69099a8cd4b3e0909c92711a0a6f`，副本保存为该目录的 `vphoned-ax-candidate`。

## AX 最小复现和原因

`Regression/ax-visible-repro.mjs <socket> <new-output> <daemon-sha256>` 在展开纵向的 TapProbe 中只比较默认查询和未过滤查询，不依赖实际点击来判断发现结果。原 daemon 的三个采样均为未过滤 9、默认 4，退出 1；`ax-visible-before.log` 保留原断言和五个缺失 identifier。App 自测报告 canvas 为 669×951 点；缺失按钮右列的 frame x≈499.2，底行 y=728，均超出 Main 的 466×678 范围但位于 App 内。

定位前列出并区分三个假设：Main 边界裁剪、AX 提供者可见性错误、daemon 二次过滤／坐标错误。固定依赖的 `IcliPrivate/Accessibility.m` 用 `icli_screen_metrics()` 的矩形与 frame 求交生成 `visible`，`IcliKit/Input/Screen.swift` 随后直接按该标记过滤。该可见性字段由桥接层几何计算生成，并非读取 App 的隐藏标记。daemon 对普通 App 原先直接返回 IcliKit 的过滤结果。该路径的几何范围解释了本轮五个缺失按钮，默认过滤的失败已被真实派发回归重现。

修改 `GuestAPI+Input.swift`：仅对双显示的普通 App，先读取完整 App 坐标空间，再查询未过滤元素，使用已有 `GuestElementTap.visible` 按 App 边界计算字段，最后依次执行 visible／clickable／limit 过滤。查询前后核对 PID、verified 前台、面板／方向与 App frame；未知、非零 origin 或变化状态拒绝并要求重试。保留 AX frame／激活点，单显示与 SpringBoard 路径不变。小于面板的兼容画布按 App 自身范围判断，不按整个内屏扩大。

`ElementTapAPITests.swift` 加入实际九按钮布局与兼容画布用例。测试边界 double 补齐原 IcliKit 已有的 count／clickable／limit 语义，避免把 double 的缺失误判为生产缺陷。准确 double 下的旧实现为 244 项、2 失败；修改后为 244 项、0 失败。原生 display／context／AX hit 及 31 项几何检查同时通过。未删除或弱化旧断言。

## 构建与实际验证

```zsh
zsh VPhoneDaemon/Tests/run-element-tap-tests.sh
zsh VPhoneDaemon/Tests/run-point-geometry-tests.sh
zsh VPhoneDaemon/Tests/run-result-schema-check.sh --icli .build/duo-sync-20261113/XcodeBundle/SourcePackages/checkouts/icli --method ui.
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/duo-sync-20261113/XcodeBundle -disableAutomaticPackageResolution -jobs 4 build
```

完整 Bundle 构建、深度严格签名和 UI 返回结构检查通过。返回结构检查首次在受限缓存环境失败，原日志 `ax-result-schema.log` 保留；正常构建权限下的 `ax-result-schema-escalated.log` 退出 0。

`ax-agent-update.mjs` 校验当前 hash、保存更新标记和环境状态，向缓存上传候选，通过 `agent.apply_update` 切换 worker 116→2872；没有替换 `/usr/bin/vphoned` 或环境库，根只读保持。实际验证：

| 检查 | 原 daemon | 候选 daemon |
| --- | --- | --- |
| 最小默认 AX 查询 | 4／4／4，未过滤均 9，失败 | 9／9／9，未过滤均 9，通过 |
| 原 `patch-port-touch.mjs` | 组合验收中内屏 tap-8 缺失 | 两面板六次实际按钮回执通过 |
| `three-issues-ax.mjs` | 原组合验收 15/15 | 15/15，锁屏拒绝通过 |

最小复现、原始实际点击及 API 单元回归均通过，才将该项记为修复。实际候选验证是同次启动中的 worker 更新，没有执行候选 daemon 的独立冷启动。未将范围扩大到嵌套 AX 层级、SpringBoard 默认可见性或所有 App 的通用坐标行为。

## App posix_spawn 的直接证据

`remap-spawn-observe.mjs <socket> <new-output> <daemon-sha256>` 不改变现有 RemapProbe 的签名或策略；启动新的 PID，并在同一窗口捕获只含该探针名称的统一日志。PID 2927 的完整报告仍为 20/20 remap、两种 standalone 的 `spawnError=1`。同一 PID 的内核日志包含：

```text
Sandbox: RemapProbe(2927) deny(1) process-fork
1 duplicate report for Sandbox: RemapProbe(2927) deny(1) process-fork
```

报告和 6 条非截断日志保存于 `spawn-observe/`，原 App 直接 spawn 断言退出 1。该次失败已经取得 App 沙盒拒绝派生进程的直接证据，不能将它当成 TXM 原始代码 remap 的失败。先前独立 launchd 受控 exec 的通过仍是另一种执行上下文，不替代 App 内派生进程的验收。本轮没有移除沙盒、增加权限或修改 TXM。

## 鼠标模式回归

新增 `VPhoneExecutable/VPhoneVirtualization/Tests/run-mouse-mode-tests.sh`。按项目已有 host 测试方式编译真实 `VPhoneGuestMouseMode`、菜单处理方法和 pointer policy；AppKit 菜单项使用真实类型，VM view／guest connection 作为边界 double。测试在 `.build/mouse-mode-tests/host-home` 的隔离偏好目录运行，覆盖默认／非法偏好、两模式菜单单选、视图更新、16 组显式策略表、缺少 control，以及新进程读取持久化 Touch。通过结果保存为 `mouse-mode-table-tests.log`，入口接入 `build.yml`。

该测试不创建 VM，不验证真实鼠标移动、捕获／释放、滚轮、跨窗口通知或 iPad pointer 外观。当前 Duo 报告 iPhone19,4；生产非捕获 pointer 路径要求 `isPadGuest`，因此需要独立 iPad guest 补齐实际指针工作流。

## 恢复和后续

候选测试结束后通过同一更新入口恢复原 daemon：worker 2872→2963，hash 回到 `612828…`；更新标记与切换前逐项相同，21 项环境库及 root_read_only 状态完全不变。恢复合盖纵向、Auto-Lock 300 秒、锁屏／熄屏与低电量原值；再次执行基础检查核对原 daemon、36 项 AX 文件／备份、pairing 文件、DriverKit 和根只读。

随后正常关机，`vm-exit-code.txt=0`，`final-handles.txt` 为空；结束时再次检查目标状态文件无打开句柄。本轮没有建立磁盘挂载。

后续保留：独立 iPad 指针／滚轮／窗口流程，显示内容方向像素验证，LLDB、CMS／真实 profile、local pairing 协议、旧固件和独立环境。App 派生进程的失败保持原记录；需要另行设计具备所需执行上下文的验收，不能通过取消现有断言计为通过。
