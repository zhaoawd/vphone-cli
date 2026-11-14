# F5 动态画面来源检查（2026-11-14）

本记录继续 [MOV 实际对齐](ACCEPTANCE.md#mov-与姿态请求实际对齐2026-11-14)。
范围为已获准的 `duo-rpc-accept-205443` 隔离副本和 CDHash
`d85f81edab6cc06b9589205ecec130585ac941e8` 的 Bundle。下述已完成的来源对照未更新 guest 组件或二进制补丁；
末节另行记录保持层诊断组件的准备状态。
结果只能说明本次采集的画面；重复画面与近黑样本的原因尚未确定。

## 复现与判据

以下命令重新解码原始 MOV，并检查已确认交接的请求后观察区间：

```zsh
node Research/Integration/duo_m5_20261030/Regression/f5-presentation-check.mjs \
  .build/duo-sync-20261113/runtime/aligned-mov.PMuQoYWe 0-3-closed
```

实际返回码为 1，输出 `ok: false`，第三次合拢检出 4 个近黑采集点，分别位于请求后约
302、467、502、541 ms。保存结果为该目录的 `presentation-check.json`。
该诊断判据要求所选交接不出现近黑 MOV 样本；重复亮度样本只作为测量结果，不设置额外的停帧阈值。
单段重放无需重新启动 VM；实际运行实验仍需冷启动、等待 guest 稳定并完成 6 次开合。

## 待验证假设与实验设置

按检查顺序列出预测，尚未作为原因结论：

| 待验证假设 | 预测与区分方法 |
| --- | --- |
| guest 活动显示输出已近黑或重复 | 同步 `display.capture_active` 也可能采到对应图像；须核对源身份和请求时间区间。 |
| FoldDisplay 的 scanout 合成或保持路径出现问题 | guest 活动显示继续变化，而宿主 MOV 保持相同样本或近黑。 |
| 宿主截图或 MOV 写入路径出现问题 | 比较 guest 原生截图、宿主 RPC 截图和 MOV；请求窗口重叠本身不证明同一瞬间的状态。 |

`f5-motion.zsh` 新增可选参数 `--guest=native` 或 `--guest=screenshot`，使用已有的
`f5-clock.mjs` 并行采样。对照不传该参数。`clock.json` 记录采样方式。
启动、菜单录制和关机由 `.build/duo-sync-20261113/run-recording-align.zsh [--guest=native]` 执行。
各轮保持相同 Bundle、vphoned 哈希、页面、3 次展开和 3 次合拢、1800 ms 观察与 2400 ms 等待。

`f5-clock-report.mjs --dual` 保存每张原生截图的文件名和 64×64 亮度 SHA-256。
`f5-source-report.mjs <evidence>` 比较 guest 请求窗口与 MOV。只有源身份稳定、来源为目标面板、
且完整请求窗口位于 MOV 重复段内部的截图才参与重复画面比较，边界保留 2 ms 的量化余量。
不同来源的哈希不直接比较。报告将近黑采集点与重叠的 guest 请求逐项列出，不将重叠等同于同时采样。

边界和来源检查的保存回归：

```zsh
node --test Research/Integration/duo_m5_20261030/Regression/test-f5-source-report.mjs
```

3/3 通过，覆盖完整窗口及量化余量、排除身份不稳定及非目标面板、缺失图像和重叠窗口的保守表示。

## 首轮同步原生截图

证据为 `.build/duo-sync-20261113/runtime/aligned-mov.2TopBnPk/`。
运行参数为 `--guest=native`，脚本返回 0；6/6 次交接由前后截图来源和 FoldDisplay 日志确认。
MOV 共 1528 帧，首末相隔 50.9 秒，相邻间隔 21.7–43.3 ms，无超过 100 ms 的采集间隔。
3 次合拢各检出 10 个 MOV 近黑样本，3 次展开均未检出。

guest 原生截图在第一次展开及前两次合拢的目标面板上也有近黑图像。逐像素检查这三张 PNG：
RGB 均为 0，alpha 均为 255，结果保存在 `guest-dark-pixels.json`。
它们是 guest render-server 调用得到的不透明纯黑图像；私有渲染 API 不返回渲染错误状态，
源身份在请求前后一致也不提供原子显示 epoch，不能仅凭这些 PNG 判定实际 scanout 在何时呈现了黑色。

原生截图请求约需 150 ms。报告没有找到完整落入 MOV 非黑重复段、且来源为目标面板的有效请求，
因此本轮尚不能区分重复画面来自活动显示、FoldDisplay 合成还是宿主缓存。
原生采样本身调用 `CARenderServerRenderDisplay`，存在影响渲染的可能；后续交替实验未确认这种影响。

本轮正常关机请求被接受，日志记录 guest 停止，三个状态文件无打开句柄。

## 无 guest 采样对照与第二轮原生截图

在同一副本上依次冷启动，运行不带 guest 采样的对照，再重复 `--guest=native`。
每轮结束均正常关机；guest 组件和 Bundle 保持不变。

| 实验设置 | 证据目录后缀 | 确认交接 | MOV 帧数 | 全片近黑样本 | 确认交接的观察区间内近黑样本 |
| --- | --- | ---: | ---: | ---: | ---: |
| 前一轮已对齐基线，无 guest 采样 | `aligned-mov.PMuQoYWe` | 6/6 | 1372 | 5 | 5 |
| 第一轮原生截图 | `aligned-mov.2TopBnPk` | 6/6 | 1528 | 30 | 30 |
| 无 guest 采样对照 | `aligned-mov.tFQgwg9T` | 6/6 | 1503 | 53 | 53 |
| 第二轮原生截图 | `aligned-mov.nq3lHKlo` | 5/6 | 1424 | 123 | 91 |

所有目录均位于 `.build/duo-sync-20261113/runtime/`。本轮新增的三段 MOV 均无超过 100 ms 的采集间隔。
无 guest 采样对照仍出现近黑，现有数据不支持把近黑样本数量变化归因于原生采样。
轮次没有随机化，且实际方向状态存在差异，不能把各轮数量用于采样开销的因果比较。

方向限制逐项保留：第一轮原生截图的第一次展开采样中短暂出现 90°；无 guest 采样对照的
第二次合拢为 0°→270°，第三次展开为 270°→0°，第三次合拢采样中出现 90°。
第二轮原生截图的第一次合拢为 90°→0°。其余交接的请求前后和宿主采样方向均为 0°。
即使只检查始终采到 0° 的交接，无 guest 采样对照的第一次合拢仍有 9 个 MOV 近黑样本；
第二轮原生截图的第二次合拢、第二次展开、第三次合拢和第三次展开也都检出近黑。
这不支持把本批所有近黑样本都归因于观察到的方向变化。

第二轮原生截图的首次展开，前后截图来源符合预期，但请求附近没有匹配的 FoldDisplay
归属日志，`handoff.tsv` 为 `log_mismatch`，整轮脚本按断言返回 1。
该次未纳入已确认交接；未修改或绕过断言。已将双路图像报告移动到最终交接断言之前生成，
使后续失败轮次也保留分析输出；本轮缺失的 `dual.tsv` 已由原始采样文件单独生成。

第二轮的第二次展开及第三次合拢各有一张来源为目标面板、身份前后一致的原生纯黑 PNG。
保存命令如下，两张图片逐像素检查均为 `maxRGB: 0`、`minAlpha: 255`、`maxAlpha: 255`：

```zsh
reg=Research/Integration/duo_m5_20261030/Regression
out=.build/duo-sync-20261113/runtime/aligned-mov.nq3lHKlo
node "$reg/f5-png-pixels.mjs" \
  "$out/motion/samples/0-2-open/guest-12.png" \
  "$out/motion/samples/0-3-closed/guest-8.png"
node "$reg/f5-source-report.mjs" "$out"
```

原生 PNG、宿主 RPC JPEG 和 MOV 均观察到近黑，现象不只存在于 MOV 文件。
这些结果支持继续检查 guest 显示输出与 FoldDisplay 的保持及合成边界；它们仍不能确定
guest 实际 scanout、原生渲染调用和宿主采集之间的先后或因果关系。
第二轮同样没有找到符合完整包含及目标源条件的 guest 请求落入非黑 MOV 重复段。

## 当前结论与下一步

近黑已在重复运行中复现，guest 原生输出路径中已取得不透明纯黑图像。
近黑和非黑重复样本的原因仍未查明。当前采样速率不足以判断短重复段内活动显示是否继续更新。
下一步需要记录保持层的源图像内容、启用及释放边界，并使用单调时钟关联 scanout 采集；
仅延长固定保持时长或按本批数量调整延迟缺少原因证据。

本轮没有修改产品代码或应用新的二进制补丁。录制时钟和来源比较回归已合并到
`run-recording-timeline-tests.sh`，宿主执行 8/8 通过，并确认 MOV 保留 320 ms 的采集间隔。
日志为 `.build/duo-sync-20261113/presentation-source-tests.log`。三轮副本均正常关机，
三个状态文件均无打开句柄；第二轮原生截图的验收失败仍作为失败保留。

## 保持层内部诊断准备

继续区分以下待验证假设：保持层捕获时源图像已黑；源图像正常但保持层未覆盖 scanout；
保持层释放后目标显示尚未恢复。本节先记录准备方案，实际执行与验证限制见下节。

`FoldDisplayTrace.m` 仅在 `/var/mobile/Library/Caches/vphone-folddisplay-trace.enabled` 首字节为 `1`
时输出 `[DEBUG-f5-hold]` JSON。写入 `0` 可关闭。事件为：

| 事件 | 记录内容与限制 |
| --- | --- |
| `swap` | 现有保持条件是否满足、当时面板归属和点亮时间。 |
| `hold_source` | 现有 Main 渲染结果的 8×8 BGRA 栅格，包括 alpha、surface ID 及渲染前后 uptime；不新增渲染。 |
| `hold_on_commit` | 保持层的 CPU 侧提交请求已发出；不证明 scanout 已显示该层。 |
| `hold_follow_owner` | 保持层跟随的新面板归属。 |
| `target_content_detected` | 原有内屏探测已判定有内容，另存同一探测 surface 的栅格。 |
| `hold_off_request` | 释放请求前该层是否仍附着、hidden、opacity、释放原因。 |

事件含 guest 启动 UUID、PID、保持 generation 和 `NSProcessInfo.systemUptime` 采样边界。
默认关闭时不构造诊断字典或读取像素。开启时的 surface 锁和日志写入仍可能影响时序，须另做关闭诊断的对照。
原有保持条件、内容判据和释放决策未改变，不能把本组件当作已验证修复。

`f5-clock.mjs --guest-clock` 在每次交接前后各读五次 `device.info`，保存宿主发送、接收时刻和
guest uptime。已核对 daemon 依赖中的 uptime 来源同为 `NSProcessInfo.systemUptime`。
`f5-hold-report.mjs` 使用全部请求窗口的 offset 交集对齐；启动 UUID 改变或交集为空时拒绝对齐。
报告给出时钟误差区间，MOV 边界另计一个 1/600 秒 tick；与边界重叠的样本标记为不确定。
“提交请求与释放请求之间”不等同于该层已呈现在 scanout。

只读准备及校准轮证据为 `.build/duo-sync-20261113/runtime/aligned-mov.bcXCYf2x/`。
6/6 次交接确认，guest 组件未替换；根文件系统为只读。前后校准的交集宽度为约 53.9–56.3 ms，
仍不足以给出逐帧精度。后续校准请求已显式设置 `screen: false, delay: 0`，其误差需实际回读验证。
原组件已完整备份至 `original-folddisplay.dylib`，副本正常关机，状态文件无打开句柄。

临时替换范围已经固定在 `f5-trace-deploy.mjs` 中：

- 仅接受当前仓库内的 `duo-rpc-accept-205443/vphone.sock`，校验当前 daemon 哈希。
- 原库 SHA-256：`c95fbf375e8ee3028e2399e3cf66f38eeacdf86e65e9da9175837994a3a076b1`。
- 诊断库 SHA-256：`f123428bb2bbede39df0cc1299b6324660e001a590f4fdf4075547ee3a18ca20`。
- 通过现有 `environment.install` 只替换 `/usr/lib/libvphonefolddisplay.dylib`，该接口临时重挂根文件系统并恢复原挂载模式；随后启用诊断并执行 `system.respring`。
- 采集六次开合后恢复原库，再次 respring；核对原库哈希、其他环境库哈希及根挂载模式。
- 原来没有诊断标记时，结束后写入 `0` 保留关闭状态。回滚失败时保留 VM 运行供修复，脚本不会继续发送关机请求。

已准备的执行命令为：

```zsh
zsh .build/duo-sync-20261113/run-recording-align.zsh '' --guest-clock --install-trace
```

组件编译和严格签名校验通过，像素栅格 9 项检查通过；完整 Debug Bundle 构建、深度严格签名及
宿主预检通过。VM 程序签名未变化，无需新增宿主 allowlist。11 项录制、来源及保持层报告回归通过，
MOV 的 320 ms 采集间隔检查通过。日志位于 `.build/f5-hold-trace/`。
用户随后明确批准本轮诊断、临时替换及回滚。实际执行与修正记录如下。

## 保持层内部诊断实际执行与回滚

证据位于 `.build/duo-sync-20261113/runtime/aligned-mov.0OdHcU7G/`。
实际运行中，`VPhoneGuestControl.syncEnvironment()` 在连接时先同步 Bundle 内不同的 guest 库。
启动日志记录仅安装了 `libvphonefolddisplay.dylib`。因此，手工部署准备步骤读到的已是诊断库
`f123428b…`，该轮 `original-folddisplay.dylib` 也误存成了诊断库，不能用于恢复原库。
诊断库实际哈希符合批准范围，SpringBoard 经 `system.respring` 重启至 PID 468 后完成六次姿态请求。

原计划未核对自动同步路径，这是执行脚本的备份来源错误。该轮 `trace-deployment.json`、
`install-verified.json` 和 `restore-verified.json` 保留原始内容；其中“原库”和回滚结果均指诊断库，
不作为最终恢复成功证据。真实原库来自只读准备轮 `aligned-mov.bcXCYf2x/original-folddisplay.dylib`，
SHA-256 为已批准的 `c95fbf37…`。

### 实际诊断数据及限制

MOV 为 1436 帧，首末相隔 47.833 秒，采集间隔 26.7–40.0 ms，无超过 100 ms 的采集空档，
共检出 61 个近黑采集点。六次均有目标面板归属日志，但三次内屏截图均返回
`source_unavailable`，原因为 `FrontBoard identity does not uniquely match a named CoreAnimation display at the same scale`。
相邻合拢的内屏前置截图也不可用。因此，六次均未满足双来源交接判据，整轮脚本返回 1，
交接验收为 0/6。报告保留 `handoffVerdict: unconfirmed`，未跳过或弱化断言。

以下是这一失败轮中的内部观测，不替代有效面板交接验收：

| 请求 | 保持源 64 点的最大 RGB | alpha 范围 | MOV 近黑样本数 | 明确位于提交请求与释放请求之间的近黑样本数 |
| --- | ---: | --- | ---: | ---: |
| 第一次展开 | 0 | 255–255 | 22 | 20 |
| 第一次合拢 | 206 | 255–255 | 6 | 3 |
| 第二次展开 | 0 | 255–255 | 12 | 9 |
| 第二次合拢 | 205 | 255–255 | 5 | 2 |
| 第三次展开 | 0 | 255–255 | 11 | 8 |
| 第三次合拢 | 204 | 255–255 | 5 | 1 |

三次展开的保持源采样点均已黑；三次合拢的保持源采样含非黑像素，仍在 CPU 侧保持区间观察到近黑。
释放前记录均为层仍附着、`hidden: false`、`opacity: 1`，这不证明该层已经显示在 scanout 上。
每次合拢和第三次展开还各有一个近黑采集点明确晚于释放请求。其余边界样本保留为不确定。
这些数据支持继续核对保持源时序及保持层到 scanout 的关系，不能据此把全部近黑归为同一原因。
原因仍未查明，不能仅按固定延迟调整释放时刻。

guest／宿主时钟 offset 交集宽度为 54.4–57.5 ms，显式设置 `delay: 0` 后仍没有获得逐帧精度。
报告另计一个 1/600 秒 MOV tick，按最保守边界分类。诊断时 guest 根文件系统已为可写，
与准备轮的只读状态不同；本轮数据不能直接用来估计开启诊断造成的画面变化。

### 最终恢复与执行脚本修正

`withWritableRoot` 的源码明确处理了 live APFS 只读重挂失败：根文件系统可能持续可写，需冷启动恢复。
本次先将运行 Bundle 的 FoldDisplay 资源恢复为真实原库并重新封装签名，使自动同步的目标也是原库。
诊断组件另存于 `.build/f5-hold-trace/stage/folddisplay/` 及 `bundled-diagnostic-before-rollback.dylib`。
随后执行 `.build/f5-hold-trace/restore-original.zsh`，证据为 `.build/f5-hold-trace/rollback.bn3w1xA0/`：

1. 第一次冷启动自动恢复原库，全部环境库哈希与只读准备轮一致；根仍为可写，随后正常关机。
2. 第二次冷启动再次核对全部环境库哈希，根为只读；正常关机，状态文件无打开句柄。

最终恢复的是 `c95fbf37…` 原库；其他环境库哈希均保持原值。诊断标记为 `0`。
当前运行 Bundle 也已恢复原库资源并重新通过深度严格签名检查，VM 程序未改动。
后续重新构建会再次打包诊断组件，诊断运行脚本现在在启动 VM 前核对 Bundle 的 guest 库来源。

执行脚本增加固定原库和候选库哈希检查，并要求初始根为只读；不再从当前已安装库任意推导“原库”。
恢复报告将“库字节已恢复”与“根挂载模式已恢复”分别记录。live 只读重挂失败时明确要求冷启动校验，
不会把可写状态记为完整回滚成功。新增回归在缺少防护时复现 3 项失败，修正后 4/4 通过；
录制及报告回归共 15/15 通过，日志为 `.build/f5-hold-trace/final-recording-tests.log`。

### 原库来源和常亮对照（2026-11-14）

本轮未替换组件，在原库上复现了重启 SpringBoard 后的来源拒绝。
`system.respring` 同时更换 backboardd PID，FrontBoard 内屏 UUID 改变，
存活 vphoned 的 CADisplay UUID 保持旧值；比例均为 3。
单独重启 vphoned 后，UUID 一致且原生截图恢复。class／instance 刷新没有
修正旧进程读值，独立新脚本进程能读到与 FrontBoard 一致的新 UUID。
该结果确认显示信息生命周期导致来源拒绝，不解释有效来源下的黑帧或重复画面。

未截断的过滤日志确认常亮合拢有 SpringBoard 的 `DisplayContentModeTransition`
点亮请求，展开先有 `ExternalRequest`、`LockButton`。低电量模式下真正熄屏的
开合对照也会点亮，设置已恢复。七轮实验前后 21 项环境库摘要相同、根只读，
均正常关机且状态文件无打开句柄。命令、UUID、PID 和验证限制见
[三项诊断](THREE_ISSUES_20261114.md)。

### 最终修复与原生 Snapshot 策略（2026-11-14）

用户已选择保留原生 Snapshot。最终 T2 不覆盖原生样式，不修改暗化设置；临时直接内屏接续实验已移除。保持层在原生过渡入口捕获有效画面，使用预先绑定 Main 的独立 displayable CAContext，镜像排除自身的原生根 context 内容；底层为黑时保留最后有效帧。电源请求前更新面板归属。原生 did-change／postflight 回调覆盖没有 App 交换回调的 Home 路径；postflight 后两个非黑探测再加 1/30 秒释放。内容期限 2 秒，外层期限 12 秒；旧代次和旧目标 epoch 不得释放新保持。

最终两轮原生 MOV：

| 实验设置 | 证据 | 结果 |
| --- | --- | --- |
| Home，六次 10 秒 continuous sweep | `.build/duo-fixes-20261114/live-recording.Zk5F4a9d/` | 六次均为原生 `.continuousLive`，交接均确认，六个观察窗口无近黑样本；保持 9494–9553 ms 后按有效内容释放，无超时。 |
| 冷启动动态 Safari，六次开合 | `.build/duo-fixes-20261114/cold-record.Q0ubnxdi/` | 六次均为原生 `.continuousSnapshot`，交接均确认，六个观察窗口无近黑样本；最长非黑重复亮度区间约 431.666 ms，14 张，内部最大间隔 35 ms。 |

两轮采到过渡方向变化，未计为全程固定纵向。Home／Safari 的录制起点分别有约 223.333／211.667 ms 间隔，均在交接窗口之外。未宣称整个 MOV 无超过 100 ms 的间隔，未宣称重复画面全部消除或全部原因已确定。

Safari 冷启动前后根均只读，全部 21 项环境库摘要一致，最终组件摘要匹配；trace 恢复 0、正常关机、状态文件无打开句柄。最终 AOD、熄屏唤醒、AX 和显示身份生命周期回归均通过。源码与测试、首轮长扫动窗口错误、完整构建和原组件恢复见 [修复执行记录](FIXES_20261114.md)。本节替代早期候选的待验证状态，不改写历史实验结果。

最终回滚完成：`cold-rollback.Kv83eQrk` 恢复原组件，`cold-verify.hUSuyJ0t` 冷启动核对原 daemon、原 FoldDisplay、21 项库、根只读、trace=0、低电量模式及旋转锁原值；随后正常关机，状态文件均无打开句柄。候选 Bundle 与源码保留，隔离副本当前运行组件为基线原版。
