# 8a75092 范围核验与本地对账（2026-10-15）

2026-10-20 当前状态：当前项固定为T32/T33独立DSC真实顺序验收。持久runner93069/CLI94446/root97562在staged .cfw_disk.tjhO0rSZ继续，最新进入GPU归档提取入口，尚未最终核验/发布。冻结VM程序字节/inode/CDHash保持，但参数探测被信号9终止；amfid44463日志确认restricted entitlements拒绝。按本任务既有精确CDHash授权发起临时helper恢复，系统原生验证待完成。安装不受此验证等待影响；后续启动依赖其完成。Undo、重新应用及on→off→on仍未验收，整项未accepted。

## 2026-10-16 roothide journal 实际核对

管理员只读检查已完成。指定 VM 的 3 份 journal 均为 v1：1 份已发布 API 安装、2 份失败且保留副本。当前磁盘 inode 匹配发布记录，但 mtime 不同；没有 generation、冻结计划或 guest 发布检查点，不能用于当前正向 DSC 撤销。磁盘无占用或附件，本轮未修改 VM。补充抽样授权请求已取消，未计作通过；见 [核对记录](T32_T33_roothide_journal_inspection.md)。

## 2026-10-16 改用已有 journal 的 VM

用户选择切换验收对象，不重新安装 vm-new。只读核对已知目录中的 7 台 VM，4 份可读已发布日志均为 v1；尚未找到具备 generation、冻结计划及 v3 发布检查点的候选。roothide 的历史因权限未读取，另有未完成事务，未恢复。等待用户提供目标名称或路径；见 [目录核对](evidence/T32-T33-existing-journal-search/inventory.json)。

## 2026-10-16 vm-new 真实验收

用户指定仓库内 `vm-new`。该 VM 缺 generation、desired plan 和 CFW journal；实际 Receipt 返回 unknown，预览及写入拒绝，离线完整磁盘和受保护文件摘要前后一致。完成当前完整签名应用构建；两次真实启动均连接原 vphoned，读回 iOS 26.1/23B85，客户机启动时间不同，两次正常停止并释放磁盘，未更新 daemon。正向撤销和中断恢复仍未验收；重新安装记录化 CFW 的扩大范围等待用户明确选择。见 [验收记录](T32_T33_vm_new_acceptance.md)和[证据清单](evidence/T32-T33-vm-new-acceptance/manifest.json)。

## 2026-10-15 DSC 撤销写入与共同发布

新增 `cfw undo` 和 `cfw receipts`，实际恢复 staged DSC 后缀候选，封存 request/applied/分组件效果 Receipt，并在同一可恢复磁盘 journal 中将 guest 来源置 unknown。157 项相关 Python、11 项 Swift 定向通过；最终 Python 全量 886 项（跳过 2 项）无失败；最终 Swift 完整入口退出 0，XCTest 325 项（跳过 7 项）、常规 Swift Testing 1529 项、限时分组 26 项及后续内存/guest 组件宿主检查通过。补充真实 Swift 验证器的连续两次安装与一次撤销回归，修复 CFW 交换后 generation 原 inode 绑定不能继续读取的问题。归档 rename 前持久化完成证据，新增交换、来源及归档边界恢复回归。真实 VM 对象待用户指定；Mach-O/Preboot、任意中间操作和受信 guest 来源推进仍未完成。见 [实施记录](T32_T33_guest_undo_publication.md)。

## 2026-10-15 已提交 guest DSC 撤销候选

新增 `cfw_disk_txn.py preview-undo`：从当前已提交 v3 journal 重建来源索引，按 declaration 反向核对 DSC 操作链末尾的一组操作，重新计算候选全部 CodeDirectory 代码页摘要。65 项组合回归通过；完整 Python 最终 869 项、跳过 2 项，无失败，退出 0。尚未执行实际 guest 撤销写入或更新安装来源，T32/T33 整项保持未验收。详情见 [专项记录](T32_T33_guest_undo_candidates.md)。

## 2026-10-15 拉取与本地修改合并

已从 `2df4be8c` 快进到远端 `fcd19e78`，恢复并合并本地未提交修改，保留两侧 Undo 来源核验和快照后磁盘检查点。完整安装采用 journal v3，环境更新保留远端 v2。备份 stash 保留，Swift 相关 27 项和 Python 定向 82 项通过；`make test_python` 最终 857 项通过（跳过 2 项），退出 0。详情见 [合并记录](pull_merge_reconciliation.md)。以下各批次结果保留其原验证范围。

## 2026-10-15 恢复批次结果

三个子范围已实施并完成相关验证。标准 Swift 全入口退出 0：XCTest321项跳7，常规SwiftTesting1507项和时限组26项通过，内存和guest组件宿主检查通过。Python恢复基线818项通过；实施后835项仅一条旧取消删除静态断言失败，更新契约后受影响模块23项通过，未重跑完整入口。具体结果、审查与未完成范围见 [恢复批次汇总](evidence/resume-three/README.md)。

剩余 TODO：snapshot变换后readonly语义核验；逆向Undo与旧IOMFB实现迁移；payload/Undo/Receipt共同发布；导入队列及完整退出状态；真实固件/VM验收。本轮不将T30/T32/T33/T60整项提升为accepted。提交与推送状态见 Git 历史。

## 2026-10-15 从 handoff 恢复

用户要求先重跑 Python 全量，再继续三个 TODO。handoff 的 16 个源码摘要全部匹配；原依赖缓存已不存在，改用已核对固定 IcliKit revision 的 `.build/daemon-api-8a75092/Xcode/SourcePackages`。Python 全量 818 项通过，跳过 1 项，425.507 秒，退出 0；见 `evidence/resume-three/python-result.json`。已恢复 Swift 剩余失败、IOMFB 可信 Undo/迁移和导出取消三个并行子任务。下文暂停状态属于上一阶段。

## 2026-10-15 三项继续实施

**暂停状态：** 用户要求准备 handoff 并暂停。最终标准 Swift 自然结束：XCTest 321 项（跳过 7 项）无失败，Swift Testing 1514 项保留 14 issues，本次修改的三个测试通过；后续限时组、内存和 guest 组件检查通过。Python 全量按用户要求主动中断，恢复后需重跑，不能引用上一批 798 项覆盖本批。详见 [第二批汇总](evidence/parallel-three-followup/README.md)。

用户要求继续并行推进三项。本批沿用上一批工作区，不改动原 Capstone overlay。

- Swift 验证：已复现环境测试的协作线程池阻塞，以及 worker 测试观察者的全局队列排队延迟。同步工作改用专用线程，结果回到原测试任务断言；保留等待期限、写互斥、读取放行、子进程完整输出与锁拒绝检查。因果实验、标准入口结果和剩余失败见 [Swift 后续记录](T30_swift_validation_followup.md)。
- T32/T33：已实现四指令 IOMFB 条件分派、状态识别、全部范围预检、跨页重签与最终读回。35 项定向检查及 3 项入口对照通过；旧算法四项反证失败。端口布局证据仅限上游 24A446，生产门控仍拒绝没有可信 Undo/迁移/事务发布资格的写入。见 [条件分派记录](T32_T33_implementation_migration.md)。
- T60：真实 import 接入 SIGINT/TERM 取消控制器，两种提取后端均检查取消，tar 子进程登记并回收，发布前检查取消并清理本次 staging。常规 1 GiB 归档的 system-tar/native × SIGINT/SIGTERM 四项真实 CLI 验收通过：退出 130/143，无残留 staging、无目标发布、无存活 tar，原归档摘要及已有目录标记保持。见 [导入取消记录](T60_import_cancellation.md)。

完整任务状态仍以具体接口和运行验收证据为准。可信 Undo 事务迁移、导出取消、队列及完整退出矩阵仍待处理；本批不提升整项 accepted。

## 2026-10-15 三项并行实施

基线为 `2df4be8ceab956d498f2cc7d79b26f4ddbdee467`。用户要求同时推进三个 TODO，本批分别处理内核幂等测试、同 ID 实现资格和进度输出断开；三个实施代理各自验证后交叉只读审查。原 Capstone 生成 overlay 保留。

- 内核幂等：原失败实际发生在第二次调用之后。已有生产代码生成同位置、前后字节相等的已应用观察，未再次改变数据；旧测试仍要求记录数不变。更新测试以区分实际修改和验证观察，另验证正式结构化执行的声明归属及输入/输出摘要。相关 21 项通过，临时移除观察的反证使两个增强测试失败。生产补丁未修改。见 [T30 记录](T30_kernel_idempotence.md)。
- T32/T33：本地 IOMFB 仍是旧无条件分派，缺少新条件分派及可信 Undo 生产链。本批在当前目标的 iOS 27 安装准入和显式 writer 入口拒绝旧实现，拒绝发生在创建证据或写入前。审查发现 guestUncovered 不自动按版本过滤，已修正为依据冻结的 iosBaseIs27 判断，iOS 26/18 的其他实际写入回归通过。最终 50 项门控测试通过。完整迁移尚未实现，不能将 T32/T33 标为 accepted。见 [迁移记录](T32_T33_implementation_migration.md)。
- T60/T46：进度写入改用 throwing API，并在每次写入前重验 TTY。真实 PTY、断管、tar 提取、正常输出及信号回归共 7 项通过；未改变信号处理器或描述符标志。队列、传输中断清理及完整退出矩阵仍未验收。见 [进度输出记录](T60_progress_pipe.md)。

集成验证与命令退出码见 [本批证据](evidence/parallel-three/README.md)。本批未操作真实 VM、系统 Store、AMFI/TCC 或已安装冻结工件。下文“最新进展”保留本批之前的阶段记录。

本批最终验证：Python 798 项通过（跳过 3 项）；Swift 限时组 9 项、tar/文件摘要内存检查及 guest 组件检查通过。标准 Swift 两次均未通过，分别为 8 / 46 issues；首次失败定向复核 3 项通过。原幂等失败均未再出现，其余失败原因未查明。未将任务整体标记为 accepted。

**最新进展：** T32/T33 已推进已提交 Receipt/report 核对、首次原件保留、撤销/重打副本预检和 `fw receipts` 入口，详见 [T32/T33 记录](T32_T33_receipt_undo.md)。guest 磁盘事务发布和真实 VM 验收仍未完成。前一批 T37 退出入口见 [T37 记录](T37_exit_routing.md)，T59 设备状态轮询见 [T59 记录](T59_event_polling.md)，依赖/声明层适配见 [T08/T09 记录](T08_T09_adaptation.md)。第 1–5 节保留首次 Git 核验阶段的范围和结果。

已取得官方固定目标的完整可达对象，完成新增范围与附件集合核验，并建立 61 项任务的本地路径/历史证据对账。没有切换分支、merge、cherry-pick、修改生产代码、构建或操作 VM。原有未提交修改保持。

## 1. Git 核验

| 对象 | 结果 |
| --- | --- |
| 固定起点 | `2d21d21fbdd4f51f013616273ceda9b35a3e0789`，不包含 |
| 固定终点 | `8a75092013eda87a4e30ed029b72028cb9279ac4`，包含 |
| 获取 | 官方 HTTPS URL，`--no-tags --no-write-fetch-head`，写入 `refs/codex/audit/upstream-8a75092`，未修改远程配置 |
| 本地 HEAD / 分支 | `0d22721f3b70771922e5df389c6bd5c974e77b7d` / `codex/upstream-2d21d21-integration` |
| 对象完整性 | 目标可达对象条目 17,500，`rev-list --objects --missing=print` 未发现缺失对象；非 shallow，起点为终点祖先 |
| 新增范围 | 194 提交：51 merge、143 非 merge；first-parent 为 65 |
| 附件集合 | `exact_set_match=true`，未解析、遗漏、越界均为空 |
| 端点路径 | 376：新增 180、修改 195、删除 1，50% rename 口径下无重命名 |
| 文本增删 | +53,097 / −6,018；正文审计排除根目录 `TODO.md`，该文件不在本次端点变化中 |
| 本地分叉 | merge-base `87f796c62a7cb385cd37afce121f6e222d83e5b5`；HEAD/目标独有提交 428/760。该数量不能用于判断功能是否缺失或已等价 |

