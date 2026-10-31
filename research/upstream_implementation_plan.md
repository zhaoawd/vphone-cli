# 上游融合实施计划

更新日期：2026-10-01。本文持续维护实施决策、阶段、验收条件和执行状态；历史全文保留在 Git 中。

本计划依据[2.2.3 差异分析与本地对账](upstream_diff_report_2026-10-01_a969cd5.md)，选择性吸收固定上游源码，保留本地五变体、检查点、控制合约与补丁约束。当前目标为 `2.2.3 / a969cd5d9206932dc1a2797348027fbc7d0ee347`。原 [2.0.8 对比报告](upstream_comparison.md)保留为历史依据。

本地 HEAD 为 `ef6f40842e1b53524cd038a84038c36d892f7031`；原生 classic prepare、创建检查点及相关测试尚未提交。P1a 已完成既定目录修正；P1b 真实 DSC、P1c 导入及导入后启动仍未验收。P2/P3 已提交原生库、API、独立 VM、原生 Restore、受控存储与 helper 候选；P4 两批 prepare 已有实现及历史验证。完整 v2/GPU、受控原生 CFW、运行时装载和 P5–P8 仍有剩余工作。具体状态见[阶段进展](upstream_remaining_progress_2026-09-29.md)与本文第 6 节。

[执行清单](upstream_execution_tasks_2026-10-01.md)采用 M0–M7/T00–T31，明确前置依赖、产出、验收和回退。T00 Git 采集和 T02 计划对账本次完成；其余任务按已有实现区分状态。9 月 30 日记录的 helper 注册/生产 Core Bundle 安装暂缓及 P1c 导入验收跳过继续有效。本次修订只更新文档和取证结果。

## 1. 固定输入

| 对象 | 固定值 |
| --- | --- |
| 实施分支 | `codex/upstream-4bab3b7-integration`，本次不改名 |
| 本次本地 HEAD | `ef6f40842e1b53524cd038a84038c36d892f7031`；工作区变动另见基线 JSON |
| 历史 2.0.8 整合起点 | `bc3bfa83ee8d3397e1caa08ce580e24407de17cd`，不作为当前 HEAD |
| 当前上游目标 | tag `2.2.3` → `a969cd5d9206932dc1a2797348027fbc7d0ee347` |
| 原上游目标 | `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3` |
| 上次对话目标 | `2.2.2 / d3403e510fd1126e9d99e7686f39465e5ab586e8` |
| 本次上游增量 | 2.0.8→2.2.3：124/122 提交；重命名口径 482 文件、+37,656/-11,915 行，排除根 TODO.md |
| 历史早期目标 | `08db376d9417a7ec0779967d6b2e748e3638d3c6`，新目标相对它增加 53 个提交，其中 47 个非合并提交 |
| 配套交付目标 | 来源为 Launchpad/Core Bundle 2.2.3；本地交付版本、最低兼容版本、guest/schema 与产物摘要独立验证 |
| 1.x 独立来源 | `1.0.14` → `9c23c8a`；继续用于 P1a catalog |
| 分析与路径映射 | [本次对账](upstream_diff_report_2026-10-01_a969cd5.md)及[历史 2.0.8 对比](upstream_comparison.md) |
| 历史 Git 证据 | [57 个提交及冲突清单](upstream_review_08db376_conflicts_2026-09-25.txt)，仅对应旧目标；2.2.3 本次已核实共同祖先与左右提交数，未做合并模拟 |

固定输入不能替换为浮动 `main`。继续使用现有实施分支，分阶段提交；不整批 merge/cherry-pick 上游增量。上游 hook 曾撤销再重做，选择性移植以固定最终源码及其依赖为依据。

