# E6：QR 探针权限修正与标准回调验收

日期：2026-09-16。实例：`vm-2607-rig2`，26.1 / 23B85 EXP。宿主 PID 99979，持有 rig2 排他任务锁。主实例未操作。证据目录：`research/artifacts/rig2-setup-20260916-172404/`。

## 对上一轮结论的修正

上一轮标准元数据探针和直接解码探针只包含平台应用及相机 TCC 权限，没有图形用户客户端权限。其失败不能证明客户机生产解码器存在相同缺陷。本轮仅改变探针签名即可改变同一输入的解码结果。

| 实验设置 | 结果 |
| --- | --- |
| 无图形权限，原始 PNG，Core Image | 0 个 QR；IOSurface 缓冲区分配返回 -6662 |
| 仅增加 IOSurfaceRootUserClient | IOSurface 分配成功；Core Image 默认和软件上下文仍返回 0 个 QR |
| 增加 IOSurfaceRootUserClient 与 IOGPUDeviceUserClient | Core Image 精确解码成功 |
| 上述权限再增加 IOSurfaceAcceleratorClient | 同样通过；本样本不需要增加该项 |
| 同一受版本控制探针移除图形权限，重新签名 | IOSURFACE_STATUS=-6662，退出码 1 |

这确定了探针权限配置是本轮 Core Image 失败的原因。测试没有修改系统安全设置、内核、生产应用权限或 libcamfix 过滤器。

Vision 默认及 CPU 路径另报告缺少 `mrcdetector.espresso.weights_nonane`，客户机 Vision.framework 目录包含对应 net/shape 和 H17 资源，但没有所报 weights 文件。旧版 Vision 路径在具备图形权限后解码成功。生产 libcamfix 使用 Core Image，本轮不引入 Vision，也不修补系统模型资源。

## 标准客户端结果

探针显式加载 libcamfix，绑定虚拟相机，通过标准 `AVCaptureMetadataOutput` 委托接收 QR，不打开 URL 或操作业务应用。

| 实验设置 | 结果 |
| --- | --- |
| 原样本呈现取得消费回执，匹配预期 URL | CALLBACKS=1，RESULT=PASS，退出码 0 |
| 同样本、错误预期值 | 收到实际内容，但 RESULT=FAIL，退出码 1 |
| neutral 已取得消费回执 | 12 秒内 CALLBACKS=0，退出码 1；没有复用旧 QR |
| 新样本 `e6-rig2-172404`，独立 presentation_id | 精确匹配新文本，CALLBACKS=1，退出码 0 |
| 新样本仍以旧 URL 为预期 | 收到新文本，旧内容断言失败，退出码 1 |

第一次回调后额外观察 1 秒，未重复回调；不据此承诺无限时间窗口内的行为。上述结果覆盖既有客户机 libcamfix。另从当前源码重新构建并签名 libcamfix，SHA-256 为 `fbb733939a43af5adbde73a5acdbd5058214a3f8942b15968f289a45e72a65fb`，单独部署后正确内容退出码 0、错误预期值退出码 1，两次均只有一次回调。

未启动系统 BarcodeScanner；其历史失败不能由本探针结果标记为已解决。标准客户端验收不等于所有应用兼容性。

## 未消费时的真实拒绝

获取唯一 cameracaptured PID，暂停该消费进程并安排独立 Shell 在 20 秒后自动恢复，同时使用 finally 主动恢复。宿主、vphoned 和发布通道保持运行。切换到 `e6-no-consumer` 后，`camera_present` 返回失败且无回执；`camera_status` 同样没有回执。恢复消费进程后，新 presentation_id 的回执出现。脚本 `no-consumer.py` 的两项断言通过。

## 交付与验证

- 新增可重复构建的 [探针源码](probes/camera_qr_probe.m)、最小已验证权限配置和构建脚本。构建只生成指定文件，不自动部署；已有输出拒绝覆盖。
- iPhoneOS arm64e 编译、ldid 签名、签名中 plist 解析、已有输出保护和 zsh 语法检查通过。
- 客户机回执 7 项与消费端 3 项隔离测试通过。
- 未修改生产算法、固件补丁或完整回归套件。

E6 仍不关闭，计数保持 17/28。尚未完成 VM 内视频显示、完整客户机操作系统重启边界和积压旧帧排空的明确观测；A3 的系统手势问题仍需独立处理。

## 还原

停止相机源后，客户机缓存、libvcamcaptured 和 libcamfix 均还原为原文件，重新下载并逐字节比较通过。已删除本轮上传的客户机探针、样本和暂存二进制；宿主源码和证据保留，可重新构建。宿主 PID 99979 退出码 0，socket 已删除，任务锁随进程退出释放。未修改 libcamfix 过滤器、用户设置或主实例。还原后的原组件没有再次启动复验。磁盘清理未执行。
