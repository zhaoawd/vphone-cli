# F3：性能与长时间运行基线方案

日期：2026-09-18。状态：离线方案，未实现工具，未启动或操作任何 VM，未连接任何控制 socket。清单定义见 [项目迭代清单 F3](project_iteration_checklist_2026-09-08.md)。F1 即将按“本轮组合证据矩阵”关闭，F2 已完成。

本文中“事实”指本轮命令输出或代码/记录中可直接读到的内容；“推断”指由事实推出但未经测量的结论；“待验证假设”需要 F3 实验确认。

## 1. 盘点结果

### 1.1 宿主（2026-09-18 采集，只读命令）

| 项目 | 值 | 来源 |
| --- | --- | --- |
| 型号 | `Mac17,9` | `sysctl hw.model` |
| CPU | 15 核：`hw.perflevel0.physicalcpu=5`，`hw.perflevel1.physicalcpu=10` | `sysctl hw.ncpu hw.perflevel0.physicalcpu hw.perflevel1.physicalcpu` |
| 内存 | 51539607552 字节（48 GiB） | `sysctl hw.memsize` |
| 系统 | macOS 26.5（25F71） | `sw_vers` |
| 数据卷 | 926 GiB，已用 692 GiB，可用 202 GiB | `df -h` |
| 交换 | total 7168 MiB，used 6133 MiB | `sysctl vm.swapusage` |
| 内存与负载快照 | PhysMem 28G used（compressor 6398M），19G unused；Load Avg 2.89/2.88/3.49 | `top -l 1 -n 0` |
| 电源 | 电池供电，38%，放电中 | `pmset -g batt` |
| 睡眠 | `sleep 1 (sleep prevented by powerd, vphone-cli, caffeinate)`，`displaysleep 120` | `pmset -g` |
| 仓库 HEAD | `4776e028b9a7` | `git rev-parse HEAD` |

事实：2026-09-12 的 [rig2 启动排查](rig2_startup_diagnosis_2026-09-12.md) 记录宿主物理内存为 16 GiB，与本轮 48 GiB 不同；是否为不同宿主或硬件变更，含义待确认。F3 结果只绑定采集时的宿主记录，不沿用该历史值。

事实：交换已用 6.1 GiB。推断：此前出现过内存压力；当前压力来源原因未查明。

### 1.2 当前运行进程（`ps -axo pid,pcpu,rss,etime,command`，只读）

| PID | 进程 | 说明 |
| --- | --- | --- |
| 41303 | `.build/vphone-cli.app/.../vphone-cli --config .../vm-2607/config.plist` | `vm-2607`，autophone 使用；启动于 2026-09-16 21:29（`ps -o lstart`）；footprint 337 MB |
| 41311、41316 | `com.apple.Virtualization.VirtualMachine`（XPC） | PPID 均为 1；41311 RSS 约 2.9 GiB、footprint 8341 MB、累计 CPU 186 分钟；41316 RSS 约 8.7 MiB |
| 41825 | `tools.phase1.vsock_health --sock .../vm-2607/vphone.sock` | autophone 健康监控，持续连接 `vm-2607` 控制 socket |
| 43193、43197、81291、84402 | autophone `serve`、`rig.main`、`control.http` | 与 `vm-2607` 相关的 autophone 服务 |
| 19950 | `amfidont --path /Users/kolar/github/vphone-cli --cdhash ...` | 宿主签名放行 |
| 44587 等 | ChatGPT/Codex 沙箱进程，工作目录为本仓库 | 与 VM 的关系未确认 |

事实：VZ XPC 进程的父进程为 launchd（PPID 1），不能从进程树直接归属到某个 vphone-cli。推断：41311 与 41316 属于 `vm-2607`（本轮唯一运行的 VM），两进程一大一小的角色划分未确认。F3 需用第 3.3 节的方法归属。

事实：`footprint <pid>` 以当前用户可读取 vphone-cli 与 VZ XPC 进程（本轮对 41303、41311 执行成功）。`/usr/bin/{footprint,vmmap,heap,leaks,top,vm_stat,powermetrics}` 均存在；`powermetrics` 需要 root，本方案不依赖它。

### 1.3 可复用实例与配置

| 对象 | 事实 | 来源 |
| --- | --- | --- |
| `.build/d4acc/lib/d4-acc` | regular，iOS/cloudOS 26.1/23B85；F1 中完成首次设置、代理写入（`192.168.64.1:10808`）与人工步骤；F1 保留 | [F1 P 组合记录](f1_p_matrix_run_2026-09-17.md) |
| d4-acc 配置 | `cpuCount=8`，`memorySize=8589934592`（8 GiB），`networkConfig.mode=nat`，`screenConfig` 1290×2796、460 ppi、scale 3 | `config.plist` |
| d4-acc 磁盘 | `Disk.img` 逻辑大小 68719476736 字节（64 GiB），`st_blocks=42473888`（实际约 20.25 GiB）；`du -sh` 20G | `stat -f '%z %b'`、`du` |
| d4-acc 运行记录 | `.vphone-runtime.json` 中 pid 21198 已不存在 | `ps -p 21198` |
| d4-acc vphoned | `.vphoned.signed` SHA-256 前缀 `5b63d668c1e8f5e4` | `shasum -a 256` |
| `vm-2607` 配置 | `cpuCount=8`，8 GiB；`Disk.img` `du` 26G | `vm-2607/config.plist` |
| `vm-new` | 目录存在，未运行；用途未确认，本方案不使用 | `ls` |
| CPU/内存设置入口 | `vphone-cli vm new <name> --cpu --memory --disk-size`（默认 8 核、8192 MB、64 GB）；`vphone-cli vm config <name> --cpu --memory`，运行中 VM 被拒绝（持有 bundle 锁） | `sources/vphone-cli/VPhoneVMCLI.swift`、`sources/VPhoneCore/VPhoneBundleOps.swift` `updateConfig` |