历史版本锚点见[2.0.8 对比报告 1.1 节](upstream_comparison.md#11-上游-tag-与版本线)：1.x 版本线上的修复从 1.x tag 取提交并用 `git cherry-pick -x` 记录来源；2.x 后续迁移以本次固定 `2.2.3 / a969cd5` 为锚点，`main` 后续提交不自动纳入。2.0.6 曾同版本替换 Core Bundle，下载产物须记录 SHA-256，不能只记版本号。

## 2. 保留决定与新增决定

- 保留 regular/dev/jb/exp/less 入口、默认 regular 及各变体既有环境。上游当前以 patch set 和 preset 选择补丁，standard 排除部分原 EXP 项；先逐项映射 Kernel、DeviceTree、DSC 和 CFW 到本地变体，再建立显式 v2 测试组合；未经映射和验收不接入本地默认 JB，更不静默改默认变体。
- 保留 `VPhoneCreateRunner`、检查点、`--resume`、`--restart-from`、`create-status` 和产物保留规则。原生化替换阶段实现，不直接复制上游顺序 creator。
- 保留 VM/库锁、离线占用保护、PID+启动时间校验及 DFU owner。进程拆分后由实际 `vphone-vm` 持 VM 锁。
- 保留宿主 Unix socket、同用户检查、headless、shell、定位 owner/generation/sequence、相机 generation/presentation_id 与消费回执、期限/取消/迟到响应及整次手势路由。
- 保留 PatchOutcome、必需步骤、事务、消融与研究记录。“50 个内核文件内容未变”仅属于 `4bab3b7..08db376` 历史结论；2.2.3 的补丁声明、预设和版本条件需重新比较，不据旧结论跳过验证。
- 新 VM 格式先采用新建 v2 bundle。旧 bundle 不自动加版本字段，不原地升级；保留可用旧格式路径和显式不兼容诊断。less 单独取证。
- 构建、资源和依赖适配提前。Makefile 与现有测试 runner 保留到替代入口完成验收；目录改名独立提交，不把上游整个 Xcode 工程当作本地测试清单。
- 不吸收递归 `0777`。采用调用用户所有权恢复和明确的访问权限；提权由本地受控入口处理，不假设新 bundle 会弹密码框。
- daemon 直接链接 IcliKit/IcliSystem，不再要求安装上游已删除的 icli 可执行文件或 `icli.execute`。任意 shell 仍需本地实现和运行环境。
- 基础 SystemHook 的相机/MISFix 注入在 P4 的新建 v2 测试路径验证。2.2.3 已删除上游 libvlocation，定位在 P5 对照 IcliKit 路径；本地已有应用层覆盖单列兼容决策，不再要求从上游迁入该库。Irisin 在 P6 作为可选环境。首轮不接管已有 Procursus，不默认切换 RootHide，也不将 payload 安装完成记为服务/tweak 可用。
- TCP 默认关闭；启用时默认 loopback。保留已迁入的宿主代理 Token 与 guest Origin/Host 检查，并对照 2.2.3 差异，明确凭据、重连和日志脱敏；非 loopback 单独验收。`force` 字段不替代认证。
- 固定外部运行输入：Irisin 实际 tag、架构、URL、摘要进入记录；GitHub `releases/latest` 不能作为可复现实验的唯一标识。

已完成且无需重复移植：导入 staging 校验、APFS 复制机制、postValidation 幂等识别和 shell 覆盖结论修正。APFS 复制不等于完整启动状态保留：`bc3bfa8` 基线的 clone 清除身份、启动允许覆盖 NVRAM；本批 P1c 已修正代码并通过无固件测试，连续启动与 clone 启动已通过，导入后启动待验收。完整 IPSW clone 效果仍需实际准备验收。

### 2.1 2.2.3 新增实施决定

| 问题 | 决定 | 执行任务 |
| --- | --- | --- |
| 既有实现 | 先保存未提交 prepare/检查点与测试，再核对等价部分；阶段完成必须有对应证据 | T01/T02/T12 |
| 补丁与默认值 | 建立旧/新 ID、记录前缀、五变体及版本条件映射；保留默认 regular 和 EXP 作用域 | T09/T10 |
| 未声明记录 | resolver 与 Gate 写入路径共同检查声明完整性；未知记录不自动放行 | T11 |
| CFW 原盘保护 | clone 失败后采用校验完整副本或拒绝；不直接回退为原盘写入 | T03/T15 |
| 旧 VM 更新 | 区分完整迁移、停机替换、在线替换及不适用；缺库/加载路径不记为升级成功 | T16 |
| 进程激活 | 文件摘要、库重新加载及应用行为分别验收；SpringBoard 不由在线更新自动重启 | T17/T18 |
| 组件与身份 | 统一五项环境库中的 libmisfix；保留每机配置，configured UDID 与安装结果分开 | T18/T19 |
| 定位 | 取消 libvlocation 必须先迁入的要求；IcliKit 0.7.7、独立 Mac 定位 app 与本地所有权合约一起适配 | T08/T20 |
| 宿主/UI | 核对宿主策略、Launchpad CLI、sheet、翻译和 Inspector 删除范围 | T24–T27 |
| 发布 | 来源版本、实际实现、guest/schema、签名/收据及分发状态独立记录 | T28–T31 |

写盘准入依赖 T03 完整备份、T11 严格计划及 T15 事务保护。独立基础修复与 UI 可以按实际接口依赖推进。helper 注册和生产安装继续暂缓；任何原生 CFW 实现都不能通过任意命令执行扩大 helper 的受控接口。

## 3. 与 `4bab3b7` 基线阶段的对应关系

| 旧阶段 | 新安排 | 调整原因 |
| --- | --- | --- |
| P0 基线 | P0 | 固定 SHA、模拟与测试基线已完成；逐变体/ABI/备份等继续记录 |
| P1 catalog / EXP 相机 DSC | P1a/P1b，新增 P1c | 保留原修正；本地 NVRAM 与克隆状态优先修正 |
| P2 Sign/Archive/Restore | P2 原生库构建，P3 恢复执行 | 新资源布局、归档依赖和 root 边界需要配套适配 |
| P3 进程拆分 | P3 | 与恢复身份、权限和资源定位一起验收 |
| P4 HTTP/WS | P5 | P4 先产生可用于真实验收的配套新镜像，避免等待关系不明确 |
| P5 v2/固件/CFW | P4 最小新镜像及基础 Hook，P6 Irisin | P5 应用定位依赖 P4 Hook；可选用户环境单独验证 |
| P6 目录/构建/CI | P2 构建基础，P7 UI，P8 最终分发 | 构建不再全部放在最后；测试入口从首阶段持续保留 |

依赖顺序：P0 → P1c（优先）及独立 P1a/P1b；P0 → P2 → P3 → P4 → P5 → P6。P7 的核心包/日志管理依赖 P3，检查面板依赖 P5，Bootstrap UI 回归依赖 P6；P8 汇总实际交付范围。P1 可在现有后端完成，最终 EXP 验收需包含 P1b；P5 定位不等待可选 Irisin 安装，也不再依赖从上游迁入已删除的 libvlocation。

## 4. 阶段与完成条件

### P0：基线、测试清单与环境

历史已完成：2.0.8 tag/完整 SHA、53/47 增量计数、关键源码核对及本地状态问题定位。本批重新模拟 `bc3bfa8 × 9d218de`，得到 243 个未合并路径；共同祖先不变。Python 基线 352 项通过，Swift Testing 基线 474 项通过，另有 XCTest 145 项、3 项跳过、0 失败。默认夹具最初缺 17 文件；9 月 29 日已从原有固定固件缓存恢复并通过 13 项固件测试，来源和范围见 [剩余阶段进展](upstream_remaining_progress_2026-09-29.md)。

2026-10-01 已采集 2.2.3 与实时工作区，124/122 提交及两个重命名口径均已复核。旧合并模拟不外推到新目标。T01 未提交文件完整保存、T03 完整 VM 备份及 T09–T11 映射/严格计划仍待完成。

P0 历史检查项及剩余工作：

1. 本批沙箱内 `make test` 受进程/socket 限制失败；在正常宿主权限下分别重跑 `make test_python` 与 `make test_swift` 均通过。后续阶段继续区分环境问题、原有失败与变更回归。
2. 将旧计划涉及的测试目标与当前 Xcode schemes 对应，保留 `FirmwareIntegrationTests` 和快速测试隔离、Python suite、F1/F2/F3 工具。
3. 为每个迁移模块记录上游 SHA/路径、本地入口、保留合约、依赖版本/许可证、测试和真实验收状态。
4. 准备独立 VM 测试 bundle 和固定固件组合。9 月 29 日 `ipsws/patch_refactor_input` 的 17 个夹具文件已恢复；13 项固件对比测试及 PCC 23B85 的 regular/dev/jb/exp 流水线已通过。less、其他固件组合及真实恢复/启动尚未验收，不能由当前夹具结果推导通过。
5. 固定版本共同祖先及合并模拟已在临时裸仓库完成；完整目录职责映射、上游 patch set/preset 到本地五变体的清单、最终相机 ABI 和 DSC 差异核对仍待补齐。
6. 建立版本台账：Launchpad/Core Bundle/guest 版本、源码 SHA、产物 URL 与 SHA-256、签名及收据、VM schema、固件 build、已有 bootstrap。停机保存完整 VM 状态与匹配宿主程序，覆盖 Disk.img、NVRAM、machine identifier、SEPStorage、SHSH 等实际存在的状态。

完成条件：源码输入和测试结果可重现；缺失环境明确记录。基线通过不等于逐变体/ABI 对照和完整 VM 备份完成，P0 保持部分完成。

### P1：独立修正

执行优先级为 P1c，其次独立推进 P1a/P1b。P1c 使用现有后端验证，不依赖 2.x 进程与协议迁移。

**P1a 当前状态**：已从固定提交应用目录/README/测试差异，兼容性清单同步为 25 条，新条目仅为 `code_selectable`。因工作区已有未提交修改，采用 `git apply --check` 后应用固定差异，未执行 cherry-pick。完整 `make test`、CLI JSON 与菜单选择通过，P1a 本轮完成。以下保留实施来源与完成条件。

**P1a 固件目录**：cherry-pick 上游 `1.0.14` 的 `9c23c8a`，增加 26.6.2/23G90、27.0 RC/24A435，配对 cloudOS 26.4/23E5207q。该提交使用本地目录布局，已含 `FirmwarePickerTests` 计数 23→25；merge-tree 显示可干净应用到 `71bbf60`。不从 2.x 路径手工抄写 URL；两条 URL 与 `08db376` 中 2.x catalog 的对应条目一致。

1. 执行 `git cherry-pick --no-commit 9c23c8a`（`--no-commit` 时 `-x` 不写入来源，提交信息需手工加入 `(cherry picked from commit 9c23c8adcd4b362120988ab9d228b959bcc23ae3)`）。保留 catalog 与测试改动；README 及 ja/ko/zh 译文的 Tested Environments 两行一并保留（2026-09-25 决定）。这两行是上游在 Mac16,6 26.6.1 上的测试记录，不是本地实测；提交信息注明来源，本地支持矩阵中这两项仍只记为 code_selectable。
2. 同一提交内同步本地兼容性清单：`research/firmware_compatibility.json` 的 `firmware.ios` 增加两条 `source: catalog` 记录，`combinations` 增加两条 `stage: code_selectable`、五个变体的组合（参照现有 `cs-23G83` 格式，cloudOS 构建号为 null）；`research/firmware_compatibility.md` 及 README 与 ja/ko/zh 译文支持矩阵段落中的 catalog 配对计数（当前为 23，每段出现两处）同步为 25，范围描述“18.6.2 至 27.0 beta”同步包含 27.0 RC。按测试源码，只合入 catalog 会使 `FirmwareCompatibilityManifestTests.catalogPairingsMatchManifest` 失败（catalog 与清单不一致），该结论尚未运行验证。
3. 保留现有条目和默认选择。执行 `make test`（覆盖 Swift catalog/清单一致性与 Python `test_firmware_compatibility.py`），并检查 `fw catalog --json` 输出与交互选择。新条目只记为 code_selectable，不表示任何变体已支持。

**P1b 当前状态**：六站点预检查、混合输入补齐、页哈希检查已实现，17 项合成 DSC 回归通过；真实 DSC 验收未完成。EXP 安装失败后继续的策略保持不变。

**P1b EXP 相机 DSC**：改造 `scripts/patchers/cfw_patch_camera_dsc.py`，六个目标全部解析、读取、分类后才写入；区分原始、已补丁、不匹配，补齐混合输入。保留 AVF-only、dry-run 和显式 force 行为；指令继续使用 Keystone helper，记录 offset、前后字节和状态。

测试覆盖全部原始、全部已补丁、NU 已补丁/AVF 原始、组内混合、最后目标不匹配、缺符号、短读、dry-run、AVF-only、写入和页面哈希失败。默认不匹配输入要求六站点零写入；成功后检查字节和修改页哈希。预检查不承诺 I/O 失败回滚。运行 `make test_python`，再用真实 DSC 副本验证哈希；EXP 安装捕获错误后继续的策略单列。

**P1c 当前状态**：候选代码已应用，新增 21 项测试通过；Swift Testing 合计 495 项、67 个 suite 通过，XCTest 145 项、3 项跳过、0 失败。`make build` 与 bundle 校验通过，真实 clonefile 检查通过。CLI/README 及译文已更新，未创建提交。签名 app 原先被 AMFI 拒绝；临时按当前 cdhash 放行后，独立副本连续启动与 clone 启动通过，持久标记及 249 项应用标识/版本一致。导入后的启动仍待验收，详情见整合记录。

**P1c NVRAM 与完整状态克隆**：参考上游 `6e9732de680e9333d5e66bbb0d4df8c8193c416d` 及 2.0.8 最终实现，分启动与克隆两个提交，不整文件替换本地保护逻辑。

1. 修改 `sources/vphone-cli/VPhoneVirtualMachine.swift`：已有 NVRAM 校验后打开；不存在时无覆盖创建。对符号链接、非普通文件和失败输入明确拒绝，不以重新创建掩盖损坏；保留实际需要的 boot-args。
2. 修改 `sources/VPhoneCore/VPhoneBundleOps.swift`：clone 保留 NVRAM、machine identifier、SEPStorage、SHSH 及关联启动状态，继续 APFS 优先、普通复制回退。保留源 VM 锁、运行中拒绝、同名与 EEXIST 竞争保护；单独清理副本宿主 PID/socket/运行状态，不删除持久身份，不复用旧停止身份。
3. 更新 `tests/VPhoneCoreTests/BundleOpsTests.swift` 中现有“重置身份”断言，验证副本完整状态、源目录不变、非 APFS 回退、同名冲突不误删、运行中拒绝。同步 clone 帮助与用户可见说明：副本保留设备身份；独立身份采用新建/恢复，不保留未经验证的“清部分文件即可成为新设备”承诺。
4. 运行 `make test_swift` 和 `make build`。在停机备份及测试副本上验证原 VM 连续启动至少两次、clone 启动、导出/导入后启动，核对票据与应用数据。不能要求运行前后 NVRAM 全文件哈希不变，因为正常启动仍会写状态。

完成条件：P1a/P1b/P1c 分别有回归与所需真实证据；缺输入时标记未验证，不能以单元测试代替克隆可启动。新补丁同步 `research/0_binary_patch_comparison.md`。

### P2：构建基础、资源及原生库

**历史状态（2026-09-28，适用于原 2.0.8 批次）**：VPhoneSign 和 VPhoneArchiveKit、SwiftPM 目标与显式 CLI 已接入。归档库采用固定 ArchiveKit 依赖，覆盖权限、链接、路径检查、排他输出和稀疏文件往返；具体验证见 [P2 第一批签名记录](p2_sign_integration_2026-09-28.md)及 [P2 第二批归档记录](p2_archive_integration_2026-09-28.md)。原有 build/CFW 签名路径保留。VM 传输已通过可选 native 后端接线，默认仍为 system-tar；IPSW 缓存和本地检查接口已接入，固件准备脚本尚未切换。详见 [P2 第三批记录](p2_transfer_integration_2026-09-28.md)。Restore 三层库与固定依赖已迁入，新增 `restore-inspect` 离线检查，原生恢复尚未接入执行阶段；详见 [P2 第四批记录](p2_restore_integration_2026-09-28.md)。本地普通/less daemon 已统一预签名构建，安装及更新共用 `guest-resources`，详见 [P2 第五批记录](p2_guest_layout_integration_2026-09-28.md)。上游 API daemon/proxy 已接入独立候选构建和无固件测试，尚未接入宿主或默认安装，详见 [P2 第六批记录](p2_daemon_api_integration_2026-09-28.md)。第七批已新增独立 `VPhoneAPIKit` 库和回环传输测试，详见 [P2 第七批记录](p2_host_api_integration_2026-09-28.md)。第八批通过显式 `--api-listen` 接入回环 TCP→VSOCK 1339 代理，默认控制路径仍使用 1337，详见 [P2 第八批记录](p2_api_proxy_integration_2026-09-28.md)。第九批已新增绑定 VM runtime 的 API 会话，通过 HTTP/WS 实例、摘要和能力比较控制 ready 状态，并在断线后重新协商；详见 [P2 第九批记录](p2_api_session_integration_2026-09-28.md)。第十批已接入显式 `transport:"api"` 的 `app_list/app_foreground` 映射及 API 命令能力查询，详见 [P2 第十批记录](p2_api_commands_integration_2026-09-29.md)。第十一批增加有界流式文件下载、响应身份检查及排他宿主文件发布，详见 [P2 第十一批记录](p2_api_files_integration_2026-09-29.md)。其他 guest components、其余宿主业务命令适配和完整 bundle 布局仍待完成；P2 保持部分完成。

2026-10-01 对账：后续 API、Restore 执行、候选组件和进程接线已提交，见阶段进展；T04–T08 仍需核对 2.2.3 的签名、线程局部 UTF-8 locale、通信/worker 和 IcliKit 0.7.7。历史段落中的“尚未接入”不作为当前判断。

依赖 P0。先保持本地现有路径可构建，再引入对应模块；不得先删除 Package.swift、Makefile 或现有测试。

1. 建立本地目标到 Xcode/bundle 的清单：CLI、VM 子进程、Core、Sign、Archive、Restore、daemon 代理/I/O worker、guest dylibs、Launchpad/helper、字符串及 entitlements。Sign/Archive/Restore 的源码迁移与目标接线分为可审查提交。
2. 引入 `VPhoneSign`、`VPhoneArchiveKit`、`VPhoneRestore`/MobileRestoreCore；适配现有接口与测试。归档依赖核对 ArchiveKit 1.0.0，恢复依赖核对固定 AppleMobileDeviceLibrary。保留本地归档 staging、manifest 校验、排他发布和权限策略。
3. 历史迁入固定 IcliKit 0.6.9（`74843a56df54936c3949239a4ffb3ddcbe37dee4`）；当前 T08 对照并固定目标 0.7.7（`9e9a6ca940ac4142771eb34cf7e052e35a7b7987`），逐项验证 API 变化。其余依赖需重新核对当前 lockfile。原 2.0.8 依赖证据：SwiftNIO 2.83.0；Swift Collections 在 workspace 与 daemon 为 1.6.0，在 `VPhoneVirtualization.xcodeproj` 为 1.7.0。逐个核对 7 个 lockfile（含新增 Launchpad 工程）与实际构建入口（workspace scheme、`StageBundle.sh` 的 `-project` 构建）的对应关系，见对比报告 4.1 节。宿主与 iOS 的依赖图分别验证，不盲目统一子工程版本。
4. 构建 daemon 和 guest components；校验 `_swift_initBorrow`、iOS deployment target、架构和 entitlements。保留所有本地 capability 对应的资源，不按上游 bundle 缺少某项就删除本地资源。
5. 确立 `Contents/MacOS`/`Contents/Resources` 及开发树路径解析；支持 PATH、符号链接和任意 cwd 启动。所有 iOS 载荷从 `Contents/Resources/guest-resources` 定位，GPU compiler plugin 从其中 dylib 定位；vphoned 使用包内预签名载荷，安装与更新源一致，不要求上游已删除的未签名副本或签名脚本。既有本地暂存名不得混作上游分发路径。
6. 将 bundle 校验接入本地构建包装：二进制清单、签名权限隔离、资源、动态依赖、归档往返。继续由 `make build` 生成可执行 VM 的实际签名产物；若实现切换到 xcodebuild，由 Makefile 包装并更新项目说明。

验证：Sign 的损坏输入、entitlements、重复签名、实际执行；Archive 的权限、硬/符号链接、稀疏文件、路径越界、无效 manifest、名称冲突、运行中拒绝；原生 Restore 先测解析/probe/ticket/错误映射。每个新增模块接入无固件套件，完成后运行 `make test`。

资源清单采用 `vphone-escalator`，不回退旧 `VPhoneEscalator` 文件名；后者仍可能是 Xcode 工程/scheme 名，不能机械重命名标识符。daemon 代理与 I/O worker 的 launchd、监控、退出联动成套接入，不以拆分等同于解除所有 Jetsam 限制。

完成条件：旧入口和新模块都可构建、相关测试通过，实际 bundle 通过校验。Xcode 编译通过不等于真实恢复或 VM 通过。

### P3：VM 进程、提权、生命周期与恢复

2026-09-29：独立 VM executable 和本地生命周期适配见 [P3 实施记录](p3_vm_process_integration_2026-09-29.md)；显式原生 Restore 后端已接入检查点，见 [原生恢复记录](p3_native_restore_integration_2026-09-29.md)。Core Bundle 受控安装、收据与签名复核已接入显式 CLI，见 [存储记录](p3_core_bundle_store_2026-09-29.md)；同团队 XPC 与管理员授权代码、独立签名 helper 候选已接入，见 [helper 记录](p3_helper_xpc_2026-09-29.md)。9 月 30 日按用户要求暂缓真实注册与生产 Core Bundle 安装；CFW 受控入口与真实恢复/启动验收仍待完成。

依赖 P2。迁入 `vphone-vm` 进程，配套修改 `VPhoneLaunchLayout`、`VPhoneVMStopper`、`VPhoneBundleGuard`、DFU owner、资源定位和 doctor。CLI 父进程不冒充 VM 身份；实际 VM 子进程持锁并在退出后释放。

保留本地受控 sudo 重执行：只传递所需环境和 bundle 路径，明确 `SUDO_UID/GID` 对库根目录和产物所有权的影响。CFW 和 deviceinterfaced 操作的非 root 错误、无 TTY、取消与失败清理都需测试。迁入所有权恢复时不引入 `VPhoneHostFilePermissions` 的递归 `0777`，也不在“目标已存在”等拒绝路径修改现有数据权限。2.0.8 已修正已有 bundle 的拒绝路径，并增加描述符遍历、硬链接与所有者检查，但仍执行 `0777`（对比报告 4.2 节）。吸收防护，不吸收权限放宽；断言拒绝后 mode/owner 不变，非 sudo 也不扩大访问权限。

接入 Launchpad helper 时保留调用者授权、root 管理的 Core Bundle 存储、安装收据和二进制 cdhash 复核。CLI sudo 与 Launchpad helper 两种入口共享受控操作边界；不能允许 UI 传入任意可执行文件，也不能以手工替换已安装二进制绕过校验。CFW 排除自身验证磁盘描述符造成的占用误报，同时保持本地锁与外部持有者拒绝；覆盖停机成功、运行中拒绝、路径/链接负向样本。

原生 Restore 接入现有阶段 runner，保持 ECID/UDID 选择、DFU owner、超时、取消、错误状态和资源清理。真实恢复前完成 probe/ticket 与故障路径验证；真实恢复使用独立 bundle，不替换可用旧后端直至验收完成。

验证：GUI/headless/DFU 启停、重复启动拒绝、双 VM、父进程退出、子进程异常退出、PID 重用、启动失败、锁释放、离线操作拒绝、不同 sudo 环境的产物所有权。不能以 lsof PID 替代停止身份校验。使用 `make build` 产物，不用 plain `swift build` 作为 VM 运行验收。

完成条件：生命周期回归、签名诊断与真实恢复/双 VM 证据齐备；未验收的恢复路径保留旧后端。

### P4：新建 v2 镜像、原生固件与最小客户机

2026-09-30：显式本地 IPSW 原生 classic prepare 已实现并通过 26.1 实际组件/清单对照；第二批已接入 `vm create` 检查点、后端选项续跑与旧 Restore 树保留，见 [P4 实施记录](p4_native_prepare_2026-09-30.md)。下载、less、GPU/v2 与原生 CFW 尚未接入，默认后端不变。第二批没有执行真实恢复或启动；本次 Git 核对确认两批 prepare 实现及测试仍未提交。

依赖 P2、P3。先完成上游 patch set/preset 到本地变体的映射，再通过显式验证入口构建新的 v2 测试组合，不将上游 standard/experimental 直接等同本地 JB/EXP，不替代默认 create 和既有 VM。该阶段提供 P5 的真实客户机输入，P5 再补齐完整本地控制合约。

1. manifest 版本诊断覆盖扫描、启动、创建、克隆、导入导出；显示不兼容原因，不静默漏掉旧 bundle。旧格式路径继续存在。
2. 原生 prepare/CFW 接入 checkpoint runner，维护七阶段记录及 variant 规则。引入每 VM staging、下载 `.partial`、失败清理和挂载残留报告。共享缓存和 restore 符号链接的旧输入需明确支持、物化或拒绝，不隐式改路径。
3. 保留 `retain_until`：CFW 后不能直接删掉 first_boot/verification 失败时仍需的 restore tree。测试中断、续跑、`--restart-from`、`--keep-artifacts`、旧产物与工具版本变化。
4. 安装配套 HTTP daemon、所需运行库、launchd plist 和已签名二进制。先验证 health、签名摘要与启动；同字节输入不触发首次启动重复自更新。此验证不要求 Irisin，不默认切换既有 bootstrap/finalization。
5. 在该显式测试路径安装基础 launchd/SystemHook 与计划要求的相机/MISFix 组件，完成构建、签名、guest 同步和进程激活；不依赖安装 Irisin。目标已删除 libvlocation，现有本地覆盖按 T20 单独决策。检查 `/vh` 与既有加载路径冲突，不无条件替换本地 `/b`。相机基础 Hook 同样记录安装/加载状态；tweak 与 bootstrap 兼容留到 P6。
6. Mach-O/DSC 移植按相同 SHA-256 输入比较候选、payload、日志、幂等和失败行为，保留必需性和事务。内核改动遵守项目技能和 patch_bsd_init_auth 限定流程；旧范围内 50 文件未变的结果不能用于新目标；原 EXP 合并及各变体补丁效果逐项验证。
7. GPU 验证显式 driver bundle 与临时 PCC 恢复两条路径，记录固件 build、驱动及 compiler plugin 摘要；覆盖网络/TSS、空间、权限、取消、挂载卸载、工作目录残留。

8. 接入 T09–T11 的声明、预设、版本条件和严格写入检查；新增补丁先完成 reveal/验证记录并同步补丁比较文档。
9. 接入 T15 的 clone/完整复制保护与排他发布，注入复制/挂载/补丁失败验证原盘完整性。
10. 接入 T16 的停机更新资格；新库或加载路径缺失时给出完整迁移要求，不用 update-environment 的跳过行为作为成功。

验收：新建、恢复、系统 CFW、health、锁屏/显示、Metal、重启；随后逐变体扩展，保留 regular/dev/jb/exp/less 的公开入口与现有后端。first_boot 的 API health 不能替代 jb_finalize、最终 verification 或应用验收。新补丁同步补丁比较文档。

完成条件：有一个可复现的配套 v2 测试镜像，阶段与产物证据完整；其余组合逐项标明旧后端、待迁移或未验收。

### P5：HTTP/WebSocket、本地合约及相机

依赖 P4 的配套镜像。旧 1337 客户机保留独立路径，新 1339 客户机显式能力协商；记录协议、daemon 摘要和会话代际。不能只靠 `api_version=1` 推断全部扩展 API。

| 范围 | 实施要求 | 必须验证 |
| --- | --- | --- |
| 宿主合约 | 逐命令映射参数、结果、错误与 capabilities；保留 Unix socket 同用户检查和 headless | 现有脚本/客户端回归、GUI/headless、重连及不支持能力的明确错误 |
| 外部认证 | 宿主 TCP 代理 Token、guest Origin/Host 检查、凭据传递与脱敏；直接 VSOCK 不误套 TCP Token 协议 | HTTP/WS 无/错/有效 Token，非法 Origin/Host，请求边界，代理重启换 Token、固定 Token、guest 重启重连 |
| 请求状态 | 保留 E1–E4 期限、取消、迟到响应和代际 | WS 乱序、并发、断线、旧响应；区分请求取消与客户机实际停止 |
| Shell | 独立 handler 与可执行文件来源；内部关机可评估专用 API | cwd、timeout、stdout/stderr、退出码、截断、超时；旧调用结果不改变 |
| 输入 | 保留整次手势固定路由和串行化，结合上游输入队列 | 多客户端并发、GUI/API、重连、方向/屏幕坐标转换 |
| 定位 | 保留 owner/generation/sequence 与持久化，对照 IcliKit 和独立 Mac 定位 app；已有本地应用层覆盖单列兼容决策 | set/clear 乱序、取消、重连、来源切换、授权拒绝、App 重启、清除覆盖与实际 CoreLocation/门店结果 |
| 相机 | 保留 v3 wire、256 字节 publish header、observe shm 和 presentation_id；统一 host/daemon/hook | 旧/新组合明确拒绝或协商、像素起始位置、源切换、迟到帧、重复 generation、停止和重启 |
| 传输 | 吸收 SIGPIPE 防护、超时、dup descriptor、上传背压和临时文件清理 | 中断上传、短写、超时、fd 生命周期、重连和内存占用 |
| 应用 | IcliKit 安装/前台查询，保留 vphone 签名回调 | IPA/TIPA、失败回滚、注册读回；PID 与 frontmost_verified 分别判定 |
| 隧道 | 可选 WS→客户机 loopback TCP | 分片、背压、5 秒排空、关闭、服务不存在；不宣称隧道自带 SSH/VNC |

相机路径迁移单独提交，但必须与 ABI 兼容设计一致。采用 mobile Media 路径前验证 cameracaptured 和应用读取权限。实际加载本地 hook，再验证测试图、视频、消费回执、应用识别、拍照和视频录制；“端口连接”和“共享内存已发布”不能充当后四项证据。

扩展 API 和静态库 `VPhoneExternalAccessKit` 可在本地合约旁增加，不替代原调用者。建立源码对应的方法/capability 清单，去掉已删除 OpenAPI 和旧 SwiftPM 产品的安装说明。TCP 访问控制与扩展写操作一起验收。认证已有上游实现，任务是迁入并保留本地边界，不再按“上游无认证”从零设计。

定位验收区分系统模拟读回、本地覆盖加载和目标 App 接收：`delivery: application_override` 不作为 App 回执；上游 iOS 26.4 Maps 蓝点记录不替代点餐 App 门店/距离场景。本地覆盖如继续使用，更新后重启目标 App 并记录 guest/库摘要与授权；采用 IcliKit 路径时记录新鲜模拟读回与目标 App 业务结果。Restart Guest 按断线、重连、health、应用操作恢复判定；代理未重启时不假定 Token 一定变化。

在线更新先完成 T17 文件与激活状态；T18/T19 核对 MISFix 注入和 UDID。SpringBoard 需要的 respring 或 guest reboot 显式记录，不以文件替换结果推定生效。宿主/daemon/打包的环境库列表必须一致。

完成条件：旧自动化合约回归与新镜像业务验收通过，旧镜像仍可使用；相机身份与应用证据分开记录。

### P6：可选 Irisin 与注入兼容

依赖 P4、P5。仅在独立新建 JB 测试副本中启用；其他变体和已有 Procursus 环境不自动迁移。

1. 复用 P4 已验证的基础 launchd/SystemHook，增加 Irisin 的 bootstrap 发现和 TweakLoader 兼容测试。检查 `/vh` 占用、weak load、launchd 重签名、重复安装；不得覆盖现有 `/b`。
2. 明确新 bootstrap profile 与 checkpoint/finalization 的对应关系；已有 `jb_finalize` 成功条件不允许用 Irisin marker 替换。上游默认 RootHide 只作为显式选项，不变成本地默认。
3. 安装/查询/状态/firmware 修复/卸载能力成套实现。记录具体 Irisin release 与 SHA-256；验证 deb metadata、重复安装、下载失败、部分替换失败、回滚和 `service_start_warning`。
4. 使用 2.0.8 的完成标记 `/private/var/db/vphoned/bootstrap.json`，并保留旧 `.vphoned-boostrap-completed` 的兼容读取及原拼写；覆盖仅旧标记、仅新标记、两者共存、无效 root 和卸载后状态，不把旧路径继续作为唯一写入目标。
5. 卸载只接受本工具确认的 root，验证 rootless symlink、RootHide 多候选、路径变化、子目录 symlink、部分失败重试、保留应用外部数据和重启结果；不接管未知既有 bootstrap。
6. 真实测试 rootless 与 RootHide：launchd 发现、xpcproxy→最终进程、直接 App、bootstrap 子进程、safe mode、无 ElleKit、安装 ElleKit 后 TweakLoader、真实 tweak 加载。首次 apt/bash 的 package 初始化单独记录。
7. 对 EXP 相机 hook 验证新旧加载路径，保持 EXP 作用域；上游没有相机 App 完整验收，不能复用传输记录作为通过证据。
8. 接入 2.0.8 轮询收束逻辑：取消并等待 poller 后写最终状态，隔离重试代际；测试安装完成后迟到轮询、失败重试、取消及关闭窗口。安装完成显示不能替代服务、tweak 和重启验证。

完成条件：bootstrap 安装、服务运行、注入、tweak 行为和卸载重启分别有证据；不能仅以 marker 或 dlopen 日志标记整个环境完成。同步补丁比较文档和各变体支持矩阵。

### P7：检查面板、本地化与窗口行为

核心包管理与持久日志依赖 P3；检查面板依赖 P5；Bootstrap UI 回归依赖 P6。按设备/控制、进程/服务、日志/崩溃、剪贴板/偏好设置分批迁入；目标已删除 UI Inspector，UI/OCR 如本地仍有调用者则独立保留或提供替代；使用 capability 控制入口。错误与未验证状态必须可见，不能将空结果显示为通过。

保留本地研究工具的暗色、中性色、等宽字体和无阴影样式。移植多 VM 窗口持久化、菜单快捷键和 `isReleasedWhenClosed = false`；验证多个 VM 的窗口/状态不串用。截图入口明确客户机内容与宿主窗口内容的语义，兼容现有 API 尺寸与坐标。

Launchpad 配套检查分三类显示：宿主 Core Bundle 最低版本、VM schema、guest 协议/组件。旧核心包可移除但不可选用，无旧 helper 名回退；不得把核心包版本拒绝解释成全部 v2 VM 必须重建。测试本地包安装、无效收据、日志文件写入、关闭管理器后 VM 行为、重新打开与多 VM 日志隔离；创建 UI 阶段与本地 checkpoint 对应，不用显示进度代替 resume。

T24–T27 补充宿主多系统检查、独立 Launchpad CLI、并发/headless socket、多选/搜索/排序/日志及 2.2.3 sheet 时序/翻译/操作顺序；Inspector 按实际调用者整理。

完成条件：GUI 功能和 headless 合约分别通过，关闭窗口与重连没有引入生命周期回归。

### P8：完整 CI、分发与最终验收

保留本地 push/PR fast checks、自托管 firmware checks；上游 build/release/package 仅提供构建、bundle 校验与产物追溯参考，不能代替测试套件。若 Swift 目标迁到 Xcode，测试 runner 必须显式选择全部相关 schemes，并继续隔离真实固件测试和环境变量。

1. 运行 `make test`、`make test_fixtures`；夹具完整后运行 `make test_firmware`。新增 Xcode 模块的 tests 必须接入 CI，记录实际执行范围。
2. 使用最终分发产物重跑 F1 支持矩阵、F2 双 VM、F3 性能/资源/磁盘；记录默认缓存改变对准备时间和空间的影响。
3. 验证完整 bundle 签名、daemon/VM 权限隔离、资源定位、更新后的 cdhash/AMFI 处理，以及无开发工具宿主上的实际运行。源代码构建与运行时依赖分别记录。
4. 最后删除已被验证替代且无调用者的旧入口；保留 Python 研究和验收工具。纯目录重命名通过中间路径处理大小写，并独立提交。
5. 文档、命令帮助、支持矩阵、方法清单和打包清单同步。未验证组合不能纳入已支持范围。
6. 保存 Launchpad 与 Core Bundle 成套产物及 SHA-256、guest 摘要、收据/签名状态和源码 SHA；验证本地构建安装与分发包的完整安装流程。CI 未签名包、公证包、源码构建和 VM 实测分别标注。
7. 按第 6 节验收表执行最终验收，只有全部交付范围通过才切换工作基线。保留未交付组合的旧后端，不以 2.2.3 来源版本号标记本地全功能通过。

完成条件：每个实际交付组合有完整证据与回退路径，构建、固件比较、真实恢复、启动及应用验证的结果分别可查。

## 5. 提交、回退与证据

每个提交只承担一项可审查行为或一次纯目录调整。记录来源 SHA/路径、本地保留差异、测试命令和结果；新补丁同步 `research/0_binary_patch_comparison.md`。不因 Git 自动合并干净就跳过语义对照。

阶段失败时修复或回退对应代码提交；固件、CFW、bootstrap 安装及卸载的测试都使用副本或独立测试 bundle。保留原 VM 与旧后端，不能把代码回退等同于磁盘内容自动回退。回退恢复匹配的宿主程序、完整 VM 和 guest 状态；单独降级 Core Bundle 不会自动撤销已更新的 Hook 或 bootstrap。备份在停机后执行，不能把只复制 Disk.img 或运行中目录复制称为完整可恢复备份。

真实验收记录至少包括：宿主/工具链、代码 SHA、最终 bundle/daemon 摘要、iPhone/cloudOS build、manifest/schema、variant、GPU/compiler plugin、bootstrap profile/release、命令、退出状态和未验证范围。模拟输入、源码推断、上游记录、本次实测分别标注。

## 6. 当前状态与下一步

| 项目 | 状态 | 证据或下一步 |
| --- | --- | --- |
| 固定目标及 Git 基线 | 本次完成 | 2.2.3/a969cd5，124/122 提交及 482 文件；T00 |
| 本地实现保存 | 未完成 | 当前 HEAD ef6f408，prepare/检查点及相关测试未提交；先完成 T01 |
| P0 | 部分完成 | 固定输入和历史夹具证据已有；新目标逐变体/严格计划、ABI 及完整备份待完成 |
| P1a | 既定目录修正完成 | catalog 25 条；新组合仍只为 code_selectable |
| P1b/P1c | 部分完成 | DSC 合成回归、连续启动/clone、导出内容比较已有证据；真实 DSC、导入及导入后启动仍未验收 |
| P2 | 部分完成 | 原生库、API 和候选组件已提交；T04–T08 的新目标差异及完整装载未完成 |
| P3 | 部分完成 | 独立 VM、原生 Restore、存储和 helper 候选已提交；注册/生产安装暂缓，受控 CFW 与真实恢复未完成 |
| P4 | 两批 classic prepare 已实现，未提交；阶段未完成 | 9 月 30 日组件对照和 Swift 回归记录已有；T09–T16 与 v2/GPU/CFW 待完成 |
| P5/P6 | 部分合约和候选已有，阶段未完成 | 定位重新适配、MISFix/UDID、环境激活、相机业务及 Irisin 验收待完成 |
| P7/P8 | 未完成 | Launchpad/UI 与最终分发、F1/F2/F3、整组恢复待完成 |

下一项：保存未提交变动（T01），在 T02 对账结果上补齐容量/完整备份（T03），推进基础差异 T04–T08 与补丁映射/严格计划 T09–T11，再接 GPU/v2 与受控 CFW。写盘前落实 T15。原生 prepare 已有实现不重复迁入；独立 UI 可按任务依赖先推进。

本次未复跑工程测试。此前结果和失败范围见各日期记录；9 月 30 日 prepare 的 Swift 全量通过不提升为 2.2.3 完整集成验收。helper 注册、生产安装及 P1c 导入验收的既有暂缓范围不由本计划修订撤销。

### 最终验收对应表

本表 A01–A20 对应旧附件的 T01–T20 验收编号；当前执行任务采用 T00–T31，两套编号含义不同。以下为最终验收条件，已有证据按第 6 节保留，缺失项继续未验证。

| 场景 | 阶段 | 通过条件与证据 |
| --- | --- | --- |
| A01/A12 版本及受控安装 | P2/P3/P7 | 最低核心包版本、schema、guest 分别判定；不安全路径/包/收据拒绝且目标未受损 |
| A02/A03/A04/A05 启动、克隆、导入导出 | P1c/P4/P8 | 至少两次正常启动、停机副本与往返导入可启动；持久身份和应用数据符合预期 |
| A06 CFW 占用 | P3/P4 | 运行中或外部持有拒绝，停机安装不被自身 fd 误报 |
| A07/A09–A11 重启与认证 | P5 | 无/错 Token 拒绝，有效 Token 可用；HTTP/WS、代理重启和 guest 重启分别恢复；仅约定入口可达 |
| A08 管理器退出 | P7 | 输出日志持久化，VM 行为符合设置，重新打开后可管理，状态不串用 |
| A13–A16/A20 应用、输入、文件与诊断 | P5/P7 | 真实 App 状态、顺序、哈希、取消/超时和组件加载可验证；OCR/accessibility 分别记录 |
| A17 Irisin | P6 | 安装/服务/tweak/卸载/重启分项通过，迟到轮询不覆盖最终状态 |
| A18/A19 定位 | P4/P5 | 授权、系统模拟或保留覆盖、坐标切换、App 重启及清除后业务结果均有证据，不能只读 current |
| 相机 | P5/P6 | 传输、加载、消费、预览、照片内容、录像/音视频同步、前后台及目标 App 分项记录 |
| 并发与资源 | P8 | F1/F2/F3 使用最终产物；同身份 clone 与独立设备实例分开，不外推硬件或折叠屏能力 |

每条记录包含版本与 SHA-256、环境/固件/schema/变体、前置条件、命令/步骤、预期、实际、日志/截图位置、执行者和结论（通过、失败、未验证、不适用）。有运行需求的项目不能以源码核对代替。

## 7. 修订记录

| 日期 | 修订 | 历史证据 |
| --- | --- | --- |
| 2026-09-24 | 建立 `4bab3b7` 目标的 P0–P6 计划及实施分支 | [历史计划全文][history-plan] |
| 2026-09-25 | 目标更新为 `08db376`，提前构建适配，重排为 P0–P8，单列相机与 bootstrap 验收 | 本文阶段对应表、实施决定和完成条件 |
| 2026-09-25 | 合并按日期维护的计划，改为固定文件名；后续直接更新本文 | 历史决策通过 Git 查询 |
| 2026-09-25 | 增加上游 tag 基线与锚点规则；P1a 改为 cherry-pick `9c23c8a` 并同步兼容性清单 | 第 1 节、P1a、[对比报告 1.1 节](upstream_comparison.md#11-上游-tag-与版本线) |
| 2026-09-25 | P1a 决定保留 `9c23c8a` 带来的 README 及译文 Tested Environments 两行 | P1a 第 1 步 |
| 2026-09-25 | P2 第 3 步更正 lockfile 版本；P3 增加 `0777` 拒绝路径与非 sudo 回归要求 | P2、P3；对比报告 4.1、4.2 节 |
| 2026-09-26 | 目标更新至 2.0.8；新增并前移 P1c，接入认证和包验证，拆分基础 Hook 与可选 Irisin，增加配套回退和最终验收表 | 对比报告及本计划 P0–P8 |
| 2026-09-26 | 第一批 P0/P1c 应用与 Mac 验证；补充临时 cdhash 放行、连续启动、clone 启动、真实导出及导入空间限制 | [整合记录](p1c_batch1_2026-09-26.md) |
| 2026-09-28 | 按用户要求跳过 P1c 导入验收；P1a 完成，P1b 代码与合成回归通过，真实 DSC 未验收 | [P1a/P1b 记录](p1ab_integration_2026-09-28.md) |
| 2026-09-28 | P2 第一批接入 VPhoneSign 与 CLI，核对 7 份锁文件和构建映射；保留现有签名路径 | [P2 第一批记录](p2_sign_integration_2026-09-28.md) |

| 2026-09-28 | P2 第二批接入 VPhoneArchiveKit 和 CLI，固定 ArchiveKit 及许可证；VM 传输后端保留 | [P2 第二批记录](p2_archive_integration_2026-09-28.md) |

| 2026-09-28 | P2 第三批加入可选原生 VM 传输、导入发布检查和 IPSW 缓存/本地检查接口；保留默认系统后端 | [P2 第三批记录](p2_transfer_integration_2026-09-28.md) |

| 2026-09-28 | 按用户要求提交已完成的 P1/P2 整合代码、测试与研究记录；真实 VM 导入及导入后启动仍跳过 | 本次整合提交；验收范围不变 |

[history-plan]: https://github.com/zhaoawd/vphone-cli/blob/9489ab296e3c1d345f936135b370d51da7a3c65d/research/upstream_implementation_plan_2026-09-24.md

| 2026-09-28 | P2 第四批接入 Restore 库、固定依赖及离线检查；保留现有 Python 恢复执行和 DFU owner 检查 | [P2 第四批记录](p2_restore_integration_2026-09-28.md) |

| 2026-09-28 | Restore 提交为 `f546d2f`；继续统一预签名普通/less daemon 与 guest-resources，保留现有 daemon 协议 | [P2 第五批记录](p2_guest_layout_integration_2026-09-28.md) |

| 2026-09-28 | P2 第六批接入固定上游 API daemon 独立构建、请求解析和 proxy 生命周期测试；候选产物未安装或激活 | [P2 第六批记录](p2_daemon_api_integration_2026-09-28.md) |

| 2026-09-28 | 第五、六批提交为 `2efd925`；第七批新增独立宿主 API v1 HTTP/WebSocket 库，VM 接线与真实客户机验收待完成 | [P2 第七批记录](p2_host_api_integration_2026-09-28.md) |

| 2026-09-28 | 第七批提交为 `a0af165`；第八批新增显式回环代理及 VSOCK 1339 接线，真实 VM 未验收 | [P2 第八批记录](p2_api_proxy_integration_2026-09-28.md) |

| 2026-09-29 | 范围明确为全部 8 个剩余阶段；完成文件传输、候选组件构建，推进 VM 进程与应用映射；真实输入和执行准入存在阻塞 | [本轮进展](upstream_remaining_progress_2026-09-29.md) |

| 2026-10-01 | 固定目标更新为 2.2.3/a969cd5；核实实时工作区与 124/122 提交、482 文件；修订 patch set/preset、严格 Gate、写盘回退、MISFix/UDID 及定位路径；建立 32 项执行清单 | [本次报告](upstream_diff_report_2026-10-01_a969cd5.md)、[任务清单](upstream_execution_tasks_2026-10-01.md)及基线 JSON |
