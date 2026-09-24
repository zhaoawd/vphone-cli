# 上游整合实施计划（2026-09-24）

## 1. 范围与基线

目标：选择性迁移上游原生模块、进程布局和客户机协议，同时保留本地多变体、创建恢复能力、自动化合约和补丁约束。每阶段形成可独立验证的提交，目录改名独立处理。

| 对象 | 固定值 |
| --- | --- |
| 实施分支 | `codex/upstream-4bab3b7-integration` |
| 本地起点 | `2fd54ee88dea161753c9c53ce030873bb9a9b1da` |
| 上游目标 | `4bab3b76b3a2b6c5d68fecd292348176dbc18c4e` |
| 已有冲突模拟的本地版本 | `2c604ea51361c0328964c7edf8b4c634cc4d3c81` |

依据：[差异评估](upstream_comparison_2026-09-24.md)、[复核报告](upstream_review_2d76f81_2026-09-24.md)、[冲突清单](upstream_review_2d76f81_conflicts_2026-09-24.txt)。315 个未合并路径是旧模拟结果，不是当前分支重新模拟的结果，也不用于估计工时。

启动核对：工作区原先干净；当前目录仍缺两个固件条目；相机 DSC 仍逐站点检查并写入；当前仓库不含固定上游提交对象。正式移植前，在独立临时仓库取得该对象并核对完整 SHA，禁止改用浮动 main 作为输入。

## 2. 实施决定

- 保留 regular/dev/jb/exp/less 入口及默认 regular，保留各变体需要的 bootstrap、SSH、tweak 和 first-boot finalization。EXP 修改只进入 EXP 路径。
- 保留创建 runner、检查点、`--resume`、`--restart-from`、`create-status`；原生化替换阶段后端。
- 保留 VM/库锁、离线占用保护、PID 与启动时间身份校验；进程拆分后由实际 VM 进程持锁。
- 保留宿主 Unix socket 合约、同用户校验及 headless 支持；HTTP/WebSocket 在其下适配。任意 shell 需要独立 handler 和可执行文件来源，不能用 `icli.execute` 代替。
- 保留 `PatchOutcome`、必需步骤、事务、消融及实验记录；不替换已有 vm_map_protect 与 postValidation 实现。
- VM 格式采用“新建配套 v2 bundle”作为首条交付路径。开发阶段保留旧格式路径；新路径明确报告不兼容原因，库清单应显示原因。旧 bundle 不自动改写、不原地升级；缓存推送升级仍为待验证假设，less 不复用该假设。
- TCP 入口默认关闭；启用时默认 loopback。非 loopback 访问控制单独实现与验收。
- 保留 Python 研究、测试和 F1/F2/F3 工具；运行时原生化不构成删除这些工具的依据。

已完成、无需重做：导入 manifest 校验前移、APFS clone、postValidation 幂等处理、shell 覆盖结论修正。完整 IPSW clone 效果仍缺本地验收。

## 3. 阶段与完成条件

### P0：基线与迁移清单

1. 创建实施分支，归档本计划。取得固定上游源码，记录来源与 SHA。
2. 在临时仓库更新冲突模拟，按职责对应新旧路径；仅处理相关源文件，不接受整棵目录覆盖。禁止读取根目录 TODO.md。
3. 运行 `make test` 记录本地基线。已有失败与后续引入的失败分别记录；检查固件夹具和真实 VM 验收条件，不把缺失夹具记为通过。
4. 补充逐项迁移清单：本地入口、上游入口、保留合约、测试、实机证据和状态。迁移源码时核对依赖版本与许可证。

完成条件：输入版本可复现，基线结果及环境限制有记录。

### P1：固件目录和 EXP 相机 DSC

分为两个提交，均不依赖原生模块迁移。

**P1a 固件目录**：修改 `sources/VPhoneCore/VPhoneFirmwareCatalog.swift`，从固定上游核对完整下载 URL，增加 26.6.2/23G90 与 27.0/24A435（上游标 RC），配对 cloudOS 26.4/23E5207q。保留旧条目和默认选择语义。在 `tests/VPhoneCoreTests/FirmwareCatalogReportTests.swift` 及实际菜单测试中覆盖新条目的选择与 JSON 输出。运行 `make test_swift`。目录可选不标为本地全部变体已支持。

