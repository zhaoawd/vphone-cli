# T32/T33 当前执行清单

2026-10-19 当前状态：b00e1d3c 已提交并 push。独立 DSC 第二次 CFW 在 .34.dyldreadonly 枚举处拒绝，原磁盘身份/mtime 与 66 段采样保持，未交换。完整只读清单确认 80 个成员及 10 个伴随输入。精确输入保持修复、实际隔离副本补丁与 6885 代码页验证通过；完整 Python 931 项（跳过 2 项）、相关 Swift 12 个测试函数及实际 release verifier 通过。签名资源/依赖/entitlement 核验通过，VM 字节及获批 CDHash 保持。第三次安装 session69696 等待原生管理员验证 PID39449；放行进程恢复等待 PID22867。真实发布、撤销与正常启动仍未验收，T32/T33 未 accepted。

固定上游目标：`8a75092013eda87a4e30ed029b72028cb9279ac4`。
起点：`2df4be8c`。保留已有 Capstone overlay；以下为 2026-10-15 的初始隔离验证范围，后续真实 VM 授权与结果按日期记录。

- [x] 核对新台账、现有 Receipt/Undo、guest 写入链与上游同 ID 迁移实现。
- [x] 建立撤销当前字节、保留补丁及首次原件的失败回归。
- [x] 实现同 ID 实现形状判定与整组撤销/重打预检，不以 ID 或形状授予应用状态。
- [x] 从现有已提交生成固件 Receipt/report 恢复撤销证据，核对 generation 和原事务。
- [x] 新增 `fw receipts` 检查与撤销预览入口，记录缺失保持 unknown、损坏拒绝和 generation 约束。
- [x] 最终相关 Swift 72 项及 APIProxy 1 项通过；标准 Swift Testing 1527 项保留既有内核幂等 issue，APIProxy 标准运行失败后单独复验通过。
- [x] 标准入口后续限时组 9 项、tar/文件摘要内存与 guest 组件检查通过。
- [x] 更新 T32/T33 研究记录和台账，保留未完成范围和历史接受状态。
- [ ] guest DSC/Mach-O/Preboot 撤销、代码页重新证明及磁盘/Receipt/Undo/来源的同 journal 发布。
- [ ] 真实 guest on→off→on、旧 VM 缺 Undo 和中断恢复验收。

已确认限制：现有通用 Undo 仅为内存处理；guest 的普通 CFW 磁盘交换尚未接入 Swift 分组件 Receipt 的同 journal 来源发布。不能把生成固件证据提升为已安装 guest 证据，也不能自动信任旧 `.bak` 或导入 Receipt。

## 当前下一项：guest 发布检查点

- [x] 保存缺最终证据仍能交换磁盘的失败回归。
- [x] 在快照修改后重新只读核验，封存原计划、操作记录、效果报告和 blob 索引，与最终磁盘摘要绑定。
- [x] 将检查点要求写入磁盘 journal；交换与中断恢复均核对，证据不一致时保留数据并拒绝确认。
- [x] 增加历史读取与错误/中断回归，执行 Python 相关与全量测试。
- [x] 更新研究记录与台账，保留实际 guest 撤销和来源发布的未完成状态。

## 2026-10-15 拉取与本地修改合并

- [x] 保存原工作区至 Git stash，保留 Capstone overlay。
- [x] `git pull --ff-only` 更新至 `fcd19e78`，恢复本地修改。
- [x] 合并来源核验、快照后只读核验及研究记录冲突。
- [x] 验证合并后的 Python、Swift 相关行为，核对工作区与备份：Python 全量 857 项（跳过 2 项）退出 0，Swift 相关 27 项通过，无未解决冲突；stash 保留。

## 当前下一项：已提交 guest DSC 撤销候选

