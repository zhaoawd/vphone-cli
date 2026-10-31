# T52 共享相机 provider 为 nil 的修复候选

候选 `2.6.2-local.4bd0cce62c46` 已按批准范围安装并部署到 t52-v2。完整克隆仅替换 libvcamcaptured，独立只读复核通过。真实应用定位两点各5条七字段正确回调，QR A、中性帧及QR B均通过；原探针程序已恢复并停止，来源均off。当前应用消费范围完成。T52整项的外置物理卷验证仍按此前要求暂缓，整项 `accepted=false`。

## 实际诊断

用户批准的限定重启已执行。首次前置检查发现探针 PID735 正在运行，工具在发信号前拒绝；该轮没有 processes.kill 请求，也没有 signal-intent。停止具名探针后，第二轮重新核实 cameracaptured PID70、UID501、启动时间1792683621.488895及两库摘要，仅发送一次 TERM。launchd 正常创建 PID809，UID501、启动时间1792686567.919082。7个重叠4秒窗口采集561条初始化日志，无采集错误；探针阶段217条日志，结束时探针停止。

日志确认 BGRA/420v 两个格式和虚拟 backing 创建成功，`native sourceBackings provider installed`。之后原生硬件来源信息仍为空，出现 `captureSourceBackings.count` 断言；视频类型1返回0个源。重启没有消除空设备现象，故没有再次发送 TERM。

同版本 CMCapture UUID `56F23E85-0EA1-34F1-AAEC-FFE67067538A` 的只读元数据确认：sourceBackings 属性声明 NSArray，实例变量声明 NSMutableArray。此前“非 NSArray 返回值”解释没有取得支持。只读控制流显示，共享 provider 在原生源信息数组 count 非0时才分配；count为0且没有既有实例时，返回 nil。该路径使用 Objective-C direct 初始化实现，运行时 selector 查询没有对应初始化方法。

正常相机授权后，临时探针调用原生共享 getter，实际记录 `providerIsNil=1`、`sharedMethodAvailable=true`、`initializerAvailable=false`。这是应用进程内的实际查询。结合新 cameracaptured 的初始化日志与同版本控制流，证据支持原生 provider 缺失使实例 getter hook 无法参与本轮枚举的解释；该阶段的daemon修复效果尚待部署验证；本轮实际结果见末节。

## 修改与回归

原实现只 hook 实例 getter。新增真实代码回归先复现 `shared != nil` 断言失败：原生共享 getter 返回 nil 时，实例 getter 的合并代码没有接收者。修复增加共享 getter hook；原生返回有效实例时原样保留，返回 nil 时仅构造一次该原生类实例，由已有实例 getter 合并实际 backing。不写框架共享实例全局变量或私有实例变量，不修改原生指令页。

5种集合/实例场景通过：nil列表、空列表、已有原生来源、重复旧虚拟来源、共享实例为nil。已有原生实例身份、原有来源和恰好一个当前虚拟 backing 的断言保留。

同权限临时探针在自身进程编入实际 backing 构造和两项 getter hook。原生共享查询先返回 nil，修复后返回 FigCaptureSourceBackingsProvider，backings 为 NSMutableArray、count=1，并包含同一个实际构造的 backing。该诊断不计为 QR 消费验收，未将 hook 安装到 daemon。结束后恢复原探针摘要 `02795c7a8bf30799bd309832f1bad6f70200fcc5b2bdc04cc417c773108faaee` 并停止。

候选仅改变 libvcamcaptured。其他库、API、classic/v2发布端、GPU、Framework及宿主VM可执行文件逐字节保持。宿主VM CDHash仍为 `89cb8ee4c9f47b15a1c63bd73c99b53a0d43a541`。首次给库使用探针的项目CMS签名时，macOS严格核验报 `CSSMERR_TP_NOT_TRUSTED`；失败产物和日志保留。最终库采用与已部署基线一致的ad-hoc签名，严格核验通过，没有更改核验条件。

