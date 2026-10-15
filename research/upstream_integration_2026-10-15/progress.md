# 8a75092 范围核验与本地对账（2026-10-15）

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
