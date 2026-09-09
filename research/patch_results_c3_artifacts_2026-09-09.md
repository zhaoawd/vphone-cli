# C3 DeviceTree、Manifest、Filesystem 与测试判据

日期：2026-09-09。范围：现有产物操作接入结构化结果，不新增固件补丁。

## 实现

DeviceTree 按现有定义声明基础 4 个步骤，EXP 共 23 个步骤（属性与新增节点合计）。每个步骤先解析/获取共享树，再执行单个定义；提交阶段统一序列化整棵树，不能把带长度变化的记录按原偏移直接写回。消融在修改树之前生效。

属性的值、长度、flags 已符合目标时返回 alreadyApplied。新增节点存在时，逐个核对定义中的属性、长度、flags；同名但内容冲突时失败，不把节点存在等同于完成。缺失必要属性不会被其他成功属性掩盖。

Manifest 使用 `patchManifestHash` 步骤。读取、计算或序列化异常转为 failed，保留错误原因。记录改为实际 Manifest 原字节与重建字节，替代原来两个空字节数组的占位记录；最终 Manifest 字节不因结构化包装而改变。

Filesystem 使用 `patchCryptexFilesystem` 步骤。原操作完成后才生成 applied 结果；异常返回 failed。结果中的字节记录表示重建 Manifest 的替换，不能解释为所有外部镜像文件的完整差异清单。外部文件的阶段记录、暂存、恢复由 C4 继续处理。

`less` 的 Filesystem 操作会写外部产物。C4 暂存机制完成前，消融干运行必须显式消融 `filesystem`（或其 patcher/完整步骤 ID）；否则在读取输入之前拒绝。这项约束避免把只禁止最终 payload 保存误报为整个流程不写磁盘。

## 测试判据

`tests/test_firmware_patches.sh` 与 `tests/test_jb_kernel_patches.sh` 请求 `--report-out`，使用 `scripts/check_patch_report.py` 验证：

- 报告、结果与记录数组必须存在；不接受 legacy 覆盖或消融运行作为验收通过。
- 必要步骤必须 applied/alreadyApplied；失败、无效状态、未知规则、越界记录索引均拒绝。
- 按当前兼容性清单核对完整方法集合，避免只输出部分成功方法的报告通过。
- 接受明确的 notApplicable 与已验证的零写入 alreadyApplied；日志文字不参与成功判定。
- 验收脚本也拒绝可选步骤的 failed 状态；生产流水线的既有必要性策略未在本项修改。

兼容性清单的 EXP DeviceTree 聚合项拆为实际 23 个定义，基础变体保留 4 项。新增 Python 用例覆盖缺失方法、部分失败、legacy、消融、门控与记录索引。

## 验证结果

`ArtifactStructuredTests`、`DeviceTreeStructuredParityTests`、CLI 结果测试与 EXP 合成测试共 12 项通过，其中 DeviceTree 原始样本比较包含两个参数用例。

原始 cloudOS 26.1 DeviceTree：基础 4 条、EXP 23 条 PatchRecord，旧 `findAll/apply` 与结构化路径的记录、最终 payload 相等，全部必要项通过。输入 IM4P SHA-256：`df0e5ceb010ae028b6e9a3322a07379a30911ee48f385cfe23f6931896cd096a`。

合成验证覆盖：DeviceTree 重建和幂等、单属性消融、必要属性缺失；Manifest 实际文件哈希与输入缺失；Filesystem 无效输入失败与整体消融不创建产物；less 干运行前置拒绝。Filesystem 完整镜像合并、挂载、重封装与输出字节比较未执行，不能据这些合成用例宣称 less 完整固件流程通过。

完整回归通过：Python 73 项、XCTest 20 项，Swift Testing 报告 291 项；显式原始样本 suite 在默认快速测试中跳过。顺序组合的字节一致性通过，但 JB 必要方法失败，见内核记录。

后续检查补充两项：必要组件失败后停止后续组件处理，避免把 Filesystem 捕获的异常转为报告后继续执行 Manifest；dev 的门控快照补入 `variant == .dev`，保持该变体原本始终启用 EXC_GUARD 的行为。新增回归使用只有第一个组件的隔离目录，确认失败后不再查找后续输入，并确认 dev 内核步骤没有被条件拦截。前面已成功写入的组件不会因此回滚，仍由 C4 处理。

原始 cloudOS 26.4 DeviceTree 的基础 4 条、EXP 23 条记录比较与必要项检查通过。输入 IM4P SHA-256：`987a9306d16a9047dc1b46fd1b3cec2aab7738aff6c5c86938ee3ada1a461e3c`。新增的失败后停止与 dev 门控回归、CLI 输出目录回归均通过 release 专项测试。

最终完整回归：`make test` 通过，Python 73 项、XCTest 20 项、Swift Testing 报告 295 项/45 suites。默认未设置原始样本和诊断变量；原始 26.4 的两项失败仍按内核记录保留，不计入这次通过结论。

产物组提交 `01847be` 后执行 `make -W sources/FirmwarePatcher/Kernel/KernelPatcher.swift build` 成功；release 二进制与 app 主程序均通过 `codesign --verify --strict`，两者导出的 7 项 entitlements 与 `sources/vphone.entitlements` 完全相等。最终构建日志归档于 `research/artifacts/c3-kernel-2026-09-09/vphone-c3-signed-build.log`。
