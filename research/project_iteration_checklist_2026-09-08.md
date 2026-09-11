# vphone-cli 开工清单与验收标准

日期：2026-09-08。

最新整体状态、分支差异、功能进展及剩余工作原因见 [2026-09-11 状态更新](project_status_2026-09-11.md)。本清单保留原工作项定义和历史验收记录。

2026-09-11 执行进展：[定位修复分支整合](location_fixes_integration_2026-09-11.md)已完成代码移植与回归，E5 的真实入口和双 VM 验收仍未完成；[C4](firmware_recovery_c4_2026-09-11.md)已开始写入审计，暂存和恢复尚未实现。完成计数保持 9/28，19 项未完成。

依据：[项目现状报告](../research/project_status_analysis_2026-09-08.md)。适用基线：`4dcbdb8` 及报告列出的 6 个未提交修改文件。

目标：先建立可验证、可恢复的 VM 与固件流程，再完善无 GUI 自动化和多 VM 使用能力。

本清单共 28 个工作项。**当前状态（2026-09-10）：9 项完成（A1、A2、B1–B4、C1–C3），19 项待执行。C3 结果见 [收尾验收](c3_completion_acceptance_2026-09-10.md)。以下日期进展保留历史状态。** 2026-09-08 更新：A1 已完成；A2 已完成并独立提交；B1 已完成并独立提交；B2 已完成并独立提交。2026-09-09 更新：B3 已完成，实机 VM 验证部分完成（优雅、SIGKILL、`--force`、未运行、持锁无目标五类场景已验证；`dfu`、`.app` 内二进制、`.failed` 分支待做）；B4 已完成并提交（`20cf892` Swift、`ff423c2` Shell）；C1 已完成（机器可读兼容性清单 + 双向校验测试 + 文档）；C2 已完成（结构化补丁结果 + 必要性规则 + 消融 CLI + 两个示例迁移，提交 `afe0905`）；C3 进行中（全部补丁器已接入结构化结果；26.4 两项内核定位已修正并通过原始样本检查，less 26.1 的 Filesystem → Manifest 和独立根哈希验收通过，完整支持矩阵验收未完成）。已完成 8 项（A1、A2、B1、B2、B3、B4、C1、C2），其余 20 项待执行（C3 计入进行中，未完成）。结果见[A1 测试基线](../research/test_baseline_2026-09-08.md)、[A2 验证记录](../research/systemos_cache_validation_2026-09-08.md)、[B4 离线操作占用保护](../research/offline_op_guard_2026-09-09.md)、[固件兼容性清单](../research/firmware_compatibility.md)与[结构化补丁结果与消融](../research/patch_results_ablation_2026-09-09.md)。

## 一、建议现在开始的工作

**第一个交付：A1 测试基线 + A2 现有 AEA 修改验证。** A1 先解决当前测试无法运行的问题；A2 范围明确，直接覆盖已有工作区修改。两个任务分别提交，便于审查。

随后完成 B1 CFW 挂载隔离、B2–B4 VM 生命周期保护，以及 C1–C3 必要补丁完整性判定。A3 触控验证需要指定固件和 GUI，可在准备好测试 VM 后执行。A4 将已确认的快速测试放入 CI。

推荐执行顺序：

1. A1 → A2 → B1。
2. B2 → B3 → B4；准备好测试 VM 后完成 A3；以 A1 为基础完成 A4。
3. C1 → C2 → C3 → C4 → C5。
4. D1 → D2；B1 和 A2 完成后执行 D3；C4 完成后执行 D4 → D5。
5. E1 → E2 → E3 → E4 → E5 → E6。
6. F1 → F2 → F3 → F4。

以上是默认顺序。已有明确依赖的任务必须按依赖执行。产品文档随每个任务更新，F4 负责最后核对全部文档。

## 二、共同约束

- 不创建、读取或更新仓库根目录的任务清单文件；进度记录在本研究文档和提交历史中。
- 保留用户已有修改；AEA 和触控分别验证，不混入同一次功能提交。
- `.ips` 诊断文件独立处理，不随代码提交；未分析前不推断原因。
- 使用 `make build` 构建和签名；完整分发包必须额外验证所需资源。
- 内核工作先读取仓库 kernel-analysis 技能；补丁定位、指令匹配和编码遵守 AGENTS.md。
- 应用新补丁时同步更新 `research/0_binary_patch_comparison.md`。
- 每个行为修改包含能验证实际结果的回归用例；文档和其他低影响调整不增加形式化测试。
- 使用临时样本、临时 bundle 或专用测试 VM 验证失败路径，避免覆盖现有研究环境。
- 历史通过、本次通过、样本缺失和环境阻塞分别记录。
- 每项工作完成后单独记录提交、验证命令、结果和限制。依赖完成不代表本项自动完成。

## 三、A：恢复测试能力并验证已有修改

### A1 — 建立可重复运行的测试基线【已完成；2026-09-08】

涉及：`scripts/setup_venv.sh`、`requirements.txt`、`Package.swift`、`tests/FirmwarePatcherTests`、`tests/VPhoneCoreTests`、`Makefile`。

- [x] 核实代理配置及 Swift 依赖获取失败的原因；恢复可用下载路径，使用可写缓存目录。创建项目 `.venv`，验证 Capstone 能解码、Keystone 能实际汇编 ARM64 指令。
- [x] 区分无固件测试、固件样本比较和需要 VM 的运行验证；增加统一测试入口及必要的样本检查。显式请求固件测试却缺失样本时应返回非零并列出缺失项。
- [x] 运行全部无固件 Swift/Python 测试，修复确认的测试或实现问题；记录 macOS、Xcode、Swift、Python、解析后的依赖及测试数量。

验收：无固件测试全部通过；缺失固件样本不会混入快速测试，也不会被报告为固件测试通过。路径别名问题须验证后处理，不直接沿用历史判断。

结果：`make test` 222 项通过（Swift 200、Python 22），`make setup_venv` 与签名构建通过。`make test_firmware` 缺少 17 个输入文件时返回非零；固件与 VM 验证未运行。路径别名断言已复现并修正。A1 提交：`b7d0382`。

### A2 — 验证并完成 AEA 解密状态识别【已完成；2026-09-08】

涉及：`scripts/cfw_install.sh`、`scripts/cfw_install_dev.sh`、`scripts/cfw_install_exp.sh`；新增对应 Shell/Python 回归样本。

