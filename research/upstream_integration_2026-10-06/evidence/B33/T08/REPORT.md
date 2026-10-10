> 本文为 B33 历史准备记录。后续批准的源维护、RootHide 构造和实际诊断已在 [B34](../../B34/T08/REPORT.md) 完成，源与监测已恢复。

# B33：T08 本机研究环境准备（2026-10-10）

恢复实验前需先暂停源 `vm-new` 的自动恢复。用户已明确批准仅在研究副本内卸载 rootless、安装 RootHide 和清理本轮临时文件/应用，并允许正常停止源 VM；用户同时要求源自动重启时暂停实验。源正常停机后于 2026-10-10 12:53:06（Asia/Shanghai）重新启动，研究副本启动前检查因此拒绝启动。实验已暂停；本轮没有执行 bootstrap 卸载、RootHide 安装或测试应用卸载。无需重复取得上述副本内操作批准。

## 结果与限制

独立研究副本 `/Users/kolar/github/vphone-cli/vm-roothide-b33-20261010` 已创建并完成一次启动、串口恢复 shell 与研究 API 验证。该副本当前仍为 rootless，尚未完成用户要求的 RootHide 转换。T08 的 180° 请求未旋转原因仍未查明；本轮没有运行新的受控方向实验，也没有修改产品源码或固件补丁。

历史 B32 样本 `/Users/qcz3840/github/vphone-cli/vm-roothide-20261010` 与冻结运行工件不在本机。已查证当前仓库、`/Users/kolar/.codex/worktrees` 与 `/private/tmp`；本机最初仅有 `vm-new` 和运行中的 `vm-2607` 两个真实 VM。用户随后明确要求在本机制作满足需求的 RootHide VM。

## 历史证据复核

命令：`.venv/bin/python research/upstream_integration_2026-10-06/evidence/B33/T08/audit-b32.py`。执行通过，结果见 `b32-audit.json`。脚本检查原始 JSONL、每阶段策略与 API 读回的一致性；它不驱动 UIKit，不是实际复现或回归验收。

同 PID 985 的 A/B/A 场景集合为 26→30→26；请求 mask 均为 4。B 阶段 5 个样本均为场景方向 1、方向锁 false、前台状态 0、无错误回调。B 阶段从请求到最后采样仅 1.001660 秒；恢复 A 条件后日志中的请求也切换为 A-restored。现有记录缺少 SpringBoard 请求接收与处理、服务端回复、较长观测窗口和 B 条件下的 90° 阳性对照。该证据不支持把“无错误回调”写为已完成旋转，也不能区分后续处理延迟、系统方向策略或请求传递异常。

恢复实验时先复现该现象：使用相同控制应用源码、相同 PID 的 A/B/A；B 条件增加 90°、0°、180°请求及至少 10 秒采样；断言实际 `effectiveGeometry.interfaceOrientation`，另取 API/AX 与截图。建立实际复现后再按请求边界逐项检验原因。当前不据这些未验证解释修改产品行为。

## 本机环境与输入