| 对象 | 结果 |
| --- | --- |
| 完整 Python | 1017项，跳过4项，退出0；沙箱外运行 |
| 单库完整克隆事务 | 9项通过；仅一个库变化，API不重写，旧盘保留和故障恢复通过 |
| 验收及辅助清理工具 | 24项通过；保留身份、错误期望、QR、回执断言 |
| 原生 nil/fallback 诊断 | 应用内查询与实际构造通过；daemon效果未验证 |
| 重启后真实 QR 复验 | 原设备列表为空；v3复制回执通过，消费失败 |

完整Python的沙箱内运行出现宿主进程及脚本执行限制失败，保留日志，向逐字核实的该测试PID30060发送SIGINT停止；没有操作VM进程。随后同一标准入口 `make test_python` 在沙箱外通过。

真实消费工具首次读到旧诊断的大文件时因1MiB内联上限提前失败。工具改用正常文件下载，仍核对新runID、PID及原消费断言；新增回归确认旧身份仍拒绝。复验进入本轮run，得到空设备和no usable input，失败证据保留。该工具修正没有改变设备枚举结果。

## 具名候选与部署范围

- 版本：`2.6.2-local.4bd0cce62c46`。
- 归档SHA-256：`a9f2967aff15201335067fa4499c6efa02c754bb05fdf03c53209120faa16639`，194512896字节。
- 新库SHA-256：`d5ca2de19077080387b6fcaf9a26f50648f6dc1b64f9992c94c4158be07b90b4`。
- 仅正常停止并重绑t52-v2；完整克隆停机磁盘，仅替换System上的libvcamcaptured，独立只读复核后原子发布；完整旧盘保持。
- API作为固定只读输入核对，摘要 `f5ce73f00f5694b1639d735af8106436aaf2cfd1bd3dc7211aef6041149cd2a8`；API及发布端均不重写。Data不离线挂载。
- 新窗口最多900秒、单一原CDHash、一次附加、无持久允许名单，独立进程监督。就绪即停止；若本次附加留下暂停状态，只有在辅助退出、debugserver不存在且启动身份匹配时才向同一amfid发送SIGCONT，并核实恢复状态。不得操作新PID或重新附加。
- 原探针数据和程序保留；临时验收完成后恢复原程序并停止。其他VM和既有历史不变，仅允许清理本次事务新建暂存文件。

准备阶段的新候选部署超出此前一次cameracaptured重启范围，曾提交具名计划请求补充批准。用户随后已明确批准；执行结果见末节。

部署前只读复核：旧五库、API、新旧发布端缓存及原探针摘要符合基线；来源均off，探针停止。原VM PID33355及base、target、t52-environment三个受保护副本保持。所有旧运行证据和新候选首次失败均保留。

准备与诊断证据179项已归档并逐项核验，清单：`evidence/T52-provider-fix-20261023/prepared/manifest.json`。准备归档时，新部署计划及其配置、协调器和11项传递依赖摘要复核通过，尚未执行；该批证据保留当时状态。


## 已批准部署的执行记录

2026-10-23 用户回复“批准此范围，继续部署及验收”，记录保存于 `.build/t52-provider-fix-20261023/approval-record.json`。冻结计划、归档、配置及工具摘要核对通过。正常关机 RPC 已接受，日志确认 `Guest stopped`，宿主 PID4438 退出，原 VM PID33355 保持。候选已安装并核验，绑定已从 cc05d88f441f 改为4bd0cce62c46。管理员认证后开始冻结的单库克隆事务；后续结果独立记录，不改写准备阶段证据。


## 部署及真实应用消费结果

用户批准后，正常关机完成；新Core Bundle安装核验、t52-v2重绑、完整磁盘克隆及单库替换均完成。独立只读结果为 `already_current`，`replace=[]`。新运行实例 `C56C5714-474B-4E54-9E2D-52FC17900A2F`，宿主PID61974。其他四库、API、classic发布端及保留的旧缓存摘要与部署前一致。cameracaptured当前映射已核对，没有额外发送相机进程TERM。

完整旧盘保存于 `.build/t51rt/lib/t52-v2/.environment-history/environment-4e212cce-3c29-4415-9c6b-2a1e75e4ad55/Disk.img`。独立重新计算完整SHA-256为 `471d42eaf6354d239d88daab5d4dd9be02a071eb003bd263b1ad1b82c69bee91`，与停机计划相同；原文件身份及6项事务元数据核对通过。更早的d27caf08历史盘身份再次核对相同，该盘本轮未重新计算完整摘要。原VM PID33355、base、target和t52-environment均保持。