d4-acc（regular）在 F1 中的能力边界（事实，来自 F1 记录）：无 shell；`app_launch` 因 uiopen 缺失失败（声明修正 `5fd007c` 未部署）；相机注入 dylib 不存在，S10 为负向；headless 启动下 `screenshot/tap/swipe/camera_present` 不可用（`screen_available=false`）；定位协议层 set/status/stop 通过；S8 开发者模式阻塞。

### 1.4 可复用代码

| 路径 | 可复用内容 |
| --- | --- |
| `scripts/host_control_client.py` | 单连接单请求 UDS 客户端、2 MiB 响应上限、socket 属主检查、`recorder.record(endpoint, request, response)` 回调、`HostControlTransportError.timed_out`、`camera_status`/`running_app` 帮助函数 |
| `scripts/f1_runtime_acceptance.py` | 证据目录与请求记录器、`git_state()`、`host_info()`、`sha256_file()`、`redact()`；S9 定位 `location_source_set` 参数模板（`mode=fixed`、`coordinate_system=wgs84`、`producer_sequence=0`、`timestamp`、`heartbeat_s`）；S10 相机回执校验 `valid_receipt` |
| `.build/f1/runtime.zsh`（Git 忽略） | headless 启动、`doctor --json` 轮询 `guest_connected`（5 秒间隔）、`vm stop` 的驱动模式 |
| `scripts/f2_dual_vm_acceptance.py` | `Evidence` 记录、`preflight` 能力检查、相机 generation/presentation 流程（`camera_isolation`） |
| `research/probes/display_state.c` | 客户机锁屏/熄屏 Darwin 通知状态只读探针（需部署到有 shell 的客户机） |
| `research/probes/a3_home_swipe.py --prepare` | 唤醒并滑动解锁无密码客户机的参考流程（仅限 rig2 设计，需改参数后复用） |
| `vphone-cli doctor [<vm>] --json` | 宿主/占用/客户机连接只读报告，schema `vphone.diagnostics` v1（[D5 记录](d5_diagnostics_2026-09-17.md)） |

### 1.5 宿主控制协议中与测量相关的事实

| 事实 | 位置 |
| --- | --- |
| 每连接一个 JSON 请求、一个 JSON+LF 响应；请求 2 MiB 上限；读、写期限各 5 秒 | [E1](host_control_protocol_e1_2026-09-11.md)、`sources/VPhoneCore/HostControlIO.swift` |
| 连接上限 `maximumConnections=16`；listen backlog 16；超限连接立即关闭 | `VPhoneHostControl.swift`、`HostControlIO.swift` |
| 命令执行期限 `defaultTimeoutMilliseconds=180000`；在途作业数达到 16 时返回 `command_busy`；超时返回 `command_timeout` 且 `operation_may_continue=true` | `VPhoneHostCommandService.swift` |
| `capabilities` 返回 `guest_connected`、`guest_capabilities`、`screen_available`、`commands`、`limits`（含 `command_timeout_ms`） | `VPhoneHostCommandExecutor.swift` `capabilitySnapshot` |
| `file_put`：`data_b64` 解码后 ≤1 MiB，`load` 读宿主普通文件 ≤64 MiB；`file_get`：默认内联 base64，`save` 写宿主文件 | 同上 |
| `tap`/`swipe` 默认 `screen=true`，注入后等待 `delay`（默认 500 ms，swipe 另加 `ms`）再截图；`screen=false` 时注入后立即返回，响应不表示手势完成 | 同上 |
| 客户机请求期限 10/30/180 秒（普通/慢/传输）；握手 8 秒；断线后 `reconnectDelay=3` 秒重连 | `VPhoneControl.swift`、[E4](guest_transport_e4_2026-09-12.md) |
| E4 实测：终止客户机守护进程后约 3.116 秒自动重连（样本数 1） | [E4 同日后续复验](guest_transport_e4_2026-09-12.md) |
| `camera_present`/`camera_status` 的回执轮询：最多 20 次 `vcam_status`，间隔 50 ms | `cameraTransportReceipt` |

相机字段（事实，[E6](camera_receipt_e6_2026-09-14.md)、`VPhoneCameraServer.swift`、`scripts/vphoned/vphoned_vcam.m`、`scripts/vcamcaptured/libvcamcaptured.m`）：

