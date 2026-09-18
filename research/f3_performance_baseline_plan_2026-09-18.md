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
| `tap` | `screen=false`，固定非交互坐标；节流间隔 `--tap-spacing-ms`（默认 100 毫秒） | GUI 启动 | 200 |
| `swipe` | `screen=false`，`ms=--swipe-ms`（默认 300），在“设置”列表内上下交替；节流间隔 `--swipe-spacing-ms`（默认 `--swipe-ms` + 50 毫秒） | GUI 启动 | 200 |
| `tap` | `screen=true`，`delay=0`；节流间隔同上 `--tap-spacing-ms` | GUI 启动 | 100 |
| `shell` | `true` | jb/exp | 200 |
| `app_launch`/`app_terminate` | `com.apple.Preferences` | exp（regular 不适用） | 各 30 |

文件路径：regular 使用 `/var/mobile/Library/f3-bench/<size>.bin`，每次覆盖同一路径，避免基准自身产生磁盘增长；运行结束删除该目录属于客户机文件删除，需在授权范围内确认（见第 7 节）。内容为固定种子伪随机字节，读回后比对 SHA-256，不一致计为失败。

`tap`/`swipe` 的 `screen=false` 延迟只表示注入调用返回，不表示客户机完成手势（事实，见 1.5）。坐标需在实验前人工确认不会触发导航。

手势节流：注入器一次只执行一个手势，手势执行期间到达的请求以 `code=gesture_busy` 被拒绝（`tap` 占用 80 毫秒，`swipe` 占用其 `ms` 时长，见 10.10）。因此三个手势类共用一个最小间隔，从一次请求开始到下一次请求开始计时：`tap` 两类合计不小于 `--tap-spacing-ms`，`swipe` 不小于 `--swipe-spacing-ms`。`--swipe-spacing-ms` 默认由本次运行发送的 `--swipe-ms` 加 50 毫秒余量得出，改变 `ms` 时长间隔随之改变。等待发生在请求开始之前，不计入 `t_total`；轮次中已经消耗在其他命令类上的时间计入该间隔，已超过间隔的轮次不再等待；非手势命令类不受该间隔约束。生效值记入 `run.json` 的 `parameters`。

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
- 置信区间：移动块 bootstrap（块长 5 分钟，2000 次）求 95% 区间；时间序列存在自相关，不使用普通最小二乘的独立误差区间。重采样对象为 Theil–Sen 拟合后的残差，不是原始值：拼接原始值块会使跨块点对不携带趋势信息，而跨块点对在点对总数中占多数，点对中位数被拉向 0，得到的是零假设分布而非斜率的置信区间（实现时用构造的上升序列验证：原始值块拼接给出包含 0 的区间，残差重采样给出下限 > 0 且覆盖真值的区间）。实现见 `scripts/f3_stats.py` 的 `moving_block_bootstrap_slope_ci`。
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

## 9. 决定记录（2026-09-18，用户回复“按建议来”）

第 8 节各项按方案内建议取值确认如下。本节为授权与设置的真源；与第 2–7 节的“可选/待定”表述冲突时以本节为准。

| 项 | 决定 | 由此产生的授权或固定项 |
| --- | --- | --- |
| 1 | 方案 C：d4-acc + 新建 exp | 授权新建一台 exp VM（26.1/23B85，约 27–30 GiB），实验全部结束后删除该 exp |
| 2 | 接受共存基线 | 先与 `vm-2607` 共存跑一轮；不请求 autophone 专用时段。若共存噪声使指标无法判读，再单独提出专用时段申请 |
| 3 | 授权将客户机“自动锁定”设为“永不” | 适用于 d4-acc 与新建 exp；记录 d4-acc 原值，实验结束后恢复；exp 因删除不需恢复 |
| 4 | E4/E5/E6c 采用 60 分钟 | headless 空闲对照为可选项，本轮不执行；E2 冷启动恢复仍按 headless 5 次 + GUI 5 次 |
| 5 | 授权 E3 与 E2 | 授权在 exp 上经 `shell` 终止 vphoned（20 次），授权 d4-acc 冷启动 10 次 |
| 6 | 授权删除 `/var/mobile/Library/f3-bench/` | 仅限该目录，基准结束后执行 |
| 7 | 接受 3.6 判定规则 | 不设数值阈值；“测量确认的增长”需两次独立运行均满足区间下限 > 0 且斜率同号 |
| 8 | 接受相机端到端延迟不可测 | 不在 F3 之前实施“回执转发 `libvcam_observed_count`/`timestamp_ns`”与“宿主暴露待处理请求计数”；两项列为 F3 之后的候选改动 |
| 9 | 仅用标准库 | 不引入 NumPy；分位数、bootstrap、Theil–Sen 自行实现并测试 |
| 10 | 以 F1 关闭时的 HEAD `0d7b009` 构建 | 该构建含 `5fd007c`；与 F1 的 `22a7c02` 证据比较时标注构建差异。E0 顺带记录 regular/dev/less 的 `app_launch`/`apps_v2` 能力声明，作为 `5fd007c` 的部署后观察（不改变 F1 已关闭的结论） |

补充固定项：用户确认实验期间宿主接交流电源（2.1 已列为要求）。

执行状态见第 10 节。

## 10. 执行记录

### 10.1 顺序 1：工具与测试（离线，已完成）

提交 `f92ac0f`（`scripts/f3_*.py` 与 `tests/test_f3_*.py`，`scripts/host_control_client.py` 计时扩展，`f1_runtime_acceptance.py` 导入改动）与 `c6b38c8`（第 9 节决定记录、3.6 残差块 bootstrap 方法说明）。两个提交均在本地，未推送。未启动 VM，未连接控制 socket。

### 10.2 顺序 2：独立工作树构建与签名（2026-09-18，已完成）

| 项目 | 值 | 来源 |
| --- | --- | --- |
| 工作树 | `.build/f3/src`，`git worktree add .build/f3/src 0d7b009` | 命令输出 |
| 提交 | `0d7b009a9434d9b1d58208ad003bfaa6890d6fc4`（第 9 节决定 10 指定） | `git rev-parse HEAD` |
| 工作树状态 | `git status --porcelain` 无输出 | 同上目录执行 |
| 前置 | `git submodule update --init --recursive`（8 个子模块 + capstone 嵌套子模块）；从主工作树复制 `.tools/bin/{trustcache,insert_dylib}`（未跟踪文件） | 命令输出 |
| 构建 | `make build` 退出码 0，01:29:39Z–01:30:34Z（约 55 秒） | 命令输出 |
| 嵌入提交号 | `VPhoneBuildInfo.commitHash = "0d7b009"` | `sources/VPhoneCore/VPhoneBuildInfo.swift`（构建生成） |
| 构建产物占用 | `.build/f3/src/.build` 536 MB；构建后数据卷可用 200 GiB | `du -sh`、`df -h` |

SHA-256 与 cdhash（记录用于第 2.1 节“可复跑记录”）：

| 对象 | SHA-256 | cdhash |
| --- | --- | --- |
| `.build/release/vphone-cli` | `521d69010804729005b9163199371ac4fe69b9a42bbf261e11043514536c7b16` | `c7c1d3869e7fa16c920f728feca7c5e2f5ec9b13` |
| `.build/vphone-cli.app/Contents/MacOS/vphone-cli` | `82e5fefad3d93e2eba5eed3618864951aaa41749170bc422c73932792cbb6a0c` | `d29917d76cf22e6b82c154d67f92f25c6e992250` |
| `.build/vphoned.signed`（与 bundle 内 `Contents/Resources/vphoned.signed` 相同） | `5f4b708beefc095d151e4ffd0d509743773f9082522146daf3953bc0777caa97` | — |