- [x] 从已提交 v3 journal 核对当前磁盘、generation、保存计划及来源索引，不依赖当前 desired 仍等于旧计划。
- [x] 增加按 declaration 反向撤销操作链后缀的只读候选，核验完整 DSC 代码页；保留后续操作或缺可信原件时拒绝。
- [x] 接入持锁的 `cfw_disk_txn.py preview-undo`，补充真实 producer → final reader → journal → preview 回归。
- [x] 执行相关与全量 Python 测试，更新研究记录、范围和未完成项：相关 65 项；全量 869 项（跳过 2 项）无失败，退出 0；证据见 `evidence/T32-T33-guest-undo/manifest.json`。

本阶段输出撤销候选摘要及验证结果；尚不执行 guest 写入、任意中间操作重打、Preboot/Mach-O 恢复或生产 IOMFB 迁移。后续实际写入仍需新事务中的安装目标映射、最终只读核验及共同发布。

下一项：在新的 staged guest 事务中映射并应用这些候选，接入实际操作证据和快照后最终核验，再共同发布分组件 Receipt/Undo/来源；任意中间补丁重打、Mach-O/Preboot 和真实 VM 验收仍未完成。

## 当前执行：DSC 撤销写入与发布

- [x] 在新 staged 磁盘内应用已核验后缀候选，完整预检目标和文件元数据；保留父事务及未撤销效果。
- [x] 同 journal 封存撤销请求、实际写入、最终分组件效果 Receipt 和 guest 来源 unknown 转换。
- [x] 接入 host 驱动、磁盘交换、来源元数据发布及中断恢复；来源读取拒绝 pending CFW 状态。
- [x] 回归覆盖完整事务、分次撤销、父证据变化、写入/最终核验失败、交换后恢复和来源竞争。
- [x] 执行 Python/Swift 相关与全量验证，记录未覆盖的真实 VM/固件范围：Python 886 项（跳过 2 项）；Swift XCTest 325 项（跳过 7 项）、常规 Swift Testing 1529 项、限时组 26 项及后续检查通过。

约束：不提升历史快照为当前 Core Bundle 来源；实际 guest 来源置 unknown。保留 IOMFB 新实现生产门控。真实 VM 验收仍需具名目标，当前仅操作测试夹具。

身份交接补充：已保存真实 Swift verifier 在 Disk.img inode 交换后拒绝 generation 的失败，接入已提交 v3 journal 的完整磁盘/证据/保留原磁盘连续性核验。实际 Swift CLI 验证器的连续两次安装及一次 DSC 撤销回归通过，四类篡改或身份变化均拒绝。

完整 Swift 首轮失败已记录：export staging 用例更新为先验证 pending 拒绝、再执行全部原排除断言；ArchiveKit 权限比较未修改源码或断言，定向及最终全量通过，首次失败原因未查明。保持所有生产拒绝条件。

证据：`research/upstream_integration_2026-10-15/evidence/T32-T33-guest-undo-publication/manifest.json`。后续具名 VM 验收见下节；Mach-O/Preboot、任意中间操作重打和受信 guest 来源推进仍待实施，T32/T33 未登记为 accepted。

## 2026-10-16：vm-new 真实验收

用户指定 `vm-new` 用于撤销写入和启动验证，路径 `/Users/kolar/github/vphone-cli/vm-new`。已核对无磁盘占用或 hdiutil 附件；64 GiB 磁盘、现有系统为 iOS/cloudOS 26.1 23B85，缺 generation 和 CFW journal。

