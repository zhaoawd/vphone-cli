# Duo 三项问题诊断，2026-11-14

本轮继续排查内屏 AX 坐标命中、常亮锁屏开合唤醒及动态画面问题。
运行目标仅为工作区内的隔离副本 `duo-rpc-accept-205443`。
使用原 FoldDisplay 库 `c95fbf375e8ee3028e2399e3cf66f38eeacdf86e65e9da9175837994a3a076b1`，
vphoned 为 `446925b66b983e6395bc2c6715885f1eae1d1836cee014a3df136f468540419b`。
本轮未替换 guest 系统库或 daemon，未放宽截图来源校验。

## 实验与回归

运行入口为 [three-issues-runtime.zsh](Regression/three-issues-runtime.zsh)。
它在启动前核对 Bundle 原库、宿主预检及状态文件句柄；使用既有隔离副本；
结束请求 guest 正常关机并检查句柄。`system.shutdown` 的 `force:true`
是该 RPC 的确认参数，未通过宿主信号强制停止 VM。
Node 脚本保存原始 RPC 结果和截图；出现待查现象不代表采集脚本自身失败。
基线判定单独执行：

```zsh
zsh Research/Integration/duo_m5_20261030/Regression/three-issues-runtime.zsh baseline
node Research/Integration/duo_m5_20261030/Regression/three-issues-check.mjs \
  .build/three-issues/run.eaC6LO5Y/samples
```

统一入口已实跑，证据为 `run.eaC6LO5Y`。第二条命令退出码为 1：`axHitTestPassed:false`、
`alwaysOnPreserved:false`、`nativeCaptureAvailable:true`。
截图可用性断言仅覆盖该组静态采样，不能判定动态画面是否停帧。

| 模式 | 证据目录（均在 `.build/three-issues/`） | 实验设置 |
| --- | --- | --- |
| `baseline` | `run.cXnEspBr` | 冷启动；外屏／内屏 AX 与截图；常亮开合各两次及无姿态变化对照 |
| `followup` | `run.KzzI3aji` | 原库重启 SpringBoard 前后来源对照；早期未过滤日志已达截断上限 |
| `followup` | `run.5fP0VLmz` | 原库重启 SpringBoard；`display.modes` 刷新；AX 一级窗口树；过滤唤醒日志 |
| `context` | `run.0pLOChAE` | 主屏幕 → Settings → 主屏幕；重启 SpringBoard 后再单独重启 vphoned |
| `cache` | `run.M5IP5gAB` | 同一脚本进程的 class／instance 刷新；低电量模式下真正熄屏的开合对照 |
| `cache-context` | `run.1ftecDjk` | 同一旧进程刷新与独立新进程的内屏 UUID 对照；核对 FrontBoard |
| `baseline` | `run.eaC6LO5Y` | 通过仓库统一入口复跑，外屏 4/4 成功、内屏 4/4 失败；常亮对照保持，四次开合均唤醒；静态截图来源均有效 |

## 1. 内屏 AX 坐标命中

原库冷启动组中，外屏 Camera／Settings 四次命中全部成功，内屏四次均返回
`AX hit testing failed (-25202)`。这四组显示状态的原生截图来源均有效，
所以该次 AX 失败可在没有截图来源 UUID 失配的状态下复现。

上下文组在已验证的前台进程中依次检查主屏幕、Settings、主屏幕，每组取三个
AX 元素点，全部位于 `x<400,y<600`；9/9 次返回 `-25202`。
Settings 的三个点对应 Apple Account、Airplane Mode、WLAN。
因此，失败范围包含普通 App，不能仅归为 SpringBoard 专用路径的问题。

一级窗口树显示 SpringBoard application root 为 466×678，
`SBHomeScreenWindow` 为 669×951，父子关系通过验证；application 和 automation
开关均为 true。树因 `max_depth:1` 明确标记为 partial，不能当作完整层级。
根和窗口尺寸不同是已观测的上下文差异，尚未证明它导致系统命中失败。
Settings 的 application root 和直接子窗口均为 669×951，开关也均为 true，
仍出现相同错误。因此，SpringBoard 根和窗口尺寸不同不足以解释所有已观测失败。

代码核对：SpringBoard 经 `vp_ax_element_at_json`，普通 App 经 IcliKit；
两条路径最终都使用 icli 的 `AXUIElementCopyElementAtPosition`，查询根由
`_AXUIElementCreateAppElementWithPid` 创建，查询前调用 `icli_screen_point_to_fixed`。
该转换优先使用线程内的 InterfaceGeometry，否则使用 captureGeometry；
当前 `elementAt` 调用点未设置活动显示屏的线程内几何。
当前接口没有显式传入显示标识或窗口上下文。内屏窗口／显示上下文是待验证假设。
原因未查明；未用几何枚举或 AXPress 替代系统命中并计为修复。

## 2. 常亮锁屏开合唤醒

基线每次开合前均确认 `locked:true`、`screen_off:true`、blanked=1、panel=1。
无姿态变化的对照保持常亮，展开和合拢各两次都使 blanked 变为 0，仍保持锁定。
展开首次观测到解除 blanked 的时间区间为请求后约 504–577 ms 和 521–591 ms；
合拢为约 3–101 ms 和 38–165 ms。区间来自相邻 RPC 样本，不是逐帧时间。