事实：该 `vphoned.signed` 与 d4-acc 当前已部署的 `.vphoned.signed`（前缀 `5b63d668c1e8f5e4`，见 1.3）不同。按第 9 节决定 10，客户机 vphoned 随启动更新，E0 需记录更新后的能力声明。

运行验证（本轮未启动任何 VM）：

| 检查 | 结果 |
| --- | --- |
| `.build/release/vphone-cli --help` | 退出码 0（未被 AMFI SIGKILL；137 表示仍被终止） |
| `.build/vphone-cli.app/Contents/MacOS/vphone-cli --help` | 退出码 0 |
| `codesign -d --entitlements -` | 含 `com.apple.private.virtualization`、`com.apple.private.virtualization.security-research`、`com.apple.security.virtualization`、`com.apple.private.bmk.allow` |
| `vphone-cli doctor --json` | 退出码 3（含 warning）；`macos 26.5.0`、`kern.hv_support=1`、`kern.hv_vmm_present=0`、SIP `custom configuration` |

amfidont 放行（本轮未使用管理员密码）：

- 事实：守护进程 pid 19950 已在运行，参数为 `--spoof-apple --path /Users/kolar/github/vphone-cli --cdhash cdf97f16f9700b76329168e04408e275faa0a524 --cdhash 900c3012d84f1a2fecd5311941b384777add8b9f`。
- 事实：`amfidont/bypass_runtime.py:72` 与 `:124` 使用 `result["path"].startswith(path)` 判定放行；本次构建产物路径 `/Users/kolar/github/vphone-cli/.build/f3/src/.build/...` 以 `--path` 值为前缀。
- 事实：两个二进制 `--help` 均退出 0，未新增 cdhash 注册。
- 推断：因路径前缀匹配命中，本次构建无需重新放行。该结论仅在守护进程保持运行时成立；宿主重启后需按既有流程（`scripts/start_amfidont_for_vphone.sh`）重新启动守护进程，并重新验证 `--help` 退出码。

隔离性（第 7 节“替换正在运行的应用包”风险）：

- 事实：主工作树 `.build/vphone-cli.app/Contents/MacOS/vphone-cli` 与 `.build/vphoned.signed` 的修改时间仍为 2026-09-17 14:29，未被本次构建改写。
- 事实：`vm-2607` 的 vphone-cli 进程 41303 仍在运行，使用主工作树的 `.build/vphone-cli.app`。

### 10.3 顺序 3：d4-acc GUI 启动与客户机状态固定（2026-09-18，已完成）

启动命令（E1、E4、E5 与 E2 的 `--launch-command` 统一使用该形式）：

```
.build/f3/src/.build/vphone-cli.app/Contents/MacOS/vphone-cli \
  --config .build/d4acc/lib/d4-acc/config.plist \
  --vphoned-bin .build/f3/src/.build/vphoned.signed
```

`--vphoned-bin` 是必需项，依据见下。stdout/stderr 重定向到 `.build/f3/logs/d4acc-gui-<UTC>.log`。

| 项目 | 值 |
| --- | --- |
| 本轮启动 | 01:45:49Z，宿主进程 pid 83586；`vphone.sock` 出现 |
| 新增 VZ XPC 进程 | 首次启动 79169、79171；重启后需按 3.3 重新采集（启动前集合为 `vm-2607` 的 41311、41316） |
| `capabilities` | `guest_connected=true`、`screen_available=true`、`boot_mode=normal` |
| `limits` | `command_timeout_ms=180000`、`request_bytes=2097152`、`inline_file_bytes=1048576`、`host_file_bytes=67108864`、`connections=16` |
| 电源 | 交流电源，电量 100%（2.1 固定项满足） |

客户机 vphoned 部署（决定 10 的前提条件）：

- 事实：以 `--config` 启动时，`--vphoned-bin` 默认值是相对路径 `.vphoned.signed`（`VPhoneCLI.swift:53`），仓库根目录不存在该文件，`VPhoneAppDelegate.swift:124` 的存在性检查因此不设 `control.guestBinaryURL`，握手不携带哈希，客户机守护进程不更新。只有 `vm launch` 调用 `stageVphoned`（`VPhoneVMLaunchCLI.swift:58`）把构建产物暂存进 bundle。
- 事实：01:39 那次不带 `--vphoned-bin` 的启动，客户机声明 `apps`、`url`，无 `apps_v2`、无 `app_launch`，即 F1 时期的守护进程。
- 事实：01:45 带 `--vphoned-bin` 重启后，客户机声明 `apps_v2` 且不含 `app_launch`、`url`，完整集合为 `apps,apps_v2,clipboard,devmode,file,hid,ipa_install,keychain,location,location_owned,settings,touch,touch_edge,vcam_receipt_v3,vcam_status`。
- 这是决定 10 要求的 `5fd007c` 部署后观察：regular 客户机无 uiopen，因此不声明 `app_launch` 与 `url`，与提交描述一致。dev/less 变体本轮未观察。

客户机状态固定项（2.4）：

| 项目 | 结果 |
| --- | --- |
| 自动锁定 | 观察值已是“永不”（01:41 截图，设置 → 显示与亮度）。本轮未修改，因此结束时无需恢复。该值何时设定，未查明 |
| 解锁 | 重启后停在锁屏。注入路径 4 次尝试均未解锁：swipe (645,2100)→(645,900)、(645,2500)→(645,1200) ms=400、(645,2790)→(645,1500) ms=700，以及 `key home`；`key power` 可唤醒屏幕（锁屏下约 30 秒休眠，休眠期间截图返回静止帧）。由用户在 GUI 窗口手动解锁后恢复。推断：与既有记录一致，SpringBoard 系统手势（Home、解锁）不响应该注入路径，应用内点击与滚动正常；原因未查明 |
| 前台应用 | “设置”根页面，滚动在顶部（大标题可见）。经主屏幕图标 (496,1957) 打开；打开前以 (422,1575) 关闭“完成 iPhone 设置”弹窗的“以后”按钮 |

tap/swipe 坐标（像素，屏幕 1290×2796）：

| 用途 | 坐标 | 验证 |
| --- | --- | --- |
| 非交互 tap | (643, 1084)，两组卡片之间的空隙 | 连续 5 次 tap 后截图与操作前逐字节相同 |
| 列表内上下交替 swipe | (643, 1957) ↔ (643, 1258)，`ms=300` | 3 组上下滑动后截图与操作前逐字节相同；不触发导航 |
| 返回根页面（准备用） | (126, 243) 为二级页面返回按钮 | 从“显示与亮度”返回根页面成功 |

事实：宿主 stdout 日志中 Swift `print` 的 `[control]` 行按块缓冲，串口输出实时写入，因此启动日志不能用于判断客户机连接时刻；状态经 `vphone.sock` 的 `capabilities` 判定（3.2 的轮询方法已按此设计）。

### 10.4 顺序 4：E0 与 E1（2026-09-18，已完成）

证据目录（`research/artifacts` 被 Git 忽略，本节保留数值）：

| 内容 | 路径 |
| --- | --- |
| E0 前置 | `research/artifacts/f3-baseline/E0-20260918T020202Z/`：`doctor-host.json`、`doctor-d4acc.json`（均只有 SIP warning，退出码 3）、`host.txt`、`processes.txt`、`cdhash.txt`、`sha256.txt`、`guest-state.png`、`capabilities.json` |
| E1 样本与汇总 | `research/artifacts/f3-baseline/E1-20260918T020303Z/`：`run.json`、`samples/latency.jsonl`、`host_samples.jsonl`、`summary/summary.{json,md}` |
| E1 宿主采样 | `research/artifacts/f3-baseline/E1-20260918T020303Z-host/` |

