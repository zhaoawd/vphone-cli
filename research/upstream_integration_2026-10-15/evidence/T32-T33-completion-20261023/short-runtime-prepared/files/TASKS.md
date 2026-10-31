# T32/T33 当前执行清单

2026-10-21 09:12 CST 更新：本轮独立 DSC 启动前 Undo→同 generation 显式重新应用的真实 VM 验证于09:07通过。三份 v4 journal 已发布；DSC .42 原件/补丁件完整摘要、0x548/0x560 和6885代码页通过；恢复与重新应用状态各两次真实无界面 API 启动/正常关机、运行后 Receipt/generation 读回通过。10个阶段均退出0，7组证明与118个归档索引文件摘要核对通过。指定 runner、观察进程、caffeinate、VM子进程和旧CDHash helper PID均已不在进程表。本轮使用冻结构建；性能优化候选未纳入，图形/补丁运行效果、Mach-O/Preboot撤销、任意中间重打和受信guest来源不在已通过范围，T32/T33整体仍未 accepted。

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

- [x] 组合回归和续跑记录已提交push为21ae78d3；399份归档摘要/大小核对通过。
- [x] 显式重装已完成SystemOS/AppOS缓存与原始只读挂载，staged旧Cryptex处理步骤返回；当前重建App/OS目标目录入口仍在计划核验，尚未开始原件复制或发布。root25634/session28495持续运行，后续39110/22627仍等待；宿主可用空间最近约81GiB。

- [x] 显式重装的SystemOS/AppOS原件复制步骤均已返回，当前进入dyld链接设置入口；随后重新应用SwapEnd。仍未最终核验或发布，原Disk.img未交换；root25634/session28495持续执行，续跑39110/22627仍等待。

- [x] 真实显式Cryptex原件复制和SwapEnd producer步骤均已返回；当前进入第2/7阶段seputil准备。具体DSC原件/补丁摘要及6885代码页仍待最终新发布证明，尚未发布或启动VM；root25634/session28495持续运行。

- [x] 真实重装第2/7阶段seputil补丁、签名、写回、权限及Hardware/AA.gl入口均已返回；当前第3/7阶段GPU归档复制入口核验，root25634/session28495继续执行。未最终核验、未发布、未启动，后续39110/22627仍等待。

## 2026-10-20：显式重装最终核验失败与符号链接复现

- [x] 事务 `20261019T124601Z-vZh3Hh4C` 在首次最终核验拒绝，退出 1；原盘 dev/inode/size/mtime 与 66 样本相同，staged 已由安装器清理。两个顺序验收脚本均停止，未执行 Undo 或启动。
- [x] 实际安装脚本隔离回归约 3 秒复现：已有目录符号链接时，`ln -sf` 在 Cryptex 内创建同名链接。真实删除记录包含 `com.apple.dyld/com.apple.dyld` 与 `dyld/dyld` 两个应不存在目标。
- [x] 用真实两条删除记录和实际安装脚本重放最终比较，复现相同 `final transported member differs from recorded output`。失败 staged 已清理，无法直接读回此次失败的全部最终状态；该证据限制保留。
- [x] 修复链接替换及 guarded writer 参数/目标检查，保存回归和错误目标诊断；执行相关与完整 Python 验证。
- [ ] 更新签名 host 应用资源并保持原获批 VM 程序；再次实际显式重装、Undo、重新应用及启停验收，归档后提交 push。

- [x] 目录符号链接修复及严格拒绝回归完成；相关43项、完整Python948项（跳过2项）通过；签名应用资源/依赖核验及原VM字节/inode保持通过。

- [x] 最终完整 Python 948 项（跳过 2 项）259.925 秒退出 0；427 份归档文件大小及 SHA-256 核对通过。
- [ ] 修复后顺序验收 session59096/CLI4097 已通过安装前核验；本次 osascript10018 等待 macOS 原生管理员验证，尚无 root 安装进程。后续使用原获批 VM 程序，无新增 CDHash 授权。

- [x] 用户完成本次验证；全局检查确认 root24328 已运行，正在核验冻结计划及历史事务。原生提权由系统授权服务启动，不能仅依据 CLI 子树判断是否已生效。
- [ ] 同一重装 session59096/CLI4097/root24328 持续执行；首次发布通过后由既有顺序脚本保存新 installed 证明并执行未启动 Undo，尚未计作通过。

- [x] 实际目录核对确认新 staged `.cfw_disk.iTDO2qSV` 与 mount `.cfw_mount.mzBPvwgT` 已建立；原 Disk.img inode247084001/mtime保持，本次仅核对元数据，未重新抽样或整盘哈希。root24328/session59096继续执行，尚未发布。

- [x] 补充验收全部通过后的归档/普通提交/push步骤 `.build/t32-cryptex-symlink-debug/archive-after-pass.py`；3 个合成数据回归函数通过，包含 14 个拒绝用例与文件复制限制。合成结果不作为真实 VM 证据。
- [ ] 归档步骤仅在真实顺序验收 state=passed、七组证明通过、三个 journal/generation/6885页/API次数匹配时执行；冻结 HEAD d968d02f、当前文档摘要和目标分支，仓库/远端变化则拒绝自动提交。归档步骤启动后请先查看 `.build/t32-cryptex-symlink-debug/archive-state.json`，不要假定已经提交；若继续修改这些进度文档，该步骤会拒绝提交，需要之后人工核对。

## 2026-10-20：恢复执行状态核对

- [x] 全局只读进程检查确认旧安装器、顺序验收及自动归档均已退出；旧 acceptance-state.json 不能作为仍在执行的证据。
- [x] 确认新增历史事务 20261020T000756Z-iTDO2qSV；无 .cfw_disk.* 或 .cfw_mount.* 目录。当前 Disk.img dev/inode/size/mtime 与先前记录一致，仅证明元数据保持。
- [ ] 读取 root 持有的指定事务；sudo 非交互读取要求密码，已发起只读 macOS 原生管理员验证，未修改所有权、权限或磁盘。
- [ ] 取得错误原文后建立最小失败回归，必要时修复并执行相关验证；不依据旧错误推定本轮原因。
- [ ] 按同一 generation 完成安装发布、启动前 Undo、原件/代码页读回、撤销后启停及重新应用启停。旧自动归档基线已因本次进度更新失效，后续需先人工核对。

## 2026-10-20：续跑只读核验

已取得 VM 目录锁，按正式 cfw_disk_txn.sample_digest 计算 66 段采样，SHA-256 为 6715076b65c9b03b5313ab5f62c0a5e69dd352072cb63e5f8fe5e56543b35108，与安装前记录一致。完整磁盘摘要未重算，未启动或写入 VM。指定 root 历史事务等待原生验证读取；尚不能确认退出原因。旧验收/归档进程不存在，未重启安装或自动归档。证据：`research/upstream_integration_2026-10-15/evidence/T32-T33-resume-20261020/manifest.json`。

## 2026-10-20：141 退出复现及持久日志重试准备

已只读取得事务与最后 14 条操作摘要。真实退出为 141，109 条操作止于 GPU 归档删除；无最终效果报告或发布证据。原事务明确记录原盘身份及 66 段采样保持。

隔离正式 host-driver 对照命令：`PYTHONDONTWRITEBYTECODE=1 .venv/bin/python3 .build/t32-resume-20261020/compare-output.py`。三个场景通过：关闭 stdout 消费者得到 141/failed，普通日志得到 0/published，普通日志加安装错误得到 37/failed；三个场景原盘均保持且无残留 staged。该结果证明可复现路径，不能确认真实输出消费者退出原因。

持久进程 PID93069 使用普通日志，先等待指定失败事务及 .cfw_temp 的原有 invoker handback，再检查签名/输入/磁盘身份，执行同 generation 的安装、启动前撤销、重新应用及各两次 API 启停和读回。所有生产核验保持；未改动 VM 程序、宿主放行或 Git。重试安装前仍须系统原生管理员验证。证据：`research/upstream_integration_2026-10-15/evidence/T32-T33-resume-20261020/manifest.json`。

- [x] 读取真实失败事务及操作摘要。
- [x] 完成 SIGPIPE 路径隔离复现和三场景对照，保存可重复脚本及证据。
- [ ] 完成指定生成物交还的原生验证，观察持久顺序验收进入安装阶段。
- [ ] 完成实际安装/Undo/重新应用/启停，按实际结果归档；不提前提升整项验收。

## 2026-10-20：持久验收执行与 T60 独立工作

- [x] 指定失败事务及 .cfw_temp 所有权交还通过；事务内容摘要保持。
- [x] 全局进程核对确认安装原生验证已完成，root97562 执行 staged .cfw_disk.tjhO0rSZ；无重复安装。
- [x] 归档真实失败事务、109 条操作及交还结果。
- [ ] 继续本次真实 DSC 顺序验收；只使用现有冻结签名应用与已批准 VM 程序。
- [ ] T60：建立并发导入不应丢失第二个请求、取消等待项不应影响其余项的回归；完成 FIFO 导入及批量选择接线。
- [ ] T60：验证退出门关闭后队列不启动新命令；执行 Launchpad 相关回归和构建。完整 T60/混合版本/实际 UI 验收范围继续单列。

## 2026-10-20：T60 导入 FIFO 与批量选择

当前源码实现 FIFO 等待、批量选择、等待项取消和退出门关闭后不启动下一项。原实现 2 项回归记录 4 个失败；实现后相关 26 项及完整 LaunchpadKit 210 项通过，6 项真实 CLI/烟测按配置跳过。首次沙箱运行的 4 个权限失败保留，同一已构建测试在沙箱外通过。逐项队列行/进度/取消 UI、签名交互和完整退出矩阵未完成；T60 整体未 accepted。详情：`research/upstream_integration_2026-10-15/T60_import_queue.md`。DSC 冻结安装继续在独立持久进程中运行，未由本轮源码构建替换。

- [x] T60 并发请求不丢失的失败回归、FIFO 与批量选择接线。
- [x] 等待/活动取消、Unicode、失败中止当前批次及退出门回归。
- [x] 相关 26 项、完整 LaunchpadKit 210 项及本地化 JSON 检查通过。
- [ ] 逐项队列状态 UI、签名交互及完整退出矩阵；继续独立 DSC 实际验收。

## 2026-10-20：T60 导入状态和取消入口

