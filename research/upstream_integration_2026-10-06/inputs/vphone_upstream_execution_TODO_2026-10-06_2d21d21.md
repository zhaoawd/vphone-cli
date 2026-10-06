# vphone-cli 固定上游整合：执行 TODO

**日期：2026-10-06｜目标：`2d21d21fbdd4f51f013616273ceda9b35a3e0789`｜47 项：46 项主线、1 项可选。**

**Goal：** 在本地 fork 上整合固定上游最终行为，保留五模式、Hook/auth/Irisin、严格权限和已有 prepare/事务工作，并完成可验证的迁移与恢复。

**Architecture：** 以真实本地实现为基础做能力对账；复用计划/Receipt/manifest、generation 和事务结构；统一模式、补丁证明、生命周期与四层版本来源契约；各功能按完整组件组合接入。

**Tech Stack：** 上游为 Swift 6 严格并发、手写 Xcode 工程、C/Objective-C guest 组件、Apple Virtualization、固件/IM4P/IMG4/DSC 处理。实际本地工程和测试入口由 T02 映射。产品运行时不新增 Python/Homebrew 依赖。

**Spec：** [总体方案与理由](sandbox:/workspace/scratch/b516258d298d/plan_revision/vphone_upstream_merge_plan_2026-10-06_2d21d21.md)。结构化数据：[任务台账 JSON](sandbox:/workspace/scratch/b516258d298d/plan_revision/vphone_upstream_integration_tasks_2026-10-06_2d21d21.json)。

**执行状态：** 文档已修订；本地源码、构建、VM 操作均尚未在本轮执行。`pending_local_audit` 仅表示尚待当前目标的本地核对，不意味着本地没有等价实现。

## 执行规则

1. 固定完整目标 SHA；main 前移另列增量。原 T00–T31 必须有去向，保留历史通过证据。
2. 先采集实际本地基线并保存工作；逐项查找等价实现，T02 映射真实修改/新增/测试文件后再实施。
3. 保留 `regular/dev/jb/exp/less`，不把 regular/exp 与上游 standard/experimental 等同；本地 auth/Hook/Irisin、权限、路径和事务规则优先。
4. 新写盘入口只能使用统一 Gate、可信原件、已验证恢复点和事务；clone/完整副本都不可用则拒绝。
5. 一项 API 返回、版本号、enabled 集合、文件已复制都不是全部生效证据；记录实际字节、来源、激活和业务验收。
6. 按语义形成小提交并记录上游来源；不整目录覆盖，不批量机械 cherry-pick，不统一 ours/theirs。
7. 每项依赖是最终接受前提；可提前做独立调查或基础实现，但不能把未满足前提的组合标通过。共享文件与同一 VM 写盘串行。
8. P0 是安全/状态/恢复/发布门槛，P1 是功能主线，P2 是可后置管理项；只有 T45 明确排除本轮主线。

## 最先检查的五类风险

- 旧 VM 缺 receipt/undo：unknown 或 not_revertible 不得被自动转换为“未打补丁”或“已关闭”。
- `.jb` 硬编码、按 iOS 版本推定 7 GiB、单项 boot-essential 未命中仍被其他 records 掩盖：必须接入真实模式和字节证明。
- clone 失败写原盘、旧 Originals 过早删除、多文件提交中断：必须进入确定恢复路径。
- 新 host 连接旧 daemon：能力/响应格式/instance 分别判断；accepted 不等于 stopped，files_installed 不等于 activated。
- 仅换 Bundle 或 kernel：来源只更新实际改动层，不自动抬升 guest 和其他 boot chain。

## 阶段与状态

`pending_local_audit → pending → in_progress → implemented → built → vm_verified → accepted`。已等价项可以经过针对性复核和回归直接取得相应证据，不要求制造新实现提交。阻塞记 `blocked`；不适用或延后注明理由、影响和原编号。仅满足接受条件后勾选；提交、部署、验收、合并和发布状态分别记录。

T00→T01→T02 后准备 T03；基础批次为 T04/T05、T06→T07→T08、T24/T46，T40 随其依赖完成。T09–T14/T32/T43 完成共享契约，随后 T15–T17/T33–T35/T44。后续具体顺序以依赖表为准。阶段分组不是强制一项不漏的串行栅栏。

| ID | 阶段 | 优先级 | 任务 | 前置 | 范围 | 当前状态 |
| --- | --- | --- | --- | --- | --- | --- |
| T00 | M0 | P0 | 冻结上游目标并采集真实本地基线 | 无 | 主线 | pending_local_audit |
| T01 | M0 | P0 | 保存本地工作并建立隔离整合分支 | T00 | 主线 | pending_local_audit |
| T02 | M0 | P0 | 建立能力对账和逐提交处置台账 | T00, T01 | 主线 | pending_local_audit |
| T03 | M0 | P0 | 验证停机一致备份和迁移样本 | T01, T02 | 主线 | pending_local_audit |
| T04 | M1 | P0 | 复核并适配 Mach O 签名空间修复 | T02 | 主线 | pending_local_audit |
| T05 | M1 | P0 | 接入 UTF8 归档并保持路径保护 | T02 | 主线 | pending_local_audit |
| T06 | M1 | P0 | 接入完整响应与连接关闭修复 | T02 | 主线 | pending_local_audit |
| T07 | M1 | P0 | 接入 worker 重试与升级确认 | T06 | 主线 | pending_local_audit |
| T08 | M1 | P1 | 将 IcliKit 候选调整为固定 0.7.16 | T02, T06, T07 | 主线 | pending_local_audit |
| T24 | M1 | P0 | 前置宿主安全构建与 launcher 约束 | T02 | 主线 | pending_local_audit |
| T40 | M1 | P1 | 接入每机 Bundle 绑定与四层版本来源 | T02, T05, T24 | 主线 | pending_local_audit |
| T46 | M1 | P1 | 独立接入 console 性能与输出完成确认 | T02, T24 | 主线 | pending_local_audit |
| T09 | M2 | P0 | 修订补丁 ID 预设与旧配置迁移 | T02, T24 | 主线 | pending_local_audit |
| T10 | M2 | P0 | 复用声明体系并强化五模式执行 Gate | T09 | 主线 | pending_local_audit |
| T11 | M2 | P0 | 修订计划持久化和损坏状态处理 | T10 | 主线 | pending_local_audit |
| T12 | M2 | P0 | 将 FirmwareOriginals 接入既有 generation 和检查点 | T03, T11 | 主线 | pending_local_audit |
| T13 | M2 | P1 | 接入原生 prepare GPU 和 staging 提交 | T12, T14 | 主线 | pending_local_audit |
| T14 | M2 | P1 | 复用共享 IPSW GPU 缓存并保留权限边界 | T02, T05, T24 | 主线 | pending_local_audit |
| T32 | M2 | P0 | 接入分组件 Receipt 并增加实际应用证据 | T10, T11 | 主线 | pending_local_audit |
| T43 | M2 | P0 | 逐项适配 Hook 门控和运行时修补 | T02, T03, T09, T10, T24 | 主线 | pending_local_audit |
| T15 | M3 | P0 | 强化离线写盘事务及崩溃恢复 | T03, T04, T11, T24, T32 | 主线 | pending_local_audit |
| T16 | M3 | P0 | 修订旧 VM 停机环境更新资格 | T08, T12, T15, T33, T34, T35, T43, T44 | 主线 | pending_local_audit |
| T17 | M3 | P0 | 接入在线更新并区分文件安装与实际激活 | T07, T08, T16, T32 | 主线 | pending_local_audit |
| T33 | M3 | P0 | 接入 guest 补丁撤销并界定旧 VM 边界 | T15, T32 | 主线 | pending_local_audit |
| T34 | M3 | P0 | 接入保留数据的离线 kernel 更新 | T12, T15, T32, T35 | 主线 | pending_local_audit |
| T35 | M3 | P0 | 成组接入共享区域检查与扩容证明 | T03, T10, T11, T32 | 主线 | pending_local_audit |
| T44 | M3 | P1 | 接入设备固件身份与旧 board 原件恢复 | T09, T10, T13, T15, T35 | 主线 | pending_local_audit |
| T18 | M4 | P1 | 保留 MISFix 安装启动并补齐应用注册 | T04, T11, T16, T17, T21 | 主线 | pending_local_audit |
| T19 | M4 | P1 | 保留 UDID 与宿主识别独立验收 | T18 | 主线 | pending_local_audit |
| T20 | M4 | P1 | 保留定位主线并核验真实权限归属 | T08, T16, T17, T24, T40 | 主线 | pending_local_audit |
| T21 | M4 | P1 | 保留 RootHide Irisin 和既有认证状态 | T08, T16, T43 | 主线 | pending_local_audit |
| T22 | M4 | P1 | 按组合适配相机并纳入新稳定性修正 | T06, T11, T16, T17, T43 | 主线 | pending_local_audit |
| T23 | M4 | P1 | 扩展输入旋转键盘和 headless 控制 | T06, T08, T11, T44 | 主线 | pending_local_audit |
| T36 | M4 | P1 | 接入 daemon 实例标识与可选启动解锁 | T06, T07, T08, T23 | 主线 | pending_local_audit |
| T37 | M4 | P1 | 接入有序关机和可观察停止回退 | T06, T07, T24, T40 | 主线 | pending_local_audit |
| T38 | M4 | P1 | 接入原生 AX 嵌套诊断及旧 guest 识别 | T08, T23, T24 | 主线 | pending_local_audit |
| T39 | M4 | P1 | 增补触摸复制和窗口失焦剪贴板同步 | T06, T23, T36 | 主线 | pending_local_audit |
| T25 | M5 | P1 | 扩展 Launchpad CLI 与批量操作状态 | T05, T15, T23, T24, T34, T37, T40, T41, T44, T46 | 主线 | pending_local_audit |
| T26 | M5 | P2 | 保留旧 UI 尾项并接入目标管理界面 | T25, T40 | 主线 | pending_local_audit |
| T27 | M5 | P2 | 修订 Inspector 及旧自动化入口去留 | T08, T23, T25, T38, T40 | 主线 | pending_local_audit |
| T41 | M5 | P1 | 接入 tunnel 和每机网络配置 | T06, T08, T16, T17, T24, T40 | 主线 | pending_local_audit |
| T42 | M5 | P1 | 成组整合音频麦克风及权限链 | T16, T17, T22, T24, T35, T40, T43, T44 | 主线 | pending_local_audit |
| T45 | M5 | P2 | 隔离实验性 120 Hz 与 FPS 功能 | T10, T23, T34, T44 | 可选 | deferred_optional |
| T28 | M6 | P1 | 同步接口文档来源与执行证据 | T04–T27、T32–T44、T46（全部主线实现项） | 主线 | pending_local_audit |
| T29 | M6 | P0 | 组装发布候选并检查版本组合 | T28 | 主线 | pending_local_audit |
| T30 | M7 | P0 | 执行声明范围的集成回归和故障注入 | T03, T29 | 主线 | pending_local_audit |
| T31 | M7 | P0 | 完成整组恢复演练与整合签收 | T30 | 主线 | pending_local_audit |