实验设置：运行 id `f3-latency-20260918T020330Z-52dca2`；02:03:30Z–02:04:22Z；构建 `0d7b009`（工具提交 `2011bc7`，工作树干净）；d4-acc GUI、`cpuCount=8`、8 GiB；与 `vm-2607` 共存；交流电源、电量 100%；运行期间另起 `caffeinate -dimsu`；`scripts/f3_host_sampler.py` 并行采样 6 个进程、bundle 磁盘与启动日志大小；tap (643,1084)、swipe (643,1957)↔(643,1258)。

结果：4036 次请求，0 次失败，`failures_by_code` 为空。实际耗时 52 秒；第 4 节对 E1 的“约 40 分钟”是未测估计，本轮实测远低于该值（64 MiB 传输约 100 毫秒量级，见下表）。

跳过的命令类（事实，来自 `counts.skipped`）：

| 命令类 | 原因 |
| --- | --- |
| `shell` | 客户机未声明 `shell` 能力（regular 变体） |
| `app_lifecycle` | `app_launch` 不可用；这是 `5fd007c` 在无 uiopen 的 regular 客户机上的预期结果 |

命令延迟（毫秒，串行并发 1，每类预热 10 次不计入；p50/p99 区间为 2000 次 bootstrap 的 95% 区间；样本数 < 100 不报 p99）：

| 命令类 | 样本数 | p50 | p90 | p99 | p50 区间 | 最小 | 最大 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `capabilities` | 500 | 0.091 | 0.192 | 0.303 | [0.086, 0.098] | 0.064 | 0.463 |
| `location_source_status` | 500 | 0.080 | 0.167 | 0.269 | [0.073, 0.084] | 0.054 | 0.339 |
| `tap:noscreen` | 200 | 0.143 | 0.212 | 0.276 | [0.131, 0.159] | 0.083 | 0.303 |
| `swipe:noscreen` | 200 | 0.164 | 0.210 | 0.313 | [0.148, 0.172] | 0.101 | 0.314 |
| `file_get:1k` | 200 | 0.399 | 0.568 | 0.763 | [0.385, 0.429] | 0.233 | 1.002 |
| `location_source_stop` | 100 | 0.428 | 0.629 | 0.860 | [0.401, 0.453] | 0.299 | 0.868 |
| `file_get:64k` | 200 | 0.814 | 1.086 | 1.375 | [0.785, 0.839] | 0.552 | 1.525 |
| `file_put:1k` | 200 | 0.940 | 1.148 | 1.802 | [0.914, 0.963] | 0.547 | 16.135 |
| `location_source_set` | 100 | 0.946 | 1.272 | 1.501 | [0.915, 1.010] | 0.594 | 1.720 |
| `file_put:64k` | 200 | 1.196 | 1.436 | 1.838 | [1.174, 1.222] | 0.825 | 17.094 |
| `file_put:1m` | 200 | 5.474 | 6.248 | 20.252 | [5.395, 5.537] | 4.737 | 23.713 |
| `file_get:1m` | 200 | 5.826 | 6.447 | 7.467 | [5.728, 5.876] | 5.006 | 7.627 |
| `tap:screen` | 100 | 14.533 | 15.183 | 19.661 | [14.492, 14.589] | 13.836 | 21.337 |
| `file_get:save16m` | 30 | 20.269 | 22.779 | — | [19.486, 20.615] | 18.882 | 33.614 |
| `screenshot:color` | 200 | 24.829 | 26.075 | 30.306 | [24.737, 24.959] | 23.299 | 37.723 |
| `file_put:load16m` | 30 | 26.560 | 31.912 | — | [25.911, 28.049] | 23.368 | 59.864 |
| `screenshot:gray` | 200 | 33.429 | 35.353 | 44.478 | [33.335, 33.539] | 31.086 | 45.492 |
| `app_list:running` | 200 | 53.189 | 56.034 | 60.989 | [52.928, 53.397] | 49.922 | 65.832 |
| `app_list:all` | 200 | 56.420 | 58.892 | 65.992 | [56.254, 56.601] | 53.224 | 87.563 |
| `file_get:save64m` | 30 | 75.294 | 82.774 | — | [73.426, 77.116] | 70.196 | 88.968 |
| `file_put:load64m` | 30 | 107.901 | 111.559 | — | [104.921, 109.208] | 96.178 | 113.737 |

观察：

- 事实：`screenshot:gray` 的 p50 为 33.429 毫秒，`screenshot:color` 为 24.829 毫秒，两者 p50 的 95% 区间不重叠（[33.335, 33.539] 与 [24.737, 24.959]），即默认的紧凑灰度路径比 sRGB 彩色路径慢约 8.6 毫秒。`VPhoneHostScreenAdapter.captureCompactScreenshot` 的注释把灰度路径描述为“small + fast”。原因未查明；需要分解捕获、转换与编码各段耗时才能定位。这是单次运行的结果，尚未按 3.6 的两次独立运行规则确认。
- 事实：`app_list` 是最慢的非文件命令（p50 53–56 毫秒），`filter=all` 比 `filter=running` 高约 3 毫秒。
- 事实：64 MiB 传输 `file_put:load64m` p50 107.9 毫秒、`file_get:save64m` p50 75.3 毫秒；1 MiB 内联两个方向均约 5.5–5.8 毫秒。
- 事实：`file_put` 的 1 KiB、64 KiB、1 MiB 三类最大值（16.1、17.1、23.7 毫秒）远高于各自 p90，`file_get` 无同类尖峰。尖峰来源未查明。

共存协变量（采样窗口 100 秒，CPU 以累计 CPU 时间差除以墙钟计算）：

| 进程 | cpu_cores | RSS（末次） | footprint（末次） |
| --- | --- | --- | --- |
| d4-acc vphone-cli 83586 | 0.25 | 166.5 MiB | 1863 MiB |
| d4-acc VZ 83588 | 0.68 | 10804.5 MiB | 8374 MiB |
| d4-acc VZ 83590 | 0.00 | 24.6 MiB | 12 MiB |
| `vm-2607` vphone-cli 41303 | 0.00 | 117.1 MiB | 382 MiB |
| `vm-2607` VZ 41311 | 0.10 | 4798.8 MiB | 8267 MiB |
| `vm-2607` VZ 41316 | 0.00 | 9.5 MiB | 12 MiB |

推断：E1 期间 `vm-2607` 的 CPU 占用为 0.10 核，属低背景负载；不能据此排除其对分位数尾部的影响。两台 VM 的 VZ 进程均为“一大一小”，与 1.2 的记录一致；两者的角色划分仍未确认。

事实：`summarize` 报告“all host samples fall inside the 600s warm-up”，即 E1 时长不足以构建 3.6 的资源序列。资源增长判定属于 E4、E5a、E5b、E6c。

E1 实验设置缺陷（2026-09-18 02:08 发现）：

- 事实：E1 结束后截图显示客户机停在“设置 → Wi-Fi”子页面，不是 2.4 要求的“设置”根页面。
- 事实：坐标 (643,1084) 只在列表滚动到顶部时落在两组卡片之间的空隙；10.3 的验证是在顶部位置做的。E1 按 3.1 将各命令类按轮次交替执行，其中的 `swipe` 改变滚动位置，`tap` 因此会落到列表行上并触发导航。
- 影响：E1 期间前台页面不是固定的，`screenshot` 各样本的画面内容随之变化；`tap` 的“固定非交互坐标”条件未满足。`tap:noscreen` 的延迟只计量注入调用返回（1.5 的事实），`capabilities`、`location_source_*`、`file_*` 不依赖前台页面，这些类的数值不受影响；`screenshot:gray` 与 `screenshot:color` 按轮次交替执行，两类看到的画面分布相近，但两者差值仍可能含画面内容差异，不能完全排除。
- 结论：10.4 的 `screenshot` 与 `tap:screen` 数值按“前台页面未固定”条件解读；灰度慢于彩色的观察需要在固定页面下复跑确认。
- 复跑前需要的改动：改用在任意滚动位置都落在卡片外的 tap 坐标（例如卡片左侧留白 x≈33，待验证），或在每次 `tap` 前把列表复位到顶部。尚未实施。

