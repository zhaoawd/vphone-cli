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


## 2026-10-19：DSC 完整伴随输入清单

2026-10-19 当前状态：b00e1d3c 已提交并 push。独立 DSC 第二次 CFW 在 .34.dyldreadonly 枚举处拒绝，原磁盘身份/mtime 与 66 段采样保持，未交换。完整只读清单确认 80 个成员及 10 个伴随输入。精确输入保持修复、实际隔离副本补丁与 6885 代码页验证通过；完整 Python 931 项（跳过 2 项）、相关 Swift 12 个测试函数及实际 release verifier 通过。签名资源/依赖/entitlement 核验通过，VM 字节及获批 CDHash 保持。第三次安装 session69696 等待原生管理员验证 PID39449；放行进程恢复等待 PID22867。真实发布、撤销与正常启动仍未验收，T32/T33 未 accepted。

最小 producer 回归在约 1 秒内复现第二次安装的同名拒绝。只读原始 Cryptex 包含 dylddata、dyldreadonly、dyldlinkedit 和 atlas；编号伴随文件包含执行权限的头部映射，未将其归类为纯不可执行数据。修复仅按精确名称保存输入前后完整摘要、身份、属性和集合，现有写入目标映射与 catalog 保持；任何变化仍拒绝发布。真实来源的 80 成员隔离副本中，仅 .42 发生 SwapEnd 0x548→0x560 与相应代码页摘要变化，全部 6885 代码页通过，10 个伴随输入保持。源缓存完整摘要前后相同。该隔离回放没有写入 VM，不构成实际发布或启动验收。

新增三类后缀的正向、五类变化拒绝、符号链接提前拒绝回归；完整 Python 931 项，跳过 2 项，242.969 秒，退出 0。实际签名 release verifier 的 12 个 Swift 测试函数通过，含 8 类身份/篡改参数及全部伴随类型。更新已完整构建应用的 Python 资源，先恢复外层签名，再记录依赖并最终封签；完整 bundle 校验通过，VM 二进制和已获批 CDHash 保持。证据：`evidence/T32-T33-new-vm-20261018/dsc-companions-20261019/manifest.json`。


## 2026-10-19：独立 DSC v4 发布与真实启动

2026-10-19 当前状态：83d4e69d 已提交并 push。独立 DSC 第三次 CFW 退出0，v4事务20261019T065441Z-XzJThk9M完成两次最终核验、快照、封存、交换及归档。未启动磁盘原件/补丁各6885代码页通过，w3从0x548改为0x560。首次启动与两次API正常启动/关机通过，读回26.0/23A341；运行后Receipt及generation verifier通过，当前镜像与发布镜像摘要分开，runtimeValidated:false。获批CDHash放行已生效。实际Undo的原生验证已完成，root73597/session58124开始；撤销、撤销后启动及重新应用的on→off→on仍待验收，T32/T33未accepted。

安装后持锁核对真实journal、独立发布副本和原始来源诊断：.42原件SHA为`e41db9aa09ab60cb6015282c9230fba89a8971129fae00c16156b29b1855c9b5`，补丁件SHA为`2fc23949b0ee8f17d01af28d83e814ee96aabc4918f46537f890843233a113ac`；Capstone语义读回w3 0x548→0x560，原件及补丁件各6885个CodeDirectory代码页通过。首次启动前当前整盘与发布摘要`ff453e298a2be2109b020f92e08f9f931f65f30a51efcbf347fa2b1f2762d10d`相同。

生产首次启动7条命令、提示符及正常关机通过。之后两次API启动读回26.0/23A341，启动时间和会话UUID不同，均记录apiAccepted、Guest stopped、退出0，无框架强制停止，磁盘/目录锁释放，配置/daemon摘要保持。真实运行后生产Receipt返回committed-publication，currentImageSHA256为`5948a0329f9ad0a469ce9c6ac851cbf90b18a41399e5b03eed6bb58e84c3184d`，runtimeImageChanged:true、runtimeValidated:false；实际Swift generation verifier也退出0。此结果证明已记录的启动和历史读取，不证明当前全部效果或显示行为。

此前放行worker附加失败后退出；之后只读观察到amfid出现及再次退出，原调用未保存LLDB错误细节，原因未完全确认。对同一获批程序执行有时限的非法参数探测后，目标62017持续存在；用户完成重试验证后，现有helper68388附加，精确CDHash放行及参数64通过。未加载或修改持久允许列表。实际Undo现由新staged事务执行，尚未登记成功。证据：`evidence/T32-T33-new-vm-20261018/dsc-publication-20261019/manifest.json`。


## 2026-10-19：Undo可写APFS分配统计

2026-10-19 当前状态：aef7f99c已push，独立DSC安装、原件/补丁各6885代码页、首次启动、两次API正常关机及运行后v4读取均通过。首次Undo在staged恢复后因整份可写APFS容器比较而拒绝，未发布；原盘身份/mtime与66样本保持。最小事务与原生隔离APFS确认容量统计变化足以触发同一错误。已仅在可写Undo比较中排除CapacityFree和卷CapacityInUse；其余容器字段、UUID、设备/路径/root身份及最终只读严格比较保持。相关27项、完整Python935项（跳过2项）及实际release verifier的Swift12函数通过，签名/依赖核验通过。修复后Undo已发起，状态见证据清单；真实重试、撤销后启动及重新应用on→off→on仍待验收，T32/T33未accepted。

真实事务`20261019T074108Z-8MSU4jQD`保留了guest-undo-applied：staged .42从2fc23949...写回原件e41db9aa...，实际写回及完整代码页检查已执行；随后第二次check_mount拒绝，未封存或交换。原盘保持检查仅覆盖身份/mtime及66样本，未在失败清理阶段重算整盘摘要。失败staged已按安装器流程移除，journal、请求、实际写入记录和blob保留。

最小事务回归2.496秒复现相同写入后拒绝。全新128MiB隔离APFS写8MiB后，仅CapacityFree与卷CapacityInUse改变，根目录身份、实际设备、路径及可写状态保持，正常卸载。修复仅在可写Undo比较排除此二统计字段，其他字段仍完整比较，最终只读比较未修改。新增写入后UUID变化拒绝、只读容量变化拒绝及容器字段保持回归。真实失败未保存前后完整容器快照，原运行是否仅此触发仍由重试验证。

完整Python935项（跳过2项），244.185秒，退出0；相关27项及新签名release CLI的Swift12函数通过。资源/依赖/签名/entitlement通过。后续boot继续使用原已放行程序，字节/inode保持；先前helper退出后该程序仍返回参数64，无需新增CDHash授权，周期探测已停止。证据：`evidence/T32-T33-new-vm-20261018/undo-allocation-20261019/manifest.json`。
