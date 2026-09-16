# 相机 QR 验收探针

`display_state.c` 是另一个只读前置状态探针，用于检查锁屏、熄屏相关 Darwin 通知原始值。它不操作界面；需要在所测版本上与截图对应，不能把未知通知键的零值当作通用解锁保证。证据见 [重启与输入对照](../e6_reboot_a3_input_2026-09-16.md)。

此目录仅包含手动验收工具。构建脚本不启动 VM、不部署文件，也不修改生产签名配置。

## A3 返回主屏对照

`a3_home_swipe.py` 仅连接仓库内 `vm-2607-rig2/vphone.sock`。调用方必须已独占 rig2 任务锁并启动 VM；工具不负责启动、停止或部署。先将已签名的 `display_state.c` 产物部署到客户机 `/tmp/vphone-a3-display-state`，确认简体中文“设置”根页面亮屏、解锁。

```sh
xcrun swiftc -module-cache-path /private/tmp/a3-swift-module-cache research/probes/a3_screen_state.swift -o /private/tmp/a3-screen-state
.venv/bin/python research/probes/a3_home_swipe.py --output <已有证据目录> --classifier /private/tmp/a3-screen-state --label swipe-1
```

坐标只适用于 1290×2796 的本轮 rig2 配置。`--start-y` 和 `--duration-ms` 用于单变量对照；`--action home` 使用 Home 键作阳性对照。每次使用不同 label，避免覆盖。退出码 0：最后两张截图均识别为主屏；1：最后两张均仍为设置；2：前置条件失败、探针失败或结果不确定。OCR 判据依赖本轮主屏图标及语言，不适用于任意布局。连续截图不保证底层画面新鲜度，仍需保留原图和状态输出；不能仅凭退出码认定完整 A3 通过。Vision 运行需要环境允许其图像识别服务访问。

`--prepare` 先读取已知通知状态，再按需唤醒、滑动解锁无密码的 rig2 并打开设置；不会修改自动锁屏设置。未知状态仍失败，不把唤醒操作作为验收结果。

`a3_input_matrix.py` 的 `basic` 模式验证点击并保存列表拖动、长按截图。`scaling`、`disconnect` 模式仅用于带临时 `a3_acceptance` 入口的隔离宿主副本；该入口不是生产协议。构建差异保存在验收目录的 `acceptance-screen-hook.patch` 和 `acceptance-command-hook.patch`，分别提供真实 view 缩放、鼠标事件、control close/connect 调用；主 VM 不得运行这些探针。示例：

```sh
.venv/bin/python research/probes/a3_input_matrix.py --output <已有证据目录> --classifier /private/tmp/a3-screen-state --label basic-1 --mode basic
```

三个模式均要求已连接且声明 `touch_edge`，调用方独占 rig2 任务锁；要求 `display_state.c` 已部署，输出目录已存在、label 未使用。工具成功只代表其断言通过，仍须检查拖动、长按及按下中断线截图。测试后移除临时宿主入口，重新构建生产 app 并复验。实现、版本范围和运行证据见 [A3 验收记录](../a3_touch_acceptance_2026-09-16.md)。

### 系统手势诊断探针

`a3_springboard_observer.m` 与同名 plist 是仅供隔离 rig2 使用的临时 SpringBoard 观测工具，不得加入生产包。默认构建透传原方法；`-DA3_IGNORE_HID_EDGES=1` 会改变应用切换识别器的边缘检查，仅用于诊断对照。日志上限 1500 条，写入 `/tmp/vphone-a3-springboard.log`。使用既有 TweakLoader 时须先确认同名目标不存在，只新增这两份文件；结束时删除它们并重启 SpringBoard，以卸载所有运行时修改。不得部署到主 VM。

`a3_hid_swipe.m` 直接调用生产 HID 实现，只在独立进程内替换指定事件字段。它需要 Foundation、iPhoneOS arm64 构建及客户机 HID 注入签名；部署路径为 `/tmp/vphone-a3-hid-swipe`。`--action hid-*` 调用对应隔离模式，坐标和时间由该探针固定，不接受额外轨迹覆盖。`hid-edge-tip-fast` 改为 18 步、每步 3333 µs，其余模式为每步 16667 µs；这些是等待参数，不是实测交付时间。UNKNOWN 必须检查截图，应用切换器不能算返回主屏通过。

证据及已验证范围见 [HID 边缘诊断](../a3_hid_edge_diagnosis_2026-09-16.md)。两个探针都不负责取得 VM 锁、自动部署或自动清理。

## 构建

在仓库根目录执行，需要 Xcode iPhoneOS SDK 和 `ldid`：

```sh
zsh research/probes/build_camera_qr_probe.sh /private/tmp/camera-qr-probe
```

输出已存在时拒绝覆盖。探针签名包含相机 TCC 许可，以及 `IOSurfaceRootUserClient`、`IOGPUDeviceUserClient` 两项图形用户客户端权限。2026-09-16 的 rig2 对照实验表明：缺少图形权限时，测试程序可能无法分配 IOSurface 或解码 QR，不能将该结果归因于生产相机链路。

## 客户机运行

先独占指定测试 VM，保存原文件和部署证据；通过该 VM 的 `file_put` 上传探针及已知 QR 样本。以下命令在客户机运行：

```sh
/tmp/camera-qr-probe file /tmp/sample.png '样本的精确内容'
/tmp/camera-qr-probe metadata '当前呈现的精确内容'
```

`file` 模式检查 IOSurface 分配及 Core Image 解码。`metadata` 模式显式加载既有 libcamfix，绑定 `vphone:vcam:0`，使用标准 `AVCaptureMetadataOutput` 委托，最多等待 12 秒。第一次回调后继续观察 1 秒，要求内容匹配且仅有一次回调。探针不打开解码 URL，不启动业务应用，不修改 TweakLoader 过滤器。

退出码 0 表示通过；1 表示没有匹配结果、图形前置检查失败或回调数量不符；2 表示输入、动态库或相机前置条件失败；3 表示 Objective-C 异常；64 表示参数错误。外层 `shell` 协议的 `ok=true` 只表示命令执行成功，必须检查 `code`、stdout 和 stderr。

标准验收顺序：

1. 用 `camera_present` 呈现唯一内容的 QR，分别检查消费回执和探针匹配结果。
2. 传入错误预期内容，要求退出码 1。
3. 呈现 neutral，要求无 QR 回调。
4. 呈现第二个唯一内容，要求匹配新内容且拒绝旧内容。
5. 停止相机源，恢复临时替换文件，删除客户机探针，并保存请求记录。

这个探针证明标准元数据客户端的解码结果，不证明系统 BarcodeScanner、所有业务应用、图像显示、视频播放或旧帧全部排空。真实证据见 [QR 权限修正与验收](../camera_e6_qr_acceptance_2026-09-16.md)。