过滤日志在请求前启动，SpringBoard 仅匹配 `unlockUIFromSource`，
vphoned 仅匹配 `tap to wake`；三组结果均未截断：

| 实验设置 | 日志与结果 |
| --- | --- |
| 无姿态变化 | blanked 保持 1，无匹配唤醒日志 |
| 常亮合拢 | `unlockUIFromSource:DisplayContentModeTransition`，`SBUIUnlockOptionsTurnOnScreenFirstKey:1`，首次 `screenWasOff:YES`，随后为 NO |
| 常亮展开 | 先有 `ExternalRequest` 和 `LockButton`，均为 `screenWasOff:YES`；随后出现 `DisplayContentModeTransition` |

早期未过滤、已截断的日志还记录了 `display content mode transition` 请求
把背光切换至 active。完整性结论以随后未截断的过滤日志为准。
三组均未观察到 vphoned 的 `tap to wake` 匹配项；此结果不证明所有替代路径均已排除。

代码显示 `display.posture` 的 CoreMotion 展开路径在铰链从 closed 改变时主动调用
`wakeDisplay()`。该方法按 `screenOff` 判断，而该值同时包含常亮和真正熄屏。
合拢没有这一调用；其点亮请求已由 SpringBoard 的显示内容模式切换日志确认。
因此，仅修改 daemon 的展开唤醒条件不足以处理合拢的唤醒来源。

另用低电量模式建立真正熄屏对照，开合前均确认 blanked=1、panel=2；
展开和合拢各一次都变为 blanked=0、panel=1，仍锁定。低电量模式已由 false
临时设为 true 并恢复 false。修复应保留真正熄屏时展开唤醒的行为；
本轮未修改唤醒策略，未拦截未知枚举或未经验证的私有 ABI。

## 3. 动态画面的来源验证前置问题

原库在三次冷启动后的重启 SpringBoard 实验中都复现来源拒绝。
FrontBoard 内屏 UUID 更新，而存活的 vphoned 读取到的 CADisplay UUID 保持旧值；
比例均为 3。调用 `display.modes`（内部执行 `+[CADisplay updateDisplays]`）
没有恢复一致。来源校验按设计返回 `source_unavailable`。

上下文组的进程和 UUID 证据：

| 状态 | SpringBoard PID | backboardd PID | vphoned PID（worker／supervisor 两项） | FrontBoard UUID | CADisplay UUID | 原生截图 |
| --- | ---: | ---: | --- | --- | --- | --- |
| 冷启动 | 37 | 73 | 114、67 | `31DED69F-8F51-446A-85F4-335EC7452440` | 同左 | 可用 |
| `system.respring` 后 | 479 | 477 | 114、67 | `2D2482AF-7B59-42AE-B0A9-FB8D2A124D6D` | 仍为 `31DED69F…` | 拒绝 |
| 仅 kickstart vphoned 后 | 479 | 477 | 495、494 | 仍为 `2D2482AF…` | `2D2482AF-7B59-42AE-B0A9-FB8D2A124D6D` | 恢复可用 |

通过 `services.kickstart {label:"com.vphone.vphoned",kill:true,force:true}`
重启 daemon 时，当前 RPC 因连接断开返回错误；后续以两个新 PID 和重连后的读取
确认重启，未把请求错误本身计为成功。

这些证据确认：`system.respring` 在本机也重启 backboardd。
结合 FoldDisplay 在新 backboardd 进程中创建内屏 render display 的代码和新 UUID，
可判断内屏 render display 被重新创建；存活的 daemon 持有旧显示信息会造成来源拒绝。
单独重启 daemon 是已验证的恢复实验，尚未实现自动处理。
该结果解释诊断轮的来源判据失败，不能解释此前来源有效时的黑帧和重复画面。

后续同一脚本进程实验保留旧 CADisplay 对象跨越重启；class 刷新与实例 `update`
后 UUID 均未变化。`cache-context` 再次复现：旧进程始终读取
`13CF3D40-2109-45F0-BC83-B9EC0895C7F0`，独立新脚本进程读取
`D6379963-89BA-4B94-BEF0-2B78DDBBCA11`，与 FrontBoard 一致，数字 ID 均为 7。
因此，简单调用上述两种刷新不足以处理这个重建场景；新进程可读到当前身份。
四个候选 `initWithDisplayId:`／`initWithDisplayID:` 及其下划线形式均未取得
运行时方法签名，未调用它们，未完成同进程新对象构造实验。

## 验证限制与下一步

- AX：继续验证系统命中的窗口／显示上下文；Settings 已排除 SpringBoard 独有故障的范围判断。
- 常亮：针对显示内容模式切换的唤醒策略建立修复实验，同时复测真正熄屏展开。
- 动态画面：先处理重建 render display 后的身份生命周期，再在来源有效条件下重跑六次交接和保持层诊断。

上述实验尚未修复三项产品问题。保持层到 scanout 的关系、有效来源下的黑帧和
重复画面原因仍未查明。结果不替代完整 Bundle 构建、修改后实际 VM 回归或动态交接验收。

七个证据目录均已核对：前后 21 项环境库摘要一致，根文件系统均为只读；
正常关机请求均获接受，驱动等待 VM 退出后记录的状态文件句柄均为空。
低电量模式已恢复 false。本轮只增加诊断与回归资产及研究记录，未修改产品实现。
