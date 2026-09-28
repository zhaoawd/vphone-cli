# 上游与本地仓库对比分析

更新日期：2026-09-28。当前目标为上游 `2.0.8`，固定提交 `9d218dedf58d4b19db5e51c8b584c1f14a96eee3`。本文根据用户提供的[9 月演进与能力评估](<../docs/vphone-cli_2026年9月演进与能力评估_截至2.0.8.docx>)修订，并核对该 tag 的关键源码及发布说明。附件的迁移建议作为分析材料，不作为执行升级的指令。

结论：继续选择性迁移。第一批已修正本地 NVRAM 覆盖与克隆启动状态清理行为，真实 VM 验收待完成；2.x 迁移同时接入认证、受控安装、配套资源和应用层定位。保留本地多变体、检查点续跑、锁、自动化合约及补丁约束。上游将原 EXP 变化并入公开流程，不能直接复制为本地 JB 默认行为。

本文与[融合实施计划](upstream_implementation_plan.md)同步维护。随后第一批 P1c 已应用到工作区并通过无固件测试与构建，见[整合记录](p1c_batch1_2026-09-26.md)；未执行固件补丁或原 VM 升级；已在停机 VM 的独立副本上验证连续启动和 clone 启动，导入后启动仍待验收。历史全文保留在 Git；上一版详细结论见[08db376 基线报告][history-08]。

2026-09-28：按用户要求跳过 P1c 真实导入及导入后启动验收，保留未验证状态。P1a 两个 catalog 条目和兼容性清单、P1b 六站点预检查及混合状态处理已应用；详见 [P1a/P1b 整合记录](p1ab_integration_2026-09-28.md)。P1b 真实 DSC 验证仍未完成。P2 已接入 VPhoneSign、VPhoneArchiveKit 库和显式 CLI；可选原生 VM 传输和 IPSW 检查/缓存接口也已接入，见 [P2 第三批记录](p2_transfer_integration_2026-09-28.md)；原生固件准备、Restore 等模块及 P3–P8 待推进，见 [P2 第一批记录](p2_sign_integration_2026-09-28.md)及 [第二批记录](p2_archive_integration_2026-09-28.md)。

## 1. 固定基线与证据范围

| 对象 | 版本或结果 |
| --- | --- |
| 当前分支 | `codex/upstream-4bab3b7-integration`；分支名称不代表当前实施目标 |
| 本次本地起点 | `bc3bfa83ee8d3397e1caa08ce580e24407de17cd` |
| 新上游目标 | tag `2.0.8` → `9d218dedf58d4b19db5e51c8b584c1f14a96eee3`；tag 对象 `03b6bbe72838f6393e7335e42f2e8134e5566ab8` |
| 上一版目标 | `08db376d9417a7ec0779967d6b2e748e3638d3c6`，位于 `2.0.0` 之后，仅其最后一个提交修改 CI |
| 本次上游增量 | `08db376..2.0.8` 共 53 个提交，其中 47 个非合并提交 |
| 历史共同祖先 | `87f796c62a7cb385cd37afce121f6e222d83e5b5`，即 `1.0.13`；本批重新核对，仍为双方 merge-base |
| 1.x catalog 来源 | `1.0.14` → `9c23c8adcd4b362120988ab9d228b959bcc23ae3` |
| 本地代码变化 | `9489ab2..bc3bfa8` 仅文档；本次整合提交包含 P1a/P1b/P1c、P2 Sign/Archive、可选原生传输和 IPSW 接口 |

方法：读取附件正文和来源索引；在线核对 2.0.5、2.0.6、2.0.8 发布说明；在临时裸仓库取得 2.0.8，按指定目录导出源码，排除根目录 `TODO.md`。本次核对资源布局、7 份 lockfile、权限处理、创建拒绝路径、NVRAM、克隆、CFW 占用判断、定位、guest 同步和 Bootstrap 轮询。未修改当前仓库 remote、分支或索引；生产代码随后增加 P1c 与 P1a/P1b 整合，详见对应整合记录。

