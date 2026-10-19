# T32/T33 当前执行清单

2026-10-19 当前状态：6de04f15已push。显式Cryptex重装已获系统验证，root25634/session28495在staged .cfw_disk.vZh3Hh4C执行SystemOS缓存入口，未发布；已确认不走已有Cryptex跳过分支。新增已有补丁Cryptex整树替换→新发布→原件Undo组合回归通过，相关28项10.297秒退出0；生产代码未再修改，先前全量942项（跳过2项）结果保持，其后新增1项组合测试，未声称新全量943项已跑。顺序脚本session39110负责新发布证明及未启动Undo，session22627负责撤销后证明/API启停/读取、显式重新应用及重复验证，失败即停止。实际撤销发布和on→off→on尚待验收，T32/T33未accepted。

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
- [x] 用户完成第三次安装的原生验证；root PID55255、session69696 已执行 staged 事务。
- [x] 放行恢复 PID22867 已返回；worker57100 报附加失败并退出，VM 参数探测137。
- [ ] 当前 amfid57825 上的同范围重试 PID58131/session27265 等待原生验证。
- [x] 第三次 CFW 已通过 DSC 枚举与 SwapEnd producer，正在处理后续组件；尚未最终核验或发布。
- [ ] 真实发布、正向撤销及正常启动验收。

## 2026-10-19：第三次安装与真实验收续跑

- [x] 原生安装验证已生效；第三次 staged 事务 `.cfw_disk.XzJThk9M` 已完成文件安装，root PID55255/session69696 正在首次 `verify-final`。
- [x] 原 helper worker57100 附加失败并退出；之后观察到 amfid57825 出现及再次退出，原 LLDB 错误细节缺失，原因未完全确认。
- [ ] 同一获批 CDHash 的重试 osascript58131/session27265 等待原生验证。
- [ ] 受限参数探测 session72154 正在执行：每20秒只进入非法参数路径，SHA/CDHash核对，不启动VM；一小时上限或建立 `.build/t32-dyldreadonly-debug/stop-execution-probe` 后停止。当前 amfid62017 已持续运行。
- [ ] 两次最终只读核验、封存和正式发布；未启动磁盘中的实际 DSC 原件/补丁/完整代码页证明。
- [ ] 首次启动、两次API正常启动/停止及运行后历史证据读取。
- [ ] 实际DSC撤销、未启动磁盘原件/代码页证明、撤销后两次API正常启动/停止。
- [ ] 同一generation重新安装CFW并验证补丁/代码页与正常启动，完成DSC效果on→off→on；不提前登记T32/T33 accepted。

- [x] 第三次 CFW 两次最终核验、封存、交换及归档通过，session69696 退出0；v4事务 `20261019T065441Z-XzJThk9M`。
- [x] 放行重试 PID58131 完成；worker68388 附加 amfid62017，参数探测连续64；仅获批 CDHash。
- [ ] 首次启动前 DSC 证明 session52797 正在执行，输出 `.build/t32-dsc-v4-installed`。

- [x] 首次启动前DSC证明通过：发布与当前整盘SHA一致，.42原件e41db9aa...与来源诊断一致，补丁件2fc23949...，w3 0x548→0x560，原件/补丁件各6885代码页通过。
- [ ] 正式首次启动脚本正在执行，输出`.build/t32-dsc-v4-first-boot`。

- [x] 第三次CFW后首次启动通过：生产7条命令、提示符匹配、退出0、Guest stopped，无框架强制停止，磁盘/目录锁释放，配置与daemon摘要保持。
- [ ] 安装后两次API正常启动/停止正在执行，输出`.build/t32-dsc-v4-api-installed`。

- [x] 安装后两次API正常启动/停止通过；iOS26.0/23A341，启动时间/会话UUID不同，apiAccepted、Guest stopped，无强制框架停止，配置/daemon保持，磁盘和目录锁释放。
- [ ] 真实启动后的Receipt与generation verifier正在执行，输出`.build/t32-dsc-v4-postboot-installed`。

