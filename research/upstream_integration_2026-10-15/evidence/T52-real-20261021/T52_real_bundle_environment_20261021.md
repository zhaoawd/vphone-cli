# T52 真实 Core Bundle 绑定与环境替换验收（保留默认 GUI 关机限制）

本轮对象为独立 `t52-v2`，路径 `.build/t51rt/lib/t52-v2`。真实创建、完整备份、宿主绑定和五库离线替换已验证。替换后只读 `already_current`，33 项离线断言通过；客户机五库摘要与当前映射匹配，24 项 API 模式运行证据断言通过，界面正常停止并释放磁盘和锁。默认 GUI 启动未启用 API 时，本次关机仍超时并触发框架强制停止，该限制未修复。临时辅助进程已停止，原 VM 保持运行。应用行为与物理外置卷未验收；`accepted=false`，T52 未提交或推送。

## 实验设置

- Core Bundle：`2.6.2-local.cd529f26a150`，新增到 `/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.cd529f26a150`；安装及非特权读取的收据核验已通过。
- 归档 SHA-256：`f61ce4e0f1c6437fa55b7e488a9c888dd5b5e2bd92b2741fa8a4a2134964660c`。
- VM CDHash：`2d9b99f3a41e6f7ba7bb3d5558f15524b409b3b5`。仅该哈希；不写持久允许名单。
- iOS/cloudOS：26.1/23B85，本地固件内容摘要见 `firmware-inputs.json`。创建检查点中的 source.sha256 为源路径字符串摘要，不能用来与归档内容摘要比较。
- 基线和目标采用同一固定源码，分别以 `-O0` 和 `-Os` 编译五个客户机库，签名与组件清单核验通过。此实验验证真实签名构建产物替换，不代表上游版本升级。
- 初始 classic 副本 `t52-environment` 被生产检查分类为 `full_migration_required`；未绕过拒绝条件。新建 v2 VM 用于正向替换验收。

## 已验证的修改

绑定环境更新固定使用所选 Bundle 封装的组件目录，拒绝显式资源覆盖，并忽略继承的组件目录覆盖。构建流程打包并检查该目录。Swift 定向测试组 9/7/10 项通过；Python 扩展 196 项通过；真实签名归档 Store 测试 1 项通过。计数按各组报告，不与历史分组累加。

## 创建与失败证据

1. prepare、patch 已通过，实际补丁记录 58 条。没有为本轮新增固件指令补丁。
2. 首次临时辅助进程提前退出，日志为 `Unexpected process state 10`。随后 DFU 被 amfid 拒绝受限权限，恢复尚未开始。进程异常的原因未查明。
3. 用户重新批准并执行 retry-1：2026-10-21T14:30:05Z 开始，统一绝对截止 2026-10-21T15:00:05Z，最多附加三次。
4. 沙箱内续跑仍在 DFU 获取锁前失败；沙箱外直接运行相同快照 CLI 获得 `VM lock acquired`，15 秒后结束探测且无遗留进程。同参数和环境在沙箱外续跑后，恢复通过，进入 CFW 安装。该对照支持执行沙箱限制影响启动；具体限制项未确认。

工作证据保留于 `.build/t52-real-20261021/`。失败日志保留；完整证据归档及后续结果待本轮完成后更新。

## 未覆盖与已知限制

- 默认 GUI 启动未启用客户机 API，本次停止走 VZ requestStop 后超时，使用框架强制停止。API 模式对照正常关机通过。框架请求为何未使该客户机关机，原因未查明。
- 客户机 API 已确认文件和映射，摄像头、定位及应用行为仍未验证。
- 物理外置卷按用户指示暂缓；本轮不代替人工审阅，accepted=false。

## CFW 失败与资源选择修正

CFW 于 2026-10-21T14:47:06Z 退出 1。失败事务 `20261021T143743Z-jXK1Nkwo` 记录原盘设备号/inode/大小/修改时间和抽样 66 处摘要保持，暂存盘未发布，清理已完成。只读调用相同快照的 `check_guest_api.py` 稳定复现 `API build pins differ from the fixed dependency graph`：前次验收命令保留 `--project-root`，选择了仓库 `.build/guest/api` 中 IcliKit 0.8.5 载荷，与 0.8.6 依赖清单不匹配。批准 Bundle 内同一检查器和封装的 0.8.6 载荷通过。

已准备移除 `--project-root`、使用批准的完整封装资源并显式记录资源工具链变更；CLI/VM 字节与基线组件环境保持。续跑在资源快照保留上限 8 份处被拒绝，CFW 未重启。没有修改保留上限或删除证据。

失败快照 `14235815-5ff4-496d-88e1-c9960d85a6eb` 已完整复制到 `.build/t52-real-20261021/retained-toolchains/` 同名目录；347 项类型、mode、UID/GID、大小、文件 SHA-256 与链接目标核对一致，源目录再核对保持。删除仓库外原副本正在请求用户明确确认。其余快照保持。