冻结启动器从research/tools移入.build后仍使用原目录深度，首次在导入host_control_client时失败，尚未创建VM。保留原冻结文件，另存仅 `parents[3] -> parents[2]` 的路径修正及摘要记录，继续同一辅助窗口；没有重新附加。VM就绪后监督器依次向自身辅助子进程发送SIGINT、SIGTERM、SIGKILL，退出码-9。worker状态文件因此仍保留running；终止结论来自监督器回执及独立进程不存在检查。独立确认helper61310、supervisor61309和debugserver均不存在。同一amfid52088身份匹配且Ss，未发送SIGCONT。

启动后前置检查发现原探针PID365运行，故拒绝正式验收；原因未查明。按具名范围正常停止后再次核对通过，才部署正式探针。所有首次失败记录保持，没有删除或降低原消费断言。

正式探针的三个诊断开关均为0，程序SHA-256 `78b916838b21dbb152236c3b0605e7f85a98b32c38e0443bd8ef90a5eac40d96`，正式容器和普通应用授权保持。验收结果：

| 对象 | 结果 | 证据 |
| --- | --- | --- |
| 定位点31.2/121.5/20及30.25/120.15/35 | 各5条CLLocationManager回调，7字段全部相同 | location-consumer/result.json |
| QR A | 设备vphone:vcam:0，AVCaptureMetadataOutput收到t52-20261022-A，错误期望被拒绝 | camera-consumer/a-record.json |
| 中性帧 | 持续6.183秒，设备和会话有效，无QR回调 | camera-consumer/neutral-record.json |
| QR B | AVCaptureMetadataOutput收到t52-20261022-B，错误期望被拒绝 | camera-consumer/b-record.json |
| v3复制回执 | 各阶段generation/presentation匹配，0 < observed <= published | camera-consumer/result.json |
| 原生普通视频源 | 3个实时窗口、387条日志；三个消费PID均返回1个类型1来源 | camera-live-summary.json |
| 收尾 | 原探针SHA-256恢复为02795c7a…108faaee，数据容器保持，应用停止；定位和相机来源均off | runtime-final/result.json、final-source-state.json |

单库修改后，同一严格消费流程从“空设备/no usable input”变为成功。结合原生nil查询、控制流和先失败后通过的真实代码回归，证据支持“原生共享provider缺失导致实例getter hook没有接收者”为本轮空枚举原因。修复未修改原生指令页或框架共享全局变量。启动前runtime_diagnostic的open EPERM仍存在；它发生在凭据消费前，不能据此认定后续读取持续失败。

本轮窗口从开始到辅助停止为86.345秒，最大900秒，一次附加，单一原CDHash；无持久允许名单。原探针恢复工具使用defer-launch，因此其安装记录passed=false表示尚未启动；随后独立摘要及进程核对通过，结束时没有启动原探针。

执行命令及结果：

- `.venv/bin/python -B .build/t52-provider-fix-20261023/run-approved-consumption.py`：定位、QR、恢复及最终运行核对均退出0；首次前置拒绝记录另存。
- `run_t52_location_consumer.py --instance-id C56C5714-474B-4E54-9E2D-52FC17900A2F --phase-timeout 30 --output .build/t52-provider-fix-20261023/location-consumer`：通过。
- `run_t52_camera_consumer.py --instance-id C56C5714-474B-4E54-9E2D-52FC17900A2F --frames .build/t52-camera-interface-20261022/consumer-frames-r3 --output .build/t52-provider-fix-20261023/camera-consumer`：通过。
- 此前候选完整Python1017项（4跳过）、单库事务9项、工具24项通过，原失败日志保持。本轮未改变候选组件源码，不重复完整套件。

本轮通过范围为具名正式探针的CLLocationManager和AVCaptureMetadataOutput消费、来源归属及停止、替换组件和保留对象核验。业务应用及外置物理卷没有在本轮验收；不据此提升上游整项accepted。没有新增固件、内核或DSC指令补丁，没有提交或推送。

运行证据独立归档于 `evidence/T52-provider-fix-20261023/runtime/manifest.json`，准备阶段179项及此前证据均保留。