## 任务细目


## M0 · 基线 对账和恢复点

### [ ] T00 · 冻结上游目标并采集真实本地基线

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** 无

**旧项关联：** T00。原标题：采集真实本地和上游固定基线。

**接口与产出：** 产出 baseline.json：实际 localHEAD、工作区分类、mergeBase、固定 upstreamTarget、三段提交范围、工具版本；历史 SHA 不作为当前本地状态。

**上游范围：**
- [AGENTS.md](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/AGENTS.md)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 在实际仓库读取本地 AGENTS 和文档约定；记录 pwd、git status、remote 和分支，不改变现有工作区。
2. 验证 9d218de、a969cd5、2d21d21 对象及祖先关系；获取对象时使用独立 upstream remote，不覆盖 origin。
3. 分别采集上游历史段、上游新增段、本地分叉及未提交变更；记录未跟踪文件清单和需要保留的忽略文件。
4. 登记 macOS、Xcode、实际构建/测试入口和可用 VM fixture；main 再前移只另列增量。

**接受条件：**
- 固定目标必须是完整 2d21d21 SHA；本地 HEAD、merge-base 来自实际命令。
- 124/122、218/158、342/280 三组提交统计可复算；357/280 文件统计只属于新增段。
- 没有把历史 ef6f408 或旧验收描述冒充当前本地检查。

**验证入口：** `baseline`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 只读采集不改变源码或 VM；对象缺失时停止后续移植，不更换目标凑数。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T01 · 保存本地工作并建立隔离整合分支

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T00

**旧项关联：** T01。原标题：保存未提交工作并建立适配起点。

**接口与产出：** 产出可恢复的 localBaseline 与 integration/upstream-20261006-2d21d21 工作分支；分支名为建议，存在时先核对归属。

**上游范围：**
实际本地仓库、历史工作和证据。该任务先采集信息，不预设虚构源码路径。

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 按 prepare、检查点、测试、文档等语义保存已跟踪修改，并备份需要保留的未跟踪实际内容。
2. 先扫描拟提交列表，排除 VM、IPSW、凭据、导出包及个人配置；不使用 git add .。
3. 从保存后的本地基线创建隔离 worktree/checkout，验证原工作目录保持原有内容。
4. 记录本地恢复引用和内容备份；尚未验证的本地修改保留 WIP 身份。

**接受条件：**
- 源码保存点包含暂存、未暂存及所需未跟踪内容；diff 清单与备份相符。
- 隔离分支基于实际本地基线，不基于纯上游目标重建而遗漏定制。

**验证入口：** `baseline`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 回到本地保存点或取回内容备份；不自动 reset、clean、删除旧分支或推送远端。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T02 · 建立能力对账和逐提交处置台账

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T00, T01

**旧项关联：** T02。原标题：对账原计划和本地等价实现。

**接口与产出：** 产出 capability-ledger 与 local-path-map；每项上游能力有本地位置、处置决定、依赖和验证入口。

**上游范围：**
实际本地仓库、历史工作和证据。该任务先采集信息，不预设虚构源码路径。

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 对原 T00–T31、当前本地代码及上游最终状态逐项判定 equivalent、adapt、new、superseded、deferred 或 unknown。
2. 将上游 342 个提交纳入历史范围核对；优先细审新增 158 个非合并提交，并检查合并提交是否另含冲突解决。
3. 为每个准备实施的任务解析真实本地修改/新增/测试路径和模块所有者，冻结其接口映射。
4. 保留原通过记录及其 SHA/fixture 范围；受此次改动影响的项目新增复验要求，不抹掉历史状态。

**接受条件：**
- 所有原任务都有去向；已等价实现可通过复验交付，不重复开发。
- 任一进入实施的任务都能定位真实文件和测试入口；unknown 不能转成缺失或已完成。
- 格式化、文档、发布元数据和被后续修正替代的提交都有明确处置理由。

**验证入口：** `baseline`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 只更新处置台账；不凭提交数量自动批量 cherry-pick。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T03 · 验证停机一致备份和迁移样本

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T01, T02

**旧项关联：** T03。原标题：验证容量、VM 一致备份及迁移 fixture。

**接口与产出：** 产出恢复清单：VM 身份、固件、磁盘、NVRAM/SEP、配置、原件、计划、receipt、guest 载荷和宿主版本。

**上游范围：**
- [VPhoneKit/VPhoneCoreKit/VirtualMachine/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/VirtualMachine/)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 选择现有稳定 VM 作为受控样本，确认停止、无磁盘写入者并记录容量需求。
2. 制作保身份恢复点；另行创建需要并发运行的测试克隆并处理其身份与网络冲突。
3. 在测试位置执行一次真实恢复并验证启动、通信、目标应用和关键数据。
4. 列出五模式策略 fixture 和实际声明支持的固件/新建/迁移组合。

**接受条件：**
- 至少一个恢复点经过实际恢复，不只验证导出命令成功。
- 恢复与克隆的身份策略分开；无唯一原件或唯一备份先删除腾空间。

