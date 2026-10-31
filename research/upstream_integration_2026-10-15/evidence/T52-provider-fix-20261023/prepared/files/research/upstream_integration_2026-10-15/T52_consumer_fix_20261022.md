# T52 应用消费修复候选（2026-10-22）

当前结果：功能候选 `2.6.2-local.cc05d88f441f` 已按补充批准部署。定位两个坐标点各收到 5 条七字段正确回调；相机 v3 双层复制回执通过。QR 消费失败：相机授权状态为 3（Authorized），公开设备列表为空，原生视频源返回 0。T52 整项 `accepted=false`。原探针程序已恢复并停止；相机、定位来源均为 off。

## 证据与修改

同版本只读采集取得 CMCapture UUID `56F23E85-0EA1-34F1-AAEC-FFE67067538A` 的指令和 Objective-C 方法。`FigCaptureSourceCopySourcesForClientAuditToken` 使用 `FigCaptureSourceBackingsProvider -sourceBackings`。原实现直接追加 `_sSourceList`，并尝试修改代码页；实际日志已记录代码页修改失败。候选改为在原生 provider 返回值中合并一个虚拟 backing，保留其他原生来源，由系统继续创建客户端来源。此修改能否解决真实空设备列表，仍待 VM 验证。

定位的 classic 来源归属接口此前没有发布应用端读取的桥接文件。新增显式 v2 定位布局，把完整七字段、generation、delivery_sequence 和发布时间原子写入 `/var/mobile/Library/SimulatedLocation/location.json`。实际发布端与读取端回归已覆盖归属冲突、序列冲突、相同请求重试、第二坐标、错误来源停止和有效停止。无效或过期状态回退原生 API；默认 native 布局保持原行为。classic 发布端在自身存活期间刷新时间，保持原 generation/序列；刷新前核对文件归属，避免长宿主心跳使状态提前过期。API daemon 使用同一路径，定时刷新固定点；清除操作取消刷新。

实际探针和 cameracaptured 曾在共享帧 `open` 处返回 EPERM。候选由 launchd 针对已识别的应用及 cameracaptured 签发限定路径的进程访问凭据，经 xpcproxy 传递。应用仅获相机目录和定位目录的读取权限；cameracaptured 另获固定复制回执文件的写入权限。应用仍须通过原有相机或定位授权检查才消费凭据，消费后移除对应环境变量。回归覆盖路径、作用范围、凭据传递、重复键、现有回执保留及符号链接拒绝。实际客户机签发和消费结果尚未验证。

## 构建与验证

- 五个客户机库使用 iPhoneOS SDK 重新构建、签名和核验；GPU 插件保持基线字节。
- 独立 API 使用固定 Icli 0.8.6 依赖构建，classic/v2 候选核验通过。沙箱内缓存写入拒绝日志保留；沙箱外构建成功。
- Bundle 资源、签名、依赖摘要和宿主闭包核验通过。宿主 VM 可执行文件与 Frameworks 保持基线字节。
- 17 项初始定向回归通过。后续 API 持续刷新和事务组合 22 项通过；最新事务 9 项通过。
- 完整 Python 首轮运行 987 项，4 项跳过，1 项夹具链接错误。补齐新增共享 C 文件的链接，保留原断言；完整复验 995 项通过（4 项跳过）。定位发布端存活刷新补充后，最终定向组合 36 项通过。

归档 SHA-256：`872f31e9b0346fdc88145b5de2e1005e8f8b6dbb40ec803b4c372be904931c83`。

## 已批准部署范围（执行中）

仅正常停止并重绑 `.build/t51rt/lib/t52-v2`。独立维护事务绑定完整 Disk.img SHA-256 和六项元数据，克隆后替换五库、`/usr/bin/vphoned-api` 及 Data 卷已有发布端缓存 `/var/root/Library/Caches/vphoned`；两卷独立只读复核后原子发布。完整旧盘保留在 `.environment-history`，不授予固件或 Undo authority。若 API 缓存或其 pending 标记出现、输入摘要变化、路径为符号链接或元数据不符，事务拒绝。