证据分为本次源码核对、上游研究记录、本地历史验证和待执行验收。源码存在不代表运行通过；上游 Maps、相机传输和固件组合记录均不提升为本地 2.0.8 组合通过。

### 1.1 上游 tag 与版本线

| 版本 | 本次使用的结论 | 证据 |
| --- | --- | --- |
| 1.0.14 | 继续作为 catalog 独立修正来源；导入 manifest 校验本地已实现 | [历史 tag 核对][history-08] |
| 2.0.0 / 08db376 | 原生化、进程拆分、v2 格式和 HTTP/WS 的历史基线 | [历史报告][history-08] |
| 2.0.4 | 早期发布截面，不包含之后的安全加固 | 附件第 2、8 章 |
| 2.0.5 | 安全修复已进入发布，新增应用层定位、Restart Guest 和本地核心包安装入口 | [发布说明][release-205] |
| 2.0.6 | 修复 NVRAM 与克隆；Core Bundle 曾同版本替换以补入 CFW 占用误报修复 | [发布说明][release-206] |
| 2.0.8 | `vphone-escalator` 命名、Launchpad 最低核心包版本与 Bootstrap 状态修复 | [发布说明][release-208] |

固定输入使用 tag 对应的完整 SHA，不在实施途中切换浮动 `main`。成套验证基线为 Launchpad 2.0.8 与 Core Bundle 2.0.8；最低可选版本约束与 VM schema 分别检查。版本号不能唯一标识同版本替换的分发产物，下载包需另记 SHA-256。本报告不推断 2.0.7 的独立变化，也不评估 2.0.8 之后版本。

## 2. 当前整体差异与本地保留范围

| 模块 | 本地实现或现象 | 2.0.8 结果及整合决定 |
| --- | --- | --- |
| 构建与交付 | SwiftPM、Makefile、独立测试 runner | Xcode、完整 Core Bundle 与独立 Launchpad；分阶段接入，保留测试入口 |
| 进程与权限 | CLI 包含 VM/UI；PID 加启动时间、VM/库锁 | `vphone-vm` 持私有权限，Launchpad helper 受控执行；本地停止身份与排他保护继续保留 |
| 启动状态 | 基线每次以 `allowOverwrite` 创建；P1c 已改为打开已有存储 | 无覆盖创建/拒绝非法类型测试通过，独立副本连续启动通过，导入后启动待验收 |
| 克隆 | P1c 已保留持久状态，使用暂存校验和持锁发布 | 运行中拒绝、目标竞争、复制回退与导入导出测试通过，clone 启动通过，导入后启动待验收 |
| VM 格式 | manifest 无 `schemaVersion` | v2 加载要求不变；旧格式另建，新宿主最低版本不等于新增 schema 迁移 |
| 固件变体 | regular/dev/jb/exp/less，默认 regular | 上游公开单一补丁集包含原 EXP；本地继续保留变体与 EXP 作用域 |
| 创建与产物 | 七阶段 runner、resume/status、指纹与保留规则 | 原生后端与 Launchpad 分阶段流程不能替代本地检查点及 first-boot finalization |
| 补丁 | PatchOutcome、必需步骤、事务、消融 | 逐补丁比较相同输入和失败行为，不能由语言、目录或内部枚举推断等价 |
| 控制协议 | 1337 长度前缀 JSON、宿主 Unix socket | 1339 HTTP/WS，外部 TCP 有 Token；旧协议保留独立路径，本地同用户检查继续保留 |
| 定位 | owner/generation/sequence 与持久化 | 新增 SystemHook 加载 libvlocation；保留本地所有权协议，增加 App 授权、重启和业务读数验收 |
| 相机 | 本地 256 字节头、发布身份和消费回执 | 上游补齐加载及环境更新，但完整应用验收仍缺；必须成套核对 wire、共享内存和 hook |
| 用户环境 | 既有 Procursus、SSH/tweak、JB/EXP finalization | 上游基础流程不默认装包管理器、SSH/VNC；Irisin 保持可选，不接管未知已有环境 |

