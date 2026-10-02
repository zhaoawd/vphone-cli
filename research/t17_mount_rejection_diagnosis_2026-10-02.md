# T17 可写重挂拒绝：只读诊断与对照实验范围

日期：2026-10-02。范围：核对已批准 R7 的失败证据、固件事务、目标映像和现有补丁；未新增补丁，未修改客户机、候选或默认固件策略。两个验收 VM 已停止保留。

## 结果

R7 确认失败于 `mount -u -w /`，目标库未替换。当前证据将未修改的 mount wrapper 根卷检查列为对照实验对象，尚不能确认本次系统调用的具体拒绝分支。R7/T17 成功路径与 R8 回退仍未通过；B7 的 R 通过前置条件未满足。

## 实验设置与证据

- 目标：26.1 / 23B85，`kernelcache.research.vphone600`。实际版本字符串为 `Darwin Kernel Version 25.1.0: Thu Oct 23 11:11:48 PDT 2025; root:xnu-12377.42.6~55/RELEASE_ARM64_VRESEARCH1`。
- 输入来自 v2 VM 固件事务 `67225571-b3ad-46d4-8b37-c1cca0c9ce96/backup/iPhone17,3_26.1_23B85_Restore/`。IM4P SHA-256 `b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac`；解压 Mach-O SHA-256 `b6846048f3a60eab5f360fcc0f3dcb5198aa0476c86fb06eb42f6267cdbfcae0`，43,991,040 字节。
- 固件 report 记录 regular 的 28 项内核写入；逐项核对原始字节与备份一致。其中包含 APFS mount、upgrade 与 sandbox mount/remount 补丁。计划将 `kernel-boot-mac_mount` 列为 excludedByVariant；该声明当前只适用于 jb/exp。
- 当前映像的 `mount_common()` 字符串引用与 PAC 函数入口、局部调用关系得到唯一 wrapper。没有使用外部符号文件或旧偏移作为匹配条件。

| 对象 | 文件偏移 | 虚拟地址 | 当前指令与关系 |
| --- | --- | --- | --- |
| mount_common 候选 | 0xCA3868 | 0xFFFFFE0007CA7868 | 由当前字符串引用恢复；符号名称是控制流与字符串对应推断 |
| wrapper 候选 | 0xCA5B38 | 0xFFFFFE0007CA9B38 | 调用上述函数，包含唯一的两个现有补丁锚点 |
| flags bit-5 检查 | 0xCA5D54 | 0xFFFFFE0007CA9D54 | `tbnz w28, #5, ...`，目标以 `mov w25, #1` 设置返回值 |
| state byte 检查 | 0xCA5D88 | 0xFFFFFE0007CA9D88 | `ldrb w8, [x8, #1]`，随后 `tbz w8, #6, ...`；另一条路径检查 flags bit 0，并设置返回值 1 |

28 项 regular 记录均不覆盖这两个检查点。这说明固件报告没有修改它们；未直接读取运行时内核内存，不能将报告与原始备份替代为运行时命中证据。既有 `KernelJBPatchMacMount.swift` 在同一语义锚点输出两项记录；本次没有执行其写入逻辑。

## 源码对应与限制

本机符号 JSON 缺失，SQLite 索引中的 `/Users/qaq/...` 路径也不存在。本机 `research/reference/xnu` 缺失。采用公开的相近版本 `xnu-12377.1.9`，而非声称匹配目标 `12377.42.6`。