**验证入口：** `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 保留原 VM 和已验证恢复点；失败样本隔离，停止写盘批次。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。


## M1 · 基础修复 宿主约束和版本绑定

### [ ] T04 · 复核并适配 Mach O 签名空间修复

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T02

**旧项关联：** T04。原标题：适配原生签名空间修复。

**接口与产出：** 输入受支持 Mach-O，输出可验证的签名结果或明确错误；回收顺序保留 LC_SOURCE_VERSION 后 LC_UUID 的规则。

**上游范围：**
- [VPhoneExecutable/VPhoneCommand/VPhoneSign/MachO/VPhoneMachOImage.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneSign/MachO/VPhoneMachOImage.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 检查本地是否已有等价实现，固定失败样本和原二进制来源。
2. 对照目标源码最小移入空间与边界修复，保留本地严格解析。
3. 运行签名测试并核验实际打包产物，记录会丢失 UUID 的条件。

**接受条件：**
- 空间足够时不删除 load command；两级回收后仍不足必须拒绝。
- 损坏头、异常 size 和支持架构边界不产生越界写入。

**验证入口：** `sign`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 独立代码提交与签名产物回退；原始二进制保持可恢复。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T05 · 接入 UTF8 归档并保持路径保护

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T02

**旧项关联：** T05。原标题：接入 UTF-8 归档并保留路径安全。

**接口与产出：** 归档接口保留同步线程 locale 范围、受控解包目的地及原子发布行为。

**上游范围：**
- [VPhoneKit/VPhoneArchiveKit/Archive/VPhoneArchiveLocale.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneArchiveKit/Archive/VPhoneArchiveLocale.swift)
- [VPhoneKit/VPhoneArchiveKit/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneArchiveKit/)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 对账已有导入导出和第一批验证记录，定位未覆盖调用点。
2. 移入 UTF-8 包装及错误路径；不在依赖线程 locale 的范围跨 await。
3. 复验多语言名称、链接、坏包、并发和导入失败清理。

**接受条件：**
- 中文、日文、emoji 名称和内容往返一致。
- 路径穿越、越界链接及损坏包无法写出目标目录；失败不覆盖有效 VM。

**验证入口：** `archive`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 保留原归档及临时导入隔离；仅回退本批代码。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T06 · 接入完整响应与连接关闭修复

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T02

**旧项关联：** T06。原标题：迁入完整响应和关闭时序修复。

**接口与产出：** HTTP、文件、WebSocket/代理明确区分响应完整、对端关闭和超时回收；复用现有认证及消息关联。

**上游范围：**
- [VPhoneDaemon/Daemon/APIWire.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/APIWire.swift)
- [VPhoneDaemon/Daemon/GuestHyperTextHandler.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestHyperTextHandler.swift)
- [VPhoneDaemon/Daemon/GuestWebSocketHandler.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestWebSocketHandler.swift)
- [VPhoneDaemon/Daemon/GuestAPI.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestAPI.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 先用大响应、慢读和提前断线用例复现本地现状，已修复则保留证据。
2. 成组适配上游发送收尾和连接回收，覆盖 VSOCK/代理两端。
3. 确认异常、取消和超时都能释放连接及 staging 文件。
4. 区分请求关联 ID 与幂等性；已可能产生副作用但丢失回复时记 unknown outcome，先读回再决定恢复或重试。

**接受条件：**
- 8/16 KiB 边界及更大合法响应长度/摘要完整。
- 无双方等待 EOF、提前 reset 截断、遗留 fd 或跨请求串包。
- 安装成功后丢回复不会仅凭同一 request ID 自动重发写操作。

**验证入口：** `protocol`（见后文；需记录本地实际命令和结果）。

**回退与保护：** host/guest/proxy 通信实现按兼容组合回退。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T07 · 接入 worker 重试与升级确认

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T06

**旧项关联：** T07。原标题：适配 worker 重试和升级退出语义。

**接口与产出：** worker 崩溃、proxy 结束、正常升级与监听成功确认分别记录；退出不等于升级成功。

**上游范围：**
- [VPhoneDaemon/Native/vphoned_proxy.c](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Native/vphoned_proxy.c)
- [VPhoneDaemon/Daemon/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/)
- [VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControl.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControl.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 对照上游 proxy/worker/plist 与本地监督进程，不重复创建第二套重启器。
2. 适配退出原因、固定重试及父子进程回收；保留本地限流和日志约束。
3. 验证新 binary 监听成功后才确认，失败缓存可回退。
4. 先于 probe 自动 agent.apply_update 固定每 VM 同步/回退策略；绑定其他 Bundle 或 hash 不同本身不授权改写 guest。

**接受条件：**
- 崩溃、信号退出、proxy 消失和升级失败均无孤儿端口。
- 新 worker 不可用时不会无界循环重启旧/坏 binary。
- 禁止改写 guest 的兼容连接前后 daemon hash 不变；显式更新路线另验升级确认。

**验证入口：** `protocol`（见后文；需记录本地实际命令和结果）。

**回退与保护：** proxy、worker、plist 和已确认 binary 配套恢复。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T08 · 将 IcliKit 候选调整为固定 0.7.16

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T02, T06, T07

**旧项关联：** T08。原标题：锁定 IcliKit 0.7.7 并对照接口。

**接口与产出：** 固定 IcliKit 0.7.16 / 702990b59ca412ad975f9f0ea5dafe95c30fac21；其他依赖按目标锁文件逐项对账。

**上游范围：**
- [VPhoneDaemon/VPhoneDaemon.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/VPhoneDaemon.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)
- [VPhoneDaemon/Daemon/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 把旧 0.7.7 目标替换为 0.7.16 的兼容评估，核对工作区内所有锁文件与实际编译链接版本。
2. 适配本地实际调用和新增 entitlement，保留旧 API 的明确降级。
3. 验证 NaN/非 UTF-8 序列化、截图重复调用、worker、location、rotation、RootHide service 和 timezone。

**接受条件：**
- 锁文件、构建和运行 daemon 来源一致；仅改版本号不算完成。
- 重复调用不出现逐次持续累积的已知泄漏；旧 guest 不因 host 新依赖被误认升级。

**验证入口：** `daemon`, `protocol`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 恢复旧锁文件及完整 daemon/载荷组合，不单独换回一项依赖。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T24 · 前置宿主安全构建与 launcher 约束

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T02

**旧项关联：** T24。原标题：复核宿主安全与构建实物。

**接口与产出：** 宿主入口继续限制身份、路径、owner 和专用 verb；launcher 与 Bundle 不能成为通用特权执行入口。

**上游范围：**
- [AGENTS.md](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/AGENTS.md)
- [VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadLauncherPolicy.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadLauncherPolicy.swift)
- [VPhoneLaunchpad/VPhoneLaunchpadLauncher/VPhoneLaunchpadLauncherProcess.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpadLauncher/VPhoneLaunchpadLauncherProcess.swift)
- [VPhoneExecutable/VPhoneVirtualization/Resources/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/Resources/)
- [VPhoneLaunchpad/VPhoneLaunchpad/Command/VPhoneLaunchpadChildProcess.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/Command/VPhoneLaunchpadChildProcess.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 将宿主安全审查从原后段移到所有写盘/新入口之前；核对本地与上游 AGENTS 冲突，保留本地多模式和严格权限。
2. 适配 root-owned Bundle store、签名/receipt 核验；分别确认 launcher、VM 和定位 helper 的权限职责。
3. 按实际工程构建，核验架构 slice、entitlements、资源和运行依赖闭包。
4. 审查 throughLauncher 的 direct fallback：合法开发构建缺 launcher 可按原普通规则运行，违反身份/路径/权限门槛不得借 fallback 绕过。

**接受条件：**
- 旧 helper、owner 错误、链接替换、共享可写路径和未知 verb 均正确拒绝。
- 产物的运行依赖可验证；不把上游 0777 策略或单一 JB 文档覆盖本地约束。
- 同时核对 policy 和调用方 fallback；实际负责授权的 app/helper 的 entitlement、usage description 和签名完整。

**验证入口：** `core`, `host`, `bundle`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 保留旧签名应用/helper/Bundle 组合及原启动路线。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T40 · 接入每机 Bundle 绑定与四层版本来源

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T02, T05, T24

**旧项关联：** T24, T25, T27。

**接口与产出：** C10：分别记录 host Bundle、guest environment、kernel、其他 boot chain；更换绑定只改变被明确执行的层。

**上游范围：**
- [VPhoneLaunchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadMachineBinding.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadMachineBinding.swift)
- [VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift)
- [VPhoneLaunchpad/VPhoneLaunchpad/Machines/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/Machines/)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 接入 per-VM binding 和整个创建流程固定版本，旧机器首次迁移前保存原解释和绑定。
2. 安装新 Bundle 不切换现有机器；缺失/损坏绑定不静默选默认执行。
3. 区分 Core Bundle >=2.6.0 代码门槛与同 major.minor 默认支持策略，跨 series 需另有验证；记录 clone/export/rename 后来源。
4. 固定每 VM daemon/environment 同步和降级策略；切绑定和 host 回退不自动授权 guest 改写。

**接受条件：**
- 新 host 旧 guest/旧 kernel 混合状态准确可见。
- 只做 update-kernel 不更新其他 boot-chain 来源；缺 Bundle 时拒绝并说明恢复路径。
- 不同本地构建可并存，不覆盖正在使用的产物。
- 不同本地构建可并存，合法 local/CI 后缀正确解析；同 series 不同 patch 不要求版本数字相同。
- 绑定改变、纯兼容连接、显式升级/回退的前后 guest hash 和 instance 均可追踪。

**验证入口：** `core`, `host`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 恢复原绑定和配置；guest/kernel 已变更时另行执行其恢复，不声称切绑定已完成回滚。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T46 · 独立接入 console 性能与输出完成确认

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T02, T24

**旧项关联：** T25, T26。

**接口与产出：** 按操作保留完整日志、顺序与退出状态；性能修复不改变 panic 识别和文本内容语义。

**上游范围：**
- [VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadLineReader.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadLineReader.swift)
- [VPhoneLaunchpad/VPhoneLaunchpad/HostSetup/VPhoneLaunchpadHelperClient.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/HostSetup/VPhoneLaunchpadHelperClient.swift)
- [VPhoneLaunchpad/VPhoneLaunchpad/Machines/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/Machines/)
- [VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadHelperProtocol.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadHelperProtocol.swift)
- [VPhoneLaunchpad/VPhoneLaunchpadHelper/VPhoneLaunchpadHelperService.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpadHelper/VPhoneLaunchpadHelperService.swift)
- [VPhoneLaunchpad/VPhoneLaunchpad/Application/VPhoneLaunchpadLogWriter.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/Application/VPhoneLaunchpadLogWriter.swift)
- [VPhoneLaunchpad/Configuration/Version.xcconfig](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/Configuration/Version.xcconfig)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 合入 helper 输出完成 ACK/归属与 console 分块扫描、批量写入最终实现。
2. 对随机切块、大量行、ANSI、并发操作和日志轮换比较输出等价。
3. 记录本地吞吐和 UI 响应基线，仅报告本地实测收益。
4. 接入完整 helper/client 协议版本；区分 callback 已接收、异步 writer 已排空和进程退出，必要时补可验证 drain 完成契约。

**接受条件：**
- 退出前尾部完整，一次操作不写入另一台机器日志。
- panic 识别与换行语义不退化，取消/轮换保持可追踪。
- ACK 缺失/30 秒超时、XPC 断线、写入失败、尾部后立即退出应用均不误报日志完整；旧 helper 升级或明确拒绝。

**验证入口：** `host`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 独立代码回退；保留已有日志，避免与媒体/固件变更混合。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。


## M2 · 补丁契约 原件准备和 Hook 策略

### [ ] T09 · 修订补丁 ID 预设与旧配置迁移

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T02, T24

**旧项关联：** T09。原标题：建立补丁 ID／预设迁移清单。

**接口与产出：** 版本化 ID 映射保留显式用户选择；regular/exp 与 standard/experimental 不做名称等同。

**上游范围：**
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/FirmwarePatchSetCatalog.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/FirmwarePatchSetCatalog.swift)
- [VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhonePatchPresetStore.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhonePatchPresetStore.swift)
- [VPhoneExecutable/VPhoneVirtualization/Resources/patches_presets/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/Resources/patches_presets/)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 列出本地已使用 ID、上游新旧声明、模式适用性和默认值变化。
2. 处理 extended/experimental、旧点号 ID 及 kernel-exp-paravirt_user_clients 的后续更名，保留显式开关意图。
3. 迁移先输出差异预览并保存原文件，再原子提交；未知或歧义映射停止执行。

**接受条件：**
- 一对一、拆分、合并、移除均有明确决定；迁移幂等。
- 显式关闭不会因新默认开启而丢失；未知/重复 ID 不降级为全部启用。

**验证入口：** `patch`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 恢复迁移前选择和版本；该任务不写固件或 guest。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T10 · 复用声明体系并强化五模式执行 Gate

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T09

**旧项关联：** T10。原标题：实现 VariantPolicy 和严格执行 Gate。

**接口与产出：** C1：resolve(mode, OS, selection, catalog) 产生冻结计划；执行只接受该计划允许的声明和实际 patch records。此为逻辑接口，T02 映射本地类型。

**上游范围：**
- [VPhoneExecutable/VPhoneCommand/VPhonePatchKit/PatchSet/VPhonePatchGate.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhonePatchKit/PatchSet/VPhonePatchGate.swift)
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Pipeline/FirmwarePipelineComponents.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Pipeline/FirmwarePipelineComponents.swift)
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/KernelCustomFirmwarePatcher.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/KernelCustomFirmwarePatcher.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 冻结本地五模式的允许/禁止和 Hook/auth/Irisin 行为矩阵。
2. 将上游声明接入已有策略；所有新入口读取真实模式，消除移植路径中的硬编码 .jb。
3. 拒绝未声明 record、依赖缺失、冲突、环和不可判定版本；启动必需项逐项核验。

**接受条件：**
- 五模式策略测试均通过，用户 override 不越过模式约束。
- 单个必需补丁缺失时，即使同一 patcher 其他补丁成功也不得放行。
- 外部可执行 patchset 默认关闭，root 不加载其代码。

**验证入口：** `patch`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 按入口关闭新能力并保留既有模式路径；不让半套 Gate 接入写盘链。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T11 · 修订计划持久化和损坏状态处理

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T10

**旧项关联：** T11。原标题：实现计划持久化、迁移与 fail-closed。

**接口与产出：** C2：冻结计划绑定 VM 身份、mode、输入 build/digest、catalog/target、schema 和 planDigest；缺失、损坏、未知 schema 分别表达。

**上游范围：**
- [VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhonePatchPresetStore.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhonePatchPresetStore.swift)
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/FirmwarePatchDrift.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/FirmwarePatchDrift.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 复用已有计划和 manifest，补足来源与 digest，避免另起一套平行配置源。
2. 将未知旧 VM 导入单独识别流程，禁止读取/解码失败后采用宽松默认。
3. 原子保存新计划并保留旧版本，检查计划与磁盘/generation 对应。

**接受条件：**
- 缺失、权限拒绝、坏 plist、不支持 schema、VM 不匹配各有确定错误。
- 只有已识别并记录边界的 legacy 可使用兼容路线；默认不能写盘。

**验证入口：** `patch`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 恢复原记录；未知 applied 状态保留 unknown，不猜测为空或已应用。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T12 · 将 FirmwareOriginals 接入既有 generation 和检查点

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T03, T11

**旧项关联：** T12。原标题：把固件原件纳入 generation／检查点。

**接口与产出：** C3：原始输入、派生产物、临时 restore tree 分开；generation 绑定 IPSW/build/device/GPU/planDigest。

**上游范围：**
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Pipeline/FirmwarePipelineOriginals.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Pipeline/FirmwarePipelineOriginals.swift)
- [VPhoneKit/VPhoneCoreKit/Bundle/VPhoneBundleOperations.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/Bundle/VPhoneBundleOperations.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 核对现有 prepare/checkpoint 原件管理，识别可直接复用部分。
2. 只从可信原始组件生成补丁；同名文件不代表同一固件。
3. 新 generation 验证并提交前保留旧 Originals；按真实依赖决定清理。

**接受条件：**
- A→A、A→B→A 和中断续跑使用正确原件；坏原件不能成为新来源。
- 旧 generation 在新输入失败或取消后仍可恢复。

**验证入口：** `patch`, `core`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 切回前一 generation；仅隔离本次临时产物。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T13 · 接入原生 prepare GPU 和 staging 提交

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T12, T14

**旧项关联：** T13。原标题：适配原生 prepare 的 GPU/v2 与原件生命周期。

**接口与产出：** 复用本地 prepare/checkpoint，源校验、提取合并、GPU 获取、完成发布分阶段记录。

**上游范围：**
- [VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneFirmwarePreparer.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneFirmwarePreparer.swift)
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Manifest/FirmwareManifest.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Manifest/FirmwareManifest.swift)
- [VPhoneKit/VPhoneCoreKit/Firmware/VPhonePCCGPUDriver.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/Firmware/VPhonePCCGPUDriver.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 核对 classic 与 GPU/v2 的实际本地入口，保留历史已通过范围。
2. 在 staging 完成 IPSW 配对、vphone600 identity、GPU 和组件校验。
3. 修正上游早期删除 FirmwareOriginals 的接入方式，完整提交新 generation 后才退休旧来源。

**接受条件：**
- 错误配对、错误 GPU、缺少组件和新输入取消均不发布半成品。
- classic 的通过记录不替代 GPU/v2；checkpoint 指纹不符时不继续旧阶段。

**验证入口：** `patch`, `core`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 恢复旧配置和 generation；失败挂载先卸载再清理 staging。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T14 · 复用共享 IPSW GPU 缓存并保留权限边界

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T02, T05, T24

**旧项关联：** T14。原标题：实现共享 IPSW/GPU 缓存边界。

**接口与产出：** 缓存只共享可验证原始归档和派生 GPU 工件；VM 身份、SEP、NVRAM、SHSH、认证不共享。

**上游范围：**
- [VPhoneKit/VPhoneArchiveKit/Transfer/VPhoneIPSWCache.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneArchiveKit/Transfer/VPhoneIPSWCache.swift)
- [VPhoneKit/VPhoneCoreKit/Firmware/VPhoneResources.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/Firmware/VPhoneResources.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 统一来源身份、缓存 key、长度/digest/manifest 校验和受控 cache 根。
2. 处理同源并发、专属 partial、取消和原子发布；保留本地 IPSW 入口。
3. 分别核对 remote ZIP Range 与整包下载续传，按实际实现描述能力。

**接受条件：**
- 截断、坏缓存、同名不同来源、并发和取消不污染有效归档。
- 不递归放宽为 0777，不因时间阈值删除其他活跃任务文件。

**验证入口：** `archive`, `core`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 隔离坏工件、删除本任务 partial，保留有效缓存和 VM 资产。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T32 · 接入分组件 Receipt 并增加实际应用证据

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T10, T11

**旧项关联：** T10, T11, T15, T17。

**接口与产出：** C7：desired/planned/generated/committed/activated/accepted 分开；Receipt 兼容上游语义，实际字节证明绑定同一 VM、generation、plan 和事务。

**上游范围：**
- [VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhonePatchPresetStore.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhonePatchPresetStore.swift)
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/FirmwarePatchDrift.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/FirmwarePatchDrift.swift)
- [VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 复用上游 PatchReceipt/Drift 与本地 manifest，补齐最小验证字段，避免双重权威账本。
2. 记录实际命中与已验证输入/输出，不直接复制 plan.enabled 为 applied。
3. 缺 receipt 保留 unknown；no-op 仅在重新验证输出后可补证据，不能借无变化跳过状态核对。

**接受条件：**
- 部分失败、缺关键 record、坏 receipt 和写入失败不标全成功。
- kernel 更新只登记 kernel，Guest 更新只登记 Guest；不能抬升其他启动链版本。
- 权限沿用本地约束，拒绝未授权改写；缺旧证据不自动推断 applied。

**验证入口：** `patch`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 恢复旧记录及关联证明；无法证实的部分标 unknown。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T43 · 逐项适配 Hook 门控和运行时修补

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T02, T03, T09, T10, T24

**旧项关联：** T21, T22, T24。

**接口与产出：** 每个 Hook 记录目标进程、系统/模式条件、加载阶段、禁用路径和部署要求；本地 auth/Irisin 门控继续生效。

**上游范围：**
- [VPhoneGuestComponents/Shared/InjectionEnvironment.h](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneGuestComponents/Shared/InjectionEnvironment.h)
- [VPhoneGuestComponents/LaunchHook/launchdhook-vphone.c](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneGuestComponents/LaunchHook/launchdhook-vphone.c)
- [VPhoneGuestComponents/SystemHook/SystemHook-vphone.c](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneGuestComponents/SystemHook/SystemHook-vphone.c)
- [VPhoneGuestComponents/VCamCaptured/Image/VCamCodePatch.m](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneGuestComponents/VCamCaptured/Image/VCamCodePatch.m)
- [VPhoneGuestComponents/Tests/InjectionEnvironmentTests.c](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneGuestComponents/Tests/InjectionEnvironmentTests.c)
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/CustomFirmwarePatches/Sandbox/KernelCustomFirmwarePatchParavirtUserClients.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/CustomFirmwarePatches/Sandbox/KernelCustomFirmwarePatchParavirtUserClients.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 区分必要稳定性修复和功能放宽，列出 no-haptics、battery、volume lookup、capture、GPU 及代码页修改。
2. 按本地策略适配服务查找例外；不把按服务名放行描述为已验证请求者身份。
3. 成组移入 VCam 代码页竞态修复与线程恢复/指令缓存处理，验证异常退出路径。
4. 明确负责 26.x/18.x 的 paravirt IOUC kernel 适配与模式默认：实际匹配 ApplePar/AppleVid/AppleVir/IOSurfac 八字节前缀，不误写成四个精确类名。
5. 前置交付只接受策略、注入和代码修补错误路径；相机/音频完整部署结果由 T22/T42/T30 回填，避免与 T16 形成循环等待。

**接受条件：**
- 五模式和 safe/禁用路径保持原策略；不增加通用 sandbox/认证旁路。
- 运行时修补错误路径可恢复线程与内存保护状态；完整相机重启结果归 T22/T42/T30，不能在本前置任务提前宣称。

**验证入口：** `guest`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 恢复相应 Hook 与加载配置；新功能默认关闭直至组合验证完成。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。


## M3 · 写盘事务 环境 内核和固件适配

### [ ] T15 · 强化离线写盘事务及崩溃恢复

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T03, T04, T11, T24, T32

**旧项关联：** T15。原标题：强化 CFW 写盘事务及锁。

**接口与产出：** C4：VM 锁覆盖验证到提交；prepareCommit、publish、recover 管理磁盘、receipt、配置的可恢复一致状态，复用本地现有事务。

**上游范围：**
- [VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift)
- [VPhoneKit/VPhoneCoreKit/Process/VPhoneConfinedDirectory.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/Process/VPhoneConfinedDirectory.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 核验 VM 停止、磁盘身份/owner/链接/路径和容量，并持久化恢复记录。
2. 在 clone 或经验证完整副本上修改；两者不可用时拒绝，不降级写原盘。
3. 完成写入、读回和卸载后提交；磁盘交换与 receipt 更新之间用日志恢复，不能声称多文件天然原子。
4. 在提交前后关键点注入中断并验证恢复选择。

**接受条件：**
- VM 忙、owner 不符、symlink/hardlink 风险、clone 不可用均不误写原盘。
- 写入、卸载、磁盘交换、receipt 写入失败后都能恢复明确一致状态。
- 挂载未退出时不递归清理；旧副本在完整验收前保留。

**验证入口：** `core`, `patch`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 依事务日志恢复磁盘、配置和 receipt；状态无法证明时停止自动重试。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T16 · 修订旧 VM 停机环境更新资格

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T08, T12, T15, T33, T34, T35, T43, T44

**旧项关联：** T16。原标题：实现停机环境更新资格和旧 VM 路由。

**接口与产出：** C5：eligibility 返回可替换、需受控迁移、需重建或拒绝及理由；缺少 loader/必需库不能作为成功跳过。

**上游范围：**
- [VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift)
- [VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestEnvironment.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestEnvironment.swift)
- [VPhoneKit/VPhoneArchiveKit/Transfer/VPhoneBoardDeviceTree.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneArchiveKit/Transfer/VPhoneBoardDeviceTree.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 按完整安装、计划、原件、内核证明、载荷和加载路径分类旧 VM。
2. 按模式生成 guest 载荷集合，保留认证、密码、包和身份；通过统一事务应用/撤销。
3. 核验必需组件并提交 Guest receipt，记录首次启动和激活需求。
4. 消费 T44 的 board 原件恢复结果；缺必要 tree 不接受 repair 已完成。旧 26.x/18.x guest 的 paravirt kernel 前提未具备时，路由 T34 或待迁移。
5. 拟更新 DSC 使用已安装并证明有效的 kernel 区域校验，不能只验证当前旧 DSC。

**接受条件：**
- 无完整安装、缺 libmisfix 或加载路径、坏计划分别正确路由。
- 旧 VM 无撤销资料时不宣称关闭成功；必需组件失败不提交整批成功状态。
- 新媒体前提、原始 board tree 或实际 kernel 证明缺失时，不把库文件更新视为整机升级完成。

**验证入口：** `patch`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 恢复环境、相关 Preboot repair、Guest receipt 和磁盘状态；重建另行作为明确迁移决策。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T17 · 接入在线更新并区分文件安装与实际激活

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T07, T08, T16, T32

**旧项关联：** T17。原标题：实现在线环境替换与实际激活状态。

**接口与产出：** C6：staged → files_installed → processes_activated → acceptance_passed；失败/待激活另列，不能由单个 reboot_required 字段推定完成。

**上游范围：**
- [VPhoneDaemon/Daemon/GuestAPI+Environment.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestAPI%2BEnvironment.swift)
- [VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControlEnvironment.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControlEnvironment.swift)
- [VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestEnvironment.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestEnvironment.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 从目标 host/guest 源码共同确认真实白名单、大小与摘要规则，继续修复旧文档与代码差异。
2. 把逐文件替换接入可恢复批次，保存旧文件及挂载状态；不引入任意路径上传。
3. 按实际加载进程给出激活动作；未执行所需重启时保留 pending_activation。
4. 连接恢复后核对实际 daemon/库/进程版本和业务能力。
5. 在线批次契约有可验证支持标识或已核实版本映射；只有 legacy environment_update 的 daemon 走明确兼容/停机路线。
6. 请求绑定 T16 产生的模式允许集合与计划；严格校验 requested/installed 集合和阶段字段，staging 路径仍受本地允许范围限制。
7. 统一自动 sync、手动更新、bootstrap 和 shutdown 的每 VM 写操作冲突规则；绑定 operation/generation，不扩大为所有 API 全局串行。
8. 混合版本测试禁用自动同步，显式更新/回退另测，记录前后 daemon/库 hash 和 instance。

**接受条件：**
- 未知库、错误 hash、断线、部分写入及只读挂载恢复失败均可诊断和恢复。
- SpringBoard/launchd 等仍加载旧库时不标全部生效；不无条件扩大 respring/reboot 行为。
- 缺字段、重复/未知组件或安装集合不一致是 protocol error/unknown outcome，不能默认空数组或 false 后报成功。
- 安装成功但回复丢失、更新与 Stop 交错、自动/手动同步竞争均有确定状态和恢复路径。

**验证入口：** `protocol`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 恢复整组文件与配置；进程尚未恢复时保留 pending_recovery，不报全部回退完成。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T33 · 接入 guest 补丁撤销并界定旧 VM 边界

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T15, T32

**旧项关联：** T11, T15, T16。

**接口与产出：** 撤销只使用已验证、绑定正确 generation 的原始字节或 .bak；缺证据时报告 not_revertible。

**上游范围：**
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/DyldSharedCache/DyldSharedCacheUndoLog.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/DyldSharedCache/DyldSharedCacheUndoLog.swift)
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcherTests/DyldSharedCache/DyldSharedCacheUndoLogTests.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcherTests/DyldSharedCache/DyldSharedCacheUndoLogTests.swift)
- [VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 接入 DSC undo、Mach-O 及 Preboot repair 备份规则，检查首次备份未包含旧补丁。
2. 在事务内执行关闭/再开启，并恢复需要的代码签名页状态。
3. 对旧 VM 无 undo、共享修改页、部分失败逐项报告真实结果。

**接受条件：**
- on→off→on 可复验；错误 generation/字节拒绝恢复。
- 缺备份不宣称已撤销；异常中途写入不能仅凭 prior-live 推定原状态未变。

**验证入口：** `patch`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 依事务恢复原磁盘和 undo/receipt；无法证明状态时隔离样本。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T34 · 接入保留数据的离线 kernel 更新

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T12, T15, T32, T35

**旧项关联：** T12, T15, T16。

**接口与产出：** update-kernel 消费可信原件/计划/实际模式，在事务内替换唯一 Preboot kernelcache；保留目标 IM4M 和其他启动链来源。

**上游范围：**
- [VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift)
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Pipeline/FirmwarePipeline.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Pipeline/FirmwarePipeline.swift)
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/CustomFirmware/CustomFirmwarePostRestoreDeviceTree.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/CustomFirmware/CustomFirmwarePostRestoreDeviceTree.swift)
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcherTests/CustomFirmware/CustomFirmwareKernelcacheSwapTests.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcherTests/CustomFirmware/CustomFirmwareKernelcacheSwapTests.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 成组接入 fdb0093 与 04a13e4 的最终行为，读取本地实际模式和版本来源。
2. 核验 Originals 或用户预生成 restore 产物、krnl 类型、目标 IMG4/IM4M、唯一 Preboot 候选。
3. 生成并读回 kernel 补丁证据，只修改 Preboot kernelcache 后提交 kernel receipt。
4. 在测试 VM 重启验证新内核、应用数据及重复更新。
5. 提交前用候选 kernel 区域与当前 guest DSC 实际 mapping/effective maxSlide 校验拟提交组合。

**接受条件：**
- 原件缺失、类型/来源不符、零/多候选均不提交。
- IM4M 原字节与关键数据保留；重复同输入一致，失败可恢复。
- 执行成功与新内核实际启动分开记录；不把它扩展为所有 boot-chain 更新。
- 7 GiB 缩回 6 GiB 而当前 DSC 超界时提交前拒绝，不改磁盘/receipt；不同 generation 不复用旧 kernel 证明。

**验证入口：** `patch`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 恢复原 kernel IMG4、磁盘副本、kernel receipt 和关联选择；其余启动链保持对应原状态。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T35 · 成组接入共享区域检查与扩容证明

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T03, T10, T11, T32

**旧项关联：** T10, T11, T15。

**接口与产出：** C8：依据已验证实际 kernel 的 base/size 与最终 DSC mapping/effective maxSlide 判断兼容；没有证据返回 unknown/reject。

**上游范围：**
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/CustomFirmwarePatches/Memory/KernelCustomFirmwarePatchSharedRegionSize.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/CustomFirmwarePatches/Memory/KernelCustomFirmwarePatchSharedRegionSize.swift)
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/KernelCustomFirmwarePatcher.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/KernelCustomFirmwarePatcher.swift)
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/DyldSharedCache/Patchers/DyldSharedCacheMaxSlidePatcher.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/DyldSharedCache/Patchers/DyldSharedCacheMaxSlidePatcher.swift)
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcherTests/Kernel/KernelCustomFirmwarePatchSharedRegionSizeTests.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcherTests/Kernel/KernelCustomFirmwarePatchSharedRegionSizeTests.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 接入 31b1385 与 ea76afa，保持具体 iOS/cloudOS 适用性，单项 boot-essential 命中为强制条件。
2. 移除无 receipt 就按 iOS 27 推定 7 GiB 的本地接入行为；对安装内核或可信关联证明读回核验。
3. 校验拟提交组合：T34 用候选 kernel+当前 DSC，T16 用已证明安装 kernel+候选 DSC；只把受支持旧格式明确路由 legacy。
4. 验证 6/7 GiB、缓存越界、非零/零 slide、0/多命中及未知 kernel。

**接受条件：**
- 只扩大虚拟地址共享区域，不把 VM RAM 或磁盘容量变化当作修复。
- 其他 kernel 补丁成功不能掩盖扩容未命中；未知区域不得按 7 GiB 放行。
- 保持现有 maxSlide 策略，恢复 DSC ASLR 不纳入本轮默认目标。

**验证入口：** `patch`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 撤回该候选能力并保留拒绝不兼容输入的检查；回退 kernel 与 DSC 必须保持兼容组合。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T44 · 接入设备固件身份与旧 board 原件恢复

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T09, T10, T13, T15, T35

**旧项关联：** T13, T23, T26。

**接口与产出：** 设备目录、restore 身份、运行时 board identity 和屏幕参数分开；目录列出不等于启动验证。

**上游范围：**
- [VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestDevice.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestDevice.swift)
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/DeviceTree/DeviceTreeGuestDevicePatches.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/DeviceTree/DeviceTreeGuestDevicePatches.swift)
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Manifest/FirmwareManifest.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Manifest/FirmwareManifest.swift)
- [Documents/Guides/iphone-models.md](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/Documents/Guides/iphone-models.md)
- [VPhoneKit/VPhoneArchiveKit/Transfer/VPhoneBoardDeviceTree.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneArchiveKit/Transfer/VPhoneBoardDeviceTree.swift)
- [VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 保留原 iPhone 路径作为回归基线，接入指定 device/board 的来源解析。
2. 区分 guest DeviceTree 与 RestoreDeviceTree，接入屏幕比例和相关 board 属性。
3. 按明确配对验证生成物与启动前输入，旧字段保持原设备解释；完整创建/启动归 T30，使用 T16/T17 已交付环境。
4. 接入 recoverBoardDeviceTree：从匹配 productType/version/build 的 IPSW manifest/member 恢复原始 board tree，受控查找缓存并按调用者权限读写、绑定 generation。

**接受条件：**
- 多板 IPSW 不选错设备，restore 检查与运行身份不串用。
- iPad 2x/iPhone 3x 与原机型的映射、生成物分别验证；整机启动和媒体由 T30 对共同矩阵回填，未测机型保持候选。
- 旧 VM 无 restore/board 原件但有正确 IPSW 时可恢复；错误 IPSW、来源不明或缺必要 tree 不报 repair 已完成。

**验证入口：** `core`, `patch`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 恢复原设备配置、generation、DeviceTree 及启动链组合；不只改名称字段回退。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。


## M4 · 客户机控制与既有功能链

### [ ] T18 · 保留 MISFix 安装启动并补齐应用注册

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T04, T11, T16, T17, T21

**旧项关联：** T18。原标题：整合 MISFix 与应用安装／启动。

**接口与产出：** 安装、扩展注册、启动和前台确认分开报告；apps.install 与 installd 路径分别验证。

**上游范围：**
- [VPhoneDaemon/Daemon/GuestAPI+AppDetail.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestAPI%2BAppDetail.swift)
- [VPhoneDaemon/Daemon/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/)
- [VPhoneGuestComponents/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneGuestComponents/)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 核对已有 MIS/Hook 目标进程和签名逻辑，保留模式限制并避免重复注入。
2. 接入 .appex 注册、应用刷新及错误对象透传，核对实际 bootstrap 布局。
3. 分别验收 vphoned 安装路径和项目实际需要的 installd 路径。
4. bootstrap refresh 使用 T21 已确认布局的 fixture；独立 MIS/installd 调查可以提前做。

**接受条件：**
- 安装被接受、安装完成、扩展注册和真正启动均有独立证据。
- apps.install 通过不作为 installd Hook 通过；devicectl 既有限制不写成已解决。
- 缺 bootstrap 时拒绝/禁用刷新，不退回系统 /Applications；按支持范围验证 RootHide/rootless 的实际目录。
- 受控 .appex 的 provider 能被系统发现并启动；App 本体前台成功不能替代扩展运行。

**验证入口：** `daemon`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 恢复载荷/Hook/配置组合并保护已有 App 数据。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T19 · 保留 UDID 与宿主识别独立验收

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T18

**旧项关联：** T19。原标题：整合 UDID、宿主识别与回退。

**接口与产出：** 身份 set/clear、guest 读回、USB/宿主重新枚举、重启恢复分开；测试身份与克隆身份不混用。

**上游范围：**
- [VPhoneDaemon/Daemon/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/)
- [VPhoneKit/VPhoneCoreKit/VirtualMachine/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/VirtualMachine/)
- [VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 保留原身份、信任关系和本地允许范围，核对目标身份实现。
2. 适配设置/清除及重启重应用，更新调用方状态。
3. 在 guest、宿主发现和实际使用链路分别读回。

**接受条件：**
- set/clear/reboot 后身份按设计一致；失败可恢复原值。
- 一次 API 成功不代替宿主识别/信任验证；不扩大可修改身份范围。

**验证入口：** `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 恢复原 UDID/配置并重新验证宿主信任。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T20 · 保留定位主线并核验真实权限归属

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T08, T16, T17, T24, T40

