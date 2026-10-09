# T08 源码与历史证据调查

调查范围：只读本地源码和历史证据；未启动VM、联网、调用SwiftPM、部署客户机、修改权限或注册helper。仓库当前HEAD为3eea98a9；本报告本地实现引用固定为b4e80c575950d768737234f9fcefc7fb7aff6081。快照和SHA-256见references.json。

## 已确认事实

1. 固定依赖为IcliKit 0.7.16 / 702990b59ca412ad975f9f0ea5dafe95c30fac21。现存/private/tmp/vphone-b24-icli-source无.git，不能重新git核对revision；Launchd.m SHA-256 ae905647…与B25/t08-observation.json一致；IcliPrivate.m SHA-256 1d688dd5…与固定overlay manifest的base_sha256一致。其余依赖源码按历史固定源目录引用，本轮未独立恢复全部Git对象。
2. services.start只传label。GuestAPI+Service.swift:31–32调用startService。IcliKit/Services.swift:166验证label后调用icli_launchd_start_json。IcliSystemPrivate/Launchd.m:238使用RoutineStart=813；serviceMessage只有name=label。launchdServiceRoutine:215–225先DomainUser=2，handle=xpc_user_sessions_get_foreground_uid(0)，仅status==113才调用DomainSystem=1/handle0。144不会回退system。这里没有传force、root路径或RootHide目录。RootHide plist重写属于loadServices，startService没有该步骤。
3. launchdRoutine:92–111通过当前进程的xpc_bootstrap_pipe调用_xpc_pipe_interface_routine。其返回非0时直接成为status；返回0且有response时，读取reply["error"]成为status。serviceActionJSON保存status、xpc_strerror(status)、最后domain。历史API错误不能区分144来自传输返回值还是reply.error。
4. IcliSystem/Services.swift:10–22将144映射为IcliError.failed("start requires launchctl service-configure privilege (launchd status 144)")。这是依赖的映射文本，没有包含实际拒绝主体、权限检查位置或需要增加的entitlement。IcliKit/Services.swift:136–164的serviceActionResult在检查错误后才构造含domain的payload。因此失败时底层domain和xpc_strerror文本先在依赖层丢失；144仅留在message字符串。GuestAPI只转发。APIWire.swift:27–43保留IcliError的code/message，仅.commandFailed附details，.failed无details，并统一HTTP400。仅改APIWire不能恢复已经丢失的domain。
5. B23-service-probe.py:4–12使用独立label com.vphone.B23.service-probe，ProgramArguments=[/var/jb/bin/sh,-c,echo B23-service-probe; sleep 20]，RunAtLoad=false、KeepAlive=false。load后domains=[system,user]、pid0、running=false；start返回HTTP400，原文144见B23-service-probe.log:6；随后unload成功。现有数据未记录实际RoutineStart domain/handle、传输码、reply.error或调用进程有效权限。源码有platform-application及Accessibility相关entitlement，未声明包含launchctl名称的键；不能由键名缺失确定根因或提出权限修复。
6. rotation调用链：GuestAPI+Device.swift:35–39→IcliKit/Device.swift:95–106→icli_rotation_set→setCompositorOrientation。Native映射0→UIInterfaceOrientation1、90→4、180→2、270→3；AXSpringBoardServer setOrientation:调用后icli_settle(0.3)，使geometry缓存失效，再返回true。该true表示存在selector并已发调用，不代表SpringBoard确认应用成功。Swift再等200ms，用rotationInfo读回，不相等则抛unavailable，HTTP400。
7. rotationInfo的degrees来自icli_screen_metrics/interfaceGeometry：有效截图时优先AXSpringBoardServer activeInterfaceOrientation；未知则回退UIImage.imageOrientation；截图无效再用panelMetrics。geometry缓存最长约1秒，setter已显式失效。device_orientation是UIDevice.orientation，历史一直0；其值不能替代界面角度。失败响应未保存请求角度以外的原始AX读回、fallback来源或时间序列。
8. B23旋转矩阵（详见rotation-matrix.json）：Settings 0成功；90/270/180均HTTP400 unavailable，稍后读回0，JPEG1290×2796。Safari0成功；90/270成功且读回对应角度，JPEG2796×1290；180 HTTP400 unavailable，随后仍270，JPEG2796×1290。两组locked=false，screen.unlock显示未锁屏且亮屏。Safari横向JPEG已有历史视觉核验；180不是只由宽高判定失败，而是明确角度读回仍270。B22早期90失败不能覆盖B23后续Safari成功。
9. B27实际证明vm-new为rootless：/var/jb→Preboot jb-vphone/procursus，.jbroot-*搜索exit0空；现代API本轮未部署。该样本不能验收实际RootHide服务能力。