参考 [vfs_syscalls.c](https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.1.9/bsd/vfs/vfs_syscalls.c#L984)：SECURE_KERNEL 下，根文件系统请求可写挂载时返回 EPERM。参考 [mount.h](https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.1.9/bsd/sys/mount.h#L273)：MNT_RDONLY 为 bit 0，MNT_UNION 为 bit 5，MNT_ROOTFS 为 0x4000。当前 wrapper 从第二个参数的 flags 位置加载 w28；state byte bit 6 和随后的 flags bit-0 检查，与根卷检查形态吻合。这是跨相近源码版本的对应推断，运行时拒绝分支仍未验证。

历史 `patch_mac_mount.md` 的第一处“Preboot-volume”解释不作为本次结论。当前寄存器来源及上述公开源码支持用户挂载 flags/MNT_UNION 的对应推断。最初偏移探测混用了虚拟地址末尾与文件偏移，故“不匹配”判断有误；动态恢复已纠正，实际两个文件偏移与历史记录一致。错误探测输出不参与结论。

其他限制：已保存串口日志包含启动挂载信息，没有提供本次重挂对应的内核拒绝位置。无法从缺少某种日志排除其他检查。API daemon 的静态 entitlement 包含 disk-device-access/no-container/rootless 项，但未核对 mount 辅助进程的运行时权限；不能宣称所有权限限制已排除。

## 验证

`scripts/diagnostics/inspect_vphone600_mount.py <解压映像>` 是只读工具，以 Mach-O executable segments、Capstone operands、字符串引用和调用关系定位唯一候选。实际命令 `.venv/bin/python3 scripts/diagnostics/inspect_vphone600_mount.py research/artifacts/v2-remaining-20261002/t17-kernel-original.raw` 退出 0；取得唯一 wrapper。初版未处理 fileset 的无 section executable segment，以及 Capstone 高地址有符号 immediate，未得到候选；修正后取得上述结果。没有以旧地址替代匹配。

证据目录 `research/artifacts/v2-remaining-20261002/`（Git 忽略）：t17-firmware-report.json、t17-regular-plan.json、t17-jb-plan.json、t17-kernel-original.raw、t17-mount-wrapper.json、t17-analysis-summary.json、t17-serial-mount-lines.txt。分析没有运行新的固件补丁测试或 VM 对照，不能建立修复结论。

## 已批准的对照实验（2026-10-02）

现有 R5–R9 计划明确不执行新增内核补丁。下面的动作原本超出该批范围；用户已单独回复“批准”。实现与准备进行中，真实 VM 对照尚未执行：

1. 在独立构建目录准备实验入口，仅对显式选择的 regular-v2 实验候选增加现有 `kernel-boot-mac_mount` 的两项记录；沿用语义匹配、ARM64Encoder、严格声明与记录，不使用本记录中的偏移作为 patch logic。先写复现/范围断言，再实现并核对只有两项额外内核写入。classic 与默认 regular 选择不变。
2. 新建隔离 VM `lp-v2-mount-accept-20261002`，继续使用现有 26.1 原件、独立缓存及已验证环境候选。保留当前 v2/classic VM、所有旧盘和事务。新建与恢复涉及认证、TSS 和磁盘空间；新宿主产物预检仍须通过。
3. 在新 VM 上先验证 R1–R4，再重复单库 R7；只有在线替换成功后，验证旧映射 stale、仅重启 cameracaptured、新映射 current，以及该次 R8 回退。若仍拒绝，保留失败结果，不追加其他补丁。只读恢复失败时按原范围重启该实验 VM，记录实际 root_read_only 状态。
4. 该实验不迁入其他 JB 补丁，不覆盖 MIS/T18，也不把成功实验自动提升为发布或默认策略。根据实测结果再决定是否纳入 v2 固件设计。

## 实验入口与准备进度

`vm create --guest-environment v2 --experimental-v2-root-remount` 要求 regular-v2。固件流水线只追加现有 MAC mount 步骤，其他 JB 步骤不执行。选项写入有效选项、事务 journal、补丁报告和实验记录；默认值省略，历史检查点与补丁选择摘要的字段保持兼容。续跑保留记录值；改变该设置要求从 prepare 生成新固件。验证器拒绝实验设置与固件报告不一致。

测试按新增范围断言失败、实现、验证执行：补丁计划测试缺少参数时编译失败；命令行测试报告 unknown option；检查点测试缺少字段时编译失败；报告不一致和事务暂存选项丢失均先得到断言失败。实现后相关测试通过。`make test_swift` 第二次运行退出 0。第一次运行同时出现归档权限比较失败与 JB 方法来源对齐失败；第二次归档测试通过，原因未查明；JB 对齐失败由 mount-only 的单独调用改变来源匹配引起，改为调用唯一声明步骤后通过，没有删除或弱化断言。

真实原始内核的内存对照：`VPHONE_DIAG_KERNEL_IM4P=<上述备份> swift test --filter KernelGateDiagnosisTests.regularMountExperimentChangesOnlyTwoAdditionalInstructions` 通过。基础 28 项记录逐项相同，仅新增 `kernelcache_jb.mac_mount.flag_gate` 与 `kernelcache_jb.mac_mount.state_clear`，各 4 字节。完整候选输出等于基础输出加这两项替换；源文件未写入。两个锚点仍由当前映像语义匹配取得，未新增固定偏移。

独立构建目录 `/private/tmp/vphone-v2-mount-build-20261002`；新 VM 名称 `lp-v2-mount-accept-20261002`；分阶段入口 `scripts/diagnostics/run_v2_mount_acceptance.zsh`。环境初始候选沿用 R6 的单库 libcamfix -O1，在线候选沿用 R7 的单库 libvcamcaptured -O1。API token 运行时生成，不写入证据。空间预检 90 GiB；保留旧 VM、旧盘及事务。构建、宿主预检及新 VM 实测结果待回填。
