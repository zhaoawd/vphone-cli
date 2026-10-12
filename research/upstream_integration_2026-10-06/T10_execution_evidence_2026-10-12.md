# T10 逐声明执行证据（2026-10-12）

本次修改声明执行门，不修改内核或其他组件的补丁匹配、替换指令、偏移发现算法及输出字节。原任务验收状态仍为未验收。

`PatchDeclarationGate.enforce(report:plan:)` 使用冻结 `selected` 中的步骤与显式记录规则求交。每条实际记录必须恰有一个已选声明归属；随后检查完整计划的全部必需声明。共享步骤的其他成功记录不能证明缺失项，整个组件缺失同样拒绝。事务提交前执行检查；只读 ablation 仍可生成报告。`--allow-ablation-output` 不豁免必需声明检查。

## 记录规则

规则表为 `sources/FirmwarePatcher/PatchSet/DeclarationRecordRules.swift`。规则源自本地实际 emitters，未采用上游声明 ID 作为实际 record ID，也没有任意前缀回退。

| 对象 | 规则来源与记录形式 |
| --- | --- |
| AVPBooter | `AVPBooterPatcher.swift` 的 `avpbooter.dgst_bypass` |
| iBoot | `IBootPatcher.swift` 的组件名加 `serial_label`、`image4_callback_bne/mov`、`boot_args_string/adrp/add`、`bootx_precondition`、五个有限 rootfs ID、`panic_bypass`；`IBootJBPatcher.swift` 的 `ibss_jb.skip_generate_nonce` |
| TXM | `TXMPatcher.swift` 的 `txm.trustcache_bypass` 与 `TXMDevPatcher.swift` 的明确 `txm_dev.*` ID 集合 |
| DeviceTree | `DeviceTreePatcher.swift` 的逐属性及节点 `patchID`，逐项精确列举 |
| Kernel | `Kernel/Patches`、`Kernel/JBPatches`、`Kernel/EXPPatches` 中的实际 `patchID` 字面值；APFS 四项分开归属，Sandbox 五个基本 hook 分开归属；扩展 hook 索引为有限集合（含 124 和 267） |
| 可变偏移后缀 | 仅 `kernel.handle_get_dev_by_role.gate_` 后接该记录 `fileOffset` 的大写十六进制文本；不接受任意后缀 |
| less | `CryptexFilesystemPatcher.swift` 的 `filesystem.cryptex.merge`，`ManifestHashPatcher.swift` 的 `manifest.hash` |

规则以可选存储字段编码到 `PatchDeclaration.recordRules` 和 `VariantPlanResolver.Entry.recordRules`，新目录与新计划均包含实际规则，因此目录摘要及计划摘要覆盖规则。旧目录、旧计划及旧 journal 缺字段时保留 nil，重新编码仍省略该字段，不回填当前规则。旧计划允许读取/恢复，但新执行门明确拒绝 selected 中无冻结规则的计划。旧 v1 journal 与旧 v2 绑定 journal 的摘要验证和只恢复测试通过；恢复不重新运行补丁器。

## alreadyApplied 证据

`StructuredExecution` 在 discovery 后、buffer commit 前，对本次 patcher 的当前输入载荷（`fallback`，即该 patcher 接收的实际当前 payload）读取记录范围，确认该范围已等于 `patchedBytes`。只有实际读回相等、范围有效且预期字节非空时，才记录载荷及输出范围的 SHA-256。证据包含声明 ID、组件、组件内 recordIndex、fileOffset、byteCount。门再次核对记录绑定及输出摘要。

结果状态、原始字节与替换字节相等、记录数量未变化均不能单独取得发布资格。零记录的 idempotent 路径继续返回原状态，但门拒绝其发布；本次没有为这些路径补造记录或改变补丁算法。证据属于本次内存执行报告，尚未实现签名收据或磁盘输出逐范围读回；后续收据工作不能把此摘要当作未经验证报告的真实性证明。

## 验证

- 旧实现的 3 个可编译行为测试均因预期错误未抛出而失败，退出码 1：[RED 日志](evidence/2026-10-12-declaration-evidence/red.log)。首次受限编译因缓存访问失败，提权重试后才取得上述行为 RED。
- `scripts/run_tests.py fixtures`：退出码 0，17 个 fixture 存在且非空。
- 最终 `swift test --scratch-path /private/tmp/vphone-five-tasks-swift-20261012 --force-resolved-versions --disable-sandbox --filter 'FirmwarePatcherTests|FirmwareIntegrationTests'`：退出码 0，313 个测试、59 个 suite 通过：[完整日志](evidence/2026-10-12-declaration-evidence/validation.log)。
- 规则纳入目录摘要及旧记录恢复兼容补充后，FirmwarePatcherTests 300 个测试通过；随后新增旧 v2 绑定 journal 测试，RequiredDeclarationEvidenceTests 11 个测试通过，两个命令均退出 0。日志为 [补充单元验证](evidence/2026-10-12-declaration-evidence/catalog-validation.log) 和 [旧绑定恢复验证](evidence/2026-10-12-declaration-evidence/legacy-binding.log)。最终代码另以 `--filter FirmwareIntegrationTests` 补跑完整固件对照，退出 0，15 个测试、12 个 suite 通过：[最终固件验证](evidence/2026-10-12-declaration-evidence/final-firmware.log)。
- 五模式 regular/dev/jb/exp/less 完整必需证据正例通过；精确缺一 APFS 必需项时同一步骤其他成功记录保留，门仅报告该缺项；缺整个组件、未知记录、无证明 alreadyApplied、载荷实际不匹配、非法偏移后缀均拒绝。
- 故障测试在事务暂存目录写入后删除一个必需声明的证据，声明门抛错，未调用 commit，原始固件及模拟磁盘文件逐项不变，未发布 history。
- 单组件真实固件记录审计通过；单组件报告提交到完整计划门明确拒绝。完整固件比较覆盖仓库现有历史参考，不表示固定上游 `2d21d21` 的字节等价。
- 旧全组件 ablation 成功夹具改为只读实验报告；发布拒绝另有事务日志测试，取消与必需执行失败仍显式测试事务路径。未启动 VM、修改 VM 磁盘、调整 AMFI/TCC、覆盖主 `.build`，未执行恢复/启动验收。