- [x] 确认具名测试对象、目录状态、磁盘占用和证据前置条件。
- [x] 使用实际 CLI 验证旧 VM 缺证据返回 unknown、撤销拒绝及磁盘保持；完整磁盘与受保护文件前后摘要一致。
- [x] 构建并校验当前完整签名应用；vm-new 两次连接现有 vphoned，读回 iOS 26.1/23B85，启动时间不同，两次正常关机并释放磁盘；配置与已有 daemon 摘要保持。
- [x] 记录正向撤销所缺前提、真实结果及源码/日志摘要，见 `T32_T33_vm_new_acceptance.md` 和对应 manifest。
- [x] 用户选择改用已有完整 journal 的 VM，不重新安装 vm-new。
- [x] 只读核对已知 library、备份和注册工作树：7 台 VM；4 份可读发布日志均为 v1，另 1 份 root 历史不可读；尚未找到有 generation、desired plan 和 v3 checkpoint 的候选。
- [x] 用户指定 `vm-roothide-b33-20261010`。
- [x] 管理员只读核对完成：三个 journal 均为 v1；1 published、2 failed 且保留副本。当前磁盘 inode 匹配 published.staged，但 mtime 不同；缺 generation、desired plan 和 guest checkpoint，不能用于正向 DSC 撤销。
- [x] 已确认旧 VM 不满足正向验收前提；用户后续授权新建独立 VM，原失败副本保持。

不从安装目录或 `.bak` 补造可信原件；缺证据时不执行正向撤销。

## 2026-10-18：新建独立验收 VM

用户提出新建 VM，沿用 T32/T33 撤销与真实运行验收目标。新对象 `vm-t32-t33-20261018`；regular/classic、64 GiB，独立原始 iOS/cloudOS 26.1 23B85，本地 IPSW 只读输入，缓存和运行状态写在仓库内。原两台 VM 保持。

- [x] 核对原始 IPSW BuildManifest、当前源码和签名应用、可用空间 223 GiB、regular DSC 声明。
- [x] 通过当前 `vm create` 建立新身份、generation 和冻结计划。
- [x] 修复实际固件暴露的 iBEC bootx 版本条件矛盾；失败 journal/report/checkpoint 已保存，正式恢复入口已归档，校验未绕过。
- [x] 定向回归、兼容性 Python 14 项、catalog Python 9 项和生成器检查通过。完整 Swift 常规 1534 项通过；APIProxy XCTest 在完整运行仍失败、单独 1 项通过，原因未查明。完整签名构建及资源/entitlement 校验通过。
- [x] 修复构建的新实例 `vm-t32-t33-20261018-r2` 准备和固件补丁均成功；7 个组件、58 条记录通过声明校验并提交。首个实例的旧 catalog 计划和证据保留。
- [x] 真实系统恢复成功：SHSH 与 restore update 均退出 0，DFU 子进程按流程停止。
- [x] 首次 CFW 管理员验证完成；安装在 readonly Cryptex 基线检查失败。v3 失败事务已归档，原 Disk.img 的 dev/inode/size/mtime 与 66 段采样摘要一致。
- [x] 核对实际 WritableVolume:false，严格兼容两种 volume 字段；相关 87 项和完整 Python 892 项（跳过 2 项）通过，签名重建完成；CFW 重试等待原生管理员验证，Mac 当前锁屏。
- [ ] 完成 CFW 与后续验收；patch/restore 已完成，先前 AMFI 信号 9 已按获批 CDHash 验证放行。
- [ ] 核对真实 v3 发布、DSC 来源/代码页并执行撤销验收；修复实际边界失败。
- [ ] 完成新 VM 启动/停止与效果验证，记录范围、未覆盖项及原 VM 保持检查。

- [x] 用户明确批准后按指定 CDHash 启动既有 amfidont；冻结 VM 程序 `--help` 退出 0，宿主放行已生效。SIP/启动参数未修改。

- [x] 更正 DSC 验收组合并建立独立 vm-t32-t33-dsc-20261018：26.0 23A341 原始归档核验、native prepare、generation 与固件事务提交均完成；只读 SwapEnd 源诊断和 6885 代码页通过。
- [x] 独立 DSC VM 真实恢复完成：SHSH 与 restore 退出 0，DFU 退出 0，磁盘及目录锁释放；尚未安装 CFW 或正常启动。
- [ ] 用户解锁 Mac 并完成现有 r2 CFW 原生管理员验证后，核对实际发布/启动边界，再完成独立 DSC VM 的 CFW、撤销与正常启动验收。