- [x] 用命令替身验证原始 `AEA1` 输入、内容为 DMG 但扩展名为 `.aea`、缓存已存在三条路径，检查解密与复制各执行几次。
- [x] 验证输入缺失、截断、无效内容、解密失败、复制失败和不完整缓存；避免把所有非 AEA 输入都无条件视为可用 DMG，失败不得留下可被误用的有效缓存。
- [x] 三个安装入口使用一致判定；证明 JB 继承的基础路径受覆盖，执行语法与回归检查后独立提交。

验收：原始 AEA 仅解密一次，已解密输入不再解密，重复运行结果一致；无效输入明确失败。系统工具生成的 APFS 测试镜像使用专用副本；Apple 固件兼容性单独记录。

结果：新增共享缓存函数，四个入口的 8 组输入验证通过；A2 新增 9 项 unittest，`make test` 共 231 项通过。专用 APFS 镜像及原生 AEA 加密/解密验证通过，脚本语法与签名构建通过。本记录随 A2 独立提交。实际固件安装与 Apple 密钥获取未验证。

### A3 — 验证客户机触控优先策略【高；依赖 A1、可用测试 VM】

涉及：`VPhoneControl.swift`、`VPhoneVirtualMachineView.swift`、`scripts/vphoned/vphoned_hid.h`、`vphoned_hid.m`。

- [ ] 验证连接状态与 `touch` 能力的选择矩阵：未连接、能力缺失、连接且支持、断线、重新连接。
- [ ] 在已准备的旧版 iOS、26.x、27.x 精确组合上检查点击、拖动、长按、边缘坐标、窗口缩放以及按下过程中断线的释放行为；缺少组合时记录未验证。
- [ ] 检查当前单指路径与原生路径的行为差异，保留有效回退；记录 GUI 证据并独立提交现有触控改动。

验收：不存在已复现的卡住按下、重复注入或坐标错误；支持范围由实际组合确定，不能只凭客户机声明能力认定交互已通过。

### A4 — 加入 PR 快速测试流程【高；依赖 A1】

涉及：新增 `.github/workflows/checks.yml`；共用 A1 的测试入口。

- [ ] 在 push/PR 上运行无固件 Swift/Python 测试和相关脚本静态检查，显式准备依赖。
- [ ] 将固件与需要私有 VM 环境的测试放到独立任务或专用运行器，上传测试摘要和失败日志。
- [ ] 缓存键包含工具链和依赖输入；验证一次正常变更及一次故意失败样本的反馈，随后移除故意失败样本。

验收：CI 测试断言失败会阻止该检查通过；不依赖个人缓存或个人固件目录。发布包校验在 D1 完成后接入同一流程。

## 四、B：保证磁盘与 VM 生命周期操作一致

### B1 — 隔离 CFW 挂载目录与清理范围【实现与验证完成；2026-09-08】

涉及：`scripts/cfw_install_host.sh`、四个 `cfw_install*.sh`。

- [x] 每次安装创建独立任务目录，通过 `CFW_HOST_MNT` 传入各变体；移除驱动中写死 `/private/tmp/cfwhost` 的清理路径。
- [x] 记录本任务实际挂载的目录和设备；退出、失败、SIGINT 清理只作用于本任务资源，原始失败码不得被清理覆盖。
- [x] 先用 hdiutil/diskutil/mount 替身测试两任务并发及中途失败，再用专用镜像副本验证真实挂载和退出。

验收：两个安装任务无目录冲突；一个任务结束不会卸载另一个任务的卷。同一磁盘的跨入口排他保护由 B2/B4 补齐。

结果：`make test` 237 项通过，6 项主机隔离专项回归与专用 APFS 镜像实验通过。B1 与本记录一并独立提交。实际安装与验证限制见[B1 验证记录](../research/cfw_mount_isolation_2026-09-08.md)。A2 提交为 `2ac6c51`。

### B2 — 建立跨入口的 VM 排他锁与运行记录【已完成；2026-09-08】

涉及：拟新增 `sources/VPhoneCore/VPhoneVMLock.swift`、`VPhoneVMRuntimeState.swift`；启动 CLI、AppDelegate、创建编排和 Shell 入口。

- [x] 选定 Swift 与 zsh 调用链能够共同遵守的锁机制；明确锁文件稳定位置、所有者和释放规则，避免锁在等待子进程期间丢失或误继承。
- [x] 将锁接入直接 `boot`、`vm launch`、创建中的 DFU/首启以及离线磁盘操作；运行记录包含 bundle 标识、PID、启动实例标识和启动时间，避免仅靠 PID 文件。
- [x] 测试重复启动、并发启动、正常退出、异常退出、过期记录、路径别名、子进程继承与两个不同 VM 的互不影响。

验收：同一 VM 不能被两个入口同时占用；异常退出后可恢复使用；不同 VM 不被错误串行化。不能通过 unlink 一个仍被持有的锁文件绕过锁。

结果：目录 inode 上的 `flock` 已由 Swift 与 Shell 共用，运行记录不作为占用依据。251 项完整回归通过，最终配置调整后 38 项专项测试通过，构建与签名校验通过。生产签名程序被 SIGKILL，原因未查明；无私有权限临时副本的启动锁检查通过。详细接入范围、旧入口和实际 VM 验证限制见[B2 验证记录](../research/vm_lock_validation_2026-09-08.md)。B1 提交为 `32d1a5f`，B2 与本记录一并独立提交。

### B3 — 使停止操作只作用于目标 VM 进程【已完成；2026-09-09；实机验证部分完成】

涉及：`VPhoneVMLaunchCLI.swift`、B2 的运行状态模块、进程测试。

- [x] 使用经过实例校验的 VM 进程记录决定信号目标，lsof 仅用于占用诊断。
- [x] 保留 SIGINT、等待、必要时 SIGKILL 的顺序；每次升级信号前重新确认进程身份，退出后确认实际状态。
- [x] 用受控子进程测试：其他程序打开 Disk.img、PID 失效或被复用、进程不响应 SIGINT、目标已退出。

验收：不向其他磁盘使用者发送终止信号；未停止成功时不会输出成功结论。