**P1b 相机 DSC**：修改 `scripts/patchers/cfw_patch_camera_dsc.py`，在全部六个目标解析、读取、分类成功后才写入。分类为原始、已补丁、不匹配；已补丁输入不重复写入，混合输入补齐剩余站点。保留独立 AVF 入口，明确 dry-run 与显式 force 的行为。替换指令继续使用 Keystone helper；日志记录站点、前后内容与状态。

测试至少覆盖：全部原始、全部已补丁、NU 已补丁而 AVF 原始、组内混合、最后目标不匹配、缺失符号、短读、dry-run、AVF-only、写入及哈希重算失败。默认模式任何目标不匹配时六个站点均零写入。成功后检查字节并验证修改页面哈希；内存模拟仅证明控制流，另用真实 DSC 副本验证哈希。预检查不承诺写入 I/O 失败回滚，失败必须报告为失败。

运行 `make test_python`；同步 `research/0_binary_patch_comparison.md`。EXP 安装遇错继续策略单独核对和记录，不能把继续执行当成补丁成功。真实 DSC 验证前不得标记真实签名通过。

完成条件：两个改动的相关回归通过；真实固件证据与模拟证据分别记录，未完成验收明确列出。

### P2：签名、归档和原生恢复

依赖 P0；按 Sign → Archive → Restore 分提交。

| 模块 | 实施范围 | 验收 |
| --- | --- | --- |
| VPhoneSign | 适配 Package.swift、资源和现有签名入口；固定 entitlements 来源 | CodeDirectory、entitlements、损坏输入、重复签名、签名产物实际执行 |
| VPhoneArchive | 引入原生归档后端；导入继续 staging 校验和持锁发布 | 权限、所有权策略、硬链接、符号链接、稀疏文件、路径穿越、无效 manifest、名称冲突和运行中拒绝 |
| VPhoneRestore | 引入 C 后端和 Swift 包装；替换恢复 bridge，保留阶段状态 | probe、ECID 选择、DFU owner、TSS、错误映射、超时、取消、子进程和资源清理 |

新增测试接入现有 firmware-free 入口，按模块运行后执行 `make test`。恢复的 probe/ticket 和错误路径通过后，在独立测试 bundle 执行真实恢复。依赖与资源未全部迁移前保留旧后端，切换点不得让一次创建混用不兼容的阶段产物。

完成条件：单元与集成测试通过，真实恢复单列证据；没有真实恢复证据时不得移除可用回退路径。

### P3：VM 进程拆分与权限

依赖 P2 恢复接口稳定。迁入 `vphone-vm` 与 VM library，配套调整 `VPhoneLaunchLayout`、`VPhoneVMStopper`、`VPhoneBundleGuard`、诊断、签名和资源定位。CLI 父进程与 VM 子进程有明确身份；锁由 VM 子进程持有，doctor 检查实际 VM 可执行文件。

验证：GUI/headless/DFU 启停、同 VM 重复启动拒绝、双 VM 隔离、父进程退出、子进程异常退出、PID 重用、启动失败、锁释放和离线操作拒绝。观察 VZ 辅助进程与磁盘占用，禁止仅凭 lsof PID 替代停止身份校验。运行 `make build` 获取实际签名产物；plain swift build 不用于 VM 验收。

完成条件：生命周期回归与真实双 VM 验收通过，权限诊断无旧布局误报。

### P4：HTTP/WebSocket 与客户机业务合约

依赖 P3；先在新建测试镜像中安装配套 daemon、icli、运行库和 launchd 配置。

1. 引入 APIKit、health 协商、HTTP 文件流与 WebSocket 请求关联；保留旧客户机的独立传输路径，显式记录所选协议与会话代际。
2. 逐项适配现有宿主命令的参数、结果与错误码。文件上传验证中断、大小限制和 rename 发布；事件验证乱序与断线。
3. 移植 shell handler，保留 cwd、timeout_ms、stdout/stderr、退出码、超时和截断状态；验证依赖 shell 的关机流程。
4. 迁移 E1–E4 期限、取消和迟到响应，区分请求取消与客户机操作实际停止。迁移定位 owner/generation/sequence 与持久化、相机 generation/presentation_id 与消费回执。
5. 保留整次手势固定路由及串行化，覆盖 GUI/API 和重连边界；验证 GUI/headless 的 Unix socket 同用户约束。