- 通过已有生产 CLI `vm clone --library-root /Users/kolar/github/vphone-cli vm-new vm-roothide-b33-20261010` 创建副本，退出 0。复制前确认源 Disk.img 没有打开句柄，复制后源小文件摘要和磁盘 mtime 保持。副本保留设备身份；源和副本不得同时运行。
- 宿主复用本机既有工件，SHA256 `35d53dbd71371180d599f684a1584fdf27fe1b48fb480a5d5bd6390419163623`，CDHash `137689278b29d01a5029da7a8a9bf9711006c083`。本机已有 AMFI 驱动进程覆盖此工件；本任务未启动、停止或修改该驱动，也未修改 SIP/AMFI/TCC 设置。本工件与 B32 的冻结工件不同，不能归为 B32 工件验收。
- 本机已有宿主工件没有 `--no-vphoned-update`。初次启动因未知参数退出 64，未进入 VM。后续使用副本原 `.vphoned.signed` 作为宿主的 classic 更新输入；研究 API 单独以 `VPHONE_API_ONLY=1` 启动，未替换系统 classic daemon。
- 已有 API 构建缓存使用 IcliKit 0.7.7。重新解析固定 0.7.16 后，通过项目 `scripts/build_daemon_api.sh` 完成签名候选构建及精确依赖检查。候选 SHA256 `7f66a29680e0b527e31fa204c2306f750ffccc5a915728ac775ec1cd787ec454`，客户机 GET `/v1/health` 实际返回相同摘要。该运行只验证健康与布局，不构成默认产物或 T08 整体验收。
- 下载 Irisin 4.5.26 与 B29 固定的 89 个软件包，共 99,693,554 字节。90 个输入逐一通过原记录的大小和 SHA256 校验。未更新软件包版本。89 包 control 元数据已从验证后的真实 deb 重新提取；尚未使用客户机 RootHide status 生成最终事务。
- B32 `controlled-fixture-v4.m` 原源码在本机 SDK 27.1 下编译成功；Info.plist 在本机重建，因此 IPA 不等于 B31 冻结工件。编译有 7 项 iOS 16 API 与部署目标 15 的可用性警告；实验客户机为 iOS 26.1，尚未运行该应用。
- 官方 Frida 17.17.0 deb 与 B32 的 SHA256 相同；server/agent 载荷已提取并核对，宿主同版本客户端位于仓库 `.build/research-b33/python`。没有修改项目 venv，也没有向客户机安装 Frida 服务。官方来源见 [Frida 17.17.0 release](https://github.com/frida/frida/releases/tag/17.17.0)。

## 客户机准备

串口实际 `id` 为 UID 0；`/iosbinpack64/bin/bash` 独立运行通过。恢复工具链接位于副本 `/var/root/vphone-b33-control/bin`，指向 System 卷的 iosbinpack64 工具，独立于待卸载的 rootless 目录。

实际 `bootstrap.inspect` 返回唯一 root `/var/jb`；符号链接目标为 `/private/preboot/3121D8E82D1CF4DDDA746144CAE210FB57AF1F46154679DEC7EEA8A917CEFD5A4573C8F1D55B681A5C7844A0D25846A6/jb-vphone/procursus`。Irisin deb 已传入研究副本 `/var/root/vphone-b33-api/irisin.deb`。恢复实验后需重新检查实际 roots，再执行现有 bootstrap.uninstall，随后安装 Irisin、生成真实 status 绑定事务、helper dry-run、实际安装和冷启动核验。

## 失败与环境变化

- 初次 classic 控制连接反复重置，原因未查明。通过串口手工启动原 `/usr/bin/vphoned` 后控制接口可用；不据此确认全部重置原因。
- 串口 base64 传输的临时 classic 文件为 242,051 字节，输入为 242,304 字节，随后客户机报告 Killed: 9。传输不完整原因未查明；该结果不能作为正确签名工件被拒绝的证据。后续 API/Irisin 采用 classic 文件传输，接口报告完整字节数，API 摘要另由实际健康响应核对。
- 首次恢复 shell 命令未设置 PATH，部分工具返回 not found；设置明确 PATH 后重新核对通过。
- Python 软件包下载遇到 TLS EOF；curl 重试后 90 个包通过摘要校验。首次宿主 pip 安装遇到 TLS/IncompleteRead；改用 uv 的仓库内 target/cache 后客户端导入通过。原失败描述和可保全日志保留，不将其归为产品故障。
- 最终快照发现源 `vm-new` 已运行，PID 14780，runtime 记录开始于 2026-10-10 12:09:52（Asia/Shanghai），与研究副本后半段运行重叠。本任务没有发起源的启动；启动来源未查明。源 NVRAM、SEPStorage 和 Disk.img mtime 与准备快照不同；config、classic 载荷和 ROM 摘要保持。最终不能宣称源完全保持。下一次启动研究副本前必须确认源已停机并避免自动重启。研究启动脚本对此设置实际 lsof 检查。

## 停机与磁盘

准备阶段研究副本正常停机，记录 `ApplePSCI - system off`、`Guest stopped` 和退出 0。独立 lsof 确认副本 Disk.img 无打开句柄；源和既有 vm-2607 仍运行，未停止其他任务的 VM。

启动监控每 0.5 秒检查余量，每次研究 API/classic 调用前也检查；阈值按保守的 5 GiB 执行。成功运行约 566.98 秒，最低 300,716,830,720 字节（约 280.07 GiB），阈值未触发。最终空间约 280 GiB。副本和准备输入保留，尚未清理测试文件。用户已批准仅在研究副本内清理本轮临时文件和应用；实验暂停期间未执行清理。

本轮验证为依赖/候选检查、实际串口/API 健康、布局与恢复能力、历史证据复核、脚本语法检查和正常停机。未运行新方向复现、RootHide 安装、软件包事务、冷启动 RootHide 验收或产品全套测试。

## 批准后停机与暂停证据

`stop-source.py` 核对 PID 14780 的真实 VM 命令及源磁盘句柄后，仅发送一次 SIGINT。进程和磁盘句柄消失，连续 10 秒未再次出现，结果为 `stopped_and_quiet_for_10_seconds`，见 `source-normal-stop.json`。随后 `boot.py` 的源磁盘检查失败，发生在创建新运行目录和启动研究 VM 之前。

源 runtime 随后记录 PID 50602、新 instanceID 及开始时间 2026-10-10T04:53:06Z。实际 ps 命令和 lsof 均确认源已运行；研究副本磁盘没有打开句柄，见 `paused-final-state.json`。本任务没有再次停止源 VM，没有关闭其监测程序，也没有启动研究副本。`source-restarted-pause.json` 的首次 ps 采集参数错误，空 `processes` 字段不能作为进程缺失证据；最终独立 ps 采集已补齐。`source-after-approved-stop.json` 是停机操作后采集，期间源已开始重启，不能作为稳定停机基线。

只读核对 `/private/tmp/autophone-rigs/vm-new/health.log`：12:53:04 的 down 事件触发 `/Users/kolar/github/autophone/scripts/on_vphone_down.sh`。该脚本调用 `autophone.recovery_observation`，其注释说明提交恢复请求。时间记录与重启相邻；具体执行重启的调用者未查明，未将钩子直接判为启动者。相关路径、脚本摘要及日志节选保存于 `source-recovery-hook-evidence.json`。未修改仓库外的自动恢复配置。

研究启动脚本新增运行期间源磁盘句柄检查；客户端在每次调用前也检查源状态。检查失败将暂停研究操作，运行中的研究 VM 会收到正常停止信号。这些新增保护仅完成语法与静态检查，尚未通过新一次实际研究 VM 运行验证。源磁盘启动前保护本次实际触发。

最终余量 301,128,884,224 字节（约 280.45 GiB，以 `paused-final-state.json` 为准），未触发 5 GiB 阈值。RootHide 转换、89 包安装、Frida 客户机部署及新的方向复现均未执行。T08 状态保持未完成。

## 继续请求后的离线推进

当前工作区曾切到 `codex/handoff-20261001` 且无未提交修改；已按用户原要求切回 `codex/upstream-2d21d21-integration`，B33 既有记录保持。当前源 runtime 为 PID 20668，开始于 2026-10-10T08:13:27Z；实际 ps 与磁盘句柄确认源在运行，研究副本仍未启动。源健康监测 PID 21157 对应 `vm-new/vphone.sock`。此前自动重启时暂停的条件继续保留。

新增 `rotation_probe.py` 和使用说明：同一 PID/场景的 A/B/A，对 B 条件依次请求90°、0°、180°，每请求至少连续10秒采样。只有阳性和拒绝对照通过，才对 B 180°作稳定旋转或无错误未旋转判定；实际方向取 `effectiveGeometry.interfaceOrientation`，同时保存独立 API/截图观测。脚本保存唯一请求ID，校验前台、方向锁、策略集合、采样间隔和进程/场景身份，并在 finally 尝试恢复本轮策略与0°。其 actual VM 入口未运行。

`.venv/bin/python -m unittest discover -s tests -p test_t08_rotation_probe.py -v` 的8项测试通过，包含原始B32短窗口、无错误未旋转、实际稳定旋转、瞬态目标、拒绝条件、旧请求ID、采样缺口及前台/锁/策略/PID前置条件。原始B32回放退出2并返回 `observation_window_too_short`；这只是证据充分性检查，不能确定未旋转原因，也不构成诊断技能要求的实际失败复现。命令和输出保存在 `offline-probe-validation.json`。

监测暂停方案见 `source-maintenance-plan.md`：仅对精确匹配源 socket 的健康监测进程临时 SIGSTOP，研究结束后恢复源和 SIGCONT；不改源码、配置或数据库。该仓库外进程操作尚未获批准，已提问；没有发送信号或修改仓库外文件。方案不保证阻止其他调度或人工启动，源检查继续保留。

本次磁盘余量约273.51GiB（以新增验证记录为准），5GiB阈值未触发。RootHide转换、89包事务、客户机Frida部署和实际旋转复现仍未执行。原因未查明，T08未新增整项验收。
