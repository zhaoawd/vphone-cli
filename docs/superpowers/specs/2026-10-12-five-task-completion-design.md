# T24、T40、T09、T10、T11 完成方案

日期：2026-10-12。状态：用户已确认五项范围和设计方向，实施计划待审阅。

## 目标和依据

用户要求继续推进并完成 T24、T40、T09、T10、T11，已分别回复“按建议推进 T24、T40、T09、T10、T11”和“同意，按这个方向推进”。工作分支为 `codex/upstream-2d21d21-integration`，起点为 `0d76f6365049c5baeba89867678fc7999a4cd505`。

验收依据为 `research/upstream_integration_2026-10-06/tasks.json` 的原步骤、接口、接受条件和剩余工作。保留 C1、C2、C10 契约。单元测试通过、静态审计通过和固件对照通过分别记录，不据此推定 VM 验收通过。

本次准备证据位于 `research/upstream_integration_2026-10-06/evidence/2026-10-12-five-task-audit/`。尚未修改产品实现或调整任务接受状态。

## 方案比较

| 方案 | 影响 | 决定 |
| --- | --- | --- |
| 复用现有事务、manifest 和 Bundle 绑定，补足身份、来源及执行证据 | 保留已有恢复路径；需要扩展现有记录和调用入口 | 用户已确认采用 |
| 独立建立新的配置及执行系统 | 需要维护两套配置和迁移路径 | 不采用 |
| 只补单元测试并将五项标为完成 | 无法满足原真实验收条件 | 不采用 |

## T09：固定声明和选择迁移

固定目标为 `2d21d21fbdd4f51f013616273ceda9b35a3e0789`。从目标源码重新提取声明、预设、版本条件和调用路径。逐项记录目标的 141 条声明与本地实现、五种变体、默认值及迁移的关系。声明数量本身不建立补丁效果等价性。

一对一、更名、拆分、合并、移除和本地无实现分别有显式决定。无实现、歧义、未知或重复 ID 不获得执行资格。显式关闭保留；迁移不能用新默认值覆盖用户选择。拆分或合并涉及不能分别执行的本地步骤时，拒绝无法保留原意的选择。

沿用 `PatchSelectionFileMigration` 的预览、原文件备份、来源摘要复核和原子发布。迁移结果仍需经过 C2 导入和 C1 解析，迁移本身不授权写固件。

## T10：冻结计划和逐项执行证据

沿用 `VariantPlanResolver`。实际 mode、固件版本与 build、选择和固定 catalog 只解析一次。CLI、create、Swift 流水线及 guest Python/zsh 写入入口使用同一计划及其摘要；不在后续步骤读取变化后的选择重新解析。

补充声明与实际 `patchID` 的明确映射。一个 Swift 步骤包含多条声明时，每条实际记录独立归属；不能用该步骤的其他成功记录证明某个必需补丁完成。未知记录、多个声明同时认领、遗漏必需声明、越过变体或版本门均在发布前拒绝。

已经应用的补丁只有在输出字节或对应文件状态经过验证后才能形成完成证据。guest 写入返回包含声明 ID、目标文件、输入与输出摘要及结果的结构化记录。执行计划与回报不一致时不得提交成功状态。

外部可执行 patchset 默认关闭。root 执行路径不加载用户提供的 patchset 代码。保留 regular/dev/jb/exp/less 的本地策略；不将其名称等同于上游 standard/experimental。

## T11：计划持久化和显式导入

复用现有 `FirmwarePlanBinding`、事务 journal 和 VM manifest，不建立第二套独立选择配置。持久化记录补足稳定 VM 身份、mode、输入 build/digest、固定 upstream target、catalog digest、schema、planDigest、磁盘及 generation 的对应关系。路径和 inode 只用于并发变更检测，不作为跨移动、改名的稳定 VM 身份。

读取明确区分 missing、permission denied、corrupt、unsupported schema、VM mismatch 和已识别 legacy。解码失败不采用默认计划。事务 journal 作为恢复证据，不能直接作为新一轮写入授权。

显式 legacy 导入先识别来源、展示差异并保存原记录。来源或 generation 无法确认时保持只读资格。保存采用暂存、同步、原子发布和读回；保留旧版本。发布结果不确定时要求读取实际状态，不盲目重试或声称回滚成功。现有 VM 锁和事务门禁覆盖这些入口。

## T24：宿主约束和运行责任链

沿用 root-owned Bundle store、签名 receipt、launcher 专用 verb 和现有 caller 校验。覆盖错误 owner、共享可写路径、链接替换、旧 helper、未知 verb 及 fallback。fallback 不能绕过普通启动路径的门槛。

实际构建检查架构 slice、entitlement、usage description、签名、资源及运行依赖。直接 CLI 和 Launchpad → launcher → 可信 store 两条路线分别验证实际负责 TCC 的应用、权限允许、拒绝、撤销及重连。单一 VM 工件的 AMFI 放行不作为 TCC 验收。

当前合并产物的 VM `--help` 收到 SIGKILL，amfid 记录 `-424`：`The file is adhoc signed but contains restricted entitlements`。当前 CDHash 为 `cce2b11198b668d5bf8e9ec662d18548a12f6444`。真实验收前需完成候选构建并冻结最终工件，再提出具体安全操作范围；旧工件授权不复用。

## T40：每机绑定、创建冻结及四层来源

分别记录 host Bundle、guest environment、kernel 和其他 boot chain 的来源、摘要、安装及激活证据。切换 host Bundle 不自动同步 guest，不改变 kernel 或其他 boot chain 的来源。缺失、损坏或不支持的绑定拒绝启动并给出恢复指定 Bundle 或显式重新绑定的操作提示。

创建全过程使用固定版本的工具链和资源。现有资源及 ROM 快照继续复用；Python/framework/packages/native dependencies、PATH 工具、SDK/JB 编译输入、固件来源及 CFW 输入需纳入可验证的固定输入，关闭执行期间读取变化来源的路径。最终创建发布可信绑定及 receipt。实验副本探测不能代替产品创建流程。

验证合法 local/CI 版本并存、同 series 不同 patch 版本、clone/export/rename、缺 Bundle、host 回退及纯兼容连接。对显式 guest 升级、回退和 kernel-only 更新分别记录四层来源、guest hash 和运行实例的前后状态。

完整验收需要完成 T12 generation、T17 在线激活、T32 分组件 receipt、T34 kernel 更新的必要能力，并遵守这些任务的前置条件。不能以减少矩阵来规避这些依赖，也不将这些依赖任务的局部实现自动标记为整项完成。

## 实施顺序和验证

先完成 T24 只读前置审计及固定上游源码恢复，然后按 T09 → T10 → T11 完成实现与失败用例。随后完成 T24 实际责任链和 T40 必要依赖、创建及四层来源矩阵。

每个行为修改先复现失败，再修正并运行相关测试。完成后运行 `make test_python`、`make test_swift`、完整 fixture 的 `make test_firmware`，在独立构建目录运行 `make build` 和 guest 组件构建，最后执行已授权的真实验收。补丁发生变化时更新 `research/0_binary_patch_comparison.md`。

主工作区保留当前分支及三个既有未跟踪研究文档。准备阶段不重建主工作区、不操作现有 VM、不修改系统安全设置。真实 VM 验收先形成明确的候选、备份、目标 VM、操作范围和恢复步骤，再取得所需授权。

本轮已有基线：55 项测试、8 个测试套件通过。固定目标源码的 141 条声明 ID 与历史集合一致；五模式适用性和二进制效果尚未重新验收。五项原接受条件未全部满足前，保留未完成状态。
