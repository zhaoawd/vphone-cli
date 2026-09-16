# 相机 QR 验收探针

此目录仅包含手动验收工具。构建脚本不启动 VM、不部署文件，也不修改生产签名配置。

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