审计程序先检查祖先和完整历史，导出完整提交元数据、端点文件表、numstat、binary/full-index patch，以及 51 个 merge 相对各父提交的 patch/remerge diff。原脚本会输出根目录 TODO 正文；根据项目规则，使用[限制作业副本](tools/audit_upstream_scoped.py)仅在正文/统计输出增加排除路径，提交图和路径元数据仍完整。未运行仓库中的构建或运行脚本。

为让 remerge 临时对象写入位于 `/tmp`，创建了本地 bare/shared 审计仓库，不检出文件。完整输出已复制到[审计证据目录](evidence/git-audit/audit.json)，不依赖临时仓库即可阅读。关键入口：[范围摘要](evidence/range-summary.json)、[集合核验](evidence/git-audit/observed_ledger_reconciliation.json)、[端点 patch](evidence/git-audit/endpoint.diff)、[完整提交表](evidence/git-audit/git_commits.json)。

初次网络获取受 sandbox 内本地代理连接限制失败；经正常执行审批后，相同固定对象获取成功。未更改代理配置。附件中的自测结果没有用作本次真实 Git 核验结果。

## 2. 合并提交审查

51 个 merge 均已导出父差异。5 个 remerge diff 非空，已阅读其解决内容：

| 提交 | 观察到的合并结果 | 本地落点 |
| --- | --- | --- |
| `fa3c2520` | spawn 路径组合多库注入和 jetsam 提升/恢复 | T18/T21/T43/T53/T55；当前本地只有 SystemHook 注入基础 |
| `7f4760d1` | 文档同时保留设备名与 CoreDevice persona 两节 | T28/T53/T55；不将文档合并视为功能已接入 |
| `e0415d1c` | 非 DFU 初始化同时设置宿主定位同步与 guest 设备名 | T20/T55；保留本地定位所有权，再接入设备名 |
| `a7fd759d` | 文档同时保留磁盘工具迁移与 Flutter AOT 两节 | T28/T52/T53 |
| `65ddcc9a` | 创建指南保留外置卷工作目录说明与 rebase 章节 | T28/T51/T52 |

[51 项合并记录](evidence/merge-review.json)保留全部父差异路径和 remerge 退出状态。上述阅读只覆盖非空解决内容；父提交的完整功能和本地适配仍需逐项审查。46 项空 remerge 输出不作为“无需移植”的结论。

## 3. 本地实现对账

[61 项能力表](local_reconciliation.json)记录当前工作区路径、文件摘要、历史接受状态与关联新增提交。32 项有本轮已定位的具体增量；其余 29 项完成当前路径检查，新增语义仍待审查。所有历史 `status`、实现提交和证据保留，只有新目标 `target_review` 更新。

| 问题 | 已有实现或证据 | 本轮定位的增量 |
| --- | --- | --- |
| 依赖与 daemon | B38 已验收 classic 1337/相机与独立 API 1339 并行组合，当前依赖 0.7.16 | 目标 0.8.5；不能只升级 pin 或用旧运行结果证明新组合 |
| 声明与默认值 | 本地 catalog/migration/generator 固定旧目标及 141 声明 | ProMotion ID 更名、standard 默认开启，以及新声明/版本适用性须重新对账；T45 继续延后 |
| 更新与可信状态 | WIP 已有 generation、desired、分组件 Receipt/实际效果、Undo 当前字节校验，以及公开 kernel 更新/回退路径 | 同 ID 旧实现识别、DeviceHub/Flutter DSC 证明及新目标资格仍需适配；不能覆盖已冻结 V9 工件 |
| 磁盘与停止 | 每 VM flock、online-operation lease、CFW staging；Stopper 校验真实 boot 身份，持有者不发信号 | 新入口接线、work-parent、磁盘工具与 SIGTERM/窗口退出完整矩阵尚未覆盖 |
| 克隆 | 完整持久状态复制、保留身份、APFS 优先及复制回退、排他发布 | 未注册 `--new-identity`，需要网络清理与密钥继承说明 |
| 快照/模板/rebase | create 资源快照、IPSW 缓存、kernel rollback 已有 | vm 命令列表没有 snapshot/template/rebase；这三项现有基础不能替代新增能力 |
| 精简/运动/设备名/时钟 | first-boot、输入/旋转、VM 名称和时区已有基础 | 新维护 API、运动端点、`device.name`、`time.clock` 及对应产品链未接入 |
| Hook 与开发工具 | 本地 SystemHook、RootHide 物理根/标记/注销与禁用变量保护 | 多库注入、DeviceHub、persona、Flutter 修复链需要成组适配，不能丢弃本地策略 |
| 下载 | 流式、Range/If-Range、ETag/Last-Modified、排他发布已实现 | 缺多连接分段调度；复用现有缓存保护 |
| 空闲性能 | binaryHash 已缓存，camera timer 已有启停 | GuestEventPublisher 仍每 3 秒轮询，未按订阅切换；缓存失效和恢复使用需验证 |
| 导入导出与日志 | staging、路径/归档保护、console reader/writer 退出握手已有 | ProgressBar 尚未采用目标可忽略写失败的路径；队列、断管/取消分离和退出最终状态需接入 |

[端点文件候选表](evidence/endpoint-local-comparison.json)覆盖全部 376 路径：87 路径存在本地同名或明确更名候选但字节不同，288 路径没有文件名候选，1 路径为上游删除。没有字节相同候选。由于本地布局与实现不同，文件名缺失不证明功能缺失，字节不同也不证明不等价；最终处置依据能力语义和实际证据。

194 条新提交均已绑定完整 SHA、父关系、合并类型和父差异路径，见[提交处置表](commit_ledger.json)。`semantic_status` 仍为 pending_semantic_review；本次不按标题自动判等价、跳过或已合入。

## 4. 未提交修改保留

保存目录：`/tmp/vphone-8a75092-preserve-20261015`。保存未暂存/暂存 binary patch，以及 2,353 个原未提交文件的清单；可读且不超过 8 MiB 的文件已复制。两份权限受限历史证据在读取时被拒绝，另两份大文件仅采集大小和纳秒修改时间，均保持原位。没有改变权限、所有权或这些证据的内容。

仓库内保存[操作前清单](evidence/wip-before.json)与[最终保护核对](evidence/wip-preservation-check.json)。本轮计划台账等指定文件的修改单独列明；生产源码、测试、原历史文档和证据须保持摘要或元数据一致，Git HEAD 和暂存 patch 须一致。临时保存不作为完整 VM 恢复点，不替代后续 T03。

## 5. 后续执行

U0 的对象、范围和集合核验已完成；T02 的逐提交语义覆盖仍在进行。接下来先核对 T08 的新依赖调用合同与 T09/T10 的新声明/更名/默认值，再补 T15/T24/T37/T40/T52 的共同边界。可独立审查 GuestEventPublisher 按订阅启停和 ProgressBar 断管处理，但纳入生产前仍需覆盖本地 API hub 与日志/取消合同。

已有 kernel 更新/回退、generation、Receipt 和 I/O 工作保留并复用。模板与精简依赖上述共同前提；T51、T58 和默认值决定维持独立。未执行构建、固件测试或 VM 验收，本轮结果仅覆盖 Git 核验、源码/路径对账与修改保留检查。


## 2026-10-15 后续：T08/T09 适配

本轮已完成 IcliKit 0.8.5 调用合同、148 项声明的更名/适用性/默认值对账及必要适配；保留本地 ProMotion 默认关闭。新 daemon 候选已构建并校验，最终相关 Swift 131 项通过；标准套件的失败与适配前对照单独保留。源码、验证和未完成真实验收见 [T08/T09 记录](T08_T09_adaptation.md)。本节追加后续结果，不改写前文首轮对账状态。

## 2026-10-15 分支恢复与 T59 设备状态轮询

用户要求切回 `codex/upstream-2d21d21-integration` 继续。当前仓库原分支为 `codex/handoff-20261001`，工作区干净。目标分支本地 `dd863325` 与已有远端引用 `76318ed1` 分别独有 3/44 个提交。本轮保留两侧提交执行合并，没有刷新远端或改变固定上游目标；当前执行范围继续采用本目录的 `8a75092` 计划。

目标分支另在 `/Users/kolar/.codex/worktrees/t08-roothide/vphone-cli` 检出且工作区干净。本轮使用 `git switch --ignore-other-worktrees` 在当前仓库继续，未修改另一工作树的文件。后续不在两个工作树同时提交同一分支。

- [x] 保留补丁比较文档两侧追加记录，以及本地布局与远端重新校验的全部测试，解决两处合并冲突。
- [x] 完成 Bundle Store、绑定路由与启动诊断的合并验证（普通宿主权限下 59 项通过），保存合并提交 `a9d07d70`。
- [x] 修复并验证已有停止拒绝测试的夹具前置条件，保留拒绝停止后子进程仍运行的断言；相关 13 项及标准入口中的该用例通过。
- [x] 适配 T59 首/末订阅通知和定时器启停，补快速重连、回调乱序、初始化与释放回归；旧实现和快速重连对照均被捕获，修改后通过。
- [x] 在 `.build/daemon-api-t59-20261015` 完成 iOS Release 构建及两类签名候选校验，未部署。
- [x] 修正测试运行器准备步骤的环境隔离与六步回归，保留首轮失败；完整验证结果见 [T59 记录](T59_event_polling.md)和[证据清单](evidence/T59-event-polling/manifest.json)。
- [ ] T59 客户机空闲性能、首响应、实例切换与其余组件；T32/T33 实现代际和 U2 共同操作边界继续按计划处理。没有把本轮部分实现登记为整项 accepted。

首次 Swift 执行因默认模块缓存无写权限失败；改用仓库内模块缓存后完成编译。沙箱定向测试的 `setuid` 归档用例实际报签名拒绝，未命中预期权限拒绝；普通宿主权限下 59 项全部通过，环境差异原因未查明。停止拒绝用例已复现 `launchedProcess == nil`，错误原文为 `Cannot inspect VM directory for committed origins`；夹具未创建 `sample` 目录，原失败尚未进入停止操作。

标准 Swift 常规 1510 项剩 1 个此前已记录的内核幂等 issue，未改动补丁或断言；入口后续步骤分别补跑，限时组 9 项、tar 管道/文件摘要内存检查及 guest 组件通过。测试准备脚本生成的 Capstone 9 行 overlay 与 manifest 的 `patched_sha256` 一致，submodule 提交未改变，保留该生成状态。本轮未操作 VM、系统 Store、AMFI 或 TCC，未推送。

最终 Python 全量重跑 785 项全部通过、无跳过（199.101 秒），显式使用本轮锁定的 IcliKit checkout；保留首轮 1 失败/2 跳过和运行器环境检查的失败日志。标准 Swift 的既有内核幂等 issue 仍待处理；不据单个局部通过升级整组状态。

## 2026-10-15 后续：T37 退出入口

基线 `94d6ca0e`，原有 Capstone overlay 保留。用户要求继续下一项，本轮处理 U2 中 SIGTERM 与主 VM 窗口关闭的关机接线：复用现有 guest 写入等待和停止策略，不操作真实 VM。