结果：目标由 `(pid, startedAt)` 对标识，`startedAt` 取 `kinfo_proc.kp_proc.p_starttime`；SIGKILL 之前重新列举进程并与快照求交集，`startedAt` 变化、记录缺失或已成僵尸的 pid 一律按已退出处理，不再收到信号。SIGKILL 与 `--force` 之后按 0.5 秒粒度、最长 3 秒确认目标消失且 bundle 锁释放，未确认时输出 `stop failed` 并以非零码退出。判定与信号逻辑移入新增的 `VPhoneVMStopper`，`lsof` 只用于「持锁但无引导目标」分支列出 Disk.img 持有者。新增 13 项 `VMStopTests`（含符号链接替身引导进程、Disk.img 持有者、`trap '' INT`、Python `flock` 持锁方、注入的 pid 复用与失败路径）；`swift test --filter 'VMStopTests|LaunchLayoutTests|VMLockTests|ShutdownPolicyTests'` 41 项通过，`make test` 295 项通过，`make build` 与 7 项 entitlements 校验通过。2026-09-09 在 VM `rig-baseline`（iOS 26.6.1，exp 变体）上完成实机验证：优雅回归（`vm stop`，4.193 s，退出码 0，无 `force-killing`）、SIGKILL 分支（`--timeout 1`，1.685 s，先 `sending SIGINT` 后 `force-killing`，退出码 0）、`--force`（0.603 s，无 SIGINT，退出码 0）、未运行（`not running`，退出码 0）与「持锁但无引导目标」（Python `flock` 持锁方，退出码 1，未发送任何信号，持锁进程存活）五类场景，每次停止后 `pgrep vphone-cli`、`lsof Disk.img`、`com.apple.Virtualization.VirtualMachine` 均为空，二次 `vm stop` 输出 `not running`；两次强杀后 VM 仍能正常引导并完成优雅关机。`dfu` 引导、`.app` 内二进制停止和 `.failed` 分支仍未实机触发。详见[修复记录](review_fixes_2026-09-08.md)「B3 停止目标身份复核（2026-09-09）」。

### B4 — 统一所有离线操作的占用保护【已完成；2026-09-09】

涉及：`VPhoneBundleOps.swift`、VM 管理/传输 CLI、restore、CFW host 安装、旧 Make/Shell 入口。

- [x] 为删除、重命名、克隆、导出、恢复、CFW 安装和修改配置定义明确的运行中策略；首版拒绝在线克隆/导出，除非另有经验证的一致快照实现。
- [x] 检查与实际操作处于同一锁生命周期内；`--force` 只跳过交互确认，不绕过磁盘占用检查。
- [x] 验证 CLI 与脚本入口、外部进程占用、检查后立即启动的竞争、路径别名和操作异常。

验收：所有列出的操作使用统一保护规则，不能从旧入口绕过；失败不破坏原 VM。

结果：新增 `VPhoneBundleGuard`（`withBundleLock` / `withLibraryLock` / `requireDFUOwner`）与 `VPhoneLibraryLock`，统一每个离线 bundle 操作的占用保护入口，两侧（Swift、Shell/Makefile）共用对目录 inode 的同一把 `flock`。三层模型：bundle 锁（config/rename/delete/clone/export/stage-vphoned/cfw-record/cleanup-firmware/fw-prepare/fw-patch/restore-decrypt，跨整个「检查—写入」窗口）、library-root 锁（create/import，把名字存在性检查与放置合并为同一锁生命周期以修 TOCTOU）、协作式 DFU 校验（restore 校验当前 DFU 持有者而非再取锁）。runtime 记录只作拒绝原因佐证，不参与是否允许判定。`recordVariant`/`removeBuiltFirmware` 改为要求 `holding: VPhoneVMLock`，使 cfw-record 锁成为编译期约束。Shell 侧：`setup_machine.sh` 去掉 `lsof/pgrep → kill -9` 预检并改为调用 `vphone-cli vm stop`（非零退出即终止，无强杀回退）；`vm_backup/vm_restore/vm_switch/vm_package/vm_create` 经 `scripts/vm_lock.py` 自包裹；`Makefile fw_prepare` 以 `vm_lock.py` 包裹。回归覆盖操作词表、嵌套锁拒绝、delete 不改字节、inode（非路径）键、create/import 同名竞争（`afterNameCheck` seam）、全部 `requireDFUOwner` 路径。验证：`swift test` B4 套件通过；`make build` 签名成功；`make test` 240 项 / 32 套件通过；所有改动脚本 `zsh -n` 通过。设计与范围见 [B4 离线操作占用保护](offline_op_guard_2026-09-09.md)。提交：`20cf892`（Swift）、`ff423c2`（Shell）。

## 五、C：补丁完整性与产物恢复

### C1 — 建立机器可读的兼容性清单【已完成；2026-09-09】

涉及：拟新增 `research/firmware_compatibility.json` 与格式校验；现有 firmware 测试脚本和固件选择报告。

- [x] 分别记录 iPhone 版本/构建、cloudOS 版本/构建、内核类型、变体、选项、验证阶段和对应证据。
- [x] 先录入能找到证据的精确组合；区分代码可选择、补丁验证通过、启动通过和特定能力通过。
- [x] 为每个补丁配置登记必要方法/补丁组和预期不适用项；计数分别记录方法数与写入记录数，不用单一总数判断兼容。

验收：清单能解释同一变体在不同输入下的记录差异；未知组合明确显示为未验证。

结果：新增 `research/firmware_compatibility.json`（`schema_version: 1`）、Python 格式校验 `tests/test_firmware_compatibility.py`（14 项，`make test` 自动发现）、Swift 一致性测试 `tests/VPhoneCoreTests/FirmwareCompatibilityManifestTests.swift`（2 项，与 `VPhoneFirmwareCatalog` 交叉校验）、说明文档 `research/firmware_compatibility.md`。清单含 5 个补丁配置（less/regular/dev/jb/exp，按流水线组件顺序列方法、gate 与预期不适用项）、23 条 catalog iOS 配对（构建号从 IPSW URL 解析；`c1_inventory.md` 记的「24 条」经复核实为 23）、4 个 cloudOS 镜像与 30 条组合。阶段分布：23 条 `code_selectable`（每条覆盖 5 变体，cloudOS 构建号 `null`）、3 条 `patch_verified`（26.1/26.3 regular/dev/jb 字节 parity、26.5 jb 83 records byte-identical）、4 条 `capability_verified`（27.0 24A5408d jb+frida、24A5380h jb、24A5390f jb、26.6.1 exp rig-baseline）。计数分列 method（JB 内核 59）与 record（84@26.x / 83@26.5 / 95@27.0），并登记 CLAUDE.md 52/66/127/141 & 10/12/14/18 与 `0_binary_patch_comparison.md` 56/70/132/163 及 method/record 三套口径的差异（CLAUDE.md 数字标记待确认，未修改 CLAUDE.md）。校验命令：`python3 -m unittest tests.test_firmware_compatibility -v` 全过；`make test` 全过；`swift build` 成功。限制：regular/dev 无完整真机 boot 证据、cloudOS 构建号多数缺失、内核类型维度含义待确认——均记入 `open_questions`。未应用新二进制补丁，`0_binary_patch_comparison.md` 未改。提交 `d03d838`。