### 2.1 本地状态问题与修正范围

在 `bc3bfa8` 基线中，[本地 VM 初始化](../sources/vphone-cli/VPhoneVirtualMachine.swift)调用 `creatingStorageAt` 并传入 `.allowOverwrite`。[本地 clone](../sources/VPhoneCore/VPhoneBundleOps.swift)复制后调用 `resetIdentity`，删除 `nvram.bin`、SHSH、预测文件和运行状态，并清空 machine identifier；SEPStorage 随目录保留。该基线的[clone 测试](../tests/VPhoneCoreTests/BundleOpsTests.swift)明确断言身份被清除。因此，APFS 快速复制已完成，不等于启动状态保留已完成。

2.0.8 的[VM 初始化][vm-208]先校验 NVRAM 为普通文件，存在时打开，不存在时无覆盖创建；仍写入特定 boot-args。其[clone][clone-208]保留完整目录。本地应吸收持久状态语义，继续保留源 VM 锁、运行中拒绝、EEXIST 不删除他人目标等保护。宿主 PID、socket、锁和运行状态属于需要单独处理的临时信息，不应随持久身份复用。

第一批已将上述 NVRAM 和 clone 语义应用到当前工作区，更新旧测试并新增 21 项测试；独立副本连续启动与 clone 启动已通过，导入后启动尚未验收。P1c 的目标是可重复启动的状态副本，不承诺独立设备身份。独立身份使用新建与恢复流程；不能仅清除部分身份就宣称得到新设备。修复不会找回此前已丢失的状态。本次启动结果只适用于整合记录中的 VM 与宿主组合，不推导其他固件或变体。

### 2.2 固件组合与补丁范围

上游[兼容性文档][compat-208]保留 PR #486 的 26.6.2/23G90、27.0/24A435 配对 cloudOS 26.4/23E5207q 的 JB、恢复、CFW、锁屏与 ping 记录，另记 26.6.2 全新创建成功。该历史记录不自动覆盖后续全部 Hook、认证、定位和最终分发产物。

[创建指南][create-208]已明确公开补丁集包含原 EXP 变化且不可选变体；pipeline 仍有内部枚举。不能把内部 `.jb` 当作与本地 JB 相同的补丁集合。本地 P4 先列出 Kernel、DeviceTree、DSC、CFW 变化到各变体的映射，再建立显式 v2 测试组合。EXP 专属变化不得进入本地 regular/dev/jb/less 默认路径。

上一轮“50 个内核文件内容未变”仅适用于 `4bab3b7..08db376`；本次未做 kernelcache 指令、符号或逐补丁行为分析，不外推到新目标。catalog P1a 与相机 DSC P1b 保持独立；新补丁实施时更新 `research/0_binary_patch_comparison.md`。

## 3. 相对 08db376 的结论修订

| 问题 | 原结论范围 | 当前结果与计划调整 |
| --- | --- | --- |
| TCP 认证 | 08db376 无认证 | 2.0.8 宿主代理有 Token，guest 有 Origin/Host 检查；P5 改为移植、适配和负向验收 |
| 创建拒绝后的权限 | 08db376 在检查已有目录前注册权限 defer | 2.0.8 已先拒绝再注册，且仅遍历本次创建的 bundle；保留本地回归要求 |
| 递归权限 | 不接受 `0777` | 新版增加描述符遍历和所有者限制，但仍执行 `0777`；保留拒绝该权限策略的决定 |
| 核心包工具 | `VPhoneEscalator` | 改为 `vphone-escalator`，没有旧名回退；P2/P3 同步清单、校验和调用者 |
| guest 资源 | 旧 bundle 布局与签名暂存方式 | `Contents/Resources/guest-resources` 中的预签名 vphoned 和 dylib；P2 按新布局接入 |
| 定位验收 | IcliKit 系统模拟路径 | 新增应用层覆盖；P4 提供基础 SystemHook，P5 验证目标 App，P6 只处理可选用户环境 |
| 固件变体 | 公开 JB 流程，保留本地多变体 | 上游已并入原 EXP；P0/P4 增加逐变体映射，禁止直接接入上游默认集合 |
| 克隆与启动 | 已有 APFS clone | P1c 代码修正、回归和构建已完成，clone 启动通过，导入后启动待验收 |
| Bootstrap 完成状态 | 一般安装与状态验收 | 增加轮询取消并等待、迟到结果和重试代际用例 |
| Launchpad | 原报告主要评估 VM 内 UI | 单独评估核心包存储、收据、helper、日志和管理器退出行为，列入 P3/P7/P8 |

