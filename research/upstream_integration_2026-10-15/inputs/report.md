# vphone-cli 上游新增变动与合并计划更新依据

**核对日期：2026-10-14**  
**范围：`2d21d21fbdd4f51f013616273ceda9b35a3e0789..8a75092013eda87a4e30ed029b72028cb9279ac4`**  
**基线不包含在新增段内；终点包含。目标为本轮读取到的 main HEAD，同时是 2.9.4 发布锚点。**

## 1. 结论、范围和证据边界

本轮不是“给旧计划再加几个 bugfix”，而是增加了模板化创建、独立身份克隆、停机快照、磁盘块重整、系统精简和更多 guest 管理协议；同时修复了 Xcode/DeviceHub/Flutter、生命周期、磁盘占用判断及多组件运行问题。[S01–S11]

对上游公开提交历史逐页核对，从目标回溯到基线，共列出 **194 条新增记录：51 条 merge 记录、143 条其他记录**，全部放在本文附录及 `commits.json`、`commits.csv` 中。交叉核对：2.6.1 发布页显示其后 198 条提交；其中 `86f1f88`、`4ca183a`、`da11793`、`2d21d21` 四条已属于旧基线，198−4=194。该统计来自 GitHub 历史枚举及发布页校对，**不是本轮实际执行 `git rev-list` 得到的结果**。[S01–S03]

本轮已完成：公开历史枚举、各发布阶段核对、关键 PR/提交和固定目标文档阅读、daemon 依赖锁两端比较、旧 47 项任务映射及新增任务建议。没有取得用户实时 fork，也没有成功取得可在当前运行环境执行 Git 审计的上游对象；因此没有给出未经证实的全量变更文件数、增删行数、完整 endpoint patch，也没有声称已经审查每个 merge 的独立冲突解决。本包附只读 Git 审计程序，补齐这些机械证据并反查枚举遗漏；源码和 VM 均未被本轮修改。

**“上游新增”“本地缺失”“本地已验收”是三件事。** 既有 2026-10-06 方案中的 47 项、历史批次成果与未完成项继续保留；本轮 `pending_local_audit` 只表示尚未对新目标做本地对账，不把旧完成项改回未完成。

### 固定版本与发布阶段

| 阶段 | 发布锚点 | 日期（GitHub 显示的发布日） | 主要新增范围 |
|---|---|---|---|
| 旧比较终点 | `2d21d21` | 2026-10-06 | 2.6.1 之后；console 性能和 helper 中文修正已在基线中 |
| 2.7.0 | `f755645` | 2026-10-07 | DeviceHub、新身份克隆、快照、统一退出关机、可选 Settings 行隐藏 |
| 2.8.0 | `65a0e9b` | 2026-10-08 | 定位、设备名、安装注册、登录提示、每机 CFW 并发、IPSW 管理 |
| 2.9.0 | `328ff74` | 2026-10-09 | 模板、精简、rebase、运动传感器、下载和磁盘工具链 |
| 2.9.1 | `a2e964f` | 2026-10-09 | 首启与空闲优化、姿态修正、剪贴板、右键、ProMotion 默认值、UI 重整 |
| 2.9.2 | `da6906f` | 2026-10-09 | 导入队列、进度断管处理、退出等待传输清理 |
| 2.9.3 | `6af3fe9` | 2026-10-12 | 时钟、RootHide 路径、前摄、board-presenting iPhone、IcliKit 0.8.0 |
| 2.9.4 | `8a75092` | 2026-10-13 | IcliKit 0.8.5、bootstrap 探测、jetsam 服务状态、DSC 头页签名、彩色附图、PCC 无网络 |

来源：[S01–S11]。PR #633 的标题后来被改成含“v2.10.0 (WIP)”的文字，但它实际合入的模板能力在 2.9.0 发布；不能根据该标题把本轮目标写成 2.10.0。[S10]

## 2. 全部功能增量：按最终行为整理

### 2.1 依赖、版本和构建

基线的 daemon 锁文件是 IcliKit **0.7.16 / `702990b59ca412ad975f9f0ea5dafe95c30fac21`**；目标是 **0.8.5 / `815ef234df5461b8eb9455931d38cb1c37992fe6`**。同一锁文件中的 libarchive、ArgumentParser、Atomics、Collections、NIO、System 六个 pin 在本轮读取的两端没有变化；这不是对仓库所有锁文件的全量审计结论。[S12–S13]

新增段先后引入 0.7.17、0.7.18、0.8.0、0.8.4、0.8.5：应用注册记录补齐、较大 IPA 解包、跳过非 app-extension 插件、截图回退、RootHide dpkg 根目录、原生分辨率、iPad 前台应用识别及已在前台应用的启动等待等行为，需要按最终版本成组验证，不能只改锁文件数字。[S04–S07、S14]

目标 Core Bundle 为 **2.9.4/build 40**，官方 Launchpad 仍为 **2.9.2**；2.9.4 的 CI Launchpad ZIP 是未公证的相同应用，不代表必须把 Launchpad 自身版本也改到 2.9.4。2.9 系列 helper 为 build 16；新 CLI 参数及模板能力要求按 series 契约匹配，而不能继续沿用旧计划的最低版本门槛。另有 Swift 6.2 格式化和编译警告修正。[S04–S07、S14]

**旧任务落点：T08、T24、T29、T40。** T08 的终点改为上述固定依赖；host、guest、kernel、boot chain 仍分别记录来源。产品运行时不因此新增 Python/Homebrew 依赖。

### 2.2 新身份克隆：身份重新生成，但密钥不独立

`vm clone --new-identity` 清除 ECID 对应的 machineIdentifier 和 MAC，首启重新产生设备标识，并清除固定 IPv4、端口转发与手工 mDNS 名称；磁盘、SEPStorage 和 NVRAM 成组保留。普通保身份克隆和新身份克隆必须分开用于恢复与并行测试。[S15]

**它不会生成独立 SEP 根秘密或 Data 卷密钥。** 把同一模板克隆成多个不同 UDID，并不等于获得多套密码学隔离的设备。需要独立密钥的实例，保留独立 restore 路线；不要把新身份克隆用作对强隔离的证明。[S10、S15]

源 VM 运行时拒绝克隆，复制前后均确认停机。后续修正允许短暂等待普通读取者释放，而不是把 Launchpad 磁盘计量器当成运行中的 VM；真正运行的 VM 或活跃控制 socket 不走这种等待放行。[S16]

**计划调整：新增 T47。** 与 T03/T19/T21/T41 关联。模板不得夹带本地认证令牌、Apple Account、个人证书、已登录业务应用或不应扩散的 Hook 状态。认证与身份如何重置属于本地额外决策，不是上游新 UDID 自动完成的动作。

### 2.3 停机快照及恢复来源

新增 `vm snapshot create/list/revert/delete`。快照保存 `Disk.img`、`SEPStorage`、`nvram.bin`，以及存在时的 `PatchReceipt.plist`、`restore-info.json`。缺失的可选记录在回退时仍应缺失，不能保留较新安装记录。创建和恢复要求停机及无相关文件持有者；只读列表和删除快照不改在线 VM 的状态。非 APFS 不退化为大文件完整复制。[S17]

**不保存** `config.plist`、`PatchSelection.plist`、固件原件、ROM 与 restore tree。Launchpad 自己保存/恢复它掌握的来源信息；CLI 创建的快照没有相应证据时，Launchpad 应显示环境/启动链未知，而非沿用新版本的标签。克隆和导出均排除快照。[S15、S17]

后续提交加强了恢复文件集检查与失败补偿。但“异常返回时尝试恢复旧文件”不等于“断电后整组可恢复”的完整事务证明。

**计划调整：新增 T48。** 延续 T03/T11/T15/T31/T32/T40 的事务、来源和真实状态契约。快照回退后要重新对账保留下来的 desired 选择与恢复出的 applied Receipt；不能直接把快照当成整机、配置及工件全量回滚。

### 2.4 模板化创建：本轮最大的架构变化

上游将 `vm create` 改为默认查找或构建模板，再克隆成目标机器；`--no-template` 保留独立恢复。模板位于同卷的 `<library>/.templates`；临时构建与冻结模板分开，同 key 构建有锁，冻结后禁止普通启动和 DFU 启动。新增 list/show/find/adopt/delete/trim/setup 等模板管理能力。[S10、S16]

Key 不是“机型+iOS”这么简单：还包括 iOS/cloudOS build、preset、boot-chain plan digest、Bundle series、磁盘大小及精简选项。CPU、内存、网络、显示等属于克隆后配置。boot-chain 覆盖参与模板键；guest 补丁覆盖在克隆后应用，避免污染公共模板。[S16]

模板 ID 也不是构建实例身份。相同 key 重建会得到相同 ID，因此新增 Build UUID 和 `TemplateSource.plist` 来源记录，区分 current、earlierBuild、deleted。导出不携带表示物理共享的模板来源。模板可根据已记录来源定位，即使原始 IPSW 已删除，也不应先重复下载再发现已有匹配模板。[S16]

**计划调整：新增 T49。** 五模式、auth/Hook/Irisin 策略及补丁实现代际需要纳入本地模板隔离规则；不可直接用上游 preset 代替本地 mode。先交付显式 opt-in 模板创建，独立 restore 保持可用，只有隔离和恢复测试通过后再讨论默认值。模板缓存是新层，不是已有 IPSW/GPU 缓存的另一个目录名字。

### 2.5 系统精简、系统应用维护与服务配置

