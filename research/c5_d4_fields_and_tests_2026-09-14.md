# C5 实验记录与 D4 创建检查点：字段及测试准备

日期：2026-09-14。状态：设计草案，未接入生产 CLI，未实现创建续跑。本轮只准备字段、约束和测试方案；C5、D4 保持未完成。

## 现有实现与设计边界

- `PatchRunReport` 已记录 variant、gates、components、ablation；`PatchResult` 的结果与必要性规则已有定义。本方案引用现有报告，不复制另一套结果枚举或补丁计数规则。
- `FirmwareTransaction.Journal` 已有 version、id、vmPath、options、phase、entries、failure；其 phase 为 building、ready、publishing、rollingBack、committed。D4 引用这个事务的身份与结果，不将创建阶段替代为事务阶段。
- `VPhoneCreateOrchestrator.run` 当前按新建 bundle、prepare、patch、restore、非 less 的 CFW、first boot、JB 提示、boot analysis 顺序执行。同名目录存在时拒绝；还没有续跑入口。
- 当前 JB Finalize 段主要输出首次启动自动执行的提示，不能直接作为已完成的检查点。当前清理固件发生在 first boot 之前，D4 实现时必须重新审查恢复输入保留时机。
- C5 的完整验收依赖 C4；D4 的完整验收依赖 B4、C4、D3。字段准备不会解除这些依赖。

## C5：实验记录字段

建议新增独立的实验记录封装，引用现有报告及字节记录。下列字段名是草案，尚不是生产输出承诺。

| 字段 | 类型与含义 | 校验或比较规则 |
| --- | --- | --- |
| `schema_version` | 整数，初版 1 | 不认识的版本拒绝按当前规则解释 |
| `run_id`、`started_at`、`finished_at` | UUID 与带时区时间；未结束时 finished_at 为 null | 同一次运行身份稳定；比较条件时不包含 ID 和时间 |
| `status`、`failed_stage`、`error` | running/succeeded/failed/cancelled；失败阶段；结构化错误或 null | succeeded 不能带失败阶段；必要补丁失败不能被其他成功组件覆盖 |
| `source` | commit、dirty、源码文件摘要清单、差异摘要 | dirty 不能只有布尔值；必须能识别实际运行源码，包括新增、修改、删除文件；不收集任意环境变量 |
| `toolchain` | 宿主/Swift/Python 版本、依赖锁摘要、资源摘要 | 与 D2 的来源记录关联；未知值为 null 并注明原因 |
| `firmware` | iPhone 与 cloudOS 的 version、build、origin | 不从文件名补全未知构建号；来源记录不含 URL 凭据或令牌 |
| `variant`、`options` | 变体及规范化后的有效选项 | 同时记录默认值，避免“未传入”被误认为“关闭”；消融选项也必须记录 |
| `inputs[]`、`outputs[]` | component、相对路径、size_bytes、sha256、availability | 路径与组件不能重复；缺失产物显式记录 unavailable，不能伪造摘要 |
| `patch_report`、`byte_records` | 原有 JSON 的相对路径、格式、SHA-256 | 保留现有字段拼写及 recordIndices 关系；不把方法数与字节写入数混用 |
| `transaction` | C4 事务 ID、阶段、日志及报告引用 | 未提交事务不能作为正式产物成功证据 |
| `evidence[]` | 阶段、命令类别、退出码、日志引用及摘要 | 错误退出仍保存已有证据；日志输出失败单独报告，不覆盖原失败原因 |

比较分成三个结果：**实验条件是否相同、补丁结果是否相同、产物摘要是否相同**。条件相同不保证大型镜像逐字节相同；任何差异都应绑定具体字段。不把运行时间、临时绝对路径和 run_id 放入实验条件摘要；规范化数据采用固定键顺序与明确的数值类型。

JSON 是唯一结构化来源，人类可读摘要由 JSON 生成。部分失败也保存完整的运行外层字段，以及已经完成的组件结果；尚未执行的组件不能补成成功或不适用。

## D4：创建检查点字段