## 2026-10-18：只读 Cryptex 硬链接读取修复

- [x] 用户完成管理员验证；第二次 CFW 失败于 snapshot，v3 归档保留，原磁盘元数据及 66 段采样保持。
- [x] 实际 readonly CodeResources（2467 字节，38 个硬链接）复现同一错误；前后属性与 inode 保持，单链接副本通过。
- [x] 正式 producer 回归先失败后通过；仅已绑定 Cryptex 来源显式启用 readonly 硬链接读取，内核 fstatvfs 前后核对；普通写入目标、镜像与 blob 单链接限制保持。
- [x] 实际源 2933 条目/2093 文件、相关 146 项、最终硬链接 8 项及完整 Python 900 项（跳过 2 项）通过；完整签名构建与冻结资源核对通过。
- [x] 按既有批准的同 CDHash 重启已安装 amfidont，进程不加载或修改持久允许列表；新冻结 VM 执行退出 0。
- [x] 第三次 CFW 在首次最终挂载核验处失败；551 条操作与失败 journal 已保存，未交换原磁盘。


## 2026-10-19：最终 APFS 挂载核验

- [x] 实际 APFS 克隆复现清单缺 MountPoint 导致的拒绝；保存原生 plist 与失败回归。
- [x] 改用卷和路径实际查询，保留设备、挂载路径及读写状态拒绝条件；相关 58 项通过。
- [x] 独立原生可写→只读重新挂载通过，正常卸载；完整签名构建通过。
- [x] 完整 Python 906 项（跳过 2 项）通过；定向 23 项通过，签名资源与当前源码摘要一致。
- [x] 用户完成管理员验证；同 CDHash 重启后 VM --help 退出 0。
- [x] 第四次 CFW 通过实际最终挂载检查；首次效果核验误拒绝签名前临时复制 GID，未发布，失败证据及 551 行操作已保存。
- [ ] 真实 v3 发布与正常启动边界、独立 DSC VM 的 CFW/撤销及正常启动验收。


## 2026-10-19：签名前复制属性核验

- [x] 三个真实程序的保存字节与签名链复现相同错误，定位 copy 创建属性被误当成显式修改。
- [x] 新增复制→补丁→签名→复制回归先失败后通过，保留显式 chmod 和未记录属性变化的拒绝。
- [x] 真实保存的三个签名链及全部 25 份非纯复制操作链重放通过；完整签名构建通过。
- [x] 完整 Python 908 项（跳过 2 项）退出 0；四个打包脚本摘要一致，旧 VM 指定文件复查保持。
- [x] 用户完成辅助进程原生验证，当前及新冻结 VM --help 均退出 0，四个冻结脚本摘要一致。
- [x] 用户完成第五次安装命令的原生管理员验证。
- [ ] 第五次 CFW 正在独立 staged 事务 .cfw_disk.H0YWJ2mL 执行（session 9529，attempt e8bb6bfd-c484-4121-a636-004d435f755b，root PID64816）。
- [ ] 实际发布、启动后 journal 读取，以及独立 DSC 实例的 CFW/撤销和正常启动验收。

- [x] 独立 APFS 克隆完成正式快照名称修改及之后的只读设备/路径核验，正常卸载；源身份元数据保持，未构成发布或启动验收。

- [x] 第五次首次完整效果核验通过；快照处理完成，当前第二次整盘只读效果核验正在执行。

## 2026-10-19：实际发布和运行后证据