- [x] 核对 AppDelegate、窗口、guest 写协调器和现有关机测试。当前仅注册 SIGINT；主窗口关闭依赖“最后一个窗口关闭”，辅助窗口存在时不能保证触发退出。
- [x] 用独立子进程保存 SIGTERM 未进入回调的失败；用实际窗口 delegate 和受控写入保存主窗口关闭未等待的失败。编译失败与行为失败分开保留。
- [x] 将两个入口接入现有关机流程，验证重复信号、原处理器恢复、辅助窗口存在、写入排队和停止回退。最终窗口测试运行真实 AppDelegate 等待路径，只替换排空后的框架操作。
- [x] 相关 Swift 44 项通过；最终窗口 3 项在标准构建中通过；Python 786 项全部通过、无跳过（198.527 秒）；限时组另补跑 9 项通过。
- [x] 更新 [T37 记录](T37_exit_routing.md)、[证据清单](evidence/T37-exit-routing/manifest.json)及任务台账；T37 历史状态与接受计数保持，未推送。
- [ ] 启动中停止、panic/未就绪/超时/权限的完整矩阵及真实 VM 停止/磁盘释放，继续按 T24/T37/T40 的原计划验收。T32/T33 的同 ID 实现代际与可信 Undo 仍待推进。

最终标准 Swift 常规 1510 项，仅保留 `postValidationRecognizesIdempotenceWithoutEmitting` 的已记录 issue（2 条记录与断言 1 条不符）；未改动该补丁或断言，`run_tests.py`/make 分别退出 1/2。此次没有重新运行标准入口其后的内存和 guest 组件检查，也没有构建/部署完整签名 App 或操作真实 VM、AMFI、TCC、系统 Store。原有已校验 Capstone overlay 保留。


## 2026-10-15 后续：T32/T33 Receipt 与撤销预检

起点 `2df4be8c`；保留 Capstone overlay。本轮先处理已有持久化证据与撤销资格，未修改 firmware/kernel/DSC 指令，未操作实际 VM。

- [x] 保存原 Undo 对保留补丁失效字节、无首次原件 no-op 的失败回归。
- [x] 用 HEAD 原 Receipt 源码复核缺失/损坏 report 仍通过、desired 改变后旧证据不可读的失败；恢复候选源码。
- [x] 通过归档 producer report、journal 原计划、generation 和当前输出核对已提交记录；Receipt 中的 originalBytes 必须与 producer 一致。
- [x] 重复应用保留首次原件，保存撤销后剩余日志；同 ID 记录形状判定与重打预检只作用于副本。
- [x] 新增 `fw receipts` 查看实际持久证据及生成固件撤销预览；缺旧证据保持 unknown，不更新安装来源。
- [ ] guest DSC/Mach-O/Preboot 撤销、代码页重新证明，以及 Disk.img、Receipt/Undo/来源的同 journal 发布和真实 on→off→on 验收。

具体回归结果及限制见 [专项记录](T32_T33_receipt_undo.md)与[证据清单](evidence/T32-T33-undo/manifest.json)。T32/T33 历史状态和接受计数保持，不能将本轮预检视为实际 guest 更新完成。T08 客户机验收、T09/T10 的指令实现及适用性仍保持未完成；此前优先推进 T32/T33 不表示前三项已经验收。


## 2026-10-18：T32/T33 新 VM 验收准备

用户授权新建独立 VM。首个 26.1/23B85 实例的准备成功，固件提交前因 bootx 声明与执行步骤的版本条件矛盾而拒绝。已保留失败证据并通过正式恢复入口归档；修复将两者统一为 cloudOS 26.4 及以后必需，保留现代输入缺少匹配和匹配不唯一时的拒绝。当前 T09 规则清单记录有实际失败证据支持的修订，原清单完整保留，固定上游源码保持。

定向测试、兼容性 Python 14 项、catalog Python 9 项及生成器检查通过。最终常规 Swift Testing 1534 项通过；完整 Swift 入口仍有未修改的 APIProxy XCTest 失败，单独 1 项通过，原因未查明，后续检查未运行。完整签名构建及 bundle 资源/entitlement 校验通过。

第二个实例 `vm-t32-t33-20261018-r2` 已完成原始固件准备；7 个组件、58 条字节记录通过声明校验，组件 Receipt 与事务已提交，patch 检查点 succeeded；随后真实系统恢复 succeeded。用户已明确授权既有 amfidont 按当前 VM CDHash 放行并继续恢复、CFW 和撤销验收；冻结程序 `--help` 退出 0，真实 DFU 恢复已验证放行。首次 CFW 在 readonly Cryptex 的 volume 字段检查失败，原磁盘元数据与 66 段采样摘要保持，v3 失败事务已归档。实际 `WritableVolume:false` 字段兼容性已修复，相关 87 项、完整 Python 892 项（跳过 2 项）及完整签名构建通过。CFW 重试当前等待新的 macOS 管理员验证，Mac 被报告锁屏。两台既有 VM 的指定文件元数据及已有摘要保持。

T32/T33 接受计数保持；真实系统恢复已完成；CFW v3、DSC 撤销及新 VM 正常启动尚未完成。详细证据和后续结果见 [新 VM 记录](T32_T33_new_vm_20261018.md)。


DSC 验收组合已更正：regular 26.1 没有默认 DSC 字节操作，r2 仅用于发布/启动验证。独立 `vm-t32-t33-dsc-20261018` 使用已核验的 26.0 23A341 原始归档与 cloudOS 26.1 23B85，已完成 native prepare 和正式 generation 发布，固件事务正在运行。只读原始 DSC 诊断定位 SwapEnd `0x548` → `0x560`，对应 6885 个代码页通过校验；不构成安装或撤销验收。旧 VM 指定文件保持检查通过。

独立 DSC 实例后续已完成固件事务提交（`c1c3bbd5-e615-4ba5-8700-0fc885925167`，7 组、58 条记录）及真实恢复。SHSH、restore、DFU 子进程均退出 0，磁盘与目录锁释放；CFW、DSC 撤销和正常启动仍待验收。r2 CFW 重试等待用户解锁并完成已有原生管理员验证，接受计数保持。

第三次 CFW 前修复实际 readonly Cryptex 的硬链接读取：原文件稳定但 nlink=38 被误拒绝，正式 producer 回归先失败后通过；最终相关 147 项、完整 Python 900 项（跳过 2 项）及真实原始源树读取通过。完整签名与冻结资源核对完成；按已批准的同 CDHash 重启既有 amfidont，未加载持久允许列表。第三次管理员验证已生效，实际 staged 安装正在执行；发布与正常启动仍待核验。


## 2026-10-19：最终 APFS 挂载核验

第三次 CFW 已于 2026-10-18T14:47:55Z 退出 1，失败位置是首次 `verify-final`，错误为 `final root is not the exact staged volume mount`。归档 `20261018T142710Z-rDDZL4Bx` 保留 551 条 guest 操作；尚未执行快照切换或磁盘交换。原磁盘 dev/inode/size/mtime 与 66 段采样摘要相同；这不是完整磁盘摘要证明。

独立 APFS 克隆复现同一错误。实际 `diskutil apfs list -plist` 对已挂载卷仍缺少 `MountPoint`；`diskutil info -plist` 对设备和路径返回准确设备标识、挂载路径及 `WritableVolume`。未挂载卷返回空 `MountPoint`，可以不含 `Mounted`。旧最终检查使用 APFS 清单的可选字段，因此误拒绝。

修复保留镜像→物理存储→唯一 APFS 卷绑定，改用卷和实际路径查询核对设备、准确挂载点及读写状态。缺失、矛盾、路径或设备不符仍拒绝；覆盖挂载在卸载前拒绝。Undo 可写入口使用同一核验。隔离原生克隆的可写→只读重新挂载已通过，原镜像身份保持，克隆已正常卸载。逻辑 `hardware` 继续沿用安装器既有 s3 目标，未改变分区映射。

相关 58 项通过；完整签名构建通过。完整 Python 回归正在运行。当前 VM 程序仍为获批 CDHash；宿主放行进程已退出，按既有授权恢复进程，正在等待原生管理员验证。第四次 CFW 尚未启动；真实发布、启动边界和独立 DSC 撤销仍未验收。证据：`evidence/T32-T33-new-vm-20261018/mount-inventory-20261019/manifest.json`。


本轮最终验证：`VPHONE_DAEMON_API_BUILD_DIR="$PWD/.build/daemon-api-t59-20261015" make test_python` 执行 906 项、跳过 2 项，无失败，227.751 秒，退出 0。首轮同为 906 项，其中原有测试替身未覆盖新增路径查询，导致 1 项失败；已补齐设备/路径两种查询，并增加实际路径查询断言，原拒绝断言保持。定向 23 项通过。完整签名构建通过，打包的 final_guest、guest_undo、volume_state 与当前源文件摘要一致。旧 VM 指定元数据与小文件摘要复查保持。管理员验证仍未返回（原生 osascript 等待中）；第四次 CFW 尚未启动，真实发布、启动及 DSC 撤销保持待验证。


## 2026-10-19：签名前复制属性核验

第四次正式 attempt `009d74f2-b1c0-4639-b08d-8eb7a14b96bb` 已完成 551 条 guest 写入，通过了此前失败的最终挂载核验；首次效果核验拒绝 `required metadata effect was overwritten`。归档为 `20261018T234718Z-5V5rPsLR`，尚未切换快照或交换磁盘。原 Disk.img 的 dev/inode/size/mtime 与 66 段采样摘要保持；这不是完整磁盘摘要证明。

保存记录中的 seputil、launchd_cache_loader、mobileactivationd 均存在同一签名复制关系：临时副本创建时 GID 为 20，最终 guest 文件保留 GID 0。普通复制核验仅关联内容，允许后续复制保留目的文件属性；签名前核验额外将早期复制创建时的属性当作必须保留的修改，因此误拒绝。真实保存字节、完整签名链和 journal 中最终属性观察的重放在修改前复现相同错误。该重放代替的是已由失败清理移除的 staged 文件属性观察，不构成新的物理挂载验收。

修复仅在签名前属性效果检查中跳过 copy 操作，与主核验循环一致；显式 chmod/chown 属性修改仍必须保留。新增真实 Mach-O 的复制→补丁→签名→复制回归先失败后通过，显式 chmod 被覆盖及最终未记录属性变化仍拒绝。三个真实程序的保存字节重放通过；全部 25 份非纯复制的保存操作链也通过，最终属性观察来自最后记录。完整签名构建通过；完整 Python 正在运行。

第五次 CFW 尚未启动。实际最终效果、快照后第二次核验、共同发布、启动及独立 DSC 撤销仍待验证。证据见 `evidence/T32-T33-new-vm-20261018/signing-copy-metadata-20261019/manifest.json`。


最终标准入口 `VPHONE_DAEMON_API_BUILD_DIR="$PWD/.build/daemon-api-t59-20261015" make test_python` 通过：908 项、跳过 2 项，无失败，233.414 秒，退出 0。完整签名构建通过，四个相关打包脚本与源码摘要一致，VM CDHash 保持获批值。旧 VM 指定元数据与小文件摘要复查一致。已退出的放行辅助进程按既有授权重新启动，当前等待 macOS 原生管理员验证；第五次 CFW 尚未启动。后续先完成实际最终核验和发布，再运行保存的启动后 journal 验收脚本，独立 DSC 实例仍未安装 CFW 或撤销。


用户完成放行进程的管理员验证后，launcher 退出 0，辅助进程 PID 37311，立即执行当前 VM 程序退出 0。第五次正式创建续跑已启动（PID 37596、session 9529、attempt `e8bb6bfd-c484-4121-a636-004d435f755b`）。新冻结副本 `e068c46b-472f-40f6-aea1-21c0c4a97b39` 的四个相关脚本摘要与源码相同，VM CDHash 与获批值相同，冻结 VM `--help` 退出 0。

