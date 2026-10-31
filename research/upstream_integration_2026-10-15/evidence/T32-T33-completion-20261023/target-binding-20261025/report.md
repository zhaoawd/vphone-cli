# T32/T33 暂存目标绑定与 EXP 路径修复（2026-10-25）

regular 三项 Mach-O 已完成同候选应用→撤销→精确重应用，结果保持。EXP 尚未完成真实部署及撤销；本轮完成局部代码修复和无 VM 回归，不将夹具结果计为真实应用验收。未启动 VM 或辅助窗口，未安装新 Bundle，未执行新的 CFW。

## 问题、原因与证据

1. **暂存目标记录错误。** `guest_write.run(cp)` 已记录正确的 Preboot 源路径和目标；`guest_write.logical(source)` 也返回正确值。实际 `cfw.main()` 在处理 `.cfw_temp` 文件时无法从挂载路径推导目标，`patch-build-version` 因而使用默认的 System 根路径。`tests/test_build_version_target_binding.py` 两次复现 Preboot 记录错误，System 对照通过。原始失败记录为 `build-version-target-binding-red-v2.log` 和 `build-version-target-binding-red-repeat.log`。最初的 `red.log` 是夹具环境摘要未同步，不能作为产品缺陷证据。
2. **本地安装路径遗漏。** 上游保留源 `VPhoneCustomFirmwareInstaller.swift` 的 System 阶段明确处理 rootfs 及 `System/Cryptexes/OS` 两份 plist，Preboot 阶段仅在文件存在时处理。本地原脚本只处理 rootfs 与 Preboot，遗漏 System/Cryptexes 路径。执行实际 Shell 补丁步骤的夹具复现此遗漏；目标规则也拒绝该路径。原始记录为 `system-cryptex-target-red.log`。
3. **当前 Preboot 文件缺失。** 只读检查已结束：`Cryptexes/OS` 为目录，`Cryptexes/OS/System` 不存在；扫描67项未找到其他 SystemVersion.plist。正常卸载、磁盘身份保持，耗时6.468秒。结果不能证明运行时会生成或映射此文件，具体运行关系尚待验证。没有创建替代文件。

原计划 `74985b1c…` 保留但撤回执行建议。本次修复改变了生产源码及规则摘要，旧候选 `16f1cc296c84` 不包含这些修复；旧计划已知两项执行输入摘要不匹配。详见 `withdrawn-plan-74985b1c-20261025.json`。未修改旧计划文件或已有批准记录。

## 修改

- `guest_write.staged_target` 从当前事务的操作记录核验最近一次 guest→staging 复制及后续修改链。检查 generation、planDigest、desiredSHA256、声明、精确目标、源路径、源字节及权限、记录的前后状态、链连续性，以及当前暂存文件完整字节与权限。缺少复制关联、上下文不符、内容或权限改变、符号链接和硬链接均在补丁写入前拒绝。暂存文件名不授予目标权限。
- `cfw.main()` 对暂存的 `patch-build-version` 输入使用上述目标；直接挂载目标仍经过精确目标表授权。
- `cfw_install_exp.sh` 增加 System卷 `System/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist`，保留现存 Preboot 文件处理。文件缺失时不创建。
- 通过生成器仅新增上述一个精确 owner 项，未增加目录前缀授权。目标表摘要从 `5f259f42583bb7b1f1426b986a86801fc421e17921fc157fe4a74bd596771213` 变为 `cf03209f536f245fb775a5a146eaa6a769d6c427ec061c644b9a5a1bc67354a8`。Swift `GuestTargetRules` 同步；原件来源映射本来已包含此目标，无需把已安装文件提升为原件。

## 验证

- 暂存目标绑定首批13项通过，3.532秒，包括重复调用和篡改拒绝。
- 增加第三条 System/Cryptex 路径、实际安装 Shell 步骤及旧规则拒绝后，共17项目标绑定测试。Shell 回归使用真实 cp、补丁入口和最终效果验证；没有 APFS 挂载或 VM。
- 文件事务回归增加两条暂存路径，执行实际生产、文件撤销、最终读回和 journal 发布；APFS查询由夹具提供。完整原件及 mode/uid/gid 恢复通过。
- 首轮相关104项中，103项通过，一项既有 v2 宿主克隆夹具被沙箱 EPERM 拒绝；未降低断言。完整 Python 回归通过：1113项，4项跳过，325.646秒，退出0。命令：`.venv/bin/python scripts/run_tests.py python`，在允许 APFS clonefile 的测试环境执行。
- 完整回归后追加整树组合检查：硬链接源→变换→真实复制→暂存build-version补丁→最终效果与原件链，连同两条原有整树路径、17项目标绑定和文件事务，共30项通过，8.540秒。该次追加只修改测试，没有修改生产代码。未重复全部Python回归。
- Swift `FirmwareDesiredPlanStoreTests`、`FirmwarePlanBindingTests` 共30项通过。新增测试证明旧全表摘要无法授权当前计划，当前计划仍可从已验证输入准备。第一次新增测试错误地在 regular 夹具中查 EXP 声明，后改为受同一全表摘要约束的 seputil 声明，未改变生产验证条件。
- `generate_guest_target_rules.py --check` 与 `zsh -n scripts/cfw_install_exp.sh` 通过。与修改前 JSON 结构比较，仅增加指定 owner 项。

