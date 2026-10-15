# T32/T33：同 ID 实现迁移的生产准入拒绝

日期：2026-10-15。固定上游目标：`8a75092013eda87a4e30ed029b72028cb9279ac4`。

## 结果与范围

第一批完成当前目标下旧 IOMFB 实现的生产准入拒绝。第二批实现隔离输入上的条件分派算法及状态识别。第三批接入 generation 原件来源、DSC 完整成员与逐操作前像的持久索引，以及实际最终读取器和磁盘发布入口的消费校验。生产准入仍拒绝；索引尚不授权撤销重打，payload/Undo/Receipt 的完整迁移发布尚未实现。T32/T33 保持未完整验收。

`scripts/patchers/plan_gate.py` 在真实安装、更新及最终证据入口的 `from_environment()` 取得已验证冻结计划后检查实现资格。若 `dyld-boot-iomfb_force_kern` 属于启用集合且 `gates.iosBaseIs27` 为真或缺失，则明确拒绝。`require_write_context()` 同样在创建证据目录或文件之前检查。

`guestUncovered` 并不按该项的上游 OS applicability 分类。iOS 26 和 iOS 18 的真实计划也可能含此 ID。因此，已验证 `iosBaseIs27 == false` 的计划可以继续其他写入。`cfw.py` 对显式 `patch-iomfb-force-kern` 命令额外拒绝，防止通过旧 OS 计划绕过缺失的迁移与发布资格。

现有只读 `load_plan()` 解码验证不新增实现拒绝；环境更新 `check_command()` 不调用此次写入准入逻辑。旧目标不能取得新执行资格，原有 target mismatch 检查保留。第一批 `--dry-run` 输出 `LEGACY diagnostic only`；第二批接入条件算法后改为 `ISOLATED diagnostic only`。dry-run 不写入，其结果不建立生产迁移或发布资格。没有新增绕过开关。

## 上游与本地证据

- 保存的 `evidence/git-audit/endpoint.diff` 中，上游 `DyldSharedCacheUndoLog.outdatedImplementations` 仅对 `dyld-boot-iomfb_force_kern` 判定 `original.count == 4`。旧实现每入口写 4 字节无条件分支，新实现每入口写 16 字节条件分派器。
- 上游 installer 对已启用且已记录的旧实现先撤销再应用；撤销失败保留旧 live 状态，重打失败记录该补丁未应用。`dyld-boot-maxslide` 则属于单独的每次重跑集合，其旧 Undo 形状无法区分实现，重跑用于修复头页证明。
- 第一批基线的 `cfw_patch_iomfb_force_kern.py` 生成无条件 `b _kern_*`，并将相同已补丁分支视为幂等。第二批已替换为下述条件算法。
- 本地 `VPhonePatchUndoLog` 是内存恢复辅助类型，没有生产调用方。其 generation 字符串、记录长度、当前字节相等均不能单独建立原件来源。
- `component_effects.py` 保存操作前内容和最终效果。操作前内容可能已含旧补丁；内容摘要证明内容一致，不能证明它是首次可信原件。不得把这些 blob 直接提升为迁移授权。

因此，本批不根据 4 字节记录或当前分支反推原始指令，也不向旧缓存写入新的“可信 Undo”。新目标的旧实现不能取得成功证据。

## 验证

定向回归覆盖：

- 真实 `cfw.py`、`plan_gate.py entry`、`plan_gate.py verify-final` 及 `cfw_install.sh` 入口拒绝。缓存测试输入分别代表原始、已修改和空内容；拒绝不依赖输入内容，并发生在读取/修改 DSC 及创建证据之前。
- iOS 26/18 的 `guestUncovered` 同 ID 计划允许另一项已授权补丁实际写入并记录效果；显式 force-kern 写入被拒绝，证据不增加。
- 排除版本、变体、显式 opt-in 和未实现分组不会误阻止其他授权写入。
- `selected` 同 ID、未知 OS gate、直接 writer context 均拒绝。
- 真实旧目标 `2d21d21fbdd4f51f013616273ceda9b35a3e0789` 继续按原 target mismatch 规则拒绝新执行，计划文件不变。
- 第一批 dry-run 明确标记旧算法，并传递只读参数；第二批更新对应断言。

