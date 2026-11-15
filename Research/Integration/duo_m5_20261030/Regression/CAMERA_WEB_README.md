# 新宿主与网页摄像头回归

本组脚本仅针对 `.build/duo-runtime-84e3ce54/machines/duo-rpc-foundation-20261115`。运行时读取 `.build/host-webcam-distribution-20261115/active-mixed-session.txt`；该文件必须指向同一证据目录中的 `mixed-session.*`。脚本验证旧 daemon 摘要，`accept`／`safari` 另要求候选 SystemHook、其他 20 项原库及根只读。它们不安装系统库、不创建 VM，也不改变宿主准入。

## 准备

先取得目标隔离副本的测试授权，启动对应测试会话，保留 `original-cache-state.json` 和不对外展示的 `boot.log`。后者提供认证回环 API；不要提交 token。使用当前源码构建的完整 Bundle，不以单个宿主可执行文件替代。

在仓库根目录执行：

```zsh
evidence="$PWD/.build/host-webcam-distribution-20261115"
zsh VPhoneGuestComponents/Tests/CameraWebProbe/build.zsh "$evidence/probe"
xcrun swiftc -parse-as-library VPhoneGuestComponents/Tests/CameraWebProbe/ReadScreenText.swift -o "$evidence/read-screen-text"
node Research/Integration/duo_m5_20261030/Regression/camera-web-runtime.mjs install
```

`install` 仅适用于尚无该 fixture 的副本；`update` 要求已存在同一 bundle ID。该安装使用 `apps.install`，不验证 installd。宿主摄像头菜单选择生成测试图案；不要选实体摄像头。首次原生／WKWebView 运行需完成此测试 App 的摄像头授权。Safari 模式通过原生截图与 Vision 识别，仅允许名称匹配的测试 App／localhost 摄像头提示；若出现 Trust 提示，只选择 Don't Trust。未匹配的提示保留，回归超时失败。OCR 依赖英文提示及外屏比例 3、无旋转，条件变化时脚本拒绝继续。

## 运行

```zsh
node Research/Integration/duo_m5_20261030/Regression/camera-web-runtime.mjs accept
node Research/Integration/duo_m5_20261030/Regression/camera-web-runtime.mjs safari
node Research/Integration/duo_m5_20261030/Regression/camera-web-runtime.mjs snapshot
```

前两项要求至少 10 帧、至少 3 个不同像素摘要；网页另要求安全上下文。网页流在 12 个采样后停止。原生测试先停止 AVCaptureSession，再开始 WKWebView，避免同时占用摄像头。结果和中间回复保存在当前会话目录。辅助模式 `tree`、`tap`、`read` 用于定位；`rpc` 直接执行给定方法，仅可在既有授权范围内使用。

GUI 回归使用 `mixed-gui.cua.js`。在 cua_repl 选择 `com.vphone.bundle`，载入函数后调用 `mixedGUIHarness(app, expected)` 的 `filesAppsProcesses()` 和 `servicesCrashes()`。`expected` 使用紧接检查前 `snapshot` 返回的真实数量；服务数量可随时间变化。脚本只打开、刷新、筛选和关闭面板。它检查中文界面文本；切换语言需相应更新选择器。

## 结束与证据范围

先停止 fixture，核实 `apps.info` 的 bundle ID／路径后注销注册，并归档生成的 App；保留数据容器和报告。恢复原 SystemHook 和测试 Bundle 对应资源，正常关机，冷启动核对原 daemon／标记、21 项库、根只读及原设置，再正常关机并核对状态文件无句柄。不要使用默认机器或其他 VM。

2026-11-15 首轮候选运行使用证据目录中的 `probe-runtime.mjs`；此处保存其路径可迁移版本并增加会话目录和原库断言。后续保存版本已在实际 VM 的 `mixed-session.yXsrIAl0` 执行 install、accept 和 safari：原生 14/14 不同帧摘要、WKWebView 10/10、Safari 10/10 通过。首次 accept 因测试权限提示超时，提示处理后原命令重跑通过；失败证据保留。7 项记录回复前置检查另行通过，不计为 VM 结果。测试 App 已注销归档，原 SystemHook／21 项库、原 daemon／标记、根只读和 Auto-Lock 已在冷启动核对，随后正常关机，无状态句柄。实际结果和限制见 [本轮验证](../VALIDATION_GAPS_20261115.md)；首轮结果见 [验收记录](../HOST_WEBCAM_DISTRIBUTION_20261115.md)。