新增离线 System 裁剪、guest 内删除被保留的 orig-fs APFS 快照、跳过 Setup、等待首次迁移稳定、移除/恢复系统应用、服务 profile 及相关查询。精简后的字节删除和底层空间释放需要分开观察；快照仍持有块时，删除文件并不等于释放空间。[S10、S16–S17]

新增主要 RPC 包括 `services.profile`、`services.profile.apply`、`setup.settle`、`apps.remove_system`、`apps.restore_system`、`apps.removed_system`、`apfs.snapshots`、`apfs.snapshot.delete`。系统应用备份、注销、移除及恢复需要完整处理；新增 entitlement 属于能力闭包，不是只复制 daemon。[S10]

2.9.1 修正慢机器首次迁移等待，不在迁移中重启 SpringBoard；iOS 26 使用自己的精简服务列表，而不是永久跳过精简或套用 iOS 27 列表。2.9.4 再修复 iOS 27 jetsam 配置中强制启用部分服务、导致精简模板重启验收失败的问题。[S07、S18–S19]

**GUI/CLI 默认行为不能混为一谈。** 2.9.1 Launchpad 的新建界面默认保留系统应用；固定目标的模板研究文档仍列 CLI 默认 slimming request 包含默认移除列表。调用包装层必须显式写入精简及应用选择，不能假定两个入口省略参数会得到同样结果。[S07、S16]

**计划调整：新增 T50。** 删除、服务变更和 snapshot 删除属于有副作用的 API；纳入本地权限、模式允许范围、操作互斥、来源记录和恢复。服务配置关闭必须只恢复它自己管理过的项，不解除用户原有禁用项。不要把“精简”自动映射为本地 `less` 模式。

### 2.6 磁盘 rebase、共享计量与存储预算

新增 `vm rebase <vm> --onto <base>`，这是磁盘块共享重整，**不是 Git rebase，也不是升级 guest 系统**。通过克隆基盘、覆盖目标差异、完整字节校验后发布新 Disk.img；目标内容、SEPStorage、NVRAM、配置和设备身份保持原语义。要求同 APFS 卷及双方停机，没有跨卷完整复制降级。[S20]

后续修正把“已有共享”和“新增共享”分开，避免同模板两克隆显示巨额虚假节省。Launchpad 按物理 extents 计量 exclusive 大小，避开 Time Machine 快照导致 APFS private size 变零的误导；不在运行中打开磁盘做计量。模板/快照或库外克隆持有旧块时，释放空间仍受限制。[S16、S20]

**计划调整：新增 T51。** 初期作为显式维护命令，不放入普通环境升级必经链。验收包含逐字节不变、身份不变、共享统计、低空间、外置卷及中断恢复；收益只以本地相同 fixture 的物理占用变化报告。

### 2.7 磁盘操作互斥、CFW 并行与临时目录

CFW install/update 从全局互斥收敛为每 VM 互斥，不同 VM 可并行，取消只影响目标操作。`install`、`update-environment`、`update-kernel` 支持 `--work-parent`，默认 scratch 可跟随 VM 外置卷。磁盘挂载调用从 hdiutil 转向 diskutil；另修复 CFW 和长 socket 路径两处 mkdtemp 缓冲区生命周期，以及 macOS 27 devfs 设备号有符号转换问题。[S11、S21–S23]

必须区分三个判断：“有进程持有磁盘”“此机器正在运行”“允许给此 PID 发停止信号”。后来 stop 只针对真实 VM 所属进程，不能杀死 Spotlight、备份程序、Launchpad 计量线程或普通读盘工具；写盘仍因相关持有者而拒绝。已有 `set-bundle --update-environment` 也要先检查占用再改变绑定，真正开始后才打印更新已启动。[S16]

**计划调整：新增 T52，强化 T15/T24/T37/T40。** 统一锁/operation/generation 契约供 clone、snapshot、rebase、CFW、模板构建及管理入口使用。每 VM 并行不是允许同一 VM 多写入者并发。新 `--work-parent` 仍必须满足本地路径、owner、权限、同卷与容量约束。

`fw prepare` 的另一个独立变化是 GPU 提取用的临时 PCC/cloudOS VM 不再创建网络设备。这仅影响准备阶段临时机，不是删除用户 VM 的 NAT/tunnel/bridged 能力。[S04]

### 2.8 退出、停止与操作状态

窗口关闭、Cmd-Q、CLI stop 和信号退出统一先请求 guest 有序关机，再等实际停止，超时后回退强制停止。此前 T37 已有有序关机，本轮是扩大入口覆盖及修正进程归属，不应重复登记成首次引入 shutdown。[S08、S16]

**计划调整：继续 T37，和 T52 共用状态机。** “请求被接受”不是磁盘已释放；停止、更新、快照、模板构建和导入取消之间的交错需要复验。发生 PID 复用、旧异步结果或控制 socket 拒绝访问时，不能按猜测继续写盘。

### 2.9 Xcode、DeviceHub 与 Flutter：需要组合整合

本轮增加 `libdevicehubfix` 及其打包、加载与环境清单；修复 DDI 挂载、DeviceHub 特性探测、捕获显示及遮罩。iOS 27 的 IOMFB force-kern 从无条件分发改为区分主显示与捕获显示，后续再解决 banded stream 导致的宿主 GPU 死锁。[S24–S25]

**同 ID 不代表同实现。** `dyld-boot-iomfb_force_kern` 没换 ID，但 Undo 记录形状从旧实现变成新实现；新增 `outdatedImplementations` 检测、撤销旧字节并重打新实现。缺少可信旧 Undo 的 VM，不会因为新 Bundle 到位就自动具备安全撤销资格。[S24]

另外有 iOS 27 CoreDevice 安装的 persona lookup 兼容补丁、Flutter AOT 重映射丢失 RX 权限修复，以及 2.9.4 在 maxSlide 调整后重新签 DSC 头页，解决设备支持准备/LLDB 读取系统库及 Flutter debug 长时间黑屏。AOT remap 与 LLDB/DSC 是两类不同问题，不可只取其中一个就宣称 Flutter 链路完成。[S26–S28]

**计划调整：新增 T53，关联 T18/T24/T32/T33/T35/T43/T44。** 把完整包载荷、Hook 策略、旧实现迁移、签名、Xcode 真正的安装和调试路径一起验收。`apps.install` 成功不能替代 Xcode/CoreDevice 安装成功；DeviceHub 修复也不自动证明所有 iPadOS/机型配对和长时间多路流都通过。早期 iPadOS 27 的配对限制单列为组合验证，不靠 release 概括作支持承诺。

### 2.10 应用、RootHide、Irisin 和注入链

spawn Hook 可向同一进程组合多库；包管理完成后注册 bootstrap 内应用；bootstrap 活跃时提高 spawned process 的 jetsam 额度。IcliKit 同期补齐安装和注册相关行为。[S09、S12–S14]

2.9.3 把 Irisin 数据目录放入实际 RootHide 环境的用户目录。2.9.4 的设备信息能识别 vphoned 安装的 bootstrap；packages/environment 对齐其 dpkg 根目录，避免 UI “未检测到”与实际已安装不一致。[S04–S06]

**计划调整：扩展 T18/T21/T43，不另建平行 Hook 框架。** 多库注入顺序、重复注入、继承环境变量及每模式允许名单需要对齐；提高内存限额不等于宿主内存无限。恢复与克隆不能把本地 auth 状态或用户数据目录静默指向另一环境。

### 2.11 定位、设备名和时钟

定位同步成为可持久化的每机开关，默认关闭；宿主授权、headless 行为、guest Location Services 状态和多 Bundle helper 协作有相应处理。先有 locationd 启动死锁重启，再有 iOS 27 cohort 竞争修复；应取最终链路，不能只保留“死了就重启”。[S09、S29]

设备名从 VM 名称传递到 guest：早期 NVRAM 路径后来被 vphoned 文件/RPC 路径替代，并配合 `libdevicename`。这组中间 NVRAM 提交保留追溯，但不按时间顺序原样装回。无效 VM 名称、运行时重命名及下次连接更新要按最终实现测试。[S09、S30]

新增 `time.clock` / clock capability：连接、周期、唤醒及宿主时钟变化时同步。它不是无条件覆盖用户时间；guest 自动时间关闭时保留手动设置，接近宿主时间时不反复改钟。[S31]

**计划调整：T20 继续；新增 T55 设备名、T56 时钟。** 时间类测试应记录自动/手动模式、时区与绝对时间是不同设置。名称同步也不等于新 UDID 或独立认证身份。

### 2.12 虚拟相机、设备修复、运动传感器

虚拟相机新增前置请求支持，按 session preset 的尺寸、方向、镜像输出视频帧，并支持 AVAssetWriter 录制。board-presenting iPhone 产品修复补齐相关按键能力；这些是已有设备/相机链的扩展，不是从零新增 iPad 或所有新设备支持。[S05、S32]

新增虚拟 HID 陀螺仪、motion RPC、device attitude 模拟与宿主实时控制面板；后续修复 Core Motion 锁顺序、SpringBoard 死锁/重启，并增加附着于显示窗口的姿态仪表。[S07、S11、S33]

**计划调整：扩展 T22/T23/T42/T43/T44；新增 T54。** 相机和运动能力按 host UI、协议、daemon、Hook、guest 版本及实际应用成组验收。必须含启停、退后台、关闭功能、respring、重连和迟到事件失效。

### 2.13 剪贴板、鼠标、截图与协议错误