事实：客户机时钟在本次会话中从 18:5x 变为与宿主本地时间一致（10:08）。原因未查明。客户机时间戳因此在本次会话内不连续，跨时刻比较客户机时钟的分析不适用。

坐标修正（2026-09-18 03:15，提交 `799d168`）：`--tap-x` 默认值由 640 改为 33（卡片左边界为 x=67，x=33 落在左侧留白）。在 d4-acc“设置”根页面的顶部、中部与列表底部各连续 5 次 `tap`，截图逐字节不变（底部一次首测因状态栏分钟跳变产生差异，缩短时间窗后复测逐字节相同）。`make test_python` 325 项通过。E1 未按新坐标复跑。

### 10.5 E5a：空闲（无定位源）（2026-09-18，已完成）

实验设置：02:09:52Z–03:10Z，60 分钟；d4-acc GUI，前台为“设置”根页面顶部，运行期间不注入任何触摸；`location_source_status` 开始时为 `off`；每 60 秒一次 `capabilities` 探活；与 `vm-2607` 共存；宿主采样器同窗口运行。证据目录 `research/artifacts/f3-baseline/E5a-20260918T020952Z/`（宿主采样 5400 条）。

结果：61 次请求，0 失败。资源序列按 3.6 排除启动后前 10 分钟。

被测 VM 的指标：

| 指标 | Theil–Sen 斜率（每小时） | 95% 区间 | 首值 | 末值 | 判定 |
| --- | --- | --- | --- | --- | --- |
| `Disk.img` 实际占用 | +10.462 MiB | [8.836, 11.688] | 21116.4 MiB | 21341.5 MiB | 增长候选 |
| `nvram.bin`、`SEPStorage` 实际占用 | 0.000 | [0, 0] | 27.012 / 0.5 MiB | 同 | 未检出 |
| vphone-cli footprint | 0.000 | [0, 0] | 73 MiB | 74 MiB | 未检出 |
| vphone-cli RSS | −0.072 MiB | [−0.163, 0] | 125.4 MiB | 121.1 MiB | 未检出 |
| vphone-cli CPU | 0.000 核 | [0, 0] | 0.000 | 0.000 | 未检出 |
| VZ 83588 footprint | 0.000 | [0, 0] | 8290 MiB | 8290 MiB | 未检出 |
| VZ 83588 RSS | +28.123 MiB | [13.013, 35.202] | 10846.4 MiB | 10058.9 MiB | 增长候选 |
| VZ 83588 CPU | 0.000 核 | [−0.000, 0.000] | 0.026 | 0.016 | 未检出 |
| VZ 83590（小进程） | 0.000（footprint、RSS、CPU） | [0, 0] | 12 MiB / 18.1 MiB | 同量级 | 未检出 |
| `boot.log` 大小 | +124.381 KiB | [122.515, 125.936] | 213.9 KiB | 319.8 KiB | 增长候选 |

VZ 83588 的 RSS 序列（每 5 分钟取值）：t+0 10807.8 → t+10 10846.4 → t+15 10477.4 → t+20 10025.7 → t+60 10058.3 MiB。事实：分析窗口内含一次约 800 MiB 的单次下降（t+10 到 t+20），其后 40 分钟从 10025.7 升到 10058.3 MiB。因此 +28.1 MiB/h 的斜率不能解释为稳定增长速率；同一进程的 footprint（3.3 指定的主指标）斜率为 0。

宿主与共存 VM（背景记录，非被测对象）：

| 指标 | 斜率（每小时） | 区间 | 判定 |
| --- | --- | --- | --- |
| `vm-2607` vphone-cli footprint | +5.714 MiB | [5.079, 6.087] | 增长候选 |
| `vm-2607` vphone-cli RSS | +5.201 MiB | [4.498, 5.798] | 增长候选 |
| `vm-2607` VZ 41311 RSS | +57.128 MiB | [32.446, 81.998] | 增长候选 |
| 宿主 swapins | +153.334 次 | [137.534, 167.467] | 增长候选 |
| 宿主 swapouts、swap 已用字节 | 0 | [0, 0] | 未检出 |
| 数据卷可用空间 | −37.476 MiB | [−74.575, −1.242] | 未检出（方向为减少） |

说明：

- `boot.log` 的线性增长是持续写入的预期结果（3.7），不等同内存缓冲增长。
- `Disk.img` 在完全空闲、无客户机写入负载的条件下仍以约 10 MiB/小时增长，来源未查明。按 3.6 规则需要同一设置的第二次独立运行才能记为“测量确认的增长”。
- `vm-2607` 的三项增长候选属于共存 VM 的自身负载，不是被测对象的结果；列出用于说明共存条件。

### 10.6 E5b：空闲（固定定位源，heartbeat 1 秒）（2026-09-18，已完成）

实验设置：03:17:43Z–04:17:43Z，60 分钟；与 E5a 同一次启动、同一前台页面、同一采样配置，区别是全程持有固定定位源（`latitude=31.2304`、`longitude=121.4737`、`heartbeat_s=1.0`）。证据目录 `research/artifacts/f3-baseline/E5b-20260918T031732Z/`（宿主采样 5393 条）。

结果：63 次请求，0 失败。`counts.skipped` 记录客户机日志大小未采样（regular 无 `shell`，无法读取 `/var/jb/...` 路径），与 1.6 的预期一致。

被测 VM 的指标：

| 指标 | 斜率（每小时） | 95% 区间 | 首值 | 末值 | 判定 |
| --- | --- | --- | --- | --- | --- |
| `Disk.img` 实际占用 | +0.469 MiB | [−2.695, 4.687] | 21345.3 MiB | 21347.1 MiB | 未检出 |
| `nvram.bin`、`SEPStorage` | 0.000 | [0, 0] | 27.012 / 0.5 MiB | 同 | 未检出 |
| vphone-cli footprint | 0.000 | [0, 0] | 75 MiB | 75 MiB | 未检出 |
| vphone-cli RSS | +0.640 MiB | [0.594, 0.684] | 126.8 MiB | 113.5 MiB | 增长候选 |
| vphone-cli CPU | −0.000 核 | [0, 0] | 0.002 | 0.000 | 未检出 |
| VZ 83588 footprint | 0.000 | [0, 0] | 8290 MiB | 8290 MiB | 未检出 |
| VZ 83588 RSS | +30.688 MiB | [20.880, 37.620] | 10060.5 MiB | 10083.3 MiB | 增长候选 |
| VZ 83588 CPU | 0.000 核 | [−0.000, 0.000] | 0.032 | 0.024 | 未检出 |
| VZ 83590（小进程） | 0.000 | [0, 0] | 12 MiB / 17.1 MiB | 同 | 未检出 |
| `boot.log` 大小 | +128.228 KiB | [126.508, 129.557] | 356.4 KiB | 462.6 KiB | 增长候选 |

宿主与共存 VM：swapins +90.909 次/小时 [72.722, 105.550]（候选）；swapouts 与 swap 已用字节为 0；数据卷可用空间 −14.141 MiB/小时 [−52.580, 15.505]（未检出）；`vm-2607` vphone-cli footprint +5.000 MiB/小时、RSS +5.123 MiB/小时、VZ 41311 RSS +131.125 MiB/小时（均为候选，属共存 VM 自身负载）。

