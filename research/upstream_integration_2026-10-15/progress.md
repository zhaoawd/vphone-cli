# 8a75092 范围核验与本地对账（2026-10-15）

2026-10-19 当前状态：f1739ebc已push。重装事务20261019T090232Z-27r0QIUW已发布且未启动；新验收发现已有Cryptex被跳过、SwapEnd幂等，缺新原件复制链，撤销候选正确拒绝，未执行Undo。已新增显式regular/classic --reinstall-cryptex，保持默认跳过与全部证据门。真实安装脚本隔离回归从失败转为通过；相关Python33项、全量942项（跳过2项）254.634秒、Swift参数/传递12函数及实际release verifier3函数（5写入设置、8身份变化）通过。新host应用签名、依赖、资源和entitlement通过，原boot程序字节/inode/CDHash保持。显式原件重装已发起（CLI20039/session28495），新发布核验、未启动Undo、撤销后启停及显式重新应用仍待验收，T32/T33未accepted。

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
