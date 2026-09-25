# 上游融合实施计划

更新日期：2026-09-25。本文持续维护实施决策、阶段、验收条件和执行状态；历史全文保留在 Git 中。

本计划依据 [上游与本地仓库对比分析](upstream_comparison.md)，选择性吸收上游模块，同时保留本地多变体、检查点续跑、自动化合约和补丁约束。当前目标包含 Xcode/bundle、IcliKit 0.6.9、相机 ABI 和 Irisin/SystemHook 的适配工作。

本次交付为分析与计划。除已列出的取证和环境检查外，所有代码阶段均未开始。

## 1. 固定输入

| 对象 | 固定值 |
| --- | --- |
| 实施分支 | `codex/upstream-4bab3b7-integration`，本次不改名 |
| 当前本地起点 | `9489ab296e3c1d345f936135b370d51da7a3c65d` |
| 新上游目标 | `08db376d9417a7ec0779967d6b2e748e3638d3c6` |
| 上一版目标 | `4bab3b76b3a2b6c5d68fecd292348176dbc18c4e`，仅用于增量对比 |
| 上游 tag | `1.0.13` = 共同祖先；1.x 稳定 `1.0.14` → `9c23c8a`；2.x pre-release `2.0.0` → `3aa5561`（`08db376` 在其后只改 CI workflow） |
| 分析与路径映射 | [当前对比报告](upstream_comparison.md) |
| Git 证据 | [57 个提交及冲突清单](upstream_review_08db376_conflicts_2026-09-25.txt) |

固定输入不能替换为浮动 `main`。继续使用现有实施分支，分阶段提交；不整批 merge/cherry-pick 57 个增量提交。上游 hook 曾撤销再重做，选择性移植以固定最终源码及其依赖为依据。