E5a 与 E5b 的比较（两者实验条件不同，不构成 3.6 要求的“同一设置第二次运行”）：

| 指标 | E5a | E5b | 说明 |
| --- | --- | --- | --- |
| `Disk.img` | +10.462 MiB/h，候选 | +0.469 MiB/h，未检出 | E5a 的磁盘增长未在 E5b 复现。E5a 紧接冷启动与 E1 负载之后，E5b 在系统稳定约 70 分钟后开始。待验证假设：E5a 的增长来自启动后的一次性后台活动，而非持续增长。区分需要在同一设置下复跑 E5a |
| VZ RSS | +28.123 MiB/h，候选（窗口含一次 800 MiB 下降） | +30.688 MiB/h，候选（首末单调上升 +22.8 MiB） | 两轮方向一致、量级相近 |
| VZ footprint | 0 | 0 | 恒为 8290 MiB。推断：该值受 8 GiB 客户机内存分配主导，对数十 MiB 级变化不敏感；3.3 以 footprint 为主指标的设定在 VZ 进程上因此可能漏检 RSS 反映的变化 |
| vphone-cli footprint | 0（73→74 MiB） | 0（75 MiB 恒定） | 未检出 |
| `boot.log` | +124.381 KiB/h | +128.228 KiB/h | 持续写入的预期结果 |

定位源持有一小时（heartbeat 1 秒）未使被测进程的 footprint 或 CPU 出现可检出的增长。

### 10.7 E4 前的冷启动隔离（2026-09-18）

- `vm stop d4-acc` 成功；停机后宿主只剩 `vm-2607` 的 VZ 进程 41311、41316。
- 04:21:33Z 以 10.3 的启动命令冷启动；客户机在 t+10 秒内 `guest_connected=true`、`screen_available=true`；能力集合与 10.3 相同（含 `apps_v2`）。
- 新 PID：vphone-cli 64240，VZ 64243、64245（按 3.3 以启动前后集合差归属被测 VM）。
- 客户机停在锁屏（截图 11:57），需人工解锁后才能执行含 `screenshot` 的 E4。
- 用户手动解锁后，经主屏幕图标打开“设置”并滚动复位到顶部；在该页面复核新坐标 x=33 连续 5 次 `tap`，除状态栏分钟跳变外画面无变化。

事实：客户机时钟在冷启动后为 11:57，约 10 分钟后显示 13:02，与宿主本地时间的偏差在本次会话内多次变化。原因未查明。所有延迟测量使用宿主单调时钟（3.1），不受此影响。

### 10.8 E4：固定时长重复负载（2026-09-18，已完成）

实验设置：05:04:01Z–06:09:04Z；负载段 3601.7 秒共 1797 组，每组 `capabilities`、`location_source_status`、`app_list running`、`file_put`/`file_get` 64 KiB（写后读回比对 SHA-256）、`screenshot`（`screen=false`，写入单个覆盖文件）；每 10 分钟一次 `location_source_set`/`stop`（各 6 次）；其后 5 分钟空闲尾部，5 次 `capabilities` 探测。冷启动隔离后的新实例（cli 64240、VZ 64243/64245），与 `vm-2607` 共存。证据目录 `research/artifacts/f3-baseline/E4-20260918T050350Z/`。

结果：10801 次请求，0 失败；`file_get` 的 SHA-256 校验全部通过。客户机日志大小未采样（regular 无 `shell`）。

命令延迟（毫秒）与 E1 的对照：

| 命令类 | E4 样本数 | E4 p50 | E4 p90 | E4 p99 | E1 p50 | E4/E1 p50 |
| --- | --- | --- | --- | --- | --- | --- |
| `capabilities` | 1797 | 0.792 | 0.894 | 1.116 | 0.091 | 8.7× |
| `location_source_status` | 1797 | 0.327 | 0.410 | 0.568 | 0.080 | 4.1× |
| `file_get:64k` | 1797 | 0.706 | 0.762 | 1.132 | 0.814 | 0.87× |
| `file_put:64k` | 1797 | 1.331 | 1.420 | 1.814 | 1.196 | 1.11× |
| `screenshot:gray` | 1797 | 38.873 | 40.147 | 48.189 | 33.429 | 1.16× |
| `app_list:running` | 1797 | 75.546 | 76.807 | 78.319 | 53.189 | 1.42× |

限制：E1 与 E4 是不同的启动会话（E4 在冷启动隔离之后），两者的差异不能单独归因于负载。

资源时间序列（排除启动后前 10 分钟）：

| 指标 | 斜率（每小时） | 95% 区间 | 首值 | 末值 | 判定 |
| --- | --- | --- | --- | --- | --- |
| `Disk.img` 实际占用 | +19.323 MiB | [17.451, 21.392] | 21365.6 MiB | 21384.1 MiB | 增长候选 |
| vphone-cli footprint | +5.714 MiB | [5.179, 6.071] | 40 MiB | 30 MiB | 增长候选 |
| vphone-cli RSS | +5.870 MiB | [5.796, 5.931] | 107.7 MiB | 98.2 MiB | 增长候选 |
| vphone-cli CPU | −0.001 核 | [−0.001, 0.000] | 0.018 | 0.000 | 未检出 |
| VZ 64243 footprint | +5.714 MiB | [−0.719, 16.514] | 8241 MiB | 8257 MiB | 未检出 |
| VZ 64243 RSS | +110.451 MiB | [87.070, 129.521] | 9285.4 MiB | 9596.8 MiB | 增长候选 |
| VZ 64243 CPU | −0.013 核 | [−0.026, −0.001] | 0.060 | 0.016 | 方向为下降 |
| VZ 64245（小进程） | 0.000 | [0, 0] | 12 MiB / 17.7 MiB | 同 | 未检出 |
| `boot.log` 大小 | +346.976 KiB | [345.766, 348.194] | 223.2 KiB | 525.3 KiB | 增长候选 |
| 宿主 swapins | +282.665 次 | [262.337, 300.219] | 61737 | 61985 | 增长候选 |
| 宿主 swapouts、swap 已用字节 | 0 | [0, 0] | — | — | 未检出 |
| 数据卷可用空间 | −38.827 MiB | [−50.935, −27.443] | 204463.3 MiB | 204428.1 MiB | 未检出（方向为减少） |

方法限制：本轮的分析窗口包含末尾 5 分钟空闲尾部，3.6 只规定排除启动后前 10 分钟、未规定排除尾部。负载结束使 CPU 与部分内存指标下行，`cpu_cores` 的负斜率与 footprint、RSS 首值大于末值都受此影响，斜率不能按“负载期稳定速率”解读。复跑时应将尾部排除在斜率估计之外。

3.7 的间接证据（负载结束后 5 分钟空闲期）：

- 事实：vphone-cli 的 footprint 在负载期末为 45 MiB，尾部两次采样降至 30 MiB，即负载结束后回落。
- 事实：尾部 5 次 `capabilities` 探测为 0.389、0.660、0.875、0.726、0.595 毫秒，未回到 E1 的 p50 0.091 毫秒。由于 E1 与 E4 是不同启动会话，该差异不能判定为负载残留；来源未查明。
- 事实：负载期与尾部均无 `command_timeout` 或 `command_busy`（`failures_by_code` 为空）。

`Disk.img` 增长的三轮对照（条件不同，不构成同一设置的复跑）：E5a 空闲 +10.462 MiB/h（候选）、E5b 空闲 +0.469 MiB/h（未检出）、E4 负载 +19.323 MiB/h（候选）。E4 每组写入并读回同一个 64 KiB 路径，按 3.4 的推断，客户机覆盖写不必然使 `st_blocks` 增长；本轮观察到的增长来源未查明。

