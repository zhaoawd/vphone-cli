# 上游合入进度与空间清理核对（2026-10-23）

核对时间：2026-10-23 17:44 CST。本轮只读取 Git、任务记录、归档清单、目录占用及进程，未删除文件、停止进程或修改既有任务状态。本文件是本轮新增的核对报告。

## 结果

- 整体合入尚未完成。实施基线为 `8a75092`，新审阅目标为 `2a0d3ac`；不能将旧目标的 9 项 accepted 当成新目标通过比例。
- 已完成工作的构建产物仍有清理空间。主仓库 `.build/out` 与 T51 独立 Swift 构建目录合计约 4.17 GiB；旧工作树另有约 4.06 GiB 构建产物，须分别核对用途。
- 本轮没有确认一组可以立即清理、且能独占释放数十 GiB 的已完成过程文件。最大的目录属于运行 VM、正在执行的验收或来源/撤销历史。
- 目录大小为 `du -k` 的已分配量统计，包含 APFS 克隆共享块；不是实际可释放量。当前卷 `df -h .` 约 55 GiB 可用，验收仍在写盘，数值会变化。

## 合入进度

| 对象 | 已完成范围 | 尚未完成范围与状态 |
| --- | --- | --- |
| U0 / T00–T02 | 新范围 `8a75092..2a0d3ac` Git 核验与 57 条提交首轮路由，215 个端点路径 | 完整语义审阅未完成；66 项总台账不是 66 项已实施 |
| T08 | IcliKit 0.8.6 固定依赖、classic/v2 独立构建、签名及相关回归；10 月 21 日 Python 949 项及 NIO 补验通过 | 该候选的完整 guest 服务、应用、截图内存验收未完成；旧目标 accepted 保留其原适用范围 |
| T47/T48 | 身份克隆、快照、恢复事务与 CLI 实现；89 项隔离回归通过 | 真实大盘快照恢复后启动、新身份副本并行启动未验收 |
| T51 | rebase、物理共享计量与恢复实现；真实 64 GiB 副本、两次启停、界面计量通过；已提交 `4b5117d6` | 外置卷暂缓，模板基准及完整故障矩阵未验收；整项 accepted=false |
| T52 | 绑定、环境更新、默认 GUI 正常关机及 APIProxy 停止竞争修复；最终 provider 候选的正式探针定位与 QR 消费通过 | 外置物理卷暂缓，业务应用范围未覆盖；整项 accepted=false。当前 t52-v2 仍运行 |
| T60 | 选定 GUI/CLI 取消与退出矩阵、两归档后端真实旧 VM 往返及完整摘要比较完成，可提交评审 | 未代替人审；导入后启动、真实 restore 阶段 AppKit 退出、全部历史组合未覆盖 |
| T32/T33 | DSC 撤销/重应用和若干真实启停已通过；文件级 Undo 实现及回归完成；新三项 Mach-O 的 on 与 off 独立审计通过 | 本轮 reapplied 进程仍运行，尚无 reapplied.json 终态；受信 guest 来源与 GUI/补丁运行效果未完成；accepted=false |
| T53 | 固定源码审计、隔离 SystemHook/DeviceHub 候选及相关回归 | 尚未接入产品、部署或完成实际开发工具验收 |

依据：`research/upstream_integration_2026-10-15/progress.md`、`tasks.json` 及各任务专题报告。台账部分顶层状态仍保留历史语义；本表按后续 dated 记录和当前进程补充，不自动改写台账。

当前分支为 `codex/upstream-2d21d21-integration`，HEAD `80502e7a` 与本地 origin 跟踪引用相同；主工作区有大量未提交修改与未跟踪文件。`git ls-remote upstream refs/heads/main` 因 SSH 连接关闭失败，未确认今天上游 main 的最新 SHA；本报告按仓库已固定目标核对。

## 已完成但仍保留的过程文件

| 对象 | 本轮占用 | 建议与条件 |
| --- | ---: | --- |
| `.build/out` | 2.41 GiB | 可重建的构建输出，优先清理候选。当前运行 VM 的可执行文件位于独立 `.app` 或系统 Bundle Store；执行前仍须确认没有新的构建使用者 |
| `.build/t51-commit-scope/swift-build` | 1.76 GiB | T51 提交范围独立验证已完成，日志已归档；优先清理候选 |
| `.build/t51-commit-scope/tree` | 0.43 GiB | 已完成验证的索引导出树；可作为第二批候选。先保全额外复制的生成文件 `VPhoneBuildInfo.swift` 和复建信息；不必删除同级日志、versions、worktree-before.json |
| `.build/daemon-api-icli086-20261021` | 0.70 GiB | 候选构建完成；只优先清理其中 `Xcode/Build`，约 0.19 GiB。保留候选、清单及测试使用的固定 SourcePackages，直至完成后续用途核对 |
| `.build/t52-consumer-fix-20261022` | 1.47 GiB | 旧 consumer 候选已被最终 provider 修复替代；包含约 0.20 GiB `Xcode/Build` 和约 0.20 GiB SDK/module 缓存。可先清理编译中间文件；旧候选、失败证据及签名归档逐项核对后再处理 |
| `.build/t52-real-20261021` | 1.45 GiB | 首次绑定和后续 GUI 关机步骤已完成；仍有旧 package、retained-toolchains、候选 tar。可精简重复产品，保留具名回滚候选与归档证据，不按整个目录清空 |
| `.build/t52-camera-interface-20261022`、`.build/t52-camera-diagnostics-20261022` | 0.41 / 0.35 GiB | 相机诊断后的最终消费已通过；可精简旧候选和诊断二进制。consumer-frames、保存的诊断证据及回归源码仍须按引用保留 |
| `/Users/kolar/.codex/worktrees/t08-roothide/vphone-cli/.build` | 4.06 GiB | 旧工作树构建产物，其中 out 为 2.19 GiB；单列为待核对候选。该工作树 status 有 3176 项 staged deletion、194 项 staged modification，不能仅凭旧任务完成就整体删除工作树；这不证明上述修改均为独立新增工作 |

