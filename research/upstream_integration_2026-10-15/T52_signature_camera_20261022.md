# T52 探针签名与相机接口修复

对象：独立 `.build/t51rt/lib/t52-v2`，regular/v2、26.1/23B85。原 VM 和既有失败证据保留。当前任务依次处理签名、相机接口与应用消费；尚未将应用消费记为通过。

当前部署为 `2.6.2-local.56be1ce20ded`。本轮批准的诊断部署和窗口已执行，最新结果见末节“诊断部署与初始化证据”；前文的待批准、未安装状态是当时记录。

## 签名拒绝条件

原正式容器程序 SHA-256 为 `860055c04fc0f85029213694052a889b2604ca99c5179db5d6ba4ef4b0dfaf74`。实际 SuperBlob 含 CodeDirectory、requirements、XML/DER entitlements，无 CMS 槽；原验收脚本调用 `apps.install` 时未传 `cert_path`，客户机 `GuestSigner` 因而未设置签名 identity。

使用同一 native VPhoneSign，只增加项目既有 `scripts/vphoned/signcert.p12` identity，保持 `__text` 和权限内容相同。结果：无 CMS 版本启动失败；CMS 版本启动通过；恢复原无 CMS 版本再次失败；恢复 CMS 版本再次通过。最终进程 PID3872、frontmost_verified=true，VM 实例为 `1B6A2DA7-7B19-41ED-BB2D-3FF385497E21`。这证明本组合的探针需要该签名步骤；不解释 TXM 内部 selector/错误码，不外推全部固件或应用。

可重复资产：`tools/experiment_t52_probe_signature.py`、`tools/reproduce_t52_probe_launch.py`。实际输出位于 `.build/t52-app-acceptance-20261022/signature-cms-r1/`；原失败位于 `signature-diagnosis-r2/`。修正本轮安装脚本，显式上传证书并传递 `cert_path`；原正式安装器不改。

## 相机接口

实际 classic 发布端和 v2 消费端的跨模块回归在修复前复制出不同像素。原发布头为256字节，消费头为64字节。原实际发布程序包含 `/var/jb/...` 路径；v2 消费库使用 mobile Media 路径。相机就绪复现为 cameraPresent=false、connected=false。

修改如下：

- 共用 `Shared/VPhoneCameraFrame.h`，保留原字段偏移，发布头256字节、复制回执128字节，携带 generation/presentation_id。
- classic 发布端默认路径保持；显式 `VPHONED_CAMERA_LAYOUT=v2` 选择与 v2 消费端相同的路径。v2 CFW 注入时记录该环境变量；未知值拒绝。为现有独立 VM 准备默认v2的具名缓存发布端候选。
- v2 消费端稳定复制后发布回执；分配失败及复制期间序号变化不确认。新增文件检查拒绝链接和非普通文件。
- v2 CamFix 接入既有 classic QR 元数据消费逻辑，使用实际共享帧解码并经 `AVCaptureMetadataOutput` 委托投递；保留弱引用及单次消费约束。尚未用实际客户机证明 QR 结果。

回归：`tests/test_guest_vcam_bridge.py` 编译实际发布实现及实际 v2 消费实现，覆盖像素、回执、错误 generation、重复读取、分配失败、复制中断、路径选择和未知布局拒绝。相关27项通过；10项既有验收资产回归通过。

正式 `make test_python` 最终970项、266.640秒通过，跳过4项。首轮沙箱受限已中断；沙箱外首轮970项因旧 Undo 替身不接收 guest_environment 出现26错误。夹具显式接收并断言冻结环境后，36项相关回归通过，最终全量通过。未修改原撤销断言或生产 Gate。

## 候选与授权

候选 `2.6.2-local.93805a71796d`，归档 SHA-256 `b1dfdce323225be681a02fac2589c5658efa90285ea538d608b01b61b265e48c`。SDK构建、签名、资源摘要、原生依赖及完整Bundle检查通过。宿主VM文件/API/Framework库保持；主CLI因资源封装重新签名。

