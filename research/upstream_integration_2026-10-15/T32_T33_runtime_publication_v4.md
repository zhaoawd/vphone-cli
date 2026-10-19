# T32/T33：运行后的 guest 发布证据

日期：2026-10-19。真实对象为独立 `vm-t32-t33-20261018-r2`；后续 DSC 对象为 `vm-t32-t33-dsc-20261018`。T32/T33 未登记为 accepted。

## 问题与证据

r2 的第五次 CFW 事务 `20261019T013451Z-H0YWJ2mL` 完成两个最终只读效果核验、快照名称修改、封存、交换和归档。正式 create 退出 0，首次及验证提示符启动均通过。随后当前 classic API 的两次独立启动和正常关机通过：启动时间和 boot session UUID 不同，均记录 `apiAccepted` 和 `Guest stopped`，没有 framework 强制停止，磁盘与目录锁释放，配置与 staged daemon 摘要保持。

运行后 `cfw receipts` 与 `cfw verify-plan` 拒绝现有 v3 事务。实际检查点摘要、5 个封存文件及 297 个 blob 均保持；保存计划与当前 desired plan、generation、配置及 machine binding 匹配。当前磁盘 dev/inode/size 保持，mtime 与整盘 SHA-256 已变化。v3 将发布效果与之后可写的运行磁盘的完整字节绑定，因此无法在正常运行后提供同一 journal 的历史证明。最小回归在同一 inode、相同大小镜像内修改一个字节即可复现拒绝。

证据见 `evidence/T32-T33-new-vm-20261018/runtime-boundary-20261019/manifest.json`。旧工具使用当前 classic 配置缺少的 shell 能力，其失败单独保存；新增 `--api` 选项后通过正常关机断言。沙箱内 AppKit `_RegisterApplication` 中止也单独保存，宿主执行通过。

## 新事务格式

新增 journal v4 与 guest checkpoint schemaVersion 2。v3 读取、交换、finish 和恢复仍保持原有完整镜像要求，不改写旧 journal，也不为旧磁盘补造发布副本。

v4 在最终只读效果核验并卸载后，将 staged 镜像保存为私有 `guest-postimage.img`。APFS 克隆不可用时使用排他创建的稀疏完整复制。保存过程检查源文件稳定性、fsync 和完整 SHA-256；检查点记录该副本的身份元数据及发布镜像摘要。原始安装前磁盘继续独立保留为归档内的 `Disk.img` 或 `Disk.img.previous`。

交换前、交换后 finish、恢复路径仍要求当前镜像与发布镜像的完整身份及 SHA-256 一致。只有已提交归档的历史读取允许运行盘的 mtime/内容变化，同时要求 dev/inode/size/birthtime 连续、封存发布副本的身份和完整摘要一致，且计划、generation、操作记录、最终效果报告、Undo 索引和 blob 集合仍全部通过核验。journal 的 v4 必需字段与检查点版本必须匹配。

历史读取分别返回发布 `imageSHA256` 和本次实际读取的 `currentImageSHA256`。运行盘内容改变时状态为 `committed-publication`，`runtimeImageChanged:true`，`runtimeValidated:false`。这些字段不确认当前组件效果或 guest 来源。读取从整盘摘要开始至所有封存证据核验结束都检查镜像属性稳定性；读取期间变化则拒绝。

DSC 撤销先将当前运行盘克隆到新事务，并比较该克隆与父事务本次读取的当前镜像摘要。历史发布摘要继续用于父事务 Receipt 绑定。实际写入前仍核对当前 DSC 文件的完整字节、大小、所有者、权限和全部 CodeDirectory 代码页；最终只读核验仍检查所有保留效果，并共同发布新的 Undo/Receipt/来源 unknown 记录。历史候选仍不授予写入权限。

Swift generation 关联核验读取同一 v4 发布副本和封存文件，沿保留的原磁盘追溯原始 generation。运行盘物理连续性只建立 generation 的机器关联，不证明当前效果、来源或撤销权限。

## 验证与未完成范围