第一批仅取 `.build/out` 与 T51 `swift-build`，目录统计合计约 4.17 GiB。加上旧工作树全部构建产物，目录统计约 8.23 GiB；后者不是已确认可全部删除的清单。APFS 共享块与快照保留可能降低实际释放量，不能承诺释放上述总量。

## 大目录的保留原因

| 对象 | 本轮占用 | 原因 |
| --- | ---: | --- |
| `vm-t32-t33-dsc-20261018` | 146.80 GiB | T32/T33 原验收对象；其中 `.cfw-history` 101.48 GiB，包含实际撤销/重应用证明和来源关联。不能视为普通缓存 |
| `.build/t32-t33-completion-20261023` | 108.00 GiB | 新验收对象、备份、冻结候选和 on/off/on 事务；reapplied 正在运行，package-r6 是当前执行来源 |
| `.build/t51rt/lib/t52-v2` | 105.59 GiB | 当前运行的正式验收 VM；`.cfw-history` 36.18 GiB，最新环境回滚盘约 19.22 GiB，均不能因位于 .build 就删除 |
| `vm-t32-t33-20261018-r2` | 52.79 GiB | 独立 26.1 创建/恢复及启停样本，后续整项仍未完成；是否退役需单独决定 |
| `.build/t32-t33-completion-20261023/pre-acceptance-backup` | 14.00 GiB | 原 VM 的具名保留备份，已计入上级目录，不重复相加 |
| `.build/t32-t33-followup-20261023/pre-runtime-backup` | 13.70 GiB | T32/T33 运行观察前备份；后续运行与效果仍未完成 |
| `vm-roothide-b33-20261010` | 33.94 GiB | 历史 T08 RootHide 验收已完成；后来又用于 T32/T33 只读资格检查。可作为“退役历史测试 VM”的讨论对象，但其独有状态、当前句柄及后续用途尚未完整核验，本轮不列为可直接清理 |
| `vm-new` / `vm-2607` | 34.36 / 36.88 GiB | 前者仍有健康监测进程，且是历史验收源；后者 VM PID33355 正在运行。不能按已完成过程副本处理 |

重复的 AEA、固件 generation、firmware-history 以及 CFW 的 Disk.img/guest-postimage.img 有内容或身份校验用途。看起来重复不能证明可删。已存在实际案例：两个旧 v4 历史目录缺少盘、postimage 与 effect-blobs，正式身份预检因此拒绝；缺失时间和原因未查明。

## 已清理对象与旧记录差异

- 10 月 23 日的五个实验副本和三个旧环境历史磁盘已经删除。对应清理记录在 `research/cleanup_2026-10-23.md`；当时可用空间即时增加约 614 MiB，不是各目录 du 之和。最新环境回滚盘仍保留。
- T60 报告最后曾记录保留 native 导入副本和约 14.50 GiB 归档。本轮 `real-vm-r3/import-native` 与 `archives` 均为空，整个 `.build/t60-remaining-20261021` 仅约 39 MiB。它们不能再作为大空间清理候选；本轮未查明后续移除的具体记录。
- T51 的 base、target、t52-environment 等副本已经在今天的清理中删除，不重复列入收益。

## 验证与限制

本轮命令：`git status`、`git log`、`git worktree list --porcelain`、`du -k -d 1/2`、文件 stat、大文件枚举、`df -h .` 和只读进程检查。未运行产品测试或重新验收 VM。

已逐文件核验归档清单的大小及 SHA-256：T51 提交范围 3 项、T08 0.8.6 适配 18 项、T60 最终记录 8 项、T52 provider runtime 97 项，均相符。该核对证明这些归档文件当前完整，不代表所有原始二进制或磁盘均已归档，也不授予删除权限。

进程检查确认：T32/T33 原生执行器 PID50959、reapplied CLI PID6999 及其 CFW shell 在运行；vm-2607 PID33355、t52-v2 PID61974 在运行。历史 runtime.json 的 PID 不能单独证明进程当前存在。

尚未执行待清理目标的排他锁、逐目标 lsof、挂载检查、全部反向引用核对，也未独立测量候选的 APFS 独占 extent。实际清理前应按具体目标完成上述核对、保全小型唯一输入和证据，并取得删除范围的明确授权。当前正在运行的验收输入不得纳入清理。
