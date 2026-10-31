# vphone-cli 清理评估（2026-10-30）

执行结果：用户在当前聊天回复“确认这些清理内容”后，十个对象均已删除，管理员执行退出 0。执行前后卷可用空间从 40.339 GiB 增至 42.755 GiB，即时增加 2.416 GiB。删除范围没有扩大，未停止进程或修改验收计划。

以下保留删除前评估和十项清单。清理对象分配量合计 31,930,339,328 字节（29.737 GiB）。

## 执行验证

- 执行器 `research/storage_cleanup_20261030.py` 先完成不删除数据的预检，再通过 macOS 原生管理员认证执行 `--apply`；两份镜像的父目录由 root 所有，需要管理员权限。
- 预检发现另一个仓库 `vphone-cli-up` 的 VM 导出进程。工作目录核对将其识别为其他项目；没有终止该进程。当前仓库十项对象的打开句柄、镜像附件及最新计划直接引用检查通过。
- 首次管理员预检被 Git 仓库所有者检查拒绝，没有开始删除。后续只为该次 `git ls-files` 增加 `-c safe.directory=/Users/kolar/github/vphone-cli`，未修改全局配置，重新完成预检后执行。
- 保存 22,386 项子项元数据和十项顶层元数据；删除后十项均不存在。91 项保护记录删除前后保持一致：包括诊断记录的摘要、选定 VM 和备份的磁盘元数据、可读启动文件摘要、最新计划摘要及 Python 环境链接。未对保留的完整 VM 磁盘重新计算摘要。
- 独立复核再次确认十项均不存在、前后保护记录相等，并逐份重算三组诊断的 15 份结果及挂载记录摘要，全部与删除前相同。
- 执行器记录卷可用空间从 43,313,344,512 字节增至 45,907,656,704 字节，增加 2,594,312,192 字节。独立复测时可用约 41.962 GiB；这些是不同时间的卷读数，受并发活动影响，不能视为独占块测量。未测量 APFS 独占 extent，未将分配量与即时空闲增量的差异归因于单一因素。
- 本次没有重建产物、运行产品测试或启动 VM。后续使用 `.build/debug` 或 `.build/release` 的编译产物前需重新构建。

证据位于 `research/evidence/storage-cleanup-20261030/`：`plan.json`、`inventory.json.gz`、`open-handles.json`、`attachments.plist`、前后进程记录、`protected-after.json`、`result.json` 和 `independent-verification.json`。执行器已记录完成状态，拒绝重复执行。

## 拟清理内容

路径均位于 `/Users/kolar/github/vphone-cli/`。批准范围限定为本表十项，不包含它们的父目录或相邻文件。

| 路径 | 分配量 GiB | 内容及影响 |
| --- | ---: | --- |
| `.build/out` | 2.311131 | 编译产物和中间文件；后续需重新构建。`.build/debug` 和 `.build/release` 分别指向其中的 `Products/Debug`、`Products/Release`，删除后须重建才能使用。 |
| `.build/test-module-cache` | 0.114002 | 测试模块缓存；后续测试重新生成。 |
| `.build/release-module-cache` | 0.029018 | Release 模块缓存；后续构建重新生成。 |
| `.build/test-cache` | 0.002045 | 测试缓存；后续测试重新生成。 |
| `.build/t32-t33-completion-20261023/cryptex-tree-stability-20261025-root/readonly/cache.dmg` | 4.546875 | 树稳定性诊断的只读镜像副本。 |
| `.build/t32-t33-completion-20261023/cryptex-tree-stability-20261025-root/writable/cache.dmg` | 4.546875 | 同组诊断的可写镜像副本。 |
| `.build/t32-t33-completion-20261023/cryptex-private-attach-20261025/readonly/cache.dmg` | 4.546875 | private attach 对照诊断的只读镜像副本。 |
| `.build/t32-t33-completion-20261023/cryptex-private-attach-20261025/writable/cache.dmg` | 4.546875 | 同组诊断的可写镜像副本。 |
| `.build/t32-t33-completion-20261023/cryptex-mounted-image-sequence-20261025/readonly/cache.dmg` | 4.546875 | 挂载后摘要读取顺序诊断的只读镜像副本。 |
| `.build/t32-t33-completion-20261023/cryptex-mounted-image-sequence-20261025/writable/cache.dmg` | 4.546875 | 同组诊断的可写镜像副本。 |

四个构建及缓存目录合计 2.456196 GiB；六份诊断镜像合计 27.281250 GiB。保留三组诊断中的 `result.json`、`attachment.plist` 和诊断源码快照，以及研究报告、测试脚本和归档证据。删除后不再保有六份副本的当时完整镜像状态；重新复现需重新制作副本。