daemon 现在能够观察真实 guest 应用产生的剪贴板变化，补齐此前只在部分桥接操作中可见的内容。右键语义改为 secondary click，而不是 Home。控制 socket 回复携带彩色小图，IcliKit 又修正部分黑图、无 SpringBoard 时的原生尺寸及 iPad 前台识别。`vphone.sock` RPC 失败透传更完整的 guest 错误对象，而非丢弃 results/reason/errno/retryable。[S04、S07、S10]

**计划调整：T06/T23/T38/T39 延伸。** 本地自动化可能依赖旧右键或灰度图，应显式迁移；不能把这些行为变化都标为透明 bugfix。继续保留 instance/generation 防迟到覆盖，以及未知副作用结果先读回、不按 request ID 盲目重试的规则。

### 2.14 空闲性能

vphoned 设备状态轮询按事件订阅开启；相机帧驱动、preview-layer 扫描、陀螺仪状态与 speaker flush timer 按实际客户端/会话开启；宿主 bundled daemon 摘要按文件缓存，减少 health probe 重复读取。[S18]

**计划调整：新增 T59，关联 T06/T22/T23/T42。** 这不是无脑延长轮询间隔：无订阅应停，有订阅必须可靠恢复，文件变化应使缓存失效。上游测量不是本地收益保证，验收应同时看 CPU、wakeups、首响应延迟及长时间启停正确性。

### 2.15 多连接 IPSW、缓存与磁盘空间 UI

下载默认四连接，可配置 1–16；Range 探测、分段续传和 ETag/If-Range 防止服务器内容中途变化混入同一缓存，服务器不支持 Range 或选择一连接时保留单流路线。进度汇总串行报告。新增已下载 IPSW 列表、删除及创建依赖提示；模板命中时不应为查找模板再下载固件。[S16、S34]

**计划调整：新增 T57，关联 T13/T14。** 验收缓存命中、Range 被忽略/改变、分段短读、断线、取消、跨 VM 同 URL 并发、读写权限及坏缓存隔离。新的库占用计量、可用空间刷新与固件删除入口要显示“可回收”和“实际立即释放”的差别。

### 2.16 登录提示、Settings 行与默认预设

新增 `libsigninfix`、`libprefsfix`，改变未登录账户相关提示和 Settings 建议组显示；另有仅对特定 iOS 27 build 的可选 Settings 行隐藏。隐藏/抑制 UI 不等于账号功能实现或安全边界增强。[S08–S09、S35]

2.9.1 把 ProMotion 放入上游 standard 默认预设，这与既有 T45“可选延后”直接冲突。[S07]

**计划调整：T45 保留显式政策；新增 T58 作为需决策的选项。** 不将 standard/experimental 自动映射成本地 regular/exp；不将上游模板精简映射成本地 less；不因升级默认关闭登录、删除系统应用或开启 120 Hz。策略变化需单独批准和记录。

### 2.17 Launchpad、导入导出与文档

Launchpad 新建改为单页和高级选项，增加机器菜单/快捷键、维护和强制终止入口，日志和表格重排、排序/多选，创建后的补丁只读查看，支持直接 .vpea 导出及拖放。对找不到原 Bundle 的 VM 仍提供受控删除；绑定与更新进度文案必须符合真实状态。[S07、S16]

2.9.2 导入以队列行显示，逐个执行，可停止；进度管道 reader 消失不意味着用户取消。SIGINT/TERM 的取消清理仍保留；退出 UI 需要等待正在进行的导入/导出安全结束。导出排除遗留 vphone.sock、快照和不适合迁移的模板物理来源；导出/导入不是物理共享克隆。[S06–S07、S16–S17]

**计划调整：新增 T60，扩展 T05/T25/T26/T27/T40/T46。** EPIPE 与取消必须是不同状态；不得在无权限或忙碌时靠 fallback 执行越权操作。文档/本地化/格式化独立提交，避免掩盖本地定制冲突；旧 console 性能补丁已经在 2d21d21 中，不重复算作本轮新增。

## 3. 不应直接重放的中间状态

| 演进链 | 本轮参考终态 | 合入注意 |
|---|---|---|
| `e5bcf80`、`a312b8f` → `c7fdced`、`4391ded`、`2fc8850` | daemon 文件/RPC 传名称 | 不恢复过时 NVRAM 名称传递 |
| 0.7.17 → 0.7.18 → 0.8.0 → 0.8.4 → 0.8.5 | 固定 0.8.5 pin | 中间版本的功能需求保留，版本号不逐级上生产 |
| 初始模板创建 → key/build/严格步骤/来源修正 | 固定目标完整模板状态机 | 不能只取 `8dbf387` 后宣布模板完成 |
| `5289466` → `50545d3` | iOS 26 专属 profile | 不把临时停用精简当永久最终设计 |
| `4f6cf11` + `f496cfe` | 新 dispatch + 旧实现迁移 | 补丁 ID 相同也要识别旧实现 |
| 初始态度控制 → `12c72fa`、`2be089b` | 修正锁顺序与 respring | 不只合 UI/RPC，遗漏线程修正 |
| 初始 rebase → `eec7350` | newly shared 与 already shared 分开 | 不使用早期过大的节省数字 |
| 引入服务 profile → `fde9caf` | iOS 27 禁用状态可生效 | “已写 overrides”不等于重启后已关闭 |
| 导出排除 socket + `6f90a2f` + `da6906f` | 归档、取消与 UI 队列完整链 | 不能用关闭进度管道模拟取消 |

这些是按语义识别的重点演进链，不表示其他 merge 已完成无独立解决内容的证明。全部 51 条 merge 仍保留在账本中。

## 4. 旧 47 项怎样调整

### 4.1 原编号保留，状态不重置

| 原任务 | 本轮更新 |
|---|---|
| T00–T03 | 目标改固定 8a75092；采集真实 local HEAD/WIP/merge-base；复用已通过证据；追加新范围对账与可恢复 fixture |
| T04–T05 | 原签名/UTF8 安全成果保留；T05 加归档 socket/快照/模板来源排除与导入取消 |
| T06–T08 | guest_error、事件订阅/摘要缓存与新协议兼容；IcliKit 调至固定 0.8.5 |
| T09–T14 | 模板键、boot/guest patch 分流、实现代际；PCC 无网络、多连接缓存；坚持五模式与原件来源 |
| T15–T17 | 多种磁盘操作统一互斥、每 VM 并行、外置 scratch；快照和模板不绕过原事务/更新准入 |
| T18–T23 | Xcode 真安装、RootHide 路径/多库、定位终态、设备名/时钟、前摄/运动/右键/剪贴板 |
| T24–T27 | helper/Bundle series 契约；新 CLI/UI 和导入队列；继续严格权限，不照搬上游宽权限 |
| T28–T31 | 增量来源台账、固定发布候选、新能力验收矩阵和整组恢复；原验收事实不抹掉 |
| T32–T35 | 同 ID 不同实现的迁移，DSC 头页重新签名；快照恢复后的 desired/applied/source 对账 |
| T36–T39 | 新异步任务绑定 instance/generation；统一所有退出入口；guest 应用复制与新截图/前台语义 |
| T40–T44 | host/guest/kernel/boot-chain 仍分层；模板来源不能顶替已安装环境来源；设备与相机补强 |
| T45 | 保留可选；拒绝因 standard 默认变化而静默开启 |
| T46 | 原 console 性能/输出 ACK 已属基线，保留成果；追加导入进度断开与取消判别 |

### 4.2 建议追加 14 个工作单元（并非已批准的必做范围）

追加 T47–T60 后是 **61 个候选管理单元**。这是建议修订稿，不代表 61 项都缺失、同等工作量或全部必须上生产。T58、T51 及默认模板化是否主线由本地目标决定；与 T45 一样可保留明确延后项。

详见 `plan_delta.md` 与 `plan_delta.json`：每项给出旧任务关联、前置条件、接受条件、恢复单位和当前 `pending_local_audit` 状态。

## 5. 建议批次：先保稳定，再引入模板，最后收 UI

| 批次 | 工作 | 退出条件 |
|---|---|---|
| B0 重新冻结并对账 | T00–T03、读取本地规则；以 194 条账本对 Git 图；核对原 47 项进度 | 真实本地映射、保存点、恢复样本，不以旧 HEAD 冒充当前 |
| B1 基础和小修复 | T08/T24 + mkdtemp/devfs + 原有协议/路径/构建修正 | 固定依赖与工程完整；保留原 VM 基线可运行 |
| B2 操作安全层 | T52、T37、T40；磁盘占用分类、每机互斥、work-parent、绑定更新顺序 | 同 VM 无并发写；不杀旁观进程；取消有归属 |
| B3 现有 VM 能力升级 | T53、T18/T20/T21/T22/T32/T33/T35/T43/T44；T55/T56 | 旧 VM 成组更新、激活、真安装/调试及回退通过 |
| B4 克隆与快照 | T47/T48；T51 可显式独立维护 | 新身份与密钥继承解释准确；快照回退不伪造配置/来源 |
| B5 模板与精简 | T50 的服务/应用/首启基础 → T49 模板编排；T57 下载 | 模板 key/build/模式隔离、并发首建、失败冻结、clone 后覆盖正确 |
| B6 体验与性能 | T54/T59/T60、T25–T27；T45/T58 按决策启用 | UI 依托真实后端，性能收益与重连正确性同时测量 |
| B7 固定候选与签收 | T28–T31 | 源码/依赖/工件/来源与测试同一候选；完成整组恢复 |

批次不是严格串行施工图：T57 可与磁盘层并行，T54/T59 可在共享协议冻结后分工；实际 VM 写盘必须串行。T49 依赖 T50 的原语，不能为了先画模板 UI 留下不可验收的后端。

## 6. 新增必须覆盖的验收场景