最终定向套件 50 项通过，耗时 33.643 秒；`git diff --check` 通过。测试日志：`evidence/T32_T33/plan-gate-tests.log`。沙箱内首次运行的既有 v2 staging 测试出现 `EPERM: Operation not permitted`；同一隔离 fixture 单项在沙箱外通过。最终定向套件在沙箱外运行，仅使用临时目录和命令替身，不连接真实 VM。

## 剩余工作

1. 对第二批条件算法执行固定 24A446 真实 DSC 对照，核验完整入口集合、分支目标与端口布局；其他 build 需要独立适用证据。
2. 建立首次原件、generation、组件、patch ID、实现代际、全部改写范围与可信 Undo 的持久关联。拒绝缺失、损坏、混合代际及部分记录。
3. 在隔离组件副本上完成旧字节核对、撤销、重打、代码页及 DSC 头页证明、最终读回；将 payload、Undo、Receipt 和来源放入同一发布事务。
4. 对缺少可信旧 Undo 的 VM 提供受控原件迁移或明确拒绝，不从当前已补丁字节补造原件。
5. 另行完成 maxslide 头页修复与对应回归，不能用 IOMFB 的记录长度机制代替。
6. 完成迁移中断、恢复、真实 VM 启动、VZ 显示、DeviceHub 流和回退验收。

## 第二批：条件算法与状态判定

`cfw_patch_iomfb_force_kern.py` 的实际入口现在先解析符号并完整规划，再写入隔离副本：

```text
cbz x0, <保留的原失败目标>
ldr w16, [x0, #0x14]
cbnz w16, _kern_Swap<Name>
b _virt_Swap<Name>
```

`0x14` 是固定上游研究在 24A446 上验证的 connection 字段偏移，本批没有新增其他固件适用证据。所有指令由 Keystone helper 生成，Capstone 按类型化操作数校验并复核编码后的完整分支目标，避免越界立即数截断。函数地址由当前 DSC 符号解析，不固化地址。

状态与处理如下：

| 状态 | 判定与处理 |
| --- | --- |
| original | 四指令间接分派结构、同一失败目标、有效 X 寄存器和无索引/无 writeback 载入；保留原失败目标生成条件分派 |
| current | 完整条件分派结构、端口偏移、scratch 寄存器、kern/virt 符号目标及规范编码匹配；不重复写指令 |
| legacy | public 第一指令为跳向对应 kern 的无条件分支；拒绝整次处理，要求可信 Undo |
| unknown | 其余完整 public/kern/virt 三符号入口；拒绝整次处理 |

上述状态是算法分类，不证明内容是首次可信原件，也不授权 Undo。旧 public/kern 对即使缺少 virt，也先检查 legacy；因此旧 31 站点集合不会仅处理新 10 站点后被误认为迁移完成。

固定上游真实缓存测试的 `ConditionalReference.leftOnVirtPath` 明确只有 `_IOMobileFramebufferSwapSignal`。本地按该操作名显式排除改写，保持其原路径；若它出现已知 legacy 无条件分支，仍拒绝。其他未知完整三符号入口不使用此例外。该例外不证明任意新 build 的 SwapSignal 内容有效。

完整预检包含必需的 Begin/End/SetLayer、符号地址冲突、唯一可执行映射、虚拟和文件范围重叠、失败分支不进入改写范围、分支编码范围和完整 CodeDirectory 页槽。16 字节跨签名页时覆盖两端页。全部预检通过后重新检查所有已分类字节，再执行写入、页摘要更新与最终字节/摘要读回。current 站点也参与页摘要检查和修复。