- [x] 第五次两个最终只读效果核验、快照修改、封存、交换及归档通过：`20261019T013451Z-H0YWJ2mL`。
- [x] 正式 create 退出 0，首次及验证提示符启动通过。
- [x] 当前 classic API 的两次正常启动/关机通过；会话 UUID 与启动时间不同，磁盘及目录锁释放，配置/daemon 摘要保持。
- [x] 保存旧工具 shell 能力不匹配、沙箱 AppKit 初始化中止的失败；新增显式 API 验收选项，原关机断言保持。
- [x] 实际运行后 v3 读取失败；只读核对检查点、5 文件、297 blob、配置及 generation 均保持，整盘 SHA/mtime 已变化。
- [x] 新增运行写入失败回归；v4 实现进行中。
- [ ] 完成 v4 Python/Swift 回归、签名构建及独立 DSC 实例的安装/撤销/启动验收。

- [x] v4 独立发布后镜像、历史读取及当前 Undo 克隆摘要绑定已实现；相关 57 项通过。
- [x] 实际 Swift verifier 与签名 release CLI 的相关 12 个测试函数通过，含 8 类身份/篡改参数。
- [x] 首轮全量 918 项有 4 个夹具版本差异，四项保留断言的定向复验通过；全量重跑进行中。
- [x] 最终签名应用构建完成，六个脚本摘要匹配；最终 VM CDHash 已固定为 `89b70a253cad2adea133b3e875519afaf72c5d17`。
- [ ] 等待最终 CDHash 放行补充批准；先前 a7d61a0b5d3b2c495daba261154b9e8ebb1cd849 申请早于最终重建完成，未执行该放行。

- [x] 最终完整 Python 919 项（跳过 2 项）、234.848 秒，退出 0；新增读取稳定性检查包含在本轮中。
- [x] 固定签名应用保留至 `.build/t32-v4-final-89b70a25.app`，VM 文件摘要与最终 preflight 一致。
- [ ] DSC CFW 安装等待原生管理员验证：session56984，CLI17265，osascript17723；尚无 journal。

## 2026-10-19：DSC .dylddata 输入与提交

- [x] 保存首次 DSC 失败事务及完整只读来源诊断；3 个伴随文件来自绑定原始 Cryptex，包含执行映射。
- [x] 保持写入目标映射，新增输入前后完整摘要、身份、属性及成员集合检查；变更、替换和符号链接拒绝回归通过。
- [x] 完整 Python 922 项（跳过 2 项），237.452 秒，退出 0；新 release verifier 的 Swift 相关 12 个测试函数通过。
- [x] 已构建签名应用副本更新 Python 资源并重新封签；VM 二进制与获批 CDHash 保持。
- [x] 用户明确要求完成后提交并 push；已 fetch，当前 HEAD 与 origin 分支无差异。
- [x] DSC 安装重试的原生验证完成：CLI10804、osascript11566、session82810；root 安装已开始。
- [x] 代码和已有证据提交 b00e1d3c，并正常 push 至原分支；Capstone overlay 与 stash 保留。
- [ ] 正式发布、DSC 撤销与新实例正常启动验收。

## 2026-10-19：DSC 完整伴随输入清单

- [x] 保存第二次安装拒绝及事务 20261019T055918Z-bAM1VrQr；原磁盘采样检查保持，未交换。
- [x] 最小 producer 回归复现 .dyldreadonly 拒绝；核对绑定只读来源的完整 80 成员及 10 个额外后缀输入。
- [x] 新增精确 dyldreadonly/dyldlinkedit/atlas 输入保持规则及正向、五类变更拒绝、符号链接拒绝回归。
- [x] 实际隔离副本 SwapEnd 补丁仅修改 .42，全部伴随文件保持，6885 代码页通过。
- [x] Swift 12 个测试函数及实际签名 verifier 通过，含全部伴随输入；资源/依赖/签名/entitlement 核验通过，获批 VM 保持。
- [x] 完整 Python 931 项（跳过 2 项）通过，242.969 秒，退出 0。
- [ ] 第三次 CFW 安装等待原生验证 PID39449/session69696；放行进程恢复等待 PID22867。
- [ ] 真实发布、正向撤销及正常启动验收。