| 字段 | 含义 | 时钟/计数域 |
| --- | --- | --- |
| `host_scheduled_frame_index`（及历史字段 `host_published_frame_index`） | 宿主定时器 tick 计数；新源/停止时归零 | 宿主，按呈现重置 |
| `transport_receipt.vphoned_published_frame_index` | vphoned 发布者进程写入共享内存的累计计数，不按 generation 重置 | 客户机发布者进程生命周期 |
| `transport_receipt.libvcam_observed_frame_index` | 消费端最近一次复制的发布编号（≤ published） | 同上 |
| `vphoned_published_at_ns`、`libvcam_observed_at_ns` | 两者均为客户机 `CLOCK_MONOTONIC` | 客户机单调时钟 |
| `libvcam_observed_count` | 客户机 `vcam_status` 返回，宿主回执未转发 | 仅客户机内部可见 |
| 帧头 `timestamp_ns` | 宿主 `ProcessInfo.systemUptime` 纳秒，写入共享内存头，`vcam_status` 未返回 | 宿主时钟 |

推断：宿主与客户机没有共同时钟字段，现有协议不能直接计算“宿主安排帧 → 客户机消费”的端到端延迟；可计算客户机内部“发布 → 消费复制”延迟和计数差。

宿主帧生产（事实）：定时器在主队列触发，每 tick 将生产与发送异步投递到 `producerQueue`；队列长度没有上限或计数暴露。推断：若生产或写入慢于 fps，队列可能积压；只能通过 `host_scheduled` 与 `published` 的差值间接观察（待验证假设）。

### 1.6 日志缓冲与待处理请求的可观测性（事实）

| 对象 | 代码事实 | 可观测性 |
| --- | --- | --- |
| vphone-cli stdout | `print` 与客户机串口输出（`VPhoneVirtualMachine.swift` 将串口读端转发到 stdout）写入标准输出；`vm launch` 子进程继承 stdio | 重定向到文件时可按文件大小增长测量；输出到无人读取的管道时可能阻塞写入（推断，未验证），基准启动必须重定向到文件 |
| `VPhoneManagedProcess.OutputBox`、`VPhoneProcessRunner.DataBox` | 无上限累积 `Data` | 用于 create/DFU/子进程捕获路径；普通 `--config` 启动的稳态路径未使用（推断，依据调用点，未逐一核对） |
| `VPhoneControl.pendingRequests` | 字典，按请求 ID 增删；无对外计数 | 无直接读数；间接观察：请求延迟分布、`command_timeout` 次数、footprint |
| `VPhoneHostCommandService.jobs` | 在途作业，≥16 时返回 `command_busy` | 无直接读数；间接观察：`command_busy` 出现次数；可选探测见 3.7 |
| 相机 `producerQueue` | 无计数 | 间接：scheduled 与 published 增量比 |
| 客户机 vcam 日志 | `vvc_logf` 追加写 `/var/jb/var/mobile/Library/vphone-vcam.log` | jb/exp 可通过 shell 或 `file_get` 读取大小；regular 无 `/var/jb` 路径（推断） |
| 客户机 vphoned `NSLog` | 系统日志 | 客户机侧需 shell；不纳入必测项 |

### 1.7 F1 运行中与性能相关的现象（事实来源：[F1 P 组合记录](f1_p_matrix_run_2026-09-17.md)）

| 现象 | F3 处理 |
| --- | --- |
| jb 熄屏锁定期间 `app_launch` 连续 3 次 `uiopen ok but no pid`，`screenshot` 返回 `encodingFailed`；解锁后通过 | 作为客户机状态固定项（亮屏、解锁），失败按类别计数，不计入延迟样本 |
| N-jb 中 `screenshot` 返回 `encodingFailed` 时 `app_launch` 成功；截图失败原因未查明 | 截图实验单独记录失败率与失败时刻前后资源样本 |
| exp 相机应用启动约 1 秒后 `camera_present` 返回 `two-level transport receipt unavailable`，4 秒后通过 | 相机实验在消费应用启动后等待并以回执成功为起点 |
| Frida Stalker 卸载与会话分离挂起 | 不属于性能项，不纳入 F3 |

## 2. 实验设置固定项

### 2.1 宿主

| 固定项 | 要求 | 记录方式 |
| --- | --- | --- |
| 型号/内存/系统 | 本轮值：Mac17,9、48 GiB、macOS 26.5（25F71）；变化即视为不同实验设置 | 每次运行写入 `host.json`：`sysctl hw.model hw.memsize hw.ncpu hw.perflevel*`、`sw_vers` |
| 电源 | 接交流电源；低电量模式关闭；运行期间 `caffeinate -dimsu` | 开始/结束记录 `pmset -g batt`、`pmset -g`；`pmset -g therm` 每 5 分钟采样 |
| 其他负载 | 除 `vm-2607` 及其 autophone 服务外，不运行构建、测试、索引、其他 VM | 每 60 秒记录 `top -l 1 -n 0` 摘要与 CPU 前 10 进程 |
| `vm-2607` 状态 | 见 2.5 取舍；共存时记录其 vphone-cli 与 VZ 进程 CPU 时间和 footprint | 与被测 VM 同一采样器、同一时刻采样 |
| 磁盘 | 数据卷可用空间 ≥ 被测 VM 实际占用 + 30 GiB（推断余量，依据 F1 单 VM 24–30 GiB） | 开始/结束 `df -k` |
| 构建 | 独立工作树（例如 `.build/f3/src`）固定提交，`make build` 签名；不替换 `vm-2607` 正在运行的 `.build/vphone-cli.app` | 记录提交、`git status --porcelain`、主程序与 `.vphoned.signed` SHA-256、`codesign -dvvv` 的 cdhash |

### 2.2 固件与变体：取舍