- [x] 新增逐项 waiting/running/cancelling 状态；等待取消不执行命令，活动取消保留行直到命令输出排空。
- [x] 应用退出先关闭命令入口，再取消导入/导出的等待和活动项；保留超时取消退出及已发布输出。
- [x] 主窗口显示导入列表和逐项取消，允许继续添加选择；使用不确定进度，不推断字节比例。
- [x] 相关 31 项、完整 LaunchpadKit 216 项（6 项配置性跳过）通过；285 项源字符串与中英文目录检查通过。
- [ ] 独立签名候选 .build/t60-import-state-20261020.app 构建与资源/依赖/签名检查；保留现有所有应用。
- [ ] 真实 UI/归档迁移和完整混合版本退出矩阵；继续 DSC 同一持久安装事务验收。

- [x] 独立签名候选构建和完整资源/本机依赖/嵌套工具链摘要检查通过；冻结 CLI/VM 字节保持。
- [x] 真实签名 CLI 隔离并发导入验证通过：两个归档均发布，源盘/目标盘/归档完整摘要保持，输出排空且无 import staging。补存具体摘要后定向复验中。

## 2026-10-20：T60 状态/取消/退出后续验证

逐项导入状态和取消入口、等待选择取消、活动项排空、退出时混合转移取消及超时保留状态已实施。31项定向、216项完整LaunchpadKit通过；独立Release签名候选及嵌套工具链/依赖/资源检查通过。真实签名CLI的隔离并发导入复验通过：两个归档发布、源盘/目标盘/归档完整摘要保持、输出排空；具体摘要已归档。真实UI操作、字节进度、真实VM迁移及完整混合版本退出矩阵仍未验收，T60整体未accepted。证据：`research/upstream_integration_2026-10-15/evidence/T60-import-state-20261020/manifest.json`。

- [x] 具体摘要归档后的真实CLI并发导入复验通过（6.656秒，两个命令退出0，输出排空）；冻结验收输入摘要保持。
- [ ] 最新全局观察：seputil 原件复制入口的冻结计划核验正在执行；当前磁盘未发布。

## 2026-10-20：用户要求完成当前项

本轮仅继续 T32/T33 独立 DSC 的真实安装→启动前Undo→撤销后启停→同generation重新应用→启停及运行后读取。沿用持久 runner93069/CLI94446/root97562，不扩展其他功能，不重启安装。最新进程为 Hardware/AA.gl 移动入口的冻结计划核验；尚未发布。

- [ ] 等待本次安装结束，核对真实 v4 发布和当前未启动磁盘的 DSC 原件/补丁/6885代码页。
- [ ] 完成实际 Undo 发布和恢复原件证明，再执行两次 API 正常启停及运行后读取。
- [ ] 同 generation 显式重新应用 Cryptex，核对新事务、代码页、两次 API 启停及运行后读取。
- [ ] 核对三份不同 journal、同 generation、原件/补丁摘要及全部证明，归档具体结果；保持更广 T32/T33 范围未验收。

### 冻结 VM 执行条件复查

冻结程序字节/inode/CDHash保持，但非法参数探测返回-9。16:33:10 的amfid日志明确记录restricted entitlements拒绝；当前amfid44463，无旧helper。按本任务既有同CDHash授权发起既有临时helper恢复，等待系统原生验证；不加载/修改持久允许列表、不更改SIP或启动参数。安装仍在同一staged事务继续。

## 2026-10-20：完成当前DSC项的执行条件

用户要求继续完成当前项，本轮仅继续已有T32/T33验收。安装已从seputil推进到GPU归档提取入口，持久进程存活，未发布；未启动重复安装。后续VM程序的参数探测返回-9，程序字节、inode和已批准CDHash保持；16:33:10宿主日志确认amfid的restricted entitlements拒绝。仅按既有同哈希授权恢复临时helper，等待系统管理员验证，不扩展允许范围、不改SIP/启动参数或持久列表。准备了最终归档脚本，只有七组真实证明、三份journal、同generation、6885代码页和两组正常启停/读回全部匹配才会通过；脚本目前仅做语法检查，未执行最终归档。

## 当前执行：计划核验性能优化（2026-10-20）

- [x] 用现有 I/O trace 建立每次计划读取的完整 generation 核验次数基线，保存能捕获重复校验的回归。
- [x] 消除单次请求内重复完整核验；每次新请求仍重新验证原件、身份及发布证据。
- [x] 验证原件篡改、inode/身份变化、历史发布副本与blob篡改继续拒绝；执行相关固件无关回归。
- [x] 使用独立候选测量优化前后调用次数/耗时并归档；当前冻结真实VM验收程序保持。

- [x] 本轮重新恢复同CDHash临时放行，参数检查持续64；不加载或修改持久允许列表。
- [x] 归档检查3项回归通过，覆盖代码页/父事务/系统版本/正常启停和读回错误拒绝；watcher82196等待全部真实证明后归档，不写VM或Git。

## 当前真实DSC验收进程与恢复入口（2026-10-20）

- 持久执行器 PID93069，状态 `.build/t32-resume-acceptance-20261020/acceptance-state.json`；只继续该执行器，不启动重复安装。
- 只读观察 `.venv/bin/python3 .build/t32-resume-acceptance-20261020/observe-acceptance.py`；watcher82196每30秒记录观察，并在全部实际证明通过后调用严格归档脚本。归档状态见同目录 `finalization-state.json`，日志 `watch-and-archive.log`；无Git操作。
- 启动执行条件观察器80317，每30秒执行冻结程序非法参数，返回64表示进入解析；验收终态或12小时自动停止。当前同CDHash临时helper80729附加amfid55934，恢复记录 `host-allowance-before-boots-20261020.json`。不加载或修改持久允许列表。
- 当前真实VM为 `vm-t32-t33-dsc-20261018`，generation `6ebc5f6705cf0bffb32da62bf3006cc7ece5027edee4306abc8031aee9f4bb42`；Undo staged `.cfw_disk.EauDALvj`。当前已完成prepare/apply、两次最终核验、封存；在publish内最后一次计划复核，尚不能确认磁盘交换或finish。
- 后续按原脚本执行恢复证明、两次API启停及读回、显式重新应用、再次证明/两次启停/读回。reapply仍可能需要系统原生管理员验证；未完成验证时不得重复启动安装。
- 最终归档需七组实际证明、三份不同journal、同generation、原件/补丁摘要与6885页、26.0/23A341及正常关机/释放磁盘；不是整项T32/T33或图形效果验收。

- [x] 本轮未启动Undo实际发布：20261020T130129Z-EauDALvj，退出0；guest来源仍为unknown，恢复证明/启停及重新应用尚待完成。

- [x] 本轮恢复原件证明及撤销后两次真实API正常启停通过，结果已归档；运行后读回与重新应用仍待完成。

- [x] 撤销后运行读回通过：cfw receipts及verify-plan均退出0，关联同Undo journal，区分当前运行镜像与封存发布镜像，runtimeValidated保持false。


## 2026-10-21：T60 收尾及计划核验性能优化收尾（当前聊天）

范围：先完成 T60 可独立执行的实现、离线回归和界面验证，再完成计划核验性能优化的评审、回归和隔离基准。当前真实 DSC 验收沿用冻结程序；不在本聊天启动或改写其 VM。现有未提交修改保留。

- [x] 核对现有源码、测试和证据；T60 队列/逐项取消已实现，现有 opt-in 导出取消测试仍观察旧最终路径，需修正为真实私有 staging。
- [x] 修复跨选择导出和调用方取消；保存源变化合同、FIFO/等待取消/退出边界回归。两个指定签名CLI候选各6项通过；全部历史混合版本范围仍未验收。
- [ ] 实际多选两归档及两个16GiB源/目标完整摘要通过；Computer Use随后连续timeoutReached，界面Cancel/AppKit Quit未验证。库/真实CLI取消和退出已有保存回归通过。
- [x] T60完整相关回归、候选签名/资源检查和证据归档完成，配置性跳过及真实VM/完整矩阵限制单列。
- [x] 评审单次计划校验去重、直接Store.read身份/证据拒绝回归及4GiB历史镜像隔离基准：7.156秒→3.658秒，读取字节减半；冻结真实验收程序保持。
- [x] 研究记录、台账、执行命令和证据索引已更新；保留UI阻塞及真实VM未验证范围，未提交或推送。


2026-10-21 T60 收尾（当前聊天）：已修复跨选择导出并发及调用方取消未传播，保留失败回归；新增两后端源变化发布拒绝及最终提交前复查。完整 LaunchpadKit221项/Core436项和Python37项通过；正式run_launchpad_cli_tests对上一候选与当前候选分别6项通过。独立签名候选为.build/t60-closeout-20261021.app。实际NSOpenPanel已多选两个16GiB稀疏夹具并发布，两份成功日志和源归档摘要保持；随后界面工具多次timeoutReached，重绑定和会话重置未恢复，1秒sample显示主线程处于正常事件循环。UI取消和AppKit Quit保持未验证，整项T60不accepted；不阻止后续隔离性能验证。当前聊天不操作真实验收VM。


## 2026-10-21：继续完成T60剩余内容

- [x] 保存创建退出原实现2项/6个issue失败；创建纳入进程组中断及输出/日志有期限等待，运行VM生命周期保持独立。
- [x] Finder归档打开在工具链验证前排队，完成入口/UTI接线和正式冷启动/无效选择回归；实际Finder交互仍待解锁。
- [x] 版本化可选JSONL进度和旧CLI不确定进度回退；socket排除、未知总量及两后端源状态合同保持。
- [x] 实际GUI发现Finder PATH缺zstd；打包zstd/xz及依赖/许可证，最小PATH两格式正式导入导出通过。
- [x] 最终独立r3签名候选和完整资源/本机依赖/嵌入清单检查通过；Kit227项（跳过10）、Core441项（跳过1）、ArchiveCLI2函数、Python62+7项通过。新/旧具名签名CLI分别8项通过；真实信号导入4+导出4场景通过。
- [x] 原候选实际idle Command-Q退出；旧真实VM的APFS克隆导出14.5GiB归档通过，源持久文件完整摘要保存；当前DSC验收VM/冻结程序保持。
- [ ] Mac当前锁定，等待用户手动解锁后完成最终候选实际活动/等待Cancel、传输Quit/超时及Finder冷打开；真实创建退出仅有受控替身回归，未执行实际restore。
- [ ] 真实VM导入预检需30,044,004,352字节空闲（含4GiB保留），当前约27.7GB；待释放至少3GiB后重新检查。原始归档和VM保留，未删数据。
- [x] 更新研究、台账和证据：research/upstream_integration_2026-10-15/evidence/T60-remaining-20261021/manifest.json。T60未accepted；未提交或推送。


