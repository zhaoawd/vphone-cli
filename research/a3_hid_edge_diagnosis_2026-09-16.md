# A3：系统手势接收与 HID 边缘类型对照

后续进展：正式宿主/客户机边缘传递修复及实机矩阵见 [A3 验收记录](a3_touch_acceptance_2026-09-16.md)。下文保留定位阶段的原始结果，不代表最终状态。

日期：2026-09-16。仅操作 `vm-2607-rig2`，26.1 / 23B85 EXP，1290×2796，简体中文。宿主 PID 1331。证据目录：`research/artifacts/rig2-setup-20260916-201333/`。主 VM 未收到控制请求或 UI 操作。

## 结果

当前客户机路径的应用内上滑在 UIKit 的边缘类型检查处失败。原事件被观测为 `UITouch._edgeType=0`、`_edgeAim=0`；同一坐标并非未送达，也不能归因于 Home 手势总开关关闭。临时忽略 HID 边缘标记可使原始宿主上滑返回主屏，撤销后重新失败。

此结果确定了一个失败条件，尚不构成生产修复。给隔离事件增加 `FromEdgeTip` 后，边缘类型变为 1，手势识别完成，但界面进入应用切换器，未稳定返回主屏。不能把该结果记作原始用例通过。

## 实验范围与观测

复用 `a3_home_swipe.py`，要求设置根页面以及前后亮屏、解锁状态。`baseline` 输出 `FAIL still in Settings`。随后通过既有 TweakLoader，仅为 SpringBoard 新增专用过滤文件与临时 dylib，不替换既有 tweak、vphoned 或相机文件。每次换探针后只重启 rig2 的 SpringBoard。

默认探针透传方法原实现，记录方法签名、决策返回值、触摸坐标、识别器状态及失败调用栈；没有覆盖返回值。诊断实验构建通过 `A3_IGNORE_HID_EDGES=1` 显式取得 `_beginRequiringIgnoresHIDEdgeFlagsForReason:` 断言，改变对应识别器的边缘检查。源码位于 `research/probes/`，不参与生产构建。

关键观测：

- `SBHomeGestureSettings.isHomeGestureEnabled=1`；`BSPlatform.homeButtonType=2`。
- `(645,2790)` 到达 UIKit 后为 `(215,930)`，与配置比例一致；结束点为 `(215,533.33)`。
- 原事件可以完成锁屏滑动，但应用内失败。相同父类下存在多个识别器，日志中的实例地址及实际类型用于区分锁屏与应用切换器。
- 应用切换识别器的 `debugDictionary` 显示 `_UISEEdgeTypeFailGestureFeature state=failed`。
- 实际 `SBFluidSwitcherScreenEdgePanGestureRecognizer.edges=15`，不等于仅底边的 4。最初只匹配 `edges==4` 的诊断构建未取得断言，不能计作有效干预。改为限定该实际识别器类后，日志记录了有效断言对象。

## 正反对照

| 实验设置 / label | 结果 |
| --- | --- |
| 原始宿主上滑 `baseline` | FAIL，仍在设置 |
| 透传观测 v1–v4 | 同一用例均 FAIL |
| 未命中目标的诊断构建 `ignore-hid-edges` | FAIL；干预未生效，不用于因果结论 |
| 实际取得忽略 HID 边缘断言 `ignore-hid-edges-v2` | PASS，最后两张截图为主屏 |
| 相同断言重复 `ignore-hid-repeat` | PASS |
| 恢复透传构建 `restored-control` | FAIL |
| 移除全部 SpringBoard 探针并重启后 `clean-original` | FAIL |

因此，“忽略 HID 边缘检查”与成功之间有干预及撤销对照，而不仅是相关观察。该断言是诊断手段，未作为正式解决方案保留。

## 隔离注入字段对照