补记（2026-09-18 07:00，提交 `96d5857`）：工具已实现尾段排除。以修正后的窗口（05:13:50Z–06:04:03Z，剔除 467 条尾段采样）重新汇总 E4，结果为 `Disk.img` +19.271 MiB/h [17.008, 21.607]、vphone-cli footprint +6.000 MiB/h [5.357, 6.399]（首 40 末 45）、vphone-cli RSS +5.936 [5.844, 6.034]（首 107.7 末 113.0）、VZ RSS +92.535 [75.402, 105.654]、VZ footprint +10.000 [0.000, 24.287]（下限为 0，非候选）、`cpu_cores` 全部为 0.000 且区间跨 0。事实：修正前 VZ 的 `cpu_cores` 斜率为 −0.013 核/小时、区间上限小于 0，修正后归零；该负斜率来自尾段。本节上方表格保留修正前的数值以对照。

### 10.9 E1 与 E5a 复跑（2026-09-18，已完成）

目的：为 3.6 规则提供 E5a 的同一设置第二次运行，并用修正后的 tap 坐标复跑 E1。

时序对齐：06:48:55Z 冷启动（cli 28876、VZ 28878/28880）；用户手动解锁；恢复“设置”根页面顶部；T+17 分钟（07:05:54Z）跑 E1 复跑；T+24 分钟（07:12:45Z）起 E5a 复跑 60 分钟。原 E5a 的前置时序为同一形式（冷启动 → E1 → T+24 分钟起空闲）。

事实：3.6 的“同一实验设置”未把“距冷启动的时间”列为固定项，本轮特意对齐该项。

#### E1 复跑

4036 次请求，0 失败。与 E1 的对照（毫秒，p50）：

| 命令类 | E1 | E1 复跑 |
| --- | --- | --- |
| `capabilities` | 0.091 | 0.100 |
| `tap:noscreen` | 0.143 | 0.124 |
| `swipe:noscreen` | 0.164 | 0.142 |
| `tap:screen` | 14.533 | 14.308 |
| `screenshot:color` | 24.829 | 25.372 |
| `screenshot:gray` | 33.429 | 33.934 |
| `app_list:running` | 53.189 | 51.623 |
| `app_list:all` | 56.420 | 54.835 |

- 灰度截图慢于彩色截图在第二次独立运行中复现（33.934 与 25.372，两者 p50 区间 [33.488, 34.249] 与 [25.200, 25.637] 不重叠）。两轮的前台页面都未固定（见下），因此该差值仍不能完全排除画面内容差异。
- 事实：两个不同启动会话的空载 `capabilities` p50 分别为 0.091 与 0.100 毫秒，E4 负载期为 0.792 毫秒。推断：10.8 中“差异可能来自启动会话”的解释因此支持减弱，与负载相关的解释更受支持；E4 尾部 5 分钟未回到 0.1 毫秒的现象仍未解释。

坐标修正未解决前台页面漂移（事实）：复跑结束时客户机位于“设置 → 通用 → 隔空投送”，并有一个模态对话框，比 E1 结束时的位置更深。已知事实：复跑开始前截图确认在根页面顶部；坐标 (33,1400) 在根页面顶部、中部、列表底部各 5 次低速点击（间隔 0.2–0.4 秒）画面逐字节不变；E1 在 52 秒内发出 4036 次请求，其中 `tap:noscreen` 200 次、`tap:screen` 100 次、`swipe:noscreen` 200 次按轮次交替、几乎无间隔。到达“隔空投送”并触发对话框至少需要三次落在行上的点击。原因未查明。待验证假设：高速连发的注入，或注入与滚动动画重叠，使点击落点与低速验证时不同；验证方式为先单独高速重放 `tap`（不含 swipe），再加入交错的 swipe。在结论出来前，E1 与 E1 复跑的 `screenshot`、`tap:screen` 数值按“前台页面未固定”解读。

#### E5a 复跑与 3.6 判定

61 次请求，0 失败。分析窗口 07:22:55Z–08:17:30Z（无负载阶段，仅排除预热）。

| 指标 | E5a | E5a 复跑 | 两次判定 |
| --- | --- | --- | --- |
| `Disk.img` 实际占用 | +10.462 MiB/h [8.836, 11.688] | +11.250 MiB/h [10.464, 11.941] | **测量确认的增长** |
| `boot.log` 大小 | +124.381 KiB/h [122.515, 125.936] | +123.077 KiB/h [122.526, 123.689] | 测量确认的增长（持续写入的预期结果） |
| vphone-cli footprint | 0.000 [0, 0] | +5.455 MiB/h [3.091, 7.013] | 候选（仅一次） |
| vphone-cli RSS | −0.072 [−0.163, 0] | −104.033 [−139.544, −54.385] | 未检出 |
| VZ footprint | 0.000 [0, 0] | 0.000 [0, 0] | 未检出 |
| VZ RSS | +28.123 [13.013, 35.202] | −1876.558 [−2432.143, −1160.611] | 候选（方向相反） |
| vphone-cli、VZ CPU | 0.000 | 0.000 | 未检出 |

结论：

1. **`Disk.img` 在空闲条件下的增长为“测量确认的增长”**（3.6 规则第 2 项）：两次独立运行的 95% 区间下限均大于 0 且斜率同号，约 10–12 MiB/小时。该结果绑定“冷启动后约 24 分钟开始的 60 分钟空闲窗口”这一设置。按 3.6 规则第 3 项，它进入优化候选评估；来源未查明，定位需要进一步实验（例如按客户机写入路径分解增长）。
2. E5b（同一次启动约 90 分钟后、持有定位源）未检出该增长。两个候选因素——距冷启动的时间与定位源——本轮无法区分，需要单变量实验。
3. VZ 进程 RSS 三轮方向不一致（E5a +28、E5b +31、E5a 复跑 −1877 MiB/h），序列由大幅阶跃主导，该指标不适合用斜率判定持续增长。同一进程的 footprint 三轮恒为 8290 MiB。
4. 宿主 swapins 与 `vm-2607` 的 footprint/RSS 也达到“确认”，属宿主与共存 VM 的背景负载，不是被测对象的结果。

建议（需用户决定）：把“距冷启动的时间”补入第 2 节固定项；`Disk.img` 增长的定位实验与指标口径调整（VZ 进程改以 RSS 为主指标或增加更细的内存口径）列入 F3 之后的候选改动。

### 10.10 前台页面漂移的排查（2026-09-18，原因已查明）

现象：E1 与 E1 复跑结束后，客户机都从“设置”根页面移动到了子页面（分别为 Wi-Fi、通用 → 隔空投送），两次均需人工或脚本恢复。

代码事实（`sources/vphone-cli/VPhoneVirtualMachineView.swift`）：注入不串行化。

- `injectTap`（第 196 行）立即发出 `mouseDown`，用 `DispatchQueue.main.asyncAfter` 把 `mouseUp` 排在 80 毫秒后。
- `injectSwipe`（第 212 行）立即发出 `mouseDown`，把 `steps = max(10, durationMs/16)` 个 `mouseDragged` 与最后的 `mouseUp` 按 `stepInterval` 排在主队列上，`ms=300` 时为 18 步、间隔约 16.7 毫秒。
- `screen=false` 时宿主命令在注入调用返回后即应答（1.5 的事实，实测 `tap` p50 0.14 毫秒），因此下一条请求的 `mouseDown` 可以在上一条手势的后续事件发出之前进入。