| 方案 | 覆盖 | 不覆盖 | 成本与授权 |
| --- | --- | --- | --- |
| A：只用 d4-acc（regular 26.1/23B85） | capabilities、file_put/get、app_list、location_source_*、GUI 启动下的 screenshot/tap/swipe/key、VM 重启恢复、空闲与重复负载资源 | shell、app_launch（uiopen 缺失）、相机回执与丢帧、vphoned 重启恢复、客户机侧资源 | 无新建；需授权以 GUI 启动 d4-acc、修改客户机“自动锁定”设置 |
| B：新建 exp（26.1/23B85） | A 的全部，加 shell、app_launch、相机、vphoned 重启恢复、客户机侧 `ps`/`vm_stat` | regular 与 exp 的差异不可由 B 单独得出 | 创建约 15 分钟（F1：12:45–13:00 UTC）、首次设置与代理写入需人工；磁盘约 27–30 GiB；需授权新建与结束后删除 |
| C（建议）：A + B | 命令延迟、空闲、重复负载在 d4-acc 上测；相机、vphoned 重启恢复在 exp 上测；两者同构建、同 CPU/内存配置 | 两台不同时运行被测负载，避免相互干扰 | B 的成本；两台 VM 分时运行 |

推断：exp 含内核与 DSC 身份改动，其命令延迟不能直接代表 regular；C 方案中通用命令在两台上各跑一次短基准，差异只作记录，不归因。

### 2.3 VM CPU/内存配置

- 固定 `cpuCount=8`、`memorySize=8 GiB`（d4-acc、`vm-2607` 与 `vm new` 默认值一致）。新建 exp 使用 `vm new/create` 的同值参数。
- 运行前后读取 `config.plist` 的 `cpuCount`、`memorySize` 写入 `vm.json`。
- 不在 F3 基线中改变配置。若用户要求研究配置影响，另列单变量实验（例如 4 核/4 GiB），不与基线合并。

### 2.4 客户机状态

| 项目 | 要求 | 方法 |
| --- | --- | --- |
| 首次设置 | 已完成 | d4-acc 已完成（F1）；新建 exp 需人工完成 |
| 亮屏与锁屏 | 屏幕相关实验期间亮屏且解锁 | 人工在“设置 → 显示与亮度 → 自动锁定”设为“永不”（regular 无 shell，只能人工；该改动需用户授权）；每次屏幕相关实验开始前执行 `screenshot`，失败则按 `key power` 唤醒并人工确认后重试；exp 另部署 `display_state` 读取锁屏状态 |
| 前台应用 | 固定为“设置”根页面（tap/swipe 实验）或相机应用（相机实验） | 实验开始截图保存 |
| 定位源 | 空闲实验分“无定位源”和“固定定位源 heartbeat 1 秒”两种条件 | 开始前 `location_source_status` 为 `off` |
| 启动模式 | 命令延迟与屏幕命令使用 GUI 启动（headless 下屏幕命令不可用）；空闲实验 GUI 与 headless 各一轮（可选） | 记录 `capabilities.boot_mode`、`screen_available` |
| 预热 | 客户机连接后等待 SpringBoard 稳定 5 分钟再开始计时 | 记录 `guest_connected` 首次为 true 的时刻 |

### 2.5 与 `vm-2607` 共存

事实：`vm-2607` 由 autophone 持续使用，其健康监控持续连接控制 socket；本任务无权停止它。宿主 15 核中性能核 5 个，`vm-2607` 与被测 VM 各配置 8 个 vCPU。

| 选项 | 说明 |
| --- | --- |
| 共存（默认） | 采样 `vm-2607` 相关进程作为协变量；报告中标明“共存基线”；不能排除其负载对延迟分位数的影响 |
| 专用时段 | 由用户与 autophone 协调，在 `vm-2607` 停机或空闲时段运行；结果标明“单 VM 基线” |

同一对比（例如优化前后）必须处于同一共存条件。

## 3. 指标定义与采集方法

### 3.1 命令延迟

- 定义：客户端单调时钟 `time.perf_counter_ns()`，从 `socket.connect()` 调用前到收到完整响应行后的时间 `t_total`；另记 `t_connect`（connect 返回）与 `t_send`（sendall 返回），用于区分排队与执行。
- 每个样本记录：命令、参数摘要（不含 base64 内容）、`ok`、`code`、`error` 前 200 字节、响应字节数、开始 UTC 时间、序号。
- 预热：每类命令先执行 10 次，不计入统计。
- 统计：成功样本的 p50/p90/p99、最小/最大、均值；失败样本单独按 `code` 计数，不参与分位数。分位数使用线性插值（NumPy `method="linear"` 等价实现）；另给出 p50/p99 的 bootstrap 95% 置信区间（2000 次重采样）。样本数 < 100 时不报告 p99。
- 并发：主基准串行（并发 1）。可选附加并发 4 的同命令基准，分别报告。
- 顺序：各命令按固定随机种子打乱的轮次交替执行（每轮每类 1 次），减少时间漂移只影响某一类命令。

