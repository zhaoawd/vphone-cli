# 新宿主、网页摄像头与构建分发集成（2026-11-15）

本轮范围为真实新宿主 GUI × 旧 daemon 验收、#906 网页摄像头路径，以及 #861／#869／#870／#888 构建分发改动。基础提交 `c0e1b9bd`；所有大体积证据位于 `.build/host-webcam-distribution-20261115/`。

## 来源和实现

- #906：`7f8a307b`，仅增加 WebKit GPU executable 后缀识别及提前加载 CamFix 的分支。该进程位于 `.xpc`，现有 `.app` 门槛未覆盖它；CamFix 自身等待 AVFCapture 加载后安装 hooks。未移植相邻 locationd 注入改动。保留本地 backboardd、SpringBoard、FoldDisplay 及其他注入目标。
- #861：合入 `a07728f0` 相对第一父提交的差异。嵌套构建保留显式 DEVELOPER_DIR、SwiftPM netrc 数据和镜像配置；隐藏 shell 构建阶段环境日志。继续清理不相关的父构建 SDK 状态。
- #869：合入 `400c0d73` 的独立改动及 `79d2155c` 增量修正。Bundle 和 Launchpad 收集固定版本依赖的原始 notice 字节，包含下载的二进制目标内嵌 notice；增量构建重新生成输出。
- #870：合入 `2d6131ee` 的独立改动。Dynamic 固定到 `772883073d044bc754d401cabb6574624eb3778f`，与工作区及所属工程的锁定文件一致，随产物保留 Apache 2.0 与 NOTICE。未更新其他包的版本。
- #888：合入 `8f00243f` 的独立改动。分发门禁拒绝未覆盖的缺失 notice；仅对上游四个精确固定的二进制包版本保留带跟踪链接的例外。测试验证例外不能接受其他版本或 checkout notice 缺失。没有执行发布流程。

版本仍为 Bundle／Launchpad 2.15.2，Launchpad 最低 Bundle 为 2.15.0。此次没有变更 Launchpad 依赖的 CLI 参数、receipt 或 Bundle 目录布局；新增许可证目录不改变已有布局的读取。未声称已经完成上游 2.17 的全部同步。

## 构建和离线回归

完整 `VPhone` Debug Bundle 构建、Bundle admission 和 `codesign --verify --deep --strict` 通过。Launchpad Debug 工程构建通过；LauncherPolicy、BundleNames／machine binding、Control 回归通过。Bundle 和 Launchpad 的实际产物都通过 `stage-package-notices.zsh --check ... --require-notices`。未执行 Developer ID 发布签名、notarization 或发布。

新增构造函数回归导入生产 `SystemHook-vphone.c` 并替换外部加载边界，验证 GPU 延迟加载、安全模式、WebContent、普通 App、cameracaptured、backboardd 和 SpringBoard。旧源码在 GPU 应加载 CamFix 的断言处失败；新源码通过。证据 `camera-routing-before.log`／`camera-routing-after.log`。

新增嵌套构建环境回归执行从生产脚本提取的 shell，替换最终构建执行器以读取子环境；验证显式认证／镜像传递、缺省选项、父 SDK／其他变量不泄漏和隐藏环境日志。旧代码失败，新代码通过。另有 notice 收集和分发门禁的正反回归。CI 接入这些入口。

执行命令与对应证据：

```zsh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/duo-sync-20261113/XcodeBundle -disableAutomaticPackageResolution -jobs 4 build
xcodebuild -project VPhoneLaunchpad/VPhoneLaunchpad.xcodeproj -scheme VPhoneLaunchpad -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/host-webcam-distribution-20261115/XcodeLaunchpad -jobs 4 build
zsh VPhoneGuestComponents/Tests/run-systemhook-camera-tests.zsh
zsh scripts/tests/nested-build-environment-tests.zsh
zsh scripts/tests/stage-package-notices-tests.zsh
zsh scripts/tests/package-notice-release-gate-tests.zsh
```

两个构建日志为 `bundle-build.log`／`launchpad-build.log`；最终四项回归日志为 `camera-routing-final.log`、`nested-env-final.log`、`notices-final.log`、`notice-gate-final.log`。四项脚本退出状态均为 0；notice 负例输出中的拒绝为预期结果。完整 Bundle 的构建在测试资产、CI 和文档整理前完成，后续未修改生产代码。

## 新宿主与旧 daemon

新宿主 CDHash `974031b523fa25f5975784700b5030123213efdd`，实际宿主预检通过，没有新增 AMFI allowlist。测试 Bundle 保留新宿主程序，guest-resources 使用已保存原版本，且禁用 daemon 自动更新。

唯一测试副本为 `duo-rpc-foundation-20261115`。`mixed-session.kn8i3dW8` 核对原 daemon `446925b6…`、原标记、21 项原库及根只读。实际 GUI 打开并刷新文件、App、进程、服务和崩溃日志面板：文件 15 项、App 268 项、服务 723 项；App 和服务超过 200 条的旧完整回复未被截断。进程筛选显示原 vphoned worker 116／supervisor 67；服务筛选找到 com.vphone.vphoned。未执行这些面板的终止、卸载或信号动作。GUI 检查补充已保存的生产列表收集和协议契约回归，不替代这些回归。