## 2026-10-21：独立 DSC 真实 VM 验证结果

- [x] 初装、启动前撤销和同 generation 显式重新应用：三份不同 v4 journal、完整摘要与6885代码页。
- [x] 恢复后和重新应用后各两次真实无界面 API 启动、正常关机及磁盘释放。
- [x] 两种状态的运行后生产 Receipt 和 Swift generation verifier 退出0。
- [x] 七组证明归档，独立核对118个索引文件的大小和SHA-256；冻结输入和两份应用签名通过。

证据：`research/upstream_integration_2026-10-15/evidence/T32-T33-new-vm-20261018/dsc-on-off-on-20261020-resume/manifest.json`。上面的整体待办继续保留，本结果仅完成DSC启动前撤销/重新应用范围。


2026-10-21 T60恢复：用户已解锁并清理空间。最终r3实际等待/活动Cancel、传输Quit超时提示及及时恢复后的排空退出通过；Finder冷打开与热打开均已启动导入。真实native VM导入两次触及4GiB保留量并退出130，均清理未发布staging。第二次记录目标分配超过60GB，源约25GB；原因待查，正在建立源/目标分配量回归。当前不增加新的真实导入重试。


## 2026-10-21：T60恢复后的实际验收

- [x] r3实际导入/导出等待及活动取消、传输Quit超时保留与排空退出、Finder冷/热打开；两个16GiB源/目标及归档完整摘要保持。
- [x] 真实64GiB默认system-tar往返8个持久文件摘要一致，源VM/归档保持，无staging，未启动VM。
- [x] 正式native1GiB稀疏盘/硬链接回归；新旧签名CLI各9项/4 suites通过；完整Kit228项（跳过11）通过。
- [ ] native真实大盘两次容量中断并清理，分配差异原因未查明；待批准清理本次具名system-tar/restored测试副本，需73,766,043,199字节保守空闲后复验。
- [ ] 实际create/restore退出和更广历史组合保持未验证；不提前登记accepted。
- [x] 更新研究/台账及evidence/T60-resume-20261021；冻结DSC输入保持，未提交或推送。


## 2026-10-21：T60具名验收矩阵完成

- [x] 用户批准后仅删除本次system-tar/restored测试副本；原VM、归档和验证结果保持。
- [x] 相同r3候选与归档完成native64GiB导入，8个持久文件完整摘要相等，无staging、未启动VM；容量阻塞解除。
- [x] GUI取消/退出/Finder、新旧签名CLI各9项、创建退出受控回归和真实两后端具名矩阵完成。候选签名及冻结DSC输入复查保持。
- [x] 归档最终结果及批准清理记录，更新台账；当前实现与具名矩阵可提交评审，不代替人审accepted。

验证限制：导入后启动、实际restore阶段AppKit退出、全部历史Bundle及跨主机文件系统组合未覆盖。分配量差异原因未查明；未修改生产归档实现，保守容量预检和4GiB运行保留量保持。未提交或推送。最终证据：research/upstream_integration_2026-10-15/evidence/T60-final-20261021/manifest.json。


## 2026-10-21：新目标 U0 对账（当前聊天）

- [x] 承接 T60 具名矩阵和 DSC 局部验收，不提升 accepted。
- [x] 取得固定目标 2a0d3ac，保存当前 WIP 摘要及 tracked diff（排除根 TODO.md）。
- [x] 隔离 Git 审计确认 8a75092 为祖先；增量57条，含20条 merge、37条其他提交，端点215条路径元数据。
- [x] 新目标首轮源码对账：枚举全部7份锁文件、核对两份ROM二进制摘要，记录本地API已有能力及classic/GUI差异。
- [x] 57条逐提交路由、20条merge全部父差异归档；原仓库对象重建结果一致，错误范围和遗漏提交拒绝验证通过。
- [x] 核对66项唯一ID、依赖无环、旧status/target_review/dependencies保持及既有脏文件摘要；证据已归档。
- [ ] 完整语义评审及实现适配：先恢复项目Python环境，再继续T08的0.8.6依赖及guest RPC验证；本轮未更改锁文件或运行VM。

当前分支和既有实现保持，不执行 VM 操作或自动合入。原用户附件及 2026-10-17 progress_migration.md 当前不可读，无法独立比对附件集合。`.venv` 是失效符号链接，本轮标准库审计使用系统 Python。

结果：research/upstream_integration_2026-10-15/U0_source_audit_20261021.md；证据：evidence/U0-20261021/manifest.json。Git范围及首轮路由完成不等同于功能等价或accepted。未提交或推送。


## 2026-10-21：T08 IcliKit 0.8.6 适配（当前聊天续跑）

- [x] 按平台锁文件恢复项目 .venv；Python3.14.5、locked probe和pip check通过，锁文件未变。
- [x] 核对4条提交/7个端点文件；Swift公开调用及JPEG源文件未变，overlay原补丁与内容摘要保持。
- [x] 同步exact requirement、resolved/expected pins及overlay revision；其他六项pin保持；正式16+3项专项通过。
- [x] Xcode27.1构建独立iOS Release classic/v2候选，签名/依赖/overlay marker/来源均通过，未安装或激活。
- [x] 正式Python949项（跳过1类）通过；支持隔离SourcePackages且核对NIO revision后，2项补验通过。证据和候选清单已归档，冻结应用摘要保持。

T08本轮结果：固定依赖适配和候选验证完成，真实guest服务/应用/截图内存仍未验收；无VM安装或激活。详见research/upstream_integration_2026-10-15/T08_icli086_20261021.md。下一项可继续T47/T48源码及来源边界对账；真实guest部署另需明确对象和范围。未提交或推送。


## 2026-10-21：T47 与 T48 克隆身份边界及整组快照实现（当前聊天续跑）

- [x] 实现 `VPhoneBundleActivity` 与 `VPhoneUnixSocket` 状态文件打开句柄检测（支持高位 `fsid` 设备号）及控制 socket 探活。
- [x] `VPhoneBundleOps.rename` 同步派生默认 mDNS 名称；`clone(newIdentity:)` 清理身份与冲突网络设置，排除 `Snapshots`、`.snapshot-revert-*`、`.template.plist`、`.cfw-history` 与根级 `.firmware-*`，并在 CLI 明确说明 SEP/Data 密钥继承关系。
- [x] 实现 `VPhoneMachineSnapshots` 整组 CoW 快照、`SnapshotRevertJournal.plist` 崩溃恢复与锁门控、恢复后收据对账及四层 `launchpad.json` 同步；注册 `vm snapshot create|list|revert|delete` 子命令。
- [x] 补充 `BundleActivityTests`、`BundleSnapshotsTests`、`BundleOpsTests`、`BundleCloneStateTests`、`MachineSnapshotsTests`、`FirmwareDesiredPlanStoreTests`、`VMSnapshotAndCloneCLITests` 共 7 个套件 89 项测试并全部通过（退出 0）。
- [ ] 真实 64GiB 已恢复 VM 的快照恢复启动与 `--new-identity` 双机并行启动验收。
- [ ] 继续推进 T09/T10 固件补丁与恢复链增量（`RestoreRamDiskSealPatcher` SystemVolume hash metadata 门控与保留选择、`ParavirtGPUPatcher` 64-bit index offset 对账）。

## 2026-10-21：T52 磁盘互斥与 CFW 工作区

- [x] 读取交接、工作区规则，核对 5a9db709/b4f59638/2745535e/c36e7d62/f9c69800 及 work-parent 相关提交。
- [x] 保留现有 boot argv/启动时间校验和磁盘持有者不发信号规则，补进程分类与错误描述回归。
- [x] 增加 Launchpad 绑定→环境更新编排、持有者预检、实际子进程启动后回调；删除继续使用嵌入式 CLI。
- [x] 增加 install/update-environment 的 --work-parent；外部挂载根记录于 VM 内事务 journal，磁盘 staging/evidence/history 保持同卷。
- [x] 首轮 Swift 53项、Python工作区5项及事务/隔离50项通过；Python沙箱EPERM与无沙箱通过日志分别保留。
- [x] 修复最终挂载根journal绑定失败后的空目录遗留；一次性驱动副本复现失败，正式驱动回归通过。补充真实lsof自身/外部持有者与长Unix socket回归，最终定向Swift55项通过。
- [x] Python扩展235项中234项通过；唯一Undo夹具缺模块问题已修正，原用例补验1项通过。完整Kit239项（跳过11）与停止/锁35项通过。
- [x] 归档 T52 报告与 manifest，同步 tasks/local_reconciliation/plan/progress；历史状态和依赖保持。
- [ ] Launchpad GUI/控制命令尚未调用新setBundle编排；真实跨设备工作目录、devfs及VM验收待执行，不登记accepted。
- [x] T52本轮验证已归档；后续T51按下节继续，真实VM与冻结.app保持。

## 2026-10-21：T51 磁盘 rebase 与物理共享计量

- [x] 核对固定上游实现与测试，接入双机目录锁、generation/Receipt保持、路径检查和取消合同。
- [x] 注册vm rebase --onto/--dry-run/--recover；完整字节验证与journal交换/恢复，新增共享/已有共享分开报告；不重写固件资格。
- [x] 实现物理extent计量、缓存和检查器展示；逐文件复查占用，短期共享目录锁排除启动/写入；未知、过期或目录读取失败显示Unknown。
- [x] 临时APFS文件rebase22项、计量6项和CLI2项通过；FirmwareDesiredPlanStore19项含rebase后旧inode资格拒绝。
- [x] 扩展Core XCTest93项及Swift Testing498项（跳过1）、Kit244项（跳过11）、相关CLI4项、来源19项通过。最终Kit245项、相关Core48项、CLI2项、来源19项通过，分组不相加。
- [x] 标准Python958项（跳过4）发现4项边界/文案检查失败；按T47/T51/T52实际合同修正后，受影响38项全部通过；锁9项通过，无未解决失败。
- [x] 归档T51报告与manifest，同步台账与进度，保留历史status/target_review/依赖及accepted=false。
- [ ] 模板标识符基准等待T49；真实外置卷/非APFS故障、实际界面、真实VM及完整进程崩溃矩阵未验收。冻结.app未操作，未提交或推送。


## 2026-10-21：T51/T52 真实 VM 与界面验收