### C2 — 定义结构化补丁结果【已完成；2026-09-09】

涉及：`Core/PatcherProtocol.swift`、`PatchRecord.swift`、拟新增补丁结果类型及 `Pipeline/FirmwarePipeline.swift`。

- [x] 定义 applied、already-applied、not-applicable、failed 四种结果；必要性由明确的版本/功能规则决定，禁止将无匹配默认视为不适用。
- [x] 将 PatchRecord 保留为实际字节变更记录；结果记录关联补丁标识、适用规则、原因和关联记录。
- [x] 用合成补丁器验证必要失败、允许跳过、已应用、不确定匹配、同组件部分成功，以及补丁组要求多条记录的情况。

验收：必要项失败时流水线返回失败；既有其他成功记录不能掩盖该失败。尚未迁移的补丁器明确标记状态覆盖范围。

结果：新增 `sources/FirmwarePatcher/Core/` 五个文件——`PatchOutcome.swift`（`PatchOutcome`/`RawStepResult`/`OutcomeKind` + 映射）、`PatchRequirement.swift`（`PatchRequirement`/`PatchRule`/`RequirementKind`）、`PatchIdentifier.swift`（`PatchID`，点分单串 Codable）、`PatchResult.swift`（`PatchResult`/`PatchGateSnapshot`/`ComponentReport`/`Coverage`/`PatchRunReport`）、`StructuredPatcher.swift`（`StructuredPatcher` 协议 + `PatchStep` + `StructuredExecution` 执行器 + `LegacyPatcherAdapter`）；`PatchRecord` 未改。`Pipeline/FirmwarePipeline.swift` 新增 `patchAllStructured(ablate:allowOutput:)`、internal `patchDataStructured(...)`、`knownAblationTargets(...)` 与门控快照构造 `prepare()`，`patchAll()` 改为薄封装。迁移 `AVPBooterPatcher.patchDGSTBypass`（required，applied/failed 路径）与 `IBootJBPatcher.patchSkipGenerateNonce`（required，alreadyApplied 路径）为 `StructuredPatcher`，方法体与 emit 的 record 逐字节不变。CLI 入口 `patch-firmware`/`fw patch` 改走结构化路径，新增 `--ablate`/`--allow-ablation-output`/`--report-out`（并镜像到 `patch-component`）；未知 ablation id 前置校验、消融运行默认 dry（不写回）。输出映射：`notApplicable` 只由 conditional rule 判 false 时产生，无匹配默认 `failed`，`ambiguous`/`encodeFail` 一律 failed。失败判定：组件失败 ⇔ 有效必要且 failed；任一有效必要 failed → CLI 非零，成功不掩盖失败；`ablated` 不使组件失败但计入 `PatchRunReport.ablation`。测试：`tests/FirmwarePatcherTests/FirmwarePatcherTests.swift` 新增 `SyntheticStructuredPatcher` 与十个合成用例（`StructuredPatchResultTests`）、C1 对齐测试（`C1AlignmentTests`，step method 集合 vs `firmware_compatibility.json` 的 `methods[].name`）、迁移补丁器 parity 测试（`MigratedPatcherParityTests`）。校验命令：`swift build` 成功；`make test` 258 项全过；`make build`（签名分发包）成功；`swift test --filter MigratedPatcherParityTests`（设 `VPHONE_TEST_AVPBOOTER`/`VPHONE_TEST_IBSS` 指向 `vm-2607` 只读派生 payload）4 项全过。parity 结果：达到单元级 record 相等（真实固件字节）——迁移前 `findAll()` 与新 step 路径产出的 `[PatchRecord]` 逐条相等（AVPBooter 非空、iBSS 幂等均相等）。限制：CLI 级 `--records-out` 前后 diff 未执行（签名二进制被 amfidont SIGKILL，退出码 137）；全流水线 dry-run sha256 对比未执行（`vm-2607` 的 iBSS 命名 `d47` 与流水线搜索 `vresearch101` 不符，离线无匹配命名 VM）；内核多方法补丁器与 DeviceTree/Manifest/Filesystem 仍为 legacy（`coverage: legacy` 明确标记），留待 C3。详见 [结构化补丁结果与消融](../research/patch_results_ablation_2026-09-09.md)。未应用新二进制补丁，`0_binary_patch_comparison.md` 未改。提交 `afe0905`。

### C3 — 分组迁移现有补丁并使用结果作为测试判据【已完成；本轮 24 + 1 场景验收；2026-09-10】

涉及：基础、JB、EXP 内核补丁器，iBoot/TXM/DeviceTree；`tests/test_*patches.sh`。

- [x] 按基础引导链、基础内核、JB、EXP 分组迁移，每组独立提交；对多条写入必须共同出现的补丁实施组级完整性检查。
- [x] 比较迁移前后同输入、同选项的字节产物，状态改造本身不得改变补丁语义；未知形态需明确失败原因。Filesystem 按同一 apply/helpers 结构证明、实际 Manifest 字节链和独立产物校验限定，不宣称两次完整镜像逐字节实测。
- [x] 将固件测试从扫描 `[-]` 切换到结构化结果；保留日志供诊断，同步更新研究文档。

验收：列入支持范围的组合通过必要集合检查；每个变体都有独立证据。缺失样本的组合不能随本项被标记完成。

