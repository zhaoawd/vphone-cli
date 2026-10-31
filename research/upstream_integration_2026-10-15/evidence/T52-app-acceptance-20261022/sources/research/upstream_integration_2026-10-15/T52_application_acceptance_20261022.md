# T52 新宿主版本与应用消费验收

本轮对象为已安装 Core Bundle `2.6.2-local.266810c8ae29` 和独立 `t52-v2`。新版本的收据、文件摘要与绑定通过核验；实际 Launchpad 显示该绑定和“已停止”，保存的界面断言通过。新版本默认GUI真实启停已通过；摄像头/定位消费行为仍未通过，物理外置卷继续按用户指示暂缓。

## 准备与批准

只读 `verify_t52_default_shutdown.py prepare --work .build/t52-app-acceptance-20261022` 通过，保存配置与绑定摘要、日志身份和磁盘/目录锁释放基线。观察工具新增工作目录和组件比较文件参数；历史默认值与原有运行/关机断言保持。界面脚本新增版本和工作目录参数，默认仍指向旧验收对象。

新 VM 程序 `--help` 退出137。用户已明确批准仅 CDHash `89cb8ee4c9f47b15a1c63bd73c99b53a0d43a541`、最长900秒、一次附加、完成即停止且不写持久允许名单的窗口。辅助脚本 SHA-256 为 `aed2aac3fd6609e41d5a0f397c3ce8c73ddf5eb6fcc7250c15cfe93b04e9fe1b`，路径为 `.build/t52-app-acceptance-20261022/boot-window/scoped-amfidont.py`。最初 `sudo -n` 需要密码。随后窗口记录确认辅助进程于11:20:07启动，PID66498，仅附加一次。用户再次执行时报 `FileExistsError`；脚本排他创建阻止了重复窗口，未删除或重置记录。辅助进程于11:32:33停止，累计745.972秒，早于900秒截止；独立确认PID不存在，原VM及受保护副本保持。

## 应用探针

新增 `research/probes/t52_application_probe.m` 和构建脚本。探针为标准 UIKit 应用，bundle ID为 `org.vphone.acceptance.t52.20261022`。定位只从 `CLLocationManager` 委托读取结果，不读取模拟控制文件；摄像头使用 `AVCaptureMetadataOutput` 消费 QR。结果包含每轮runID、PID、时间、授权状态及委托事件，写入应用自身 Caches 的 `t52-application.json`。旧 manager/output 的迟到回调被对象身份检查拒绝。每轮最长60秒，支持显式停止。

```sh
zsh research/probes/build_t52_application_probe.zsh \
  .build/t52-app-acceptance-20261022/consumer-probe-r2
.venv/bin/python -B -m unittest discover \
  -s research/upstream_integration_2026-10-15/tools -p 'test_t52_*'
```

首次链接缺少 CoreGraphics，原失败日志保留；显式链接后编译及严格签名检查通过。输出为 arm64e、IOS、最低26.0。探针已通过正式 apps.install 容器入口安装并注册，实际启动仍失败，见实际结果。

`verify_t52_application_observation.py` 核对探针身份、runID/PID/模式、时刻、真实委托事件类型、两次定位回调的七个数值字段，以及摄像头虚拟设备和唯一QR内容。6项模拟记录回归通过；与4项既有日志身份回归合计10项通过。这些单元测试输入为合成数据，不作为真实应用验收。

## 实际执行顺序

1. 用户启动已批准的窗口后，检查实际截止与辅助进程状态，在剩余时间内执行。
2. 通过现有 Launchpad 默认启动新版本；使用 `running` 断言核对进程字节、冻结绑定、无HTTP监听、系统版本及五库摘要；保存实际运行/正常停止界面和日志，核对磁盘/目录锁释放。
3. 通过同一绑定的 CLI 建立独立 API 验收会话，使用临时认证令牌和 localhost 监听；核对实例和能力，保留 `--no-vphoned-update`。
4. 仅当目标路径和bundle ID均不存在时安装本轮探针。通过生产定位来源入口设置两组不同WGS84坐标，各自启动唯一runID的定位观察，读取消费者记录并验证。通过生产相机入口呈现唯一QR、错误预期、neutral和第二个QR，逐轮保存消费回执与标准元数据结果。
5. 原计划停止本轮来源与探针、正常关机并复核受保护对象。用户随后明确要求保留当前VM运行，因此本轮停止测试来源和应用、停止辅助进程并核对受保护对象，保留VM运行。探针产生的数据与注册项的删除遵守现有明确批准门。