- [x] 用户明确继续真实 VM 与实际界面验收；外置物理磁盘未连接，用户指示暂缓外置卷验收。
- [x] 构建独立签名 CLI/VM/Launchpad及r2候选；资源、权限、内嵌工具链核对通过；现有vm-2607保持。
- [x] 只读克隆vm-new至.build/t51rt/lib/base与target；真实64GiB rebase、外部读进程拒绝、完整摘要和原VM文件身份复核通过。
- [x] 用户完成具名认证后，419d5a6c候选对rebase副本两次真实启动、guest连接、iOS26.1/23B85读取、正常关机、磁盘和目录锁释放通过；helper已停止且PID不存在。
- [x] 隔离库r2实际停止/外部读进程/释放恢复回归通过；保存模块、AX及截图。真实运行实例ID、停止按钮、Unknown/缓存提示及关机后当前计量回归均通过。
- [x] 更新报告与任务台账；归档具名磁盘及界面证据，外置物理卷按用户指示暂缓，两次真实启动续验已完成，不代替人审accepted。

实际界面发现停止VM计量长期Unknown：两次保存的回归复现；2秒对照无逐文件lsof映射9709文件，有lsof仅9文件，预算耗尽还影响下一目录元数据枚举。已分离枚举预算、合并共享锁内目录预检、保留状态文件即时持有者检查及逐文件本地状态复查。最小断言先失败后通过；完整Kit248项、Python24项通过；r2实际停止状态显示36.9GB已分配、8kB独占，回归通过。外部读进程显示/恢复及真实运行/关机后恢复验收均通过。

2026-10-21具名启动最终结果：原VM完整摘要/身份再次复核保持，base磁盘stat版本保持；target允许正常guest写入，config/staged daemon/ROM/UDID保持。真实运行期间rebase拒绝；r2运行状态实例ID和关机后36.31GB/612.3MB当前计量回归通过。临时helper8387在约148秒后停止，独立ps确认不存在；vm-2607仍为33355。最终证据见authorized-boots/manifest.json；外置卷按用户指示暂缓；未提交或推送，accepted=false。


## 2026-10-21：T51提交范围

- [x] 按功能暂存rebase/计量及必要的停止检查、快照journal基础；其他WIP保留。
- [x] 索引独立导出构建，相关Swift78项和Python23项通过；原工作区895文件摘要保持。
- [x] T51具名范围已提交4b5117d6，未推送；继续T52 GUI及环境更新launcher路由接线。


## 2026-10-21：T52实际入口接线

- [x] 提交T51后保留其他WIP；复现cfw环境更新被launcher路由拒绝。
- [x] 增加机器操作菜单/绑定sheet，保留首次完整备份和显式环境更新选择。
- [x] 只允许已验证选中Bundle的环境更新协议；冻结绑定并在写入前复核，失败/取消保留已发布绑定。
- [x] 补路由、协议、编排、CLI及Python绑定漂移回归，完成用户具名批准后的实际签名界面检查。
- [x] 归档证据与台账；生产Core Bundle安装仍遵守既有批准门，外置物理卷暂缓。

T52入口续验：Swift定向22/1/10项、扩展256/35/2/42项（共跳过12项）通过；Python相关218项及最终绑定模块56项通过，分组不相加。独立候选签名/内嵌工具链核对和保存的实际绑定界面回归通过；取消后VM所检查文件保持且无绑定发布。真实root-owned Bundle认证/绑定/环境替换尚未验收；外置物理卷按用户要求暂缓；本轮改动未提交，accepted=false。报告见T52_entrypoints_20261021.md。

## 2026-10-21：T52真实 Core Bundle 绑定及环境替换

- [x] 用户要求继续真实绑定与环境替换；创建独立 t52-environment 副本并完成实际只读磁盘检查。
- [x] 发现原副本为 classic /b，缺少五个 v2 库，生产检查为 full_migration_required，原盘保持；不绕过迁移限制。
- [x] 修复绑定环境组件被继承环境变量覆盖的问题；构建时打包协议所需签名 dylib，补齐打包检查及回归。
- [x] 生成具名 Core Bundle 2.6.2-local.cd529f26a150 和 SHA-256，获批安装到新版本目录并核验 root-owned 收据。
- [x] 核验 archive 与本地固件内容摘要；独立 v2 VM 创建及具名临时放行已获批准。
- [x] 完成具名 store 安装、首次完整备份、真实绑定、实际环境替换及只读读回；保存证据与限制。

T52真实验收进展：用户已批准并终端认证。系统store已安装并核验2.6.2-local.cd529f26a150，归档摘要与收据匹配；独立t52-v2 prepare/patch成功，实际生成58条记录。辅助进程85760于21:19:08以Unexpected process state 10异常退出；21:27:23 DFU被amfid拒绝受限权限，恢复未开始，CFW及后续绑定/替换仍待完成。原临时放行已停止且绝对30分钟窗口已过，不自动延长。准备retry-1单哈希、统一30分钟绝对截止、最多3次重新附加的辅助脚本，尚未执行，等待新窗口批准。源VM和具名CoreBundle不替换；已有固件与恢复输入保留。

T52重试：用户批准并执行 retry-1，27581仅放行同一CDHash，统一截止时间2026-10-21T15:00:05Z，最多3次附加。沙箱内续跑仍在DFU获取锁前失败；沙箱外直接同快照探测取得VM锁，随后同参数/环境在沙箱外续跑，原生restore工作进程已运行。具体沙箱限制项未确认。没有重复prepare/patch，没有扩大哈希范围或延长窗口。

T52恢复已通过；CFW退出1且未发布暂存盘。只读检查复现项目资源覆盖选中0.8.5载荷，与0.8.6 pins不匹配；批准Bundle内0.8.6组合通过。修正续跑参数后在8份资源快照保留上限处拒绝。已完整备份347项失败快照并核验，等待用户批准删除仓库外该原副本，未绕过上限。绑定/环境替换仍未执行。

T52等待快照删除确认期间已停止辅助进程27581（stoppedAt=1792594364.516097，早于原截止），独立ps确认PID不存在；t52-v2无遗留进程，vm-2607仍为33355。原安全窗口不复用。CFW修正续跑尚未执行。

T52快照处置已获用户明确批准：再次核验347项源/备份一致且无进程使用后，仅删除14235815原临时目录，备份和其他7份快照保持。已使用批准Bundle封装资源续跑CFW（PID44018），不复用已停止AMFI窗口。

T52封装资源CFW已通过旧API不匹配位置，但在v2 launchd签名处被正确拒绝：原命令区3192、__text3208，注入后3208，ldid新增16字节签名命令覆盖代码。离线真实字节复现；新增v2注入空间预留，按现有Swift签名器策略只删除LC_SOURCE_VERSION，保留UUID/指令/签名校验。217项扩展回归和最终14项签名单元通过；禁用预留步骤的反事实回归复现原拒绝，启用后通过。创建修复放入独立资源副本，系统Bundle未改。用户批准后复核并删除211c/665两份已备份失败快照，其他6份保持；已用修复副本续跑CFW，PID66901，AMFI不重启。

T52第三轮CFW已实际通过v2 launchd签名（权限及代码保持），但最终transport校验拒绝classic/v2先后覆盖同一API plist。新增实际cfw_stage_api基础写入+冻结profile合并+v2安装+最终证明链回归，先复现相同覆盖拒绝；修复为v2基础阶段保留候选校验并交由v2阶段安装API，基础合并忽略缓存classicAPI job。9项定向与235项扩展通过，transport校验未改。创建资源副本现5个脚本差异；以PID87143、session18630续跑，日志cfw-profile-fix/create.log。旧AMFI仍停止；同一具名VM执行--help被amfid Code=-424拒绝，已准备并请求新boot-window的30分钟单哈希授权，尚未启动。

T52启动窗口已获用户明确批准：仅同一CDHash、最多30分钟、最多3次附加且共用绝对截止、不写持久允许名单。boot-window脚本尚未启动；计划在CFW后段请求用户终端认证，随后完成首次启动、绑定、环境替换和替换后启动。

## 2026-10-22：真实创建、首次绑定和界面环境继承缺陷

独立t52-v2创建续跑退出0。CFW发布通过；first_boot检测到shell prompt，发送既定命令并关机；verification再次检测到bash prompt，所有适用阶段均为succeeded且verified。替换前实际只读检查为offline_update，五个库分别匹配固定源码的-O0基线，磁盘抽样和身份保持。

实际Launchpad提交首次完整备份，生产绑定命令完成三份完整文件清单比较后发布2.6.2-local.cd529f26a150绑定。另行复核备份和当前盘的66处抽样一致、七个身份/配置文件摘要保持，备份无launchpad.json。绑定后的环境预检报告找不到lsof，尚未写盘；绑定按设计保留。

最小Foundation实验和实际子进程类回归均确认当前macOS上显式Process.environment=nil丢失继承环境。改为仅在显式提供环境时赋值，保留空字典和指定PATH覆盖行为。原继承测试失败，修复后23项相关测试通过；完整Kit258项测试通过、跳过17项。新的隔离界面候选.build/t52-envfix-launchpad-20261022.app已构建并通过签名/封装检查，内嵌CLI/VM字节保持，待用户给予新候选打开授权后重试实际环境替换。系统Bundle未改。

boot-window于2026-10-21T16:01:17Z启动，首轮实际放行覆盖了创建启动；16:16:12Z在三次附加后停止，错误Unexpected process state 10，辅助PID已不存在。随后同一VM二进制--help退出-9，amfid新PID2568记录受限权限Code=-424拒绝；原amfid PID78198已消失。日志未确认其退出原因；没有新的主动附加授权，因此未以主动调试复现原因，也未改写宿主amfidont安装。不得复用三次额度。离线替换继续，替换后启动需新的具名授权窗口。

## 2026-10-22：T52 实际环境替换读回完成

- [x] 新候选已获当次打开授权；经实际界面完成具名系统Bundle环境更新，用户已认证，事务exit_code=0且published。
- [x] 独立只读读回already_current，33项断言通过；五库目标摘要、磁盘交换、身份/配置/变体保持与历史原盘保留通过。
- [x] 系统Bundle收据复核通过；三个受保护副本检查保持，原vm-2607仍为PID33355；独立VM无运行/挂载/锁遗留，旧具名辅助进程均不在运行。
- [x] 用户已解锁；完成、运行及停止界面回归和AX/截图已保存。
- [x] 用户批准并认证600秒单哈希一次附加窗口；完成替换后读回、映射及API模式正常关机，辅助进程在352.713秒后停止且PID不存在；默认GUI关机限制另记。
- [x] 本次为单次续推，未新增重复调度；外置物理卷仍按用户指示暂缓，accepted=false，未提交或推送。