用户明确批准该版本、仅 t52-v2 停机/重绑、保留旧磁盘的两库替换、匹配发布端、本次新增暂存清理，以及 CDHash `89cb8ee4c9f47b15a1c63bd73c99b53a0d43a541` 最长900秒/一次附加/不写持久允许名单的新窗口。旧窗口不复用。

t52-v2 已正常停止；完整APFS克隆备份位于 `.build/t52-camera-interface-20261022/pre-deployment-vm-backup`，关键文件逐字节一致、磁盘66处采样一致。用户完成管理员验证后，新Bundle已核验并完成宿主重绑；正式离线更新在写盘前拒绝，错误为 `Firmware desired plan VM/generation/disk identity mismatch`。当前磁盘来自 version 2 环境事务；其证据不满足现行固件身份连续性要求。原 Gate 未改。

在线资格检查返回 launchd Mach-O is unreadable or malformed；未绕过其拒绝条件，改用正式停机事务。

## 应用消费现状

签名通过后，原 URL 阶段请求超时，随后实际截图出现系统“在 T52Acceptance 中打开”确认框。该现象不能直接归因为UIKit生命周期。探针补充显式UIWindowScene，并支持应用自有的仅含mode/runID的请求文件；测量值仍仅从标准消费者回调获得。

请求文件触发后已有真实应用事件；首轮 CLLocationManager 在 authorization=0 时返回 kCLErrorDenied。locationd 定向日志确认本客户端未获授权，尚无定位回调。后续候选改为scene激活后启动请求，并在授权允许后才调用startUpdatingLocation；此候选已构建，尚未部署。权限允许、两组定位回调、QR/错误预期/neutral/第二QR均未通过。所有失败记录保留，未降低验证器要求。

下一步：取得离线事务终态；在具名VM部署已批准的v2发布端，开启获批新窗口并启动；重新绑定验收脚本的实例标识，补正常权限流程、定位和QR消费。完成后停止来源与辅助进程，复核受保护对象和新旧收据。

## 2026-10-22 续推：两库事务与实际消费

独立工具 `tools/t52_environment_maintenance.py` 仅接受本轮 t52-v2、候选 .93805a71796d 和已批准的两个库摘要。计划绑定原始完整磁盘 SHA-256 `6963ae9f9dd1593952b5b850852b99e56ddd583219733491b78f5df952ab350d`、磁盘身份、六项元数据摘要、安装收据及候选摘要。只在 APFS 克隆上替换，重新只读核验后原子交换；完整旧盘保存在 `.environment-history/environment-7c8a48f4-42d2-4838-84d3-18e1541d59f7`。固件和 Undo authority 均保留 unknown，未写旧 .cfw-history 或生成新的固件身份授权。

7 项事务/故障恢复回归通过。现有环境更新49项回归在沙箱内因ps权限失败，原日志保留；相同测试集在沙箱外通过。真实事务已发布，发布时新盘完整 SHA-256 为 `20b4f6c78870759523382e78ab4d3cc8125d319fb47e7b16bf8ddde998c69b1b`；独立只读复核为 already_current，五库摘要符合候选。启动后磁盘正常写入，发布时摘要只用于该次事务证据。

新运行实例为 `55A25B78-4CAD-4053-9C3E-9CFCD3E75F64`，宿主PID64038。辅助63729仅附加一次；停止标记、SIGINT/SIGTERM未使同步循环退出。用户认证后SIGKILL结束具名辅助；独立ps确认63729和debugserver63734消失，amfid63727为Ss，无调试状态。停止日志时长上界673.277秒，小于批准900秒。helper-state.json因强制结束保留旧running值，以独立进程证据为准。未写持久名单。

匹配发布端缓存 SHA-256 `0c3c906aabd670968fe4947bbf68c1130f9af0c5c93216dad8ec8c80ed9332b8` 写入和读回通过。原缓存不存在、系统/usr/bin/vphoned保留。services.signal返回失败；核对实际PID/程序路径后只向classic发布端发送TERM，重启为缓存程序，camera_present能力通过。