完成条件：旧自动化调用合约回归通过；新镜像实际完成文件、shell、定位读数、帧消费和应用识别。health 成功不等于业务验收通过。

### P5：v2 格式、原生固件与 GPU/CFW

依赖 P2–P4。先实现新建 v2 bundle 与显式版本诊断，再迁移固件准备和 CFW。

- 新旧 manifest 测试覆盖缺失字段、不支持版本、扫描、启动、克隆、导入导出；不通过添加版本字段把旧镜像标为兼容。
- 将原生准备接入现有 checkpoint runner：下载、暂存发布、占用保护、失败清理及续跑。迁入 fw inspect，明确它只读取 manifest。
- Mach-O/DSC 逐项移植，先用相同 SHA-256 输入比较候选、payload、结果、幂等和失败行为；保留必需性及事务。内核工作先读项目 kernel-analysis-vphone600 skill，其他目标使用各自证据。
- 保留五变体入口与安装资源；按变体记录新安装器等价范围，验证 JB finalization、iOS 27 注册与 EXP 相机 hook。
- GPU 分别验证显式 bundle 路径和临时 PCC 恢复路径，记录固件 build、驱动和 compiler plugin 哈希。验证空间、权限、TSS 失败、取消、挂载卸载和临时目录清理。
- 使用最终 GPU + compiler plugin + daemon + manifest 组合验证锁屏、持续显示、Metal、重启。上游早期运行记录不替代该组合的本地证据。

完成条件：新建、分阶段中断续跑、恢复、CFW、启动和应用验收形成同一组合的证据；缺失环境对应未验收状态。所有新补丁同步补丁比较文档。

### P6：目录、构建、CI 与分发

依赖 P1–P5。大小写目录重命名用中间路径并独立提交；更新脚本、资源与文档引用，不混入行为修改。保留 Makefile 兼容入口，直到替代命令及 CI 全部验证。

保留 push/PR checks、自托管 firmware checks，以及 FirmwareIntegrationTests 与快速测试的隔离。更新资源清单、离线诊断和打包签名。最终执行 `make test`、`make test_fixtures`；夹具完整时执行 `make test_firmware`，后者不等价于 VM 验收。重跑 F1 支持矩阵、F2 双 VM 和 F3 性能/资源/磁盘记录，并在无开发工具宿主验证实际分发流程。

完成条件：每个公开支持组合均有对应证据，失败及未验证组合明确列出；文档与命令入口一致。

## 4. 冲突处理与回退

| 冲突范围 | 处理原则 |
| --- | --- |
| Package.swift / resolved | 按模块引入目标和依赖，保留本地测试目标；每阶段独立解析和构建 |
| 修改/删除的 pipeline、CLI、脚本 | 先列职责对应，再迁移；删除状态不能作为丢弃本地行为的理由 |
| VM/UI/定位/相机 | 保留业务状态与宿主合约，修改接线后分别验收 |
| 内核匹配器 | 保留现有算法与结构化结果；有输入对照证据才增加分支 |
| Research/Kernel 迁移提示 | 按文档主题确定归属，不批量接受 Git 推断 |
| 测试改名与 CI | 保留快速测试和真实固件测试隔离，先更新发现路径再删除旧入口 |

每阶段代码、测试和研究记录成套提交。阶段失败时修复或回退该阶段提交；旧 VM 数据与已接受的基线保持可恢复。恢复、CFW 和固件实验使用副本或独立测试 bundle，不以运行中的研究 VM 作为试验目标。

## 5. 执行状态

| 项目 | 状态 | 证据 / 下一步 |
| --- | --- | --- |
| 阅读三份报告与当前源码核对 | 已完成 | 本地起点、目录条目与相机写入顺序已核对 |
| 创建实施分支 | 已完成 | `codex/upstream-4bab3b7-integration` |
| 实施计划 | 已完成 | 本文 |
| P0 上游对象与测试基线 | 待执行 | 当前仓库未包含目标上游对象；取得固定源码后记录 make test |
| P1–P6 代码实施及验收 | 待执行 | 从 P1a/P1b 开始，依上述依赖推进 |

本次启动交付为计划与新分支；没有迁入生产代码，没有执行固件修改、恢复或 VM 验收。后续每阶段记录提交、命令、退出状态、产物哈希和未验证范围，避免将计划状态写成验收结果。
