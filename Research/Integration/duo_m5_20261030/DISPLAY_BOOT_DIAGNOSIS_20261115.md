# 显示与启动诊断（2026-11-15）

本轮处理 TASKS.md 第 4 项，保留原生 Snapshot。证据目录为 `.build/followup-3-5-20261115/`。宿主准入后已完成新的方向矩阵、两轮实际录制及来源比较。新增复现包括 Safari 方向恢复失败，以及启用原生采样的一轮录制中 5 个近黑样本。近似静止画面、方向失败和冷启动失败的完整原因仍未查明。

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

这与此前内屏右横屏请求的实际拒绝记录一致；不将拒绝计为内屏右横屏实现通过。现有宿主 UI 的界面方向选项不能扩充 guest relay 的设备姿态枚举。宿主获准后新增实测见后文；方向与拒绝断言分别保存。

## 冷启动证据

`Regression/boot-evidence-report.mjs` 将历史失败、恢复启动和本轮宿主拒绝分开报告：

| 记录 | 观察结果 | 验证限制 |
| --- | --- | --- |
| `contract-session.E6EeraJ5` | VM started、host control listening、early boot complete；DriverKit 等待／找不到 server 各 3 条；没有 vphoned HTTP 连接；后来按批准发送 SIGINT | 没有失败时 guest worker／supervisor 状态，无法区分服务未启动、崩溃、VSOCK 服务异常等原因 |
| `contract-session.nylzAtsG` | DriverKit 等待 2 条、找不到 server 0 条；RPC 已连接，最后正常 system off／Guest stopped | 成功重试不证明前一次故障已修复 |
| 本轮 `mixed-session.Q0cEXnsC` | boot.log 为空，宿主预检明确 AMFI 拒绝；没有 guest 启动或状态文件句柄 | 属于宿主准入失败，不计为同一 guest 冷启动问题复现 |

DriverKit 日志不能单独证明 RPC 未连接的原因，也不能把 AMFI 拒绝归因于 guest。上表保留准入前历史；准入后的失败和成功启动分别见后文。没有将成功重试作为故障已修复的证据。

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

准入前的分析未修改录制器、FoldDisplay、姿态 API 或系统库。后续获准的运行验证包含临时 SystemHook 替换及回滚、隔离副本设置和 trace 标记恢复；本轮未改动生产源码。

## 准入后的启动与回滚

CDHash `974031b5…` 经用户批准加入 amfid allowlist，宿主预检通过。foundation 的 `mixed-session.kzVTD1HI` 进入 guest，摄像头 VSOCK 1338 连接，但 HTTP health 超时，RPC 未连接。该次未获得失败时的 guest 进程、堆栈或 VSOCK 服务状态，原因未查明。驱动曾报告正常关机未完成，随后进程与状态文件句柄消失；退出方式未记录。本轮未向它发出停止信号，不记为正常关机。

其后 `foundation-cold.Yvgr8IYP`、摄像头会话及回滚后 `foundation-cold.vcjedef1` 成功连接。最终回滚冷启动核对原 daemon／标记、21 项原库、根只读、Auto-Lock 120 秒，通过后正常关机，无状态句柄。新 CFW 副本 `cfw-cold.oOJWgOQf` 与保存版入口 `cfw-cold.ayt7RfkO` 也均连接成功。它们不排除间歇启动故障。

## 方向矩阵与失败

保存入口为 `Regression/followup-orientation.mjs`，先读取 App Info.plist，要求 iPhone 方向声明含 portrait、landscape-left、landscape-right。Preferences 只有 iPad 方向数组，不能代替外屏 iPhone Safari 场景。foundation 的 Preferences 和 Safari 失败均保留；没有删除不符合预期的结果。

候选 CFW 的 `orientation-cfw-final/results.json` 中，外屏 0°／90°／270°、内屏 0°／90°／180°均读回目标角度，原生截图 display ID 分别为 1／7。外屏 180°、内屏 270°明确返回 `invalid_param` 和 `the host controls have no upside-down orientation`。但该次 finally 从 Safari 恢复外屏 0°失败，整次命令退出 1；直接再次请求 0°仍失败，切回 Home 后恢复 0°成功。

脚本据此增加 Home 清理、锁屏状态等待、原姿态断言，以及独立保存主流程错误和恢复错误。`orientation-cfw-restored` 再次运行时，外屏初始 0°请求失败且实际保持 90°，其余 7 项符合预期；finally 恢复原合盖 0°、锁屏、Auto-Lock 120 秒及旋转锁原值。该命令仍退出 1，方向回归未整体通过。

进一步的缩减尝试发现，`apps.launch` 返回成功后，后续读取仍可能是 Home；这影响方向测试前提。脚本增加两次连续 verified 前台读回，要求测试过程中仍为 Safari，并保存 `display.capture_active` 的 unavailable 回复。一次 `orientation-cfw-foreground` 在处理缺少 base64 的截图回复时抛出证据处理异常；脚本随后按 available 字段判断，保留不可用结果为失败而不尝试解码。最终 `orientation-cfw-availability` 的 8 项角度／拒绝／来源检查和原状态恢复全部通过，命令退出 0。上述改动仅修正回归资产；没有改动产品方向实现，不能认定此前失败已由产品修复。