2026-10-22 06:38单次续推复核：最新会话未收到既有解锁及600秒单哈希请求的人工回复；新窗口未启动，Disk.img stat与替换后记录一致，未重跑环境更新。按“执行后不再重复调度”要求，将本次t52续推任务设为PAUSED并从配置独立复核。继续等待既有批准门，不重复提问。

## 2026-10-22：T52 替换后运行验收结果

- [x] 实际GUI默认启动使用所选Bundle与冻结绑定，客户机26.1/23B85和五库目标摘要读回通过。
- [x] 首次默认GUI停止超时并触发框架停止，失败原始证据保留；同一断言重放仍拒绝。
- [x] 同一窗口/API模式绑定CLI启动，经实际GUI停止，apiAccepted/Guest stopped、退出0、磁盘与目录锁释放通过。
- [x] API文件及映射均为current，扫描264进程、无旧映射及未检查项；24项运行证据断言通过。
- [x] 600秒单哈希辅助进程仅附加一次，352.713秒后停止；最终系统Bundle、受保护副本和原VM核对通过，无目标进程或挂载遗留。
- [x] 上轮默认GUI关机失败已保留；后续新增直接VSOCK API路径并通过真实默认GUI启停复验，见下节及T52_default_GUI_shutdown_20261022.md。
- [ ] 摄像头/定位应用行为未验证；物理外置卷按用户指示暂缓。
- [x] 同步报告、台账与证据；accepted=false，未提交或推送，续推调度保持暂停。

## 2026-10-22：T52 默认 GUI 关机续修

- [x] 重放首次默认 GUI 失败日志，正常关机断言仍拒绝；保留原始失败证据。
- [x] 为默认启动、不启用 HTTP 监听的生产停止路径建立先失败后通过的回归；另按客户机 Connection: close 语义复现并修正连接复用问题。
- [x] 增加仅停止时使用的 VSOCK API 关机请求，两连接共用3秒总期限，保留能力检查、取消释放与旧客户机回退。
- [x] 相关分组108项通过；混合扩展运行的既有APIProxy测试失败日志保留，单项和完整11项独立通过，混合失败原因未查明。
- [x] 独立候选2.6.2-local.af333c78ac3b签名/依赖/封装核验通过，全部客户机及Framework资源保持字节一致；已安装Bundle不改。
- [x] 用户批准并认证后安装具名候选，仅重绑t52-v2；默认GUI启动、版本/五库摘要、无API监听、实例状态、正常关机、退出0及磁盘/锁释放全部通过。
- [x] 修正验收脚本旧日志偏移不适配新文件的问题；4项边界回归通过，保留首次脚本失败日志及所有停止断言，重放同一次真实结果通过。
- [x] 600秒单哈希窗口仅附加一次，205.739秒后停止；独立确认辅助进程和目标VM已结束，无挂载遗留，原VM和受保护副本保持，两版Bundle收据通过。

默认GUI关机问题的修复及真实验收已完成。t52-v2当前宿主绑定为2.6.2-local.af333c78ac3b，环境更新未重跑，客户机组件保持。报告见T52_default_GUI_shutdown_20261022.md，证据单独保存在evidence/T52-GUI-shutdown-20261022/manifest.json；此前失败与验收证据保持。摄像头/定位应用行为未验证、物理外置卷按用户指示暂缓；本批未提交或推送，T52整项accepted=false。

## 2026-10-22：APIProxy 混合测试失败排查

- [x] 原混合组合捕获错误HTTP503；独立12轮1次复现；100轮竞争产生20个错误503，10轮等待连接器阶段对照通过。
- [x] 确认停止准入与容量耗尽共用false，导致客户端关闭前误发503；状态探针和无探针单变量反证均支持，反证产生55个错误503。
- [x] 同锁内区分reserved/stopped/capacityReached，停止直接结束、真实上限503保持；APIProxy13项通过，原混合组合加2项回归后110项连续3轮通过，未隔离失败测试。
- [x] 临时探针已移除，源码恢复与证据摘要已核验；更新研究记录与台账，不启动VM、不修改AMFI或已安装候选。

报告见T52_APIProxy_stop_race_20261022.md，证据见evidence/T52-APIProxy-stop-race-20261022/manifest.json。该失败已在源码层修复并验证，系统部署另行记录。T52整项仍保留摄像头/定位应用行为及暂缓的物理外置卷范围。

## 2026-10-22：APIProxy 修复提交与部署

- [x] 仅提交本轮APIProxy源码、回归、研究记录与证据，提交a0119127；其他未提交工作保持，未推送。
- [x] 从当前已验收Bundle复制客户机资源，构建新宿主CLI/VM；候选2.6.2-local.266810c8ae29签名、依赖、资源解析与512个源码摘要通过，客户机和Framework字节保持。
- [x] 在既有系统store新增具名版本，仅重绑已停止的t52-v2；不重新安装客户机环境、不启动VM、不修改AMFI。
- [x] 新旧收据、安装字节、绑定、磁盘元数据/选定配置摘要及受保护对象核验通过，保存提交与部署记录。

用户完成终端认证后安装成功，t52-v2当前宿主绑定为2.6.2-local.266810c8ae29。旧版本及原VM保持，本次未启动VM、未修改AMFI，未推送；新版本真实启动未验证。T52应用行为和暂缓的物理外置卷范围保持未验收。部署记录见T52_APIProxy_deployment_20261022.md。

## 2026-10-22：T52 新版本与应用验收续推

- [x] 新版本收据、停止状态、磁盘/目录锁及绑定基线通过；实际Launchpad绑定/已停止界面断言与截图通过。
- [x] 标准CoreLocation/AVCaptureMetadataOutput应用探针构建签名通过，尚未安装；6项消费记录验证回归与4项日志身份回归通过。
- [x] 用户批准900秒、一次附加、仅新VM哈希的临时窗口；脚本已准备，sudo需要认证，已请求用户自己的终端执行。
- [x] 新版本默认GUI真实启停通过；独立API会话就绪，辅助进程已提前停止，受保护对象复核通过。
- [x] 按本轮批准注销旧探针注册并完成正式容器安装；旧文件摘要及数据路径保持。
- [ ] 完成应用消费验收：正式容器探针启动仍失败，kernel有TXM CodeSignature错误；相机未就绪，发布端/消费端路径不同。具体签名拒绝条件和相机连接重置原因仍待查明。

后续已启动并完成默认GUI启停；API会话按用户要求保留，辅助进程已停止。旧窗口不复用，物理外置卷仍暂缓。详见T52_application_acceptance_20261022.md。

## 2026-10-22：下一项T53开发工具组合兼容

- [x] 核对固定上游DeviceHub、persona与Flutter实际构建/注入位置；Flutter直接编入SystemHook，修正初始文件名检索遗漏。
- [x] 三个原生C测试程序通过，DeviceHub/Flutter实验库及含Flutter的SystemHook隔离构建/签名/架构检查通过，r2共24步通过。
- [x] 修正Undo测试夹具的guest_environment关键字合同并断言冻结profile，原106项Python组合复验通过；Swift Undo14项通过。初始失败日志保留。
- [ ] 按本地固定来源、声明目标和Receipt/Undo协议接入完整载荷与标记；补齐DSC/kernel前置后分别执行开发工具真实验收。

T53已推进至源码审计和隔离候选通过，产品接入、迁移发布及真实工具验收未完成，accepted=false；未部署此候选。详见T53_developer_compatibility_20261022.md。

T52续推实际结果：新宿主默认GUI真实启停已通过，五库摘要/绑定/正常关机/退出0/磁盘锁释放通过。API会话PID69035按用户明确选择保留运行；辅助PID66498仅一次附加，745.972秒后停止且独立确认不存在。用户已完成初始设置，系统设置应用启动对照通过。探针注册已成功，但实际启动被客户机System Policy process-exec拒绝；原始arm64e与已解锁arm64对照均失败。已准备正式容器IPA并请求仅注销本轮注册项和安装器暂存清理批准；消费行为仍未验收，不再等待初始设置或旧AMFI窗口。详见T52_application_acceptance_20261022.md。


T52正式容器续验：用户批准范围已执行，安装及旧文件/数据路径保持核验通过。正式容器启动仍失败；移除platform-application及arm64对照均未通过，已恢复原生安装字节。系统相机与地图启动对照通过，但cameraPresent=false、相机连接未建立；实际二进制共享内存路径不同，源码头大小定义256/64不同。定位确认不作为消费通过。来源与对照应用已停止，原VM/副本/绑定复核通过，t52-v2按用户要求保持运行，AMFI辅助未重启。后续依次查明探针签名拒绝条件、统一相机组件接口并复验定位/QR；物理外置卷暂缓，accepted=false。本轮未提交。见T52_application_acceptance_20261022.md。

## 2026-10-22：探针签名、相机接口与应用消费验收

- [x] 在既有 t52-v2 实例复现正式容器探针启动失败，建立签名拒绝条件的单变量验证。
- [x] 保存原因、对照与签名修复回归；保留原探针及受保护 VM。
- [x] 复现相机接口失败，统一发布端/消费端协议并完成相关回归和候选构建。
- [ ] 在具名 VM 验证定位回调与 QR 消费，归档实际结果、摘要和未覆盖范围。

本轮用户明确要求按以上顺序实施与验收。仓库外修改、删除数据及主机安全变更仍按各自批准条件执行；已有旧窗口不复用。

签名诊断更新：原正式容器程序缺CMS；相同native signer、相同__text与权限，仅补项目证书后启动通过，恢复无CMS失败，再恢复CMS通过。相机跨实际发布/消费代码像素偏移复现先失败后通过，27项定向及10项验收资产回归通过；候选2.6.2-local.93805a71796d已签名封装。全量首轮970项因同一旧Undo夹具关键词合同出现26错误，显式接收并断言guestEnvironment后36项通过，最终全量复验进行中。定位已有应用事件但尚无消费通过，旧URL请求存在系统打开确认框；新探针通过scene激活阶段/自有runID-mode文件触发，保留真实错误。用户已明确批准deployment-plan.json的具名部署与新900秒单哈希一次附加窗口；旧窗口不复用，其他VM和原数据保持。

T52 本轮续推：最终全量 Python 970 项通过（4 项跳过）。候选 .93805a71796d 已安装并重绑；正常离线更新在写盘前因 v2 历史事务缺少固件磁盘身份连续性而拒绝。保持原 Gate，新增仅支持本轮 VM/两库/固定签名候选的独立维护工具，以完整 Disk.img SHA-256 和六项元数据摘要绑定，固件与 Undo authority 保持 unknown，归档放在 .environment-history。7 项事务/故障恢复及现有49项环境回归通过；用户认证后实际事务发布，完整旧盘保持，独立只读复核 already_current。

