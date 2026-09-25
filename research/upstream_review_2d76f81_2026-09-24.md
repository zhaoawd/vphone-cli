# 2d76f81 上游差异复核与合入建议

日期：2026-09-24。

结论：评估文档对进程拆分、原生恢复、JB 公开入口、HTTP 客户机协议和 v2 manifest 的主要判断有源码依据。应分模块迁移，保留本地的状态管理和补丁约束。文档中“icli.execute 能覆盖 shell”是已确认错误。当前分支已经完成导入校验前移和 APFS clone 两项修正。

## 1. 范围与方法

| 对象 | 固定版本 |
| --- | --- |
| 被 review 的提交 | 2d76f814490e23e599197c22929f4b50071a978a |
| 该提交的原始本地代码基线 | 6288a02ad295889d31b4bdd024fa85bcbd0f22f1 |
| 本次复核时的当前分支 | 2c604ea51361c0328964c7edf8b4c634cc4d3c81 |
| 上游 Lakr233/vphone-cli | 4bab3b76b3a2b6c5d68fecd292348176dbc18c4e |
| 共同祖先 | 87f796c62a7cb385cd37afce121f6e222d83e5b5 |
| 客户机固定依赖 icli 0.6.1 | c3407df5f160919b5eb7d2fefb5a5c21351314fb |

2d76f81 只修改 research/upstream_comparison_2026-09-24.md，没有引入上游生产代码。本次从 Git 获取固定上游版本，核对关键入口和实现，并用 Git 2.53.0 在临时裸仓库模拟三方合并。

按仓库规则，在共同祖先、本地、上游的顶层树中排除 TODO.md，再构造仅供模拟的提交。没有读取该文件内容。事后核对：这三个树及 2d76f81 中均未跟踪 TODO.md，排除步骤不改变模拟输入；直接对原提交执行 `git merge-tree --write-tree` 得到相同计数。模拟未修改原仓库的分支、remote、索引或工作区，也未解决或提交冲突。

重新计算得到原报告的 178 个本地独有提交、114 个上游独有提交，以及 649 文件/87,348 新增行/26,915 删除行的上游变化统计，均与原报告一致。大量变化来自文件拆分、目录改名、Swift 移植和内嵌 C 依赖，不能当作独立新增功能数量。

## 2. 文档 review 发现

### [P2] icli.execute 无法替代本地任意 shell 执行