## 4. 新增变化与本地影响

### 4.1 Xcode、bundle 与依赖

[集成指南][bundle-208]将 Core Bundle 定义为完整容器：宿主程序位于 `Contents/MacOS`，iOS 载荷位于 `Contents/Resources/guest-resources`。只分发预签名 vphoned，不包含未签名副本、签名脚本或 entitlement 文件。上层程序负责安装、验证、授权和更新，不能就地改写签名二进制；VM 更新后需处理新 cdhash 的 AMFI 准入。

本次核对共 7 个 `Package.resolved`，比旧目标增加 Launchpad 工程。workspace 和 daemon 的 IcliKit 为 0.6.9（`74843a56df54936c3949239a4ffb3ddcbe37dee4`），SwiftNIO 为 2.83.0，Collections 为 1.6.0；Virtualization 独立工程为 Collections 1.7.0。ArchiveKit 依赖 libarchive.xcframework 1.0.0，原生恢复依赖 AppleMobileDeviceLibrary 1.0.1790243523。具体构建入口决定依赖解析范围，不能只复制一份 lockfile；本次未运行 Xcode 解析或构建。

P2 增加 Launchpad、helper 和全部 guest 资源清单。Makefile 和 `scripts/run_tests.py` 保留至替代入口验收。上游构建、bundle 校验和手动 CI 打包不能替代本地 fast、firmware、VM 和应用验收；未签名 CI Launchpad 也不等于公证分发包。

### 4.2 提权与宿主文件权限

[核心包存储][store-208]由 root 管理，安装收据记录二进制 cdhash，helper 执行前校验；最低版本为 2.0.8，并处理 `-local` 后缀。Launchpad helper 与核心包中的 AMFI 工具职责不同，Core Bundle 自身仍不负责弹密码框或自动提权。集成本地构建时也必须走校验流程，不能替换已安装二进制来取得特权执行。

[权限函数][permissions-208]使用描述符相对遍历、`O_NOFOLLOW`、设备及 inode 检查，跳过多硬链接普通文件；root 下限制所有者。但其准入文件和目录仍被设为 `0777`。因此吸收路径与竞争防护，保留本地明确 mode、socket `0600`、同用户检查和所有权策略。

[creator][creator-208]已在权限 defer 前检查 `alreadyExists`，并以 `createdBundle` 限制遍历。本报告撤销“新目标仍会在已有 bundle 拒绝路径上放宽权限”的判断。非 sudo 与新产物权限仍需本地负向测试。

[CFW 安装器][cfw-208]持有验证过的磁盘描述符后解析 lsof PID，排除自身，其他进程占用仍拒绝。迁入时保留本地 bundle 锁及停止身份校验；验证停机安装不会被自己误报，外部占用仍被拒绝。

### 4.3 HTTP 与 WebSocket 认证及重连

按[2.0.8 API 文档][api-208]，Token 校验位于宿主 TCP 代理；直接 VSOCK 客户端与 guest 检查应分别处理。代理启动生成 Token，也支持 `VPHONE_API_TOKEN`；HTTP/WS 可使用 Bearer，WS 还支持 query 或子协议传递。guest 拒绝带 Origin 或不允许的 Host 请求。这不等于每个 VSOCK 请求都使用相同 Bearer 校验。