| 领域 | 场景与判断 |
|---|---|
| 版本/模式 | 五模式各自解析和执行；新旧 Bundle/daemon 混用先冻结自动更新；不套用上游 preset 默认值 |
| 补丁实现迁移 | 同 ID 旧 Undo → 新实现；缺 Undo、部分记录、读回失败均不得伪报升级完成 |
| 克隆 | 运行/启动中拒绝；复制前后检查；ECID/MAC/UDID 变化；静态网络清理；SEP/密钥继承声明 |
| 快照 | 三状态文件一致；可选记录不存在；配置/选择保留导致 drift；CLI 与 Launchpad 来源不同；故障恢复再失败 |
| 模板 | 同 key 双构建；模式和 boot 覆盖隔离；guest 覆盖不污染模板；同 ID 不同 Build；冻结后拒绝启动；原 IPSW 删除 |
| 精简 | iOS 26/27 分表；服务 owned-set 回退；系统应用备份/注册；慢迁移；重启后实际状态；jetsam 禁用修正 |
| 磁盘/并行 | CFW、clone、snapshot、rebase、计量交错；非 VM 持有者；PID 复用；外置卷掉线/低空间/路径欺骗；取消只影响一机 |
| Xcode/Flutter | 配对、DDI、DeviceHub、实际 CoreDevice 安装、LLDB、Flutter debug 与 AOT 分测；长时间多路流 |
| guest 集成 | 正确 jbroot/dpkg；Irisin 真用户路径；多库注入；手动时间保持；名称改动；定位授权和 cohort |
| 媒体与控制 | 前/后摄与录像；方向/镜像；运动锁顺序；右键新语义；guest Copy；彩色截图；旧 instance 迟到结果失效 |
| 导入/导出 | 特殊文件过滤、Unicode、坏归档、路径越界；进度 EPIPE 不等于取消；SIGINT/TERM 清理；退出等待；半成品不进入正常列表 |
| 空闲性能 | 零订阅/有订阅切换；相机/音频/运动重复启停；摘要缓存失效；长时间无积累及恢复响应 |

新增恢复单位不能只写“回滚 Git commit”：宿主应用/helper、每机绑定、guest 文件和加载状态、kernel/DSC/DeviceTree、磁盘+SEP+NVRAM、模板 Build 与其所有消费者，都要明确各自恢复边界。所有未测组合登记 `not_run`，不能拿上游作者的测试代填本地通过。

## 7. Git 审计程序与使用边界

`audit_upstream.py` 是开发/审计辅助程序，不是产品运行时依赖。它不 fetch、不 checkout、不 merge、不 cherry-pick、不改 refs、不操作 VM。仅在已有完整 Git 对象的仓库中读取，拒绝 shallow 和非祖先范围，输出目录必须新建且位于输入仓库之外。

```sh
python3 audit_upstream.py \
  --repo /path/to/your/vphone-cli \
  --out /tmp/vphone-upstream-audit-20261014
```

输出：完整 SHA/parents/时间/原提交消息、拓扑序与 first-parent 列表、最终树 name-status/numstat/二进制 diff、每个 merge 相对各父提交的差异与 remerge 诊断、194 条网页账本与真实 Git 集合的差集。`audit.json` 只在全部步骤完成后生成。remerge 输出为空并不自动证明 merge 没有独立语义，仍需评审。

当前交付中的 **Git 对象审计未执行于真实上游或用户 fork，macOS/Xcode/VM 构建及运行测试均未执行**。程序的本轮测试仅限临时 Git fixture，结果见 `audit_self_test.json`。完整文件/行数和本地剩余工作量须由真实输出填入；在此之前保持 null，而不是沿用旧报告的 357 文件或其他历史数字。

## 8. 来源索引

各提交的直接来源链接还逐条列在附录和结构化账本。下列资料中，固定目标的文档/锁文件用于描述终态；PR 的中间报告和历史测试只用于解释演进，不等于当前候选验收。