探针活动场景候选 SHA-256 `a4b1015211a511d042a9c19e1e1122823a027574de4d078ca802b17b14a7b64a` 已部署，原程序备份保持。定位首轮因等待正常权限提示超时；后续宿主像素点击“允许一次”后，authorization=4，收到一条纬度31.2/经度121.5/高度20/水平精度5/垂直精度6/速度2/方向90的真实回调。当前严格的每点双回调验证未通过；两组坐标未验收。

QR输入已由系统CIDetector核对：a/b分别为不同内容，中性图无QR。消费工具回归共12项通过。实际相机首轮在启动客户端前缺少复制回执；调整客户端顺序后探针仍返回空设备和no usable input，未记为通过。映射检查确认探针已加载SystemHook/libvlocation/libcamfix，cameracaptured已加载SystemHook/libvcamcaptured；初始化失败原因仍在查证。所有实际失败记录保留。

## 当前条件与待批准诊断候选

新诊断探针的构建曾遗漏原正式探针的 `com.apple.private.security.container-required`，导致新进程未读取正式容器中的请求。已修正构建器，并在部署前强制校验此权限；实际缺权限产物被拒绝，修正产物通过。新增回归覆盖缺失、布尔值、错误bundleID与正确bundleID；验收工具当前15项通过（含独立进程监督器2项）。这一修正未改变签名ABA结论；此前缺权限诊断轮次不作为消费证据。

当前正确容器诊断产物 SHA-256 为 `02795c7a8bf30799bd309832f1bad6f70200fcc5b2bdc04cc417c773108faaee`。新进程679确认：`startUpdatingLocation` 实现在 `/usr/lib/libvlocation.dylib`，`availableMetadataObjectTypes` 实现在 `/usr/lib/libcamfix.dylib`；只打开、不读取载荷的诊断对相机共享帧返回 errno=1（EPERM），对定位桥接文件返回 errno=2（ENOENT）。相机设备仍为空。事实仅支持“探针共享帧访问被拒绝、定位桥接文件缺失”；虚拟设备注册失败的具体条件尚未查明，不能把这两项条件直接当作全部原因。

为读取初始化失败细节，已准备 `2.6.2-local.56be1ce20ded`：归档SHA-256 `59822dd34e15f7c9734fa69e5f4ceca9dcf1efa442c7d64bf5bac549f8ad05f4`。相对已部署.938，两项库只将受限日志写入失败时的统一日志消息改为public字符串；无设备、权限或定位功能修复声明。构建、签名、完整Bundle检查通过；实际跨发布/消费代码4项回归通过，工具15项通过。VM/API/Framework字节及发布端保持。原生VM纯help仍被SIGKILL，未打开磁盘。

新窗口使用独立进程监督器，避免原辅助的LLDB同步调用阻止Python线程处理停止标记。监督器预留7秒升级SIGINT、SIGTERM、SIGKILL；两项实际子进程回归覆盖拒绝常规信号时的停止标记和绝对期限，均在期限内结束。该监督器尚未用于实际AMFI附加，旧窗口不复用。具名候选、库摘要、安装脚本及新窗口计划保存在 `.build/t52-camera-diagnostics-20261022/deployment-plan.json`；截至本节记录尚未获新范围批准、尚未安装或停机。

当前收尾检查确认：定位来源off、相机来源off/streaming=false，诊断探针已停止；t52-v2仍为PID64038/实例55A25B78-4CAD-4053-9C3E-9CFCD3E75F64。三个受保护副本base/target/t52-environment逐项设备号、inode、大小、mtime及既有摘要保持；原vm-2607仍由PID33355运行。新旧数据、磁盘与库保留，无提交或推送。消费仍未通过。

证据归档：`evidence/T52-signature-camera-20261022/manifest.json`，当前161个记录均逐项SHA-256复核。部署.938与待批准.56的证据分目录保存。当前源码快照含后续诊断修改，各候选构建时的源码摘要以其不可变provenance为准。

## 2026-10-22 诊断部署与初始化证据