此入口用于隔离副本；写入或重签期间的 I/O 故障可能留下不完整的隔离输出。失败不会输出完成结果，但当前没有 durable rollback，不能将这一局部执行代替 payload/Undo/Receipt 事务。生产门控因此继续拒绝。dry-run 同样检查结构和签名槽，但不写入指令、摘要或资格证据。

第二批回归直接调用实际 `patch_iomfb_force_kern()`，使用带真实 mapping、CodeDirectory 和页摘要的临时 DSC 文件；只有符号查找边界被替换。另有真实 `cfw.py --dry-run` 子进程测试，使用确定性的 `ipsw` 输出替身。

算法、既有语义与 guardrails 合计 **35 项通过**，日志见 `evidence/T32_T33/conditional-algorithm-tests.log`。测试覆盖完整原始、当前、混合、legacy、unknown、缺必需符号、旧集合缺 virt、SwapSignal 例外、空指针目标、16 字节跨页、缺失/截短签名槽、过远分支、输入变化和重签失败。未执行真实 VM 或真实固件写入。

RED 对照将 `HEAD` 中的旧 writer 载入独立测试命名空间，执行条件路由、legacy 拒绝、缺必需 virt 和缺签名四项断言；四项均失败且无测试错误。日志：`evidence/T32_T33/conditional-baseline-tests.log`。三个受影响的生产门控/dry-run/旧 OS 对照测试通过，日志：`evidence/T32_T33/conditional-plan-gate-tests.log`。全部验证只涉及临时 fixture。


## 第三批：generation 来源与操作前像的持久关联

新增 `scripts/patchers/undo_provenance.py`。真实调用路径为：

1. `cryptex_source.prepare` 比较工作源与 generation 原件内容，直接从 generation 原件生成缓存，并复核生成前后的原件内容身份。不会把工作缓存的当前字节补记为首次原件。
2. `cryptex_source.attach` 在原始 SystemOS 的只读挂载中记录 DSC 成员摘要。捕获前后均通过 `hdiutil` 核对缓存与 mountpoint 的绑定，通过 `diskutil` 核对精确的只读挂载。来源校验重算 generation manifest 的 content ID，以及 manifest 中对应顶层 original 的实际目录树摘要；符号链接、硬链接、内容变化均拒绝。marker 写入后验证失败会恢复此前 marker。
3. `guest_write` 的实际树复制证据把原始只读成员与安装目标关联。`cfw.py` 的 DSC 生产入口记录操作前后保留内容，并附加当时 Python patchers 源文件集合的摘要。该摘要是观察到的实现身份，不是工具链签名或运行时证明。
4. `final_guest` 在只读最终卷验证完整操作链后，重建并持久化 `guest-undo-provenance.json`。每项记录 generation、计划、完整 DSC 成员原始摘要、source binding、复制记录、declaration ID、实现摘要、逐操作前后摘要及全部差异范围。签名页差异属于范围的一部分。写入索引后再次检查来源、staged image 身份、操作证据、挂载关联和只读状态。
5. `plan_gate.py verify-final` 将索引摘要放入最终证明，并将索引、最终证明和操作文件的摘要密封到 staged journal。`cfw_disk_txn.publish` 在交换磁盘之前读取这些证据，从原件与完整链重新计算索引，核对当前 VM、执行证据目录和 staged inode。缺失或不同的索引、证明、journal anchor 均拒绝。

索引状态为 `qualified-preimages-not-migration-authority`。完整成员原始内容与每个 patch 操作前像分别保存。操作前像可能包含前序补丁，不能单独作为首次原件。来源缺失的既有 DSC 操作只记录于 `unqualifiedTargets`，不产生 Undo 资格；已建立来源链后，链中断、混代、缺 blob、未知实现身份或不支持的传输则拒绝。当前不支持尺寸变化的 DSC 操作，也不把 EXP 转换后的可写缓存提升为原始只读来源。