新实例 55A25B78-4CAD-4053-9C3E-9CFCD3E75F64/PID64038 已就绪。单哈希辅助仅附加1次；常规停止未退出，用户认证后强制结束，OS独立确认辅助及debugserver均不存在、amfid无调试状态；停止日志给出的时长上界673.277秒，小于900秒。匹配发布端缓存摘要与camera_present能力通过。相机实际探针仍无可用设备/无复制回执；映射检查确认探针已加载SystemHook/libvlocation/libcamfix，cameracaptured已加载SystemHook/libvcamcaptured，继续查初始化日志。定位正常权限点击后已获授权并收到一条七字段正确回调，严格双回调要求尚未通过。新验收工具12项通过，实际失败均保留；消费 accepted=false。

T52当前条件：正确容器诊断产物确认两项方法分别来自libvlocation/libcamfix；探针只读打开相机共享帧返回EPERM，定位桥接文件返回ENOENT。虚拟设备注册失败原因未查明。诊断构建器遗漏正式容器权限的问题已修正，部署前保护覆盖实际缺权限/正确产物；工具15项通过。新候选2.6.2-local.56be1ce20ded仅增加可读初始化日志，构建/签名/Bundle核验和4项跨代码回归通过；尚未安装，已请求具名新候选及新900秒一次窗口批准，旧窗口不复用。独立进程监督器2项实际子进程回归通过，AMFI实际行为尚未复验。当前来源和探针已停止，t52-v2保持运行；原VM和三副本复核通过。161项证据已归档并逐项校验，消费accepted=false。

2026-10-22 用户已明确批准 .56be1ce20ded 诊断部署及新的900秒/一次附加窗口。归档与冻结脚本摘要核验通过，新版本安装/收据核验、t52-v2正常停机及重绑已完成；已生成绑定本轮完整磁盘SHA的两库维护计划，当前等待macOS管理员认证。新窗口尚未开始，消费accepted=false。

2026-10-22 认证后续推：.56两库克隆事务发布完成，旧盘完整保留，独立只读复核already_current。新实例372C906F-9315-4ED3-B596-94670EEA9AAA/PID98713就绪；独立进程监督的单哈希窗口仅附加1次，69.615秒后结束，辅助和supervisor均独立确认不存在。初始化完整日志确认虚拟源已创建并加入列表，同时代码页修改失败、cameracaptured共享帧open返回EPERM；空设备枚举完整原因未查明。QR仍无可用输入；定位正常授权后仅1条正确回调，60秒双回调未通过。现有API定位对照被owner/generation校验拒绝，保留校验，未直连绕过。启动观察socket竞态已补3项先失败后通过回归，工具组合18项通过。85项本轮证据独立归档，前批161项保持。最终来源off、探针停止；五库/发布端/探针摘要、新旧收据、旧盘身份、原VM和三个副本复核通过。待修复受所有权管理的定位桥接、相机访问与枚举条件，再补消费；accepted=false，无提交或推送。

工具组合的归档后复验：沙箱内真实Unix socket测试失败，独立bind检查返回EPERM；相同18项在沙箱外通过，原断言保持。执行环境与失败结果另存postarchive-validation清单，未改写此前85项证据。

同版本只读指令复核：诊断探针权限与原探针完全相同，实际启动后取得CMCapture UUID56F23E85-0EA1-34F1-AAEC-FFE67067538A的唯一匹配片段。Capstone确认原CBZ W0/CBZ W25分支仍存在、共用跳过目标，与初始化失败位置一致；不据此外推空设备的完整原因。采集后原探针摘要恢复并停止，来源均off；默认和显式诊断构建均通过，证据另存source-filter-readonly清单。仍待功能修复及消费通过。

## 2026-10-22：继续完成相机与定位消费

- [x] 取得同版本只读控制流、完整空设备列表及原生 sourceBackings provider 方法；已据此准备 backing 合并，完整空设备原因仍待真实复验。
- [x] 为 classic 定位发布端接入桥接状态建立实际代码回归并完成修改；来源归属、序列、重试和停止断言通过。
- [ ] 为固定模拟文件提供限定访问，保留应用授权及来源 owner/generation 约束。
- [ ] 构建并核验具名功能候选，按明确部署范围执行真实 VM 定位与 QR 验收。
- [ ] 保留失败证据、旧盘和其他 VM，更新报告和台账。

2026-10-22 功能候选准备：五库、独立 API 和 classic/v2 发布端构建签名通过；候选2.6.2-local.3b5348f496ed封装及Bundle核验通过，宿主VM及Framework字节保持。访问凭据限定相机/定位读取及cameracaptured固定回执写入，真实签发消费待验。新增API状态持续刷新及清除回归通过；七文件离线克隆事务9项回归通过，包含中途失败、恢复、旧盘保留、API缓存/摘要/模式/符号链接拒绝。完整Python首轮987项因LaunchHook夹具漏链接新增C文件出现1错误，修正链接且保持断言，定向22项通过，完整复验进行中。运行t52-v2只读核对仍为旧诊断版本，API/发布端摘要匹配、API缓存不存在；未部署或开启新窗口。五库+API+缓存及新窗口超出此前两库诊断范围，完成具体计划后请求具名批准。见T52_consumer_fix_20261022.md；accepted=false。


最终功能候选改为2.6.2-local.cc05d88f441f，归档872f31e9…04931c83；补齐classic发布端在长宿主心跳期间的存活刷新，保留原generation/序列，停止后不再写入。完整Python995项通过（4跳过）、最终定向36项通过。用户已明确批准五库+API+发布端缓存、完整旧盘保留、临时探针及新900秒单哈希一次窗口。安装首轮store busy拒绝；遗漏force字段的关机RPC被拒绝并使宿主保留pending_recovery，已核实客户机worker_idle且无事务，经系统设置正常滑动关机成功，PID98713退出，原VM33355保持。首次失败记录保留，重试同一归档安装中，未开始窗口。真实消费仍未通过。

T52已安装并核验cc05d88f441f，t52-v2已正常系统关机和重绑。离线只读预检查挂载Data失败；独立卷信息为FileVault=true、Locked=true。未创建写盘事务、未替换客户机组件、未开启原批准窗口。已准备仅System五库/API的完整克隆事务及启动后缓存重命名保留/发布/失败恢复，12项回归通过；修改步骤已具体提交补充批准，VM保持停止。

T52准备阶段133项证据已独立归档并逐项核验，清单evidence/T52-consumer-fix-20261022/prepared/manifest.json。原批准计划和调整计划的冻结脚本摘要复核通过；无本轮待发布磁盘事务，安全窗口未开始，客户机组件尚未替换。当前等待用户对Data锁定后调整步骤的补充确认；已有候选安装及t52-v2正常停止/重绑保持。

2026-10-22 补充批准后，System-only五库/API完整克隆事务已发布，旧盘保留于.environment-history/environment-d27caf08-b214-4b7e-8347-9a0f23400404，独立只读already_current；Data保持未挂载。新实例0C9D0EF5-5072-42CC-B7DD-86096210D871/PID4438已就绪。授权辅助仅一次附加，60.199秒后worker4083和supervisor4079已退出、debugserver不存在；amfid4077仍Ts暂停，当前已请求管理员认证仅发送SIGCONT恢复，不重附加。发布端缓存切换和应用验收等待该恢复及独立核实后继续。


## T52 当前状态：定位通过，QR 设备枚举失败

- [x] 按补充批准完成 System 五库/API 克隆事务及只读复核，完整旧盘保持。
- [x] 单哈希一次附加窗口结束；原 amfid 自行退出，旧认证请求取消，没有 SIGCONT 或重新附加。
- [x] 已保留旧缓存并切换匹配发布端，摘要及新 PID 核验通过。
- [x] 两个定位坐标各 5 条七字段正确回调通过，并按 generation 停止。
- [x] 相机 v3 双层复制回执通过；应用授权状态 3，公开视频设备仍为空，QR 失败证据保持。
- [x] 不重启的实时日志确认普通视频源返回 0；同 UUID 只读 dispatch 解码确认 provider getter 路径。
- [x] 原探针摘要恢复并停止、来源 off；五库/API/新旧发布端、原 VM 和三个受保护副本核验通过。
- [x] 大文件采集及超时恢复 3 项回归、精确进程身份门回归通过；工具全组合 22 项沙箱外通过，保留沙箱失败。
- [x] 一次具名 cameracaptured 重建已获批准并执行：首次探针运行前置拒绝0次信号，停止后核实原身份发送1次TERM，PID809重建；日志已采集。
- [ ] 查明 provider 生效条件，完成真实 QR A/neutral/B 回归，随后更新证据与台账。accepted=false。

详见 research/upstream_integration_2026-10-15/T52_consumer_fix_20261022.md。旧认证问题已完成处理，无需重弹认证。

T52 本轮运行证据 106 项已归档并逐项核验，见 evidence/T52-consumer-fix-20261022/runtime-before-camera-restart/manifest.json；相机重启待补充批准，未执行。

2026-10-23 用户已批准 camera-restart-plan.json 的一次限定重启。首次前置检查发现探针 PID735 运行，发信号前拒绝（0次TERM），已停止该探针；重新核对相机原身份后执行同一批准操作，记录保留于 camera-restart-r1/r2。


## 2026-10-23：T52 nil provider 修复准备完成

- [x] 同版本只读控制流、NSArray/NSMutableArray元数据、应用内原生getter返回nil及初始化日志核对。
- [x] 缺共享实例回归先失败，增加共享getter fallback后5种场景通过；不改原生代码页、全局实例或私有ivar。
- [x] 同权限临时探针实际原生类/fallback/backing构造诊断通过，原探针恢复并停止。
- [x] 单库候选4bd0cce62c46完成签名与Bundle核验，其他库/API/发布端/宿主VM字节保持。
- [x] Python完整1017项（4跳过）、单库事务9项、工具24项通过；沙箱失败及签名首轮失败保留。
- [x] 重建后正式消费复验仍无设备，复制回执通过；来源off，原VM及三个受保护副本保持。
- [ ] 新单库候选部署已请求具名批准，计划 .build/t52-provider-fix-20261023/deployment-plan.json；未安装、未停VM、未开新窗口。
- [ ] 部署后完成真实定位和QR A/neutral/B验收，恢复探针并更新台账。accepted=false。

详见 research/upstream_integration_2026-10-15/T52_provider_fix_20261023.md。

