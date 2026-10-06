# vphone-cli 上游整合方案（2026-10-06 修订）

**固定目标：`2d21d21fbdd4f51f013616273ceda9b35a3e0789`｜历史范围起点：2.0.8｜47 项任务：46 项主线、1 项可选。**

**本轮交付状态：完成方案与执行清单修订；未在用户实际仓库执行代码合并、构建或 VM 迁移。** 当前 Linux 研究环境已取得官方上游对象并核对关键源码；本地 fork 的实时状态留给 T00–T02 采集。

配套文件：[完整执行清单](sandbox:/workspace/scratch/b516258d298d/plan_revision/vphone_upstream_execution_TODO_2026-10-06_2d21d21.md) · [结构化任务台账](sandbox:/workspace/scratch/b516258d298d/plan_revision/vphone_upstream_integration_tasks_2026-10-06_2d21d21.json)。本方案接替 2026-09-30 的差异报告作为当前执行依据，原稿的历史事实按发生时点保留。

## 1. 目标与总体思路

以当前本地 fork 为基础，按能力和依赖接入固定上游目标的最终实现；复用本地已有的等价工作，维持 `regular/dev/jb/exp/less`、Hook、认证、Irisin、权限与路径约束、prepare/检查点及事务恢复能力。代码来源追溯到提交，完成标准落在实际行为、可验证状态和恢复能力。

本轮目标拆为三层：

1. **保住已有行为和数据。** 先保存真实本地工作，建立可恢复样本；历史通过项受到改动影响时复验，不删去原通过事实，也不凭旧结果直接放行新候选。
2. **让固件与环境更新可信。** 先完成模式、计划、原件、Receipt、事务和实际补丁证明，再开放环境、kernel、撤销及依赖它们的功能。
3. **在明确版本组合中交付功能。** 通信、控制、媒体、网络和管理入口各自成组整合；新旧组件并存时探测能力并记录来源。每个阶段可以产生独立验收点，最终候选再覆盖本轮完整支持范围。