结果（第一组：基础引导链，2026-09-09）：迁移 `IBootPatcher`（iBSS/iBEC/LLB 三模式基类）、`TXMPatcher`、`TXMDevPatcher` 为 `StructuredPatcher`；`IBootJBPatcher`、`TXMDevPatcher` 的结构化一致性从 extension 改为类体内 `override func buildSteps()`（动态派发，`emittedRecords`/`commit` 继承基类），与基类迁移同一改动完成以避免中间态编译失败。`buildSteps()` 精确复现 `findAll()` 的每模式方法集合与顺序；`patchImage4Callback` 定为 `.required`（每个 iBoot 组件唯一必要锚，防止「全 optional → 零记录静默通过」的回归），其余 iBoot 方法 `.optional`，`TXMPatcher.patchTrustcacheBypass` 与 `TXMDevPatcher` 全部 6 方法 `.required`。方法体与 emit 的 record 逐字节不变，仅对 `patchSerialLabels`/`patchBootArgs`/`patchRootfssBypass`/`patchBootxPrecondition`/`patchSelector24ForcePass`/`patchSelector42_29Shellcode` 增加返回信号以区分完整/部分/无匹配/歧义。映射修正：`PatchOutcomeMapping` 原将 `.optional` + `noMatch` 判为 `failed`（仅因 optional 不计入 `hasRequiredFailure` 而无害），现改为 `notApplicable(reason: "optional, no anchor")`，仅 `.required` 与规则为真的 `.conditional` 在无匹配时判 `failed`。清单 `research/firmware_compatibility.json` 修正：iBSS/iBEC/LLB 各变体加入 `patchImage4Callback`（required=true），并按实际 mode 分支删除错列方法（iBSS 仅 serial+image4；iBEC 去 rootfs/panic；LLB 去 bootxPrecondition）；TXM dev/jb/exp 的 `patchSelector24Shellcode` 更名为 `patchSelector24ForcePass`（对齐 Swift 方法名，不改 Swift 名）。字节 parity：迁移前 `findAll()` 与新 step 路径产出的 `[PatchRecord]` 逐条相等且非空。验收用未改写的库存输入以覆盖全部方法——iBSS/iBEC/LLB 的 `vresearch101.RELEASE.im4p` 取自 cloudOS IPSW、txm(`txm.iphoneos.research.im4p`) 取自基础 IPSW（IM4P，测试内经 `IM4PHandler.load(...).payload` 解压），覆盖 iBSS/iBEC/LLB 三模式与 TXMPatcher/TXMDevPatcher 完整方法集。parity 判据为同一输入上 old==new 字节相等，在库存输入与已安装的 `vm-2607` 输入上均成立。测试：新增 C1 对齐用例（iBEC/LLB/TXM 等值、iBSS-base 子集、TXM-regular 等值）、env 门控真字节 parity 用例（`VPHONE_TEST_{IBSS,IBEC,LLB,TXM}_IM4P`）、映射修正合成用例（optional+noMatch→notApplicable）。校验：`swift build` 成功；`python3 -m unittest tests.test_firmware_compatibility` 14 项全过；`make test`（Python 69、Swift 270）全过；`swift test --filter MigratedPatcherParityTests` 9 项全过；`make build` 签名成功。限制：`patchRootfssBypass` 是否 LLB 引导被改 rootfs 的硬需求 待验证（暂 `.optional`）；未应用新二进制补丁，`0_binary_patch_comparison.md` 未改。剩余 C3 组（基础内核 / JB / EXP 内核，及 DeviceTree/Manifest/Filesystem）仍为 legacy 覆盖，待后续组迁移。详见 [C3 基础引导链迁移](../research/patch_results_c3_bootchain_2026-09-09.md)。提交 `355121f`。

后续推进（2026-09-09）：基础内核 `KernelPatcher` 已迁移为 12 个结构化方法，补齐 Sandbox 五个 hook 的完整性判定、条件与消融的执行前拦截。完整回归、构建和签名校验通过；`vm-2607` 同输入 regular/dev 的记录与 payload 比较通过，但仍有 8 个必要方法失败，因此原始样本完整性验收未完成。详见 [C3 内核迁移记录](patch_results_c3_kernel_2026-09-09.md)。C3 仍为进行中。

本轮提交：基础内核 `dcc7268`、JB `4dc54c9`、EXP `587e02e`、产物与验收脚本 `01847be`。最终 `make test`：Python 73、XCTest 20、Swift Testing 报告 295 项通过；原始样本测试的失败与未执行范围单独记录。

本轮补充：JB 33 个、EXP 1 个、DeviceTree 基础 4 个/EXP 23 个，以及 Manifest/Filesystem 各 1 个步骤已迁移；单组件 CLI 与固件测试均使用结构化结果。26.1 原始内核 regular/dev/JB 26.x 必要集合通过。26.4 regular、EXP 与 DeviceTree 必要集合通过；dev 的 `patchExcGuardBehavior`、JB 的 `patchVmMapProtect` 失败。已运行的同输入记录与 payload 比较均相等，包含 base → JB → EXP 顺序组合。两项失败未放宽为可选；less 完整镜像合并未执行，因此 C3 不标记完成，已完成工作项仍为 8/28。详见 [内核记录](patch_results_c3_kernel_2026-09-09.md)、[EXP 记录](patch_results_c3_exp_2026-09-09.md)与[产物及验收脚本记录](patch_results_c3_artifacts_2026-09-09.md)。

后续诊断：26.4 EXC_GUARD 的调用链出现内联检查与包装函数尾调用；vm_map_protect 的限制检查迁移到回调并改用 BIC/CMP/CCMP。两项定位失败原因已查明，尚未修改补丁。less 三份镜像输入存在，但缺少 `apfs_sealvolume_26.1`。详见 [C3 验收诊断](c3_acceptance_diagnosis_2026-09-09.md)。

内核修正提交 `2b53743`：26.1/26.4 的预期地址、唯一 4 字节写入、重复应用与异常锚点拒绝测试通过；26.4 必要集合和包含 Frida 的 base → JB → EXP 顺序组合通过，组合为 133 条记录。修正后尚未执行 VM 实机测试。less 已补齐 26.1 seal 工具，首次完整运行因临时镜像峰值占用导致 ENOSPC；调整临时副本释放时机后完整重跑通过（1207.272 秒）；四个组件 Manifest 哈希、AEA 解密与内容检查通过，清理校验挂载新增的 `.fseventsd` 后原始 root hash 的导入 digest.db 和不导入两种校验均通过。less 修正与验收提交 `c5bb188`。尚未刷写或引导该产物。见 [内核修正](c3_kernel_retarget_2026-09-09.md)、[less 验收](c3_less_acceptance_2026-09-09.md)。