当前独立 CFW 安装命令仍在等待 macOS 原生管理员验证（wrapper PID 38304）；未发现 root 安装进程或新的 `.cfw_disk.*` 目录，尚未建立磁盘事务。用户已被提示完成当前安装对话框；既有动作授权保持有效。


用户已完成第五次安装命令的原生管理员验证。root 安装进程 PID64816 已建立 `.cfw_disk.H0YWJ2mL` 并进入正式 guest 安装；创建续跑 session9529 继续运行。最终核验、磁盘发布、首次启动及独立 DSC 撤销尚未完成。


等待第五次安装期间，独立 APFS 克隆使用正式 `apfs_snap_rename.py` 完成两条快照名称记录修改；工具与第五次冻结副本摘要一致。之后 System 与安装器既有 s3 目标的准确设备/路径/只读核验通过，正常卸载。源镜像身份元数据保持，未做完整磁盘摘要；仅替换 .build 的 private-path 资格边界，全部挂载查询真实执行。此项不证明 CFW 效果发布或 guest 启动。


2026-10-19 后续结果：r2 第五次 CFW 已发布，事务 `20261019T013451Z-H0YWJ2mL`；正式 create 退出 0，首次及验证提示符启动通过。额外当前 classic API 的两次正常关机回归通过：启动时间和会话 UUID 不同，均收到 Guest stopped，磁盘/目录锁释放，配置与 daemon 摘要保持。运行后 v3 receipts/verify-plan 拒绝；整盘 SHA/mtime 变化，而封存检查点、5 文件、297 blob、配置及 generation 核对通过。正在实现新 v4 的独立发布后镜像和运行身份连续性，不改写历史 v3 journal，不授予当前效果或来源权限。独立 DSC 安装/撤销仍待验证，T32/T33 未 accepted。证据：`evidence/T32-T33-new-vm-20261018/runtime-boundary-20261019/manifest.json`。


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


## 2026-10-19：运行后保留文件漂移

2026-10-19 当前状态：aeb1651e 已 push。真实 Undo 重试的实际写回、完整代码页和可写挂载复核通过；首次最终核验发现保留文件不符，事务20261019T081934Z-JTYX6fft未发布，原盘身份/mtime与66样本保持。只读检查4686个输出，无读取错误，hardware:/AA.gl内容摘要从e221f140…变为4779643e…；其余内容/类型/链接/权限位一致。自动用户挂载未保留属主视图，UID/GID不作结论；正常卸载、镜像身份保持。未放宽生产校验。相关31项回归通过；同一独立VM完整CFW重装等待原生验证，之后先撤销未启动发布，再执行启停及同generation重新应用。运行后保留AA.gl变化的撤销仍拒绝，T32/T33未accepted。

撤销写回记录为`.42`从`2fc23949b0ee8f17d01af28d83e814ee96aabc4918f46537f890843233a113ac`恢复到原件`e41db9aa09ab60cb6015282c9230fba89a8971129fae00c16156b29b1855c9b5`。实际apply-undo退出0并进入第一次verify-final，确认原失败处的写入后可写挂载复核通过。随后保留输出核验拒绝；失败staged按安装器流程清理，journal、请求、写入记录和blob保留。

只读挂载对4686个发布输出进行比较：`hardware:/AA.gl`内容摘要由`e221f140369bf7b0b540793d068f72c7d7d086357aa70c9bd0ace7e7da1c6dd0`变为`4779643ee5398bcbea5eb5056e3966bccd31aa21fbb33ee2e5e5ad0ae1b31d9a`；其他输出内容、类型、链接与权限位一致，无读取错误。自动挂载的UID/GID视图未保留真实guest属主，不能据此判断属主变化。镜像身份保持，正常卸载。该文件变化的具体时间与原因未直接观测；最终拒绝符合保留效果严格核验，未修改生产校验。

新增copy-only hardware字节或权限变化拒绝回归，相关31项2.563秒退出0。下一次完整CFW重装后先验证未启动发布，再立即Undo；此边界与此前实际运行后Undo拒绝分开记录。继续保留真实Undo发布、恢复后启停和重新应用未完成状态。证据：`evidence/T32-T33-new-vm-20261018/retained-drift-20261019/manifest.json`。


## 2026-10-19：显式Cryptex重新安装

2026-10-19 当前状态：f1739ebc已push。重装事务20261019T090232Z-27r0QIUW已发布且未启动；新验收发现已有Cryptex被跳过、SwapEnd幂等，缺新原件复制链，撤销候选正确拒绝，未执行Undo。已新增显式regular/classic --reinstall-cryptex，保持默认跳过与全部证据门。真实安装脚本隔离回归从失败转为通过；相关Python33项、全量942项（跳过2项）254.634秒、Swift参数/传递12函数及实际release verifier3函数（5写入设置、8身份变化）通过。新host应用签名、依赖、资源和entitlement通过，原boot程序字节/inode/CDHash保持。显式原件重装已发起（CLI20039/session28495），新发布核验、未启动Undo、撤销后启停及显式重新应用仍待验收，T32/T33未accepted。

重装事务整盘发布SHA为`fcae888a5b9759efab692c4adbad80226dc33c779e876aaed28733059ea0d676`，生产v4核验确认当前与发布摘要相同。安装日志记录Cryptex已存在而跳过复制，SwapEnd已0x560且重新证明代码页未改变；新Undo索引entries为空。验收脚本在撤销候选处拒绝，顺序脚本停止，未启动或执行Undo。不得把旧journal或当前已安装字节补造为此新事务的原件。

新增`cfw install --reinstall-cryptex`，仅regular/classic，解析与冻结variant核对均限制范围。host驱动在sudo重执行中保留该参数，并显式向安装器传递0/1，环境变量本身不能启用。安装器在该选项下从绑定原始固件重新执行现有缓存、只读来源捕获、Cryptex复制和语义补丁流程；所有修改先在staged磁盘执行。默认已有Cryptex跳过规则保持，dev/jb/exp、v2、Undo/environment组合拒绝。

实际regular脚本在隔离树上的最小回归0.628秒确认原跳过现象；新增选项后3项0.651秒通过。实际host驱动及既有撤销/隔离回归33项53.325秒通过；首次沙箱EPERM记录保留，原断言在宿主重跑通过。完整Python942项（跳过2项）254.634秒退出0。Swift参数/传递12函数和最终签名CLI的3个verifier函数（5写入设置、8身份变化）通过。新host应用完整封签与7个原生依赖检查通过，原VM启动程序字节/inode与获批CDHash保持。

下一次基线和最终重新应用均明确使用新选项，避免再次只得到幂等记录。先保存新事务installed证明，再执行未启动Undo；随后验证原件/6885代码页、两次API启停与运行后读取。此前运行后AA.gl漂移拒绝仍是独立结果，不据此放宽保留效果检查。证据：`evidence/T32-T33-new-vm-20261018/cryptex-reinstall-20261019/manifest.json`。


## 2026-10-19：已有Cryptex替换与新Undo组合回归

2026-10-19 当前状态：6de04f15已push。显式Cryptex重装已获系统验证，root25634/session28495在staged .cfw_disk.vZh3Hh4C执行SystemOS缓存入口，未发布；已确认不走已有Cryptex跳过分支。新增已有补丁Cryptex整树替换→新发布→原件Undo组合回归通过，相关28项10.297秒退出0；生产代码未再修改，先前全量942项（跳过2项）结果保持，其后新增1项组合测试，未声称新全量943项已跑。顺序脚本session39110负责新发布证明及未启动Undo，session22627负责撤销后证明/API启停/读取、显式重新应用及重复验证，失败即停止。实际撤销发布和on→off→on尚待验收，T32/T33未accepted。

隔离测试使用已有producer、来源核验、整树删除/重建/复制、补丁、最终读取、journal封存和交换。先保留已有两次补丁的目标，重新挂载generation原始来源并替换已有树；新发布生成合格首个原件撤销候选，实际Undo写回原件后再次最终核验及发布通过。APFS调用使用已有隔离挂载替身，原件、效果、索引、代码页和journal代码照常运行；此结果不能替代当前真实VM验收。新增组合单项3.331秒；相关28项10.297秒退出0。

真实安装已通过原生验证，root25634运行并建立staged，当前进入SystemOS缓存入口。源发布前不启动VM。新增顺序验收脚本等待Undo成功后才读回原件及6885页、执行两次API启停和运行后读取；之后显式重新应用，再执行来源/DSC、两次启停和读取。同generation、三份不同journal、原件和补丁摘要一致才输出on/off/on通过；不修改Git、AMFI或VM启动程序，任何失败停止后续。证据：`evidence/T32-T33-new-vm-20261018/cryptex-composition-20261019/manifest.json`。


## 2026-10-20：已有目录符号链接与显式Cryptex重装

2026-10-20 当前状态：21ae78d3已push。显式Cryptex重装事务20261019T124601Z-vZh3Hh4C最终核验拒绝，原盘身份/mtime与66样本保持，两个顺序验收脚本停止，未执行Undo或启动。已用真实删除记录与实际安装脚本复现已有目录符号链接的ln -sf额外写入，改用ln -sfn，并在写入入口拒绝跟随目录或尾斜杠；最终严格比较保持并新增目标/字段诊断。相关43项及最终完整Python948项（跳过2项）通过，签名应用和原VM程序保持核验通过。修复后重试CLI4097/session59096已发起，Undo及on→off→on尚待验收，T32/T33未accepted。

真实失败的首次不一致目标未记录，staged已按流程清理，无法直接核对全部最终状态。失败日志包含616条操作；删除记录将Cryptex内com.apple.dyld/com.apple.dyld和dyld/dyld置为missing。隔离运行实际regular安装器时，已有外层目录符号链接使ln -sf在目标目录内新增同名链接；把这两个真实删除观察交给生产最终比较器即可复现相同错误。此机制已复现，真实重试仍需确认是否存在其他不一致。

regular的跳过分支、复制分支与development同类命令改用ln -sfn；guarded writer仅新增此参数，并拒绝会跟随已有目录符号链接、带尾斜杠目录目标或真实目录目标的调用。新增实际安装脚本和写入入口失败回归、带旧内部链接的整树替换/发布/原件Undo组合回归。最终比较仍逐字段严格相等，错误增加目标和不一致字段名，AA.gl漂移拒绝保持。

最终完整Python命令make test_python，948项、跳过2项、259.925秒退出0。相关43项、12.775秒退出0；沙箱fclone EPERM原日志保留，宿主原断言重跑通过。此次未修改Swift和二进制补丁；host CLI仅因资源封签改变签名字节，可执行内容保持；原获批VM程序字节、inode和CDHash保持。证据：`evidence/T32-T33-new-vm-20261018/cryptex-symlink-20261020/manifest.json`。

## 2026-10-20：续跑只读核验

已取得 VM 目录锁，按正式 cfw_disk_txn.sample_digest 计算 66 段采样，SHA-256 为 6715076b65c9b03b5313ab5f62c0a5e69dd352072cb63e5f8fe5e56543b35108，与安装前记录一致。完整磁盘摘要未重算，未启动或写入 VM。指定 root 历史事务等待原生验证读取；尚不能确认退出原因。旧验收/归档进程不存在，未重启安装或自动归档。证据：`evidence/T32-T33-resume-20261020/manifest.json`。

## 2026-10-20：141 退出复现及持久日志重试准备

已只读取得事务与最后 14 条操作摘要。真实退出为 141，109 条操作止于 GPU 归档删除；无最终效果报告或发布证据。原事务明确记录原盘身份及 66 段采样保持。

隔离正式 host-driver 对照命令：`PYTHONDONTWRITEBYTECODE=1 .venv/bin/python3 .build/t32-resume-20261020/compare-output.py`。三个场景通过：关闭 stdout 消费者得到 141/failed，普通日志得到 0/published，普通日志加安装错误得到 37/failed；三个场景原盘均保持且无残留 staged。该结果证明可复现路径，不能确认真实输出消费者退出原因。

