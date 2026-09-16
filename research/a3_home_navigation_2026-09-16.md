# A3：底部上滑与 Home 键对照

后续进展：边缘类型检查的原因及生产修复已在 [HID 诊断](a3_hid_edge_diagnosis_2026-09-16.md)和 [A3 验收](a3_touch_acceptance_2026-09-16.md)中记录；以下为修复前的历史对照。

日期：2026-09-16。组合：rig2，26.1 / 23B85 EXP，1290×2796，简体中文。宿主 PID 94329，原客户机文件未替换，能力包含 `touch`。证据：`research/artifacts/rig2-setup-20260916-180746/`。主 VM 未收到控制请求或 UI 操作。

## 实验设置与结果

每轮有效上滑实验均检查操作前后的 `lockstate=0`、`hasBlankedScreen=0`；从“设置”根页面开始，终点固定为 `(645,1600)`。

| 实验设置 | 结果 |
| --- | --- |
| 起点 `(645,2790)`，300 ms，重复两次 | 均仍在设置 |
| 起点 y=2795，其余不变 | 仍在设置 |
| 起点 y=2700，其余不变 | 仍在设置 |
| 100 ms，原起点 | 仍在设置 |
| 800 ms，原起点 | 仍在设置 |
| 新工具连续三张截图，原起点与时长 | `FAIL still in Settings`，退出码 1 |
| 同一工具改用 Home 键 | `PASS Home visible in two final captures`，退出码 0 |
| 主屏点击设置图标 | 进入设置 |
| 主屏设置图标原地按住 1500 ms | 出现快捷菜单；前后均亮屏、解锁 |

最后两项证据为 `settings-via-tap.jpg`、`longpress-2-after.jpg` 及对应请求。早先一次长按发生在自动锁屏后，打开了锁屏壁纸选择界面，不计入应用内长按验收。退出该界面后重新解锁，没有选择新壁纸。Home 对照后的一次旧坐标点击打开健康欢迎页，没有继续设置；随后用 Home 返回主屏。

## 原因与支持范围

底部上滑失败的原因仍未查明。本轮不支持只改变起点或持续时间即可解决的假设。Home 键可用；现阶段可以作为该组合已验证的返回主屏方式，但不能代替底部手势通过，也未将底部上滑自动转换成 Home 键。

只读查询显示设备树 `buttons/home-button-type=<02000000>`，MobileGestalt `HomeButtonType=2`、`DeviceClass=iPhone`、`ProductType=iPhone17,3`。与仓库 `DeviceTreePatcher.basePropertyPatches` 的既有值一致。`DeviceSupportsHomeGesture` 与 `DeviceSupportsMultitasking` 返回 null，不可解释为 false。旧版第三方手势实现也使用 `homeButtonType=2`，因此不能据此认定配置错误或修改该值。参考：[HalFiPad 原始实现](https://github.com/hieuvh/HalFiPad/blob/master/TweakSB.xm)。尚需本组合 SpringBoard 的手势启用状态或事件接收证据，才能区分系统策略与事件信息问题。

本轮未修改生产输入算法、设备树或固件补丁。A3 仍缺少完整连接状态矩阵、窗口缩放、真实按下中断线释放，以及其他精确版本组合；本轮长按仅覆盖主屏设置图标。

## 可重复工具与验证

新增 `research/probes/a3_home_swipe.py` 与 `a3_screen_state.swift`，调用方负责独占 rig2 并部署只读状态探针。示例：

```sh
.venv/bin/python research/probes/a3_home_swipe.py --output research/artifacts/rig2-setup-20260916-180746 --classifier research/artifacts/rig2-setup-20260916-180746/a3-screen-state --label durable-swipe
.venv/bin/python research/probes/a3_home_swipe.py --output research/artifacts/rig2-setup-20260916-180746 --classifier research/artifacts/rig2-setup-20260916-180746/a3-screen-state --label durable-home --action home
```

以上 label 已有证据，重新运行必须换新 label。前者退出 1，后者退出 0。工具依赖本轮语言、图标布局及屏幕尺寸；OCR 和连续截图不能保证底层截图新鲜度，不声明为通用 UI 判据。Swift 分类器构建通过；受限沙箱内 Vision 调用失败，允许服务访问后真实正反对照通过。Python 语法检查及 `tests.test_guest_touch` 的 1 项现有 HID 测试通过。未修改生产代码，未重跑完整固件测试。

## 退出与清理

PID 94329 退出码 0，socket 已删除。首次删除两个客户机临时探针时 `/bin/rm` 不存在，返回 127。为完成清理检查，重新启动 rig2（PID 96894，证据目录 `research/artifacts/rig2-setup-20260916-181856/`）；重启后两文件已不存在。确认实际命令为 `/var/jb/usr/bin/rm`，幂等清理及两个不存在断言返回 0。没有替换客户机服务或消费端文件，没有执行项目磁盘清理。

清理会话 PID 96894 最终退出码 0，socket 已删除，任务锁已释放。新增分类器的参数错误退出码 2、既有截图 HOME/SETTINGS 分类以及重复 label 拒绝覆盖均已验证；`git diff --check` 通过。改动尚未提交。