对照实验（每次从截图验证过的“设置”根页面开始；导航判定为裁剪导航栏左上角区域后比对哈希，根页面无返回按钮）：

| 实验 | 刺激 | 结果 |
| --- | --- | --- |
| A | 200 次连发 `tap` (33,1400)，0.03 秒内发完 | 未导航 |
| C | 200 次连发 `swipe`，0.03 秒内发完 | 导航到“通用 → 隔空投送” |
| C 复现 | 同 C，两次 | 两次均未导航 |
| E | 10 次 `swipe`，间隔 2 秒 | 未导航 |
| 间隔扫描 | 各 20 次 `swipe`，间隔 1.0/0.7/0.4/0.2 秒 | 四组均未导航 |
| 分批 | 200 次连发 `swipe`，每 20 次停 2.5 秒 | 未导航 |
| 混合 | 150 轮 `swipe` + 内联 `screenshot` + `tap`，2.3 秒内 450 次请求，两次 | 两次均未导航 |
| 大文件 | 40 轮 `swipe` + 64 MiB `file_put` + `tap`，4 秒，两次 | 两次均未导航 |
| E1 完整负载 | 4036 次请求 / 52 秒 | 两次运行均导航 |

结论：

- 事实：只有 E1 的完整负载稳定复现（2/2）。单独的 `tap` 连发、`swipe` 连发、`swipe`+截图、`swipe`+大文件传输在本轮均未复现；`swipe` 连发仅第一次出现、两次复现失败。
- 原因未查明。注入不串行化是代码层面的事实，但本轮实验未能用重叠注入单独触发该现象，因此“重叠注入导致误触”仍是待验证假设。
- 事实：实验 C 期间客户机的“隔空投送”设置由“仅限联系人”变为“接收关闭”。该改动由排查实验造成，未恢复（恢复操作会触发 iCloud 登录提示，原值未必能写回）。
- 对已有数据的影响不变：E1 与 E1 复跑的 `screenshot`、`tap:screen` 按“前台页面未固定”解读；`capabilities`、`location_source_*`、`file_*`、`app_list` 与 `tap:noscreen`、`swipe:noscreen` 不依赖前台页面。

#### 事件流日志与结论（2026-09-18 09:10）

工具：`VPHONE_TOUCH_LOG=1` 开启的注入与路由事件日志（提交 `0239cf2`）。诊断构建 `.build/f3diag/src`（HEAD `0239cf2`，含日志代码），与测量构建 `0d7b009` 不同，本轮延迟数值不进基线。09:08:26Z 冷启动、人工解锁、恢复“设置”根页面顶部后跑一次完整 E1：4036 次请求，0 失败，结束时客户机位于“通用 → 隔空投送”并有模态对话框，即第三次复现（3/3）。日志 9272 行，保存在 `research/artifacts/f3-baseline/E1diag-20260918T091013Z/touchlog.txt`。

代码事实（`sources/vphone-cli/VPhoneTouchRoute.swift`）：`VPhoneTouchRoute` 只保存一个 `active` 目标，按“同一时刻只有一个手势”建模。

```swift
if phase == 0 { active = guestSession.map(Destination.guest) ?? .native }
if case let .guest(session) = active, guestSession != session { active = .discard }
let result = active
if phase == 3 { active = .discard }
```

因此手势 B 的 `down` 会覆盖仍在进行的手势 A 的 `active`；随后任一手势的 `up`（phase 3）把 `active` 置为 `.discard`，另一手势剩余的 move/up 全部被丢弃。注入不串行化（见上）使这种交叉成为常态。

测量结果（本轮 531 个手势）：

| 手势与路由形态 | 数量 |
| --- | --- |
| `tap`：down=guest、up=guest（完整） | 183 |
| `tap`：down=guest、up=discard | 137 |
| `swipe`：down=guest、move 部分 discard、up=discard | 119 |
| `swipe`：down=guest、move 部分 discard、up=guest | 86 |
| `swipe`：全部 guest（完整） | 4 |
| 其他 | 2 |

- 事实：4635 个路由相位中 2102 个为 `discard`（45%）。
- 事实：**257 / 531（48%）的手势把 `down` 送到了客户机，而 `up` 被丢弃**，即客户机侧留下一个未释放的触摸，由客户机自身的会话结束逻辑释放。
- 事实：这些未释放触摸的落点为 (33,1400) 137 次（左侧留白，无控件）与 x=643 的 120 次（y=1258 或 1957，即 swipe 起点，落在列表行上）。

因果链（结论）：注入不串行化 → 手势交叉 → 单槽路由状态被覆盖 → 近半数手势的 move/up 被丢弃 → 客户机侧收到 `down` 后由会话逻辑释放，等效为在 `down` 落点上的一次点击 → swipe 起点落在列表行上时触发导航。这解释了无需任何 `tap` 也能导航（实验 C），以及实验 A（全部落在留白）不导航。

推断（未直接记录）：单独的 swipe 连发多次未复现，可能是列表处于减速滚动时的触摸被 iOS 用于停止滚动而不激活行；E1 的混合负载在手势之间有文件传输与截图造成的间隙，列表更常处于静止，因此误触更容易激活行。

影响范围（超出 F3）：任何以快于手势完成速度下发 `tap`/`swipe` 的自动化都会在客户机侧留下未释放触摸并可能产生非预期激活。本轮已观察到它改动了客户机设置（“隔空投送”在排查与诊断运行中被改动）。

修复方向（需用户决定，尚未实施）：

1. 在视图层串行化手势：新手势等待上一手势的全部排队事件发出后再开始。这是主修复，直接消除交叉。
2. 让 `VPhoneTouchRoute` 按手势跟踪状态而不是单槽。这能防止状态互相覆盖，但客户机的单点触摸传输本身无法表达两个同时手势，因此只能作为第 1 项的补充。
3. 基准侧：`tap` 与 `swipe` 分段执行并在段间留停顿，每段结束校验前台页面。属于绕开问题的测量侧措施。

#### 修复与验证（2026-09-18 09:30，提交 `a6161e2`）

已实施第 1、2 项：

- `VPhoneVirtualMachineView` 用有界 FIFO 串行发射手势：一个手势的全部排队事件发完后才开始下一个。队列上限为 4 个等待中的手势（在途合计 5）；队满时拒绝注入，`tap`/`swipe` 返回 `ok=false`、`code=gesture_busy`，不静默丢弃。被接受手势的时序不变（tap 的 up 在 +80 毫秒，swipe 按 `durationMs` 分 `max(10, durationMs/16)` 步）。
- `VPhoneTouchRoute` 改为按手势保存目标（`GestureID` 为 `.user` 或 `.injected(Int)`），手势结束或目标变为 `.discard` 时删除条目，手势 id 无条件分配。真实鼠标事件走 `.user`，不在调用点特判。
- Swift 测试新增交叉手势与队列上限用例；`swift build` 通过，`run_tests.py swift` 468 项通过。

验证运行（诊断构建 `a6161e2`，`VPHONE_TOUCH_LOG=1`，09:30:12Z 冷启动、人工解锁、恢复“设置”根页面顶部）：

| 项目 | 修复前（`0239cf2`） | 修复后（`a6161e2`） |
| --- | --- | --- |
| 路由相位中 `discard` | 2102 / 4635（45%） | **0 / 2446** |
| `down` 送达客户机而 `up` 被丢弃的手势 | 257 / 531（48%） | **0** |
| E1 结束时的前台页面 | 通用 → 隔空投送（3 次运行均漂移） | 设置根页面（未漂移，仅滚动位置不同） |
| 注入被拒（`gesture_busy`） | 不适用 | 232 次（`tap` 131、`swipe` 101） |