| 字段 | 含义 | 约束 |
| --- | --- | --- |
| `schema_version`、`creation_id` | 检查点版本与创建身份 | 首次创建时建立；重试保留 creation_id |
| `bundle_identity` | 机器标识摘要、bundle 路径、配置摘要 | 路径或 VM 名称不是唯一身份；克隆、替换身份须拒绝盲目续跑 |
| `effective_options`、`inputs_digest` | 规范化创建选项及输入条件摘要 | 版本、变体、Frida、EXP 身份选项改变时定位受影响阶段，不沿用旧成功状态 |
| `attempt_id`、`resumed_from` | 本次尝试身份、上一份检查点引用 | 每次续跑保存上一份记录，不能覆盖失败历史 |
| `stages[]` | prepare、patch、restore、cfw、first_boot、jb_finalize、verification | 每阶段保存状态、起止时间、输入/产物引用、验证器版本及证据 |
| `stages[].status` | pending/running/succeeded/failed/cancelled/not_applicable | 不适用必须有变体规则；进程退出后遗留 running 需要重新核实 |
| `recovery_required` | 是否存在需先处理的中断、事务或设备状态 | 这是待处理状态，不自动等价于可安全重试 |
| `retained_artifacts[]` | 后续阶段及恢复仍需要的输入 | 未完成消费者阶段前不得自动删除；显式删除后记录不可用及重建方式 |

阶段成功需要“执行结果与验证器均通过”，不能仅按退出 0 写入 succeeded。restore 需要核对目标身份和设备状态；first_boot 需要客户机就绪证据；jb_finalize 需要最终状态，而不是日志中出现启动提示。less 的 cfw、非 JB/EXP 的 jb_finalize 应按规则标为 not_applicable。

检查点写入应在实例排他保护中完成：写临时文件、同步文件、替换、同步目录。文件持久化不表示整个 VM 创建事务具有原子性。C4 固件事务未恢复时，续跑应停止在明确的恢复要求处。

## 续跑判断顺序

1. 取得库与实例所需的占用保护，验证创建身份；现有运行任务存在时拒绝写入或续跑。
2. 验证检查点版本、字段、路径及引用；拒绝损坏文件、路径越界和未知阶段。
3. 处理未结束的 C4 事务及运行记录。restore 中断必须重新探测设备，不能按旧 PID、旧 DFU 状态或旧日志直接继续。
4. 核对源码、工具、输入、选项与产物。只有契约允许的变化才可复用；默认拒绝未知兼容性变化。
5. 逐阶段运行只读验证器，决定保留、重跑或拒绝。跳过执行也必须留下新的验证证据。
6. 所有必需阶段确认后标记创建完成，再按后续用途处理保留产物。

## 无 VM 测试方案

| 场景 | 驱动方式 | 预期结果 |
| --- | --- | --- |
| 相同输入两次实验 | 临时小文件与固定工具/选项，改变 run_id 和时间 | 实验条件比较相同，差异报告只列运行身份与时间 |
| 选项或组件变化 | 单独改变变体、消融选项、一个输入字节 | 条件比较指出具体字段；不能只比较补丁总数 |
| 必要补丁失败或取消 | 替身组件成功后失败/取消 | 保留已完成部分，未运行部分不计成功，原错误保留 |
| 日志或记录写入失败 | 临时目录中注入 ENOSPC、rename、fsync 失败 | 不留下可被当作完整成功的记录；不掩盖原错误 |
| 阶段故障矩阵 | 替身执行器在每阶段执行前、执行后、检查点提交前失败 | 首次执行和续跑序列可核对，不跳过未验证阶段 |
| 产物损坏/移走 | 成功检查点后改变文件、身份或配置 | 验证失败，拒绝错误复用 |
| 状态文件损坏/未来版本 | 截断 JSON、未知 schema、重复阶段 | 拒绝加载，不启动执行器 |
| C4 事务未提交 | 合成 building/publishing/rollingBack journal 引用 | 报告 recovery_required，不自动标记 patch 成功 |
| 锁冲突和并发续跑 | 临时目录、受控子进程和真实目录锁 | 只有一个调用可进入写入；失败者不改检查点 |
| 不适用阶段 | less、regular、dev、jb、exp 的阶段规则 | 仅适用规则允许跳过；缺少执行结果不等于不适用 |
| 恢复输入保留 | 未完成 first_boot/verification 的合成状态 | 清理器保留被后续阶段引用的输入 |

上述为待实现的测试清单，不是已通过测试。优先实现最小纵向流程：prepare 的记录/失败保存与只读验证，然后接入 patch/C4，最后接入 restore/CFW/客户机阶段。

## 需要 VM 的后续验收

| 场景 | 前置条件 |
| --- | --- |
| restore 中断后重新探测和续跑 | 专用 VM 独占、身份已记录、可重新准备的固件输入及空间预算 |
| CFW 中断与重复安装 | D3 各变体真实安装验收完成；VM 关闭并可独占挂载 |
| first_boot、JB finalize 断开/重启 | 客户机可用，明确成功判据，保留失败日志与恢复输入 |
| 完整 less 成功提交与续跑 | C4 暂停决定解除，满足空间与权限条件 |

本轮不触发这些验收，不修改 VM、C4 日志或创建流程。