## 临时放行停止

等待快照删除批准期间，已通过stop标记停止辅助进程27581。停止时间2026-10-21T14:52:44Z，早于原绝对截止；独立ps确认PID不存在。amfid已脱离debugserver，t52-v2无遗留进程，vm-2607继续由原PID33355运行。没有写持久允许名单；此窗口不复用。后续CFW和离线绑定/替换本身不要求该辅助进程，实际VM再次被AMFI拒绝时才需要具名新窗口批准。

实际界面补验：CFW期间启动按钮禁用；退出后t52-v2显示已停止、创建检查点为failed/cfw，绑定仍缺失。AX与截图已归档。

## 已批准的快照处置与封装资源续跑

用户明确批准删除具名已备份失败快照。删除前重新核验源目录、备份目录与记录的347项清单一致，并检查无进程使用；删除后备份再核验通过，其余7份快照名称集合保持。已使用批准Bundle完整封装资源续跑CFW，记录`--accept-tool-change`资源指纹变化，未重启已停止的AMFI辅助进程。

封装资源续跑的实际快照为`b3c82a8f-7d92-4936-bccc-c147a047360a`。该快照的classic/API组合检查、生产安装器的五库候选检查及v2 daemon候选检查均通过；基线组件与构建后已验证目录逐文件摘要相同。源代码构建检查器直接放在mini-repo运行会因未封装源码而失败，不作为安装候选的运行时检查结果；原失败记录保留，实际生产候选检查单独保存。

## 真实 launchd 签名空间缺陷与修复

封装资源 CFW 事务`20261021T150033Z-LgvNNC6B`在 v2 注入签名处失败，报告`signature load command overwrote non-padding bytes`。原命令区结束3192，__text起点3208；/vh注入后命令区到3208，外部ldid追加16字节LC_CODE_SIGNATURE到3224，覆盖前16字节代码。离线重放相同保存字节和实际ldid稳定复现。校验器正确拒绝；暂存盘未发布，原盘设备号/inode/大小/修改时间及抽样摘要保持。

修复在注册的v2注入步骤中显式预留签名空间：仅必要时移除信息性LC_SOURCE_VERSION，保留LC_UUID、其他命令、代码和节偏移。沿用现有VPhoneMachOImage.signed策略。新增修改由既有Mach-O效果证明记录，verify_signing拒绝条件不变。缺少可移除命令、命令区与内容重叠、预留区非零时拒绝；已有足够空间时不改写。

- `.venv/bin/python3 -B -m unittest tests.test_component_signatures tests.test_component_effects tests.test_patch_plan_gate tests.test_cfw_env_install tests.test_cfw_env_update tests.test_cfw_disk_transaction tests.test_cfw_host_isolation`：217项通过；初次沙箱运行的一项EPERM在正常主机权限下通过。
- 最终签名单元组14项通过。真实注入/签名/最终证明链用例升级为无剩余header空间的节布局；临时禁用预留步骤时复现原拒绝，启用时通过。
- `.venv/bin/python3 -B research/upstream_integration_2026-10-15/tools/verify_t52_launchd_signing.py`：实际保存字节复验通过，代码、entitlements保持，全部最终CodeDirectory页摘要通过。预留后命令区3192，签名后3208。

修复放入独立未绑定创建资源副本`.build/t52-real-20261021/creation-toolchain/Contents/Resources`，仅两个脚本与已安装资源不同，变更摘要已记录。已安装Bundle未改写。本次创建结果不能用作已安装Bundle原有创建流程已修复的证据；后续绑定与五库更新仍使用已批准的系统Bundle。

用户明确批准后，重新核验347项并删除211c7983及66564e56两个原临时快照；完整备份再核验通过，其他6份保持。修复后的CFW已续跑，日志`.build/t52-real-20261021/cfw-fix/create.log`；未启动新AMFI放行窗口。

## v2 API profile 重复安装顺序

事务`20261021T152829Z-J0vIUUED`的v2安装报告为installed，实际launchd注入和签名已通过，权限摘要前后相同。最终transport校验拒绝`unrelated copy overwrites an earlier required effect`：基础阶段按classic profile写入API plist，v2阶段再用另一个profile写入同一目标。原盘身份/抽样摘要保持，暂存盘未发布。

将真实`cfw_stage_api`基础写入、冻结配置下的`inject-daemons`、v2安装和最终证明组合到保存的回归中，复现相同拒绝。修复保留基础组合候选校验，v2模式的API实际安装交给v2阶段；基础boot plist合并按冻结profile排除缓存classic API job。classic默认合并行为保持测试覆盖。transport/effects最终拒绝条件未改。9项定向、235项扩展通过；语法及diff空白检查通过。