## 待验证假设

- 服务：user domain的RoutineStart被拒绝，144导致未调用system。源码确定其控制流；历史失败究竟发生在user还是system尚未记录（user可能先113再system144）。不能把“user144阻断fallback”写为已确认根因。
- 服务：调用者身份、bootstrap上下文或launchd服务配置权限检查产生144。需要调用pid/uid/euid、原始XPC码和日志，不能用rootless布局或源码entitlement列表单独证明。
- 旋转：前台应用或场景支持的方向集合造成Settings与Safari差异、Safari拒绝180。现有成败相关性支持进一步验证，未记录运行场景支持集合，不能确定因果。
- 旋转：SpringBoard执行延迟、AX返回未知或几何回退造成短时不一致。setter缓存失效以及稍后读回仍失败降低了“只在200ms窗口失败”的解释范围，但现有采样未覆盖1秒以上时间序列，仍未排除。

原因未查明。没有建议增加权限、修改fallback或扩大force范围。

## 最小可执行实际验证方案（本轮未执行）

前提：未来明确选择并受控启动实际客户机；保留classic生产文件。普通rootless现象复现与实际RootHide验收分别记录；RootHide验收必须先提供并证明实际RootHide样本。先记录VM身份、health.instance_id、binary_hash/source_overlay、iOS版本、前台应用和锁状态。

已有诊断无需修改权限：services.status、services.list、services.print可查询服务domain与状态；processes.list可读进程uid；logs.syslog可按process=launchd或SpringBoard有界采集。classic shell可执行id、只读ps和launchctl print system/<label>、launchctl print user/<uid>/<label>。这些查询不能替代RoutineStart实际调用链证据，也不能证明EUID、审核令牌或服务配置检查通过。

probe.py是未运行的单次RPC取证工具。使用已受控开放的本机API URL及0600 token文件，例：

    /usr/bin/python3 /private/tmp/vphone-b28-t08/probe.py --url http://127.0.0.1:PORT --token-file /path/to/token --request-file /private/tmp/vphone-b28-t08/requests/services-status.json --output /private/tmp/vphone-b28-t08/runtime/services-status.json

服务：只对独立、非生产、RunAtLoad=false/KeepAlive=false的fixture调用一次services.start；此前后各记录status和pid。复用B23 fixture步骤，始终finally unload，再确认label absent。增加采集日志后才重试一次，不改变domain顺序；不要把system直接调用或shell fallback当作修复。若另以launchctl start或kickstart对照，须分别记录可执行文件hash/签名、身份、bootstrap上下文和命令类型；不同CLI的成功不能直接证明daemon调用缺少哪个权限。

旋转：同一客户机、同一daemon实例，记录原前台应用和锁状态；解锁并关闭方向锁。依次对Settings、Safari执行0、90、270、180，每次记录setter完整HTTP回复，随后在0、0.25、0.5、1、2秒采样rotationInfo、原生interfaceRotationDegrees/activeInterfaceOrientation及其来源，并保存JPEG。每项记录实际前台bundle/scene、支持方向集合、locked值；每组finally恢复原角度及锁状态。原前台若为未验证Home Screen，不调用apps.launch(com.apple.springboard)，B23已有该恢复调用失败证据；用现有受控Home操作恢复并读回。方向策略假设须与场景方向集合、SpringBoard日志及原生AX值共同核对。