固定目标位于 2.6.1 发布锚点之后。它用于冻结研究、适配和验收边界；本地产品版本不因目标标签而自动等同官方版本。后续 main 前移，另建增量，不改变正在执行批次的目标。来源：[固定整合目标](https://github.com/Lakr233/vphone-cli/commit/2d21d21fbdd4f51f013616273ceda9b35a3e0789)、[2.6.1 发布锚点](https://github.com/Lakr233/vphone-cli/commit/f9ea9015a82d29187d4b65cc15883d9bdc37a21c)。

## 2. 已确认的范围，以及仍需本地核对的事实

### 2.1 固定范围

| 对象 | 完整 SHA | 用途 |
|---|---|---|
| 上游历史范围起点 2.0.8 | `9d218dedf58d4b19db5e51c8b584c1f14a96eee3` | 延续旧报告范围，不断言它就是当前本地 merge-base |
| 上次目标 2.2.3 | `a969cd5d9206932dc1a2797348027fbc7d0ee347` | 区分原有任务与本轮新增范围 |
| 发布锚点 2.6.1 | `f9ea9015a82d29187d4b65cc15883d9bdc37a21c` | 来源说明，不替代固定目标 |
| 本轮固定目标 | `2d21d21fbdd4f51f013616273ceda9b35a3e0789` | 源码、依赖、任务和验收共同终点 |
| 当前本地基线 | T00 采集 | 历史 `ef6f408` 加未提交变更不当作当前结果 |

官方 Git 对象本轮可访问，旧报告“网络失败、计数待复算”的限制已更新。Git 2.51.1 下，先校验祖先关系，再使用 `rev-list --count` 和 `--no-merges --count` 得到：

| 上游范围 | 全部提交 | 非合并提交 |
|---|---:|---:|
| 2.0.8 → 2.2.3 | 124 | 122 |
| 2.2.3 → 固定目标 | 218 | 158 |
| 2.0.8 → 固定目标 | 342 | 280 |

**仅新增段 2.2.3→固定目标**，端点 diff 使用 `--find-renames=50%`，得到 357 个变更路径（157 新增、200 修改），+46,978 / −2,067 行；其中 `.swift/.c/.m/.h/.py/.sh` 六类源文件为 280 个。这些数字不代表本地剩余工作量，也不能替代配置、entitlements、资源、工程文件和合并解决内容审查。全范围非合并提交数和新增段源码文件数均为 280，属于不同统计口径。可复算命令与结果见结构化台账 `source_audit`。

上游新增段有 60 个合并提交；先细审 158 个非合并提交的能力和修正，再检查 merge 是否含独立解决内容。不能假定每个非合并提交都要移入，也不能假定 merge 全无语义变化。

### 2.2 历史证据的保留方式

历史工作目录记录为 `/Users/qcz3840/github/vphone-cli`，当时 HEAD 为 `ef6f408`，另有 prepare、检查点、测试和文档修改。此前记录过第一批适配以及 Swift/XCTest、Mac Release、APFS、重复启动和停机克隆启动等验收。它们作为历史检查点保留；本轮没有取得该实时工作区，也不把它们推定为当前候选已经通过。

2026-09-30 TODO 的 32 项当时统一为待执行，这是那份任务清单的状态，不能反向抹掉更早批次的工作。本轮新增的 `pending_local_audit` 表示“对当前固定目标尚待本地对账”，既不表示代码一定缺失，也不表示已经完成。T02 在已有证据范围内判定等价、适配、新增、被替代、延后或未知。

本轮读取依据包括 2026-09-30 的差异报告和执行 TODO，以及已知的历史整合记录。原始本地 comparison、implementation、remaining-progress 与批次验收文件需在真实仓库中重新定位；未检索到可用副本不等于用户仓库没有这些文件。原稿快照：

- [2026-09-30 差异报告](sandbox:/workspace/scratch/b516258d298d/plan_revision/vphone_upstream_diff_report_2026-09-30_a969cd5.md)
- [2026-09-30 执行 TODO](sandbox:/workspace/scratch/b516258d298d/plan_revision/vphone_upstream_execution_TODO_2026-09-30_a969cd5.md)

## 3. 对已有内容和目标的具体调整

| 项目 | 旧方案 | 修订方案 | 调整原因与落点 |
| --- | --- | --- | --- |
| 范围和终点 | 2.0.8→2.2.3；124/122 为待复算预期 | 终点固定到 2d21d21；保留历史段和新增段，实测总范围 342/280 | 旧工作仍需核对，新增 218 个提交不能替代历史欠项。T00–T02 |
| 实施方式 | 按能力整合、保留本地定制 | 继续保留，并增加逐提交处置、最终状态复核和合并提交解决内容审查 | 本地 squash/重实现无需重复；被后续修正的中间状态不重复引入。T02 |
| 依赖目标 | IcliKit 0.7.7 | 候选固定为 0.7.16 / 702990b…；其他锁文件按实际目标对齐 | 新增能力依赖调用和 entitlements，不能只更新版本数字。T08 |
| 补丁账本 | 计划、模式、applied 和 generation | 复用上游 Receipt/Drift/Undo，补足实际命中、读回、提交与激活证据 | 无需另建平行补丁框架，也不能把计划等同磁盘事实。T09–T12、T32–T35 |
| 内核与旧机升级 | 重点为环境更新 | 加入保留数据的 update-kernel、共享区域校验、撤销与 legacy 资格判定 | 新环境可能要求旧 kernel 尚未具备的前提。T15–T17、T33–T35 |
| 宿主检查 | T24 位于较后管理阶段 | T24 移入 M1；每 VM Bundle 绑定 T40 前置 | 新写盘和管理入口先遵守本地权限、身份及版本来源契约。 |
| 原件和事务 | 保留本地 prepare/checkpoint、clone/备份保护 | 加强跨文件恢复日志、新 generation 发布、no-op 补证据和单项必需补丁验证 | 上游有可复用能力，也有不能照搬的宽松失败分支。T12–T17、T32 |
| 控制能力 | 响应、输入、定位、应用和 Inspector | 追加 instance/unlock、有序关机、AX nested、触摸复制，并列出混合版本降级 | 旧 daemon 能响应基础 API，不代表理解新语义。T36–T39 |
| 网络和设备 | 原配置与原固件路径 | 加入 tunnel、每机网络、iPad/多 iPhone 身份路径并保留旧配置解释 | 新增字段缺失的默认值要逐项迁移，目录出现机型不代表本地支持。T41、T44 |
| 媒体和 Hook | 相机、定位、RootHide/Irisin 配套 | 音频/麦克风与 DeviceTree、kernel、HAL、路由、Hook、权限成组交付 | 单个 dylib 更新不足以构成新媒体链；本地门控继续有效。T20–T22、T42–T43 |
| console 与 UI | 2.2.3 的管理界面尾项 | 保留旧项并追加输出 ACK、分块性能和当前设置/创建流程 | 基础日志正确性可早验收；UI 完成依赖后端真实状态。T25–T27、T46 |
| 实验范围 | 实验开关受模式约束 | 120 Hz/FPS 独立 T45 默认延后；外部 root patchset、恢复 DSC ASLR 不纳入本轮 | 主线验收可收敛，后续启用需独立证据，不默认扩大安全或支持范围。 |

上述“强化、拒绝、回退、证据”等规则是本地接入设计要求；它们并非全部已经存在于上游。IcliKit 当前锁文件和新增能力来源分别见 [daemon 的精确依赖锁](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/VPhoneDaemon.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)、[Receipt 和撤销集成](https://github.com/Lakr233/vphone-cli/commit/a153e9ddc46d1af522acb167fff4b9518eebcd1f)、[每 VM Bundle 绑定](https://github.com/Lakr233/vphone-cli/commit/9205fd25fd2346829efc1fef88b16b18db349688)、[用户态网络 tunnel](https://github.com/Lakr233/vphone-cli/commit/ef93c2970de86693461aa6f7e52f356f7efe2b94)、[virtio 音频实现](https://github.com/Lakr233/vphone-cli/commit/9ad39f1c2298a9658a47bd45e6e3ff812d0ce911)、[实验性显示刷新补丁](https://github.com/Lakr233/vphone-cli/commit/141e114966c433fd2bbd3565129b04d0dfef30c4)。

## 4. 按什么方式合入 Git 历史

### 4.1 以本地分支为起点，按语义形成提交

T00 先采集真实 HEAD、merge-base、已跟踪和未跟踪修改、可用工程及测试入口；T01 保存有意保留的工作，建立隔离 worktree/checkout。建议整合分支名 `integration/upstream-20261006-2d21d21`，若已存在先核对归属。VM、IPSW、导出包、凭据和个人配置不放入源码保存提交。

T02 同时维护两张关联表：

- **能力表：** 上游最终行为、本地等价位置、要保留的差异、处置决定、任务和接受条件。
- **提交表：** 上游 SHA、最终状态是否仍有效、所属任务、本地适配提交、跳过/替代原因、验证证据。检查 merge 解决内容是否已覆盖。

可以直接 `cherry-pick -x` 的，是确认隔离、依赖明确且本地路径和接口基本一致的小提交。涉及目录重构、共享 ABI、固件流水线、进程生命周期和多模式的改动，以固定目标的最终状态为参考做语义移植，并在本地提交注明来源。不要为重现上游过程先引入已被后续修正的缺陷。

每个提交或评审单元只包含一个可验证、可恢复的变化，记录：任务 ID、完整上游 SHA/路径、本地适配差异、验证命令和结果、工件/VM 范围、回退单位。格式化、本地化清理与功能变化分开。冲突逐处解释，不统一选 ours/theirs，不整目录覆盖本地定制。

### 4.2 合并记录与功能覆盖分开

本方案默认采用可追溯的能力移植。T31 完成后，再依据真实分支拓扑决定本地目标分支的整合方式。如果确需让 Git 记录固定上游为已合并祖先，必须在全部适配后审查一次真实 merge 的树差异和冲突，并对变化后的候选复验；不可用 `merge -s ours` 或空提交伪装功能已覆盖。未实施的 T45 和其他显式排除项保留在处置表中。

本轮文档修订未执行上述代码操作。真正实施时读取用户实际仓库的规则；上游单一 JB、宽权限或工程约定不能覆盖用户已有多模式与严格约束。上游当前使用手写 Xcode 工程和 Swift 6 严格并发，不能仅凭根目录 `swift build` 推定 Bundle 已构建完整。来源：[上游工程和构建约定](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/AGENTS.md)。

## 5. 先固定十项接口契约

以下名称是逻辑契约，不预设本地类型或文件名。T02 将它们映射到实际实现；优先扩展已有结构，不新建两套互相矛盾的状态源。

| 编号 | 契约 | 任务 | 必须满足的含义 |
| --- | --- | --- | --- |
| C1 | 模式与冻结计划 | T09–T10 | 输入真实 mode、OS/build、选择和声明；输出经过依赖/冲突/必需项校验的计划。每个实际 patch record 必须归属于被允许声明。 |
| C2 | 持久化与兼容导入 | T11 | 计划绑定 VM、mode、输入来源、schema 和 digest；missing、corrupt、unsupported、legacy 分开。未知状态不取得写盘资格。 |
| C3 | 原件与 generation | T12–T14 | 可信原始输入与派生产物分开，generation 绑定固件、设备、GPU 和计划；新 generation 提交前保留旧原件。 |
| C4 | 离线提交事务 | T15 | 锁、可信路径、clone/完整副本、写入读回、卸载、磁盘发布及记录持久化形成可恢复事务；任一步失败均有确定恢复动作。 |
| C5 | 旧 VM 更新资格 | T16、T33–T35 | 返回可直接更新、需先更新 kernel、需迁移、需重建或拒绝及原因；根据真实布局与证据判定，不根据版本名称猜测。 |
| C6 | 在线安装与激活 | T17 | 验证事务能力与完整响应，区分 legacy；文件安装、进程加载和业务验收分开。自动/手动写入受每 VM 操作规则约束，pending_activation/pending_recovery 是有效状态。 |
| C7 | 分组件应用事实 | T32 | 复用 Receipt/manifest，记录 desired、planned、generated、committed、activated、accepted；实际命中和读回证据不得由 enabled 集合替代。 |
| C8 | DSC 与内核共享区域 | T35 | 内核更新校验候选 kernel+当前 DSC，环境更新校验已证明安装 kernel+候选 DSC。使用真实 base/size/mapping/effective maxSlide；证据缺失拒绝写入。 |
| C9 | 连接代际和自动行为 | T36–T39 | instance 区分重连与 daemon 生命周期；异步操作绑定 generation，无可靠标识时停用相应自动行为；副作用结果未知先读回，不按 request ID 盲目重试。 |
| C10 | 四层来源与兼容性 | T07、T24、T40、T29 | 分别记录 host Bundle、guest environment、kernel、其他 boot chain 和同步策略；版本下限、series 支持策略、协议、ABI、固件分别判断，切 host 不自动授权改 guest。 |

### 5.1 计划、应用记录与真实磁盘状态

上游已引入 Receipt、Drift 和撤销记录，适合作为兼容基础。接入时仍要核实每一步实际结果。固定源码里，部分路径用 resolved plan 的 enabled 集合作为记录来源；共享区域扩容返回值没有在调用处逐项强制成功，流水线其他补丁产生 record 也可能满足较粗的成功检查；安装器还存在按 receipt 或 iOS 27 版本推定区域大小的路线。因此，“计划中存在共享区域补丁”不能证明当前安装内核已经扩容。这是本轮源码静态分析得出的接入风险，尚未在用户 VM 上复现。来源：[Kernel patcher 执行和 records](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/KernelCustomFirmwarePatcher.swift)、[固件流水线成功判定](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Pipeline/FirmwarePipeline.swift)、[CFW 安装器最终实现](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift)。

本地规则为：每个必需补丁要有唯一/可解释命中、实际 patch records 和输出读回；Receipt 关联同一 VM、generation、planDigest、kernel/guest 工件和提交事务。发生部分失败、no-op、记录缺失或记录写入失败时，保持真实状态。no-op 只有在重新验证已有输出后才可补证据；不能无条件登记全部 enabled。

desired → planned → generated → committed → activated → accepted 是六个不同事实。它们不要求新增六套文件：复用既有 plan、manifest、Receipt 与执行日志，把不足的来源和状态补齐。UI/API 只报告已经取得证据的阶段。

### 5.2 原件、事务与撤销的分工

FirmwareOriginals 用于从干净输入重打补丁；事务副本用于失败时恢复磁盘；checkpoint 用于验证同一输入下可续跑；undo 用于从已知当前状态撤销指定修改。四者各自承担不同职责，不能互相替代。

上游 prepare 存在先移除旧 Originals、随后再验证新输入的时序；安装器 clone 不可用时可走原盘路径，Receipt 保存和局部补丁失败也有较宽松的处理。接入时保留旧 generation 到新 generation 完成验证与提交；只允许 clone 或经过验证的完整副本；必需组件失败要阻断整批接受，记录持久化失败进入可恢复状态。跨磁盘、receipt 与配置的多文件提交用恢复日志协调，不声称一次 rename 能保证整组原子性。来源：[prepare 和原件发布](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneFirmwarePreparer.swift)、[CFW 安装器最终实现](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift)。

撤销只允许使用绑定正确原件/输入摘要的 undo 或备份。旧 VM 没有可信备份，或者 `.bak` 已包含旧补丁时，不能靠新选择列表推定旧修改已经去掉。正确结果可以是 `not_revertible` 或需要恢复/重建，但不能报“关闭成功”。来源：[DSC 撤销记录](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/DyldSharedCache/DyldSharedCacheUndoLog.swift)、[CFW 安装器最终实现](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift)。

### 5.3 共享区域修复的准入规则

上游特定 cloudOS 26.4 vphone600 内核共享区域大小为 6 GiB（`0x180000000`）；其研究使用的新 iPhone iOS 27.0.1 DSC 大小 `0x185804000`，即使 slide 为 0 也超出；补丁把区域扩到 7 GiB（`0x1C0000000`），base 不变。适用性及上游验证组合有限，不能推广到全部未来 kernel。来源：[共享区域兼容检查提交](https://github.com/Lakr233/vphone-cli/commit/31b138545da0ab99e0a9d340cc65e8cf2dda3c0b)、[共享区域扩容提交](https://github.com/Lakr233/vphone-cli/commit/ea76afacb6861e92695613ccfc43f4aa8583e8a9)、[共享区域扩容补丁](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/CustomFirmwarePatches/Memory/KernelCustomFirmwarePatchSharedRegionSize.swift)。

T35 用实际 kernel 的 base/size 与 staging 最终 DSC 的 mapping、effective maxSlide 校验；不根据 iOS 版本或选择 ID 猜测。区域检查与 VM RAM、磁盘剩余容量分别处理。未知 kernel、解析失败或扩容未命中，不得按 7 GiB 放行依赖该条件的环境。现有安装流程对 maxSlide 的处理仍保留；恢复 DSC ASLR 单独研究，不混入本轮默认范围。

校验对象必须是**拟提交组合**：T34 更新内核时检查“候选 kernel＋当前 guest DSC”；T16 更新环境时检查“已安装且已证明的 kernel＋候选 DSC”。7 GiB 内核换回 6 GiB，而当前 DSC 已超界时，必须在提交前拒绝，保持磁盘与 Receipt 不变；不能用旧 generation 的证明为新 kernel 放行。

## 6. 分阶段执行和并行边界

| 阶段 | 任务 | 阶段交付与退出条件 |
| --- | --- | --- |
| M0 基线 对账和恢复点 | T00、T01、T02、T03 | 实际基线、能力对账、源码保存点、经过恢复验证的 VM 样本。未拿到本地映射的任务不进入实施。 |
| M1 基础修复 宿主约束和版本绑定 | T04、T05、T06、T07、T08、T24、T40、T46 | 基础修复可单独验收；新宿主入口与 Bundle 绑定受统一权限、身份和版本规则约束。 |
| M2 补丁契约 原件准备和 Hook 策略 | T09、T10、T11、T12、T13、T14、T32、T43 | 五模式、计划、原件、Receipt 和 Hook 的契约一致，形成后续所有写入的共同基础。 |
| M3 写盘事务 环境 内核和固件适配 | T15、T16、T17、T33、T34、T35、T44 | 更新资格和可恢复事务完整；环境、kernel、DSC 及固件设备路径可验证。 |
| M4 客户机控制与既有功能链 | T18、T19、T20、T21、T22、T23、T36、T37、T38、T39 | 原有 guest 能力保留，新控制能力按新旧组合和实例生命周期正确工作。 |
| M5 网络 媒体与管理入口 | T25、T26、T27、T41、T42、T45 | 网络、媒体、CLI/UI 按完整后端能力交付；T45 为可选后续项。 |
| M6 文档与不可变发布候选 | T28、T29 | 文档及证据闭合，形成代码和产物摘要均固定的发布候选。 |
| M7 组合回归 恢复和签收 | T30、T31 | 声明支持范围通过集成回归和实际恢复，记录签收与本地整合决定。 |

阶段是交付分组，**真实执行顺序以任务依赖为准**。T24、T40、T46 已移到早期；T14 在 T13 前；T35 在依赖它的环境、kernel 和新设备链前；T34/T44 的更新与来源能力先于 T16，T34 也先于对应管理入口 T25。T28 的最终闭合依赖所有主线实现项，但每项文档应随代码维护，不能等到最后才写。T45 不进入主线完成依赖。

### 6.1 建议实施批次

1. **先完成 T00→T01→T02，并完成 T03 的受控恢复样本。** 产出真实差异、文件映射和可恢复基线后，才能确定准确改动量。
2. **第一批基础检查点：T04/T05、T06→T07→T08、T24/T46。** 相互独立的模块可以并行；每个语义单元通过其故障场景后留下检查点。T40 随 T05/T24 完成接入；它无需阻止签名或日志单项先交付。
3. **补丁共同基础：T09→T10→T11→T32；T12/T14→T13；T43。** 先评审模式和状态契约，再在共同安装器中整合。不要多人同时各自改出一套 planner、receipt 或事务协议。
4. **更新主线：T15→T33；T35；T34/T44；T16→T17。** 实现层面可按接口分工；实际旧 VM 若缺 kernel 前提，运行路线必须先完成并验收 T34，再执行依赖新区域的 T16/T17。T16 的资格判定不等于自动调用内核更新。T44 先交付设备映射、原件恢复和生成物，完整创建/启动使用 T16/T17 的环境在 T30 接受，避免循环等待。
5. **控制与旧功能：T21→T18→T19；T20/T22/T23；T36–T39。** 核心兼容可先按原机型复验；最终接受包含 T44 声明支持的设备与显示组合。T43 前置交付策略和修补错误路径，完整相机/媒体验收在 T22/T42/T30，不提前标整机通过。
6. **管理和体验：T41、T42、T25–T27。** 网络可先于最终管理入口，媒体须等待完整固件/Hook/权限组合。UI 的最终接受以实际后端状态为依据。
7. **候选与验收：T28→T29→T30→T31。** 冻结源码、依赖与全部产物摘要；按声明范围做组合回归和恢复演练。候选改变后只重测受影响契约和必要发布门槛。

可由三个工作流并行承担“宿主/工具”“固件/事务”“guest/API/媒体”，但共享接口先冻结，共享文件指定单一批次整合点。并行测试使用不同构建目录与独立 VM 副本；同一 VM 的写盘任务必须串行。不得以任务编号连续或提交量大小代替依赖分析。

### 6.2 工作量与检查点

47 项是管理与验收单元，不是 47 个同等成本的提交。T00–T03 属于基线/保护，T28–T31 属于收口验收；复杂实现项可以拆为多个小提交。取得本地映射前不给出看似精确的工期。T02 完成后按“已有等价只需复验、局部适配、跨组件新增、需要 VM 验证”分别估算，优先安排 T15/T32–T35/T42 等跨组件项目。

每个阶段留下四件东西：代码保存点、实际工件清单、范围明确的验收记录、已验证的恢复路径。第一批修复通过即可形成内部可用检查点；只有 T31 完成后才把本轮主线标为完整接受。

## 7. 旧 VM 的实际升级路线

| 检查结果 | 路线 | 完成依据 |
|---|---|---|
| 完整环境、可信来源、内核/DSC 兼容 | 停机环境更新；可在线替换的部分按白名单独立执行 | 事务、Guest receipt、实际加载与业务验收均完成 |
| 旧 kernel 不满足新环境前提，有可信原件与兼容签名容器 | 先停机 update-kernel，重启验证，再更新环境 | kernel 实际证明和启动结果先成立，后续环境独立验收 |
| 已有补丁与新选择不同，有可信 undo/备份 | 在统一事务中撤销/应用 | on→off→on 可复验，最终字节和记录一致 |
| 缺 receipt 但内容和来源可识别 | 先只读审计，补可信证据或进入受控 legacy 迁移 | 不从版本号补写 applied，不默认开启全部补丁 |
| 缺 loader、必需库或加载路径 | 明确完整迁移方案，必要时重建测试实例后迁移数据 | 替换文件无法补足的安装前提得到验证 |
| 原件/undo 不可信、计划损坏或固件不兼容 | 停止写入，恢复可信来源或选择重建 | 不在未知状态下反复原地尝试 |

update-kernel 必须成组参考最初替换和后续原件重打补丁实现，保留目标 IMG4 内 IM4M 及其他 DER 内容，只处理唯一 Preboot kernelcache。它不会自动更新所有其他启动组件。当前上游路径有硬编码 `.jb` 的地方，本地必须读取真实模式并走同一 Gate。来源：[离线 kernel 更新](https://github.com/Lakr233/vphone-cli/commit/fdb00934c34ed188d8a883b286c0f445e9f11535)、[基于原件重打补丁和管理入口](https://github.com/Lakr233/vphone-cli/commit/04a13e47c74ce9dcb01863ff4ded8b1c98f4366c)、[CFW 安装器最终实现](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift)。

在线环境更新以目标 host/guest 的实际白名单和摘要协议为准，旧文档的固定“四库/五库”数量不再作为规格。SpringBoard、launchd 或其他进程仍加载旧库时，即使文件已替换也只能记 `pending_activation`。激活动作按实际加载链和操作范围处理，失败需要恢复文件与运行状态。来源：[guest 在线环境 API](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestAPI+Environment.swift)、[环境载荷公共描述](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestEnvironment.swift)。

本地新增的在线批次恢复契约必须能被明确识别；旧 `environment_update` capability 不足以证明支持事务。仅支持 legacy 行为的 daemon 进入受限兼容或停机路线。请求绑定模式允许的组件集合和计划；返回的 installed、阶段和重启信息必须完整且与请求一致，缺字段、重复/未知项不能采用空数组/false 默认后报成功。guest 报告的 staging 路径也仍需满足本地目录和文件名约束。来源：[guest 在线环境 API](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestAPI+Environment.swift)、[宿主自动同步与环境响应解析](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControlEnvironment.swift)。

部分旧 VM 缺少原始 board DeviceTree。T44 接入从匹配 productType、version、build 的 IPSW manifest/member 恢复原件，绑定 generation，并按调用者权限受控读写。缺必要 tree 影响旧 iPad board audio 或相关 iPhone product repair 时，T16 不接受上游“警告后跳过”作为整机完成。错误 IPSW、无法识别来源或已污染原件必须拒绝恢复。来源：[按固件来源恢复 board DeviceTree](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneArchiveKit/Transfer/VPhoneBoardDeviceTree.swift)、[CFW 安装器最终实现](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift)。

## 8. 新旧版本组合与功能语义

| 组合或场景 | 计划行为 | 验收重点 |
| --- | --- | --- |
| 旧 host + 旧 daemon | 保留用户当前可用组合及恢复点 | 作为原有功能基线，记录真实版本/摘要，不能以历史 SHA 代替。 |
| 新 host + 旧 daemon | 冻结自动 daemon/environment 同步后，验证基础 API；新能力探测后启用 | 先后 hash 不变；缺 screen_unlock/system_shutdown 则禁用；AX nested 验证格式；无 instance 不跨重连复用基线。 |
| 旧 host + 新 daemon | 冻结自动同步后验证既有请求与默认响应；显式回退单独测试 | 无法禁止改写的旧 host 不计纯兼容通过；复验 flat 默认、基础输入、升级确认及认证。 |
| 新 host + 新 daemon | 新能力按配置和前提开放 | host/guest 载荷、ABI、entitlements、激活与每机来源均相符。 |
| 新 Launcher + 旧/新 Core Bundle | 区分代码版本下限与本地支持矩阵 | 上游代码要求 Bundle >=2.6.0；同 major.minor 作为默认支持策略，不能由版本下限推定任意更高 series 都兼容。 |
| 新 Bundle + 旧 guest/kernel | 仅改变宿主运行绑定，显示其他层仍旧或未知 | 不自动写 guest/Preboot，不把“已安装新 Bundle”展示成整机已升级。 |
| 旧 VM 无 receipt/undo | 分类为 legacy/unknown，完成只读识别后决定迁移路线 | 已选配置、版本号或当前文件名均不是实际应用证据；无可信撤销源不承诺关闭旧补丁。 |
| 新 kernel + 旧其他 boot chain | 仅在已验证固件组合内允许 | update-kernel 保留 IM4M，其他 boot chain 版本保持原来源；启动和数据回归必须通过。 |

每 VM Bundle 绑定和 Launcher 行为来自 [每 VM Bundle 绑定](https://github.com/Lakr233/vphone-cli/commit/9205fd25fd2346829efc1fef88b16b18db349688)、[稳定 launcher](https://github.com/Lakr233/vphone-cli/commit/53ce50672e2339898c7463904b12038d2d04b33f)、[Bundle 安装和兼容检查](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift)。固定代码的版本门槛是 **Core Bundle ≥2.6.0**；它没有强制同 series 上限。同 major.minor 是本方案的默认支持策略，跨 series 要额外通过兼容矩阵；不要求 Launchpad 2.6.0 与 Bundle 2.6.1 的 patch 号相同，合法 local/CI 后缀按上游规则解析。

**自动同步必须先纳入版本策略。** 固定上游在 health probe 后、读取 capability/instance 之前，发现 binary hash 不同便可调用 `agent.apply_update`；连接建立后还会自动 `syncEnvironment()`。因此测试组合可能在第一次连接时就被改变，旧 host 也可能反向替换新 daemon/库。本地先冻结每 VM 同步/回退策略，把“禁止改写 guest 的纯兼容”与“明确执行更新/回退”分开，记录前后 daemon/库 hash 和 instance。无法禁止改写的旧 host 不可记作纯兼容测试通过。绑定新旧 Bundle 本身不自动取得修改 guest 的资格。来源：[连接探测和自动 daemon 更新](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControl.swift)、[宿主自动同步与环境响应解析](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControlEnvironment.swift)。

同时，launcher policy 拒绝后，上游调用方可能直接启动原可执行文件。T24 必须验证这条 fallback：合法开发构建缺 launcher 可按既有普通进程规则处理；违反身份、路径、owner 或权限门槛的目标不能借 fallback 绕过本地门控。定位还通过独立 `VPhoneLocation.app` 请求授权，需要核验实际 helper 的签名、usage strings 和生命周期；不能从 launcher 稳定性直接推定定位已正确授权。来源：[launcher 调用方和直接执行回退](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/Command/VPhoneLaunchpadChildProcess.swift)、[独立定位 helper 的授权](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/LocationHelperProcess/main.swift)。

控制协议的几个具体边界必须写入实现与文档：

- **解锁：** `screen.unlock` 是唤醒/状态判断和需要时输入调用方提供的密码，不是密码绕过。历史中间 daemon 可能有 `screen_unlock` 却缺可靠 instance；此时保留手动入口，关闭依赖实例识别的自动流程。同 instance 重连不重复自动解锁，设置切换只影响后续启动。来源：[屏幕解锁状态机](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestScreenUnlock.swift)。
- **停止：** `system.shutdown` 被接受不代表磁盘已经释放。Launchpad 先请求并观察 VM 停止，再按超时回退；直接 CLI stop 的既有语义单列。离线更新和备份都以实际 stopped/无写入者为前提。来源：[guest 有序关机](https://github.com/Lakr233/vphone-cli/commit/58c069f92331663ef6191701e40c3c2eff0cab98)、[宿主停止流程](https://github.com/Lakr233/vphone-cli/commit/8af70697cce947f8c222bc43dcda74e03d6aee05)。
- **AX 层级：** `nested:true` 需要验证 `format`、`relationship_source`、`action_eligible` 等真实响应；只有 `ui_inspection` 或 HTTP 200 不能证明支持嵌套，旧 daemon 可能忽略参数返回 flat。层级是带 partial/诊断状态的快照，节点 ID 不作为持久点击选择器。来源：[原生 AX 层级接口](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestAPI+Hierarchy.swift)、[AX 原生查询实现](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Native/vphoned_ax_hierarchy.m)。
- **剪贴板：** 原有 Cmd C/X/V 同步继续保留。本次新增的是触摸 Copy 与失焦同步；它依赖 instance、changeCount 和 generation 判断新内容。无可靠基线时退回原行为，避免迟到响应覆盖 Mac 内容。来源：[触摸复制和失焦同步](https://github.com/Lakr233/vphone-cli/commit/fe46ee2f65cc35d7559139f393c9427370265459)。
- **应用安装：** vphoned 的 `apps.install` 路径不能证明真正经过 installd 的 Hook 已通过；按项目使用方式分别测试安装、扩展注册、启动和宿主识别。来源：[guest HTTP API 文档](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/Research/vphoned_http_api.md) 与执行清单 T18 的源码范围。

对 daemon/environment/bootstrap 更新与 shutdown 规定每 VM 冲突处理，写操作绑定 operation/generation。上游请求 ID 用于关联响应，API 执行队列可并发，不是请求去重协议；副作用已发生但回复丢失时，先记 unknown outcome 并读回状态，再决定恢复或重试。旧 instance 的解锁或剪贴板异步任务在停止、重连代际改变或功能关闭后失效，图片下载第二段 await 后再次核对。验收增加安装完成丢回复、更新与 Stop 交错、guest 重启后旧异步结果返回三类用例即可，不需要将所有 API 全局串行。来源：[API 并发执行](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestAPI.swift)、[连接探测和自动 daemon 更新](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControl.swift)。

## 9. 网络、设备、媒体和 Hook 如何接入

网络 tunnel 是用户态 IPv4 TCP/UDP，跟随普通宿主 socket 路由；它不承诺通用公网 ICMP 转发。MAC、IP、DNS、gateway、转发和 mDNS 按每机保存，配置改变与需要重启的行为明确分开。特别是上游 `resolvesMacName=nil` 解释为 true，不能声称所有新增可选字段在缺失时都不改变旧行为；T41 先核对本地旧解释再显式迁移。来源：[用户态网络 tunnel](https://github.com/Lakr233/vphone-cli/commit/ef93c2970de86693461aa6f7e52f356f7efe2b94)、[每机网络配置](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/Support/VPhoneNetworking.swift)、[地址和转发设置](https://github.com/Lakr233/vphone-cli/commit/9ab69f8813bfb0d38697685329cbbcf0c6121381)。

新设备路径分别处理 IPSW identity、restore board、运行时 DeviceTree 和显示比例；保留原机型基线。iPad/新 iPhone 列入目录仅表示有候选描述，实际支持必须对应明确 iOS/cloudOS 配对和启动、输入、媒体证据。来源：[设备和固件身份扩展](https://github.com/Lakr233/vphone-cli/commit/80db5ac16419bde153f140a0cbeb92e66fb45724)。

音频/麦克风按完整链交付：固件和 DeviceTree 前提、kernel、virtio HAL、ring/时钟、44.1/48 kHz、VirtualAudio 路由、host 权限与采集生命周期、capture Hook、更新和激活。不能只替换 dylib 就宣布旧 VM 已具备能力。相机的 runtime code patch 竞态修复与 Hook 部署也成组处理。来源：[virtio 音频实现](https://github.com/Lakr233/vphone-cli/commit/9ad39f1c2298a9658a47bd45e6e3ff812d0ce911)、[麦克风接入](https://github.com/Lakr233/vphone-cli/commit/5daa03ee957cfc389a421058000b66e951a7e0f6)、[采集链配套](https://github.com/Lakr233/vphone-cli/commit/571e2ad0e33aea8895ef3e6b58648a3c3f3bc8b3)、[VCam 运行时修补竞态修复](https://github.com/Lakr233/vphone-cli/commit/f5f34505d5e3653140d76289a2efeabc33102d77)。

Hook 保留每模式允许范围与 auth/Irisin 条件。上游针对音量服务的例外按操作/名称过滤/服务名匹配，不能把它描述为已经验证调用者为 SpringBoard。必要兼容例外应限定范围，不扩成通用服务或认证放行。来源：[音量服务查找例外](https://github.com/Lakr233/vphone-cli/commit/50694721e73437fefbd2abde2bff001352a8f40f)。

T43 同时明确负责旧 26.x/18.x guest 所需的 paravirt IOUC kernel 适配及默认选择。实际匹配是 `ApplePar/AppleVid/AppleVir/IOSurfac` 八字节前缀，不能写成四个精确类名的白名单。相机/媒体资格检查要核实这个 kernel 前提；只换环境 dylib 不等于已经补上，缺失时进入 T34 或待迁移状态。来源：[paravirt IOUC kernel 补丁](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/CustomFirmwarePatches/Sandbox/KernelCustomFirmwarePatchParavirtUserClients.swift)。

console 的输出完成 ACK 和分块解析性能修复独立进入早期批次；正确性包括操作归属、尾部输出、panic 识别、顺序、轮换和取消。性能收益只写本地同 fixture 的实测结果。来源：[helper 输出完成确认](https://github.com/Lakr233/vphone-cli/commit/5ecee05d30b685d43b0e1a2ec66ea7f2259fac02)、[console 分块处理性能修复](https://github.com/Lakr233/vphone-cli/commit/da1179396997ddbaaf7198cdf9946ae6b0a56de3)。

ACK 只证明前面的 callback 已处理；当前 LogWriter 异步写入，不能由 ACK 直接推定日志已落入文件。T46 交付完整 helper/client/writer 协议，分别证明输出接收、writer 排空和操作退出；覆盖 ACK 缺失/30 秒超时、XPC 断开、写入失败和收到尾部后立即退出应用。旧 helper 升级或明确拒绝。来源：[helper 输出 ACK 等待](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpadHelper/VPhoneLaunchpadHelperService.swift)、[异步日志写入](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/Application/VPhoneLaunchpadLogWriter.swift)。

## 10. 验收、发布候选与恢复

| 领域 | 必要场景 | 接受条件 |
| --- | --- | --- |
| 历史与本地保留 | 真实 HEAD/WIP；五模式；Hook/auth/Irisin；已通过 prepare/checkpoint/导入导出 | 旧行为有基线；等价项不重写；历史结果与当前复验分列。 |
| 签名与归档 | Mach-O 空间/损坏头；中文/日文/emoji；链接与越界路径；大文件和坏包 | 正确结果或明确拒绝；无目标目录外写入；失败不覆盖有效产物。 |
| 补丁选择 | 旧 ID；显式 off；缺声明/冲突/环；五模式；坏 schema；单项 boot-essential 未命中 | 可解释迁移；unknown 拒绝写盘；其他补丁成功不能掩盖必需项失败。 |
| 原件和缓存 | A→A、A→B→A；新输入失败；GPU/v2；并发/截断/取消/坏缓存 | generation 对应正确；旧原件保留；缓存不混入 VM 身份和凭据。 |
| 磁盘事务 | VM 忙；锁竞争；clone/容量/挂载失败；磁盘交换和 receipt 写入前后中断 | 无原盘降级；恢复日志可决定一致状态；实际恢复后能启动并读回数据。 |
| 旧 VM 迁移 | 完整/不完整安装；缺 loader/lib；坏/缺 receipt；有/无 undo；共享区不兼容 | 正确进入更新、先更新 kernel、受控迁移或拒绝；无备份不报已撤销。 |
| kernel/DSC | 唯一/零/多 Preboot 候选；IM4M；6/7 GiB；缩回而 DSC 超界；不同 generation；0/多命中 | 拟提交组合兼容；缩回不兼容时提交前拒绝；实际字节与记录一致，不靠版本推定。 |
| 在线更新 | 旧能力/缺字段/未知组件；多文件部分失败；成功后丢回复；与 Stop 交错；旧库仍加载 | 契约识别严格；文件、激活、业务验收分离；结果未知先读回；批次可恢复。 |
| 协议与 lifecycle | 大响应/慢读/取消；worker/proxy 退出；冻结自动更新的新旧组合；instance 变更后晚响应 | 兼容测试没有改写 guest；无孤儿连接；升级确认可靠；旧任务不在新实例生效。 |
| 解锁/停止/AX/剪贴板 | Setup Assistant、手动/自动 unlock；accepted/实际 stopped；nested/flat；触摸 Copy/慢响应/切窗 | 能力不足明确降级；未验证密码路径如实标记；snapshot ID 不作稳定选择器；旧剪贴板不回流。 |
| 原有 guest 功能 | apps.install 与实际 installd 分测；UDID set/clear/reboot；定位 fresh readback；RootHide/Irisin | 权限、身份、包状态和目标应用保持；各链路独立证明。 |
| Bundle 与管理 | 缺绑定/坏签名/owner；多 VM/同名；clone/export；批量失败/取消；Launcher series | 定位正确、来源准确、版本不静默漂移；半成品不标成功。 |
| 设备与网络 | 原 iPhone；声明支持 iPad/新 iPhone；2x/3x；NAT/tunnel/bridged/none；MAC/IP/转发/mDNS | 按实测组合声明支持；缺省字段不无意变更旧机行为；无意外 LAN 暴露和跨 VM 清理。 |
| 媒体与 Hook | 预览/拍照；44.1/48 kHz；录放/双工；权限拒绝；重复启停；代码页失败 | 按完整组件组合稳定工作；进程/线程/保护状态可恢复；原五模式策略保持。 |
| console 和恢复 | 随机分块/尾行/ANSI/panic/并发/轮换；ACK 超时/XPC 断开/writer 失败/立即退出；分层和整组恢复 | 接收、writer 排空和退出分开证明；每类恢复边界明确；至少一次整组恢复成功。 |

### 10.1 支持范围的定义

所有五模式都执行策略测试；实际 VM 测试覆盖计划声明支持的 mode × 固件/device × 新建/旧机迁移组合，再叠加有风险的 host/guest/ABI 混用场景。采用有依据的代表组合与风险覆盖，不要求没有意义的全排列。任何未测组合都写为 `not_run` 或候选，不记 pass；不适用场景给理由。

T29 候选清单固定本地 SHA、上游 SHA、精确依赖、构建工具链、host/guest/kernel/其他启动组件摘要、配置 schema、模式支持和补丁证明。T30/T31 结果必须对应同一清单。只改版本号、build 成功、文件复制成功或 API 返回成功都不足以替代运行验收。

### 10.2 构建与测试安排

任务清单列出已核对的上游测试入口，包括 FirmwarePatcherTests、VPhoneSignTests、VPhoneCoreKitTests、VPhoneArchiveKitTests、原生 AX 测试以及完整 Bundle 构建。它们是移植参照；T02 必须在本地映射实际工程、scheme、SDK 和命令。daemon 目标按 guest SDK 构建，不伪造 macOS 测试目的地。Release/签名与运行依赖闭包还需实物检查；仅 Debug 编译不能替代最终产物验收。来源：[上游工程和构建约定](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/AGENTS.md)。

测试补充围绕有实质风险的契约和故障，不为纯翻译、文档编辑或可逆小 UI 改动编写机械测试。通过后按影响范围收敛复验；没有新的风险或必要门槛就不无上限扩大测试。

### 10.3 恢复单位和停止条件

| 变更 | 恢复单位 | 恢复成功依据 |
|---|---|---|
| 仅源码/宿主 | 本地提交、签名应用/helper、Bundle、绑定与对应配置 | 原组合启动和通信恢复；不推定 guest 已恢复 |
| 在线/离线环境 | 整组 guest 文件、加载配置、Preboot repair、Guest receipt/undo、进程状态 | 实际加载与目标应用恢复 |
| kernel 更新 | 原 kernel IMG4、磁盘/事务副本、kernel receipt/计划 | 原 IM4M/容器来源、启动和关键数据恢复 |
| 设备/共享区域/媒体组合 | 关联 DeviceTree/kernel/DSC/路由/载荷和来源记录 | 恢复为经过验证的兼容组合 |
| 完整迁移 | 保身份磁盘、NVRAM/SEP/配置/原件/记录与宿主工件 | 实际启动、身份/信任、通信、应用及关键数据恢复 |

存在计划不能解释、原件不可信、备份未验证、空间不够、组件不兼容或实际字节不确定时，停止相应写入。T03 的备份要真实恢复一次，T31 再执行当前候选的整组恢复。保身份恢复和并发测试克隆分开；验收前不清理唯一备份、原件或有效 VM。

## 11. 旧 32 项映射和新增 15 项

保留 T00–T31 编号，便于追溯原 TODO；调整标题、阶段和依赖。原编号关联到新增任务表示范围拆分或加强，不表示原任务已经完成或被删除。

| 编号 | 旧标题 | 修订标题 | 新增关联 |
| --- | --- | --- | --- |
| T00 | 采集真实本地和上游固定基线 | 冻结上游目标并采集真实本地基线 | 沿用同一编号 |
| T01 | 保存未提交工作并建立适配起点 | 保存本地工作并建立隔离整合分支 | 沿用同一编号 |
| T02 | 对账原计划和本地等价实现 | 建立能力对账和逐提交处置台账 | 沿用同一编号 |
| T03 | 验证容量、VM 一致备份及迁移 fixture | 验证停机一致备份和迁移样本 | 沿用同一编号 |
| T04 | 适配原生签名空间修复 | 复核并适配 Mach O 签名空间修复 | 沿用同一编号 |
| T05 | 接入 UTF-8 归档并保留路径安全 | 接入 UTF8 归档并保持路径保护 | 沿用同一编号 |
| T06 | 迁入完整响应和关闭时序修复 | 接入完整响应与连接关闭修复 | T37 |
| T07 | 适配 worker 重试和升级退出语义 | 接入 worker 重试与升级确认 | T36、T37 |
| T08 | 锁定 IcliKit 0.7.7 并对照接口 | 将 IcliKit 候选调整为固定 0.7.16 | 沿用同一编号 |
| T09 | 建立补丁 ID／预设迁移清单 | 修订补丁 ID 预设与旧配置迁移 | 沿用同一编号 |
| T10 | 实现 VariantPolicy 和严格执行 Gate | 复用声明体系并强化五模式执行 Gate | T32、T35 |
| T11 | 实现计划持久化、迁移与 fail-closed | 修订计划持久化和损坏状态处理 | T32、T33、T35 |
| T12 | 把固件原件纳入 generation／检查点 | 将 FirmwareOriginals 接入既有 generation 和检查点 | T34 |
| T13 | 适配原生 prepare 的 GPU/v2 与原件生命周期 | 接入原生 prepare GPU 和 staging 提交 | T44 |
| T14 | 实现共享 IPSW/GPU 缓存边界 | 复用共享 IPSW GPU 缓存并保留权限边界 | 沿用同一编号 |
| T15 | 强化 CFW 写盘事务及锁 | 强化离线写盘事务及崩溃恢复 | T32、T33、T34、T35 |
| T16 | 实现停机环境更新资格和旧 VM 路由 | 修订旧 VM 停机环境更新资格 | T33、T34 |
| T17 | 实现在线环境替换与实际激活状态 | 接入在线更新并区分文件安装与实际激活 | T32 |
| T18 | 整合 MISFix 与应用安装／启动 | 保留 MISFix 安装启动并补齐应用注册 | 沿用同一编号 |
| T19 | 整合 UDID、宿主识别与回退 | 保留 UDID 与宿主识别独立验收 | 沿用同一编号 |
| T20 | 改造定位链路并隔离旧 Hook | 保留定位主线并核验真实权限归属 | 沿用同一编号 |
| T21 | 核对并适配 RootHide／Irisin 基础设施 | 保留 RootHide Irisin 和既有认证状态 | T43 |
| T22 | 按最终组件组合适配相机 | 按组合适配相机并纳入新稳定性修正 | T42、T43 |
| T23 | 整合输入、多指、旋转及 headless | 扩展输入旋转键盘和 headless 控制 | T36、T38、T39、T44、T45 |
| T24 | 复核宿主安全与构建实物 | 前置宿主安全构建与 launcher 约束 | T40、T42、T43 |
| T25 | 整合 Launchpad CLI 和批量管理 | 扩展 Launchpad CLI 与批量操作状态 | T37、T40、T41、T46 |
| T26 | 迁入最新 2.2.3 的界面尾部修复 | 保留旧 UI 尾项并接入目标管理界面 | T44、T45、T46 |
| T27 | 整理 UI Inspector 和遗留入口 | 修订 Inspector 及旧自动化入口去留 | T36、T38、T39、T40 |
| T28 | 同步 API 文档与执行台账 | 同步接口文档来源与执行证据 | 沿用同一编号 |
| T29 | 完成组合兼容与发布候选检查 | 组装发布候选并检查版本组合 | 沿用同一编号 |
| T30 | 执行集成回归与故障注入 | 执行声明范围的集成回归和故障注入 | 沿用同一编号 |
| T31 | 演练整组回滚并签收 | 完成整组恢复演练与整合签收 | 沿用同一编号 |

| 新增编号 | 任务 | 阶段 | 本轮范围 |
| --- | --- | --- | --- |
| T32 | 接入分组件 Receipt 并增加实际应用证据 | M2 | 主线 |
| T33 | 接入 guest 补丁撤销并界定旧 VM 边界 | M3 | 主线 |
| T34 | 接入保留数据的离线 kernel 更新 | M3 | 主线 |
| T35 | 成组接入共享区域检查与扩容证明 | M3 | 主线 |
| T36 | 接入 daemon 实例标识与可选启动解锁 | M4 | 主线 |
| T37 | 接入有序关机和可观察停止回退 | M4 | 主线 |
| T38 | 接入原生 AX 嵌套诊断及旧 guest 识别 | M4 | 主线 |
| T39 | 增补触摸复制和窗口失焦剪贴板同步 | M4 | 主线 |
| T40 | 接入每机 Bundle 绑定与四层版本来源 | M1 | 主线 |
| T41 | 接入 tunnel 和每机网络配置 | M5 | 主线 |
| T42 | 成组整合音频麦克风及权限链 | M5 | 主线 |
| T43 | 逐项适配 Hook 门控和运行时修补 | M2 | 主线 |
| T44 | 接入设备固件身份与旧 board 原件恢复 | M3 | 主线 |
| T45 | 隔离实验性 120 Hz 与 FPS 功能 | M5 | 可选延后 |
| T46 | 独立接入 console 性能与输出完成确认 | M1 | 主线 |

## 12. 状态填写和执行起点

当前主线任务统一 `pending_local_audit`；T45 为 `deferred_optional`。对账后使用 `pending → in_progress → implemented → built → vm_verified → accepted`，必要时记录 `blocked`、`not_applicable` 或有理由的 `deferred`。纯文档/无需 VM 的项可以注明不适用阶段；历史证据、实现提交、当前验收字段分开填写。只有符合接受条件的任务才勾选。

后续实际执行从 **T00–T03** 开始，随后按第一批基础检查点推进。真实本地映射、实现提交和 VM 结果留空是有意保留的执行信息，并非用假设代填。更新本台账时保留旧编号、处置决定、完整 SHA、准确路径和证据范围。

本轮主线要求覆盖 46 项，其中也包括基线、保护、文档和验收任务；不等于 46 个新增功能。T45 可单独延后，外部 root 可执行 patchset、恢复 DSC ASLR、未经测试机型/固件、超出当前协议的额外功能也不因目标变更而自动取得支持承诺。

## 附录：关键上游来源

所有 blob 链接固定在 `2d21d21fbdd4f51f013616273ceda9b35a3e0789`；commit 链接用于追溯变更来源，实施规格仍以固定目标最终状态为准。源码事实、上游验证报告、本地设计要求和本地实测结果在本文中分别标明。本轮没有把上游发布说明直接转成本地验收结论。

- [固定整合目标](https://github.com/Lakr233/vphone-cli/commit/2d21d21fbdd4f51f013616273ceda9b35a3e0789)
- [2.6.1 发布锚点](https://github.com/Lakr233/vphone-cli/commit/f9ea9015a82d29187d4b65cc15883d9bdc37a21c)
- [上游工程和构建约定](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/AGENTS.md)
- [CFW 安装器最终实现](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift)
- [prepare 和原件发布](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneFirmwarePreparer.swift)
- [补丁计划和 Receipt 存储](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhonePatchPresetStore.swift)
- [补丁差异判定](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/FirmwarePatchDrift.swift)
- [Kernel patcher 执行和 records](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/KernelCustomFirmwarePatcher.swift)
- [固件流水线成功判定](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Pipeline/FirmwarePipeline.swift)
- [共享区域扩容补丁](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/CustomFirmwarePatches/Memory/KernelCustomFirmwarePatchSharedRegionSize.swift)
- [共享区域兼容检查提交](https://github.com/Lakr233/vphone-cli/commit/31b138545da0ab99e0a9d340cc65e8cf2dda3c0b)
- [共享区域扩容提交](https://github.com/Lakr233/vphone-cli/commit/ea76afacb6861e92695613ccfc43f4aa8583e8a9)
- [DSC 撤销记录](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/DyldSharedCache/DyldSharedCacheUndoLog.swift)
- [离线 kernel 更新](https://github.com/Lakr233/vphone-cli/commit/fdb00934c34ed188d8a883b286c0f445e9f11535)
- [基于原件重打补丁和管理入口](https://github.com/Lakr233/vphone-cli/commit/04a13e47c74ce9dcb01863ff4ded8b1c98f4366c)
- [Receipt 和撤销集成](https://github.com/Lakr233/vphone-cli/commit/a153e9ddc46d1af522acb167fff4b9518eebcd1f)
- [daemon 的精确依赖锁](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/VPhoneDaemon.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)
- [guest 在线环境 API](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestAPI+Environment.swift)
- [环境载荷公共描述](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestEnvironment.swift)
- [连接探测和自动 daemon 更新](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControl.swift)
- [宿主自动同步与环境响应解析](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControlEnvironment.swift)
- [API 并发执行](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestAPI.swift)
- [按固件来源恢复 board DeviceTree](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneArchiveKit/Transfer/VPhoneBoardDeviceTree.swift)
- [paravirt IOUC kernel 补丁](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/CustomFirmwarePatches/Sandbox/KernelCustomFirmwarePatchParavirtUserClients.swift)
- [guest HTTP API 文档](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/Research/vphoned_http_api.md)
- [原生 AX 层级接口](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestAPI+Hierarchy.swift)
- [AX 原生查询实现](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Native/vphoned_ax_hierarchy.m)
- [屏幕解锁状态机](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestScreenUnlock.swift)
- [触摸复制和失焦同步](https://github.com/Lakr233/vphone-cli/commit/fe46ee2f65cc35d7559139f393c9427370265459)
- [guest 有序关机](https://github.com/Lakr233/vphone-cli/commit/58c069f92331663ef6191701e40c3c2eff0cab98)
- [宿主停止流程](https://github.com/Lakr233/vphone-cli/commit/8af70697cce947f8c222bc43dcda74e03d6aee05)
- [每 VM Bundle 绑定](https://github.com/Lakr233/vphone-cli/commit/9205fd25fd2346829efc1fef88b16b18db349688)
- [Bundle 安装和兼容检查](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift)
- [稳定 launcher](https://github.com/Lakr233/vphone-cli/commit/53ce50672e2339898c7463904b12038d2d04b33f)
- [launcher 路径及操作约束](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadLauncherPolicy.swift)
- [launcher 调用方和直接执行回退](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/Command/VPhoneLaunchpadChildProcess.swift)
- [独立定位 helper 的授权](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/LocationHelperProcess/main.swift)
- [每机网络配置](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/Support/VPhoneNetworking.swift)
- [用户态网络 tunnel](https://github.com/Lakr233/vphone-cli/commit/ef93c2970de86693461aa6f7e52f356f7efe2b94)
- [地址和转发设置](https://github.com/Lakr233/vphone-cli/commit/9ab69f8813bfb0d38697685329cbbcf0c6121381)
- [设备和固件身份扩展](https://github.com/Lakr233/vphone-cli/commit/80db5ac16419bde153f140a0cbeb92e66fb45724)
- [virtio 音频实现](https://github.com/Lakr233/vphone-cli/commit/9ad39f1c2298a9658a47bd45e6e3ff812d0ce911)
- [麦克风接入](https://github.com/Lakr233/vphone-cli/commit/5daa03ee957cfc389a421058000b66e951a7e0f6)
- [采集链配套](https://github.com/Lakr233/vphone-cli/commit/571e2ad0e33aea8895ef3e6b58648a3c3f3bc8b3)
- [VCam 运行时修补竞态修复](https://github.com/Lakr233/vphone-cli/commit/f5f34505d5e3653140d76289a2efeabc33102d77)
- [音量服务查找例外](https://github.com/Lakr233/vphone-cli/commit/50694721e73437fefbd2abde2bff001352a8f40f)
- [实验性显示刷新补丁](https://github.com/Lakr233/vphone-cli/commit/141e114966c433fd2bbd3565129b04d0dfef30c4)
- [helper 输出完成确认](https://github.com/Lakr233/vphone-cli/commit/5ecee05d30b685d43b0e1a2ec66ea7f2259fac02)
- [console 分块处理性能修复](https://github.com/Lakr233/vphone-cli/commit/da1179396997ddbaaf7198cdf9946ae6b0a56de3)
- [helper 输出 ACK 等待](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpadHelper/VPhoneLaunchpadHelperService.swift)
- [异步日志写入](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/Application/VPhoneLaunchpadLogWriter.swift)
