# E6：视频循环与应用显示验收

日期：2026-09-16。实例：`vm-2607-rig2`，26.1 / 23B85 EXP，1290×2796。证据目录：`research/artifacts/rig2-setup-20260916-222835/`。主 VM 宿主 PID 21605 在本轮前后持续运行；未连接其控制接口。

## 结论

E6 按当前清单定义完成。累计完成数更新为 19/28。

本轮为现有 `camera_present` 增加可选 `source: "image" | "video"`。省略时仍为 `image`。视频使用生产 `VPhoneVideoFileProducer`，沿用 generation、独立 `presentation_id` 和 v3 复制回执；`ok=true` 仍只表示客户机完成帧复制，不表示应用显示或识别。

既有证据分别覆盖：重复 generation 的新旧呈现隔离、源切换期间旧回执拒绝、暂停消费者时拒绝成功、恢复后新呈现成功、vphoned 服务重启、完整客户机操作系统重启、QR 正确/错误预期、neutral 不复用旧 QR。见 [回执定义](camera_receipt_e6_2026-09-14.md)、[QR 验收](camera_e6_qr_acceptance_2026-09-16.md)和[完整重启](e6_reboot_a3_input_2026-09-16.md)。本轮补齐视频和系统相机可见结果。

旧帧场景由两层证据覆盖：宿主 generation fence 测试要求切换前已调度的生产任务不得发送；客户机发布区只保存最新一帧，暂停消费者后切换源并恢复时，只接受新 presentation_id 的回执。QR 新内容拒绝旧文本，neutral 期间没有旧 QR 回调。这里的“积压”不表示客户机存在多帧队列。

## 代码与测试

失败测试先证明 `source=video` 仍返回 `source=image`，且 MP4 路径进入静态图像接口。实现后，视频路径进入 `VPhoneVideoFileProducer`，`VPhoneCameraServer.sourceKind` 为 `videoFile`；未知 source 在改变现有呈现前返回 `invalid_argument`。`HostCommandExecutorTests` 21 项通过。最终 `make test` 通过：Python 113 项；XCTest 143 项、3 项跳过；Swift Testing 336 项、53 个 suite。

隔离签名应用位于 `.build/e6-final/.build/vphone-cli.app`，主二进制 SHA-256 为 `7408430d…c39d09`。构建包含签名、资源和 entitlement 检查。它没有覆盖主 VM 使用的 `.build/vphone-cli.app`。

## 实机结果

样本 `two-second-loop.mp4` 为 10 fps、20 帧、2.000 秒：前 10 帧红色，后 10 帧蓝色；SHA-256 为 `a4256623…61b7c15a`。

| 实验设置 | 结果 | 证据强度 |
| --- | --- | --- |
| rig2 已还原的消费端，呈现视频 | 宿主持续 streaming，但 30 秒内无复制回执 | 负向对照 |
| 同一组件，改呈现已通过的静态 QR | 同样无复制回执 | 排除视频容器是该失败的必要条件 |
| 只替换为配套签名 `libvcamcaptured`，重新呈现视频 | `ok=true`；presentation_id `96BDCB34-993D-47B8-903C-2C6F779D9235`；复制回执 generation 和标识均匹配 | 客户机复制通过，不代表应用显示 |
| 读取客户机发布共享内存 | frame_index 4748、4754、4761、4768、4774、4781；中心 RGB 依次为蓝、红、红、蓝、红、红 | 证明客户机发布帧在变化 |
| 已安装旧版 libcamfix 的系统相机 | 可见红色首帧，但连续截图不变化 | 负向对照；不能据此关闭应用显示项 |
| 只替换为当前源码构建的 libcamfix 并重启系统相机 | 4.84 秒内 10 张截图中心色为蓝、红、红、蓝、蓝、红、红、蓝、蓝、红 | 系统相机可见动态画面；观测时间超过两个视频周期 |
| 视频呈现运行约 515 秒后查询状态 | streaming=true，host scheduled=5150，复制回执仍匹配原 presentation_id | EOF 后仍持续生产；不把 scheduled tick 当作已复制帧 |
| `camera_stop(policy=neutral)` | 新 generation、新 presentation_id `00780947-F75C-439C-A91A-FB500BA50C79` 取得独立回执；系统相机显示白色画面 | 旧红/蓝画面未保留为 neutral 结果 |
| 停止 neutral | streaming=false，策略为 keep_last | 停止只停止生产，不声明客户机已清空末帧 |

应用显示使用系统相机；QR 结果使用标准 `AVCaptureMetadataOutput` 测试客户端。两个结果独立记录。未把系统相机画面或复制回执解释为系统 BarcodeScanner 已识别；系统 BarcodeScanner 仍不在支持声明内。

旧版 libcamfix 与当前源码版本都包含预览泵，但本轮只观测到当前源码版本显示动态视频。两者差异的最小代码原因未进一步定位，因为生产 CFW 安装入口会从当前 `scripts/camfix/libcamfix.m` 构建，不会安装本轮负向对照的旧文件。

## 恢复与范围

客户机 `libvcamcaptured` 和 libcamfix 均在操作前备份，结束时还原后重新下载并逐字节比较。还原哈希分别为 `ffd0401e…68cf4` 和 `7bd7ec7c…34b80e`。两份 `/tmp` 暂存文件已删除，`cameracaptured` 已重启。rig2 宿主退出码为 0，socket 已删除，任务锁释放。

临时 AMFI 放行只匹配 `.build/e6-final/.build/vphone-cli.app`，结束后已停止。主 VM 原宿主 PID 21605 仍运行，Disk.img 持有者仍为 PID 21608。

本次结果只适用于上述精确 EXP 组合和当前配套组件。没有验证其他系统版本、固件变体、所有相机应用或视频编码格式。