新磁盘事务使用 `version: 2` 和固定 `provenanceMode: required`；没有可切换的免检参数。生产 stage 调用为 `cfw_install_host.sh` 的唯一 `txn stage` 路径。环境更新的真实 `cfw_env_update.apply` 现在捕获文件复制效果，host 环境更新与完整安装都执行 `verify-final`；环境更新通常产生空 DSC 资格索引，但仍需完整最终效果证明。旧 version 1 事务可继续恢复与清理，不能继续 publish；重新执行需建立新 staged 事务。

### 当前边界

- 本批没有执行逆向 Undo、旧实现撤销、新实现重打，也没有解除 IOMFB 门控。
- 新索引验证原件与操作链关联，尚未建立 installed Receipt 与 payload/Undo 的共同发布协议。
- host 在最终效果读取之后仍执行 cleanup 和受控 snapshot rename。该步骤会修改同一 image，因此当前发布只绑定 staged dev/inode，不能直接用此前 mtime 检查最终磁盘全部内容。snapshot 后再次验证或转换证明仍待完成；不得把此次索引消费表述为完整安装语义或迁移发布验收。
- 完整 generation original 目录树需要重新读取和计算摘要，真实大固件上的时间与空间成本尚未测量。
- 未操作真实 VM、真实挂载或真实固件写入。原始来源、挂载关联和最终卷使用隔离 fixture 与系统命令替身验证。条件算法对真实 24A446 的完整入口验收仍待完成。

### 验证范围

`tests/test_undo_provenance.py` 调用真实 prepare/attach、guest_write、cfw.main、plan_gate verify-final 和 publish consumer。覆盖有效来源链、缺来源不提升原件、原件篡改/硬链接、可写卷/错误挂载、混合 generation、缺实现身份、缺原 blob、最终成员替换、索引篡改/链截断、删除索引与 anchor 的组合、跨 VM 整套证明互换、索引持久化期间 image/rows/manifest 变化、环境更新实际 apply 与最终证明。环境资格分类在该组合测试中使用替身；既有环境套件单独覆盖真实分类、只读检查和更新拒绝。

磁盘复制/交换/清理套件的 disposable installer 不运行真实固件生产者，其 test-only harness 显式替换 provenance consumer；真实 provenance consumer 的拒绝与交换前调用由上述专项测试覆盖。生产没有测试绕过参数。native 磁盘原语脚本也经相同隔离 harness，避免把原语测试误当成固件资格验收。


第三批相关组合初跑 157 项：156 项通过，1 项失败。失败项仍断言解密器输入为可变工作源；修正为精确 generation 原件路径，并增加内容相等断言后，最终补跑 **36 项全部通过，59.956 秒**。补跑包含 15 项来源/索引专项、修正单项、环境最终证明失败拒绝和 19 项磁盘事务/恢复测试。`git diff --check` 与 `zsh -n scripts/cfw_install_host.sh` 通过。完整 Python 套件由主代理顺序执行并另行记录。

证据：`evidence/T32_T33/preimage-validation.json` 保存验证范围、限制与源码摘要；`preimage-related-initial.log.gz` 保存相关组合结果；`preimage-final-targeted.log.gz` 保存最终补跑。初次沙箱内相关运行的进程/磁盘检查出现 EPERM，保留于 `preimage-sandbox-environment-failures.log.gz`；授权的沙箱外重跑使用同一隔离 fixture 和断言。

`test_index_validation_is_not_post_snapshot_payload_attestation` 记录当前边界：最终读取后同 inode 修改模拟 snapshot 变化，索引重建仍只核对此前已观察的来源和效果链，不证明修改后的 payload。该测试不调用交换发布，不授权迁移，也不解除生产门控。后续需在 snapshot 转换后重新执行只读语义校验，或者建立独立的受控转换证明。