最小运行写入回归先失败后通过。补充发布副本缺失、字节变化、inode 替换、符号链接、运行盘替换或大小变化、发布完成前写入、v4 降级、克隆失败及完整复制替代路径。新增读取期间写入回归先失败，修复后相关 57 项通过。

实际 Swift plan verifier 的两次安装、每次后的模拟运行写入、一次实际撤销及撤销后模拟运行写入通过；原检查点、磁盘、machine binding、保留原盘拒绝条件保持，并新增发布副本变化/替换和运行盘大小变化的拒绝。相关 Swift 12 个测试函数通过（含参数化用例），新签名 release CLI 也完成同一回归。

首轮完整 Python 918 项有 4 个夹具失败、跳过 2 项：v1 夹具残留新 v4 字段，以及三个归属权清单未包含新增发布副本。夹具已修正，全部原断言保留，四项定向复验通过。最后完整回归与实际 DSC 安装/撤销/启动结果将在执行后追加。

真实 r2 使用 v3，运行后仍按原要求拒绝。新 v4 必须通过独立 DSC VM 的真实安装和撤销验证后再登记相应证据。Mach-O/Preboot 撤销、任意中间操作重打及受信 guest 来源推进仍未完成。


2026-10-19 当前状态：r2 第五次 CFW 已发布、create 退出 0、两次提示符启动及额外两次 API 正常启动/关机通过。已实现 v4 独立发布后镜像、运行身份连续性及读取期间稳定性检查，旧 v3 严格拒绝条件保持。最终 Python 全量 919 项（跳过 2 项）退出 0，相关 Swift 12 个测试函数及实际签名 release verifier 回归、完整签名构建、六脚本资源摘要核对通过。DSC VM 正式安装命令已启动，等待原生管理员验证，尚无磁盘事务；最终 CDHash 89b70a253cad2adea133b3e875519afaf72c5d17 的补充批准尚待回复。实际 DSC 撤销未执行，T32/T33 未 accepted。 证据：`evidence/T32-T33-new-vm-20261018/runtime-v4-20261019/manifest.json`。运行证据边界与格式说明见 `T32_T33_runtime_publication_v4.md`。本阶段未更改新的固件指令匹配或替换算法。


2026-10-19 当前状态：合并已完成，r2 第五次 CFW 发布、提示符启动及额外两次 API 正常关机通过；v4 独立发布副本与运行后历史证据已实现。独立 DSC 首次 CFW 在后续 producer 枚举 .33.dylddata 时拒绝，原磁盘身份及 66 段采样保持，未交换。已完成只读来源检查和输入保留修复；完整 Python 922 项（跳过 2 项）、相关 Swift 12 个测试函数及实际 release verifier 通过。资源更新、依赖、签名和 entitlement 核验通过，VM CDHash 保持获批 89b70a253cad2adea133b3e875519afaf72c5d17。重试 session82810 等待原生管理员验证。用户已要求提交并 push；真实 DSC 发布、撤销及后续启动仍待验收，T32/T33 未 accepted。

修复前最小 producer→最终核验回归复现 `undeclared DSC write member`。真实只读检查记录 3 个普通伴随文件，包含执行权限映射，因此不将它们归为纯不可执行数据。现有写入目标规则及 catalog 保持；仅按精确编号名称将其作为输入，并在补丁前后核对完整字节、身份、属性和集合。任何变更仍拒绝发布。新增正向及五类变更拒绝、符号链接拒绝回归通过。一次相关套件运行被沙箱 EPERM 阻止，未弱化断言；标准宿主全量 922 项通过。

已批准最终 CDHash 的现有 amfidont 仅加载该值；不加载或修改持久允许列表。`--help` 实际返回 0 且无输出；提供必需 --config 后，当前与保留程序均按预期拒绝非法选项、退出 64，确认进入参数解析。可选的 root 私有日志读取请求已取消，没有干预正式安装。证据：`evidence/T32-T33-new-vm-20261018/dylddata-20261019/manifest.json`。