P5 保留本地 Unix socket 同用户合约，接入认证、凭据传递、日志脱敏与连接重建；覆盖缺失/错误 Token、非法 Origin/Host、过大请求头和传输边界。Token 随代理重启的变化与 guest 重启分开测试，不能假设两者总是同步发生。非 loopback 入口仍保持默认关闭，`force` 不替代认证。

Restart Guest 可能先断开再返回。完成条件为断线后重新连接、health 和应用操作恢复，不要求原重启请求必然返回完整响应。继续保留 E1–E4 的期限、取消、迟到响应、会话代际和整次手势路由。扩展方法清单按源码维护，不沿用 API 文档残留的旧 SwiftPM 产品名。

### 4.4 应用层定位与 guest 同步

上游[定位记录][location-208]描述 iOS 26.4 中系统请求成功但 Maps 无位置的现象，并记录新增覆盖后 Maps 蓝点移动及重新启动后加载成功。这是上游单项应用验证，未覆盖本地所有固件和业务 App。

[libvlocation][location-hook-208]由 SystemHook 装入新启动 App，检查坐标有效性及 CLLocationManager 授权；[guest 同步清单][environment-208]包含该库。`delivery: application_override` 表示已发布覆盖坐标，不是逐 App 回执。系统模拟仍为尽力执行路径。宿主升级、guest 同步、guest 重启和 App 重新加载必须分别记录。

依赖调整：P4 在显式 v2 路径安装并验证基础 SystemHook 与 libvlocation，P5 执行 set/clear、所有权乱序、权限拒绝、App 重启、门店/距离等业务验收；P6 才安装可选 Irisin。基础 Hook 不依赖安装包管理器，不自动替换已有 Procursus 或本地 `/b`。任何本地替代加载方案都需给出实际加载证据。

### 4.5 相机与可选 Irisin

2.0.8 已包含无 bootstrap 加载相机 Hook 和运行时环境同步的实现；[相机记录][camera-208]仍区分传输与 Camera.app 预览、拍照、录像。新增 CoreMedia 数据处理不能代替应用验收。上次核对的 64/256 字节共享头差异、发布身份和 observe 回执仍是迁移检查项，实施前按最终目标重核完整 ABI。

P5 成套验证宿主、daemon、hook、像素起始位置、消费回执、停止、源切换、照片内容、录像及第三方 App。P1b 的六目标预检查、混合输入与页面哈希验证继续保留；新目标的 DSC 算法等价性未在本次确认。

Irisin 仍作为独立新建测试副本中的可选环境。固定实际 tag、架构、URL、SHA-256；rootless/RootHide、服务、tweak、卸载和重启分开验收，不接管未知安装。[Bootstrap 菜单][bootstrap-208]已取消并等待轮询任务后写入最终状态；本地增加迟到结果、失败后重试与关闭窗口的状态回归。[Irisin 完成标记][irisin-208]已改为可写数据卷的 `/private/var/db/vphoned/bootstrap.json`，保留旧 `.vphoned-boostrap-completed` 读取；P6 同步新旧标记策略。基础 SystemHook 加载验证属于 P4，可选 bootstrap 注入兼容验证属于 P6。

### 4.6 性能和生命周期证据

附件记录特定 DSC 实验 physical footprint 约 3419 MB 降至约 13 MB，RSS 仍约 1.1 GB；vphoned 代理与 I/O worker 拆分也有上游记录。这些数值不作为本地验收阈值，不代表整台 VM 内存需求。P2/P5 核对 daemon 代理、worker、launchd 和退出联动，P8 使用最终产物重测 F3。

Launchpad 将 VM 输出持久化到日志文件，需在 P7 测试关闭管理器、继续运行 VM、重新打开管理器和日志访问。管理器创建阶段显示不等价于本地 checkpoint/resume，VM 进程仍按本地身份和锁管理。

## 5. 职责映射与实施边界