2026-09-10 收尾进展：C1 的 EXC_GUARD、Frida gate 名称已与 `PatchRule.rawValue` 统一；五变体步骤对齐及 16 个 EXC_GUARD 实际流水线门控组合测试通过。上述 26.4 两项定位失败、less 工具缺失及首次 ENOSPC 为历史状态，后续修正和重跑结果见前段。完整支持矩阵及修正后产物运行验收仍未完成，**C3 仍为进行中**。本轮剩余验收范围见 [C3 验收收尾记录](c3_acceptance_remaining_2026-09-10.md)，门控修改见 [C1 门控一致性修正](firmware_compatibility.md#9-门控一致性修正2026-09-10)。

2026-09-10 补充验收：26.1 / 23B85 与 26.4 / 23E5207q 原始内核 SHA-256 重新核对一致；base 的 regular、dev、iOS 18 gate、强制 EXC_GUARD 四配置在两份输入上分别为 28 / 29 / 29 / 29 条记录。26.4 JB 的 iOS 27 gate / Frida 四组合为 84 / 96 / 88 / 100 条记录；以上完整记录、payload 比较和必要集合检查通过。26.1 与 26.4 的默认 base → JB → EXP 顺序组合均为 117 条记录，完整记录、payload 和必要集合检查通过。组件级门控验证不代表对应 iPhone 构建全链通过；26.3 本轮样本、引导链精确证据、部分 EXP 顺序组合及 VM 运行验收仍缺失，C3 保持进行中。实测日志与剩余范围见 [C3 剩余验收](c3_acceptance_remaining_2026-09-10.md)。

本轮回归：首次 `make test` 的 Python 73 项通过；Swift VMStop 出现 9 条断言失败，同时沙箱拒绝 `ps`，该次 Swift 不记为通过。在允许进程查询的环境重跑 `make test_swift` 退出码为 0，XCTest 20 项、Swift Testing 298 项 / 46 suites 全部通过（25.525 秒）。完整日志见本轮验收文档。C3 状态和已完成工作项计数不变。

2026-09-10 顺序组合补充：26.4 原始内核的 base → JB → EXP 在 iOS 27 gate 开启、Frida 关闭时通过完整记录、payload 和必要集合检查，共 129 条记录（1 test / 1 suite，156.853 秒）。仅 Frida 开启的组合随后通过，共 121 条记录（1 test / 1 suite，95.959 秒）；26.4 的四种 iOS 27 gate / Frida 顺序组合均已有完整记录、payload 和必要集合证据。精确 26.1 / 23B85 四种非 less 引导链生产流水线和必要集合报告随后通过，regular / dev / jb / exp 分别为 29 / 34 / 68 / 88 个声明方法、58 / 70 / 152 / 178 条记录；独立落盘 payload 验证通过（六类二进制记录重放，DeviceTree 序列化 parity）；C1 新增独立 `patch_verified` 组合并保留历史证据。详见 [精确引导链验收](c3_full_pipeline_acceptance_2026-09-10.md)。精确固件全流水线与运行验收仍未完成，C3 保持进行中。详见 [C3 剩余验收](c3_acceptance_remaining_2026-09-10.md)。

2026-09-10 收尾矩阵扩展（进行中）：准备 261、263（本轮 cloudOS 实际构建为 `23D129`）、2661、270b5、1862 五组精确输入，覆盖 24 个非 less 场景及 1 个 less 默认场景。生产报告、落盘验证与完整 legacy/structured parity 分别验收；历史 `23D128` 不由本轮替代。Filesystem 采用迁移差分证明、实际 Manifest 字节链与独立产物校验分别记录，不能表述为已执行两次完整镜像 byte parity。恢复/启动按原工作项归入 F1，多文件中断恢复归入 C4，相关能力仍未验证。运行尚未结束，C3 状态与已完成计数不变。详见 [C3 收尾验收记录](c3_completion_acceptance_2026-09-10.md)。

2026-09-10 最终验收：上述 24 个非 less 场景全部通过完整 legacy/structured payload 与 records 比较、必要集合、落盘重放和 DeviceTree 序列化检查；less 默认完整流水线、真实 Manifest/三个引导组件 parity、21 组件摘要、独立解密内容及无 digest.db 的原始 root hash 校验通过。C3 已完成，累计 **9/28**，剩余 19 项。历史 cloudOS 23D128 和其他 catalog 可选组合不随本轮升级；恢复/启动归 F1，多文件中断恢复归 C4。完整限定与证据见 [C3 收尾验收](c3_completion_acceptance_2026-09-10.md)。此前段落保留为历史进度。

### C4 — 避免失败留下无法判断的部分修改固件【高；依赖 C3、B4】

涉及：`FirmwarePipeline.swift`、`IM4PHandler.swift`、`CryptexFilesystemPatcher.swift`、`ManifestHashPatcher.swift`、固件 CLI。

- [ ] 审计所有写入和挂载副作用，覆盖 `less` 文件系统/Manifest 路径；不能只暂存七个引导链二进制。
- [ ] 在暂存区完成修改和校验，验证通过后使用可恢复的提交记录交付产物。多文件替换不宣称具备文件系统级原子性。
- [ ] 在读取、打补丁、保存、Manifest 更新和提交各阶段注入失败；验证磁盘不足、进程退出和重复执行后的恢复行为。

验收：失败前后的原始输入、暂存结果和正式产物均可识别；中断后能够恢复一致状态，不依赖手工猜测。

### C5 — 输出可重现的补丁实验记录【高；依赖 C1–C4】

涉及：固件 CLI、PatchRecord 导出、VPhoneCore 报告模块；拟新增补丁实验记录文档。

- [ ] 自动记录输入/输出哈希、项目提交与未提交状态、工具版本、两个固件构建号、变体、选项和必要补丁结果。
- [ ] 从同一数据生成 JSON 与人类可读摘要；失败时同样保存已完成部分和失败阶段。
- [ ] 对两次完全相同的运行验证记录可比较，对不同选项验证差异可定位。

验收：研究者可以根据记录重建输入条件并判断产物完整性；历史总数不作为当前运行的替代证据。

## 六、D：构建、依赖和创建恢复

### D1 — 统一构建与应用包资源检查【高；依赖 A1】

涉及：`Makefile`、`scripts/build.sh`、`.github/workflows/release.yml`、`VPhoneResources.swift`。

- [ ] 让 `make build`、脚本和发布流程调用同一个构建实现；若保留精简包，显式区分产物类型。
- [ ] 完整包检查覆盖 scripts、Python patchers、资源档案、工具、vphoned、requirements 和真实签名资源路径；所有资源写入完成后进行最终签名校验。
- [ ] 从仓库外目录和符号链接启动应用包的无 VM 命令，验证资源解析；将资源检查接入 A4 和 release。

验收：完整包不依赖仓库当前目录；使用正确签名和资源的二进制执行命令。不能把精简包报告为可移植完整包。

### D2 — 固定并核验依赖解析结果【高；依赖 A1、D1】

涉及：`Package.resolved`、Python 依赖记录、`setup_venv.sh`、`VPhoneResources.swift`、CI。

- [ ] 根据实际解析结果固定 Swift 传递依赖和受支持 Python 环境的依赖版本，记录本地工具版本与资源来源/校验值。
- [ ] 统一脚本与 Swift 的依赖能力探测，包括 Keystone 实际汇编，避免只验证可 import。
- [ ] 验证空缓存初始化、已有兼容环境、损坏环境、下载失败和升级回退；不承诺未验证的平台使用同一锁文件。

验收：新环境能得到已验证的依赖组合；依赖差异可从诊断报告查明。

### D3 — 提取共同 CFW 安装步骤【高；依赖 A2、B1】

涉及：四个 `cfw_install*.sh`；拟新增 `scripts/lib/cfw_common.sh`。

- [ ] 提取 Python 选择、AEA/DMG 判定、缓存创建、挂载路径和共用错误处理；首先迁移已有重复逻辑。
- [ ] 变体专用阶段保持显式顺序和条件，避免将所有差异压入一个难以验证的通用函数。
- [ ] 验证每个变体的阶段序列、重复运行和故障清理，比较迁移前后的调用及产物。

验收：同一基础逻辑只维护一份，变体不互相引入额外补丁或阶段。

### D4 — 为创建流程增加检查点与续跑【高；依赖 B4、C4、D3】

涉及：`VPhoneCreateOrchestrator.swift`、创建 CLI、`VPhoneManagedProcess.swift`；拟新增创建状态模型和编排测试。

- [ ] 持久保存 prepare、patch、restore、CFW、first-boot、JB-finalize、verification 的状态及输入/产物摘要。
- [ ] 增加明确的续跑入口；重新验证前置产物后跳过已完成阶段。版本、选项或产物发生不兼容变化时拒绝盲目续跑。
- [ ] 使用可替换的阶段执行器测试每阶段失败/取消/重启；真实 restore 中断须重新探测设备状态，不能仅凭旧检查点继续写入。

验收：同名创建中断后有明确恢复路径；重新执行不会将部分成功误判为整体成功。默认清理策略保留恢复所需产物。

### D5 — 统一环境与 VM 诊断输出【中；依赖 B2、C5、D2、D4】

涉及：setup/VM CLI、`boot_host_preflight.sh`、资源和 bundle 报告模块。

- [ ] 提供单一诊断入口，报告宿主机条件、签名、依赖、资源、占用、创建阶段和最后失败原因。
- [ ] 提供文本与 JSON，使用稳定错误类别；检查本身默认只读，修复动作显式区分。
- [ ] 诊断报告默认不包含密码、令牌、客户机文件内容或完整用户数据；验证缺少组件和状态损坏的输出。

验收：使用者能区分环境、依赖、输入、补丁、恢复和客户机运行问题。

## 七、E：稳定自动化接口

### E1 — 修正请求长度并定义协议约束【高；依赖 A1】

涉及：`VPhoneHostControl.swift`；拟新增协议文档与 HostControl 测试。

- [ ] 明确 JSON 最大字节数、UTF-8 分片、换行终止、EOF、无效 JSON 和超长请求处理；移除当前依赖 read 分片方式的 4,096 字节行为。
- [ ] 明确 `file_put` 内联数据与宿主机文件路径两种方式的容量限制，超限返回稳定错误。
- [ ] 明确 socket 路径、目录/socket 权限、同用户访问模型、读写超时和并发上限；测试空连接、慢连接、半包和输出端不读取。

验收：接收行为不随分片方式改变；超限和超时不造成无限等待或无界任务堆积。

### E2 — 分离控制传输、命令执行和画面能力【高；依赖 E1】

涉及：`VPhoneHostControl.swift`、AppDelegate；拟新增命令执行与画面提供接口，最终命名在该项设计中确定。

- [ ] socket 层只负责连接与消息；命令层管理参数和结果；截图/录屏通过可选画面能力提供。
- [ ] 为现有命令保持字段和默认行为兼容；新增协议能力发现，清楚表达不可用的功能。
- [ ] 用替身覆盖 shell、文件、应用、定位、相机与截图的成功、错误和能力缺失，核对既有调用方可见结果。

验收：无 AppKit 视图也能创建命令执行对象；GUI 默认截图行为不回归。

### E3 — 支持 headless 宿主机控制【高；依赖 E2、B2】

涉及：`VPhoneAppDelegate.swift`、launch CLI、E2 的控制模块。

- [ ] 将普通 VM 的控制 socket 生命周期移出 GUI 分支；DFU 独立处理，只提供其真实可用能力。
- [ ] 无 GUI 时支持客户机能力查询、Shell、文件、应用和定位；缺少画面能力时截图返回明确错误。
- [ ] 验证 GUI、headless、DFU、客户机断线及 VM 退出后的 socket 行为与清理。

验收：`--headless` 的普通 VM 可以通过本地控制接口执行上述命令；退出后不遗留可被误判为可用的 socket。

### E4 — 建立客户机传输的故障与取消测试【高；依赖 E2】

涉及：`VPhoneControl.swift`、`vphoned_protocol.m`、`vphoned.m`；协议集成测试。

- [ ] 验证大小端长度、4 MiB 边界、短读写、请求 ID、并发响应、文件附带数据及重复/未知 ID。
- [ ] 验证握手超时、大传输中断、迟到响应、断线重连与旧写队列不得写入新连接。
- [ ] 区分调用方超时、请求取消与客户机操作实际停止；无法取消的操作明确报告其仍可能执行。

验收：完成回调最多执行一次，旧连接结果不会交付给新请求，大文件操作不造成无期限阻塞。

### E5 — 验证定位的持久化与流控制【高；依赖 E3、E4】

涉及：`VPhoneSystemLocationController.swift`、`VPhoneControlLocationAdapter.swift`、`VPhoneLocationProvider.swift`、定位测试。

- [ ] 通过真实控制入口验证固定位置、流推送、owner 竞争、generation/sequence、暂停、停止和超时 hold/stop。
- [ ] 验证客户端消失、客户机重连、宿主程序重启和持久文件损坏；固定位置的恢复范围与流的生命周期分别描述。
- [ ] 验证宿主位置同步与外部位置源切换，以及两个 VM 的状态隔离。

验收：新源不接收旧 generation 的位置；重连不会被宿主定位意外覆盖；状态报告能够说明当前所有者和生效情况。

### E6 — 定义并验证相机回执语义【高；依赖 E3、E4】

涉及：`VPhoneHostControl.swift`、`VPhoneCameraServer.swift`、`VPhoneFrameProducer.swift`、客户机 vcam 模块、`libvcamcaptured.m`。

- [ ] 定义回执表达“同 generation 已消费任意帧”还是“指定帧已消费”；检查两端帧编号含义，再修正注释与判断。
- [ ] 验证 generation 切换、旧帧积压、生产已启动但客户机未消费、客户机重启、视频结束及停止后的中性画面策略。
- [ ] 选定测试应用分别验证客户机收到帧、应用显示帧和 QR 等应用侧结果，三者独立记录。

验收：回执不会把旧源结果归属到新源；不能将传输成功直接报告为应用识别成功。

## 八、F：运行验收、性能与文档

### F1 — 建立精确组合的端到端验收矩阵【高；依赖 A3、C3、D4、E5、E6】

涉及：C1 清单、拟新增 `tests/runtime` 和相应研究记录。

- [ ] 按可获得样本选择一组主要回归组合和一组旧版本组合，逐步覆盖 less/regular/dev/jb/exp；不宣称尚未测试的排列组合已支持。
- [ ] 每组合记录创建、恢复、首次/第二次启动、GUI 输入、文件/应用、DDI、定位、相机及适用的 Frida 客户端会话。
- [ ] EXP 额外验证身份相关行为与图形/计算路径，确认非 EXP 变体未获得这些改动；失败绑定精确输入、阶段和日志。

验收：支持矩阵从本次运行证据生成；Frida 服务端口连通不替代客户端 instrumentation 验证。

### F2 — 验证两个 VM 同时工作的完整流程【高；依赖 B4、E3–E6】

涉及：拟新增多 VM 自动化测试，实例状态和日志。

- [ ] 两个 VM 同时启动，分别进行应用、文件、定位和相机操作，验证任务与结果归属。
- [ ] 停止或重启其中一个 VM，确认另一个继续工作；验证重名、路径别名、端口配置和后台任务取消。
- [ ] 检查重建/导出/安装时的占用保护，以及失败后的 socket、锁、挂载和进程清理。

验收：两个 VM 不发生状态串用或相互清理。该验收只证明两实例场景，不推导任意规模并发能力。

### F3 — 建立性能和长时间运行基线【中；依赖 F1、F2】

涉及：控制、相机和进程观测，独立基准脚本及报告。

- [ ] 固定宿主机、固件、CPU/内存配置与负载，记录命令延迟分位数、连接恢复、CPU/内存、磁盘实际占用、相机延迟和丢帧。
- [ ] 进行固定时长的重复操作与空闲实验，报告样本数、持续时间及资源增长；同时检查进程日志缓冲和待处理请求是否持续增长。
- [ ] 只针对测量确认的问题安排优化，优化前后使用相同实验设置比较。

验收：得到可复跑的基准，不预先承诺性能提升比例；没有测量依据的优化保留为后续候选项。

### F4 — 完成文档与交付核对【中；依赖相关工作项完成】

涉及：`AGENTS.md`、README 与多语言文档、研究索引、补丁比较文档、CI/发布说明。

- [ ] 更新实际模块图、入口、目录、变体、权限与依赖说明，移除失效文件引用；历史研究结论标明适用日期与组合。
- [ ] 从兼容性清单和运行记录生成计数/支持范围；记录开发包与完整包区别、headless 能力以及故障恢复命令。
- [ ] 核对全部工作项的提交和验收结果，对仍缺固件/GUI/客户机证据的项保持未完成状态。

验收：文档命令可复现，支持范围与结果一致；根目录不引入被仓库规则禁止的任务文件。

## 九、建议的提交与阶段结束条件

建议一个工作项拆成可独立审查的提交；C3 等横跨多个补丁器的工作按模块分批。避免将协议重构、补丁语义调整和 GUI 行为修改放在同一提交。

| 阶段 | 结束条件 |
| --- | --- |
| 第一批：A1、A2 | 测试环境可用；无固件测试通过；AEA 分支与重复运行通过回归检查 |
| 数据操作保护：B1–B4 | 安装资源隔离；进程所有权清楚；离线操作不能绕过占用保护 |
| 固件完整性：C1–C5 | 精确兼容性输入；必要补丁失败即失败；产物可以恢复；实验可追溯 |
| 构建与恢复：D1–D5 | 完整包资源正确；依赖可重现；创建中断后有经过验证的恢复路径 |
| 自动化：E1–E6 | headless 可控；协议受测试约束；定位和相机成功含义明确 |
| 运行交付：F1–F4 | 精确组合及两个 VM 实测完成；性能基线与文档一致 |

当前不作为开工前置项：全面重写成单一语言、跨平台宿主机、云端集群调度、仅为减少文件行数的大规模拆分，以及没有明确实验目标的 EXP 补丁扩展。

## 评审修复进展

A2/B1/B2/B3 与触控评审修复及验证见[修复记录](review_fixes_2026-09-08.md)。真实已解密 SystemOS 校验通过；A3 来宾交互与完整 CFW 安装仍待验证。B3 已实现并通过单元测试；实机 VM 验证已覆盖优雅停止、SIGKILL 分支、`--force`、未运行与「持锁但无引导目标」，`dfu`、`.app` 内二进制与 `.failed` 分支待做。
