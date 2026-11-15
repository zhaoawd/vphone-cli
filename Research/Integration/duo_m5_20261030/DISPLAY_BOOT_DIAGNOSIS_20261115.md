# 显示与启动诊断（2026-11-15）

本轮处理 TASKS.md 第 4 项，保留原生 Snapshot。证据目录为 `.build/followup-3-5-20261115/`。新增全尺寸像素分析、启动阶段报告和对应负例；原问题的完整原因仍未查明，右横屏新的实机验收尚未完成。

## 约 432 ms 区间的测量范围

复放 `.build/duo-fixes-20261114/cold-record.Q0ubnxdi/recording.mov`，保持原始 PTS，不重采样为固定帧率。此前报告使用 64×64 灰度采样摘要。最长非黑相同摘要区间位于 PTS 10.981667–11.413333，14 个样本、约 431.666 ms，最大相邻间隔 35 ms；对应已确认交接 `0-1-open`。

新增 `Regression/f5-frame-detail.mjs` 对该区间按原尺寸 1398×2034 解码为 RGBA，得到 14 个不同完整摘要。相邻帧 RGB 平均绝对差为 0.000770286–0.000994421（通道值范围 0–255），任一通道最大差为 5；没有像素的 RGB 通道差超过 8。独立的全片 `framemd5` 结果也确认该 14 帧摘要各异。

因此，现有证据支持“缩略亮度样本相同、全尺寸解码像素存在极小差异”。它不支持将这些样本称为逐像素相同的 MOV 帧。差异可能包含编码差异或小范围内容变化，不能据此证明源画面持续更新，也不能认定观察到的近似静止画面已消失。

## 保持事件对齐

复用已有单调时钟区间，约 54.996 ms 的时钟不确定性继续保留，不将事件压缩为精确时刻：

| 事件 | 相对姿态请求的区间 |
| --- | --- |
| CPU `hold_on_commit` | 13.685–68.681 ms |
| 相同缩略亮度样本 | 303.649–735.315 ms |
| 首个 `hold_frame_update` | 692.755–747.797 ms |
| CPU `hold_off_request` | 892.870–947.891 ms |

该亮度区间完整位于 CPU 提交与释放请求之间；首个源更新事件的不确定区间与末段重叠。释放记录的 `attached=0`，这些 CPU 记录不能证明保持层在整个区间实际显示于 scanout。`snapshot-repeat-timeline.json` 同时保留这些范围及限制。

后续待验证假设按当前证据排序如下；本轮没有用它们修改延迟、强制 Live 或绕过系统策略：

1. 保持源在该段主要使用初始 Snapshot。预测：正确目标面板的原生源采样在完整包含的请求窗口内保持近似不变，变化边界与源更新事件关联。
2. 源已变化，但合成／scanout 尚未体现。预测：同一窗口的正确来源原生截图已变化，宿主记录仍近似静止；须额外确认保持层可见性。
3. 宿主采集或编码路径复用了近似静态内容。预测：源与独立显示采样均已变化，只有 MOV 输出未跟随。当前极小 RGBA 差异本身不能区分这种情况。

区分这些假设仍需实际运行：原生截图请求窗口必须完整落在观测区间内，并确认面板、来源、方向和时钟。已有历史采样没有提供充分的同窗口源进度证据。只延长保持时长或改变过渡策略缺少原因依据。

## 右横屏与方向变化

当前 `GuestAPI+Device.swift` 的 foldable rotation 映射如下，`libvphonehinge.m` 的 orientation picker 没有 device orientation 2（upside-down）。CoreMotion relay 开启时，daemon 对该值明确拒绝。

| 请求的界面角度 | 外屏 device orientation | 内屏 device orientation |
| --- | ---: | ---: |
| 0° | 1 | 3 |
| 90° | 4 | 1 |
| 180° | 2，relay 拒绝 | 4 |
| 270°（右横屏） | 3 | 2，relay 拒绝 |

这与此前内屏右横屏请求的实际拒绝记录一致；不将拒绝计为右横屏覆盖通过。现有宿主 UI 的界面方向选项不能扩充 guest relay 的设备姿态枚举。本轮 VM 未进入 guest 启动阶段，因此没有新增的外屏 270°通过、内屏 270°拒绝或过渡方向实测。后续应分别断言支持的姿态结果及不支持姿态的拒绝，不能仅检查请求返回成功。

## 冷启动证据

`Regression/boot-evidence-report.mjs` 将历史失败、恢复启动和本轮宿主拒绝分开报告：

| 记录 | 观察结果 | 验证限制 |
| --- | --- | --- |
| `contract-session.E6EeraJ5` | VM started、host control listening、early boot complete；DriverKit 等待／找不到 server 各 3 条；没有 vphoned HTTP 连接；后来按批准发送 SIGINT | 没有失败时 guest worker／supervisor 状态，无法区分服务未启动、崩溃、VSOCK 服务异常等原因 |
| `contract-session.nylzAtsG` | DriverKit 等待 2 条、找不到 server 0 条；RPC 已连接，最后正常 system off／Guest stopped | 成功重试不证明前一次故障已修复 |
| 本轮 `mixed-session.Q0cEXnsC` | boot.log 为空，宿主预检明确 AMFI 拒绝；没有 guest 启动或状态文件句柄 | 属于宿主准入失败，不计为同一 guest 冷启动问题复现 |

DriverKit 日志不能单独证明 RPC 未连接的原因，也不能把本轮 AMFI 拒绝归因于 guest。原冷启动故障缺少可稳定重现的运行反馈；在获准宿主运行条件恢复前，只完成证据复放与回归准备，不实施推测性修复。

## 回归与结果

```zsh
node Research/Integration/duo_m5_20261030/Regression/test-followup-evidence.mjs
node Research/Integration/duo_m5_20261030/Regression/f5-frame-detail.mjs \
  .build/duo-fixes-20261114/cold-record.Q0ubnxdi/recording.mov \
  .build/duo-fixes-20261114/cold-record.Q0ubnxdi/movie-timing.json
node Research/Integration/duo_m5_20261030/Regression/boot-evidence-report.mjs \
  .build/rpc-contract-next-20261115/contract-session.E6EeraJ5/boot.log
```

12 项证据处理检查通过，覆盖 RGB／alpha 区分、像素阈值、尺寸拒绝、启动阶段区分和 DriverKit 错误不自动推定原因。全尺寸解码和三个真实日志报告已执行；早期 FFmpeg filter 转义失败保留，修正后执行通过。工具仅用于构建机诊断，不新增产品 runtime 依赖。

本轮没有修改录制器、FoldDisplay、姿态 API、系统库或 VM 设置。新的运行验证被宿主准入阻塞；原因定位与完整方向覆盖仍未完成。