持久进程 PID93069 使用普通日志，先等待指定失败事务及 .cfw_temp 的原有 invoker handback，再检查签名/输入/磁盘身份，执行同 generation 的安装、启动前撤销、重新应用及各两次 API 启停和读回。所有生产核验保持；未改动 VM 程序、宿主放行或 Git。重试安装前仍须系统原生管理员验证。证据：`evidence/T32-T33-resume-20261020/manifest.json`。

## 2026-10-20：T60 导入 FIFO 与批量选择

当前源码实现 FIFO 等待、批量选择、等待项取消和退出门关闭后不启动下一项。原实现 2 项回归记录 4 个失败；实现后相关 26 项及完整 LaunchpadKit 210 项通过，6 项真实 CLI/烟测按配置跳过。首次沙箱运行的 4 个权限失败保留，同一已构建测试在沙箱外通过。逐项队列行/进度/取消 UI、签名交互和完整退出矩阵未完成；T60 整体未 accepted。详情：`T60_import_queue.md`。DSC 冻结安装继续在独立持久进程中运行，未由本轮源码构建替换。

## 2026-10-20：T60 状态/取消/退出后续验证

逐项导入状态和取消入口、等待选择取消、活动项排空、退出时混合转移取消及超时保留状态已实施。31项定向、216项完整LaunchpadKit通过；独立Release签名候选及嵌套工具链/依赖/资源检查通过。真实签名CLI的隔离并发导入复验通过：两个归档发布、源盘/目标盘/归档完整摘要保持、输出排空；具体摘要已归档。真实UI操作、字节进度、真实VM迁移及完整混合版本退出矩阵仍未验收，T60整体未accepted。证据：`evidence/T60-import-state-20261020/manifest.json`。

## 2026-10-20：完成当前DSC项的执行条件

用户要求继续完成当前项，本轮仅继续已有T32/T33验收。安装已从seputil推进到GPU归档提取入口，持久进程存活，未发布；未启动重复安装。后续VM程序的参数探测返回-9，程序字节、inode和已批准CDHash保持；16:33:10宿主日志确认amfid的restricted entitlements拒绝。仅按既有同哈希授权恢复临时helper，等待系统管理员验证，不扩展允许范围、不改SIP/启动参数或持久列表。准备了最终归档脚本，只有七组真实证明、三份journal、同generation、6885代码页和两组正常启停/读回全部匹配才会通过；脚本目前仅做语法检查，未执行最终归档。

## 2026-10-20：管理员验证后附加失败

用户确认已完成原生验证并在终端执行 sudo -v。第二次调用实际返回 helper60603，但日志记录附加失败；当前 amfid60692 存在。冻结 VM 参数探测再次返回 -9，程序摘要与 inode 保持。工具进程 sudo -n 返回需要密码，用户终端凭据在该进程不可用。当前安装已推进到 GPU 文件 chmod 的冻结计划核验，未发布。已保存探测脚本及诊断辅助脚本；后者沿用唯一获批 CDHash 和现有断点处理，只增加 euid、LLDB 附加错误和目标 PID 记录。其原生验证待完成，尚不能判定附加失败原因。

## 2026-10-20：同 CDHash 放行复验通过

用户完成诊断调用原生验证。09:01:23 UTC 的日志记录 euid0、按名称附加成功、目标 amfid60692 和两个各有一处位置的既有断点；helper62985 仅载入获批 CDHash。保存的 probe-boot-readiness.py 在恢复前返回 -9，09:01:40 UTC 复验进入参数解析并按预期返回64，冻结 VM 摘要和 inode 保持。此前附加失败原因未查明；成功重试未改变目标查找方法或断点处理，不能据此确认进程重启、名称匹配或权限中的具体原因。只验证了程序执行条件，未启动 VM。CFW 继续至 GPU CodeResources chmod 的冻结计划核验，未发布；当前项的后续 Undo/重新应用/正常启停仍由既有顺序 runner 执行。证据：evidence/T32-T33-resume-20261020/manifest.json。

## 2026-10-20 17:52 CST：DSC 安装第6/7步

本轮只读观察确认第4/7步 iosbinpack64 已推进至第6/7步 mobileactivationd 签名前核验，verify-plan CPU97.3%，持久 runner93069/CLI94446/root97562继续。安装 CLI约3小时，尚未最终核验、封存或交换，on-off-on-result.json不存在；未把子步骤序号换算为全体验收百分比。诊断 helper因目标state10退出，但冻结 VM参数检查仍退出64，程序摘要/inode保持，未重复请求系统验证。保存 current-progress-20261020.json 和观察记录；当前剩余顺序为安装发布、未启动Undo、原件/6885代码页证明、两次正常启停、同generation显式重新应用、重复证明/两次启停/读回。T60代码已有31定向、216完整LaunchpadKit及1真实CLI检查通过，真实UI和完整VM退出矩阵待验收；本轮无新源码修改、提交或推送。

## 2026-10-20：在DSC安装期间推进T60

DSC独立VM和冻结程序继续执行安装，第7/7步vphoned安装入口已观察到，尚未发布。并行在独立临时库中补充真实CLI导入中的退出协调回归，2项9.065秒退出0；等待项不启动、活动CLI退出130、输出排空、无残留和指定摘要保持均通过。强化了真实 `.import-` 目录断言，首次测试观察路径错误和成功复验均保存；生产源码未修改。实际AppKit交互与完整VM/混合版本退出矩阵仍未验收，T60整项未accepted。证据：evidence/T60-real-import-termination-20261020/manifest.json。

## 2026-10-20 19:34 CST：状态复核

DSC仍在首次安装，已从vphoned推进到第7/7步末段launchd.plist的chmod前核验；verifier CPU94.2%，持久runner存活，CLI累计4小时44分钟。未最终核验或发布，未进入本轮Undo/重新应用/启停；最终on-off-on结果不存在。T60最近结果仍为18:11归档的2项真实CLI回归通过，之后没有新增UI或完整矩阵验证，不提升accepted。源码及证据未新增提交或推送。实际观察见 evidence/T32-T33-resume-20261020/progress-20261020-1934.json。

## 2026-10-20：安装计划核验的重复完整读取

源码确认 plan_gate 每次 write/sign 先经 from_environment/load_plan 调 Swift verify-plan；后者的 DesiredPlanStore.validate 先调用 loadVerified，再经 originalURLs 第二次调用 loadVerified。该路径核验generation原件；在CFW已交换inode后，还沿发布记录检查完整postimage和全部effect blob摘要。实际观察小型chmod/sign阶段分别等待数分钟，核验进程CPU持续90%以上。重复完整核验是当前主要已定位性能问题，各类摘要/读取的时间占比尚未测量；一次1秒sample因普通用户无权采样root进程退出255，未额外请求系统验证。未改变校验门或中断安装；安装当前已从launchd.plist chmod进入临时目录清理前核验，未发布。优化应先建立明确性能基线和篡改/身份变化回归，再决定如何复用已验证结果；不能直接以永久缓存替代当前读取要求。证据：evidence/T32-T33-resume-20261020/plan-verification-cost-20261020.json。

## 2026-10-20：单次计划读取完整校验去重

已将DesiredPlanStore.validate中第二次loadVerified改为从本次刚核验的manifest解析原件路径；每次新请求仍完整核验，无跨请求缓存。trace回归优化前捕获2次并退出1，优化后1次退出0；修改原件并恢复mtime仍拒绝。47项相关Swift及实际Release CLI的5种写入/8类变更拒绝回归通过。独立证据链夹具交替对照中位143.313ms→85.219ms，完整fileSHA256字节减半，输出与夹具摘要保持；不能外推真实64GiB安装时间。真实DSC安装发布/installed证明已通过，冻结程序继续执行启动前Undo，尚未整体验收。见T32_T33_plan_verification_performance.md及对应manifest。本轮未提交/推送。

## 2026-10-20 21:07 CST：继续真实DSC验收

用户要求继续完成真实VM验收。确认首次安装及installed-proof均退出0，事务20261020T070734Z-tjhO0rSZ、同generation、6885代码页及原件/补丁指令通过；当前root66219执行prepare-undo，尚无撤销发布。冻结CLI/VM/runner/postboot工具摘要均保持。参数预检查再次返回-9，已按既有唯一CDHash授权请求诊断helper恢复，原生验证待完成；有期限参数检查只执行非法选项，终态或12小时自动退出，不写VM或改宿主配置。Undo继续，不因启动前置条件等待停止。

## 2026-10-20 22:21 CST：真实启动前Undo发布

事务20261020T130129Z-EauDALvj（guest-dsc-undo-v1）于14:20:42 UTC完成，version4、status published、exit0，使用RENAME_SWAP。实际日志确认两个最终效果核验、挂载清理、发布及ownership handback通过；组件Receipt已共同发布，guest来源仍unknown。当前restored-proof正在核对恢复原件；尚未报告恢复证明、撤销后启停或重新应用通过。真实事务metadata和日志已保存至evidence/T32-T33-resume-20261020/undo-published-20261020，不包含镜像或blob原件；原件继续保留于VM journal。

## 2026-10-20 22:24 CST：恢复证明及两次正常启停通过

restored-proof退出0：实际原件SHA256为e41db9aa09ab60cb6015282c9230fba89a8971129fae00c16156b29b1855c9b5，w3恢复0x548，6885代码页核验通过；parent为本轮installed事务，guestOrigin unknown。撤销后两次API启动均读回26.0/23A341，bootSeconds和bootSessionUUID不同，stop/vm退出0、guestStopped true、forcedFrameworkStop false、diskReleased true；config/staged daemon摘要保持。当前运行后Receipt/generation读取正在执行；未将history读取或显示/运行时效果提前记为通过。实际证明已保存至evidence/T32-T33-resume-20261020/restored-20261020和api-restored-20261020。

## 2026-10-20 22:30 CST：撤销后运行读回通过并开始重新应用

Receipt和verify-plan均退出0，关联Undo事务20261020T130129Z-EauDALvj。状态committed-publication、runtimeImageChanged true、runtimeValidated false；发布SHA79e94266…与当前运行SHA6458b911…分开，磁盘物理身份保持。显式同generation重新应用CLI15708已开始普通用户预检；尚未观察到新root安装器或新磁盘事务。此前恢复原件、6885页及两次API正常启停证据均已封存到本轮续跑证据目录。重新应用及最终重复证明/启停/读回尚待执行。

2026-10-20 23:03 CST：重新应用的 root installer17578 已完成 host 入口检查并启动 regular 安装器入口校验。进程观察已保存为 `evidence/T32-T33-resume-20261020/reapplication-current-observation.json`；验收 runner、原始 CLI 和 VM 程序保持，当前无新发布结果。

2026-10-21 00:04 CST：重新应用已完成 SystemOS/AppOS 挂载，当前 staged Cryptex 替换操作仍在执行；新磁盘尚未发布。只读观察与 TASKS.md 已更新。

2026-10-21 00:54 CST：重新应用已完成两份 Cryptex 复制和 dyld 链接设置，DSC SwapEnd producer 按目标0x560启动，目前执行完整计划校验；无新发布结果。可用空间只读检查约46GiB。

2026-10-21 01:51 CST：重新应用已结束 Cryptex/DSC、seputil 和 gigalocker 步骤，进入第3/7项 GPU 驱动安装；尚未发布，完整 DSC 字节/代码页仍待独立证明。

2026-10-21 03:07 CST：重新应用已结束第3/7项 GPU 驱动安装，进入第4/7项 iosbinpack64 安装。恢复阶段的完整证明、两次正常启停和读回已通过；重新应用发布及后续证明仍待完成。resume manifest 顶层状态已更正为当前进度，原退出141诊断字段保存于 initialDiagnosis。