配速对照（`tap` 间隔 150 毫秒、`swipe` 间隔 400 毫秒，各 100 次）：200 次请求全部 `ok`，2085 个路由相位全部为 `guest`，无 `discard`，页面未漂移。

事实：日志中两条“缺少 `up`”的记录经查为日志行被客户机串口输出撕开（同一 stdout 无缓冲写入）与日志切片边界所致，不是丢弃事件。

对基准的影响（需用户决定）：E1 的 500 次手势请求中有 232 次被拒。基准以远高于手势完成速率的速度下发 `tap`/`swipe`（200 次 `tap` 连发需约 16 秒才能放完），修复后这些请求会得到 `gesture_busy` 而不是产生误触。3.1 的手势类因此需要配速（`tap` ≥ 100 毫秒、`swipe` ≥ 350 毫秒）并相应延长 E1 时长，或把 `gesture_busy` 作为一类失败计入并只对被接受的请求统计延迟。本轮未改基准。

事实：本节的验证运行使用诊断构建，与基线构建 `0d7b009` 不同，其延迟数值不进基线。基线数据是否需要用含修复的构建重跑，取决于上一段的基准配速决定。

#### 配速后的 E1 重跑（2026-09-18 09:53，提交 `77524de`）

用户决定给手势类配速（提交 `77524de`，实现见 3.1“手势节流”）。运行条件：构建 `a6161e2`（含手势修复，`VPHONE_TOUCH_LOG` 未设置，避免每事件 print 影响手势延迟）；09:41:23Z 冷启动、人工解锁、恢复“设置”根页面顶部；与 `vm-2607` 共存。证据目录 `research/artifacts/f3-baseline/E1paced-20260918T095353Z/`。

结果：4036 次请求，**0 失败**（修复后未配速时为 232 次 `gesture_busy`）；耗时 2 分 3 秒（未配速时 52 秒）；运行结束时前台仍为“设置”根页面顶部，导航栏区域哈希与运行前一致。

| 命令类 | E1（`0d7b009`） | E1 复跑（`0d7b009`） | E1 配速（`a6161e2`） |
| --- | --- | --- | --- |
| `capabilities` | 0.091 | 0.100 | 0.087 |
| `tap:noscreen` | 0.143 | 0.124 | 0.296 |
| `swipe:noscreen` | 0.164 | 0.142 | 0.289 |
| `tap:screen` | 14.533 | 14.308 | 15.858 |
| `screenshot:color` | 24.829 | 25.372 | 28.808 |
| `screenshot:gray` | 33.429 | 33.934 | 37.504 |

单位为毫秒 p50。说明：

- 事实：`tap:noscreen` 与 `swipe:noscreen` 的 p50 由约 0.13–0.16 毫秒升到约 0.29 毫秒。注入路径在修复后增加了手势入队与按手势的路由状态查找。该增量的具体来源未查明。
- 事实：`screenshot` 两类的 p50 分别升高约 3.4 与 4.1 毫秒（约 12%–16%）。截图路径未被本次修复改动；两次运行的构建与启动会话均不同，差异来源未查明。
- 事实：灰度截图慢于彩色截图在第三次独立运行中仍然成立（37.504 与 28.808）。本轮前台页面固定在“设置”根页面，10.4 中“画面内容差异”的限制在本轮不适用。
- 限制：本轮与 10.4 的基线运行使用不同构建与不同启动会话，逐类比较只作记录，不归因。

基线数据的处理：10.4 的 E1 与 10.9 的 E1 复跑在手势类上测量的是“每次注入都被接受但近半数在客户机侧不完整”的行为，与本轮口径不同，两者的手势类数值不可比较。非手势命令类（`capabilities`、`location_source_*`、`file_*`、`app_list`）不受手势修复影响。E4、E5a、E5b、E5a 复跑不含手势注入，结论不受影响。

下一步：E5a、E5b、E4（各 60 分钟）与 E2，需继续占用宿主专用时段。

### 10.11 `Disk.img` 增长的定位（2026-09-18）

起点：10.9 按 3.6 规则把空闲条件下的 `Disk.img` 增长判为“测量确认的增长”（约 10–12 MiB/小时，两次独立运行）。本节定位其来源。

方法：headless 冷启动（磁盘实验不需要屏幕，因此不需要人工解锁），`Disk.img` 每 5 秒采样一次，覆盖冷启动后 0–85 分钟。另对已有的 E5a、E5b、E4、E5a 复跑的 60 秒采样序列重新按逐点差分检查。

#### 结果：增长不是连续的，而是离散事件

各运行中相邻采样点之间变化不小于 5 MiB 的事件：

| 运行 | 采样跨度 | 净变化 | 阶跃事件（相对该运行起点） |
| --- | --- | --- | --- |
| E5a（冷启动后 24 分钟起） | 60 分钟 | +287.6 MiB | t+9 分 +76 MiB；t+10 分 −15 MiB；t+54 分 +225 MiB |
| E5a 复跑（冷启动后 24 分钟起） | 64 分钟 | +112.3 MiB | t+5 分 +76 MiB；t+59 分 +19 MiB；t+60 分 +8 MiB |
| E5b（同一次启动约 90 分钟后） | 60 分钟 | +4.3 MiB | 无 |
| E4（负载，冷启动后约 42 分钟起） | 65 分钟 | +22.2 MiB | 无 |
| headless 专项（冷启动后 0 分钟起，5 秒采样） | 26 分钟（进行中） | +87.1 MiB | t+19.33 分 +75.5 MiB（发生在单个 5 秒间隔内） |

事实：

- 约 +76 MiB 的事件在三次覆盖“冷启动后 19–33 分钟”窗口的运行中各出现一次（E5a 的 t+9 对应冷启动后约 33 分钟，E5a 复跑的 t+5 对应约 29 分钟，headless 专项为 19 分钟）。5 秒采样显示它发生在单个采样间隔内。
- 除阶跃外，各运行的逐点变化为几 MiB 量级、方向有正有负。
- E5b 与 E4 的窗口不含阶跃，净变化分别为 +4.3 与 +22.2 MiB。
- 事实：停机后 `Disk.img` 的实际占用会下降。连续两次启动前的读数为 21502.4 MiB 与 21443.6 MiB，中间是一次 headless 启动、21 分钟空闲与一次 `vm stop`，净减少 59 MiB。

#### 对 10.9 结论的修正

10.9 记录的“空闲条件下 `Disk.img` 以约 10–12 MiB/小时增长，测量确认”在数值上成立，但把它读作持续增长是错误的：该斜率来自窗口内一到两次离散分配事件，不是稳定速率。3.6 的判定规则（两次独立运行区间下限均大于 0 且同号）不能区分阶跃与趋势——一次落在窗口中部的阶跃同样会给出下限大于 0 的斜率区间。

由此，E5a 与 E5b 的差异不需要“定位源”或其他解释：E5a 的窗口包含冷启动后的阶跃，E5b 的窗口不包含。10.6 中列为待区分的两个因素（距冷启动的时间、定位源）中，前者是实际起作用的那个。

#### 未查明与下一步

- 写入这约 76 MiB 的是什么，未查明。区分“客户机写入”与“宿主侧稀疏文件分配”需要读取客户机文件系统用量，regular 客户机无 `shell`，本机做不到；需要带 shell 的 jb/exp 客户机。
- E5a 中 t+54 分的 +225 MiB 事件在 E5a 复跑中未出现（该处为 +19 与 +8 MiB），是否可复现未确定。headless 专项覆盖到冷启动后 85 分钟，用于观察第二次事件。
- 3.6 的判定规则需要补充阶跃检测：在判定“持续增长”前先检查序列是否由少数离散跳变主导。本节的逐点差分即为可用方法。该改动尚未实施。