用户已批准 .56 诊断候选及新的900秒、一次附加窗口，并完成两库事务的系统认证。安装收据、新旧Bundle复核、正常停机、重绑及克隆事务均完成。完整旧盘保存在 `.build/t51rt/lib/t52-v2/.environment-history/environment-728bf0d4-fa9d-4c12-b5f9-413c93cccb11/Disk.img`，其设备号、inode、大小和mtime与事务前记录一致。事务前完整磁盘SHA-256为 `2fa3ea5e19f338aed22df9709c704cd4818f1a746af88693c42c509b0e23b9f1`，发布时新盘SHA-256为 `591f69d155b839506e2f5aca025edee11cd72ae6bcf7aaeba5e4e560327de387`；启动后的正常写入不再与发布时摘要比较。独立只读复核为 already_current、replace为空。固件与Undo authority仍为unknown。

本轮只替换两项诊断库：libcamfix为 `e4d026ce6942b4d75ff1a123c0360143e8c6b4a9fd3d862523e61e98676a3747`，libvcamcaptured为 `a41d3f8438f9841de0751322bf87eece6b19a2e56e1123952a20aa1860f70c71`。运行后五库、classic发布端及正确容器探针摘要再次读回通过。

新实例为 `372C906F-9315-4ED3-B596-94670EEA9AAA`、宿主PID98713。启动观察脚本首次在socket建立前读取endpoint而退出；实际VM已启动，随后按现有进程继续观察，未启动第二个VM。已为该竞态保存真实延迟Unix socket回归：原逻辑3项失败；将endpoint读取放入有界重试后3项通过。验收工具组合18项通过。该测试不启动VM。

新辅助worker98465仅附加一次。VM就绪后，独立supervisor98461依次使用SIGINT、SIGTERM、SIGKILL结束worker；实际窗口69.615秒。独立进程检查确认两者已不存在，amfid83428为Ss，无调试或停止状态。未写持久允许名单。helper-state因SIGKILL保留终止前running值，最终状态以supervisor-stop和独立stop-verification为准。该窗口已结束，不能复用。

相机初始化的首次4秒采集遗漏了后续步骤，不能据此认定初始化阻塞。改用七个重叠的4秒窗口覆盖22秒；r2单窗口达到500行上限，r3提高至2000行后各窗口均未截断。最新cameracaptured为PID508，日志确认：

- `FigCaptureSourceServerStart()`已返回，`CreateFromBacking ret=0x0`，虚拟源已加入源列表。此前“虚拟源未注册”的解释已被本轮证据排除。
- 两种代码页修改均失败：`vm_protect+COPY failed: 2`、`vm_remap FIXED|OVERWRITE failed: 2`，随后记录 `per-source NOP patch FAILED`。
- 帧接收器已订阅通知，但打开 `/var/mobile/Media/SimulatedCamera/vphone-vcam-frame.shm` 返回 `Operation not permitted`；后续记录 `still-drive: no shm frame yet`。源码的open失败分支直接返回，当前文件传输路径因此无法完成帧复制。

应用QR复验仍返回空uniqueID和`no usable input`，双层复制回执未取得。探针自身打开同一共享帧也返回EPERM。当前证据确认了源创建成功、代码页写入失败和共享帧访问拒绝；空设备枚举的完整原因仍未查明，不能把代码页写入失败单独认定为全部原因。

定位复验通过标准系统提示选择“使用App时允许”，authorization=4。实际CLLocationManager收到一条七字段正确回调，60秒内未收到第二条，严格验证返回 `Two real consumer callbacks are required`。每点双回调和第二坐标均未验收。

源码对照确认classic发布端使用CLSimulationManager，没有写libvlocation定时读取的桥接文件。客户机API的GuestLocationSimulation实现了该文件发布；但通过宿主RPC进行`location.set`对照被所有权校验拒绝：`method_not_forwardable`，理由为`bypasses location owner and generation; use location_source_set or location_stream_*`。未改用直连API绕过该校验，未创建桥接文件。因此“文件存在时应用能否读取、定时回调能否成立”仍未验证；连续回调失败的完整原因未查明。