| 命令 | 参数 | 适用实例 | 每类样本数 N |
| --- | --- | --- | --- |
| `capabilities` | — | 全部 | 500 |
| `location_source_status` | — | 全部 | 500 |
| `app_list` | `filter=running`；`filter=all` | 全部 | 各 200 |
| `file_put` | `data_b64` 1 KiB、64 KiB、1 MiB；`load` 16 MiB、64 MiB | 全部 | 内联各 200；`load` 各 30 |
| `file_get` | 内联 1 KiB、64 KiB、1 MiB；`save` 16 MiB、64 MiB | 全部 | 内联各 200；`save` 各 30 |
| `location_source_set` + `location_source_stop` | 固定坐标，`persist=false`，每对新 generation | 声明 `location_owned` 的实例 | 100 对（分别统计 set 与 stop） |
| `screenshot` | 默认（灰度 compact）；`color=true` | GUI 启动 | 各 200 |
| `tap` | `screen=false`，固定非交互坐标 | GUI 启动 | 200 |
| `swipe` | `screen=false`，`ms=300`，在“设置”列表内上下交替 | GUI 启动 | 200 |
| `tap` | `screen=true`，`delay=0` | GUI 启动 | 100 |
| `shell` | `true` | jb/exp | 200 |
| `app_launch`/`app_terminate` | `com.apple.Preferences` | exp（regular 不适用） | 各 30 |

文件路径：regular 使用 `/var/mobile/Library/f3-bench/<size>.bin`，每次覆盖同一路径，避免基准自身产生磁盘增长；运行结束删除该目录属于客户机文件删除，需在授权范围内确认（见第 7 节）。内容为固定种子伪随机字节，读回后比对 SHA-256，不一致计为失败。

`tap`/`swipe` 的 `screen=false` 延迟只表示注入调用返回，不表示客户机完成手势（事实，见 1.5）。坐标需在实验前人工确认不会触发导航。

### 3.2 连接恢复

| 场景 | 适用 | 操作 | 时间点 | 样本数 |
| --- | --- | --- | --- | --- |
| VM 冷启动 | 全部 | `vm stop` 后以固定参数启动（stdout 重定向文件） | `t0` 启动进程 spawn；`t_sock` `vphone.sock` 出现；`t_guest` `capabilities.guest_connected=true`；`t_caps` `guest_capabilities` 包含预期集合；`t_screen` GUI 模式下 `screenshot` 首次成功 | 10 |
| vphoned 进程重启 | jb/exp | `shell` 下发终止 vphoned（launchd 重新拉起） | `t_kill` 命令发出；`t_down` 首次观察到 `guest_connected=false`；`t_up` 恢复 true；`t_ok` 首个 `file_get` 成功 | 20 |

- 轮询：`capabilities` 每 250 ms 一次；`t_sock` 以 100 ms 间隔 `stat`。轮询间隔带来的分辨率误差上界为轮询间隔，报告中注明。
- 报告：各区间（`t_sock−t0`、`t_guest−t0`、`t_caps−t_guest`、`t_up−t_down`、`t_ok−t_kill`）的中位数、最小、最大与全部样本；超时（冷启动 600 秒、重启 60 秒）计为失败并保留日志。
- 冷启动每次之间间隔固定 60 秒；记录是否首轮（文件缓存影响，待验证假设）。
- 事实：`t_up−t_down` 包含 `reconnectDelay=3` 秒的设计延迟。

### 3.3 宿主进程 CPU 与内存时间序列

| 对象 | 识别 | 采样 |
| --- | --- | --- |
| 被测 vphone-cli | 启动脚本记录的子进程 PID；与 `.vphone-runtime.json` 的 `pid` 核对 | 每 5 秒 `ps -o pid,rss,vsz,time,etime -p`；每 60 秒 `footprint -p <pid>`（取 Footprint 总值） |
| 被测 VZ XPC 进程 | 启动前记录全部 `com.apple.Virtualization.VirtualMachine` PID 集合；启动后新增 PID 归属被测 VM，并以 `ps -o lstart` 核对启动时间在 spawn 后 60 秒内；若新增 PID 数与预期不符，本轮标记“归属不确定” | 同上 |
| `vm-2607` 相关进程 | 41303、41311、41316（每次运行开始重新确认 PID） | 同上 |
| 宿主整体 | — | 每 60 秒 `vm_stat`、`sysctl vm.swapusage`、`sysctl vm.loadavg`、`memory_pressure -Q` |
| 采样器自身 | 采样器 PID | 每 60 秒 `ps -o time` |

- CPU 使用以累计 CPU 时间差计算：`cpu_cores = Δ(user+sys 时间) / Δ(墙钟)`，不使用 `ps %cpu`（其值为衰减平均）。
- 内存以 `footprint` 为主指标，RSS 为辅助指标；两者口径不同，不相互替代。

### 3.4 磁盘实际占用

- 被测 VM `Disk.img`：每 60 秒 `stat -f '%z %b'`，实际占用 = `st_blocks × 512`；`nvram.bin`、`SEPStorage` 同法记录。
- VM 目录下日志文件、`vphone.sock` 以外的新文件：开始与结束 `find <bundle> -type f -exec stat -f '%N %z %b' {} +` 对比。
- 宿主数据卷：每 5 分钟 `df -k`；该值受宿主其他进程影响，只作背景记录。
- 推断：客户机内部删除文件不一定使 `st_blocks` 减少（取决于客户机与 VZ 是否下发 discard，未验证），因此报告“增长量”，不把不减少解释为泄漏。

### 3.5 相机延迟与丢帧（exp）