- [S01 当前提交历史](https://github.com/Lakr233/vphone-cli/commits)
- [S02 基线附近历史](https://github.com/Lakr233/vphone-cli/commits?after=8a75092013eda87a4e30ed029b72028cb9279ac4+174)
- [S03 2.6.1 发布与累计计数](https://github.com/Lakr233/vphone-cli/releases/tag/2.6.1)
- [S04 2.9.4 发布](https://github.com/Lakr233/vphone-cli/releases/tag/2.9.4)
- [S05 2.9.3 发布](https://github.com/Lakr233/vphone-cli/releases/tag/2.9.3)
- [S06 2.9.2 发布](https://github.com/Lakr233/vphone-cli/releases/tag/2.9.2)
- [S07 2.9.1 发布](https://github.com/Lakr233/vphone-cli/releases/tag/2.9.1)
- [S08 2.7.0 发布](https://github.com/Lakr233/vphone-cli/releases/tag/2.7.0)
- [S09 2.8.0 发布](https://github.com/Lakr233/vphone-cli/releases/tag/2.8.0)
- [S10 模板 PR #633](https://github.com/Lakr233/vphone-cli/pull/633)
- [S11 2.9.0 发布](https://github.com/Lakr233/vphone-cli/releases/tag/2.9.0)
- [S12 基线 daemon Package.resolved](https://github.com/Lakr233/vphone-cli/blob/2d21d21fbdd4f51f013616273ceda9b35a3e0789/VPhoneDaemon/VPhoneDaemon.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)
- [S13 目标 daemon Package.resolved](https://github.com/Lakr233/vphone-cli/blob/8a75092013eda87a4e30ed029b72028cb9279ac4/VPhoneDaemon/VPhoneDaemon.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)
- [S14 固定目标提交](https://github.com/Lakr233/vphone-cli/commit/8a75092013eda87a4e30ed029b72028cb9279ac4)
- [S15 身份克隆和快照 #605](https://github.com/Lakr233/vphone-cli/pull/605)
- [S16 固定模板设计说明](https://github.com/Lakr233/vphone-cli/blob/8a75092013eda87a4e30ed029b72028cb9279ac4/Research/Host/machine_templates.md)
- [S17 固定快照指南](https://github.com/Lakr233/vphone-cli/blob/8a75092013eda87a4e30ed029b72028cb9279ac4/Documents/Guides/snapshots.md)
- [S18 首启与空闲修复 #643](https://github.com/Lakr233/vphone-cli/pull/643)
- [S19 jetsam 禁用状态 #664](https://github.com/Lakr233/vphone-cli/pull/664)
- [S20 固定 rebase 设计说明](https://github.com/Lakr233/vphone-cli/blob/8a75092013eda87a4e30ed029b72028cb9279ac4/Research/Host/disk_rebase.md)
- [S21 每机 CFW 并行 b36dbaa](https://github.com/Lakr233/vphone-cli/commit/b36dbaa)
- [S22 外置 scratch 6b55fed](https://github.com/Lakr233/vphone-cli/commit/6b55fed)
- [S23 工作目录参数 4254854](https://github.com/Lakr233/vphone-cli/commit/4254854)
- [S24 DeviceHub #604](https://github.com/Lakr233/vphone-cli/pull/604)
- [S25 GPU stream #624](https://github.com/Lakr233/vphone-cli/pull/624)
- [S26 安装 persona 15a5af7](https://github.com/Lakr233/vphone-cli/commit/15a5af7)
- [S27 Flutter AOT #627](https://github.com/Lakr233/vphone-cli/pull/627)
- [S28 DSC 头页 a68a533](https://github.com/Lakr233/vphone-cli/commit/a68a533)
- [S29 locationd 竞争 1e9dc6b](https://github.com/Lakr233/vphone-cli/commit/1e9dc6b)
- [S30 名称终态 2fc8850](https://github.com/Lakr233/vphone-cli/commit/2fc8850)
- [S31 宿主时钟 #659](https://github.com/Lakr233/vphone-cli/pull/659)
- [S32 前置相机 #654](https://github.com/Lakr233/vphone-cli/pull/654)
- [S33 运动姿态锁修正 #647](https://github.com/Lakr233/vphone-cli/pull/647)
- [S34 分段下载 fc6456f](https://github.com/Lakr233/vphone-cli/commit/fc6456f)
- [S35 登录抑制 #620](https://github.com/Lakr233/vphone-cli/pull/620)

旧任务依据为本轮从 Library 读取的 `vphone_upstream_merge_plan_2026-10-06_2d21d21.md`（完整）及对应 execution TODO（首段）。本包不覆盖或改写原文件。

## 附录 A. 194 条新增提交处置账本

**顺序为 GitHub 历史页面展示顺序（新到旧），不是可直接执行的 cherry-pick 顺序。** M 为合并记录，C 为其他实现/发布主旨记录，D 为文档/格式主旨记录；该主旨分类不等于逐文件证明为纯文档或纯代码。逐条本地状态仍需在 T02 填写。

| # | Commit | 类别 | 模块 | 新增/修正概要 | 建议关联 |
|---:|---|---|---|---|---|
| 1 | [`8a75092`](https://github.com/Lakr233/vphone-cli/commit/8a75092) | M | 依赖构建 | 合并 #667：IcliKit 0.8.5 与 2.9.4 | T08/T24/T29/T40 |
| 2 | [`ccf8ef7`](https://github.com/Lakr233/vphone-cli/commit/ccf8ef7) | C | 依赖构建 | 消除 daemon 与 CLI 的四项编译警告 | T08/T24/T29/T40 |
| 3 | [`9a8f659`](https://github.com/Lakr233/vphone-cli/commit/9a8f659) | C | 依赖构建 | 锁定 IcliKit 0.8.5，更新 2.9.4 版本 | T08/T24/T29/T40 |
| 4 | [`3f3bc2f`](https://github.com/Lakr233/vphone-cli/commit/3f3bc2f) | M | 应用与Bootstrap | 合并 #665：识别本机安装的 bootstrap | T18/T21/T43 |
| 5 | [`9a7388c`](https://github.com/Lakr233/vphone-cli/commit/9a7388c) | M | 依赖构建 | 合并 #666：IcliKit 0.8.4 | T08/T24/T29/T40 |
| 6 | [`2cd1db4`](https://github.com/Lakr233/vphone-cli/commit/2cd1db4) | C | 依赖构建 | IcliKit 0.8.4 对齐环境及包数据库根路径 | T08/T24/T29/T40 |
| 7 | [`4c2d768`](https://github.com/Lakr233/vphone-cli/commit/4c2d768) | C | 应用与Bootstrap | 设备信息报告 vphoned 安装的 RootHide 布局 | T18/T21/T43 |
| 8 | [`33737fe`](https://github.com/Lakr233/vphone-cli/commit/33737fe) | M | 系统精简 | 合并 #664：修正 jetsam 强制启用服务 | T50 |
| 9 | [`fde9caf`](https://github.com/Lakr233/vphone-cli/commit/fde9caf) | C | 系统精简 | 让 iOS 27 中被禁用的服务保持关闭 | T50 |
| 10 | [`35d8e8f`](https://github.com/Lakr233/vphone-cli/commit/35d8e8f) | M | Xcode与Flutter | 合并 #662：DSC 头页重新签名 | T53 |
| 11 | [`ea5382b`](https://github.com/Lakr233/vphone-cli/commit/ea5382b) | M | 输入与剪贴板 | 合并 #663：控制回复附带彩色图像 | T06/T23/T38/T39 |
| 12 | [`87ba47e`](https://github.com/Lakr233/vphone-cli/commit/87ba47e) | C | 输入与剪贴板 | 控制 socket 的附带截图改为彩色 | T06/T23/T38/T39 |
| 13 | [`a68a533`](https://github.com/Lakr233/vphone-cli/commit/a68a533) | C | Xcode与Flutter | maxSlide 修改后重新证明 DSC 头页 | T53 |
| 14 | [`8cf780d`](https://github.com/Lakr233/vphone-cli/commit/8cf780d) | M | 固件与磁盘安全 | 合并 #661：临时 PCC 恢复机不接网络 | T52 |
| 15 | [`e91b907`](https://github.com/Lakr233/vphone-cli/commit/e91b907) | C | 固件与磁盘安全 | GPU 提取用临时 PCC 机移除网络设备 | T52 |
| 16 | [`6af3fe9`](https://github.com/Lakr233/vphone-cli/commit/6af3fe9) | C | 依赖构建 | 引入 IcliKit 0.8.0，发布 2.9.3 | T08/T24/T29/T40 |
| 17 | [`c4a0081`](https://github.com/Lakr233/vphone-cli/commit/c4a0081) | C | 应用与Bootstrap | Irisin 数据目录放到实际 jbroot 用户目录 | T18/T21/T43 |
| 18 | [`f4e4fb2`](https://github.com/Lakr233/vphone-cli/commit/f4e4fb2) | M | 时间同步 | 合并 #659：宿主时间同步 | T56 |
| 19 | [`3715b5b`](https://github.com/Lakr233/vphone-cli/commit/3715b5b) | C | 时间同步 | guest 时钟跟随 Mac | T56 |
| 20 | [`0e7a7e7`](https://github.com/Lakr233/vphone-cli/commit/0e7a7e7) | M | 设备与相机 | 合并 #657：board-presenting iPhone 修复 | T22/T23/T42/T43/T44 |
| 21 | [`e52dc61`](https://github.com/Lakr233/vphone-cli/commit/e52dc61) | C | 设备与相机 | 对展示本机 board 的 iPhone 执行产品修复 | T22/T23/T42/T43/T44 |
| 22 | [`0da1bea`](https://github.com/Lakr233/vphone-cli/commit/0da1bea) | M | 运动传感器 | 合并 #656：传感器面板 | T54 |
| 23 | [`5075153`](https://github.com/Lakr233/vphone-cli/commit/5075153) | C | 运动传感器 | 去掉运动面板重复的坐标轴文字 | T54 |
| 24 | [`5632674`](https://github.com/Lakr233/vphone-cli/commit/5632674) | C | 运动传感器 | 显示窗口附带姿态角度仪表 | T54 |
| 25 | [`2032dff`](https://github.com/Lakr233/vphone-cli/commit/2032dff) | M | 设备与相机 | 合并 #654：前置虚拟相机 | T22/T23/T42/T43/T44 |
| 26 | [`5f3ac24`](https://github.com/Lakr233/vphone-cli/commit/5f3ac24) | C | 设备与相机 | 支持前摄及相机规格的视频帧 | T22/T23/T42/T43/T44 |
| 27 | [`7fc2e2c`](https://github.com/Lakr233/vphone-cli/commit/7fc2e2c) | D | 文档与格式 | 说明 2.9 系列进入维护阶段 | T28/T29 |
| 28 | [`64a4c09`](https://github.com/Lakr233/vphone-cli/commit/64a4c09) | C | 依赖构建 | 避免网络初始化变量同名遮蔽 | T08/T24/T29/T40 |
| 29 | [`da6906f`](https://github.com/Lakr233/vphone-cli/commit/da6906f) | C | 导入导出与UI | 导入进度行与退出清理，发布 2.9.2 | T60 |
| 30 | [`6f90a2f`](https://github.com/Lakr233/vphone-cli/commit/6f90a2f) | C | 导入导出与UI | 进度读取端消失不再中止导入 | T60 |
| 31 | [`a2e964f`](https://github.com/Lakr233/vphone-cli/commit/a2e964f) | C | 导入导出与UI | 归档跳过遗留 socket，2.9.1 发布锚点 | T60 |
| 32 | [`4f3cee3`](https://github.com/Lakr233/vphone-cli/commit/4f3cee3) | C | 导入导出与UI | 调整页面切换器及进度活动名称 | T60 |
| 33 | [`9341c9b`](https://github.com/Lakr233/vphone-cli/commit/9341c9b) | C | 导入导出与UI | 机器菜单、快捷键、只读补丁及直接导出 | T60 |
| 34 | [`83b791d`](https://github.com/Lakr233/vphone-cli/commit/83b791d) | C | 导入导出与UI | 重组机器操作，扩展日志与模板界面 | T60 |
| 35 | [`2c3b818`](https://github.com/Lakr233/vphone-cli/commit/2c3b818) | C | 导入导出与UI | 重做新建、表格及弹窗，设置 2.9.1 版本 | T60 |
| 36 | [`c39628a`](https://github.com/Lakr233/vphone-cli/commit/c39628a) | M | 导入导出与UI | 合并 #649：简化新建机器 | T60 |
| 37 | [`12945bd`](https://github.com/Lakr233/vphone-cli/commit/12945bd) | M | 文档与格式 | 合并 #648：磁盘研究说明 | T28/T29 |
| 38 | [`f5de67e`](https://github.com/Lakr233/vphone-cli/commit/f5de67e) | C | 导入导出与UI | 新建缩为一页，高级选项折叠 | T60 |
| 39 | [`1cb62d1`](https://github.com/Lakr233/vphone-cli/commit/1cb62d1) | D | 文档与格式 | 补齐模板、克隆与服务文档 | T28/T29 |
| 40 | [`d2f85f4`](https://github.com/Lakr233/vphone-cli/commit/d2f85f4) | D | 文档与格式 | 记录 VM 磁盘空间研究 | T28/T29 |
| 41 | [`9346777`](https://github.com/Lakr233/vphone-cli/commit/9346777) | M | 运动传感器 | 合并 #647：Core Motion 姿态修复 | T54 |
| 42 | [`2be089b`](https://github.com/Lakr233/vphone-cli/commit/2be089b) | C | 运动传感器 | 防止姿态模拟导致 SpringBoard 重启 | T54 |
| 43 | [`ca60543`](https://github.com/Lakr233/vphone-cli/commit/ca60543) | M | 导入导出与UI | 合并 #644：补丁筛选空结果布局 | T60 |
| 44 | [`84e9cec`](https://github.com/Lakr233/vphone-cli/commit/84e9cec) | M | 默认策略 | 合并 #645：标准预设启用 ProMotion | T09/T10/T45 |
| 45 | [`4051399`](https://github.com/Lakr233/vphone-cli/commit/4051399) | M | 模板与首启 | 合并 #643：首启与空闲优化 | T49/T50 |
| 46 | [`f167100`](https://github.com/Lakr233/vphone-cli/commit/f167100) | D | 系统精简 | 记录 iOS 26 服务裁剪清单 | T50 |
| 47 | [`50545d3`](https://github.com/Lakr233/vphone-cli/commit/50545d3) | C | 系统精简 | 增加 iOS 26 专属服务精简配置 | T50 |
| 48 | [`492a4f6`](https://github.com/Lakr233/vphone-cli/commit/492a4f6) | C | 默认策略 | standard 预设默认开启 ProMotion | T09/T10/T45 |
| 49 | [`cf129b8`](https://github.com/Lakr233/vphone-cli/commit/cf129b8) | C | 导入导出与UI | 补丁筛选无匹配时维持面板布局 | T60 |
| 50 | [`a6a2aae`](https://github.com/Lakr233/vphone-cli/commit/a6a2aae) | D | 文档与格式 | 记录姿态锁顺序与 iOS 26 精简限制 | T28/T29 |
| 51 | [`5289466`](https://github.com/Lakr233/vphone-cli/commit/5289466) | C | 系统精简 | 中间修正：iOS 26 暂不套用 iOS 27 精简表 | T50 |
| 52 | [`12c72fa`](https://github.com/Lakr233/vphone-cli/commit/12c72fa) | C | 运动传感器 | 修复姿态 Hook 与 Core Motion 的死锁 | T54 |
| 53 | [`e4a6ef4`](https://github.com/Lakr233/vphone-cli/commit/e4a6ef4) | C | 模板与首启 | 消除 daemon 退出拖住首启重启的问题 | T49/T50 |
| 54 | [`9e2d690`](https://github.com/Lakr233/vphone-cli/commit/9e2d690) | C | 模板与首启 | 模板冻结前清理其自身启动崩溃记录 | T49/T50 |
| 55 | [`b7e545c`](https://github.com/Lakr233/vphone-cli/commit/b7e545c) | M | 输入与剪贴板 | 合并 #641：右键语义修复 | T06/T23/T38/T39 |
| 56 | [`35f92d1`](https://github.com/Lakr233/vphone-cli/commit/35f92d1) | C | 固件与磁盘安全 | 克隆等待短时读取者释放磁盘 | T52 |
| 57 | [`9700aa5`](https://github.com/Lakr233/vphone-cli/commit/9700aa5) | C | 模板与首启 | 模板匹配由 CLI 提供，持有者规则加一致性测试 | T49/T50 |
| 58 | [`43d8470`](https://github.com/Lakr233/vphone-cli/commit/43d8470) | D | 空闲性能 | 记录 guest 自有组件的空闲成本 | T59 |
| 59 | [`c35e99b`](https://github.com/Lakr233/vphone-cli/commit/c35e99b) | C | 空闲性能 | daemon 二进制摘要按文件缓存 | T59 |
| 60 | [`afc62ef`](https://github.com/Lakr233/vphone-cli/commit/afc62ef) | C | 空闲性能 | 只在事件 socket 有订阅时轮询设备 | T59 |
| 61 | [`7cdf6a5`](https://github.com/Lakr233/vphone-cli/commit/7cdf6a5) | C | 空闲性能 | 只在样本流动时刷新陀螺仪状态 | T59 |
| 62 | [`a7a5d13`](https://github.com/Lakr233/vphone-cli/commit/a7a5d13) | C | 空闲性能 | 扬声器停止时取消刷新定时器 | T59 |
| 63 | [`069d530`](https://github.com/Lakr233/vphone-cli/commit/069d530) | C | 空闲性能 | 相机预览层扫描随会话启动 | T59 |
| 64 | [`22bd752`](https://github.com/Lakr233/vphone-cli/commit/22bd752) | C | 空闲性能 | 相机帧驱动按客户端需求开启 | T59 |
| 65 | [`40f4f3e`](https://github.com/Lakr233/vphone-cli/commit/40f4f3e) | C | 模板与首启 | 首启等待数据迁移并显示进度 | T49/T50 |
| 66 | [`eebe680`](https://github.com/Lakr233/vphone-cli/commit/eebe680) | C | 模板与首启 | 跳过设置向导时不打断迁移中的 SpringBoard | T49/T50 |
| 67 | [`e73cdda`](https://github.com/Lakr233/vphone-cli/commit/e73cdda) | C | 输入与剪贴板 | 右键执行次要点击而非 Home | T06/T23/T38/T39 |
| 68 | [`625f6c6`](https://github.com/Lakr233/vphone-cli/commit/625f6c6) | M | 输入与剪贴板 | 合并 #640：guest 应用剪贴板 | T06/T23/T38/T39 |
| 69 | [`328ff74`](https://github.com/Lakr233/vphone-cli/commit/328ff74) | C | 依赖构建 | 发布 2.9.0 | T08/T24/T29/T40 |
| 70 | [`b4f00fc`](https://github.com/Lakr233/vphone-cli/commit/b4f00fc) | D | 文档与格式 | 按 Swift 6.2 执行格式化 | T28/T29 |
| 71 | [`2276a0d`](https://github.com/Lakr233/vphone-cli/commit/2276a0d) | C | 输入与剪贴板 | daemon 可观察真实 guest 应用的复制行为 | T06/T23/T38/T39 |
| 72 | [`9957d0a`](https://github.com/Lakr233/vphone-cli/commit/9957d0a) | M | 模板与首启 | 合并 #633：模板化机器创建 | T49/T50 |
| 73 | [`ab441ae`](https://github.com/Lakr233/vphone-cli/commit/ab441ae) | C | 磁盘重整 | 修正 rebase 两处提示 | T51/T52 |
| 74 | [`eec7350`](https://github.com/Lakr233/vphone-cli/commit/eec7350) | C | 磁盘重整 | rebase 只把新增共享块算作节省 | T51/T52 |
| 75 | [`f9c6980`](https://github.com/Lakr233/vphone-cli/commit/f9c6980) | C | Bundle绑定 | 环境更新真正启动后才输出开始提示 | T52 |
| 76 | [`c36e7d6`](https://github.com/Lakr233/vphone-cli/commit/c36e7d6) | C | Bundle绑定 | 绑定并更新前先检查磁盘占用 | T52 |
| 77 | [`eb77997`](https://github.com/Lakr233/vphone-cli/commit/eb77997) | C | 模板与首启 | Inspector 按模板 build 匹配来源 | T49/T50 |
| 78 | [`5952484`](https://github.com/Lakr233/vphone-cli/commit/5952484) | C | 固件与磁盘安全 | 区分运行 VM 与普通磁盘读取进程 | T52 |
| 79 | [`77efe89`](https://github.com/Lakr233/vphone-cli/commit/77efe89) | C | 模板与首启 | Launchpad CLI 创建支持逐补丁覆盖 | T49/T50 |
| 80 | [`e31942a`](https://github.com/Lakr233/vphone-cli/commit/e31942a) | C | 磁盘重整 | 不打开运行中机器的磁盘做占用计量 | T51/T52 |
| 81 | [`9a35217`](https://github.com/Lakr233/vphone-cli/commit/9a35217) | C | 模板与首启 | 按构建批次统计模板使用者和删除影响 | T49/T50 |
| 82 | [`5a9db70`](https://github.com/Lakr233/vphone-cli/commit/5a9db70) | C | 生命周期 | stop 只向目标机器所属进程发信号 | T52 |
| 83 | [`6e0488c`](https://github.com/Lakr233/vphone-cli/commit/6e0488c) | C | 系统精简 | 重启提示保留到 guest 确实重启 | T50 |
| 84 | [`1029b23`](https://github.com/Lakr233/vphone-cli/commit/1029b23) | C | 模板与首启 | 固定模板构建键，guest 覆盖留给克隆 | T49/T50 |
| 85 | [`9e063a7`](https://github.com/Lakr233/vphone-cli/commit/9e063a7) | C | 磁盘重整 | 按物理区间而非 APFS private size 计量 | T51/T52 |
| 86 | [`bfeb362`](https://github.com/Lakr233/vphone-cli/commit/bfeb362) | C | 模板与首启 | 固定请求键并在无下载情况下查找模板 | T49/T50 |
| 87 | [`4d9d188`](https://github.com/Lakr233/vphone-cli/commit/4d9d188) | C | 导入导出与UI | 统一模板列表中的精简服务名称 | T60 |
| 88 | [`0de9048`](https://github.com/Lakr233/vphone-cli/commit/0de9048) | C | 模板与首启 | Launchpad 接入精简模板创建 | T49/T50 |
| 89 | [`84eefee`](https://github.com/Lakr233/vphone-cli/commit/84eefee) | C | 模板与首启 | 无原始 IPSW 时查找模板并记录来源 | T49/T50 |
| 90 | [`b4f5963`](https://github.com/Lakr233/vphone-cli/commit/b4f5963) | C | 固件与磁盘安全 | 修复长 socket 路径 mkdtemp 缓冲区生命周期 | T52 |
| 91 | [`7b6f2f6`](https://github.com/Lakr233/vphone-cli/commit/7b6f2f6) | C | 固件与磁盘安全 | 模板裁剪挂盘改用 diskutil | T52 |
| 92 | [`f0a67c0`](https://github.com/Lakr233/vphone-cli/commit/f0a67c0) | C | 系统精简 | 离线裁剪模板 System 卷并清理残留 | T50 |
| 93 | [`a9eb109`](https://github.com/Lakr233/vphone-cli/commit/a9eb109) | C | 模板与首启 | 模板增加准备启动与精简选项 | T49/T50 |
| 94 | [`8dbf387`](https://github.com/Lakr233/vphone-cli/commit/8dbf387) | C | 模板与首启 | 新增模板及模板化 vm create | T49/T50 |
| 95 | [`3e6437c`](https://github.com/Lakr233/vphone-cli/commit/3e6437c) | C | 模板与首启 | 模板步骤记录 guest APFS 快照删除 | T49/T50 |
| 96 | [`80f4951`](https://github.com/Lakr233/vphone-cli/commit/80f4951) | C | 协议与错误 | 控制 socket 透传 guest 完整错误对象 | T06/T07/T36 |
| 97 | [`2a41d10`](https://github.com/Lakr233/vphone-cli/commit/2a41d10) | C | 系统精简 | 修正快照 entitlement 与跨卷系统应用备份 | T50 |
| 98 | [`5ebfa46`](https://github.com/Lakr233/vphone-cli/commit/5ebfa46) | C | 系统精简 | 新增系统应用移除与 orig-fs 快照删除 | T50 |
| 99 | [`975553e`](https://github.com/Lakr233/vphone-cli/commit/975553e) | C | 系统精简 | 新增服务配置与首启稳定等待 | T50 |
| 100 | [`7064a82`](https://github.com/Lakr233/vphone-cli/commit/7064a82) | M | 模板与首启 | 分支同步 origin/main | T49/T50 |
| 101 | [`9c9446a`](https://github.com/Lakr233/vphone-cli/commit/9c9446a) | C | 依赖构建 | IcliKit 0.7.18 放宽 IPA 解包容量 | T08/T24/T29/T40 |
| 102 | [`4254854`](https://github.com/Lakr233/vphone-cli/commit/4254854) | C | 固件与磁盘安全 | 环境及内核更新支持 --work-parent | T52 |
| 103 | [`7d22444`](https://github.com/Lakr233/vphone-cli/commit/7d22444) | C | 固件与磁盘安全 | 按位解释设备号以避免有符号转换陷阱 | T52 |
| 104 | [`65ddcc9`](https://github.com/Lakr233/vphone-cli/commit/65ddcc9) | M | 固件与磁盘安全 | 合并 #632：外置卷临时工作区 | T52 |
| 105 | [`caa9dbd`](https://github.com/Lakr233/vphone-cli/commit/caa9dbd) | M | 定位 | 合并 #636：iOS 27 locationd 启动竞争 | T20/T36/T43 |
| 106 | [`d3df4e5`](https://github.com/Lakr233/vphone-cli/commit/d3df4e5) | M | 运动传感器 | 合并 #635：陀螺仪及姿态模拟 | T54 |
| 107 | [`8b1b07b`](https://github.com/Lakr233/vphone-cli/commit/8b1b07b) | M | 磁盘重整 | 合并 #617：vm rebase | T51/T52 |
| 108 | [`2a1e03a`](https://github.com/Lakr233/vphone-cli/commit/2a1e03a) | C | 磁盘重整 | rebase 让现有磁盘共享相同块 | T51/T52 |
| 109 | [`1e9dc6b`](https://github.com/Lakr233/vphone-cli/commit/1e9dc6b) | C | 定位 | 修复 iOS 27 locationd cohort 竞争 | T20/T36/T43 |
| 110 | [`b2a1861`](https://github.com/Lakr233/vphone-cli/commit/b2a1861) | D | 文档与格式 | 刷新 Launchpad 提取的本地化条目 | T28/T29 |
| 111 | [`193f575`](https://github.com/Lakr233/vphone-cli/commit/193f575) | C | 运动传感器 | 显示应用增加实时姿态控制 | T54 |
| 112 | [`e36f537`](https://github.com/Lakr233/vphone-cli/commit/e36f537) | C | 运动传感器 | guest 增加设备姿态模拟 | T54 |
| 113 | [`67a05e5`](https://github.com/Lakr233/vphone-cli/commit/67a05e5) | C | 运动传感器 | 显示应用增加实时陀螺仪控制 | T54 |
| 114 | [`6b55fed`](https://github.com/Lakr233/vphone-cli/commit/6b55fed) | C | 固件与磁盘安全 | CFW scratch 使用 VM 所在外置卷 | T52 |
| 115 | [`0be9528`](https://github.com/Lakr233/vphone-cli/commit/0be9528) | C | 运动传感器 | 新增虚拟 HID 陀螺仪与 motion RPC | T54 |
| 116 | [`ddf168b`](https://github.com/Lakr233/vphone-cli/commit/ddf168b) | M | 固件与磁盘安全 | 合并 #631：CFW 临时目录修复 | T52 |
| 117 | [`4bd1d3b`](https://github.com/Lakr233/vphone-cli/commit/4bd1d3b) | C | 固件与磁盘安全 | 修复 CFW mkdtemp 缓冲区生命周期 | T52 |
| 118 | [`738983e`](https://github.com/Lakr233/vphone-cli/commit/738983e) | M | 固件与磁盘安全 | 合并 #630：diskutil 迁移 | T52 |
| 119 | [`a7fd759`](https://github.com/Lakr233/vphone-cli/commit/a7fd759) | M | 固件与磁盘安全 | diskutil 分支同步 main | T52 |
| 120 | [`1cc651a`](https://github.com/Lakr233/vphone-cli/commit/1cc651a) | M | Xcode与Flutter | 合并 #627：Flutter AOT 映射修复 | T53 |
| 121 | [`0768640`](https://github.com/Lakr233/vphone-cli/commit/0768640) | C | 固件与磁盘安全 | 替换弃用的 hdiutil 调用 | T52 |
| 122 | [`4391c10`](https://github.com/Lakr233/vphone-cli/commit/4391c10) | C | Xcode与Flutter | 修复 Flutter AOT 重映射丢失 RX 权限 | T53 |
| 123 | [`dfcfae9`](https://github.com/Lakr233/vphone-cli/commit/dfcfae9) | M | 固件下载 | 合并 #626：多连接 IPSW 下载 | T57 |
| 124 | [`fc6456f`](https://github.com/Lakr233/vphone-cli/commit/fc6456f) | C | 固件下载 | IPSW 多连接下载 | T57 |
| 125 | [`65a0e9b`](https://github.com/Lakr233/vphone-cli/commit/65a0e9b) | C | 依赖构建 | 发布 2.8.0 | T08/T24/T29/T40 |
| 126 | [`3823a55`](https://github.com/Lakr233/vphone-cli/commit/3823a55) | M | Xcode与Flutter | 合并 #624：分带屏幕流 GPU 死锁 | T53 |
| 127 | [`a11e857`](https://github.com/Lakr233/vphone-cli/commit/a11e857) | M | 固件下载 | 合并 #623：已下载 IPSW 管理 | T57 |
| 128 | [`038be1d`](https://github.com/Lakr233/vphone-cli/commit/038be1d) | M | 导入导出与UI | 合并 #622：iPadOS 标签 | T60 |
| 129 | [`66956a8`](https://github.com/Lakr233/vphone-cli/commit/66956a8) | C | Xcode与Flutter | 避免 banded stream 卡死宿主 GPU | T53 |
| 130 | [`1c2c23e`](https://github.com/Lakr233/vphone-cli/commit/1c2c23e) | C | 固件下载 | Launchpad 列出与删除缓存 IPSW | T57 |
| 131 | [`a85ecbb`](https://github.com/Lakr233/vphone-cli/commit/a85ecbb) | D | 文档与格式 | 统一中文快照操作文案 | T28/T29 |
| 132 | [`4d34bbe`](https://github.com/Lakr233/vphone-cli/commit/4d34bbe) | C | 导入导出与UI | iPad guest 显示 iPadOS 标签 | T60 |
| 133 | [`a9608f3`](https://github.com/Lakr233/vphone-cli/commit/a9608f3) | M | 定位 | 合并 #616：guest 定位服务 | T20/T36/T43 |
| 134 | [`d00f29c`](https://github.com/Lakr233/vphone-cli/commit/d00f29c) | M | Xcode与Flutter | 合并 #614：Xcode persona lookup | T53 |
| 135 | [`7f4760d`](https://github.com/Lakr233/vphone-cli/commit/7f4760d) | M | Xcode与Flutter | persona 分支同步 origin/main | T53 |
| 136 | [`289f46a`](https://github.com/Lakr233/vphone-cli/commit/289f46a) | M | 应用与Bootstrap | 合并 #618：spawn 内存额度 | T18/T21/T43 |
| 137 | [`fa3c252`](https://github.com/Lakr233/vphone-cli/commit/fa3c252) | M | 应用与Bootstrap | 分支同步 origin/main | T18/T21/T43 |
| 138 | [`7ddc6df`](https://github.com/Lakr233/vphone-cli/commit/7ddc6df) | M | 应用与Bootstrap | 合并 #619：包管理应用注册 | T18/T21/T43 |
| 139 | [`f6b57bc`](https://github.com/Lakr233/vphone-cli/commit/f6b57bc) | M | 依赖构建 | 合并 #621：IcliKit 0.7.17 | T08/T24/T29/T40 |
| 140 | [`1c77108`](https://github.com/Lakr233/vphone-cli/commit/1c77108) | C | 定位 | 重启启动阶段已死锁的 locationd | T20/T36/T43 |
| 141 | [`3e71620`](https://github.com/Lakr233/vphone-cli/commit/3e71620) | M | 登录与设置策略 | 合并 #620：登录提示抑制 | T58 |
| 142 | [`5be1f18`](https://github.com/Lakr233/vphone-cli/commit/5be1f18) | C | 依赖构建 | IcliKit 0.7.17 对齐 uicache 注册记录 | T08/T24/T29/T40 |
| 143 | [`e0415d1`](https://github.com/Lakr233/vphone-cli/commit/e0415d1) | M | 定位 | 定位分支同步 upstream/main | T20/T36/T43 |
| 144 | [`fe991fc`](https://github.com/Lakr233/vphone-cli/commit/fe991fc) | C | 登录与设置策略 | 增加登录抑制和设置建议隐藏库 | T58 |
| 145 | [`f1accd8`](https://github.com/Lakr233/vphone-cli/commit/f1accd8) | M | 固件与磁盘安全 | 合并 #613：删除无效 boot-args 写入 | T52 |
| 146 | [`19bd0f4`](https://github.com/Lakr233/vphone-cli/commit/19bd0f4) | M | 设备名称 | 合并 #609：guest 设备名称 | T55 |
| 147 | [`5050c4d`](https://github.com/Lakr233/vphone-cli/commit/5050c4d) | C | 定位 | 宿主定位开关保持在当时 2.7 series | T20/T36/T43 |
| 148 | [`872a8b4`](https://github.com/Lakr233/vphone-cli/commit/872a8b4) | C | 应用与Bootstrap | 包操作后注册 bootstrap 内的应用 | T18/T21/T43 |
| 149 | [`269517f`](https://github.com/Lakr233/vphone-cli/commit/269517f) | C | 应用与Bootstrap | bootstrap 活跃时提高 spawn 的 jetsam 额度 | T18/T21/T43 |
| 150 | [`c96decf`](https://github.com/Lakr233/vphone-cli/commit/c96decf) | C | 定位 | 宿主定位同步变为可持久化的每机开关 | T20/T36/T43 |
| 151 | [`15a5af7`](https://github.com/Lakr233/vphone-cli/commit/15a5af7) | C | Xcode与Flutter | 修复 iOS 27 CoreDevice 安装 persona 查询 | T53 |
| 152 | [`4702333`](https://github.com/Lakr233/vphone-cli/commit/4702333) | C | 固件与磁盘安全 | 停止写入 guest 不读取的 NVRAM 启动参数 | T52 |
| 153 | [`3d4a9d0`](https://github.com/Lakr233/vphone-cli/commit/3d4a9d0) | D | 设备名称 | 记录设备名传递路径与测量 | T55 |
| 154 | [`2fc8850`](https://github.com/Lakr233/vphone-cli/commit/2fc8850) | C | 设备名称 | 设备名由 vphoned 传递，不再依赖 NVRAM | T55 |
| 155 | [`4391ded`](https://github.com/Lakr233/vphone-cli/commit/4391ded) | C | 设备名称 | daemon 接受宿主固定设备名 | T55 |
| 156 | [`c7fdced`](https://github.com/Lakr233/vphone-cli/commit/c7fdced) | C | 设备名称 | 名称 Hook 从 daemon 保存文件读取 | T55 |
| 157 | [`ba9d023`](https://github.com/Lakr233/vphone-cli/commit/ba9d023) | M | 固件与磁盘安全 | 合并 #611：每机 CFW 锁 | T52 |
| 158 | [`73d0253`](https://github.com/Lakr233/vphone-cli/commit/73d0253) | M | Bundle绑定 | 合并 #610：删除不依赖原 Bundle | T52 |
| 159 | [`b36dbaa`](https://github.com/Lakr233/vphone-cli/commit/b36dbaa) | C | 固件与磁盘安全 | 不同机器的 CFW 操作允许并行 | T52 |
| 160 | [`2745535`](https://github.com/Lakr233/vphone-cli/commit/2745535) | C | Bundle绑定 | 原 Core Bundle 缺失时仍可删除机器 | T52 |
| 161 | [`0e59e69`](https://github.com/Lakr233/vphone-cli/commit/0e59e69) | D | 设备名称 | 说明 guest 固定名取自 VM 名称 | T55 |
| 162 | [`a312b8f`](https://github.com/Lakr233/vphone-cli/commit/a312b8f) | C | 设备名称 | 中间实现：启动前经 NVRAM 传递名称 | T55 |
| 163 | [`8825d63`](https://github.com/Lakr233/vphone-cli/commit/8825d63) | D | 设备名称 | 补充名称固定机制文档 | T55 |
| 164 | [`8b31d00`](https://github.com/Lakr233/vphone-cli/commit/8b31d00) | C | 设备名称 | guest 环境加入 libdevicename | T55 |
| 165 | [`e5bcf80`](https://github.com/Lakr233/vphone-cli/commit/e5bcf80) | C | 设备名称 | 中间实现：从 NVRAM 固定设备名 | T55 |
| 166 | [`fc80ed6`](https://github.com/Lakr233/vphone-cli/commit/fc80ed6) | C | 应用与Bootstrap | spawn Hook 支持一次注入多库 | T18/T21/T43 |
| 167 | [`f755645`](https://github.com/Lakr233/vphone-cli/commit/f755645) | C | 依赖构建 | 发布 2.7.0 | T08/T24/T29/T40 |
| 168 | [`45fab51`](https://github.com/Lakr233/vphone-cli/commit/45fab51) | M | Xcode与Flutter | 合并 #604：DeviceHub 屏幕 | T53 |
| 169 | [`2e39906`](https://github.com/Lakr233/vphone-cli/commit/2e39906) | D | Xcode与Flutter | 整理 DeviceHub 研究说明 | T53 |
| 170 | [`fc22a9d`](https://github.com/Lakr233/vphone-cli/commit/fc22a9d) | D | Xcode与Flutter | 记录高负载多屏流的停顿和延迟 | T53 |
| 171 | [`1e5c465`](https://github.com/Lakr233/vphone-cli/commit/1e5c465) | D | Xcode与Flutter | 记录安静宿主单路 DeviceHub 测试 | T53 |
| 172 | [`25d19e5`](https://github.com/Lakr233/vphone-cli/commit/25d19e5) | D | Xcode与Flutter | 记录 DeviceHub 矩阵与编码停顿 | T53 |
| 173 | [`aa20eb8`](https://github.com/Lakr233/vphone-cli/commit/aa20eb8) | M | 身份克隆 | 合并 #605：新身份克隆与磁盘快照 | T47 |
| 174 | [`773b6c1`](https://github.com/Lakr233/vphone-cli/commit/773b6c1) | M | 登录与设置策略 | 合并 #606：可选 Settings 行隐藏 | T58 |
| 175 | [`1cdcad7`](https://github.com/Lakr233/vphone-cli/commit/1cdcad7) | M | 生命周期 | 合并 #608：退出前关闭 guest | T52 |
| 176 | [`5cc2b28`](https://github.com/Lakr233/vphone-cli/commit/5cc2b28) | M | 导入导出与UI | 合并 #607：空闲磁盘空间刷新 | T60 |
| 177 | [`9cefcbd`](https://github.com/Lakr233/vphone-cli/commit/9cefcbd) | C | 生命周期 | 窗口及命令退出统一先关闭 guest | T52 |
| 178 | [`f496cfe`](https://github.com/Lakr233/vphone-cli/commit/f496cfe) | C | Xcode与Flutter | 已装 iOS 27 独立迁移 force-kern 补丁 | T53 |
| 179 | [`de8774c`](https://github.com/Lakr233/vphone-cli/commit/de8774c) | C | 导入导出与UI | Launchpad 打开期间刷新可用磁盘空间 | T60 |
| 180 | [`80d4735`](https://github.com/Lakr233/vphone-cli/commit/80d4735) | C | 协议与错误 | 集中封装 vphone.sock 连接 | T06/T07/T36 |
| 181 | [`272b75f`](https://github.com/Lakr233/vphone-cli/commit/272b75f) | D | 系统精简 | 记录可恢复移除 Wallet 的研究 | T50 |
| 182 | [`680b3a0`](https://github.com/Lakr233/vphone-cli/commit/680b3a0) | C | 磁盘快照 | 无来源快照恢复后将环境标为未知 | T48 |
| 183 | [`6ed4954`](https://github.com/Lakr233/vphone-cli/commit/6ed4954) | C | 身份克隆 | 复制完成再次确认源机器停机 | T47 |
| 184 | [`84b9f7d`](https://github.com/Lakr233/vphone-cli/commit/84b9f7d) | C | 磁盘快照 | 加强快照整组恢复与元数据校验 | T48 |
| 185 | [`623abab`](https://github.com/Lakr233/vphone-cli/commit/623abab) | C | 固件与磁盘安全 | socket 拒绝当前用户时按运行中处理 | T52 |
| 186 | [`b07d6df`](https://github.com/Lakr233/vphone-cli/commit/b07d6df) | C | 登录与设置策略 | 新增可选 Settings 行隐藏及研究说明 | T58 |
| 187 | [`8f20100`](https://github.com/Lakr233/vphone-cli/commit/8f20100) | C | 身份克隆 | 克隆与快照复用状态文件及身份规则 | T47 |
| 188 | [`ac8268b`](https://github.com/Lakr233/vphone-cli/commit/ac8268b) | D | Xcode与Flutter | 将 DeviceHub 研究重写为参考文档 | T53 |
| 189 | [`4f6cf11`](https://github.com/Lakr233/vphone-cli/commit/4f6cf11) | C | Xcode与Flutter | 修复 iOS 27 DeviceHub 捕获显示 | T53 |
| 190 | [`62b388d`](https://github.com/Lakr233/vphone-cli/commit/62b388d) | C | Xcode与Flutter | 使 Xcode DeviceHub 可展示 guest 屏幕 | T53 |
| 191 | [`d898718`](https://github.com/Lakr233/vphone-cli/commit/d898718) | C | 磁盘快照 | Launchpad 接入新身份克隆与快照 | T48 |
| 192 | [`ba2ea41`](https://github.com/Lakr233/vphone-cli/commit/ba2ea41) | C | 身份克隆 | 克隆可重新生成设备身份 | T47 |
| 193 | [`ead66d1`](https://github.com/Lakr233/vphone-cli/commit/ead66d1) | C | 磁盘快照 | 新增停机磁盘状态快照命令 | T48 |
| 194 | [`673e9e9`](https://github.com/Lakr233/vphone-cli/commit/673e9e9) | C | 固件与磁盘安全 | 写状态前判断机器是否正在运行 | T52 |

完整处置建议、旧任务多对多关联及演进注意事项在 JSON/CSV 对应行中；表中合并记录不是额外重复功能。