最终复核：定位来源off，相机来源off、streaming=false。采集结束后曾出现新的后台探针PID521，最终核验发现后仅结束该探针，后续检查无探针进程。t52-v2按既有要求保持运行。三个受保护副本base/target/t52-environment的设备号、inode、大小、mtime及既有文件摘要保持，原vm-2607仍为PID33355。新旧Bundle收据均通过。旧库、旧磁盘及探针证据保留；未提交或推送。

本轮独立归档 `evidence/T52-camera-diagnostic-20261022/manifest.json` 共85项，引用前批161项清单的SHA-256，未覆盖前批证据。可重复命令：

工具18项在沙箱外通过。归档后同组合在沙箱内复验时，真实Unix socket测试失败；独立最小检查确认AF_UNIX bind返回errno=1。保留原断言，在沙箱外以相同命令复验18项通过，未修改测试。执行这些真实socket回归需要允许创建本地Unix socket的环境；沙箱失败及复验记录见独立补充清单 `evidence/T52-camera-diagnostic-20261022/postarchive-validation/manifest.json`。

```sh
.venv/bin/python -m unittest discover -s research/upstream_integration_2026-10-15/tools -p 'test_t52_*.py'
.venv/bin/python research/upstream_integration_2026-10-15/tools/capture_t52_camera_init.py --instance-id 372C906F-9315-4ED3-B596-94670EEA9AAA --output NEW_OUTPUT_DIRECTORY
.venv/bin/python research/upstream_integration_2026-10-15/tools/run_t52_camera_consumer.py --instance-id 372C906F-9315-4ED3-B596-94670EEA9AAA --frames .build/t52-camera-interface-20261022/consumer-frames-r3 --output NEW_OUTPUT_DIRECTORY
.venv/bin/python research/upstream_integration_2026-10-15/tools/run_t52_location_consumer.py --instance-id 372C906F-9315-4ED3-B596-94670EEA9AAA --phase-timeout 60 --output NEW_OUTPUT_DIRECTORY
```

待完成：在所有权协议管理的发布链中接入定位桥接；解决相机共享帧访问及源枚举条件，再重跑两点定位与QR-A/中性图/QR-B消费。当前 .56 只增加日志，不含这些功能修复；本轮诊断部署已完成，应用消费accepted=false。

### 同版本源过滤指令的只读复核

新增仅显式设置 `T52_CAPTURE_SOURCE_READONLY=1` 才编入的探针诊断。程序只读取CMCapture已映射的代码段，按现有结构特征定位分支，未调用被检查的函数、修改代码页或读取模拟帧载荷。默认与显式诊断两种构建均通过。诊断程序与原探针的权限字典逐项相同；实际进程PID626正常启动，正式数据容器保持。

实际CMCapture UUID为 `56F23E85-0EA1-34F1-AAEC-FFE67067538A`，代码段大小6015032字节，结构匹配唯一。保存8192字节片段，SHA-256为 `36ac6d1738505fc1df1d2a4ac1c6fe4cdc4b06b812dfee60024589f7df03ed88`。`tools/disassemble_t52_capture_source.py` 使用Capstone语义操作数核验：`0x1c4425c48`、`0x1c4425c4c`仍分别为CBZ W0、CBZ W25，均跳转至`0x1c4425cc4`。该地址与cameracaptured初始化日志中的失败补丁位置一致，进一步确认原过滤分支仍存在。以上地址仅为本轮观测，不写入补丁逻辑。代码中的属性含义仍需结合后续证据核验，未据此新增空设备枚举的因果结论。

采集后恢复原正确容器探针，实际读回SHA-256为 `02795c7a8bf30799bd309832f1bad6f70200fcc5b2bdc04cc417c773108faaee`；独立确认探针停止、定位off、相机off/streaming=false。未开启新辅助窗口。新证据另存 `evidence/T52-camera-diagnostic-20261022/source-filter-readonly/manifest.json`，此前清单保持。