上述数值来自 `du -sk` 的分配量。六份诊断镜像由 APFS 克隆创建，可能与源镜像或其他副本共享数据块。未测量独占 extent，不能承诺释放 29.737 GiB；实际回收量须执行后复测卷可用空间。

## 核对结果

- 十个对象均存在，真实路径保持在仓库内；`git ls-files -- <path>` 对十项均无跟踪文件。
- 对四个目录逐项执行 `lsof -nP +D <path>`，对六份镜像逐项执行 `lsof -nP -- <path>`，十次均退出 1，标准输出和诊断均为空。本次未观察到打开句柄；这不保证执行时仍无占用。
- `hdiutil info -plist` 返回的五个附件均不位于本仓库，十项候选没有当前镜像附件。
- 只读进程清单未发现 vphone VM、CFW、T32/T33、Swift 构建、xcodebuild、测试入口或 Cryptex 诊断进程。运行状态文件中的历史 PID 不作为当前运行证据。
- 三组诊断的 `result.json` 均记录原始源镜像身份及完整摘要保持、两个副本正常卸载。原始源摘要为 `600c789470b94e733796f0a0158365177c275a918a34e4d0f9ee1f7cd5fcdbf6`。本轮读取既有结果，没有重新计算六份镜像的完整摘要。
- 最新来源身份续行计划 `.build/t32-t33-completion-20261023/exp-source-identity-acceptance-20261026/offline-plan.json` 中，未发现十项候选的直接路径引用。检查包括 JSON 字段名及值。历史诊断记录仍引用这些副本，删除后该处路径不再存在；保留原始记录，不改写历史证据。
- 依据：`research/upstream_integration_2026-10-15/T32_T33_cryptex_tree_stability_20261025.md`、`T32_T33_staged_dsc_20261025.md` 及三组诊断结果。后者明确记录 mounted-image-sequence 与 private-attach 属于隔离诊断。

## 保留对象及限制

| 对象 | 本次可读分配量 GiB | 保留原因 |
| --- | ---: | --- |
| `.build/t32q-20261024` | 170.097 | regular 已通过验收的磁盘、历史镜像及撤销链。整体删除会失去该实验状态；不能单独抽删历史镜像后继续视为完整链。 |
| `.build/t33t-20261025` | 67.206 | EXP 当前续验对象；`.cfw-reboot-identity.json` 明确引用历史 Disk.img、guest-postimage.img 和恢复来源。 |
| `.build/t32q-20261024-binding-backup` | 14.001 | 启动和绑定备份，最新计划列为保留磁盘。 |
| `.build/t32-t33-completion-20261023/pre-acceptance-backup` | 14.002 | EXP 来源备份，最新计划直接引用。 |
| `.build/t32-t33-completion-20261023/t33t-first-binding-20261025` | 14.001 | 既有验收备份，本轮未完成独立退役评估。 |
| `vm-t32-t33-dsc-20261018` | 45.317 | 既有 DSC 验收 VM，最新计划列为保留磁盘。 |

这些对象属于有状态的验收环境。若后续决定整体退役，需要明确接受相应续验、撤销及历史重放能力丢失，并检查其他对象对其原始 ROM、磁盘和来源文件的引用。本轮建议清单不包含这种退役。

保留 `vm-new`、`vm-2607`、`vm-roothide-b33-20261010`、所有其他 VM、原始 IPSW、固件 generation/历史、候选包及 tar、Python 环境、依赖源码、Git 数据和所有源码修改。未访问仓库根 `TODO.md`。

`.build` 本次可读分配量约 322.831 GiB；部分 root 私有 generation、原件、恢复来源及备份目录不可枚举，完整占用尚未核实。不可读内容未记为零，也未纳入拟清理范围。最新执行目录中的 `recovered-undo-result.json` 不可读，未据此更新验收结论。`TASKS.md` 仍记录整体 `accepted=false`。

本轮未运行产品测试、固件比较或真实 VM 验收。它们不能替代清理前的路径、占用和引用检查。本报告不证明清理后重新构建或重建诊断环境已通过。

## 确认后的执行要求

只删除本表十项。执行前重新检查路径、Git 跟踪、打开句柄、镜像附件和相关进程；如出现新增引用或占用，停止对应项。保留诊断元数据及既有验收对象，记录每项执行结果和清理前后卷可用空间。若需扩大范围，先另列具体对象供用户确认。