版本锚点按[对比报告 1.1 节](upstream_comparison.md#11-上游-tag-与版本线)：1.x 版本线上的修复从 1.x tag 取提交并用 `git cherry-pick -x` 记录来源；2.x 结构迁移以 `2.0.0` 或之后的 tag 为锚点，`main` 上 tag 之后的提交单独列出。

## 2. 保留决定与新增决定

- 保留 regular/dev/jb/exp/less 入口、默认 regular 及各变体既有环境。新 v2 验证路径先建立 JB 最小组合，未验收的其他组合继续使用现有后端；不静默改默认变体。
- 保留 `VPhoneCreateRunner`、检查点、`--resume`、`--restart-from`、`create-status` 和产物保留规则。原生化替换阶段实现，不直接复制上游顺序 creator。
- 保留 VM/库锁、离线占用保护、PID+启动时间校验及 DFU owner。进程拆分后由实际 `vphone-vm` 持 VM 锁。
- 保留宿主 Unix socket、同用户检查、headless、shell、定位 owner/generation/sequence、相机 generation/presentation_id 与消费回执、期限/取消/迟到响应及整次手势路由。
- 保留 PatchOutcome、必需步骤、事务、消融与研究记录。本次增量中 50 个上游内核 Swift 文件内容未变；不以新目录为理由重做已有匹配器。
- 新 VM 格式先采用新建 v2 bundle。旧 bundle 不自动加版本字段，不原地升级；保留可用旧格式路径和显式不兼容诊断。less 单独取证。
- 构建、资源和依赖适配提前。Makefile 与现有测试 runner 保留到替代入口完成验收；目录改名独立提交，不把上游整个 Xcode 工程当作本地测试清单。
- 不吸收递归 `0777`。采用调用用户所有权恢复和明确的访问权限；提权由本地受控入口处理，不假设新 bundle 会弹密码框。
- daemon 直接链接 IcliKit/IcliSystem，不再要求安装上游已删除的 icli 可执行文件或 `icli.execute`。任意 shell 仍需本地实现和运行环境。
- 新 bootstrap/launchd/SystemHook 作为显式可选能力。首轮不接管已有 Procursus，不默认切换 RootHide，也不将 payload 安装完成记为服务/tweak 可用。
- TCP 默认关闭；启用时默认 loopback。非 loopback 访问控制完成前不作为可交付入口。`force` 字段不替代认证。
- 固定外部运行输入：Irisin 实际 tag、架构、URL、摘要进入记录；GitHub `releases/latest` 不能作为可复现实验的唯一标识。

已完成且无需重复移植：导入 staging 校验、APFS clone、postValidation 幂等识别和 shell 覆盖结论修正。完整 IPSW clone 效果仍需实际准备验收。

## 3. 与 `4bab3b7` 基线阶段的对应关系

| 旧阶段 | 新安排 | 调整原因 |
| --- | --- | --- |
| P0 基线 | P0 | 固定新 SHA，重新模拟；测试基线仍待运行 |
| P1 catalog / EXP 相机 DSC | P1 | 内容保留，两个独立提交 |
| P2 Sign/Archive/Restore | P2 原生库构建，P3 恢复执行 | 新资源布局、归档依赖和 root 边界需要配套适配 |
| P3 进程拆分 | P3 | 与恢复身份、权限和资源定位一起验收 |
| P4 HTTP/WS | P5 | P4 先产生可用于真实验收的配套新镜像，避免等待关系不明确 |
| P5 v2/固件/CFW | P4 最小新镜像，P6 bootstrap | 将默认系统安装与可选用户环境分开验证 |
| P6 目录/构建/CI | P2 构建基础，P7 UI，P8 最终分发 | 构建不再全部放在最后；测试入口从首阶段持续保留 |

依赖顺序：P0 → P1；P0 → P2 → P3 → P4 → P5 → P6。P7 依赖 P5；P8 汇总所有实际交付范围。P1 与原生模块改造互不依赖，但最终 EXP 验收需包含 P1b。

## 4. 阶段与完成条件

### P0：基线、测试清单与环境

已完成：固定对象与共同祖先、增量提交、职责映射、两次合并模拟、工具链和夹具检查。当前新上游模拟为 277 个未合并路径；计数不能用于估工时。

实施前完成：

1. 运行 `make test`，记录命令、退出状态和日志；区分原有失败与后续引入的失败。
2. 将旧计划涉及的测试目标与当前 Xcode schemes 对应，保留 `FirmwareIntegrationTests` 和快速测试隔离、Python suite、F1/F2/F3 工具。
3. 为每个迁移模块记录上游 SHA/路径、本地入口、保留合约、依赖版本/许可证、测试和真实验收状态。
4. 准备独立 VM 测试 bundle 和固定固件组合。默认 `ipsws/patch_refactor_input` 当前缺 17 个文件；配置完整 `VPHONE_TEST_FIXTURES` 后重跑存在性检查。缺夹具时继续无固件工作，真实二进制对比保持未验收。

完成条件：源码输入和测试结果可重现；缺失环境明确记录。本次未运行 `make test`，不把 P0 标为全部完成。

### P1：独立修正

**P1a 固件目录**：cherry-pick 上游 `1.0.14` 的 `9c23c8a`，增加 26.6.2/23G90、27.0 RC/24A435，配对 cloudOS 26.4/23E5207q。该提交使用本地目录布局，已含 `FirmwarePickerTests` 计数 23→25；merge-tree 显示可干净应用到 `71bbf60`。不从 2.x 路径手工抄写 URL；两条 URL 与 `08db376` 中 2.x catalog 的对应条目一致。

1. 执行 `git cherry-pick --no-commit 9c23c8a`（`--no-commit` 时 `-x` 不写入来源，提交信息需手工加入 `(cherry picked from commit 9c23c8adcd4b362120988ab9d228b959bcc23ae3)`）。保留 catalog 与测试改动；README 及 ja/ko/zh 译文的 Tested Environments 行记录的是上游在 Mac16,6 26.6.1 上的测试，不是本地实测，是否保留待决定。
2. 同一提交内同步本地兼容性清单：`research/firmware_compatibility.json` 的 `firmware.ios` 增加两条 `source: catalog` 记录，`combinations` 增加两条 `stage: code_selectable`、五个变体的组合（参照现有 `cs-23G83` 格式，cloudOS 构建号为 null）；`research/firmware_compatibility.md` 及 README 与 ja/ko/zh 译文支持矩阵段落中的 catalog 配对计数（当前为 23，每段出现两处）同步为 25，范围描述“18.6.2 至 27.0 beta”同步包含 27.0 RC。按测试源码，只合入 catalog 会使 `FirmwareCompatibilityManifestTests.catalogPairingsMatchManifest` 失败（catalog 与清单不一致），该结论尚未运行验证。
3. 保留现有条目和默认选择。执行 `make test`（覆盖 Swift catalog/清单一致性与 Python `test_firmware_compatibility.py`），并检查 `fw catalog --json` 输出与交互选择。新条目只记为 code_selectable，不表示任何变体已支持。

**P1b EXP 相机 DSC**：改造 `scripts/patchers/cfw_patch_camera_dsc.py`，六个目标全部解析、读取、分类后才写入；区分原始、已补丁、不匹配，补齐混合输入。保留 AVF-only、dry-run 和显式 force 行为；指令继续使用 Keystone helper，记录 offset、前后字节和状态。

测试覆盖全部原始、全部已补丁、NU 已补丁/AVF 原始、组内混合、最后目标不匹配、缺符号、短读、dry-run、AVF-only、写入和页面哈希失败。默认不匹配输入要求六站点零写入；成功后检查字节和修改页哈希。预检查不承诺 I/O 失败回滚。运行 `make test_python`，再用真实 DSC 副本验证哈希；EXP 安装捕获错误后继续的策略单列。

完成条件：两项相关回归通过；真实输入缺失时准确标记未验证。新补丁同步 `research/0_binary_patch_comparison.md`。

### P2：构建基础、资源及原生库

依赖 P0。先保持本地现有路径可构建，再引入对应模块；不得先删除 Package.swift、Makefile 或现有测试。

1. 建立本地目标到 Xcode/bundle 的清单：CLI、VM 子进程、Core、Sign、Archive、Restore、daemon、guest dylibs、字符串及 entitlements。Sign/Archive/Restore 的源码迁移与目标接线分为可审查提交。
2. 引入 `VPhoneSign`、`VPhoneArchiveKit`、`VPhoneRestore`/MobileRestoreCore；适配现有接口与测试。归档依赖核对 ArchiveKit 1.0.0，恢复依赖核对固定 AppleMobileDeviceLibrary。保留本地归档 staging、manifest 校验、排他发布和权限策略。
3. 固定 IcliKit 0.6.9（`74843a56df54936c3949239a4ffb3ddcbe37dee4`）、daemon Swift Collections 1.6.0、SwiftNIO 2.83.0；核对实际参与构建的各 lockfile。宿主与 iOS 的依赖图分别验证，不盲目统一子工程版本。
4. 构建 daemon 和 guest components；校验 `_swift_initBorrow`、iOS deployment target、架构和 entitlements。保留所有本地 capability 对应的资源，不按上游 bundle 缺少某项就删除本地资源。
5. 确立 `Contents/MacOS`/`Contents/Resources` 及开发树路径解析；支持 PATH、符号链接和任意 cwd 启动。GPU compiler plugin 从 dylib 定位；`.vphoned.signed` 安装和更新源必须一致。
6. 将 bundle 校验接入本地构建包装：二进制清单、签名权限隔离、资源、动态依赖、归档往返。继续由 `make build` 生成可执行 VM 的实际签名产物；若实现切换到 xcodebuild，由 Makefile 包装并更新项目说明。

验证：Sign 的损坏输入、entitlements、重复签名、实际执行；Archive 的权限、硬/符号链接、稀疏文件、路径越界、无效 manifest、名称冲突、运行中拒绝；原生 Restore 先测解析/probe/ticket/错误映射。每个新增模块接入无固件套件，完成后运行 `make test`。

完成条件：旧入口和新模块都可构建、相关测试通过，实际 bundle 通过校验。Xcode 编译通过不等于真实恢复或 VM 通过。

### P3：VM 进程、提权、生命周期与恢复

依赖 P2。迁入 `vphone-vm` 进程，配套修改 `VPhoneLaunchLayout`、`VPhoneVMStopper`、`VPhoneBundleGuard`、DFU owner、资源定位和 doctor。CLI 父进程不冒充 VM 身份；实际 VM 子进程持锁并在退出后释放。

保留本地受控 sudo 重执行：只传递所需环境和 bundle 路径，明确 `SUDO_UID/GID` 对库根目录和产物所有权的影响。CFW 和 deviceinterfaced 操作的非 root 错误、无 TTY、取消与失败清理都需测试。迁入所有权恢复时不引入 `VPhoneHostFilePermissions` 的递归 `0777`，也不在“目标已存在”等拒绝路径修改现有数据权限。

原生 Restore 接入现有阶段 runner，保持 ECID/UDID 选择、DFU owner、超时、取消、错误状态和资源清理。真实恢复前完成 probe/ticket 与故障路径验证；真实恢复使用独立 bundle，不替换可用旧后端直至验收完成。

验证：GUI/headless/DFU 启停、重复启动拒绝、双 VM、父进程退出、子进程异常退出、PID 重用、启动失败、锁释放、离线操作拒绝、不同 sudo 环境的产物所有权。不能以 lsof PID 替代停止身份校验。使用 `make build` 产物，不用 plain `swift build` 作为 VM 运行验收。

完成条件：生命周期回归、签名诊断与真实恢复/双 VM 证据齐备；未验收的恢复路径保留旧后端。

### P4：新建 v2 镜像、原生固件与最小客户机

依赖 P2、P3。先通过显式验证入口构建一个新的 JB v2 测试组合，不替代默认 create 和既有 VM。该阶段提供 P5 的真实客户机输入，P5 再补齐完整本地控制合约。

1. manifest 版本诊断覆盖扫描、启动、创建、克隆、导入导出；显示不兼容原因，不静默漏掉旧 bundle。旧格式路径继续存在。
2. 原生 prepare/CFW 接入 checkpoint runner，维护七阶段记录及 variant 规则。引入每 VM staging、下载 `.partial`、失败清理和挂载残留报告。共享缓存和 restore 符号链接的旧输入需明确支持、物化或拒绝，不隐式改路径。
3. 保留 `retain_until`：CFW 后不能直接删掉 first_boot/verification 失败时仍需的 restore tree。测试中断、续跑、`--restart-from`、`--keep-artifacts`、旧产物与工具版本变化。
4. 安装配套 HTTP daemon、所需运行库、launchd plist 和已签名二进制。先验证 health、签名摘要与启动；同字节输入不触发首次启动重复自更新。此验证不要求 Irisin，不默认切换既有 bootstrap/finalization。
5. 新 `/vh` launchd/SystemHook 注入留到 P6 的显式模式；迁入 CFW 系统修正时不得无条件替换本地 `/b` 和原有加载方案。
6. Mach-O/DSC 移植按相同 SHA-256 输入比较候选、payload、日志、幂等和失败行为，保留必需性和事务。内核改动遵守项目技能和 patch_bsd_init_auth 限定流程；本次 50 个上游内核文件内容未变不构成放弃本地验证的依据。
7. GPU 验证显式 driver bundle 与临时 PCC 恢复两条路径，记录固件 build、驱动及 compiler plugin 摘要；覆盖网络/TSS、空间、权限、取消、挂载卸载、工作目录残留。

验收：新建、恢复、系统 CFW、health、锁屏/显示、Metal、重启；随后逐变体扩展，保留 regular/dev/exp/less 的公开入口与现有后端。first_boot 的 API health 不能替代 jb_finalize、最终 verification 或应用验收。新补丁同步补丁比较文档。

完成条件：有一个可复现的配套 v2 测试镜像，阶段与产物证据完整；其余组合逐项标明旧后端、待迁移或未验收。

### P5：HTTP/WebSocket、本地合约及相机

依赖 P4 的配套镜像。旧 1337 客户机保留独立路径，新 1339 客户机显式能力协商；记录协议、daemon 摘要和会话代际。不能只靠 `api_version=1` 推断全部扩展 API。

| 范围 | 实施要求 | 必须验证 |
| --- | --- | --- |
| 宿主合约 | 逐命令映射参数、结果、错误与 capabilities；保留 Unix socket 同用户检查和 headless | 现有脚本/客户端回归、GUI/headless、重连及不支持能力的明确错误 |
| 请求状态 | 保留 E1–E4 期限、取消、迟到响应和代际 | WS 乱序、并发、断线、旧响应；区分请求取消与客户机实际停止 |
| Shell | 独立 handler 与可执行文件来源；内部关机可评估专用 API | cwd、timeout、stdout/stderr、退出码、截断、超时；旧调用结果不改变 |
| 输入 | 保留整次手势固定路由和串行化，结合上游输入队列 | 多客户端并发、GUI/API、重连、方向/屏幕坐标转换 |
| 定位 | 保留 owner/generation/sequence 与持久化，适配 IcliKit | set/clear 乱序、取消、重连、来源切换和应用实际 CoreLocation 读数 |
| 相机 | 保留 v3 wire、256 字节 publish header、observe shm 和 presentation_id；统一 host/daemon/hook | 旧/新组合明确拒绝或协商、像素起始位置、源切换、迟到帧、重复 generation、停止和重启 |
| 传输 | 吸收 SIGPIPE 防护、超时、dup descriptor、上传背压和临时文件清理 | 中断上传、短写、超时、fd 生命周期、重连和内存占用 |
| 应用 | IcliKit 安装/前台查询，保留 vphone 签名回调 | IPA/TIPA、失败回滚、注册读回；PID 与 frontmost_verified 分别判定 |
| 隧道 | 可选 WS→客户机 loopback TCP | 分片、背压、5 秒排空、关闭、服务不存在；不宣称隧道自带 SSH/VNC |

相机路径迁移单独提交，但必须与 ABI 兼容设计一致。采用 mobile Media 路径前验证 cameracaptured 和应用读取权限。实际加载本地 hook，再验证测试图、视频、消费回执、应用识别、拍照和视频录制；“端口连接”和“共享内存已发布”不能充当后四项证据。

扩展 API 和静态库 `VPhoneExternalAccessKit` 可在本地合约旁增加，不替代原调用者。建立源码对应的方法/capability 清单，去掉已删除 OpenAPI 和旧 SwiftPM 产品的安装说明。TCP 访问控制与扩展写操作一起验收。

完成条件：旧自动化合约回归与新镜像业务验收通过，旧镜像仍可使用；相机身份与应用证据分开记录。

### P6：可选 Irisin 与新注入流程

依赖 P4、P5。仅在独立新建 JB 测试副本中启用；其他变体和已有 Procursus 环境不自动迁移。

1. 选择性移入最终版 launchd/SystemHook 与公共头、构建目标、签名及 CFW 安装逻辑。检查 `/vh` 占用、weak load、launchd 重签名、重复安装；不得覆盖现有 `/b`。
2. 明确新 bootstrap profile 与 checkpoint/finalization 的对应关系；已有 `jb_finalize` 成功条件不允许用 Irisin marker 替换。上游默认 RootHide 只作为显式选项，不变成本地默认。
3. 安装/查询/状态/firmware 修复/卸载能力成套实现。记录具体 Irisin release 与 SHA-256；验证 deb metadata、重复安装、下载失败、部分替换失败、回滚和 `service_start_warning`。
4. 保留完成标记的确切协议字段和路径，包括上游 `.vphoned-boostrap-completed` 的现有拼写；需要修正时制定兼容读取策略，不能单端改名。
5. 卸载只接受本工具确认的 root，验证 rootless symlink、RootHide 多候选、路径变化、子目录 symlink、部分失败重试、保留应用外部数据和重启结果；不接管未知既有 bootstrap。
6. 真实测试 rootless 与 RootHide：launchd 发现、xpcproxy→最终进程、直接 App、bootstrap 子进程、safe mode、无 ElleKit、安装 ElleKit 后 TweakLoader、真实 tweak 加载。首次 apt/bash 的 package 初始化单独记录。
7. 对 EXP 相机 hook 验证新旧加载路径，保持 EXP 作用域；上游没有相机 App 完整验收，不能复用传输记录作为通过证据。

完成条件：bootstrap 安装、服务运行、注入、tweak 行为和卸载重启分别有证据；不能仅以 marker 或 dlopen 日志标记整个环境完成。同步补丁比较文档和各变体支持矩阵。

### P7：检查面板、本地化与窗口行为

依赖 P5。按设备/控制、进程/服务、日志/崩溃、UI/OCR、剪贴板/偏好设置分批迁入；使用 capability 控制入口。错误与未验证状态必须可见，不能将空结果显示为通过。

保留本地研究工具的暗色、中性色、等宽字体和无阴影样式。移植多 VM 窗口持久化、菜单快捷键和 `isReleasedWhenClosed = false`；验证多个 VM 的窗口/状态不串用。截图入口明确客户机内容与宿主窗口内容的语义，兼容现有 API 尺寸与坐标。

完成条件：GUI 功能和 headless 合约分别通过，关闭窗口与重连没有引入生命周期回归。

### P8：完整 CI、分发与最终验收

保留本地 push/PR fast checks、自托管 firmware checks；上游 build/release 仅提供构建与 bundle 校验参考，不能代替测试套件。若 Swift 目标迁到 Xcode，测试 runner 必须显式选择全部相关 schemes，并继续隔离真实固件测试和环境变量。

1. 运行 `make test`、`make test_fixtures`；夹具完整后运行 `make test_firmware`。新增 Xcode 模块的 tests 必须接入 CI，记录实际执行范围。
2. 使用最终分发产物重跑 F1 支持矩阵、F2 双 VM、F3 性能/资源/磁盘；记录默认缓存改变对准备时间和空间的影响。
3. 验证完整 bundle 签名、daemon/VM 权限隔离、资源定位、更新后的 cdhash/AMFI 处理，以及无开发工具宿主上的实际运行。源代码构建与运行时依赖分别记录。
4. 最后删除已被验证替代且无调用者的旧入口；保留 Python 研究和验收工具。纯目录重命名通过中间路径处理大小写，并独立提交。
5. 文档、命令帮助、支持矩阵、方法清单和打包清单同步。未验证组合不能纳入已支持范围。

完成条件：每个实际交付组合有完整证据与回退路径，构建、固件比较、真实恢复、启动及应用验证的结果分别可查。

## 5. 提交、回退与证据

每个提交只承担一项可审查行为或一次纯目录调整。记录来源 SHA/路径、本地保留差异、测试命令和结果；新补丁同步 `research/0_binary_patch_comparison.md`。不因 Git 自动合并干净就跳过语义对照。

阶段失败时修复或回退对应代码提交；固件、CFW、bootstrap 安装及卸载的测试都使用副本或独立测试 bundle。保留原 VM 与旧后端，不能把代码回退等同于磁盘内容自动回退。

真实验收记录至少包括：宿主/工具链、代码 SHA、最终 bundle/daemon 摘要、iPhone/cloudOS build、manifest/schema、variant、GPU/compiler plugin、bootstrap profile/release、命令、退出状态和未验证范围。模拟输入、源码推断、上游记录、本次实测分别标注。

## 6. 当前状态与下一步

| 项目 | 状态 | 证据 / 下一步 |
| --- | --- | --- |
| 新上游取证与对比 | 已完成 | `4bab3b7 → 08db376`，57 个提交，固定源码与职责映射 |
| 合并模拟 | 已完成 | 同一本地分别对旧/新上游；318/277 个未合并路径 |
| 本地生产代码状态 | 未改动 | `2fd54ee → 9489ab2` 只有旧计划文档 |
| 上游 tag 基线 | 已核对 | `1.0.13` = 共同祖先，`1.0.14` = `9c23c8a`，`2.0.0` = `3aa5561`；P1a 改为 cherry-pick |
| 环境检查 | 部分完成 | Xcode 26.4、Swift 6.3；`make test_fixtures` 失败，缺 17 文件 |
| P0 测试基线 | 待执行 | 实施前运行 `make test`；补齐夹具后再执行固件比较 |
| P1–P8 | 待执行 | 先 P1a/P1b，再 P2 构建与资源适配；按依赖推进 |

本次没有运行上游构建、项目测试套件、固件补丁、恢复或 VM。下一步代码工作从 P0 测试基线与 P1 独立修正开始，不直接执行整体合并。

## 7. 修订记录

| 日期 | 修订 | 历史证据 |
| --- | --- | --- |
| 2026-09-24 | 建立 `4bab3b7` 目标的 P0–P6 计划及实施分支 | [历史计划全文][history-plan] |
| 2026-09-25 | 目标更新为 `08db376`，提前构建适配，重排为 P0–P8，单列相机与 bootstrap 验收 | 本文阶段对应表、实施决定和完成条件 |
| 2026-09-25 | 合并按日期维护的计划，改为固定文件名；后续直接更新本文 | 历史决策通过 Git 查询 |
| 2026-09-25 | 增加上游 tag 基线与锚点规则；P1a 改为 cherry-pick `9c23c8a` 并同步兼容性清单 | 第 1 节、P1a、[对比报告 1.1 节](upstream_comparison.md#11-上游-tag-与版本线) |

[history-plan]: https://github.com/zhaoawd/vphone-cli/blob/9489ab296e3c1d345f936135b370d51da7a3c65d/research/upstream_implementation_plan_2026-09-24.md