T52 provider修复准备证据179项已归档并逐项核验；部署计划和冻结工具摘要复核通过，新候选安装及新窗口均未执行，等待已发出的具名部署批准。

2026-10-23 用户已明确批准4bd0cce62c46单库克隆部署和新900秒单哈希一次窗口及限定恢复。同一计划、归档、配置和冻结脚本摘要复核通过；开始正常停机。

2026-10-23 执行已批准范围：t52-v2 正常关机、候选4bd0cce62c46安装核验及重绑完成；管理员认证已触发执行冻结单库克隆事务。正式探针三个诊断开关均为0，构建及项目签名完成，尚未部署验收。


## 2026-10-23：T52 本轮应用消费完成

- [x] 用户批准的4bd0cce62c46单库克隆事务及独立只读复核；完整旧盘SHA重新核对通过。
- [x] 新实例定位两点各5条七字段正确回调；QR A/中性帧6.18秒无QR/QR B及v3回执全部通过。
- [x] 同一窗口一次附加，86.345秒后辅助及监督器退出，debugserver不存在；amfid未暂停，无SIGCONT。
- [x] 原探针恢复并停止、来源off、其他组件/缓存和受保护VM核对通过；首次脚本及前置拒绝记录保持。
- [x] 报告、台账及独立运行证据归档。上游整项accepted=false；外置物理卷按此前要求暂缓，业务应用未验。

本轮探针签名拒绝条件、统一相机接口及具名应用消费验收已完成。见 research/upstream_integration_2026-10-15/T52_provider_fix_20261023.md。


## 2026-10-23：推进T32/T33收据、撤销及来源证明

- [x] 核对既有DSC on/off/on与四次启停证据；旧结果仍不证明当前目标或业务运行效果。
- [x] 增加只读当前目标核验：独立挂载、逐项目标内容/元数据、来源关联、签名页、稳定性及身份复核。
- [x] 增加逐声明撤销资格报告，明确合格DSC后缀、需要保留后续操作及不支持/缺原件目标；不扩张写入权限。
- [x] 保存失败能力回归，完成相关测试与真实停机VM只读核验。
- [x] 按证据准备更广撤销或运行效果的具名验收计划；新VM写盘/启动窗口遵守明确授权范围。
- [x] 更新报告、台账和独立证据；不得将历史发布关联提升为受信来源或运行效果。


2026-10-23 T32/T33本轮进度：
- [x] 正式只读当前目标核验与逐声明Undo资格报告；最终16项新回归、相关100项、Swift3项、Python全量1030项通过（4跳过）。
- [x] 当前盘4680/4681匹配，仅AA.gl不同；DSC原件关联和6885签名页通过；发布镜像4681项全部匹配。未放宽校验，原因未查明。
- [x] 包含原盘的12项持久启动文件完整备份，原元数据保持；冻结57项运行准备输入及具体计划，安全窗口未开启。
- [ ] 新窗口和一次GUI运行观察需明确批准；更广撤销/Mach-O/Preboot、受信guest来源和实际补丁运行效果仍未完成。
报告：research/upstream_integration_2026-10-15/T32_T33_installed_effects_20261023.md。

2026-10-23 T32/T33运行诊断已获用户明确批准，计划SHA-256为7e6686ac5232991e13d575e3682258d40d73593f2b839f799517857518bde9a7；批准单独保存在runtime-approval.json。57项执行输入和上一批55项证据复核通过。已请求系统管理员认证；认证完成前未启动VM或辅助窗口。一次观察执行器等待限定窗口就绪，禁止自动重复启动。

2026-10-23 T32/T33批准执行结果：一次GUI/API启动成功，AA.gl首次读取被EPERM拒绝，原观察脚本未继续显示观察；system.shutdown成功、Guest stopped、宿主退出0。单哈希一次附加18.847秒后辅助/监督器退出，debugserver不存在、原amfid未暂停。实际观察失败保持，未重启或重新附加。独立阶段异常处理已修复，两项新回归先失败后通过，4项测试通过；旧执行源码已保留。启动后磁盘只读核验正在等待macOS系统认证，其他VM保持，accepted=false。

T32/T33单次运行诊断36项证据已独立归档并逐项核验，清单evidence/T32-T33-followup-20261023/runtime-approved/manifest.json；包含原执行脚本、实际失败、正常关机及安全收尾、修复后未执行脚本及4项回归。12项原备份及旧55/118项证据复核通过。启动后只读核验仍等待当前系统认证，没有开启第二窗口或重复启动。

2026-10-23 T32/T33启动后只读核验完成：4680/4681匹配，唯一AA.gl在本次受限操作区间内由f92c991d…变为ff2f7d4b…，具体写入者、时点和原因未查明；其余4680目标与启动前相同，6885签名页通过。严格退出1及原基线保持。两卷正常卸载、镜像detach，独立确认目标未附加，审计期间身份与元数据稳定。一次运行诊断结束，无再次启动或附加；设置显示、更广Undo、受信guest来源及补丁运行因果效果仍未通过。报告T32_T33_installed_effects_20261023.md；新增只读证据post-runtime-readonly，accepted=false。


## T32/T33 本次具名诊断收尾

- [x] 一次已批准GUI启动诊断结束；API就绪及正常关机确认，AA.gl读取EPERM、未取得显示帧，失败保持。
- [x] 启动后独立只读核验完成，4680/4681匹配；仅AA.gl内容较启动前变化，6885签名页通过，未放宽基线。
- [x] 正常卸载和detach，独立确认磁盘身份及元数据在审计期间稳定、VM和辅助进程已退出。
- [x] 新增18项只读证据归档并逐项核验；旧55、36和118项证据复核通过，报告及台账更新。
- [ ] 后续显示验收需新的具名启动及辅助窗口授权；本次额度已使用，未重复启动。
- [ ] 更广Mach-O/Preboot撤销、受信guest来源和补丁运行因果效果仍待补。accepted=false。

## 2026-10-23：完成T32/T33（继续实现与完整验收）

- [x] 普通CFW发布保存逐声明/组件实际效果Receipt，并与同一journal/磁盘/plan/generation绑定；旧历史无Receipt保持unknown。
- [ ] 扩展有认证原件的Mach-O/Preboot撤销，完整前像/后续依赖/签名页及原件完整性验证；缺证据明确not_revertible。
- [ ] 补齐受信guest生产者与磁盘/Receipt/来源共同发布和恢复；不得用已安装字节补造受信原件。
- [ ] 完成相关回归、构建及具名真实显示/撤销验收准备。新增VM写盘/启动/辅助窗口须按具体范围批准。
- [ ] 真实验收后更新台账，只有满足原验收条件才登记accepted。

T32/T33完成续推：普通CFW逐声明Guest收据及v5/schema3同journal密封/恢复已实现，旧v3/v4保持兼容unknown；82项宿主隔离回归、最终6项收据专项通过。已准备同generation客户Erase原始rootfs镜像及只读备份比较脚本，等待系统认证；文件级Undo、受信guest来源及真实GUI验收仍进行中，无本轮VM写入/启动/辅助窗口。见T32_T33_completion_20261023.md。

T32/T33收据验证更新：Swift相关构建及3项测试通过。首轮全量1036项有4项新合同夹具断言失败；补全收据交还清单、v5降级拒绝和旧v4运行对照后20项定向通过，最终完整复验进行中（日志python-full-final.log）。Mach-O原件/.bak只读比较仍等待当前macOS认证，尚未执行挂载。

T32/T33：最终完整Python1037项（4跳过）、296.033秒、退出0；Swift3项通过。管理员原件只读比较退出0并正常卸载：三项Mach-O .bak与generation原件内容及元数据相同（45/13/1120代码页），launchd当前原件相同/139页但无.bak；launchd.plist.bak内容相同但GID0≠原件80。文件级Undo需分别绑定内容和元数据，不自动升级旧历史。

T32/T33文件撤销续推：generation只读原件已接入v5同journal密封；普通安装捕获固定Mach-O/数据原件，文件Undo核对完整操作/暂存复制/签名/元数据链并恢复完整原件，旧无证明历史不升级。21项新专项通过，包含实际Preboot plist变长恢复、权限恢复、空保留操作、备份损坏拒绝及交换中断恢复。修复普通patch-build-version已有Preboot目标映射拒绝。相关122项宿主复验仅2项日志文案合同失败（测试加载旧文本及改名），已精确更新；最终完整Python与Swift/隔离CLI构建进行中。无真实VM写盘、启动或新辅助窗口。

T32/T33最终候选f25c0583c438及335项输入冻结，1059项全量Python（4跳过）、3项Swift、release CLI、28项文件/审计定向和2项验收执行门测试通过。新的当前完整盘及12项备份通过。用户明确批准计划cdb74f7a…的离线应用→三项Mach-O撤销→重应用，随后完成macOS认证；真实执行进行中，不启动VM、不启用窗口、不安装或重绑。受信guest来源和GUI运行仍待补，accepted=false。

T32/T33离线首轮已结束：计划cdb74f7a…在任何暂存/安装前被Swift身份门拒绝，全部12项持久文件完整摘要及身份保持、旧335项冻结输入保持、无新事务。最小只读Swift回放定位到20261019T090232Z-27r0QIUW及更早发布缺少postimage/保留盘/blob；缺失发生原因未查明，不补造历史。另修复本轮v5协议漏接Swift身份读取器的问题，v4/v5的16类身份/篡改、3类完整文件Undo和5类写入设置通过，实际元数据与缺历史拒绝两项只读回放确认。

新候选a88440c704e4及340项输入冻结。用户已明确批准新计划f3eabf4a…：保留原VM，仅创建具名新隔离启动状态克隆，经两份已核验IPSW和归档原始ROM正式生成新generation，同语义计划下验三项Mach-O on/off/on；仅允许清理具名8,885,633,024字节解密缓存及新暂存，不启动VM或窗口。当前正在复核输入，随后请求系统认证。旧批准不自动授权新范围，两个批准分别保存。

2026-10-23 新隔离计划340项冻结输入复核通过；当前macOS系统认证进程等待，根执行日志及新副本尚不存在。首轮失败、原VM保留及v5身份兼容修复证据40项已另批归档，全部摘要核验；准备证据119项保持。tasks.json、local_reconciliation.md和progress.md已纠正旧“执行中”状态，accepted=false。

2026-10-23 用户已完成新隔离计划f3eabf4a…的系统认证，原生root执行器已启动，fresh-offline-acceptance目录及根执行日志已生成。执行器先检查具名缓存及磁盘空间，再完整复核原VM的12项启动文件；尚无任何on/off/on通过结论，不启动VM或辅助窗口。