前提：呈现 1080×1920 QR PNG（F1 已使用的竖屏图），`fps` 分别为 8（默认）与 30；相机应用 `com.apple.camera` 在前台，启动后等待回执成功再开始计时。每 2 秒一次 `camera_status`（带 `generation` 与 `presentation_id`），同时记录客户端请求发出与返回的宿主单调时间 `h_req`、`h_resp`。

记第 i 个成功样本为 `S_i = (h_i, sched_i, pub_i, obs_i, pub_at_i, obs_at_i)`，其中 `h_i = h_resp_i`。仅使用满足以下条件的相邻样本对：generation 与 presentation_id 相同，`streaming=true`，`pub_i ≥ pub_{i-1}`（发布者未重启），`sched_i ≥ sched_{i-1}`。

| 指标 | 公式 | 说明 |
| --- | --- | --- |
| 宿主安排速率 | `r_sched = Δsched / Δh` | 与名义 fps 比较，反映主队列定时器是否延迟 |
| 客户机发布速率 | `r_pub = Δpub / Δ(pub_at)/1e9` | 客户机时钟 |
| 传输缺失率（窗口估计） | `L_tx(W) = 1 − (pub_end − pub_start) / (sched_end − sched_start)`，窗口 W ≥ 60 秒 | 包括 fence 丢弃、生产返回 nil、写失败与窗口边界在途帧；`sched` 在回执等待之后读取（事实），存在单向边界偏差，窗口越长相对影响越小（推断） |
| 宿主积压估计 | `backlog_i = sched_i − pub_i − c`，`c` 为首个样本的差值 | 持续上升表示宿主队列或传输积压（待验证假设） |
| 消费滞后帧数 | `lag_frames_i = pub_i − obs_i` | 采样瞬间消费端落后的帧数 |
| 客户机内部发布→复制延迟 | 当 `obs_i == pub_i` 时，`d_i = obs_at_i − pub_at_i` | 同一客户机 `CLOCK_MONOTONIC`；只在相等样本上定义，报告可用样本比例 |
| 消费跳帧（上界） | `1 − Δobs_distinct / Δpub`，`Δobs_distinct` 为窗口内观察到的不同 `obs` 值个数 | 2 秒采样只能看到部分编号，是上界估计；精确值需要 `libvcam_observed_count`，宿主回执当前未转发（事实） |
| 回执可用率 | 含 `transport_receipt` 的样本 / 全部样本 | 无回执样本单列 |

不可测项（事实 + 推断）：宿主帧安排到应用显示的端到端延迟没有共同时钟字段，F3 不报告。若需要，候选方案为：回执转发 `libvcam_observed_count` 与帧头 `timestamp_ns`，并设计时钟偏移估计；属于代码改动，F3 不预先实施。

时长：每个 fps 连续 30 分钟，样本约 900 个；另做 1 次 60 分钟 fps=8 长运行（与 4.3 合并）。

### 3.6 空闲与重复负载下的资源增长

- 输入序列：3.3 与 3.4 的时间序列，排除启动后前 10 分钟（预热）。
- 斜率估计：Theil–Sen 斜率（单位：footprint MiB/小时、RSS MiB/小时、CPU 核、Disk 实际占用 MiB/小时、日志文件 KiB/小时）。
- 置信区间：移动块 bootstrap（块长 5 分钟，2000 次）求 95% 区间；时间序列存在自相关，不使用普通最小二乘的独立误差区间。
- 判定规则（事先写定，不设数值阈值）：
  1. 95% 区间下限 > 0 的指标记为“增长候选”，只报告，不据此优化。
  2. 同一实验设置的独立第二次运行中该指标再次满足条件 1，且两次斜率同号，记为“测量确认的增长”，进入第 3 项优化候选评估。
  3. 其余情况记为“未检出持续增长”，并同时报告区间宽度（检测能力有限）。
- 另报告首末 10 分钟均值差与最大值，便于人工核对。

### 3.7 日志缓冲与待处理请求

| 对象 | 方法 | 结果口径 |
| --- | --- | --- |
| vphone-cli stdout 日志 | 启动时重定向到 `<out>/boot.log`；每 60 秒记录文件大小 | 按 3.6 计算增长速率；速率稳定线性为预期（日志持续写入），不等同内存缓冲增长 |
| 客户机 vcam 日志（exp） | 每 10 分钟 `shell stat -f %z /var/jb/var/mobile/Library/vphone-vcam.log` | 大小与增长速率 |
| 宿主待处理客户机请求 | 无直接计数（事实）；观察负载结束后 5 分钟空闲期内 footprint 是否回落、`capabilities` 延迟是否回到基线分布、负载期 `command_timeout` 次数 | 只能报告间接证据，不写成“无积压” |
| 宿主在途命令作业 | 无直接计数；负载结束后以 17 个并发 `capabilities` 请求探测，统计 `command_busy` 次数（可选，需确认不影响客户机） | `command_busy=0` 说明探测时在途作业 <16 − 并发数；不证明中间过程无积压 |
| 相机生产队列 | 3.5 `backlog_i` | 间接 |

若需要直接计数，候选改动为在 `capabilities` 或独立诊断命令中增加 `pending_guest_requests`、`host_command_jobs` 只读字段。该改动不属于 F3 基线，是否实施由用户决定。

## 4. 实验矩阵

