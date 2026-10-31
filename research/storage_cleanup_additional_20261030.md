# vphone-cli 新增清理评估（2026-10-30）

最新状态：用户随后要求“完全清理c”，旧 DSC VM 的整个剩余目录已删除，包括此前保留的 generation 和固件历史。本次额外移除分配量 20.917 GiB，卷可用空间即时增加 20.918 GiB；被引用的约 328 KiB 原始 ROM 另存并核验为输入归档。具体结果及旧输入路径退役影响见 `research/storage_cleanup_c_full_20261030.md`。下文保留较早 A+B 及 C 两项清理的阶段记录。

执行结果：A+B 共 12 项已按用户“先清理a+b，另外旧dsc vm是什么”的指令删除；随后用户明确要求“清理c这块”，C 组两项也已删除。两次执行均退出 0。A+B 执行时卷可用空间即时增加 12.893 GiB；C 执行时卷可用空间即时减少约 52 MiB，未观察到净增加。各阶段的保留对象复核通过，原始 ROM、generation 和验收计划保持。

以下保留评估时的具体清单及影响。A 组可从保留 tar 或重新下载恢复；B 组删除后失去两轮失败现场的完整二进制重放能力。C 组已退役的两项分配量合计 24.399 GiB，旧 VM 现已无法启动。

## C 执行与验证

- 执行器：`research/storage_cleanup_c_20261030.py`。无参数预检及 `--apply` 均退出 0，使用当前用户权限完成，未发起管理员认证。
- 范围仅为 `vm-t32-t33-dsc-20261018/Disk.img` 与 `vm-t32-t33-dsc-20261018/iPhone17,3_26.0_23A341_Restore`。删除前重新检查整个旧 VM 及两项对象的打开句柄、挂载、操作锁、目录写权限和 Git 跟踪状态，归档 60 份小型记录并逐成员核验。
- 最新计划对两项对象的直接引用仍只有旧磁盘在 `unrelatedDiskIdentities` 中的一项保留身份。原始 ROM 完整摘要与 `frozenInputs` 匹配，删除前后及独立复查均保持。原计划不改写；旧磁盘保留检查已不再满足。`retirement.json` 单独记录退役路径、原计划摘要、旧磁盘身份和保留 ROM，未来计划需要明确登记退役例外，不将旧计划表述为可重跑。
- 两项均确认不存在。568 项保护记录删除前后及独立复查保持一致，包括其余 VM/备份的选定磁盘元数据、可读启动文件摘要、旧 VM 的 generation/固件历史目录和文件元数据、原始 ROM 摘要、保留候选 tar、失败事务其余记录、诊断记录、Python 环境链接和验收计划摘要。没有重新计算保留的完整 VM 磁盘和旧固件大镜像摘要。
- 删除文件的分配量为 26,198,761,472 字节（24.399 GiB）。卷可用空间记录为 52,108,775,424 → 52,054,245,376 字节，即 48.530 → 48.479 GiB，差值 -54,530,048 字节（约 -52 MiB）。独立复查时为 49,561,600,000 字节（46.158 GiB）。不同时间的卷读数持续变化；本次未隔离并发写入或测量 APFS 独占 extent，实际物理回收量未确认，不能将上述差值归因于单一因素。
- 未启动或停止 VM，未执行 CFW、固件重建或产品测试；本项不证明旧 VM 可以恢复。60 份小型归档记录不能恢复完整磁盘或 Restore 工作目录。

执行证据：`research/evidence/storage-cleanup-c-20261030/`，含 `plan.json`、`inventory.json.gz`、`retired-small-records.tar.gz`、`small-records-manifest.json`、占用及挂载记录、`protected-after.json`、`retirement.json`、`result.json` 和 `independent-verification.json`。执行器已记录完成状态，拒绝重复执行。

## A+B 执行与验证