| 本地入口 | 2.0.8 入口或职责 | 保留要求 |
| --- | --- | --- |
| `Package.swift`、Makefile | `VPhone.xcworkspace` 及子工程 | 构建包装、全部测试入口与 fast/firmware 隔离 |
| `sources/VPhoneCore` | `VPhoneKit/VPhoneCoreKit` | 锁、检查点、停止身份、完整状态与诊断 |
| `sources/vphone-cli` | `VPhoneExecutable/VPhoneCommand/VPhoneCommand`、`VPhoneExecutable/VPhoneVirtualization/UI` | 多变体、resume/status、headless 和 API 合约 |
| `sources/FirmwarePatcher` | `VPhoneExecutable/VPhoneCommand/FirmwarePatcher` | 逐变体补丁范围、结构化结果、事务与消融 |
| Python restore、外部归档/签名 | 原生 VPhoneRestore、VPhoneArchiveKit、VPhoneSign | DFU owner、错误/取消、staging、路径和元数据校验 |
| `scripts/vphoned`、guest 资源 | `VPhoneDaemon`、`VPhoneGuestComponents` | 代理/worker、协议、签名、加载和同步分别验收 |
| Unix socket 客户端 | `VPhoneKit/VPhoneExternalAccessKit` | 可并存，不替换旧客户端合约；新增 Token 适配 |
| 现有 VM 管理 | `VPhoneLaunchpad` 与受限 helper | 核心包验证、日志、管理器与 VM 生命周期分离 |

## 6. 历史合并模拟与本次限制

本批已在临时裸仓库重跑 `bc3bfa8 × 9d218de` 的 merge-tree，得到 243 个未合并路径，退出 1；共同祖先不变。完整目录差异统计尚未重做。上一轮[冲突清单](upstream_review_08db376_conflicts_2026-09-25.txt)使用本地 `9489ab2`，对 `4bab3b7` 为 318 个未合并路径，对 `08db376` 为 277 个；57 个增量提交、171/187 个双方独有提交及旧文件/行数均只适用于上一轮输入。

不能将上述计数改写为 2.0.8 的结果，也不能将冲突数量作为工作量。P0 继续完成逐变体映射和模块依赖；继续拒绝因修改/删除冲突而删除本地能力，研究文档保留本地组织方式。

## 7. 保留决定与优先级

1. P0 固定对象、合并模拟和测试基线已完成；继续补齐模块清单、逐变体/ABI 和完整备份。夹具本批复查仍缺 17 文件。
2. P1c 代码和无固件验证已完成，签名 app 临时按 cdhash 放行后，连续启动和 clone 启动通过，导入后启动待验收；P1a catalog、P1b EXP 相机 DSC 分别提交，不等待 2.x。
3. P2/P3 提前处理完整资源、7 份 lockfile、helper、收据、签名和权限；保留本地排他与恢复身份。
4. P4 新建显式 v2 测试镜像并建立基础 Hook；先确定逐变体映射，不将上游合并的 EXP 自动加入本地 JB。
5. P5 完成认证、重连、本地控制合约、应用定位与相机分项验收；P6 仅安装可选 Irisin。
6. P7/P8 完成管理 UI、最终分发和 F1/F2/F3；旧环境保留到新组合验证完成。

## 8. 本次验证与未验证范围