新隔离副本10项启动文件及完整克隆摘要检查通过；正式fresh producer生成generation 34abf58b3c5166e0b393f8e9c53b14deee5835efc4ec561f6629ef0c79c89664，CLI退出0且输出语义计划摘要与批准要求相同。正在克隆新generation原件工作树，on/off/on尚未完成，无VM启动或窗口。辅助非root观察因desired-plan权限被拒绝，未修改其权限或绕过读取；正式root执行器继续核对实际manifest。


2026-10-23 新隔离计划f3eabf4a…实际结束：generation=34abf58b3c5166e0b393f8e9c53b14deee5835efc4ec561f6629ef0c79c89664，语义计划与批准相同；首次CFW已采集generation文件原件，但旧assert_mount_under_vm在SystemOS挂载前拒绝批准的外部工作目录。没有新磁盘发布，三阶段均未计通过；按失败即停止，未重试。两盘均无附件，失败暂存正常卸载并清理，失败journal保留。独立完整摘要确认原VM12项身份/元数据/内容保持，新副本10项启动文件仍与备份相同且inode独立，340项冻结输入保持；两个受保护VM仍运行。正在建立该路径检查的复现及修复；新候选续验需具体方案，原批准不自动重试。accepted=false。


2026-10-23 外部挂载路径修复：实际shell复现3项仅合格外部路径失败，拒绝分支保持。assert_mount_under_vm对外部路径改用现有private_path门：重读冻结计划、继承VM锁、核对journal中mountRoot的dev/inode/uid及无符号链接路径；真实mount-cryptex仍单独核验固定挂载目标、源镜像和generation。16项挂载/工作目录及121项相关shell、计划门、宿主事务和文件Undo回归通过，续验执行门2项通过，语法和空白检查通过。未增加固件、内核或DSC指令补丁。

修复候选2.6.2-local.887b0069c62a封装及签名/依赖闭包/Bundle核验通过，归档SHA-256为55b37cf5f02ed228e4dfda0b423161b7bf7747995db29dc985259eb083777c9a，194647552字节；VM及guest载荷相对基底保持，未安装到Store。新resumed-file-acceptance-plan.json（SHA-256 ba1279954c64ab30712e0e92eb4428c2b222f91d0cf9e621a39ad358f6d7fd95）冻结342项输入，仅拟在同一新副本和新generation上执行一次on/off/on，原12项和新10项完整摘要/身份先复核，每阶段严格独立只读审计；root重新读取实际desired和manifest，正式CLI重新验证完整generation/磁盘身份。允许正式CFW正常清理该新副本的.cfw_temp（含此前失败生成的可重建源缓存）及新暂存，保留原VM、旧盘、generation、失败journal和证据。新候选及失败后的再次执行尚未获准，未重试；不启动VM或窗口，不重建generation、不安装或重绑。受信Guest来源和运行效果仍未通过，accepted=false。

2026-10-23 用户明确批准续验计划ba1279954c64ab30712e0e92eb4428c2b222f91d0cf9e621a39ad358f6d7fd95；342项冻结输入再次复核通过，独立批准标记及用户原文已保存。已排除旧执行/认证进程，发起本次具名系统认证，等待认证后执行。此次只在保留的新副本上验三项Mach-O，无VM启动、窗口、Store安装或重绑；原计划的失败记录和已归档证据保持。

续验系统认证已生效，resumed-root-execution.log已输出完整原VM/新副本基线复核阶段，root执行器运行中；不再等待认证，尚未进入CFW阶段。

续验认证已确认；原VM12项和新副本10项完整内容/身份复核通过，实际root重新读取同generation/同语义计划及归档关联后进入on阶段，候选887b0069c62a在.cfw_disk.xoAlcrnT采集新原件。尚未发布或完成任何一个验收阶段。

2026-10-23 续验进展：on事务20261023T074423Z-xoAlcrnT通过独立只读审计，4681项目标及5项代码页记录核验通过，磁盘摘要与发布记录相同；三项撤销事务20261023T082509Z-gml5bJzX已发布并保留前盘，正在进行独立只读审计及完整原件/签名页复核。尚未执行重应用，整项accepted=false；本轮未启动VM或辅助窗口。

2026-10-23 续验off独立审计及三项完整原件/签名页复核通过，on与off均完成。执行器已进入reapplied阶段的已有发布链核验，尚未完成最终发布/审计和原VM最终完整复核。三阶段全部通过前不计完整文件on/off/on通过；本轮无VM启动或辅助窗口，accepted=false。

2026-10-23 运行观察器独立复验：原4项回归通过。代码核查GuestAPI.apps.foreground总是提供verified字段，旧观察器仅比较bundle_id；新增失败复现中verified=false、缺失、1及字符串true均被错误计为显示通过。修复为要求verified is True并保存原始前台返回，5项回归通过，AA.gl拒绝仍保留失败并继续显示检查。该观察器不属于当前离线冻结输入，未用于本轮VM运行，也未开启新窗口。日志runtime-foreground-red.log/runtime-foreground-green.log。

2026-10-23 续验重应用进展：SystemOS与AppOS均已在批准的外部工作目录正常只读挂载，进入实际Cryptex安装；最终发布、第三阶段独立审计及原VM最终完整复核尚未完成。归档工具已补入保留检查和运行观察器来源，只在执行结束后归档；未修改342项冻结输入。

2026-10-23 后台收尾已启动：finalize_t32_resumed_acceptance.py，PID 37530，已固定原执行器PID 50959及15:42:15启动身份，状态waiting-existing-native-run。仅在该原进程结束并产生结果后核对三阶段、原VM最终完整复核、342项冻结输入、目标挂载和受保护VM；随后更新completion_20261023及证据归档。成功归档要求保留检查全部通过。失败停止并保留记录，不启动/重试原生事务、VM或辅助窗口。工具语法和差异空白检查通过，后台状态已读回；实际收尾尚未执行。当前Cryptex源镜像已正常卸载，重应用进入SwapEnd补丁处理。

2026-10-23 继续T32/T33：已确认root50959和收尾37530仍运行，重应用第5/7阶段。完成新prepare_t32_completed_runtime.py准备入口，需三阶段完整成功、收尾及归档通过后，才能持锁备份实际reapplied磁盘并生成新GUI计划；未启动VM。前置拒绝实际验证，运行观察器5项通过。Preboot build-version真实生产入口仅EXP，当前regular/classic不覆盖；可信Guest来源桥接、Preboot实际验收及GUI仍待完成。

2026-10-23 后续运行准备已接续：PID 65121以--wait-and-prepare-only等待收尾37530，仅在offline-acceptance-finalized后执行一次只读备份/计划生成；失败或等待超时停止，不自动重试，不启动VM或辅助窗口。预期磁盘身份包含观察器要求的ctime_ns，配置路径检查与Swift清单解析路径一致。新工具不在342项原生冻结输入内；不得在进程等待期间修改该工具。可信Guest来源桥接仍未实现，不能由该准备或运行计划抬升来源资格。

2026-10-23 续验计划ba127995…已结束，结果为失败；保留已通过阶段和原始失败记录，没有自动重试、回滚、VM启动或辅助窗口。错误：Reapplied target differs from the first on state: system:/usr/libexec/seputil。T32/T33整项accepted=false。

2026-10-23 签名差异已定位并独立核验：相同签名前输入和参数经ldid产生不同CMS signingTime及其签名值。三项文件的CMS以外全部字节、证书、算法、其他签名属性和安装元数据一致；六份CMS密码学校验及全部代码页通过。原始完整文件字节相等验收继续失败，不改写旧记录。新增独立CMS核验6项回归通过，包含有效/无效时间篡改、签名损坏、证书/字段修改及代码改变的拒绝。独立保存证据核验同时确认原VM12项完整内容/身份、342项冻结输入及66项旧归档保持。无新挂载或VM写入。

同一隔离副本10项启动文件的完整备份已核验；completed-runtime/runtime-plan.json已准备，SHA-256 8f47f172215467fc7f9aef31c464ae71b1709acdd0b59e32ff9587e3462e5621，冻结365项工具/证明，资格明确为原件精确恢复+CMS签名时间差异的密码学校验，原完整字节验收仍失败。计划仅拟一次GUI/Settings显示与AA.gl摘要观察，原窗口已消耗，新计划尚未批准、未启动VM或辅助窗口。AA.gl既有EPERM继续保留为失败，不能由显示通过覆盖。可信Guest来源桥接、真实Preboot数据撤销及运行效果仍未完成，accepted=false。

2026-10-23 用户明确批准GUI诊断计划8f47f172…，独立批准标记及用户原文已保存。365项冻结工具、备份清单及当前磁盘身份复核通过；将通过系统认证执行一次root窗口准备，单次附加就绪后自动运行冻结GUI观察器。无重试，不安装CFW或客户机程序，完成或失败触发停止标记。

2026-10-23 GUI计划8f47f172…已消耗一次启动和一次辅助窗口，结果失败：宿主在启动后报告invalid or oversized socket path，未进入API/显示及AA.gl观察。目标vphone.sock路径为124字节，macOS sun_path仅104字节含终止符。宿主requestStop超时后自行执行框架停止，正常关机未通过。独立确认VM/worker/supervisor及debugserver均已退出；辅助20.348秒、一次附加、无持久名单，amfid身份保持且未暂停，不需SIGCONT。10项完整启动备份、原VM12项完整内容/身份及365项工具复核通过，目标无挂载。没有重试或回滚。accepted=false。

2026-10-23 套接字前置检查已修复：根窗口准备及GUI观察器在启动前按Darwin sockaddr_un的104字节容量（含NUL）检查UTF-8长度；实际长路径bind拒绝、根入口不能先启动helper及字节边界回归由红转绿，含原观察器共8项通过。新短路径诊断副本.build/t32r-20261023从保留的启动前完整备份准备，10项完整摘要与源相同且inode独立，不复制generation/journal/binding资格，不改变故障副本或旧历史；尚未启动。新socket含NUL64字节。新计划short-runtime/runtime-plan.json，SHA-256 12b5f5aecd6ae878587521ee20204ce91e710e5ba6c8ec6e5ff303b0530f69f3，368项工具及wrapper路径已复核。计划显式请求允许仅该新诊断副本宿主自身在致命错误/停止超时时的requestStop→框架停止回退，并将回退计正常关机失败；无agent强停/杀进程。新启动和新窗口尚未批准。来源桥接、Preboot实际验收和运行效果仍待完成，accepted=false。