| 编号 | 实验 | 实例 | 条件 | 样本/时长 | 预计时长 |
| --- | --- | --- | --- | --- | --- |
| E0 | 前置检查 | 全部 | 构建、签名、doctor、宿主记录、客户机状态截图 | — | 15 分钟 |
| E1 | 短基准（命令延迟） | d4-acc（GUI） | 串行；3.1 表 | 约 4200 次请求 | 约 40 分钟（file 64 MiB 与 screenshot 占主要时间；实际待测） |
| E1x | 短基准（exp 通用命令对照 + shell/app） | exp（GUI） | 同 E1 子集 | 约 2000 次请求 | 约 30 分钟 |
| E2 | 冷启动恢复 | d4-acc | headless 与 GUI 各 5 次 | 10 | 约 40 分钟（单次启动时间待测） |
| E3 | vphoned 重启恢复 | exp | GUI | 20 | 约 15 分钟 |
| E4 | 固定时长重复负载 | d4-acc（GUI） | 每 2 秒循环一组：`capabilities`、`location_source_status`、`app_list running`、`file_put`/`file_get` 64 KiB、`screenshot`；每 10 分钟一次 `location_source_set`/`stop` | 60 分钟，约 1800 组 | 60 分钟 + 5 分钟尾部空闲 |
| E5a | 空闲（无定位源） | d4-acc（GUI） | 仅采样，每 60 秒 1 次 `capabilities` 作为探活 | 60 分钟 | 60 分钟 |
| E5b | 空闲（固定定位源 heartbeat 1 秒） | d4-acc（GUI） | 同上 | 60 分钟 | 60 分钟 |
| E6a | 相机推流 fps=8 | exp（GUI） | 3.5 | 30 分钟 | 35 分钟 |
| E6b | 相机推流 fps=30 | exp（GUI） | 3.5 | 30 分钟 | 35 分钟 |
| E6c | 相机长时 fps=8 | exp（GUI） | 3.5 + 3.6 | 60 分钟 | 65 分钟 |
| R | 复跑 | 与出现“增长候选”的实验相同 | 同一设置 | 同原实验 | 视候选数量 |

说明：

- E4、E5、E6c 的分钟数是建议值，不是由统计功效计算得出；若用户有更长连续时段，可改为 120 分钟并在报告中记录。
- E4 负载频率每 2 秒一组，约 0.5 组/秒；这是为长时运行设定的固定节奏，不代表最大吞吐。
- 若选择方案 A，跳过 E1x、E3、E6*。

## 5. 工具实现建议（不实现）

| 项目 | 建议 |
| --- | --- |
| 脚本 | `scripts/f3_benchmark.py`，子命令 `latency`、`recovery-boot`、`recovery-daemon`、`soak`、`idle`、`camera`、`summarize`；宿主采样器 `scripts/f3_host_sampler.py`（独立进程，便于在 VM 启动前开始采样） |
| 复用 | 请求层复用 `scripts/host_control_client.request/endpoint/require_ok/camera_status`；为计时新增不改变现有行为的可选计时回调或在 recorder 中记录时间（修改公共客户端需保持 F1/F2 测试通过）；证据目录、`git_state`、`host_info`、`sha256_file`、`redact` 从 `f1_runtime_acceptance.py` 抽出到 `scripts/lib` 共享模块或直接引用；定位与相机参数模板沿用 F1 S9/S10 |
| 启动/停止 | 冷启动恢复实验沿用 `.build/f1/runtime.zsh` 的启动方式（`--config ... --headless` 或 `vm launch`），stdout/stderr 重定向文件；停止使用 `vm stop`；工具默认不启动 VM，`recovery-boot` 需显式 `--allow-vm-lifecycle` |
| 安全约束 | 拒绝 socket 路径解析到 `vm-2607`；输出目录必须不存在；所有客户机写入限定 `/var/mobile/Library/f3-bench/` |
| 输出 | `<out>/run.json`（设置、提交、SHA-256、宿主、VM 配置、实验参数、随机种子）；`samples/*.jsonl`（每请求一行）；`host_samples.jsonl`；`camera_samples.jsonl`；`summary.json`（分位数、斜率与区间、判定）；`summary.md`（中文表格，由 `summary` 子命令生成） |
| 可复跑记录 | 构建提交与工作树是否干净；`vphone-cli` 主程序 SHA-256 与 cdhash；bundle 内 `.vphoned.signed` SHA-256；客户机 `capabilities.guest_capabilities`；宿主 1.1 各项；VM `config.plist` 的 cpu/内存；`vm-2607` 是否运行；电源状态；实验开始/结束 UTC |
| 测试 | `tests/test_f3_benchmark.py`：分位数插值、bootstrap 种子可复现、Theil–Sen 与块 bootstrap、相机样本对筛选与公式（含发布者重启、presentation 变更、`obs==pub` 边界）、VZ PID 归属、`vm-2607` 路径拒绝、输出 schema；使用本地 Unix socket 假服务端（参考 F2 的 socket 集成测试方式）；纳入 `make test_python` |
| 依赖 | 统计计算优先用标准库实现；若引入 NumPy 需经 `requirements.txt` 与锁定流程 |

## 6. 执行顺序、预计时长与人工环节