- [x] 安装后真实两次启动的Receipt/verify-plan通过，runtimeImageChanged:true、runtimeValidated:false，发布镜像SHA ff453e...与当前SHA 5948a0...分开。
- [ ] 已发起独立DSC实际Undo命令，日志`.build/t32-dyldreadonly-debug/undo.log`；同一generation，仅dyld-boot-iomfb_swapend，原生验证结果待核对。

- [x] 用户完成实际Undo原生验证，root73597/session58124已执行；固定generation，仅dyld-boot-iomfb_swapend。
- [x] 发布与真实启动证据归档至dsc-publication-20261019；原VM保持范围沿用已有记录，未新增旧VM写入。

- [x] 发布/启动证据提交并push为aef7f99c，远端与本地一致。
- [x] 周期参数探测session72154已通过stop文件停止，92次记录，最后返回64；其间helper68388再次记录目标退出后结束，同一VM程序仍可进入参数解析，无需重复放行。
- [x] 实际Undo prepare-undo通过；staged目录`.cfw_disk.8MSU4jQD`，root73597/session58124正在apply-undo（PID79623）。

## 2026-10-19：Undo可写APFS分配统计

- [x] 首次Undo失败事务已保留，.42在staged写回e41db9aa...并完成写回/代码页检查，随后挂载复核拒绝；原盘未交换，身份和66样本保持。
- [x] 最小事务回归red.log在2.496秒复现写入后同一错误。
- [x] 全新128MiB隔离APFS写8MiB：仅CapacityFree及卷CapacityInUse改变，root身份、实际设备/路径/可写状态保持；正常卸载。
- [x] 可写Undo比较仅排除两个实际分配统计字段；保留其他完整容器字段及实际root/设备/路径核验；最终只读比较未改。
- [x] 相关26项加只读严格性1项通过；实际新签名hostCLI的Swift12函数通过；新资源/依赖/签名/entitlement通过，原boot程序inode及字节保持。
- [ ] 完整Python回归session95763，日志.build/t32-undo-mount-debug/python-full.log。
- [ ] 使用新host应用重试同generation、同声明Undo；使用原已放行VM路径启动。

- [x] 完整Python935项、跳过2项，244.185秒，退出0；日志python-full.log。
- [ ] 修复后Undo重试已发起，新host应用.build/t32-undo-mount-final.app，日志.build/t32-undo-mount-debug/undo-retry.log；原生验证待核对。

- [ ] 修复后Undo重试session99319/CLI97676/osascript98151正等待原生管理员验证，尚无新事务。

- [x] 撤销重试的原生管理员验证完成（osascript 98151）；root 安装进程 2004 已开始，当前核验 generation、保存计划及父事务证据。
- [ ] 完成修复后的撤销发布、原件及 6885 代码页核验、撤销后 API 启停与运行后读取；随后完成同 generation 重新应用及启停验证。

- [x] 修复后重试 prepare-undo 完成，staged `.cfw_disk.JTYX6fft`；root2004/session99319 已进入 apply-undo。远端与本地 aeb1651e 一致。

- [x] 修复后真实 apply-undo 完成，已进入首次 verify-final；原失败处的写入后可写挂载复核通过，尚未发布。


## 2026-10-19：保留文件漂移拒绝

- [x] 修复后的 apply-undo、实际写回和可写挂载复核通过；首次最终核验拒绝，事务 20261019T081934Z-JTYX6fft 未发布，原盘身份/mtime 与 66 样本保持。
- [x] 无需额外管理员对话框的只读挂载核对 4686 输出；AA.gl 内容摘要不同，其他内容/类型/链接/权限位一致；属主视图不可靠，不据此报告属主变化。正常卸载、磁盘身份保持。
- [x] 保存 copy-only hardware 内容和权限漂移拒绝回归，0.021 秒通过；未修改生产拒绝条件。
- [ ] 同一独立 VM 的 CFW 重装 session55770/CLI13075 已开始预检；发布后先执行 Undo，保持启动前边界，再验证撤销后启停与同 generation 重新应用。