独立创建资源副本增加`cfw_common.sh`、`cfw.py`、`cfw_daemons.py`三处修改，合计五个脚本与安装资源不同；仍未改写系统Bundle。新续跑日志`cfw-profile-fix/create.log`。

同一已批准VM二进制的只读`--help`预检退出-9，23:50:27的amfid日志确认Code=-424受限权限拒绝。未打开VM磁盘，未启动VM。已请求新的boot-window单哈希30分钟授权，脚本准备完成但未启动。旧窗口不复用。

用户已批准boot-window的新30分钟单哈希启动窗口，范围为独立t52-v2首次启动、创建验证和替换后启动。脚本尚未启动，统一截止从实际启动计时；计划在CFW后段请求用户终端完成认证。

## 2026-10-22：真实创建、首次绑定和界面环境继承缺陷

独立t52-v2创建续跑退出0。CFW发布通过；first_boot检测到shell prompt，发送既定命令并关机；verification再次检测到bash prompt，所有适用阶段均为succeeded且verified。替换前实际只读检查为offline_update，五个库分别匹配固定源码的-O0基线，磁盘抽样和身份保持。

实际Launchpad提交首次完整备份，生产绑定命令完成三份完整文件清单比较后发布2.6.2-local.cd529f26a150绑定。另行复核备份和当前盘的66处抽样一致、七个身份/配置文件摘要保持，备份无launchpad.json。绑定后的环境预检报告找不到lsof，尚未写盘；绑定按设计保留。

最小Foundation实验和实际子进程类回归均确认当前macOS上显式Process.environment=nil丢失继承环境。改为仅在显式提供环境时赋值，保留空字典和指定PATH覆盖行为。原继承测试失败，修复后23项相关测试通过；完整Kit258项测试通过、跳过17项。新的隔离界面候选.build/t52-envfix-launchpad-20261022.app已构建并通过签名/封装检查，内嵌CLI/VM字节保持，待用户给予新候选打开授权后重试实际环境替换。系统Bundle未改。

boot-window于2026-10-21T16:01:17Z启动，首轮实际放行覆盖了创建启动；16:16:12Z在三次附加后停止，错误Unexpected process state 10，辅助PID已不存在。随后同一VM二进制--help退出-9，amfid新PID2568记录受限权限Code=-424拒绝；原amfid PID78198已消失。日志未确认其退出原因；没有新的主动附加授权，因此未以主动调试复现原因，也未改写宿主amfidont安装。不得复用三次额度。离线替换继续，替换后启动需新的具名授权窗口。

## 2026-10-22 03:40：实际环境替换与独立读回通过

用户批准并打开环境继承修复候选，界面选择已绑定的t52-v2并启用环境更新；实际launcher将绑定摘要固定为a1052a1068b815ee862b89cc7843bd1091d6ec1c0567aaacdec6b8e4ddfd1ba1，执行系统Bundle封装CLI和组件。用户在系统弹窗完成管理员认证。事务20261021T163833Z-aCYGC037于北京时间00:43:02发布，exit_code=0，五个库均由-O0基线替换为-Os目标；七个身份/配置文件保持。没有重启客户机。

03:38后的独立只读检查为already_current，无剩余替换项；检查期间磁盘保持。保存的断言脚本33项全部通过，包括五个基线/目标/生产者摘要、磁盘inode交换、大小/owner/mode、身份/配置/变体/guest environment记录及新增历史记录。另行核对历史Disk.img inode248683860及66处抽样摘要与替换前记录一致，现有Disk.img inode248707904、大小68719476736。该抽样复核不表示另外计算了历史盘完整摘要；首次绑定的完整备份校验由生产命令完成。

执行命令与报告：

```sh
.venv/bin/python3 -B research/upstream_integration_2026-10-15/tools/read_t52_environment.py after
.venv/bin/python3 -B research/upstream_integration_2026-10-15/tools/verify_t52_environment_acceptance.py \
  --before .build/t52-real-20261021/environment-before-2.json \
  --after .build/t52-real-20261021/environment-after.json \
  --comparison .build/t52-real-20261021/component-comparison.json \
  --metadata-before .build/t52-real-20261021/metadata-before-2.json \
  --metadata-after .build/t52-real-20261021/metadata-after.json \
  --output .build/t52-real-20261021/environment-acceptance.json
```

已再次核验系统Bundle收据。base、target、t52-environment的设备号/inode/大小/mtime及选定身份文件摘要保持；vm-2607仍为PID33355。独立t52-v2无运行进程、无挂载、目录锁可获取；无本次具名AMFI辅助进程。当前同一VM二进制--help仍退出-9，未打开VM磁盘。