| 检查 | 状态 |
| --- | --- |
| 附件、发布说明、2.0.8 tag/commit 与 53/47 提交计数 | 本次已核对 |
| 本地 NVRAM、clone 及测试 | P1c 已整合；新增 21 项通过，原生 clonefile 检查通过；连续启动/clone 启动通过，导入后启动待验收 |
| 关键源码与 7 个 lockfile | 本次已核对；具体范围见第 1、4 节 |
| merge-tree、全量差异、逐补丁和 ABI 对照 | 新目标模拟为 243 个未合并路径；其余项目继续完成 |
| 工具链与夹具 | 本批复查 Xcode 26.4、Swift 6.3，默认夹具仍缺 17 文件 |
| 本地测试、构建与执行 | 9 月 28 日 make test：Python 369 项、Swift Testing 497 项，XCTest 145 项（3 项跳过、0 失败），内存回归通过。此前 P1c make build/bundle 校验及临时 cdhash 执行通过；本轮未重建签名产物，未构建上游 2.x |
| P1a/P1b | P1a 目录/清单、CLI JSON 和菜单选择通过；P1b 17 项合成 DSC 回归通过，真实 DSC 未验收 |
| P2 Sign | SwiftPM 库/CLI 和 25 项上游测试、5 项本地集成及 2 项 CLI 测试接入；完整 Swift Testing 529 项通过 |
| P2 Archive | 原生库、CLI、固定依赖和许可证已接入；归档相关 32 项通过；最终完整 Swift Testing 561 项、XCTest 145 项（3 跳过），签名构建通过；VM 传输后端保留 |
| P2 VM 传输/IPSW | 原生传输通过显式参数接入，默认仍为 system-tar；本地 IPSW 检查、缓存 API 和导入发布检查已接入，见第三批记录 |
| 恢复、连续启动、克隆、双 VM、定位、相机与业务 App | 本轮 P1a/P1b 未运行；此前 P1c 副本启动证据见记录，上游或本地旧证据不替代新组合验收 |

## 9. 修订记录

| 日期 | 修订 | 证据 |
| --- | --- | --- |
| 2026-09-24 | 建立 4bab3b7 分析和计划 | [历史复核](upstream_review_2d76f81_2026-09-24.md) |
| 2026-09-25 | 更新至 08db376，调整为 P0–P8，补充 tag、lockfile 与权限结论 | [上一版全文][history-08]、[冲突清单](upstream_review_08db376_conflicts_2026-09-25.txt) |
| 2026-09-26 | 根据附件推进到 2.0.8，前移状态修正，更新认证、权限、EXP 范围、定位依赖和配套验收 | 本文固定源码与发布引用；实施计划同步修订 |
| 2026-09-26 | 第一批 P1c 应用；P0 基线与 243 路径模拟完成，临时放行后连续启动和 clone 启动通过，导入后启动受空间限制 | [整合记录](p1c_batch1_2026-09-26.md) |

[history-08]: https://github.com/zhaoawd/vphone-cli/blob/bc3bfa83ee8d3397e1caa08ce580e24407de17cd/research/upstream_comparison.md
[release-205]: https://github.com/Lakr233/vphone-cli/releases/tag/2.0.5
[release-206]: https://github.com/Lakr233/vphone-cli/releases/tag/2.0.6
[release-208]: https://github.com/Lakr233/vphone-cli/releases/tag/2.0.8
[vm-208]: https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/VPhoneExecutable/VPhoneVirtualization/UI/VirtualMachine/VPhoneVirtualMachine.swift
[clone-208]: https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/VPhoneKit/VPhoneCoreKit/Bundle/VPhoneBundleOperations.swift
[compat-208]: https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/Documents/Guides/compatibility.md
[create-208]: https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/Documents/Guides/create-and-run.md
[bundle-208]: https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/Documents/Guides/bundle-integration.md
[store-208]: https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift
[permissions-208]: https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/VPhoneKit/VPhoneCoreKit/Process/VPhoneHostFilePermissions.swift
[creator-208]: https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/VPhoneExecutable/VPhoneCommand/VPhoneCommand/VirtualMachine/VPhoneVirtualMachineCreator.swift
[cfw-208]: https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift
[api-208]: https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/Research/vphoned_http_api.md
[location-208]: https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/Research/Guest/location_simulation_26_4_failure.md
[location-hook-208]: https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/VPhoneGuestComponents/LocationFix/libvlocation.m
[environment-208]: https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestEnvironment.swift
[camera-208]: https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/Research/Guest/virtual_camera_transport.md
[bootstrap-208]: https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/VPhoneExecutable/VPhoneVirtualization/UI/UserInterface/Menu/VPhoneMenuBootstrap.swift
[irisin-208]: https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/VPhoneDaemon/Daemon/GuestIrisinInstaller.swift