- 执行器：`research/storage_cleanup_ab_20261030.py`。先运行无参数预检，再运行 `--apply`，两次均退出 0；使用当前用户权限完成，未发起管理员认证。
- 删除前再次核对固定 12 项范围、真实路径、完整清单、目录写权限、目录锁、Git 跟踪状态、当前计划直接引用、挂载、打开句柄和相关进程。六个解包目录与保留 tar 的 1682 个普通文件及模式、类型、符号链接比较再次通过。
- 两轮失败事务的 8 份不超过 8 MiB 的 JSON 小型记录先归档并逐成员读回核验；两份约 56 MB 的 `guest-changes.jsonl` 留在原处，删除前后完整摘要及元数据保持。保留各轮 `transaction.json` 的内容和元数据。
- 12 项删除后均不存在。782 项保护记录删除前后及独立复查保持一致，含 C 组旧 VM 全部可读目录和文件的元数据、选定 VM/备份的磁盘元数据及可读启动文件摘要、失败事务其余文件的完整摘要、保留 tar 摘要、诊断记录、Python 环境链接和最新验收计划摘要。未重新计算保留的完整 VM 磁盘和旧固件大镜像摘要。
- 独立复查再次核对 12 项不存在，重新读取保护状态并逐成员核对小型归档，全部通过。没有修改验收计划、启动或停止 VM、执行 CFW、运行产品测试或重建缓存。
- 执行器的卷可用空间记录：26,408,161,280 → 40,252,334,080 字节，即 24.595 → 37.488 GiB，增加 13,844,172,800 字节（12.893 GiB）。稍后的独立读数为 34,979,840,000 字节；不同时间的卷读数仍有变化，原因未在本次清理中调查，不归因于单一进程，也不作为独占物理块计量。

执行证据：`research/evidence/storage-cleanup-ab-20261030/`，含 `plan.json`、`inventory.json.gz`、`package-comparisons.json`、`failed-small-records.tar.gz`、`small-records-manifest.json`、占用及挂载记录、`protected-after.json`、`result.json` 和 `independent-verification.json`。执行器有完成记录后拒绝重复删除。

上轮已删除的十项不重复计入。本次所有路径均相对 `/Users/kolar/github/vphone-cli/`，仅表内对象属于候选，其父目录和相邻文件不在范围内。

## A：可恢复副本和依赖缓存，1.771 GiB

| 路径 | 分配量 GiB | 结果及影响 |
| --- | ---: | --- |
| `.build/t32-t33-completion-20261023/exp-bootstrap-pristine-9770-20261025` | 0.18137 | 与保留的 `2.6.2-local.9770cba52828.tar` 比较通过。 |
| `.build/t32-t33-completion-20261023/exp-plist-lifetime-pristine-3ffd-20261025` | 0.18137 | 与保留的 `2.6.2-local.3ffd9e46ee74.tar` 比较通过。 |
| `.build/t32-t33-completion-20261023/exp-reboot-recovery-pristine-f430-20261026` | 0.18137 | 与保留的 `2.6.2-local.f43043c4c559.tar` 比较通过。 |
| `.build/t32-t33-completion-20261023/exp-reboot-recovery-pristine-f430-20261026-r2` | 0.18137 | 与同一 f430 tar 比较通过。 |
| `.build/t32-t33-completion-20261023/exp-staged-dsc-pristine-e127-20261025` | 0.18137 | 与保留的 `2.6.2-local.e12747163c76.tar` 比较通过。 |
| `.build/t32-t33-completion-20261023/source-identity-pristine-73b-20261026` | 0.18155 | 与保留的 `2.6.2-local.73b536cbb70c.tar` 比较通过。 |
| `.build/artifacts` | 0.22540 | SwiftPM 下载或解包的二进制依赖；后续构建可能需要重新下载及解包。 |
| `.build/daemon-api-icli086-20261021/PackageCache` | 0.11322 | 旧 daemon 构建的包缓存；后续构建可能重新下载依赖。 |
| `.build/daemon-api-icli086-20261021/Xcode/SourcePackages` | 0.17204 | 旧 daemon 构建的依赖检出和产物；恢复该构建需重新解析及检出依赖。 |
| `.build/t52-consumer-fix-20261022/daemon-api/Xcode/SourcePackages` | 0.17204 | 同类旧依赖目录；恢复该构建需重新解析及检出依赖。 |