- [x] 续跑核对：原生验证已生效，重装 root19942/session55770 正在 staged `.cfw_disk.27r0QIUW` 安装；无需重复验证或启动第二份安装。
- [ ] 重装发布后保存新的 installed 证明到 `.build/t32-dsc-v4-rebaseline`；后续 restored 证明必须引用此新事务，不能引用首次安装事务。新发布核验及 Undo 前不启动 VM。

- [x] 保存有上限的续跑脚本 `.build/t32-rebaseline-debug/after-install.py`（session99202）：等待 CLI13075 结束并要求完整发布成功日志，持锁保存新 installed 证明，再自动发起同 generation/声明的未启动 Undo；任一步失败即停止。当前等待安装，无 VM 启动。


## 2026-10-19：已有Cryptex的重新安装与撤销来源

- [x] 重装事务20261019T090232Z-27r0QIUW退出0、两次最终核验/交换/归档通过；新发布整盘SHA fcae888a5b9759efab692c4adbad80226dc33c779e876aaed28733059ea0d676，未启动。
- [x] 新 installed 证明正确拒绝：Cryptex已存在而跳过复制，SwapEnd已0x560，未建立新的只读来源/可逆操作链；顺序脚本session99202停止，未执行Undo。
- [x] 新增实际regular安装脚本的隔离失败回归，并实现显式regular/classic --reinstall-cryptex；从绑定原始固件重走既有复制及补丁链，默认跳过行为保持。未知设置、其他variant/profile/mode拒绝，sudo重执行与root-popup参数传递保持。
- [x] Swift相关12项通过；单独host CLI构建、驱动回归及完整Python回归正在执行。原boot程序SHA/inode和已批准CDHash核对保持，参数路径64。
- [ ] 将验证后的新host应用用于显式Cryptex重装，持锁保存新installed证明，不启动；随即执行Undo，再保存restored证明和两次API启停/运行后读取。
- [ ] 最终重新应用也明确使用 --reinstall-cryptex，保存新的来源/代码页证明、两次API启停与运行后读取，再提交push完成证据。

- [x] 相关Python33项、完整Python942项（跳过2项）254.634秒、Swift参数/传递12函数和新签名CLI的verifier3函数（5设置/8身份变化）全部通过；新应用签名/资源/依赖/entitlement通过，原获批VM程序保持。
- [x] 新入口和证据提交并push为2e0e0dea，远端一致；394个归档文件摘要与大小一致。
- [ ] 显式原件重装 session28495/CLI20039 已完成预检，osascript21116 等待macOS原生管理员验证；尚无root进程，新日志 `.build/t32-cryptex-reinstall-debug/cfw.log`。
- [ ] 续跑 session39110/`.build/t32-cryptex-reinstall-debug/after-install.py` 等待安装；新 installed 证明使用 `.build/t32-dsc-v4-rebaseline-fresh`，通过后同generation/同声明Undo，任何失败即停止，等待上限12小时；未启动VM。

- [x] 用户完成原生验证；显式Cryptex重装 root25634/session28495 已开始，正在核验generation与保存计划。续跑session39110保持等待新发布，不提前启动VM。

- [x] 显式重装已通过安装前入口核验并建立 staged `.cfw_disk.vZh3Hh4C`；regular安装器已启动，尚未发布，原Disk.img未交换。

- [x] 保存并启动撤销后顺序验收 `.build/t32-cryptex-reinstall-debug/after-undo.py`（session22627）：等待先前Undo成功发布；持锁核对restored原件/代码页，再两次API启停及运行后读取；显式重新应用Cryptex后再核对DSC、两次启停和读取。同generation/三份不同journal及原件/补丁摘要必须一致，失败即停止，不修改Git或宿主放行。当前仅等待，未启动VM。

- [x] 已有Cryptex整树替换、新发布及原件Undo组合回归通过；相关28项10.297秒退出0。实际root25634进入SystemOS源缓存入口，原件重装分支已执行，未发布。