部署前只读核对：原实例 `372C906F-9315-4ED3-B596-94670EEA9AAA`，仍绑定 `.56be1ce20ded`；运行 API 摘要 `9b60814f…efff101`，发布端缓存摘要 `0c3c906a…ed9332b8`，API 缓存不存在。API 大文件的普通读取因大小上限被拒绝；运行摘要来自 `device.info`，磁盘文件摘要将在正常停机后的只读检查中核验。

需要一个新的、仅针对 CDHash `89cb8ee4c9f47b15a1c63bd73c99b53a0d43a541` 的最长 900 秒、一次附加、无持久允许名单窗口。独立进程监督，到 VM 就绪即停止。原 VM、其他副本、旧 Bundle、旧盘和探针数据均保留。现有正式容器仅更新本轮已签名探针程序，用于同一定位/QR 验收。

此前授权只覆盖两个相机库的诊断替换；本候选增加三个库、API 和发布端缓存替换，已取得用户对本具名新范围的明确批准。

## 验收步骤

1. 正常停止、绑定新 Bundle，执行冻结的离线事务和独立只读复核。
2. 在新窗口中启动原 t52-v2，核实 API 与来源能力；立即结束并独立核实辅助进程状态。
3. 核实实际加载库及匹配发布端，部署并读回本轮探针程序。
4. 通过已有正常权限完成两个固定坐标的多回调验收，并验证精确 generation 停止。
5. 对两个不同 QR 内容执行相机呈现、复制回执与应用识别验收。保留所有失败，结束本轮来源及探针。

## 部署执行记录

首次安装因 Core Bundle store busy 拒绝，没有安装或改盘。正常关机 RPC 漏传 API 要求的 force 确认字段，被客户机拒绝；宿主将该拒绝记为无恢复记录的 pending_recovery。只读环境状态为 worker_idle=true、transactions=[]。保留原限制和失败记录，通过客户机系统设置“通用 → 关机 → 滑动来关机”完成正常关机，宿主记录 Guest stopped，PID98713退出，原VM PID33355保持。没有强制停止VM或直连HTTP。正在重试同一批准归档；第一次空收据及日志保留。安全窗口尚未开始。

离线预检查在挂载 Data 卷时返回 Illegal byte sequence，尚未创建写盘事务。独立只读卷信息确认 Data: FileVault=true、Locked=true；没有尝试解锁。System-only 完整克隆及启动后发布端缓存重命名替换方案已准备，12项回归通过；旧缓存完整保留，重命名失败恢复原路径。候选、目标和原批准未开启窗口保持，调整部署顺序已提交补充批准。当前VM正常停止、已绑定新Bundle，客户机库/API/缓存尚未替换，安全窗口未开始。


## 补充批准后的实际执行与验收

用户批准 Data 锁定后的顺序调整。System-only 完整克隆事务已发布，五库及 `/usr/bin/vphoned-api` 独立只读复核为 already_current。完整旧盘保留于 `.environment-history/environment-d27caf08-b214-4b7e-8347-9a0f23400404`，部署时完整摘要为 `ba9f87f07faed17f953a2366afe1998515de16c944429cba0e48258f8717647c`；后续只读复核其设备、inode、大小、mtime、权限和所有者均保持，未重新计算完整摘要。Data 未离线挂载。

新实例 `0C9D0EF5-5072-42CC-B7DD-86096210D871`、宿主 PID 4438 就绪后，单哈希辅助仅附加一次，worker 在 60.199 秒后停止。初次独立检查记录 amfid PID 4077 为 Ts；随后该进程由系统退出，服务记录 `JETSAM_REASON_MEMORY_IDLE_EXIT`。没有执行 SIGCONT，没有重新附加。旧认证请求已取消；不再需要用户完成该认证。辅助、supervisor、debugserver 和原 amfid 均不存在，清理独立确认时长上界 624.896 秒，小于 900 秒。后续服务按需启动了新的 amfid 进程。本轮没有验证窗口结束后的拒绝行为。