第一次驱动引用错误的 worker 路径而退出，VM 已正常关机；该失败保留在 `mixed-session.WZ1LUxgU`，不计为产品失败。修正后才开始正式 GUI 检查。

## 摄像头对照

使用原生 Objective-C 测试 App `com.vphone.tests.camera-web`。它提供 AVFoundation 输出、WKWebView 和 guest 回环 HTTP 页，记录帧尺寸、帧数和不同像素摘要。只传输宿主生成的测试图案，未启用实体摄像头。测试 App 首次因未声明 iOS 27 scene 生命周期而退出，修正后进入测试；该 fixture 失败保留，不计为产品摄像头失败。

原 SystemHook SHA-256 为 `755f089d13e8a3df7ac6d0ea91ecd0eebf79b8a98a92c101ce305b0dad1caac9`。原生对照采到 1280×720 的 11 帧、3 个不同摘要。WKWebView 的回环页报告 secure=true、mediaDevices=true；发起 getUserMedia 后内容进程终止。对应 WebKit GPU 的 SIGABRT 崩溃栈含 `AVCaptureFigVideoDevice _setActiveFormat:...`、`AVCaptureSession addOutput:` 和 `WebCore::AVVideoCaptureSource::setupSession()`。证据 `wk-baseline-final.log`、`wk-before.ips`。

候选 SystemHook SHA-256 为 `6aa02df8eacfe8d94fd85ea6cf701e8d612f29b018c9407deb4d7bc0dde28217`。临时安装只改变这一项，其余 20 项库、原 daemon 与原标记不变；安装后根暂时可写，正常关机并冷启动后确认只读。`mixed-session.SJJeV3zG` 的实际保存式回归通过：原生 1280×720、13 帧／13 个不同摘要；WKWebView 480×640、10 帧／10 个不同摘要、secure=true。帧变化检查没有以动作返回成功或仅枚举设备替代。

`mixed-session.j82PBpC8` 的 Safari 实测通过：回环页 secure=true，480×640、10 帧／10 个不同摘要。CamFix 日志确认加载到 `com.apple.WebKit.GPU`（PID 550、574、588、602）；仅按旧 daemon 的进程简称筛选完整 GPU 名称返回 0，不能据此判断进程不存在。证据为 `safari-accept.log`、会话内 `safari-accept-summary.json`／`safari-dom-latest.json`、`systemhook-candidate.log` 和 `camfix-candidate.log`。

同一会话实际执行保存的 `Regression/mixed-gui.cua.js`，五类面板均通过。一次服务断言使用检查前较早读取的 725 项而失败；重新读取 RPC 为 726 项后，按相同断言重跑通过。服务数量随运行状态变化，未更新固定基线或弱化断言。汇总 `gui-regression-results.json`；原始快照为会话内 `gui-rpc-expected.json`／`gui-rpc-lists.json`。

网页帧数为每 200 ms 读取 canvas 的采样次数；不同摘要证明采到变化画面，不用于测定摄像头实际输出帧率。旧宿主与新 daemon 的反向运行证据沿用 [RPC 契约验收](RPC_CONTRACT_NEXT_20261115.md)，本轮补充新宿主 GUI 与旧 daemon；未将策略单元测试写成全部版本组合的实际验收。

候选会话 worker 的 `librariesUnchanged:true` 字段来自复用摘要模板；实际断言要求候选 SystemHook 和另外 20 项原库。该字段不表示候选 SystemHook 与原库相同。

## 回归资产和清理

摄像头 fixture 位于 `VPhoneGuestComponents/Tests/CameraWebProbe/`，运行脚本与说明位于 `Regression/camera-web-runtime.mjs`／`Regression/CAMERA_WEB_README.md`。实际正式运行使用 `.build` 中的脚本；保存版本改用相对仓库定位，并增加会话目录、候选库和根只读前置断言，语法检查通过，新增前置断言未重新安装候选实测。构造函数及构建环境回归均保存旧实现失败、新实现通过的证据。

结束时核实测试 App 的 bundle ID、App 路径和数据路径后，停止并注销注册，将生成的 App 归档至 `/var/root/Library/Caches/CameraWebProbe-20261115-archived.app`。App 列表不再包含该 fixture；数据容器 `/private/var/mobile/Containers/Data/Application/BFE33FFD-17FB-4EFC-860A-0574A2FC865A` 及其报告保留，未卸载或删除测试数据。

先恢复测试 Bundle 的原 SystemHook 资源并重新封签，再通过 `environment.install` 回滚 guest。回滚时核对原 SystemHook 摘要及其他 20 项原库；临时根可写，回复要求重启。`j82PBpC8` 经 `system.shutdown` 正常关机。最终冷启动 `mixed-session.ElVltMe0` 核对原 daemon `446925b6…`、原标记、全部 21 项原库、根只读和 Auto-Lock 原值 120 秒（never=false），随后再次正常关机，状态文件无打开句柄。原副本及其他身份副本未启动。候选测试中一次中断后的停止没有正常关机证据，不将该次停止计为正常关机验收。

本轮完成三个请求项的实现和上述范围的验收。未覆盖实体摄像头、其他 iOS 版本、installd 安装链、Developer ID 发布签名与 notarization；未推送或发布。原生 Snapshot、Duo AX、严格 Auto-Lock `never` 及 render-server 生命周期代码未因本轮改变。