**旧项关联：** T20。原标题：改造定位链路并隔离旧 Hook。

**接口与产出：** 宿主授权/位置来源、guest set/clear、fresh simulated readback 分别报告；legacy 路径显式识别。

**上游范围：**
- [VPhoneExecutable/VPhoneVirtualization/UI/HostDevices/VPhoneLocationProvider.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/HostDevices/VPhoneLocationProvider.swift)
- [VPhoneDaemon/Daemon/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/)
- [VPhoneExecutable/VPhoneVirtualization/LocationHelperProcess/main.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/LocationHelperProcess/main.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 核对 VPhoneLocation 打包及本地旧定位 Hook 使用范围，保留其他 Hook。
2. 分别核实 launcher、vphone-vm、VPhoneLocation.app 的权限职责；定位以 helper 的签名、usage strings 和真实授权状态验收，不从 launcher 存在推定。
3. 验证无权限、无坐标、无海拔、helper 退出、重连及 guest 未 ready。

**接受条件：**
- 位置来源与新鲜模拟读回可证明；更换 Bundle 不造成错误授权归属。
- 只替换明确被取代的定位路径，保留本地必要 legacy 条件。
- 普通/直接 CLI 启动、Bundle 切换和不同本地构建均核实授权；VM/管道结束后 helper 正确退出。

**验证入口：** `core`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 恢复已有位置方案及对应载荷/配置；避免新旧默认混装。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T21 · 保留 RootHide Irisin 和既有认证状态

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T08, T16, T43

**旧项关联：** T21。原标题：核对并适配 RootHide／Irisin 基础设施。

**接口与产出：** bootstrap 更新是幂等补缺；密码、SSH host keys、包状态、认证配置和模式策略继续保持。

**上游范围：**
- [VPhoneGuestComponents/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneGuestComponents/)
- [VPhoneDaemon/Daemon/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 对照原本地布局与上游 service/首次包安装逻辑，列明实际需要补入的项。
2. 接入 IcliKit service 兼容和必要基础初始化，不覆盖用户已有状态。
3. 分别验证新 VM、已有 bootstrap、重复执行和工具不齐。

**接受条件：**
- 已修改密码、host keys 和包状态不丢失；重复运行不重置环境。
- 本地 Irisin/认证/模式门控保持原允许范围。

**验证入口：** `daemon`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 按变更清单只撤销本批新内容；恢复原权限和配置。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T22 · 按组合适配相机并纳入新稳定性修正

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T06, T11, T16, T17, T43

**旧项关联：** T22。原标题：按最终组件组合适配相机。

**接口与产出：** 相机交付覆盖 host 帧生产、公共 ABI、guest 消费、资源及部署；运行时代码页修改归入 T43 策略。

**上游范围：**
- [VPhoneGuestComponents/VCamCaptured/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneGuestComponents/VCamCaptured/)
- [VPhoneGuestComponents/CamFix/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneGuestComponents/CamFix/)
- [VPhoneExecutable/VPhoneVirtualization/UI/HostDevices/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/HostDevices/)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 保留本地帧生命周期、消费回执及 ABI 约束，按目标最终组件组合对账。
2. 合入 capture/GPU prewarm 等配套修正，避免只更新一个 Hook。
3. 验证系统和第三方预览、拍照、取消、格式/颜色/时间戳及进程重启。

**接受条件：**
- 预览可见与拍照数据正确分别验收；帧/回执不串 VM。
- 重复开关和目标持续场景无未解释内存增长或 cameracaptured 竞态。

**验证入口：** `guest`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** host、guest、公共头、资源和配置整组恢复。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T23 · 扩展输入旋转键盘和 headless 控制

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T06, T08, T11, T44

**旧项关联：** T23。原标题：整合输入、多指、旋转及 headless。

**接口与产出：** 整次手势绑定 VM、坐标空间和旋转版本；键盘设置缺失维持本地已核实旧行为。

**上游范围：**
- [VPhoneDaemon/Daemon/GuestAPI+Input.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestAPI%2BInput.swift)
- [VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestKeyMap.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestKeyMap.swift)
- [VPhoneExecutable/VPhoneVirtualization/UI/UserInterface/VPhoneVirtualMachineKeySender.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/UserInterface/VPhoneVirtualMachineKeySender.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 保留 input.touch_sequence 真实契约，对账本地队列和 headless 路由。
2. 接入旋转后的手势映射、特殊键和每 VM 硬件键盘开关。
3. 对正常输入补齐回归，120 Hz 另由可选 T45 处理。

**接受条件：**
- 多指、归一化/点坐标、旋转中输入、取消和并发无丢失结束事件。
- iPad 2x/iPhone 3x、键盘开关和 headless 按声明组合有效，不臆造 RPC。

**验证入口：** `core`, `protocol`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 保留旧协议兼容；终止未完成手势，恢复旧配置解释。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T36 · 接入 daemon 实例标识与可选启动解锁

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T06, T07, T08, T23

**旧项关联：** T07, T23, T27。

**接口与产出：** C9：health.instance 区分启动和重连；手动 unlock 与默认关闭的自动 unlock 分开。

**上游范围：**
- [VPhoneDaemon/Daemon/GuestScreenUnlock.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestScreenUnlock.swift)
- [VPhoneDaemon/Native/vphoned_unlock.m](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Native/vphoned_unlock.m)
- [VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControlSystem.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControlSystem.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 接入 screen.unlock 状态机、能力声明和默认关闭配置，保留调用方已知密码输入语义。
2. 使用可信 instance 与 Setup Assistant 状态决定自动流程，带入启动早期观察和重试。
3. 缺 screen_unlock 禁用；有该能力但缺可靠 instance 时保留手动入口、跳过自动解锁。

**接受条件：**
- cold boot、熄屏、亮屏锁定、已解锁、respring/userspace reboot 均按实际状态处理。
- 同 instance 重连不再次解锁；勾选设置不立即解锁当前 VM。
- 密码路径未实测时仍标未验证，不扩大为绕过密码功能。
- 停止、换实例或关闭功能后，旧实例的异步解锁任务失效。

**验证入口：** `protocol`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 关闭自动解锁并恢复原连接/输入行为，保留手动控制。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T37 · 接入有序关机和可观察停止回退

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T06, T07, T24, T40

**旧项关联：** T06, T07, T25。

**接口与产出：** system.shutdown 复用 auth/force/root；accepted、VM stopped、disk free 分开；记录 graceful 或 host fallback。

**上游范围：**
- [VPhoneDaemon/Native/vphoned_power.m](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Native/vphoned_power.m)
- [VPhoneDaemon/Daemon/GuestAPI+AppDetail.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestAPI%2BAppDetail.swift)
- [VPhoneLaunchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadMachineLibrary.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadMachineLibrary.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 接入 guest halt、system_shutdown capability 和菜单条件。
2. Launchpad Stop 先请求关机，再观察退出并按目标超时策略回退；保留直接 CLI stop 语义。
3. 更新备份/更新调用方，实际停止且磁盘释放后才进入写盘。

**接受条件：**
- 无认证/force/权限时拒绝；连接因关机中断时以 VM 实际状态判断。
- 旧 guest、DFU、panic、未 ready 和超时均有明确 fallback 结果。
- 更新与 Stop 冲突按每 VM 写操作规则处理，不在更新提交中途无条件终止。

**验证入口：** `protocol`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 恢复原停止入口；已停止 VM 不因 UI 回退自动启动。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T38 · 接入原生 AX 嵌套诊断及旧 guest 识别

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T08, T23, T24

**旧项关联：** T23, T27。

**接口与产出：** ui.tree {nested:true} 保留 flat 默认；必须验证 format/relationship_source/action_eligible，ui_inspection 或 HTTP 200 不足以证明 nested 支持。

**上游范围：**
- [VPhoneDaemon/Daemon/GuestAPI+Hierarchy.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Daemon/GuestAPI%2BHierarchy.swift)
- [VPhoneDaemon/Native/vphoned_ax_hierarchy.m](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Native/vphoned_ax_hierarchy.m)
- [VPhoneDaemon/Tests/HierarchyTests.m](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Tests/HierarchyTests.m)
- [Research/vphoned_http_api.md](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/Research/vphoned_http_api.md)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 成组接入 native 父子查询、entitlements、接口锁、限额和前台 PID 前后检查。
2. 带入 AX switch 恢复、readiness retry 和 partial/error 元数据。
3. 调用方识别旧 daemon 忽略 nested 返回 flat 的情况，明确降级，不把 snapshot ID 当点击 selector。

**接受条件：**
- 循环/共享节点、父关系冲突、无 frame、前台变化和超限都有诊断结果。
- 新旧 daemon 响应格式识别正确；private API 超时不被承诺为硬实时。

**验证入口：** `hierarchy`, `protocol`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 关闭 nested 能力，保留既有 flat/action 接口。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T39 · 增补触摸复制和窗口失焦剪贴板同步

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T06, T23, T36

**旧项关联：** T23, T27。

**接口与产出：** 只同步本次可靠基线后的 guest Copy；保留既有 Cmd C/X/V 与文本 1 MiB、图片 16 MiB 限制。

**上游范围：**
- [VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneClipboardSync.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneClipboardSync.swift)
- [VPhoneKit/VPhoneCoreKit/Support/VPhoneClipboardTransfer.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/Support/VPhoneClipboardTransfer.swift)
- [VPhoneExecutable/VPhoneVirtualization/UI/VPhoneHostAutomationServer.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/VPhoneHostAutomationServer.swift)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 复用已有键盘同步，仅接入 fe46ee2 的 focus/连接基线和 guest change count 增量。
2. 带入 instance/generation、paste/type 后基线和晚响应淘汰；图片第二段 await 返回后再次核验实例、代际及宿主剪贴板状态。
3. 旧 guest 缺 instance 时不跨重连复用计数，无可靠基线时退回原键盘同步。

**接受条件：**
- 长按 Copy、图片、快速切窗、慢响应、重启和 automation type 不回流旧内容。
- 不会把 Mac rich text 的 plain-text 回流无意覆盖原内容；无能力时停用。

**验证入口：** `core`, `protocol`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 关闭失焦同步，保留原 Cmd C/X/V 行为。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。


## M5 · 网络 媒体与管理入口

### [ ] T25 · 扩展 Launchpad CLI 与批量操作状态

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T05, T15, T23, T24, T34, T37, T40, T41, T44, T46

**旧项关联：** T25。原标题：整合 Launchpad CLI 和批量管理。

**接口与产出：** UI/CLI 共用目标 VM 解析与操作状态；成功按每台机器及实际事务结果报告。

**上游范围：**
- [VPhoneLaunchpad/VPhoneLaunchpad/Control/VPhoneLaunchpadControlCommands.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/Control/VPhoneLaunchpadControlCommands.swift)
- [VPhoneLaunchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadCreationPipeline.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadCreationPipeline.swift)
- [Documents/Guides/launchpad-cli.md](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/Documents/Guides/launchpad-cli.md)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 保留跨 library 的稳定 VM 标识和仅修改显式字段的旧规则。
2. 接入 per-VM Bundle、网络、设备、内核更新和有序停止入口，固定整个创建流程的版本。
3. 验证批量部分失败、断连、取消、导出半成品和后台生命周期。

**接受条件：**
- 同名机器不误操作；一台失败不覆盖其他机器状态或日志。
- 取消不会把半成品标成功，重试遵守原事务和恢复入口。

**验证入口：** `host`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 关闭新增入口或回退管理层；按每台 VM 的实际写入集合分别恢复。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T26 · 保留旧 UI 尾项并接入目标管理界面

**优先级：** P2　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T25, T40

**旧项关联：** T26。原标题：迁入最新 2.2.3 的界面尾部修复。

**接口与产出：** 原 2.2.3 sheet/翻译/菜单尾项继续可追溯；新增创建/设置分页、确认与进度按最终能力接入。

**上游范围：**
- [VPhoneLaunchpad/VPhoneLaunchpad/Application/VPhoneLaunchpadModel.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/Application/VPhoneLaunchpadModel.swift)
- [VPhoneLaunchpad/VPhoneLaunchpad/Localizable.xcstrings](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/Localizable.xcstrings)
- [VPhoneLaunchpad/VPhoneLaunchpad/Machines/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/Machines/)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 逐项保留 ded81cb–caebc24 的原处理记录，对照目标最终实现消除过时补丁。
2. 接入最新设置、后台启动和进度/关闭交互，保留本地新增文案。
3. 检查连续切换、快速操作、取消、创建中关闭和支持语言。

**接受条件：**
- 界面状态与真实任务阶段一致；按钮出现不代表后端能力已具备。
- 不误删本地字符串，纯 UI 变更不夹带固件或权限修改。

**验证入口：** `host`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 独立 UI 提交回退，不触发 guest 更新。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T27 · 修订 Inspector 及旧自动化入口去留

**优先级：** P2　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T08, T23, T25, T38, T40

**旧项关联：** T27。原标题：整理 UI Inspector 和遗留入口。

**接口与产出：** Inspector 显示实际来源与待应用状态；旧 ui.* / ui.ocr 调用方逐项迁移，不因上游删面板而删除接口。

**上游范围：**
- [VPhoneLaunchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadMachineInspector.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadMachineInspector.swift)
- [VPhoneExecutable/VPhoneVirtualization/UI/UserInterface/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/UserInterface/)
- [Research/vphoned_http_api.md](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/Research/vphoned_http_api.md)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 核对本地真实调用方，分别决定保留、替代、隔离和移除。
2. 接入 wanted/planned/applied 与四层来源，分别显示绑定来源、实际运行来源和待执行更新，未知状态如实显示。
3. 如果展示 AX 层级，保留诊断/partial 属性，拒绝把 snapshot ID 当点击选择器。

**接受条件：**
- 无孤立引用；旧业务调用不被界面清理无意破坏。
- 缺 Bundle、旧 guest、无 receipt 及能力不支持均有准确状态。

**验证入口：** `host`, `protocol`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 保留必要旧入口或隔离开关，恢复旧 UI 不回写假升级状态。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T41 · 接入 tunnel 和每机网络配置

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T06, T08, T16, T17, T24, T40

**旧项关联：** T25。

**接口与产出：** 网络计划统一解释 mode、MAC、IP、gateway/DNS、转发和名称；旧字段缺省先按本地旧行为迁移。

**上游范围：**
- [VPhoneKit/VPhoneCoreKit/Support/VPhoneNetworking.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/Support/VPhoneNetworking.swift)
- [VPhoneKit/VPhoneCoreKit/Network/VPhoneUserspaceNetwork.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/Network/VPhoneUserspaceNetwork.swift)
- [VPhoneKit/VPhoneCoreKit/Network/VPhonePortForwarder.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneKit/VPhoneCoreKit/Network/VPhonePortForwarder.swift)
- [VPhoneDaemon/Native/vphoned_network.m](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/Native/vphoned_network.m)
- [Documents/Guides/networking.md](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/Documents/Guides/networking.md)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 接入 tunnel 及固定地址/端口/mDNS 配置，检查本地原网络模式和监听边界。
2. 明确 resolvesMacName=nil 的上游行为差异，旧机器按原行为显式保存；配置失败原子回退。
3. 验证并发 VM、克隆 MAC、端口冲突、停止释放和权限受约束的 lease 清理。
4. host tunnel/配置规划可先实现；guest 设置生效等待 T16/T17 交付，新 host+旧 guest 无能力时仅记待应用，重连后核对实际值。

**接受条件：**
- NAT/tunnel/bridged/none 按支持范围测试，模式切换需重启的语义清楚。
- 无意外 LAN 监听；TCP/UDP、固定 IP 与宿主路由场景实际可用。
- 不把 guest 手设网络当作本工具配置清除。
- tunnel 仅 IPv4、公网 ICMP 不转发，端口默认 loopback；返回 DHCP 只撤销本工具写入的配置。

**验证入口：** `core`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 恢复本机原网络配置和转发；不改全局宿主路由，不误清其他 VM lease。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T42 · 成组整合音频麦克风及权限链

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T16, T17, T22, T24, T35, T40, T43, T44

**旧项关联：** T22, T24。

**接口与产出：** 音频交付包含 DeviceTree/kernel 前提、HAL 插件、VirtualAudio 路由、host 权限与延迟、capture Hook 和激活。

**上游范围：**
- [VPhoneGuestComponents/VirtIOSound/VPVirtIOSoundPlugin.m](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneGuestComponents/VirtIOSound/VPVirtIOSoundPlugin.m)
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/CustomFirmware/CustomFirmwareVirtualAudioGraphConfigurations.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/CustomFirmware/CustomFirmwareVirtualAudioGraphConfigurations.swift)
- [VPhoneExecutable/VPhoneVirtualization/UI/HostDevices/VPhoneHostAudioLatencySync.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/UI/HostDevices/VPhoneHostAudioLatencySync.swift)
- [VPhoneGuestComponents/VCamCaptured/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneGuestComponents/VCamCaptured/)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 按机型/OS 确定完整组件集合，接入上游最终时钟/ring/采样率/路由实现。
2. 整合麦克风仅在录音期间采集、音量/静音和权限拒绝行为。
3. 与相机及 Hook 组合验证重复启停、双工、进程重启和环境更新。
4. 与 T44 共用 productType、board、guest build、cloudOS/kernel、模式、环境版本、新建/迁移矩阵，媒体另记录采样率与录放/双工。

**接受条件：**
- 44.1/48 kHz、播放/录音/双工、音量/静音和重复启停按支持矩阵通过。
- 权限拒绝不崩溃，不因仅更新 dylib 就宣布旧 VM 具备新音频链。
- 原 iPhone 的音频结果不代替 iPad/其他候选机型验证。

**验证入口：** `guest`, `patch`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 按音频完整写入集合恢复载荷、路由、DeviceTree repair、配置和激活状态。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T45 · 隔离实验性 120 Hz 与 FPS 功能

**优先级：** P2　**范围：** 可选延后　**状态：** `deferred_optional`

**依赖：** T10, T23, T34, T44

**旧项关联：** T23, T26。

**接口与产出：** 可选后续任务；本轮默认关闭 120 Hz，普通发布的关闭行为由 T10/T23 验收。

**上游范围：**
- [VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/CustomFirmwarePatches/Drivers/KernelCustomFirmwarePatchDisplayRefresh.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneCommand/FirmwarePatcher/Kernel/CustomFirmwarePatches/Drivers/KernelCustomFirmwarePatchDisplayRefresh.swift)
- [VPhoneExecutable/VPhoneVirtualization/Resources/patches_presets/standard.plist](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/Resources/patches_presets/standard.plist)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 在实验分支独立接入 FPS 显示和 kernel-exp-display_refresh_120hz，保持选择可解释。
2. 通过已验证 update-kernel 投递，并记录宿主显示器与 guest pacing。
3. 需要纳入支持范围时重新开启该任务，补足启用/撤销与性能证据后才宣传。

**接受条件：**
- 默认配置不启用；关闭恢复原 timing。
- 不保证任意宿主达到 120 FPS；未实施不阻断普通功能候选。

**验证入口：** `patch`, `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 关闭选项并恢复原 kernel 及记录。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。


## M6 · 文档与不可变发布候选

### [ ] T28 · 同步接口文档来源与执行证据

**优先级：** P1　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T04–T27、T32–T44、T46（全部主线实现项）

**旧项关联：** T28。原标题：同步 API 文档与执行台账。

**接口与产出：** API/配置/补丁/交付路径与真实代码一致；历史事实、当前实现和已验证组合有独立证据。

**上游范围：**
- [Research/vphoned_http_api.md](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/Research/vphoned_http_api.md)
- [Documents/Guides/launchpad-cli.md](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/Documents/Guides/launchpad-cli.md)
- [Research/0_binary_patch_comparison.md](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/Research/0_binary_patch_comparison.md)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 以最终代码更新方法、capability、参数、权限、超时、重试及旧 guest 行为。
2. 维护补丁对照研究记录、旧任务映射、版本来源和支持矩阵；不在仓库根创建 TODO.md。
3. 从每项任务回填实际 commit、测试、VM/恢复证据；解释未支持和可选项目。

**接受条件：**
- 白名单与响应结构来自 host/guest 同版本源码；没有四库/五库等过时文档差异。
- 已分析、已实现、已构建、已运行及已接受不混记。

**验证入口：** `docs`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 保留历史版本及其验收范围；文档回退不改变 VM 状态。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T29 · 组装发布候选并检查版本组合

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T28

**旧项关联：** T29。原标题：完成组合兼容与发布候选检查。

**接口与产出：** 候选绑定本地 SHA 和 upstream SHA；宿主、guest 环境、kernel、其他 boot chain 分别给出来源和兼容要求。

**上游范围：**
- [VPhone.xcworkspace/](https://github.com/Lakr233/vphone-cli/tree/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhone.xcworkspace/)
- [VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift)
- [VPhoneExecutable/VPhoneVirtualization/Resources/Info.plist](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneExecutable/VPhoneVirtualization/Resources/Info.plist)

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 按固定锁文件和源码构建完整候选，检查所有资源、权限和签名实物。
2. 区分 Core Bundle >=2.6.0 的代码门槛、同 major.minor series 的默认支持策略，以及 host/daemon/ABI/固件的不同兼容维度。
3. 混合版本分别跑禁止改写 guest 的纯兼容测试和显式升级/回退，记录连接前后 daemon/库 hash 与 instance，形成不可变候选。

**接受条件：**
- 本地版本号不冒充官方功能等价；未实现能力不借版本号绕过门槛。
- 旧/新组合按矩阵兼容或明确拒绝；T45 默认关闭且不计入已支持。
- 未验证更高 series 不借版本下限宣称支持；合法 local/CI 后缀正确解析，同 series 不同 patch 不要求版本数字完全相同。
- 纯兼容测试组合没有被自动同步悄然改写。

**验证入口：** `bundle`, `host`, `protocol`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 保留上一完整候选；更改候选后按影响范围重新验收。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。


## M7 · 组合回归 恢复和签收

### [ ] T30 · 执行声明范围的集成回归和故障注入

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T03, T29

**旧项关联：** T30。原标题：执行集成回归与故障注入。

**接口与产出：** 按 fixture、模式、固件、host/guest/ABI 组合记录 pass/fail/not_run/not_applicable，未测不能计通过。

**上游范围：**
实际本地仓库、历史工作和证据。该任务先采集信息，不预设虚构源码路径。

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 在受控测试副本执行方案中的策略、迁移、控制、网络和媒体矩阵。
2. 覆盖提交中断、能力缺失、旧配置、旧 receipt、Bundle 混用和实际启动。
3. 汇总用户关键应用/数据/身份及各任务残余风险，决定候选是否可签收。

**接受条件：**
- 所有声明支持的必需场景无未解释失败。
- 不要求无意义全排列，但每个纳入支持的组合都有实际证据。

**验证入口：** `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 失败回到对应恢复点，关闭受影响能力，不在唯一原 VM 上继续试错。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。

### [ ] T31 · 完成整组恢复演练与整合签收

**优先级：** P0　**范围：** 主线　**状态：** `pending_local_audit`

**依赖：** T30

**旧项关联：** T31。原标题：演练整组回滚并签收。

**接口与产出：** 恢复单位包含代码/Bundle、guest 文件、kernel/Preboot、配置、receipt/undo、身份和数据；最终证据与候选一致。

**上游范围：**
实际本地仓库、历史工作和证据。该任务先采集信息，不预设虚构源码路径。

**本地修改/新增/测试路径：** T02 核对后填写；当前 `resolve_in_T02`。上游路径只作为参照，不能直接当成本地已存在文件。

**执行步骤：**
1. 分别演练仅宿主回退、环境回退、kernel/磁盘回退，并确认各自边界。
2. 在恢复后重新验证启动、通信、目标应用、关键数据及身份/信任。
3. 记录接受范围、未支持范围和下一轮基线；独立评审后整合到本地目标分支。

**接受条件：**
- 至少一次真实整组恢复通过；仅切回旧 Bundle 不被视为 guest/kernel 已恢复。
- 签收依据包含实际代码、工件与 VM 证据；合并、部署、对外发布状态分别记录。

**验证入口：** `vm`（见后文；需记录本地实际命令和结果）。

**回退与保护：** 验收前不清理唯一备份或原件；失败保留上一可用组合。

**执行回填：** 本地等价位置/处理决定、负责人、上游来源、本地提交、实际测试命令与日志、工件摘要、VM/固件/模式、恢复点、残余风险、接受结论均待实际执行后填写。历史验收单独引用，不自动继承为本轮通过。


## 验证入口与命令

下列入口已对照固定上游工程与源码存在性；本地执行前仍需 T02 映射。它们是计划命令，不是本轮已经运行的测试。对共享工程并行运行时使用独立构建目录，避免产物互相覆盖。

### `baseline`

git status --short --branch；git rev-parse HEAD；git merge-base HEAD TARGET；固定范围 rev-list/diff。只读结果逐项归档。

### `patch`

```bash
xcodebuild -project VPhoneExecutable/VPhoneCommand/VPhoneCommand.xcodeproj -scheme FirmwarePatcherTests -destination 'platform=macOS,arch=arm64' test
```

### `sign`

```bash
xcodebuild -project VPhoneExecutable/VPhoneCommand/VPhoneCommand.xcodeproj -scheme VPhoneSignTests -destination 'platform=macOS,arch=arm64' test
```

### `core`

```bash
xcodebuild -project VPhoneKit/VPhoneKit.xcodeproj -scheme VPhoneCoreKitTests -destination 'platform=macOS,arch=arm64' test
```

### `archive`

```bash
xcodebuild -project VPhoneKit/VPhoneKit.xcodeproj -scheme VPhoneArchiveKitTests -destination 'platform=macOS,arch=arm64' test
```

### `hierarchy`

VPhoneDaemon/Tests/run-hierarchy-tests.sh（按该脚本声明的解释器运行）

### `daemon`

按实际 guest 目标构建 vphoned scheme；在 T02 登记该工程要求的 SDK/目的地，并以 guest 的 runtime hash 验证部署结果。

### `guest`

按已映射 GuestComponents Makefile/测试入口构建并验证 ABI；guest 联测单独登记。

### `host`

按本地已核实 Launchpad 构建及测试入口验证；纯界面部分用实际操作记录，不虚构 test scheme。

### `bundle`

```bash
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/XcodeBundle build
```

### `protocol`

由 T02 定位现有 transport/daemon 测试入口；增加本任务列明的契约用例，记录确切命令、request/response 和进程结果。

### `vm`

仅在 T03 的受控 VM 副本执行本任务验收；记录 host/guest/kernel/build/模式、命令、日志和恢复点。

### `docs`

验证接口示例、任务引用、路径、状态与最终代码；不为文档格式编辑另写产品测试。

### 构建与运行的补充要求

- 正式候选执行实际本地 Release/签名流程，并检查所有资源、slice、entitlements、helper、guest 载荷和运行依赖；Debug 命令仅提供可复现构建起点。
- 若触及 restore 层，按真实本地映射补跑 `VPhoneRestoreTests`；上游工程位于 `VPhoneExecutable/VPhoneCommand/VPhoneRestore/VPhoneRestore.xcodeproj`。
- 上游 AX 原生测试、guest 组件测试和 daemon 编译目标不能互相替代；编译与在 guest 中加载是两类证据。
- 对不可逆状态或数据风险，使用故障注入与真实恢复；低风险 UI/文档改动只做必要核对。

## 基线统计命令（只读）

从 T00 确认的实际仓库根运行；完整对象可用是前提。取上游对象另作为明确 fetch 步骤，不变更 origin、不覆盖工作区，不在此猜测本地目录。

```bash
git status --short --branch
git rev-parse HEAD
git remote -v
git merge-base HEAD 2d21d21fbdd4f51f013616273ceda9b35a3e0789
git merge-base --is-ancestor 9d218dedf58d4b19db5e51c8b584c1f14a96eee3 a969cd5d9206932dc1a2797348027fbc7d0ee347
git merge-base --is-ancestor a969cd5d9206932dc1a2797348027fbc7d0ee347 2d21d21fbdd4f51f013616273ceda9b35a3e0789
git rev-list --count 9d218dedf58d4b19db5e51c8b584c1f14a96eee3..a969cd5d9206932dc1a2797348027fbc7d0ee347
git rev-list --no-merges --count 9d218dedf58d4b19db5e51c8b584c1f14a96eee3..a969cd5d9206932dc1a2797348027fbc7d0ee347
git rev-list --count a969cd5d9206932dc1a2797348027fbc7d0ee347..2d21d21fbdd4f51f013616273ceda9b35a3e0789
git rev-list --no-merges --count a969cd5d9206932dc1a2797348027fbc7d0ee347..2d21d21fbdd4f51f013616273ceda9b35a3e0789
git rev-list --count 9d218dedf58d4b19db5e51c8b584c1f14a96eee3..2d21d21fbdd4f51f013616273ceda9b35a3e0789
git rev-list --no-merges --count 9d218dedf58d4b19db5e51c8b584c1f14a96eee3..2d21d21fbdd4f51f013616273ceda9b35a3e0789
git diff --find-renames=50% --shortstat a969cd5d9206932dc1a2797348027fbc7d0ee347 2d21d21fbdd4f51f013616273ceda9b35a3e0789
git diff --find-renames=50% --name-status a969cd5d9206932dc1a2797348027fbc7d0ee347 2d21d21fbdd4f51f013616273ceda9b35a3e0789
```

期望上游范围分别为 124/122、218/158、342/280；新增段端点 diff 为 357 路径、+46,978/−2,067。当前本地左右差异要独立计算，不能从这些数字相减推算剩余任务。命令输出可能含本地路径和远端信息，证据归档前按内容处理敏感值。

## 任务完成记录模板

```text
Task: Txx
Disposition: equivalent | adapt | new | superseded | deferred | unknown
Local baseline and paths:
Upstream SHA and final source:
Local implementation commits:
Preserved local behavior:
Actual build/test commands and results:
Artifact hashes and host/guest/kernel/boot-chain sources:
VM / mode / firmware fixture:
Failure injection and recovery evidence:
Historical evidence referenced (date and scope):
Remaining risk / unsupported combinations:
Acceptance and reviewer:
```

此模板是实际执行的回填字段；本轮没有使用占位提交、虚构测试输出或未经运行的 pass 来填充台账。