2026-10-21 04:09 CST：重新应用已结束第4/7项 iosbinpack64、第5/7项 launchd_cache_loader，当前进入第6/7项 mobileactivationd。安装器仍未报告失败；发布、独立证明和后续运行验证未完成。

2026-10-21 04:44 CST：重新应用已结束第6/7项 mobileactivationd，进入第7/7项 LaunchDaemons。冻结 cfw_common.sh 与 cfw_install.sh 中该项约有27个写入/补丁调用；按近期单次约7分钟估算，本项仍需约3小时，最终校验和发布另计。该数值为执行时间估算，未完成范围保持。

2026-10-21 05:46 CST：重新应用第7/7项中 classic vphoned、独立 API 的执行文件和 plist 安装步骤已结束，进入 bash plist 写入。当前仍未发布。冻结 CLI/VM 保持，前一性能优化候选不属于本轮运行输入。

2026-10-21 06:44 CST：重新应用第7/7项中 bash、dropbear、trollvnc plist 写入与权限步骤已结束，进入 rpcserver_ios plist 写入。安装器未报告失败，发布与后续验证未完成。

2026-10-21 07:09 CST：用户询问是否卡住。最新进程观察显示 runner 存活、verify-plan CPU约92%，已完成 rpcserver_ios 配置与 classic vphoned plist 写入，当前执行权限设置前校验。总状态 reapply-cfw 在完整安装结束前保持；按近期单次约7分钟和剩余步骤估计约1–2小时，未作为完成时限。


## 2026-10-21：T60 独立收尾及性能验证续跑（当前聊天）

修复跨选择导出并发和调用方取消未传播，保存原始失败回归；两后端导入/导出接入最终发布前源变化复查。完整LaunchpadKit221项、Core436项和Python37项通过。正式CLI入口对上一和本轮签名候选各6项通过。实际NSOpenPanel多选两个16GiB稀疏夹具，两个源/目标完整磁盘摘要均相等，无staging；随后UI工具的AX/截图/重绑定/重置连续timeoutReached。1秒sample显示主线程处于正常事件循环，超时原因未查明；实际UI取消和AppKit Quit不提升通过。T60保持未accepted，详见T60_import_queue.md和evidence/T60-closeout-20261021/manifest.json。

按用户顺序继续计划读取性能优化收尾。已构造含两个4GiB历史postimage的独立合成夹具，并通过正式Swift/Python验证链发布及Undo。新增通过Store.read直接核验身份/历史证据拒绝的断言，相关48项通过、可选fixture按配置跳过；完整trace确认两个独立读取各一次loadVerified和verifyOriginals。首轮对照输出及夹具摘要保持；该轮部分时间与回归并行，正在独立重测作为最终时间证据。不替换正在真实验收的冻结程序，不操作其VM。


2026-10-21 当前聊天最终复核：4GiB历史证据链独立Release对照中位7.155970秒→3.657979秒，完整摘要读取17179943362→8589971681字节；每请求generation核验2→1，输出/夹具摘要保持。48项相关回归包含1项配置性跳过，执行47个函数通过；具体identityMismatch断言的3个实际verifier函数再次通过。两份新证据索引的全部文件和源码SHA256复核通过，66个任务ID唯一、JSON有效、git diff --check通过。真实冻结CLI/VM摘要保持。T60实际UI取消/Quit仍因工具超时未验证；T60与T32/T33整体状态不提升，源码/证据仍未提交或推送。

2026-10-21 08:03 CST：重新应用全部7项组件安装与清理步骤已结束，进入第一轮最终效果核验。快照处理、第二轮核验、封存/交换及重新应用后的独立证明与运行验证仍未完成。

2026-10-21 08:13 CST：按当前 root17578 的两次直接 verify-final 调用及冻结脚本顺序核对，第一轮最终效果核验、cleanup 与启动快照处理已结束，进入第二轮只读核验。已保存调用PID/观察时间及host脚本SHA；封存、发布和后续独立/运行证明仍未完成。

2026-10-21 08:36 CST：两轮最终效果核验和启动快照处理已进入后续 seal。封存进程74327先后执行两个直接 verify-plan 子进程74344/83091；两者均已结束，seal仍在运行。进程观察和研究清单已更新；未确认封存、发布或重新应用后的运行验证通过。


### 2026-10-21：T60剩余实现和离线矩阵

完成创建退出等待、Finder归档排队/UTI、版本化JSONL进度、socket排除；实际GUI缺zstd已复现并打包zstd/xz和依赖/许可证。最终r3候选签名/资源/依赖通过，Kit227（跳过10）/Core441（跳过1）/ArchiveCLI2函数/Python62+7通过；新旧具名签名CLI各8项、真实信号导入4+导出4场景通过。旧VM克隆导出15,564,157,664字节归档通过。实际GUI因Mac锁定待手动解锁；真实VM导入需30,044,004,352字节空闲且当前差约2.2GiB，待释放至少3GiB后复核。未删数据，未启动旧VM，不更改DSC冻结输入；T60未accepted。证据：evidence/T60-remaining-20261021/manifest.json。未提交或推送。

2026-10-21 09:12 CST：独立 DSC 启动前 Undo→同generation显式重新应用真实VM序列已通过。10阶段退出0，7组证明通过；恢复与重新应用状态各2次真实API启动/正常关机、26.0/23A341、磁盘释放和运行后Receipt/generation读取通过。最终归档118个索引文件/26,257,055字节的大小与SHA-256独立核对通过；指定后台PID均已不在进程表。源构建冻结基线d968d02f，优化候选未纳入本轮；不推进运行效果、图形、Mach-O/Preboot或受信来源的接受状态。证据：`evidence/T32-T33-new-vm-20261018/dsc-on-off-on-20261020-resume/manifest.json`。本轮未执行Git提交或推送。


### 2026-10-21：T60用户解锁后实际矩阵

最终r3实际导入/导出等待和活动Cancel、传输Quit超时保留及排空退出、Finder冷/热打开通过；两个16GiB完整摘要保持。真实64GiB默认system-tar导入完成，8个持久文件及源VM/归档完整摘要保持，无staging、未启动VM。新增正式native稀疏/硬链接回归，新旧签名CLI各9项通过；Kit228项（跳过11）通过。native真实大盘两次触及保留空间并取消，分配差异原因未查明，未修改生产归档代码。待批准清理本次约62GiB的system-tar/restored测试副本后复验，原盘/归档/结果保留。实际create/restore与更广历史组合仍未验收，T60未accepted。证据：evidence/T60-resume-20261021/manifest.json。


### 2026-10-21：T60具名矩阵完成

用户批准后仅删除本次system-tar/restored测试副本，空闲恢复77.824GB。相同r3候选/归档的native64GiB真实导入通过，8个持久文件完整摘要一致，原VM/归档保持，无staging、未启动VM；native目标分配约27.5GiB。GUI、两个签名CLI各9项及两个真实导入后端的具名矩阵完成，可提交评审。分配差异原因未查明，不声称修复；实际restore退出、导入后启动和全部历史组合仍未覆盖，不代替人审accepted。最终证据：evidence/T60-final-20261021/manifest.json。未提交、推送或发布。


## 2026-10-21：新目标 U0 Git 核验与首轮源码对账

按当前用户继续推进待办的请求，取得固定目标2a0d3ac；8a75092..2a0d3ac完整Git图确认57条提交（20 merge、37条其他提交）、first-parent19条、端点215路径。全部merge父差异和排除根TODO.md的端点内容已归档。附件原枚举当前不可读，未冒充独立集合比对；旧194条统计不与本轮相加。

保存当前HEAD+WIP摘要和tracked diff，57条记录逐条路由，原仓库对象重建结果一致；错误范围/遗漏提交拒绝通过。核对全部7份锁文件及两份ROM二进制与固定记录摘要；确认上游IcliKit0.8.6与本地0.8.5差异。本地API文件传输已有身份/临时发布能力，classic和GUI大文件仍须分别适配；ROM、tvOS/X1和默认值不自动扩大。完整语义评审、依赖升级及新目标运行验收未完成。

66项唯一ID/依赖无环、历史status/target_review/dependencies保持及既有脏源码摘要核对通过。本轮未改生产实现、未运行VM、未提交或推送。项目.venv指向已不存在的生成目录，仅使用系统Python标准库；下一项为恢复受锁文件约束的项目环境，再审阅T08依赖与guest RPC兼容。详见U0_source_audit_20261021.md和evidence/U0-20261021/manifest.json。


## 2026-10-21：T08 IcliKit 0.8.6 适配与独立候选

承接U0后续任务，按项目3.14平台锁恢复.venv；locked probe、包版本及pip check通过。核对0.8.5→0.8.6四条提交/七个端点文件：主要修复为前台用户lookup的sessions guard；Swift调用和JPEG源文件未变。同步本地exact requirement、resolved/expected pins和overlay revision，原JPEG补丁及内容摘要保持，其余六项pin不变。

独立.build/daemon-api-icli086-20261021的iOS Release编译链接和classic/v2候选签名、依赖、marker、来源检查通过；候选未安装或激活。16项pin/overlay和3项实际固定依赖宿主回归通过，新增foreground guard已接入正式测试。正式make test_python全量运行中，终态见后续记录与manifest；不以宿主替身或构建结果证明真实tvOS/iOS运行。初始网络沙箱失败和最终成功日志分别保留；冻结应用两份执行文件摘要保持。详见T08_icli086_20261021.md及evidence/T08-icli086-20261021。未提交或推送。


2026-10-21 T08终态：正式make test_python运行949项、250.597秒，退出0，跳过1个默认NIO目录缺失的测试类。夹具新增隔离SourcePackages入口并核对实际NIO revision后，该类2项补验通过（15.725秒）。没有重复全量，也未弱化原断言。16项pin/overlay、3项固定依赖宿主回归和classic/v2独立iOS候选检查均通过。证据清单、原始失败/成功日志和源摘要见evidence/T08-icli086-20261021/manifest.json。实际guest服务、应用与截图内存仍未验收；候选未安装或激活，旧accepted和旧目标证据保持。当前可继续T47/T48来源/恢复边界对账。未提交或推送。


## 2026-10-21：T47 与 T48 克隆身份边界、APFS 快照与四层来源对账

承接T08后续任务，完成T47（`rename` 派生mDNS跟随、`clone(newIdentity:)` 身份与独占网络清理、复制前后停机与无漂移签名校验、根级 `.firmware-*` 与 `Snapshots` 排除、SEP/Data密钥共享说明）和T48（`<bundle>/Snapshots/<name>/Snapshot.plist` 必选/可选状态文件整组CoW快照、`.snapshot-revert-*` 事务日志与崩溃恢复门控、恢复后缺失收据重置、四层 `launchpad.json` 对账及 `vm snapshot create|list|revert|delete` CLI）全部实现。

7个Swift测试套件（`BundleActivityTests` 12项、`BundleSnapshotsTests` 12项、`BundleOpsTests` 29项、`BundleCloneStateTests` 12项、`MachineSnapshotsTests` 4项、`FirmwareDesiredPlanStoreTests` 18项、`VMSnapshotAndCloneCLITests` 2项）共89项测试全部通过（退出0）。快照恢复与新身份克隆均拒绝直接复用源机 `FirmwareDesiredPlanStore` 预检资格。真实64GiB VM快照恢复与双机并行启动仍未验收，历史status保持。详见T47_T48_clone_snapshots_20261021.md及evidence/T47-T48-20261021/manifest.json。未提交或推送。


## 2026-10-21：T52 恢复验证与归档