随后通过现有宿主接口上传匹配发布端，完整旧缓存重命名保留，仅向核实的旧 classic PID 65 发送 TERM，新 classic PID 532 连接成功。新发布端摘要为 `158112408243280d3639947a1c3ea3453550d5ea4573d570323d5ec2c7806d10`；保留旧缓存摘要为 `0c3c906aabd670968fe4947bbf68c1130f9af0c5c93216dad8ec8c80ed9332b8`。运行 API 摘要为 `f5ce73f00f5694b1639d735af8106436aaf2cfd1bd3dc7211aef6041149cd2a8`。最终五库、API、发布端、旧缓存摘要核验通过。

| 验收对象 | 结果 | 证据 |
| --- | --- | --- |
| 定位坐标 31.2, 121.5, 20 | 5 条 CLLocationManager delegate 回调，七字段正确 | location-consumer-r1/result.json |
| 定位坐标 30.25, 120.15, 35 | 5 条 CLLocationManager delegate 回调，七字段正确 | location-consumer-r1/result.json |
| 相机 v3 发布与复制 | generation、presentation_id 和帧序号匹配，实际复制回执通过 | camera-consumer-r2-authorized/result.json |
| 相机授权 | 标准公开接口返回 3（Authorized） | camera-auth-preflight-current.json |
| 公开视频设备与 QR | 设备为空，无可用输入；QR 回调未通过 | camera-consumer-r1、camera-consumer-r2-authorized |

定位来源均按对应 generation 停止。应用侧定位访问和 cameracaptured 相机读取/回执写入已取得实际结果；应用相机读取尚未进入可用设备后的消费路径。启动时诊断 open 的 EPERM 发生在访问凭据正常消费之前，不能据此认定后续消费失败。

## 相机设备枚举继续诊断

同一 CMCapture UUID 的只读采集新增 Objective-C dispatch 元数据。宿主 Capstone 解码取得 9207 个 selector 映射，确认普通客户端调用 `sharedCaptureSourceBackingsProvider` 及 `sourceBackings`。原先两个 CBZ 属于预热来源筛选分支；现有证据不能将它们写成普通视频源为空的已确认原因。

不重启相机进程的实时采集显示，本轮探针 PID 645 请求视频源时，cameracaptured 记录 `captureSourceBackings.count` 断言，并记录 `Returning 0 sources with types 1 for client 645`。进程 PID 70 和启动时间保持。当前待验证假设：provider 未成功安装、安装后 getter 未在实际调用中生效、或初始化期间覆盖了 getter。完整原因未查明。没有修改原生权限或放宽消费断言。

只读 dispatch 诊断文件超过 1 MiB，首次内联读取被拒绝；随后的停止回复超时导致原工具未进入恢复。失败记录保留。独立核实探针已经退出后，通过宿主文件下载取得完整文件，恢复原探针摘要 `02795c7a8bf30799bd309832f1bad6f70200fcc5b2bdc04cc417c773108faaee` 并读回核验。工具现改用文件下载，停止回复不确定时仍进入独立停止检查与恢复路径，3 项故障回归通过。

22 项验收工具回归在沙箱内有 1 项真实 Unix socket 用例失败；相同 22 项在沙箱外通过，原断言保持。沙箱失败和通过日志均保留。原 VM PID 33355 及 base、target、t52-environment 三个受保护副本只读复核通过。

已准备一次仅对核实 PID 70/UID 501/原启动时间的 cameracaptured 发送 TERM 并采集正常重建日志的计划，见 `.build/t52-consumer-fix-20261022/camera-restart-plan.json`。身份变化或回复不确定时不重发；不替换库、不重启 VM、不启用 AMFI 窗口。该动作超出此前仅终止旧 classic 发布端的批准范围，已请求补充批准，尚未执行。

本轮运行证据 106 项已归档并逐项核对 SHA-256，清单：`evidence/T52-consumer-fix-20261022/runtime-before-camera-restart/manifest.json`。此前 prepared 133 项及更早各批证据保持。该批冻结在相机进程重启之前；补充批准仍待答，重启尚未执行。


2026-10-23 续推：限定相机重启已获批准，核实原身份后仅一次TERM，PID809正常重建；仍无视频源。原生共享provider为nil的应用查询和同版本控制流已记录，fallback修复候选4bd0cce62c46已准备，未部署。1017项Python、9项单库事务、24项工具回归通过；新候选部署待补充批准。详见 T52_provider_fix_20261023.md；前节及106项归档反映重启前状态，保持不变。