应用探针验证范围为标准API消费，不能外推所有业务应用。尚无本轮真实消费者结果。完整T52仍为 `accepted=false`。证据见 `evidence/T52-app-acceptance-20261022/manifest.json`。

## 实际执行结果

- 11:23:00由实际Launchpad默认启动新版本，VM PID68216，实例46070813-16B7-4497-928F-3852B8E37E2A。系统26.1/23B85、五库目标摘要、冻结绑定、无HTTP监听及不更新daemon的断言通过。
- 11:23:28由实际界面停止；直接VSOCK请求获apiAccepted，Guest stopped、退出0、磁盘和目录锁释放、配置/绑定摘要保持，运行及停止界面断言通过。
- 11:24:25启动同一绑定的图形API会话，VM PID69035，实例1B6A2DA7-7B19-41ED-BB2D-3FF385497E21，localhost:54073。随机令牌只传入子进程环境，未保存至证据。
- 首次将探针写入独立的任意容器目录后，apps.register被拒绝。查询确认未注册；固定icli源码的bundleOwner检查确认任意未托管容器被视为其他安装器所有。未伪造托管标记。将本轮文件移动至未占用的/var/mobile/T52Acceptance-20261022.app后，按受支持的bootstrap路径注册成功，数据目录为FFA16ABD-DF93-4C3A-9157-6F04783AF75C。原任意容器目录保留为空目录。
- 定位来源入口成功确认投递一组坐标，但探针没有消费记录；该确认不计为应用行为通过。来源loc-c679b6de-6b64-4588-a6e3-a766104a7335已通过精确generation停止。
- 初次直接启动报告device_locked；既有无密码解锁入口通过，界面仍为Setup语言页。用户明确选择保留VM，并完成初始设置。随后agent.health报告setup_pending=false，系统设置应用启动对照成功（PID920、frontmost_verified=true），探针仍启动失败。
- 最小脚本reproduce_t52_probe_launch.py连续捕获failed和无进程；RunningBoard记录Launchd job spawn failed、EPERM。1秒定向kernel日志记录System Policy对xpcproxy的process-exec拒绝，路径为上述探针程序；客户机amfid定向日志没有记录，不据此认定AMFI原因。
- 待验证假设为架构兼容、签名/权限、注册/容器/persona条件。仅改arm64的对照也失败；首次架构对照被自动锁屏干扰，原结果保留。回归脚本增加setup已完成和明确解锁前置条件后，arm64仍失败。未证实arm64e是原因。另已准备同权限的ldid签名实验副本，尚未部署；不将其视为修复。

最小命令：

```sh
.venv/bin/python -B research/upstream_integration_2026-10-15/tools/reproduce_t52_probe_launch.py \
  --output .build/t52-app-acceptance-20261022/launch-reproduction-arm64-unlocked
```

结果为退出1、state=failed、guest_code=failed、runningProcesses=[]。脚本检查当前VM实例，执行实际生产启动并独立查询进程，不以API提交成功代替启动成功。

原始arm64e IPA为T52Acceptance-container.ipa（16875字节），SHA-256为8eb8ded29a3e309a2e6acb19f3978006e8e80db66aad86a07b1280d9217f1e19。用户随后批准仅注销本轮注册项、保留旧文件/数据，并通过apps.install正式安装及清理本轮安装暂存。该步骤已执行，结果如下。

当前VM按用户明确要求保持运行；临时放行辅助进程已停止，未申请或启动新窗口。摄像头与定位消费者结果仍未取得。报告中的前置准备、失败和假设均保留，当前状态见current-result.json。


## 正式容器安装与后续诊断

`install_t52_probe_container.py` 在固定VM实例、原注册路径、探针未运行及IPA摘要检查通过后执行。`container-transition-result.json` 为 `installed_and_verified`：新注册类型为User，原生容器路径为 `/private/var/containers/Bundle/Application/FE3CFC90-BF86-41D6-8123-31520D687DEA/T52Acceptance.app`，原数据容器FFA16ABD-DF93-4C3A-9157-6F04783AF75C复用。旧探针的Info.plist、可执行文件和CodeResources逐文件摘要保持；旧目录和数据均保留。安装器添加了其原有的container-required及PMAP_CS_APP_STORE签名权限。本步骤没有修改安装器或签名器。