六个解包副本合计 1.08839 GiB，四个依赖目录合计 0.68269 GiB。保留五份对应 tar、候选 JSON、依赖锁定文件、源码及构建日志。解包副本删除后，历史构建工具如需原路径，须先从对应 tar 恢复。

复用项目已有只读比较器 `research/project_storage_review_20261024.py`。五份 tar 完整 SHA-256 与候选记录匹配；六个目录共 1682 个普通文件的内容摘要、模式、成员类型和符号链接比较通过，未发现额外未归档成员。最新计划的冻结输入及其他字段没有这些目录的直接引用。

另外检查的 `exp-cryptex-links-package-20261024` 未找到 CLI 摘要相同的候选记录；`exp-cryptex-links-package-20261024-r2` 与本次尝试的候选 tar 存在 provenance 文件大小差异。两项未纳入建议，没有将其标为可从已核验 tar 完整恢复。

## B：两轮失败事务的二进制证据，12.403 GiB

| 路径 | 分配量 GiB | 结果及影响 |
| --- | ---: | --- |
| `.build/t33t-20261025/.cfw-history/20261025T100633Z-Bvlz2q7C/effect-blobs` | 6.20141 | 对应 staged DSC / bootstrap 失败轮次的保存字节。 |
| `.build/t33t-20261025/.cfw-history/20261025T114952Z-zhZ5OOCf/effect-blobs` | 6.20141 | 对应后续 plist 生命周期失败轮次的保存字节。 |

两份 `transaction.json` 均为 `status=failed`、`exit_code=1`、`staged_removed=true`，未发布。各自的 `transaction.json`、JSON/JSONL、日志、报告及诊断脚本全部保留，仅删除表中的两个 `effect-blobs` 目录。

最新来源恢复计划保留四份旧失败记录。已核对 `execute_t33_reboot_acceptance.py:verify_preservation`：对旧失败事务核对的是 `transaction.json`；最新计划冻结输入没有上述两个 blob 目录的直接引用。当前已提交证据选择器 `scripts/cfw_disk_txn.py:committed_guest_evidence` 要求 `status=published`。这两轮失败产物不属于已发布撤销链的选择对象。

删除仍有明确影响：二进制 blob 是原始失败现场的一部分，删除后不能完整重放这两轮的保存字节。保留的摘要和日志不能恢复这些字节。后续若再次运行依赖这些失败字节的历史诊断，需要重新构造实验；本次不保证能够生成与原现场相同的字节。执行前应归档并核验两轮的小型记录、保存完整删除清单，保持 transaction 内容及元数据不变。

本组不包含已发布事务 `adMN63qO`、恢复事务、`.cfw-recovery-sources`，也不包含 regular 的已发布历史。

## C：旧 DSC VM 退役清单，24.399 GiB（已执行）

该对象是 2026 年 10 月 18 日为 T32/T33 新建的独立 DSC 验收 VM，目录为 `vm-t32-t33-dsc-20261018`。DSC 指 dyld shared cache。该实例使用 iOS 26.0 23A341 + cloudOS 26.1 23B85、regular/classic 配置，用于验证既有 IOMFB SwapEnd DSC 修改及其撤销、重新应用和启停行为。此前 regular 26.1 实例不执行该项修改，因此另建 26.0 基线。依据：`research/upstream_integration_2026-10-15/T32_T33_new_vm_20261018.md` 的“独立 DSC 实例准备”及后续记录。