上次进程读取被自动批准审核的额度限制阻止，命令未执行；此次在所提示的重置时间之后重新提交审核，进程读取通过。未绕过审核。单次续推发现Mac锁定，Computer Use无法检查完成界面；已请求用户手动解锁，并请求新的600秒、一次附加、同一CDHash的启动窗口批准。新脚本已准备、未运行，无新允许名单写入。替换后启动、五库客户机内读回、正常关机及应用级激活仍未验证。此次未新增重复调度。

2026-10-22 06:38单次续推仅复核状态：最新会话未收到解锁和新窗口批准回复；窗口未启动，替换后磁盘stat保持，未重复执行已通过的更新。续推调度已按指令设为PAUSED并独立核对；后续依赖原有待答请求。此复核未重新读取界面，不据此推断当前锁屏状态。

## 2026-10-22 07:14：替换后客户机读回、映射与关机对照

用户已解锁Mac，并批准新的600秒、一次附加、仅CDHash `2d9b99f3a41e6f7ba7bb3d5558f15524b409b3b5` 的窗口，随后在自己的终端完成sudo认证。辅助进程17044于07:08:27.252启动，07:14:19.965停止，实际352.713秒，独立ps确认不存在；没有写持久允许名单。两次启动均使用同一已安装Bundle的VM字节和冻结绑定，处于同一绝对窗口内；没有重新附加或延长窗口。

| 实验设置 | 结果 | 证据 |
| --- | --- | --- |
| 实际Launchpad默认启动，VM PID17501，实例2E9AED7C-6215-4FAB-9289-3456350BFD09 | 正常启动，26.1/23B85及五库目标摘要读回通过。停止走requestStop并超时，随后框架强制停止；正常关机断言失败 | post-update-stop-failure/serial.log、failure.json、validation.json及validation.log |
| 同一绑定CLI启动，显式--api-listen 127.0.0.1:0，临时随机令牌未保存，VM PID19590，实例ADA8D757-702F-49E9-8A1F-656FB06267C1；经实际Launchpad停止 | API声明system.shutdown，五库摘要再次匹配，界面停止得到apiAccepted，日志出现Guest stopped，wrapper退出0，无超时/强制停止，磁盘和目录锁释放 | api-boot/launch-result.json、readiness.json、serial.log及post-update-stop-result.json |

第二组启用了宿主API，也将启动方式从GUI改为绑定CLI/headless，因此不是严格的单变量实验。源码VPhoneAppDelegate仅在apiOptions存在时创建apiSession；第一次能力报告中rpc/environment_status为false、经典通道shell为false。关机选择条件因而没有客户机命令路径。第二次API就绪并接受system.shutdown，支持“未启用宿主API会话导致该命令关机路径不可用”的结论。该对照没有解释VZ请求未被本次客户机完成的原因，也没有修复默认GUI启动选项。默认模式的失败不会被第二次成功覆盖。

API environment_status返回already_current，environment.loaded扫描264个进程，complete=true、uninspected为空。五个库均为current、stale为空：launchdhook在PID1；SystemHook、libvcamcaptured、libcamfix、libvlocation均有当前映射。保存的文件读回脚本只断言文件字节；后续verify_t52_runtime_evidence.py另行断言映射、正常关机、实例对应和辅助进程界限，共24项通过。该证据不表示摄像头或定位的应用行为已通过。

正常关机校验器保持原断言：重放首次模式的原runtime与serial时仍退出1、报告强制停止；使用API模式serial时退出0。没有删除或弱化失败断言。已保存的复验命令：

```sh
.venv/bin/python3 -B research/upstream_integration_2026-10-15/tools/verify_t52_running_guest.py
.venv/bin/python3 -B research/upstream_integration_2026-10-15/tools/verify_t52_stopped.py \
  --serial .build/t52-real-20261021/api-boot/serial.log
.venv/bin/python3 -B research/upstream_integration_2026-10-15/tools/verify_t52_runtime_evidence.py
```

第一条只读取已经运行的具名VM，不启动或停止进程；本轮API模式运行时退出0。第二条本轮退出0；首次失败重放的完整argv和退出1保存在post-update-stop-failure/validation.json。第三条24项证据断言通过。界面updated/running/stopped脚本回归及AX/截图均保存，API模式启动使用绑定CLI，停止使用实际GUI；不将该模式表述为默认GUI启动已经支持正常关机。

最终复核：系统Bundle收据通过；base、target、t52-environment的设备号/inode/大小/mtime及选定身份摘要保持，vm-2607仍为PID33355。独立VM及具名辅助进程不在运行，无目标挂载；config、launchpad绑定、restore-info及UDID记录摘要保持。目标Disk、NVRAM与SEP允许本次客户机启动的正常写入，不用启动前mtime判断其保持。未修改系统Bundle，未安装新版本，未提交或推送。续推调度保持暂停。