## 最小诊断改动建议与测试点（未修改生产源码）

首选只增日志，不改协议或业务行为：

- 固定依赖Sources/IcliSystemPrivate/Launchd.m的launchdRoutine，拆开记录transport_status、是否有reply、reply.error及final_status；launchdServiceRoutine记录每次routine/domain/handle，包含pid/getuid/geteuid、label及最终domain。serviceActionJSON的xpc_strerror原文一并记录。不要打印完整XPC字典、环境或令牌。使用显式临时诊断开关，默认关闭。
- Sources/IcliPrivate/IcliPrivate.m的setCompositorOrientation/interfaceGeometry记录requested、selector是否存在、AX原始值、截图orientation、几何valid与最终degrees来源和单调时钟；IcliKit/Device.swift在unavailable前记录实际读回。必须在函数实际边界记录，APIWire事后日志无法恢复原始XPC数据。
- 通过仓库dependencies/daemon-api-overlays/新增精确patch及manifest条目绑定revision、base/patched/patch SHA，保留既有JPEG overlay。scripts/daemon_api_overlays.py检查精确源码和marker；不手工编辑不可追溯的checkout。新二进制hash和诊断日志目的地需另做来源核对，不能沿用旧hash的运行授权。

测试点：用模拟XPC返回验证user144时仅一次user调用、user113后system144时两次且最终system、transport144与transport0/reply.error144日志分离；status0和EALREADY原有语义不变；日志关闭时响应和调用顺序不变；输出不含令牌。旋转测试覆盖原生selector缺失、有效返回但读回不符、AX未知而fallback有效、90/270成功和180读回仍270；保留原HTTP400/code/message。测试只证明诊断和控制流，不证明真实guest根因。overlay校验测试位于tests/test_daemon_api_overlays.py；错误包络测试应围绕sources/VPhoneDaemon/Daemon/GuestOperationFailure.swift和APIWire.swift新增隔离测试，不把服务144伪装为.commandFailed。

若必须增加错误details：须先在依赖serviceActionResult抛错前保留typed failure的raw status/domain/message及可选attempts，再由APIWire保留details；保留code/message兼容。现有GuestOperationFailure.response已支持details，缺口在错误来源和catch分支。单改GuestOperationFailure或APIWire无效。优先完成日志诊断，避免同时改变业务调用和包络。

## 现代API_ONLY历史目录与现存宿主工件

- 历史guest目录/二进制：/var/root/vphone-b23-api/vphoned；日志/var/root/vphone-b23-api/b23-api.log。B23-worker-matrix.py:88明确VPHONE_API_ONLY=1启动；B23-worker-matrix.json.initial_control_restored.health读回SHA83075a0c9de2ff5bbfd01b211ce204f59bd18cdf9eb0efb7bd0891a62f00bc07及overlay marker。目标为b21-restored-vm-new-20261009，不能自动换成vm-new。
- 历史B23 stop记录隔离进程清理、classic生产/usr/bin/vphoned和/var/root/Library/Caches/vphoned为306ed42b…；恢复样本保留。现代隔离目录本轮未访问客户机，不声称现在仍存在或可启动。
- 宿主现存两个文件本轮只读hash均为83075a0c9de2ff5bbfd01b211ce204f59bd18cdf9eb0efb7bd0891a62f00bc07，9,041,056字节：.build/acceptance/B22/api-cache-fixed/vphoned与.build/daemon-api-v2/candidate/vphoned。完整绝对路径及hash在references.json。未复制、执行或部署。
- API_ONLY源码main.swift:8–19跳过cached-binary bootstrap、vcam和Irisin startup；仍运行proxy/worker。它不自行赋予新的launchd或Accessibility权限。

剩余工作：取得原始每次XPC调用和原生AX读回的实际日志；受控复现服务fixture及方向矩阵；确认实际RootHide样本后另验RootHide路径/服务。上述工作未执行，T08不具备完整验收依据。