读取中断交接并核对保留源码。完成进程分类、停止保护、Launchpad绑定顺序和CFW外部挂载工作区的离线验证。新增真实lsof自身排除/外部读者检查与长Unix socket探活回归。发现最终只读挂载根绑定失败会跳过清理，修复前副本故障注入稳定复现，正式驱动修复后通过，原磁盘摘要/inode保持且未发布。

首轮Python沙箱staging遇到EPERM，无沙箱同套件50项通过。最终Swift定向55项、Kit239项（跳过11）、停止/锁35项通过。Python11模块235项中234项通过，唯一Undo驱动夹具缺模块失败修正后原用例1项补验通过；断言和生产拒绝条件保持，无未解决测试失败。

setBundle当前仅有库接口，GUI/控制命令接线、真实跨设备/devfs与VM安装启动仍待验证。保留历史status/target_review/依赖与新目标accepted=false。未操作真实VM或冻结.app；未提交或推送。报告：T52_disk_exclusivity_20261021.md；证据：evidence/T52-20261021/manifest.json。


## 2026-10-21：T51 实现和离线验证

实现vm rebase --onto/--dry-run/--recover；持双机目录锁，私有候选逐字节及完整SHA-256校验后journal交换，恢复前阻止Swift/Python其他入口。新增/已有共享按原盘物理extent区分，逻辑字节及身份/SEP/NVRAM/来源元数据保持，实际FirmwareDesiredPlanStore回归确认旧inode资格拒绝。

Launchpad接入物理计量与Allocated/Exclusive/Unknown展示、30秒刷新/15秒预算和按文件缓存。逐文件占用复查及共享目录锁排除合作启动/写入，目录错误、未知映射和过期结果不报告已确认独占量。

扩展Core XCTest93项/Swift Testing498项（跳过1）、Kit244项（跳过11）、CLI4项、来源19项通过；最终Kit245项、相关Core48项、CLI2项、来源19项通过。Python标准958项（跳过4）发现4项历史边界/文案失败，按具体调用修正后受影响38项通过；锁9项通过，无未解决失败。分组存在重复，不相加。

模板基准等待T49，真实外置卷/跨卷/非APFS故障、实际GUI与VM启动、完整进程崩溃矩阵未验收；历史状态和依赖保持，accepted=false。未操作真实VM或冻结.app，未提交或推送。详见T51_disk_rebase_20261021.md与evidence/T51-20261021/manifest.json。后续按计划先推进T50精简基础，再处理T49模板构建。


### 2026-10-21 T51/T52真实磁盘与界面验收

真实64GiB副本rebase和原VM摘要/身份复核通过，新增共享64MiB，无pending。实际界面暴露逐文件lsof预算问题；最小回归先失败，修复后完整Kit248项及Python24项通过，r2实际停止/外部读进程/释放恢复回归通过。新签名及冻结VM程序均被AMFI受限权限检查拒绝（--help退出-9），真实启动等待本次具名CDHash临时放行授权；未更改主机安全设置。外置物理卷按用户指示暂缓。报告T51_runtime_acceptance_20261021.md，证据evidence/T51-runtime-20261021/manifest.json。accepted=false，未提交或推送。


2026-10-21具名启动续验：用户已批准419d5a6c候选临时AMFI放行。sudo -n需要密码，Computer Use禁止操作Terminal；已提供具体命令供用户终端认证。候选身份复核保持，helper增加900秒上限和停止标记，两次真实启动及35秒GUI检查点脚本已准备。helper尚未启动，未改变主机安全设置，实际启动仍未执行。授权持续有效，不重复请求。


2026-10-21 T51真实启动续验完成：仅使用用户批准419d5a6c候选，对已rebase的target执行两次真实启动和生产vm stop。guest连接、26.1/23B85、不同boottime/instanceID、正常关机和磁盘/目录锁释放均通过。实际r2运行实例、Unknown/缓存提示、关机后当前计量回归通过；运行中rebase拒绝。原输入完整摘要/身份复核保持，base未启动，vm-2607仍为原PID；helper8387已停止且PID不存在，无持久允许名单写入。最终证据evidence/T51-runtime-20261021/authorized-boots/manifest.json，范围见T51_runtime_acceptance_20261021.md。外置卷仍暂缓；accepted=false，未提交或推送。


2026-10-21 T52入口续验：T51已提交4b5117d6，未推送。本轮接入机器绑定弹窗及新绑定Bundle的环境更新协议，保留完整备份、来源和认证约束；实际子进程成功/失败/取消与绑定漂移拒绝回归通过。Swift各扩展组256/35/2/42项、Python相关218项和最终绑定模块56项通过，分组不相加。用户具名批准后的签名候选绑定界面回归通过，取消后所检查VM文件保持。root-owned store不存在，真实绑定及环境替换尚未验收；外置物理盘按用户要求暂缓。本轮源码未提交、accepted=false；见T52_entrypoints_20261021.md及evidence/T52-entrypoints-20261021/manifest.json。


2026-10-21 T52真实验收续跑：root-owned具名Bundle安装与收据核验通过，独立regular/v2恢复通过。CFW因验收命令的仓库资源覆盖选择0.8.5 guest载荷，与0.8.6 pins不匹配而退出；原盘抽样/身份保持，暂存盘未发布。批准Bundle内0.8.6组合只读检查通过；修正参数后因8份资源快照保留上限拒绝，已完整备份并核验一份失败快照，待用户批准删除仓库外该原副本。绑定和实际环境替换仍待执行，accepted=false。报告：T52_real_bundle_environment_20261021.md；证据：evidence/T52-real-20261021/manifest.json。

2026-10-22 T52真实续验：regular/v2 CFW、first_boot及verification全部succeeded/verified，命令退出0；五库-O0基线只读检查为offline_update。实际界面完成完整备份核验和2.6.2-local.cd529f26a150绑定，环境预检因Process.environment=nil丢失PATH而找不到lsof，未替换盘。实际子进程回归先失败，修复后23项定向和完整Kit258项测试通过、跳过17项；新候选签名/封装及内嵌字节保持检查通过，待新候选打开授权后继续。原boot-window三次附加后停止且PID不存在，不复用。外置物理卷仍按用户要求暂缓，accepted=false，未提交或推送。

2026-10-22 03:40 T52续推：实际GUI经批准Bundle完成五库环境替换，事务20261021T163833Z-aCYGC037于00:43:02 published且exit_code=0。独立只读already_current、33项断言和历史原盘inode/抽样复核通过，系统Bundle收据及受保护VM复核通过。Mac锁定，完成界面与替换后启动尚未验证；已请求手动解锁及新的600秒单哈希一次附加窗口批准，新脚本未执行。单次续推未新增重复调度；外置卷暂缓、accepted=false、未提交。见T52_real_bundle_environment_20261021.md及evidence/T52-real-20261021/manifest.json。

2026-10-22 07:14 T52替换后验收：默认GUI绑定启动与五库客户机摘要读回通过，但未启用API的默认停止超时，框架强制停止，原失败保留。API模式同一Bundle/绑定启动，经实际GUI正常停止，apiAccepted和Guest stopped、退出0、磁盘/锁释放通过；五库当前映射确认，24项运行证据断言通过。单哈希600秒窗口仅附加一次，352.713秒后停止且PID不存在，原VM/受保护副本/系统Bundle最终核对通过。默认GUI关机限制未修复；应用行为和外置物理卷未验收，accepted=false、未提交，调度保持暂停。见T52_real_bundle_environment_20261021.md及evidence/T52-real-20261021/manifest.json。


## 2026-10-22：T52 默认 GUI 关机修复候选

默认停止路径新增仅停止时使用的直接VSOCK API请求，不创建宿主HTTP监听。生产选择路径及客户机Connection: close协议回归先失败后通过；最终分组108项通过，既有APIProxy混合运行失败原因未查明，单项及11项独立套件通过。独立候选2.6.2-local.af333c78ac3b签名/依赖/封装通过，客户机资源与Framework库字节保持。具名安装、t52-v2宿主重绑及600秒新单哈希批准请求已提交；均未执行，真实默认GUI关机仍待验收，accepted=false、未提交。详见[T52_default_GUI_shutdown_20261022.md](T52_default_GUI_shutdown_20261022.md)。

T52默认GUI候选已获具名安装/宿主重绑和600秒一次附加单CDHash的明确批准。sudo -n需要认证，脚本未运行；已请求用户终端执行，实际GUI可读取，重绑准备弹窗已取消，目标仍为原绑定且停止。批准范围保持有效，后续无需重新批准。


## 2026-10-22：T52 默认 GUI 真实正常关机通过

具名2.6.2-local.af333c78ac3b已安装并复核，仅t52-v2宿主重绑，客户机环境更新未重跑。实际默认图形启动无HTTP API监听，26.1/23B85及五库目标摘要匹配；实际GUI停止经直接VSOCK请求获得apiAccepted、Guest stopped及退出0，磁盘/目录锁释放，身份配置和新绑定保持。实例969AF5BD-896B-4636-B7E4-260EC4AEE33A、PID64720。验收脚本日志轮换偏移缺陷已保存失败并修正，4项边界回归通过，未重复启动VM。600秒单哈希窗口仅附加一次，205.739秒后停止且PID独立确认不存在；原VM33355和受保护副本保持，两版Bundle收据核验通过。默认GUI问题已完成修复与真实验收，混合套件既有APIProxy失败原因未查明，应用行为和物理外置卷仍未验收，T52整项accepted=false、未提交。见[T52_default_GUI_shutdown_20261022.md](T52_default_GUI_shutdown_20261022.md)。


## 2026-10-22：APIProxy 混合失败已定位并修复

停止先关闭全局准入再逐个关闭客户端，原reserveAttempt将停止与容量耗尽都返回false，调用方可能在客户端关闭前误发503。独立12轮1次复现；100轮竞争20个错误503，10轮阶段对照通过；无探针单变量反证55个错误503。修复在同一锁内区分三种准入结果，停止直接结束，真实上限503保持。APIProxy13项通过；原混合组合加2项回归后110项连续3轮通过，未隔离失败测试。临时探针已移除，源码与证据已保存；未重建/安装Bundle、启动VM、修改AMFI或提交。报告见[T52_APIProxy_stop_race_20261022.md](T52_APIProxy_stop_race_20261022.md)。

APIProxy修复已提交a0119127，未推送，其他未提交工作保持。部署候选2.6.2-local.266810c8ae29完成签名/依赖/资源解析与512个源码摘要核验，客户机资源和Framework库字节保持。sudo -n需要密码，安装脚本未执行；已请求用户终端认证。安装后仅重绑t52-v2，核验脚本已准备，不启动VM或修改AMFI。详见[T52_APIProxy_deployment_20261022.md](T52_APIProxy_deployment_20261022.md)。

APIProxy修复a0119127已部署为2.6.2-local.266810c8ae29，仅切换已停止的t52-v2宿主绑定；新旧收据、安装字节、绑定及磁盘元数据/选定配置摘要核验通过，原VM和受保护副本保持。客户机资源与Framework库字节保持，未重跑环境更新，未启动VM、未修改AMFI、未推送；新版本真实启动未验证，T52整项accepted=false。详见[T52_APIProxy_deployment_20261022.md](T52_APIProxy_deployment_20261022.md)。

2026-10-22续推：T52新宿主版本停止/绑定界面与只读基线通过，应用探针构建和10项验收资产回归通过；已批准900秒单哈希窗口仍待终端认证。下一项T53固定源码审计、3个C程序及实际SystemHook/DeviceHub隔离构建通过，修正Undo夹具合同后106项Python、14项Swift通过；未接入或部署T53产品，迁移与真实工具验收待完成。详见T52_application_acceptance_20261022.md及T53_developer_compatibility_20261022.md。