`a3_hid_swipe.m` 直接包含生产 `vphoned_hid.m`，通过替换函数指针只改变指定字段。轨迹固定，客户端独立运行；它没有替换正在运行的 vphoned。不能将隔离程序的时间间隔直接等同于宿主定时注入的实际时序。

| 隔离注入设置 | 结果 |
| --- | --- |
| 生产原字段 `hid-baseline` | 仍在设置 |
| 只把 Hand 类型改为 3 | 仍在设置 |
| 只添加 `SwipeUp`（bit 24） | 仍在设置 |
| 只添加 `FromEdgeTip`（bit 11） | `_edgeType=1`，识别器完成；截图为应用切换器 |
| 移除 SpringBoard 探针后，仅 `FromEdgeTip` | 仍可进入应用切换器，未返回主屏 |
| `FromEdgeTip`，18 步间隔由 16667 µs 改为 3333 µs | 应用切换器；未通过返回主屏判据 |
| `FromEdgeTip` 加 `SwipeUp` | 应用切换器；未通过返回主屏判据 |

这些应用切换器截图被工具分类为 UNKNOWN，退出码 2，并经人工图像检查确认；没有误记为 PASS。`edge-flat`、`edge-pending` 只是探针保留的候选模式，本轮未运行，不产生支持结论。

声明参考：[WebKit 的 IOKit SPI](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/PAL/pal/spi/ios/IOKitSPIIOS.h) 中 Hand 类型为 3；[Apple IOHIDEventTypes 头文件副本](https://github.com/alexandred/VoodooI2C-Rewrite/blob/master/Dependencies/Headers/IOKit/hid/IOHIDEventTypes.h) 中提供候选事件掩码。字段对当前组合的实际影响以本轮观测为准。WebKit 的应用内注入使用不同交付入口，不能直接替代系统导航验收。

## 后续实现边界

下一步应在宿主定时注入路径上验证边缘类型与方向信息的完整传递，并核对结束时的状态与速度。正式实现需要把“手势开始于边缘”与普通列表拖动区分，并在整段手势及断线释放中保持一致；不能对所有触摸无条件添加边缘位，也不能用 Home 键替换所有底部上滑。现阶段未改生产代码、固件或设备树，A3 不关闭。

## 验证与清理

探针 arm64/arm64e 构建使用 `-Wall -Wextra -Werror` 并通过，ldid 签名通过；过滤 plist 校验、Python 语法检查及现有 HID 断线释放单测通过。未运行完整固件测试。两份 SpringBoard 注入文件已删除并断言不存在，随后重启 SpringBoard（最终 PID 5967）；原始上滑失败仍可复现，`clean-home` 的 Home 键对照通过。客户机临时命令与日志已清理，五个文件不存在断言返回 0，证据已下载到宿主目录。未修改既有客户机服务、相机文件或用户设置。

宿主 PID 1331 最终退出码 0，控制 socket 已删除，任务锁已释放。`git diff --check` 通过。研究代码及记录尚未提交；项目磁盘清理未执行。

## 后续部署核验（进行中）

证据目录 `rig2-setup-20260916-205403` 的候选客户机启动日志显示 `bind: Address already in use`，实际仍是自动重启的安装服务。该目录的 `actual-edge` 失败不能归属于候选修复。此前仅上传缓存并启动独立服务的实验，必须补充运行版本核验；不能据文件上传成功推断代码生效。

本轮关闭 rig2 后，仅离线备份和替换 System 卷 `/usr/bin/vphoned`。原安装文件 SHA-256 为 `a0e0140a70fcf63b1e91f3bb92cd84b21ea105325841f20c56f091337ade0fc2`；原缓存为 `2b90b8e555c86e794733e661e9bdee4dae510e7f5fcc0ef0e9396f673a168cf4`，两者均保留。专用挂载已卸载，未重装 CFW、未修改主 VM。重启后下载 `/usr/bin/vphoned` 与候选产物逐字节一致；还需核对缓存启动及能力声明，不能仅以安装文件一致作为运行版本证据。