release CLI构建完成；沙箱中的dsymutil失败记录保留，在正常构建环境生成项目内调试符号后成功。新候选`2.6.2-local.caa8df845ab6`归档SHA-256为`ca86224b32fb34df22d90d05baae06072be43a52ad6943a9728c670bbd0d2e7d`，195003392字节。完整Bundle签名、12份宿主Mach-O依赖及客户机资源核验通过。相对旧候选仅CLI、4份脚本/规则资源、来源记录、构建索引及Bundle签名记录改变；VM程序和客户机资源字节保持。该候选未安装，不能据此声称真实消费通过。

## 迁移与后续验收

全表摘要变化会影响所有声明规则及 catalog 身份，不能手改旧 desired-plan 的摘要或复用其执行批准。`FirmwareDesiredPlanStore.prepare` 会先读取旧 desired-plan，旧规则失效时不会隐式覆盖。generation 的标识由已验证原件及磁盘身份决定，并非由本轮规则摘要单独决定。

后续采用新隔离副本，通过正式 generation/plan 准备入口建立匹配关系，保留现有 regular 通过状态、EXP失败副本、原件和历史。只对新副本执行 EXP 验收。必达目标为两份真实 System 文件；Preboot按实际存在性报告，不能用“跳过”替代其部署通过。各阶段核对安装目标、来源、完整原件恢复、首次及重应用的完整字节与 mode/uid/gid。新候选、新对象和写盘范围须形成独立具名计划后批准。

具名计划已准备：`.build/t32-t33-completion-20261023/exp-target-binding-acceptance-20261025/offline-plan.json`，SHA-256`b3b98f370e384a3659dea2428651cb033566e01a8641897651038a3701f8805b`。目标为尚未创建的`.build/t33s-20261025`，只执行EXP正式安装及build-version声明的应用→撤销→精确重应用；不重跑regular。新副本从保留完整备份复制10项启动文件，正式入口生成匹配的新generation/plan；使用现有锁定Python环境。每阶段保留独立审计、完整原件及来源要求。若出现额外Preboot撤销目标，精确目标集合核验失败并停止，不将其计为通过。

289项计划输入已冻结并读回，94项执行输入已冻结并读回。新执行器7项隔离回归通过，覆盖目标和规则替换拒绝、容量不足时先拒绝、生产失败不重试、不回滚，以及保留核验失败不能返回成功。此处执行器测试的生产阶段为夹具；共用的原生阶段读回和精确transition继续由既有执行器实现。计划初始门槛75GiB，准备时可用61030400000字节（56.84GiB），容量检查不通过。尚未生成批准标记，未发起新系统认证或部署。

随后只读准备复核通过：源备份10项完整字节及身份、14个保留磁盘身份、94项执行输入、目标不存在及无附件。已封装的实际CLI执行只读`fw plan --variant exp --base-os 26 --no-cloudos-frida-capable --json`，build-version规则与新目标表摘要一致。最近可用61243432960字节（57.04GiB），距75GiB门槛约17.96GiB；本轮没有删除数据。该核验记录在`fresh-exp-preparation-checks.json`。

成本测量已证明单次 regular `verify-plan` 用时222.811秒，其中四次64GiB历史postimage摘要占200.603秒；嵌套读数不相加。本轮没有减少完整性检查或引入跨请求摘要缓存。后续不重跑 regular，先验证新路径的完整局部调用链，再考虑原生执行。当前空间低于旧75GiB新副本初始门槛，不自动清理旧数据。

真实 Settings/显示、AA.gl及应用消费仍待验收；AA.gl EPERM 原因未查明。T32/T33整体 `accepted=false`。

归档索引：`evidence/T32-T33-completion-20261023/target-binding-20261025/manifest.json`。只归档源码、JSON和日志，不归档签名P12或客户机二进制副本。