`TASKS.md` 的 2026-10-21 结果记录了该 VM 限定范围的初装、启动前撤销、同 generation 重新应用，以及撤销后和重新应用后各两次无界面 API 启动、正常关机。该记录不代表 T32/T33 整体验收完成。当前 regular 和 EXP 续验对象分别为 `.build/t32q-20261024` 与 `.build/t33t-20261025`；旧实例的原始 ROM 仍被最新计划引用。

| 路径 | 分配量 GiB | 结果及影响 |
| --- | ---: | --- |
| `vm-t32-t33-dsc-20261018/Disk.img` | 13.96888 | 删除后旧 VM 无法启动。最新计划仍把该路径列为 `unrelatedDiskIdentities` 中的保留磁盘。 |
| `vm-t32-t33-dsc-20261018/iPhone17,3_26.0_23A341_Restore` | 10.43061 | 旧固件工作目录；删除后不能直接复用该工作目录执行恢复。 |

`research/failed_rounds_cleanup_20261025.md` 的已执行结果明确：旧 DSC 的完整 `.cfw-history` 已在 10 月 25 日获批退役；上述两项因达到当时容量目标而跳过。它们仍为现存实验状态，不能把过去的批准当作本次删除授权。

最新来源恢复计划对旧 DSC 的直接引用有两类：一是本表 Disk 的保留身份；二是下列固件 generation 内的原始 ROM，必须保留：

`vm-t32-t33-dsc-20261018/.firmware-generations/6ebc5f6705cf0bffb32da62bf3006cc7ece5027edee4306abc8031aee9f4bb42/originals/AVPBooter.vresearch1.bin`

因此 C 组只能删除表内两项；保留整个 `.firmware-generations`、`.firmware-history`、ROM、配置和研究记录。原计划及历史保留清单保持原文，不能删除后仍宣称该磁盘保留检查通过；未来验收需要在新检查清单中明确登记该退役例外，不重跑已消费计划。

评估阶段没有核验所有历史计划对旧工作目录的引用，也没有删除后重建 VM 的实际验证。C 组因旧 VM 无法启动及原路径保留检查失效的影响，未并入优先 A+B；随后收到明确授权才单独执行。

## 公共核验与保留范围

- 14 项候选均完成真实路径和完整可读子项枚举，真实路径均保持在仓库内；无 Git 跟踪文件。
- 对目录逐项执行 `lsof -nP +D`，对 Disk 执行 `lsof -nP --`。14 次均退出 1，标准输出及诊断为空，未观察到打开句柄。
- `hdiutil info -plist` 未发现候选的镜像附件。进程清单未发现 VM、CFW、T32/T33 执行器或构建测试进程。
- A、B 最新计划直接引用为零；C 的 Disk 有一处保留身份引用。所有数值与引用检查保存在评估 JSON，未修改任何验收计划。
- A+B 分配量合计 15,219,105,792 字节（14.17390 GiB）；包含 C 时合计 41,417,867,264 字节（38.57339 GiB）。`du` 分配量包含 APFS 可能共享的数据块，不能保证同量回收。上轮 29.737 GiB 分配量清理后卷可用空间即时仅增加 2.416 GiB，本轮也必须执行后复测。
- 不删除其他 VM、当前 regular/EXP 磁盘、已发布历史、恢复来源、原始 IPSW、generation、固件历史、备份、候选 tar、Python 环境、源码或研究证据。没有依据将 `logs/artifact-spool` 全部视为无引用缓存，本轮未把它们列入删除清单。
- 部分 root 私有 generation、恢复来源和备份目录仍未枚举，完整占用尚未核实。这些目录未计为零，也未列入本轮候选。当前 `accepted=false` 状态保持。

评估证据目录：`research/evidence/storage-review-additional-20261030/`，含 `assessment.json`、`package-comparisons.json`、`inventory.json.gz`、`open-handles.json`、`attachments.plist` 和 `processes.json`。评估阶段只统计、比较及检查占用；后续批准后的实际删除及验证见本报告前述两节，未扩大表内范围，未执行产品测试、固件比较或真实 VM 验收。