位置：[2d76f81 中的原报告第 200 行](https://github.com/zhaoawd/vphone-cli/blob/2d76f814490e23e599197c22929f4b50071a978a/research/upstream_comparison_2026-09-24.md#L200)。

原文把文件、应用、shell 都列为新 API 可以覆盖的功能，并据此缩小了必须保留的本地功能范围。这会遗漏 shell 迁移工作：

- 上游 IcliCommand.execute 使用 posix_spawn，固定执行 /usr/bin/icli；argv 只作为 icli 的参数。
- 固定依赖 icli 0.6.1 的 README 明确说明 shell 在 0.3.0 被移除；该版本的命令树也没有 shell。
- 本地 VPhoneControl.runShell 接受任意命令、cwd、timeout_ms，交由客户机 shell 执行，并返回 stdout、stderr、退出码、超时和截断状态。

影响：现有 shell 自动化不能只改成 icli.execute。基于 runShell 的客户机关机流程也需要重新接线。保留能力时，应同时迁移客户机 handler、shell 可执行文件的安装来源和响应合约；若改写为专用 API，需逐一确认现有调用用途及返回值。

证据：[上游调用实现](https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Scripts/VPhoned/Daemon/IcliCommand.swift#L64)、[固定 icli README](https://github.com/owngoal-dev/icli/blob/c3407df5f160919b5eb7d2fefb5a5c21351314fb/README.md#L197)、[本地 runShell](../sources/vphone-cli/VPhoneControl.swift)。

修订状态：本次归档复核结果时，已修正原评估 §3.5 的 shell 覆盖结论及 §5 第三阶段的迁移范围。未修改生产代码。

### 当前状态补充

以下两项在 2d76f81 时确实未修复，后续 002ef63 已完成，不能再次列为当前待合入代码：

- 导入归档先在 staging 中加载 manifest，成功后才持库锁放入最终目录；已增加无效 manifest 回归测试。
- fw_prepare.sh 使用 cp -Rc。后续提交记录了 200 MB APFS 目录复制实验，未对完整 IPSW 执行 fw_prepare。

postValidation 的已补丁形态识别，本地在 2d76f81 时已经存在；本地还要求原始候选与已补丁候选总数为一，并返回结构化 .idempotent/.ambiguous。无需再移植上游的 Bool 返回版本。这是合入范围补充，不是原文关于上游提交内容的事实错误。

### 21a9ce2 后续复核：相机 DSC 的部分应用输入

`21a9ce2` 正确补充了 EXP 安装捕获相机补丁错误后继续的行为，但“影响是日志不能区分状态”需要限定为全部目标已完整补丁的输入。安装继续不证明剩余目标已补齐，也不证明失败前没有写入。

实验设置：使用本地 `.venv` 调用 `cfw_patch_camera_dsc.apply_all_camera_patches`，以该模块的五个 NeutrinoCore 符号和一个 AVFCapture 符号构造内存输入。指令由项目 `cfw_asm.asm` 生成：原始输入为 `pacibsp; nop` 的编码，已补丁输入分别为 `mov w0, #0; ret` 和 `mov w0, #3; ret`。符号解析、chunk 存储和 `reattest_modified_pages` 均替换为模拟实现；后者只记录调用，不重算真实页面哈希。实际补丁函数的检查、写入顺序和异常路径保持不变。

| 输入状态 | 内存写入次数 | 页面哈希重算函数调用次数 | 结果 |
| --- | ---: | ---: | --- |
| 六个站点均为原始输入 | 6 | 2 | 两组补丁完成 |
| 六个站点均已补丁 | 0 | 0 | 第一个 NeutrinoCore 站点报错；没有新增写入 |
| NeutrinoCore 全部已补丁，AVFCapture 未补丁 | 0 | 0 | NeutrinoCore 阶段报错；AVFCapture 保持未补丁 |
| 按符号排序，第一个 NeutrinoCore 站点为原始输入，第二个已补丁，其余为原始输入 | 1 | 0 | 第一个站点写入后，在第二个站点报错；未到组末的哈希重算 |

源码核对：本地在循环内逐站点检查和写入，整组完成后才调用 `reattest_modified_pages`；真实 `DSCChunks.write_at_vma` 直接写入文件。上游相机 DSC 实现先解析并检查全部目标，再进入写入阶段。这支持把“部分应用后的恢复”和“写入前完整校验”列入迁移范围。该预检查不等同于对写入阶段 I/O 失败提供回滚保证。

建议在 EXP 范围内识别原始、已补丁和不匹配三种状态；混合输入应能补齐剩余站点，不匹配输入应在写入前被拒绝，并验证成功写入后的页面哈希。EXP 安装遇错是否继续作为独立策略处理。以上实验没有读写真实 DSC，没有验证真实签名或 VM 行为。

证据：[本地相机补丁函数](../scripts/patchers/cfw_patch_camera_dsc.py)、[chunk 写入](../scripts/patchers/cfw_dsc_chunks.py)、[EXP 安装错误处理](../scripts/cfw_install_exp.sh)、[固定上游相机 DSC 实现](https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/FirmwarePatcher/DyldSharedCache/Patchers/DyldSharedCacheCameraPatcher.swift)。

## 3. 可以合入什么

“可以合入”表示值得选择性迁移，不表示整个上游提交已通过 cherry-pick、编译或 VM 验收。

| 内容 | 作用 | 本地状态与判断 | 验证范围 |
| --- | --- | --- | --- |
| b86dcaf 导入校验前移 | 防止无效归档占用最终 VM 名称 | 002ef63 已吸收；保留本地库锁 | 已有回归测试，本次未重跑 |
| 8c2cf10 的 APFS clone | 减少准备固件时的重复写入 | 002ef63 已吸收；不需重复合入 | 完整 IPSW 准备仍未验证 |
| 9c23c8a 两个固件目录条目 | 增加 26.6.2/23G90、27.0/24A435 与 cloudOS 26.4 的配对 | 可优先选择性移植条目及对应菜单测试 | 只增加选择项；上游运行记录不能写成本地全部变体支持 |
| 相机 DSC 状态识别与写入前校验 | 区分原始、已补丁和不匹配输入；检查全部目标后再写入 | 可在 EXP 范围内单独吸收；本地混合输入可能提前退出，或先写入后报错而未调用页面哈希重算。安装捕获错误后继续，不证明补丁完整；详见 §2 | 首次/重复/部分应用输入、剩余站点补齐、不匹配输入零写入、日志分类、页面哈希一致性；安装遇错继续策略单独验证 |
| VPhoneSign | 进程内完成原先由 ldid 承担的签名 | 适配后合入，边界相对独立 | entitlements、CodeDirectory、实际执行 |
| VPhoneArchive | 原生归档、解包及元数据处理 | 适配后合入；导入导出必须继续经过本地锁和占用保护 | 权限、硬链接、稀疏文件、路径与无效 manifest |
| VPhoneRestore 与 C 后端 | 用内嵌 libirecovery/idevicerestore 替换 Python 恢复桥接 | 值得迁移；替换本地创建阶段的后端 | ECID 选择、DFU owner、TSS、超时、取消、清理及真实恢复 |
| Swift 固件准备、Mach-O/DSC 移植 | 减少宿主外部依赖，集中在 Swift 实现 | 逐项迁移；保留多变体门控和事务语义 | 相同哈希输入的记录、payload、失败和重复应用结果 |
| HTTP/WebSocket、OpenAPI、VPhoneAPIKit | 提供标准化第三方接入、事件和二进制文件传输 | 可作为新传输层；不能替换本地业务状态协议 | 新旧客户机迁移、取消/迟到响应、headless、权限与应用行为 |
| vphone-vm 进程拆分 | 普通 CLI 与私有虚拟化权限分离 | 可合入，但必须同时迁移锁、进程身份、诊断和打包 | 启停、DFU、双 VM、父子进程退出与锁释放 |

VPhoneSign/VPhoneArchive/VPhoneRestore 均涉及 Package.swift 和资源结构适配，不能简单复制目录后视为完成。

## 4. 主要冲突及影响

| 变化 | 上游行为 | 与本地的冲突 | 影响与处理 |
| --- | --- | --- | --- |
| v2 manifest / 7155bbd | 只接受 schemaVersion=2，并校验应用主版本为 2 | 本地 manifest 没有该字段 | 直接合入后旧 VM 无法加载；库扫描可能跳过旧 bundle。应先确定重建或受验证的迁移方案，仅添加版本字段不能证明客户机兼容 |
| 进程拆分 / 8e4e75c 等 | vphone-cli 启动 vphone-vm | 本地只按 vphone-cli 识别 boot 进程，doctor 检查当前 CLI 的私有 entitlements | 停止目标和 DFU owner 判断需要更新；私有权限检查改为检查 vphone-vm；VM 锁必须由实际运行进程持有 |
| JB-only / b04425d、f88d667、f4a60c4 | 公开 create/patch/install 固定 JB，默认不安装 bootstrap、SSH/VNC、tweak 等环境 | 本地默认 regular，且支持 dev/jb/exp/less 和首次启动 finalization | 不应整体替换本地入口。会改变默认产物，影响 Sileo、SSH、tweak、相机 hook 等工作流 |
| HTTP 客户机 / 11f9dc4、c8d155e、8eecc0d | 1337 长度前缀 JSON 改为 1339 HTTP/WebSocket | 旧 daemon、新客户端不兼容；新客户端不回退到 1337 | 客户机升级与宿主升级必须配套；旧缓存推送方案仍是待验证假设，less 另行处理 |
| 宿主自动化 | 上游 Unix socket 仅有 ping/screenshot/tap/swipe/key/type，且仅 GUI 模式启动 | 本地 headless、能力发现、shell、定位所有权、相机回执、期限/迟到响应及同用户检查没有等价替代 | 保留本地对外合约并适配新传输；VPhoneAPIKit 可以与该方案同时使用 |
| shell | icli.execute 只执行 icli 命令树 | 不支持本地任意 shell 命令、cwd 和原有响应结构 | 单独迁移 handler 和客户机环境，或逐一改为专用 API |
| 生命周期 | 上游 stop 根据 lsof Disk.img 的 PID 发信号；clone/rename/delete 等没有本地排他保护 | 本地按 PID+启动时间验证并等待退出和锁释放 | 不接受以 lsof 替换现有停止实现。信号是否落到 VZ 辅助进程仍待运行验证；占用检查存在明确实现差异 |
| GPU 来源 / b06496e、f9e7abb | 默认恢复临时 PCC VM 提取 GPU，再合入自建 compiler plugin；可传 --gpu-driver-bundle | 本地准备流程和资源依赖不同 | 默认准备增加真实 VM 恢复、TSS 和磁盘挂载。临时配置为 8 CPU/8 GB/64 GB 稀疏磁盘；影响耗时、权限、网络和显示验证 |
| 创建状态 | 上游顺序创建，已有目标目录直接拒绝，无本地检查点续跑 | 本地 --resume、--restart-from、create-status | 保留 runner/checkpoint 外层，只替换阶段实现；否则失败后的自动恢复能力丢失 |
| 内核及 pipeline | 上游匹配器返回 Bool/PatchRecord，逐组件写回 | 本地 PatchOutcome、必需步骤、事务、消融和实验记录 | 保留本地约束。vm_map_protect 在本地已有实现和重复输入识别，不应直接替换成上游 Shape C 扫描器 |
| 构建及 CI | PascalCase 目录、Scripts/build.sh、URL 依赖；release CI 不执行 swift test | 本地 Makefile、路径、firmware-free/firmware 分离、Python 验收工具和 PR checks | 目录重命名与逻辑迁移分开；保留本地回归 workflow 和 F1/F2/F3 验收 |

额外可用能力：上游 fw inspect 通过远程 ZIP range 读取 BuildManifest，提前查看 vresearch101ap/vphone600ap 身份；可随原生准备模块迁移。此功能读取 manifest，不证明该固件完成了补丁或启动验收。

API 的 TCP 监听默认关闭；显式绑定非 loopback 地址时，上游没有认证层，文件写入及 daemon 更新能力会对该监听网络开放。若采用此入口，应保留本地访问约束或在部署层提供等价访问控制。

## 5. Git 合并模拟

| 结果 | 2d76f81 → 上游 4bab3b7 | 当前 2c604ea → 上游 4bab3b7 |
| --- | ---: | ---: |
| 未合并路径数 | 313 | 315 |
| 内容冲突事件（含 1 条 add/add） | 54 | 54 |
| 修改/删除冲突事件 | 56 | 57 |
| 目录迁移提示事件 | 199 | 200 |
| 重命名/重命名冲突事件 | 2 | 2 |

内容冲突事件按 `--messages -z` 的消息类型 `CONFLICT (contents)` 统计，其中 53 条为普通内容冲突，1 条为 `Package.resolved` 的 add/add 冲突。路径数和事件数的统计单位不同；同一重命名冲突可能涉及多个路径。200 条目录迁移提示不等于 200 处逻辑冲突，也不代表目录可以全部自动接受。例如，Git 建议把本地若干输入/宿主诊断文档统一移到 Research/Kernel，仍需人工确定归属。

主要冲突位置：

- Package.swift、Package.resolved、Makefile、release.yml：模块、依赖、构建和测试入口。
- FirmwarePipeline.swift、DeviceTreePatcher.swift、IBootPatcher.swift、CryptexFilesystemPatcher.swift：被识别为本地修改/上游删除，实际需与上游重构后的职责逐项对应，不能按删除状态丢弃本地功能。
- KernelJailbreakPatchVmProtect.swift、KernelJailbreakPatchPostValidation.swift 等：匹配策略、结构化返回值和补丁约束直接冲突。
- VPhoneVirtualMachineAppDelegate.swift、VPhoneHostAutomationServer.swift、VPhoneCameraServer.swift、VPhoneLocationProvider.swift：宿主接线、自动化和状态协议。
- 旧 VPhoneControl、创建/恢复/固件 CLI、CFW 脚本与 ObjC daemon handlers：上游替换或移除，本地仍有增强行为。
- PatchComparisonTests、VerboseJBDebug：双方移动/改名目标不同。需保留本地 FirmwareIntegrationTests 与快速测试的隔离。

[全部未合并路径与冲突事件](upstream_review_2d76f81_conflicts_2026-09-24.txt)。`21a9ce2` 已将原 JSON 快照移出版本控制，约定本地路径为 `research/artifacts/upstream_review_2d76f81_merge_2026-09-24.json`；该产物不随仓库分发。以下命令需要在包含双方提交对象的临时仓库中运行，只重新生成一次合并的 **NUL 分隔原始输出**，不会生成 JSON：

```sh
git merge-tree --write-tree --messages -z \
  2c604ea51361c0328964c7edf8b4c634cc4d3c81 \
  4bab3b76b3a2b6c5d68fecd292348176dbc18c4e \
  > /tmp/vphone-merge-2c604ea-4bab3b7.bin
```

复核另一组结果时，将第一个提交参数替换为 `2d76f814490e23e599197c22929f4b50071a978a`，并使用不同输出文件名。存在合并冲突时，该命令退出码为 1，仍会输出冲突结果。恢复原 JSON 格式还需要解析 NUL 分隔字段，并组合两次模拟及其元数据；这里不提供该 JSON 重建脚本，也不将原始输出标为 JSON。

## 6. 建议的合入顺序

1. 文档的 shell 覆盖结论已修正，导入/APFS clone 已完成。后续选择性移植两个固件目录条目，并在 EXP 范围内增加相机 DSC 三种状态识别、全部目标写入前校验及混合输入补齐；安装遇错继续策略单独处理，无需先迁移整个 Swift DSC 模块。
2. 独立引入签名、归档、恢复模块，保留本地阶段合约、排他锁和错误状态。原生恢复先完成探测/ticket/错误路径验证，再做真实恢复。
3. 成套迁移进程拆分与权限检查，验证停止身份、DFU owner、双 VM 和退出后的资源释放。
4. 保留本地宿主 API 和状态模型，引入 HTTP/WebSocket 客户机传输；逐项迁移 shell、位置所有权、相机回执、手势路由和取消/迟到响应处理。客户端库可复用，但不替代这些语义。
5. 在 VM 格式和客户机升级路径确定后迁移 v2 manifest、原生 CFW/GPU 流程；保留多变体安装器和需要的附带客户机环境。
6. 最后统一目录、名称、构建和 CI。目录变更可预先作为独立准备提交，但应避免与协议及补丁逻辑混在一个提交中。

本次没有执行构建、项目测试套件、真实固件补丁、恢复或 VM 启动。后续相机 DSC 实验只使用内存模拟输入验证本地函数控制流，没有新增真实固件同输入二进制对照或签名验证结果。上述顺序是基于依赖和现有实现的整合建议，不是运行验收结论。

## 7. 关键源码证据

- [当前对比报告](upstream_comparison.md)；[原评估历史版本](https://github.com/zhaoawd/vphone-cli/blob/9489ab296e3c1d345f936135b370d51da7a3c65d/research/upstream_comparison_2026-09-24.md)
- [本地进程识别](../sources/VPhoneCore/VPhoneLaunchLayout.swift)
- [本地占用保护](../sources/VPhoneCore/VPhoneBundleGuard.swift)
- [本地停止身份检查](../sources/VPhoneCore/VPhoneVMStopper.swift)
- [本地 vm_map_protect](../sources/FirmwarePatcher/Kernel/JBPatches/KernelJBPatchVmProtect.swift)
- [本地 postValidation](../sources/FirmwarePatcher/Kernel/JBPatches/KernelJBPatchPostValidation.swift)
- [上游 Package.swift](https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Package.swift)
- [上游 manifest](https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneCore/VPhoneVirtualMachineManifest.swift)
- [上游准备流程](https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneCLI/VPhoneFirmwarePreparer.swift)
- [上游 CFW 安装](https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneCLI/VPhoneCustomFirmwareInstaller.swift)
- [上游宿主接线](https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneVirtualMachineKit/VPhoneVirtualMachineAppDelegate.swift)
- [上游客户机控制](https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneVirtualMachineKit/GuestCommunication/VPhoneGuestControl.swift)
- [上游创建器](https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Sources/VPhoneCLI/VPhoneVirtualMachineCreator.swift)
- [上游 API 文档](https://github.com/Lakr233/vphone-cli/blob/4bab3b76b3a2b6c5d68fecd292348176dbc18c4e/Research/vphoned_http_api.md)