| 顺序 | 内容 | 预计时长 | 人工/授权 |
| --- | --- | --- | --- |
| 0 | 用户确认第 8 节决定项 | — | 用户 |
| 1 | 实现工具与测试（离线） | 另行估算 | 无 VM |
| 2 | 独立工作树构建与签名；amfidont 放行新 cdhash | 约 20 分钟 | 管理员密码（F1 方案记录每次构建后需重新放行） |
| 3 | d4-acc GUI 启动；设置“自动锁定=永不”；确认“设置”根页面与 tap/swipe 坐标 | 约 20 分钟 | 用户操作 GUI；授权修改客户机设置 |
| 4 | E0、E1、E5a、E5b、E4（同一次启动内按此顺序；E4 与 E5 间停止并冷启动以隔离） | 约 5 小时 | 专用时段；期间不在宿主运行其他重负载 |
| 5 | E2 冷启动恢复 | 约 40 分钟 | 授权反复启停 d4-acc |
| 6 | （方案 B/C）新建 exp、首次设置、代理写入 | 约 1 小时 | 授权新建；用户操作首次设置 |
| 7 | E1x、E3、E6a、E6b、E6c | 约 3 小时 | 授权终止客户机 vphoned；相机应用首次引导需人工关闭 |
| 8 | 汇总；对“增长候选”安排 R 复跑 | 视结果 | 专用时段 |
| 9 | 结束处理：恢复 d4-acc 自动锁定设置（如用户要求）、删除 `/var/mobile/Library/f3-bench/`、按决定保留或删除 exp | 约 20 分钟 | 删除需用户明确授权 |
| 10 | 仅对“测量确认”的问题提出优化方案，获批后实现，并在相同设置下复跑对应实验比较 | 视问题 | 用户 |

合计 VM 时段约 9–10 小时（方案 C，不含复跑）；可拆分为多个时段，但同一对比的前后运行需保持第 2 节全部固定项一致。

## 7. 风险

| 风险 | 影响 | 处理 |
| --- | --- | --- |
| 与 `vm-2607` 共享宿主 CPU、内存与磁盘 I/O | 延迟分位数与资源序列含外部噪声；vCPU 总数 16 大于性能核 5 个 | 同步采样 `vm-2607` 进程作为协变量；报告标明共存条件；可选专用时段 |
| 宿主交换已使用 6.1 GiB | 长时实验中可能出现换页导致的延迟尖峰 | 记录 swapins/swapouts 增量；开始前记录 `memory_pressure` |
| 电池供电与热降频 | CPU 频率变化影响延迟 | 要求交流电源；记录 `pmset -g therm` |
| 屏幕熄灭或锁定 | `screenshot` 失败、应用启动失败（F1 事实） | 自动锁定“永不”；实验前截图检查；失败按 code 计数并保留时刻 |
| 替换正在运行的应用包 | `vm-2607` 使用 `.build/vphone-cli.app` | 在独立工作树构建，不写入该路径 |
| amfidont 放行 | 新构建未放行时进程被 SIGKILL | 构建后按既有流程放行 |
| 基准自身影响 | 采样器与 `camera_status` 轮询占用 CPU，并触发客户机 `vcam_status` 请求 | 记录采样器 CPU；相机轮询间隔固定为 2 秒并在报告中说明 |
| stdout 管道阻塞 | 串口输出写入无人读取的管道可能阻塞（推断） | 统一重定向到文件 |
| 客户机文件写入增长 | 重复写入使 Disk.img 实际占用增长 | 覆盖固定路径；结束时的删除需授权 |
| 连接并发探测 | 17 个并发请求可能与 autophone 无关，但会占满被测 VM 命令槽 | 仅在负载结束后执行，且为可选项 |
| VZ XPC 进程归属错误 | 资源数据归属到错误 VM | 启动前后 PID 集合差与 `lstart` 双重核对；不确定时标记 |

## 8. 需要用户决定的事项

1. 固件/变体方案：A（只用 d4-acc）、B（只用新建 exp）或 C（两者，建议）。选择 B/C 时是否授权新建 exp VM（约 27–30 GiB），以及结束后保留或删除。
2. 与 `vm-2607` 的关系：接受共存基线，或协调 autophone 专用时段。
3. 是否授权修改 d4-acc（及 exp）客户机“自动锁定”为“永不”，以及实验后是否恢复。
4. 连续时长：E4/E5/E6c 采用 60 分钟，或更长（例如 120 分钟）；是否需要 GUI 与 headless 两种空闲对照。
5. 是否授权对 exp 执行 vphoned 进程终止（E3）与 d4-acc 反复冷启动（E2，10 次）。
6. 是否授权基准结束后删除客户机 `/var/mobile/Library/f3-bench/`。
7. 增长判定规则：接受 3.6 的“两次独立运行均区间下限 > 0 才确认”规则，或指定数值阈值（需给出依据）。
8. 是否接受 3.5 声明的相机端到端延迟不可测；若需要，是否将“回执转发 `libvcam_observed_count`/`timestamp_ns`”或“宿主暴露待处理请求计数”列为 F3 之前的独立代码项。
9. 统计依赖：仅用标准库，或引入 NumPy。
10. 构建提交：F1 运行使用 `22a7c02` 构建；当前 HEAD `4776e02` 已包含 `5fd007c`（`apps_v2`/`app_launch` 能力声明修正）。F3 以 F1 关闭时的 HEAD 构建（客户机 vphoned 随启动更新，能力声明会与 F1 运行时不同），或沿用 `22a7c02` 构建以对齐 F1 证据。