T52后续实际执行：新版本默认GUI真实启停通过；同一独立VM的API会话保持运行。辅助进程在745.972秒、一次附加后停止且独立确认不存在。用户完成初始设置后，设置应用启动对照通过；探针启动仍失败，kernel记录System Policy process-exec拒绝。arm64单变量对照未消除失败，已准备原始arm64e正式容器IPA；当前等待仅注销本轮注册项及原生安装暂存清理的明确批准，未执行该步骤。T53隔离候选与回归结果保持，未接入产品或部署。


2026-10-22 T52正式容器续验：已执行用户批准的本轮注册项注销及apps.install安装，旧探针文件摘要和原数据路径保持。正式容器启动仍failed且无进程，kernel出现TXM CodeSignature错误，具体条件未查明；移除platform-application及arm64对照均失败，已恢复原始安装字节。系统相机/地图能启动，但cameraPresent=false、连接未建立；实际classic daemon与v2相机库包含不同共享内存路径，源码头大小定义256/64不同，连接重置的具体原因仍待验证。定位来源确认未计消费通过。本轮来源及系统对照应用已停止，受保护VM和绑定复核通过；t52-v2按用户要求保持运行，AMFI辅助未重启。下一步查明签名拒绝条件、统一相机组件接口后补定位/QR消费验收；外置物理卷暂缓，T52 accepted=false、未提交。见T52_application_acceptance_20261022.md及其证据清单。

### 2026-10-22：T52 签名/相机接口实际续验

CMS单变量ABA启动通过；共享协议统一及相关回归通过，全量Python970项通过（4跳过）。.938候选已部署，两库事务发布，完整旧盘保持，只读复核already_current。实际定位仅一条七字段正确回调，相机仍无设备/无回执；探针共享帧open=EPERM、定位桥接文件open=ENOENT，消费未通过。临时辅助与debugserver在900秒内结束并独立确认，原VM与三副本复核保持。仅增加可读初始化日志的.56诊断候选已构建核验，未安装，新的具名部署和单次窗口批准待答；当前VM保持运行、来源与探针停止。详见T52_signature_camera_20261022.md与161项证据manifest；accepted=false。


2026-10-22 T52 诊断部署续推：用户批准及认证后，2.6.2-local.56be1ce20ded两库事务发布、旧盘保留和只读already_current核验完成。新实例372C906F-9315-4ED3-B596-94670EEA9AAA/PID98713就绪，独立监督窗口一次附加69.615秒后结束。完整日志确认虚拟源创建成功，代码页修改和共享帧访问失败；空设备枚举完整原因仍未查明。定位正常授权后仅1条正确回调，严格双回调失败；API对照被owner/generation校验拒绝，未绕过。启动socket竞态3项回归及工具组合18项通过。85项新证据独立归档，前批161项保持；来源和探针停止，五库/旧盘/收据/受保护对象复核通过。待在所有权发布链接入定位桥接、修复相机访问及枚举条件后补消费，accepted=false。详见T52_signature_camera_20261022.md及evidence/T52-camera-diagnostic-20261022/manifest.json。


2026-10-22 T52功能候选2.6.2-local.cc05d88f441f已封装及核验；完整Python995项通过（4跳过）、最终定向36项通过。用户明确批准五库/API/发布端缓存的完整克隆替换、临时探针、新900秒单哈希一次窗口。首次安装store busy拒绝，保留日志；t52-v2现已通过系统设置正常关机，PID98713退出，原VM33355保持，正在重试同一归档，窗口尚未开始。消费accepted=false。见T52_consumer_fix_20261022.md。


T52 补充批准后的实际部署完成：cc05d88f441f 的 System 五库/API 克隆事务发布，旧盘完整保持；辅助一次附加 60.199 秒后退出，原 amfid 自行退出，旧 SIGCONT 认证取消，无重新附加。匹配发布端切换及新旧摘要核验通过。两个定位坐标各 5 条七字段回调通过，相机 v3 双层复制回执通过；标准相机授权为 Authorized，但公开视频设备为空，QR 仍失败。不重启的实时日志记录普通视频源返回 0，完整原因未查明。原探针恢复并停止，来源 off，原 VM 和三个受保护副本保持；22 项工具回归在沙箱外通过。一次具名 cameracaptured 重建日志计划已准备并请求补充批准，尚未执行；accepted=false。详见 T52_consumer_fix_20261022.md。


2026-10-23 T52：已批准的一次相机重启完成，日志确认backing/hook安装，但原生视频源为0。应用内原生共享provider查询返回nil；同版本控制流显示无源信息时共享实例不创建。仅实例getter的缺接收者回归先失败，增加共享getter fallback后通过；原生类/实际backing应用内诊断通过，原程序恢复。单库候选4bd0cce62c46封装核验通过，其他客户机库/API/发布端/宿主VM字节保持；完整Python1017项（4跳过）、单库事务9项、工具24项通过。正式QR仍失败，回执通过；来源和探针停止、受保护对象保持。新候选部署计划待具名批准，未执行，accepted=false。见 T52_provider_fix_20261023.md。


2026-10-23 T52单库候选4bd0cce62c46已按批准部署，完整旧盘重新计算SHA相同，其他库/API/发布端保持。新实例C56C5714-474B-4E54-9E2D-52FC17900A2F定位两点各5条七字段正确回调，QR A/中性帧6.183秒无QR/QR B及v3回执全部通过。正常权限探针未编入诊断hook；cameracaptured普通类型1源返回1。一次辅助窗口86.345秒后进程与debugserver独立确认不存在，同一amfid未暂停，无SIGCONT。原探针恢复、数据保持、来源off、原VM和三个副本核验通过；首次路径失败和启动后探针前置拒绝保留。当前应用消费范围完成，外置物理卷按此前要求暂缓，业务应用未验，整项accepted=false；无提交或推送。运行证据另存evidence/T52-provider-fix-20261023/runtime/manifest.json。


2026-10-23 T32/T33推进：新增正式cfw verify-effects，独立只读核验当前盘4681个目标，4680匹配，仅hardware:/AA.gl内容摘要不同；DSC .42完整摘要、6885代码页和原件关联通过，符号派生语义仍为w3=0x560。保留发布镜像4681项全部匹配，具体写入者和原因未查明。最终Python1030项（4跳过）、相关100项、Swift命令3项、新reader16项及运行准备2项通过。包含原盘的12个根级持久文件完整备份通过，元数据保持。更广撤销、图形/补丁运行效果及受信guest来源仍待补；新一次GUI/AA.gl摘要/显示帧观察与单哈希900秒一次窗口已形成具名计划，尚未批准/执行。accepted=false，无提交推送。见T32_T33_installed_effects_20261023.md及独立证据。

2026-10-23 T32/T33具名运行诊断：一次GUI/API启动并正常关机；AA.gl file_get返回EPERM，显示帧未采集，运行效果未通过。限定辅助一次附加18.847秒后退出、amfid未暂停；未重附加。修复观察脚本独立阶段错误处理，4项回归通过，实际旧失败保持。启动后磁盘只读核验等待系统认证；无新增固件/内核/DSC补丁，更广Undo与受信guest来源仍未完成。详见T32_T33_installed_effects_20261023.md。

2026-10-23 T32/T33启动后只读核验完成：4680/4681匹配，唯一AA.gl在本次受限操作区间内由f92c991d…变为ff2f7d4b…，具体写入者、时点和原因未查明；其余4680目标与启动前相同，6885签名页通过。严格退出1及原基线保持。两卷正常卸载、镜像detach，独立确认目标未附加，审计期间身份与元数据稳定。一次运行诊断结束，无再次启动或附加；设置显示、更广Undo、受信guest来源及补丁运行因果效果仍未通过。报告T32_T33_installed_effects_20261023.md；新增只读证据post-runtime-readonly，accepted=false。

2026-10-23 T32/T33续推：普通v5逐声明收据、固定Mach-O/Preboot数据的generation原件及完整文件Undo已实现并通过回归；全量Python1059项（4跳过）、Swift3项、文件/审计定向28项通过。候选f25c0583c438、335冻结输入及完整12项备份已核验，用户批准cdb74f7a…离线计划并完成认证，真实三项Mach-O on/off/on执行中。无新VM启动或辅助窗口；受信guest来源、GUI运行和整项验收仍未通过。详见T32_T33_completion_20261023.md。


2026-10-23 T32/T33隔离验收进度校正：原计划cdb74f7a…首阶段在写盘前被身份门拒绝，三项Mach-O应用、撤销、重应用均未完成；12项持久文件及335项冻结输入保持。两份早期v4祖先记录缺少盘、postimage和effect-blobs，缺失时点及原因未查明。Swift身份读取器另已补齐v5/schema3兼容并通过v4/v5、完整文件Undo和真实只读回放。新候选a88440c704e4及新隔离计划f3eabf4a…已获用户批准，340项冻结输入复核通过，当前等待macOS系统认证，尚未创建新副本。两批准备/失败证据共119及40项分别归档并逐项核验。未启动VM或开启新窗口；受信guest来源、GUI/补丁运行效果与整项验收仍未完成，accepted=false。详见T32_T33_completion_20261023.md。

2026-10-23 用户已完成新隔离计划f3eabf4a…的系统认证，原生root执行器已启动，fresh-offline-acceptance目录及根执行日志已生成。执行器先检查具名缓存及磁盘空间，再完整复核原VM的12项启动文件；尚无任何on/off/on通过结论，不启动VM或辅助窗口。


2026-10-23 新隔离计划f3eabf4a…实际结束：generation=34abf58b3c5166e0b393f8e9c53b14deee5835efc4ec561f6629ef0c79c89664，语义计划与批准相同；首次CFW已采集generation文件原件，但旧assert_mount_under_vm在SystemOS挂载前拒绝批准的外部工作目录。没有新磁盘发布，三阶段均未计通过；按失败即停止，未重试。两盘均无附件，失败暂存正常卸载并清理，失败journal保留。独立完整摘要确认原VM12项身份/元数据/内容保持，新副本10项启动文件仍与备份相同且inode独立，340项冻结输入保持；两个受保护VM仍运行。正在建立该路径检查的复现及修复；新候选续验需具体方案，原批准不自动重试。accepted=false。


2026-10-23 外部挂载路径修复：实际shell复现3项仅合格外部路径失败，拒绝分支保持。assert_mount_under_vm对外部路径改用现有private_path门：重读冻结计划、继承VM锁、核对journal中mountRoot的dev/inode/uid及无符号链接路径；真实mount-cryptex仍单独核验固定挂载目标、源镜像和generation。16项挂载/工作目录及121项相关shell、计划门、宿主事务和文件Undo回归通过，续验执行门2项通过，语法和空白检查通过。未增加固件、内核或DSC指令补丁。

修复候选2.6.2-local.887b0069c62a封装及签名/依赖闭包/Bundle核验通过，归档SHA-256为55b37cf5f02ed228e4dfda0b423161b7bf7747995db29dc985259eb083777c9a，194647552字节；VM及guest载荷相对基底保持，未安装到Store。新resumed-file-acceptance-plan.json（SHA-256 ba1279954c64ab30712e0e92eb4428c2b222f91d0cf9e621a39ad358f6d7fd95）冻结342项输入，仅拟在同一新副本和新generation上执行一次on/off/on，原12项和新10项完整摘要/身份先复核，每阶段严格独立只读审计；root重新读取实际desired和manifest，正式CLI重新验证完整generation/磁盘身份。允许正式CFW正常清理该新副本的.cfw_temp（含此前失败生成的可重建源缓存）及新暂存，保留原VM、旧盘、generation、失败journal和证据。新候选及失败后的再次执行尚未获准，未重试；不启动VM或窗口，不重建generation、不安装或重绑。受信Guest来源和运行效果仍未通过，accepted=false。