原生截图字段 `orientation_mapping_verified=false`、`capture_content_verified=false` 继续保留。来源身份匹配不能替代内容方向的像素验证；外屏 90°截图的 FrontBoard interface orientation 仍为 1，不能将所有角度的元数据解释为场景内容已经正确旋转。

待验证假设及预测：

1. 相同的设备姿态未重新发送方向事件。`libvphonehinge.m` 仅在 `state.orientation != self.orientation` 时调用 `dispatchOrientation`。预测：Safari 恢复横向场景后，直接请求已存储的 portrait 失败，先请求另一个方向再请求 portrait 可成功；仍需排除下游行为。
2. Safari 场景拒绝目标方向。预测：即使显式改变设备方向再请求 portrait，Safari 仍失败，Home 可成功。
3. 面板／场景切换未稳定。预测：延长同一请求前的稳定窗口或重复请求会改变结果；需保存实际状态和事件，不能用延迟猜测修复。

`Regression/followup-orientation-repro.mjs` 保存三次 Home／Safari 恢复循环、重复 0°请求、90°→0°对照以及 hinge 配置／状态。该入口仍以所有 portrait 请求生效作为成功条件，不把预期复现失败改为通过。

缩减尝试的结果：初版 3 次 portrait 请求均生效，但未断言横向前提，因此不计为原失败的稳定复现。加入实际 270°前提后，`orientation-resume-checked` 第 2 次循环的准备失败，前台读回为 Home。再加入 verified 前台稳定检查后，`orientation-resume-foreground` 的 3 次 portrait 请求均生效，原失败未复现。三个待验证假设仍未区分；缺少带有效场景前提、可稳定复现原方向失败的反馈，不实施基于去重条件的推测性修改。

## 新录制与无原生截图采样对照

两轮都使用同一 CFW 启动、候选 daemon `c04e362a…`、FoldDisplay `a96179b7…`、动态本机 Safari 页面、原生 Snapshot、`--guest-clock`、相同观察与稳定窗口。`snapshot-cfw-source` 使用 `--guest=native`；`snapshot-cfw-control` 不启用该参数。两轮仍执行交接前后原生来源检查；后者仅取消连续原生截图采样，不是完全没有原生捕获。录制通过宿主原生菜单完成，MOV 起点按 uptime 与姿态请求对齐。

| 实验设置 | 结果 | 验证限制 |
| --- | --- | --- |
| 连续原生截图采样 | 6/6 交接确认；2216 MOV 帧，相邻 20–46.667 ms，无 >100 ms 空档；第 3 次合盖有 5 个近黑样本，位于请求后约 142.229–275.562 ms | `presentation-check.json` 为 false；不将此前无黑帧记录推广到本次设置 |
| 不启用连续原生截图采样 | 6/6 交接确认；2598 MOV 帧，相邻 21.666–40 ms，无 >100 ms 空档；六个观察窗口无近黑样本；最长非黑相同缩略亮度区间约 700 ms、22 帧，位于第 1 次开盖 | 单轮对照不能证明连续原生捕获是黑帧原因；重复亮度现象仍存在 |

连续采样轮第 3 次开盖的最长非黑相同缩略亮度区间约 533.333 ms、17 帧。其内有两个完整包含、来源匹配的内屏原生请求，但两者均为近黑采样且摘要相同，不能据此证明有效源画面在更新，也不能证明保持层 scanout 内容。400 ms 与 233.333 ms 的另外两个重复区间没有完整包含的正确目标源请求。

两轮第 3 次开盖均由 0°变为 90°，合盖由 90°回到 0°；旋转锁设置及请求 portrait 不等于全程纵向。CPU hold 事件和原生采样继续按各自时间窗口解释；`attached=0` 等记录仍不能证明 scanout 可见性。

连续采样轮第 3 次合盖的 CPU commit 区间为请求后 10.020–67.216 ms，release 区间为 992.301–1049.521 ms；5 个近黑 MOV 样本均位于两个请求边界之间。首个 hold_frame_update 区间为 38.939–96.159 ms。上述事实仍不证明保持层已经在该窗口持续显示；不能仅调整 release 延迟来声称修复黑帧。

执行命令为 `Regression/f5-motion.zsh <CFW socket> <new output>/motion c04e362a… 192.168.65.1 --guest=native --guest-clock`；对照将第五个参数改为 `''`。两轮均实际运行 MOV timing、alignment、hold report 和 presentation check；连续采样轮另运行 source report。完整参数和回复保存在 `.build`，报告失败保留原退出码。两轮结束均恢复 trace=0、原姿态、锁屏、旋转锁和 Auto-Lock，根只读；没有改变 Snapshot 策略或延长保持时长。