正式容器安装后的启动回归仍退出1，`state=failed`，`runningProcesses=[]`。定向kernel日志出现 `TXM [Error]: CodeSignature: selector: 24 | 0xA1 | 0x30 | 1`。这表明该轮存在代码签名错误记录；具体拒绝条件原因未查明，不能仅凭该日志确定所需补丁。此轮不再以旧 `/var/mobile` 路径的System Policy日志解释正式容器结果。

随后使用相同项目签名器，仅移除platform-application权限，保留其他权限及代码指令；启动仍失败。再以同源码arm64程序及同组减少后的权限测试，启动仍失败。上述对照没有证实架构或platform-application是单独原因。实验后已恢复正式安装器生成的原始可执行文件，读回SHA-256为 `860055c04fc0f85029213694052a889b2604ca99c5179db5d6ba4ef4b0dfaf74`，并刷新注册。失败输出和实验记录保留于 `launch-reproduction-container/`、`launch-without-platform/`、`launch-container-arm64-without-platform/` 与 `platform-entitlement-experiment/`。

## 相机就绪和系统应用对照

系统相机启动成功（PID1389、frontmost_verified=true），但宿主相机连接反复报告 `Connection reset by peer`；`verify_t52_camera_readiness.py` 实际退出1，`cameraPresent=false`、`connected=false`、`streaming=false`、发布帧数为0。这是相机未就绪的复现，不是QR消费验收。

实际客户机文件读回并计算摘要：

| 对象 | SHA-256 | 二进制中的共享内存路径字符串 |
| --- | --- | --- |
| /usr/bin/vphoned | ad3d292c05134f83bfcb7b871e0637eff0e7ca41f975cd80ff1e8895e252ab62 | /var/jb/var/mobile/Library/vphone-vcam-frame.shm |
| /usr/lib/libvcamcaptured.dylib | 2e94e0d035a717dfd82f91f8547a789aa82f2978569a488289be95c9ede17e97 | /var/mobile/Media/SimulatedCamera/vphone-vcam-frame.shm |

源码 `scripts/vphoned/vphoned_vcam.h` 定义classic发布头大小256，`sources/VPhoneGuestComponents/VCamCaptured/VCamFrameProtocol.h` 定义v2消费头大小64；前者listener在open_shm失败时返回。客户机 `/var` 列表未见jb目录。API健康结果为 `camera_publisher_enabled=false`、`bootstrap_startup_enabled=true`，不能将其改写为API_ONLY模式。`/usr/bin/vphoned-api` 的直接读回因file_too_large被拒绝，本轮未取得该文件的独立原始字节摘要。

事实为当前文件包含不同共享内存路径，且源码协议定义存在差异。当前发布端与消费端不具备已验证的一致接口；具体连接重置原因仍需进一步验证。本轮未创建兼容链接、改写系统库、更新daemon或修改内核。

系统地图启动成功（PID1434），本轮固定定位来源收到确认；界面显示定位权限预览，选择“允许一次”。未取得标准探针定位委托或地图数值坐标，因此不计为定位应用消费通过。后续已精确停止本轮generation，并退出地图与相机。

可重复的实际失败命令：

```sh
.venv/bin/python -B research/upstream_integration_2026-10-15/tools/reproduce_t52_probe_launch.py \
  --output .build/t52-app-acceptance-20261022/launch-reproduction-container
.venv/bin/python -B research/upstream_integration_2026-10-15/tools/verify_t52_camera_readiness.py \
  --output .build/t52-app-acceptance-20261022/camera-readiness-r1
```

两条命令均返回1；输出目录保存原结果，重新执行须使用新目录。前者启动本轮诊断应用并查询进程；后者检查实际能力及相机状态。原有10项观察/日志测试通过只能证明验收资产的断言行为。

## 当前结果与后续步骤

`container-followup-cleanup.json` 和 `container-followup-protected-checks.json` 通过：定位来源已停止，系统对照应用已退出，探针恢复为原生安装字节且注册保留，原VM33355与三个受保护副本保持，t52-v2的所检查配置与绑定摘要保持。临时AMFI辅助进程仍不存在，未重启放行窗口；VM69035按用户明确要求保持运行。

正式容器安装已完成；应用消费验收仍失败，T52整项 `accepted=false`。后续应分别查明正式容器程序的签名拒绝条件、统一相机发布/消费组件的路径与协议，再运行标准定位回调和QR消费验证。组件更新和主机安全变更继续保留各自批准门；物理外置卷按用户要求暂缓。T53保持隔离候选验证结果，尚未接入产品或完成真实开发工具验收。本轮诊断和证据记录未提交或推送。
