# C3 内核补丁结果迁移

日期：2026-09-09。承接 C3 基础引导链提交 `355121f`。本次按基础内核、JB、EXP 分组记录实现与验证。

## 基础内核：实现

`KernelPatcher` 声明 12 个结构化方法，顺序与原 `findAll()` 一致。11 个基础方法为 required；`patchExcGuardBehavior` 使用 `excGuardActive` 条件，与 dev、iOS 18 和显式 EXC_GUARD 选项保持对应。枚举方法和消融目标时不解析或修改输入；首个实际执行的方法初始化 Mach-O、ADRP/BL 索引和 panic 定位。

执行器在方法调用前处理消融和为假的条件规则。内核 `emit()` 会立即修改内存缓冲区，因此事后删除记录不能代替这项检查。

每个方法的 Bool 完成信号与该方法新增的记录共同决定结果：返回 false 表示 failed；已有部分记录时保留这些记录并说明组未完成。返回 true 且有记录时，根据原字节与替换字节是否全部相同区分 applied/alreadyApplied。返回 true 但没有记录默认是 noMatch，不能推断为已应用。

`patchApfsMount` 已使用四个子方法的逻辑与。`patchSandbox` 原来只检查任意一个 hook 成功，现要求声明的五个 hook 全部成功；定位、写入顺序和字节不变。此修改不会增加补丁写入，但会使此前部分成功的组件返回失败。未迁移的调用者仍可读取原有记录。

## 分析来源与范围

输入范围为 `kernelcache.research.vphone600`。本次修改结果编排和完整性判据，不重新定位内核补丁，不增加指令编码或文件偏移。

本地 `kernel_symbols.db` 包含 release/research 两条记录，但 JSON 路径指向另一台机器的 `/Users/qaq/...`，当前 JSON 文件缺失。因此本次没有可引用的符号地址结果，也未把数据库路径作为补丁器运行依赖。

按仓库技能补充 `research/reference/xnu`，提交 `f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`。`security/mac_policy.h` 声明了基础 Sandbox 使用的五个 hook；这里只核对名称与独立回调关系，不用最新 XNU 的字段位置替代当前内核的定位证据。

## 验证设置

- 无固件测试：缺失必要方法、部分组失败、已应用字节、条件关闭和消融不执行写入、清单方法集合。
- 真实输入比较：同一输入分别创建旧 `findAll()/apply()` 与结构化路径实例，比较完整 `[PatchRecord]` 和最终 payload。输入以只读方式加载，产物仅在内存中比较。
- `VPHONE_TEST_KERNEL_IM4P` 未设置时，固件比较 suite 显式跳过；设置后文件缺失或解码失败会使测试失败。
- 当前 `ipsws/` 与用户固件缓存为空。`vm-2607` 里的输入可能已被修改，比较相等不能证明原始固件全部必要项均成功。原始样本获取和结果另记。

## 本轮结果

基础内核专项：6 项测试通过，其中真实输入比较包含 regular/dev 两个参数用例。`vm-2607` 输入分别产生 14/15 条记录，旧路径与结构化路径的记录和最终 payload 均相等。两种模式均有 8 个方法失败：`patchApfsRootSnapshot`、`patchApfsSealBroken`、`patchBsdInitRootvp`、`patchDebugger`、`patchPostValidationNOP`、`patchPostValidationCMP`、`patchApfsGraft`、`patchApfsMount`。这组结果不作为原始固件补丁完整性通过的证据。

首次沙箱内 `make test`：Python 69 项通过；Swift 的 VMStopTests 出现 9 条断言失败，沙箱同时拒绝 `ps`。内核专项通过。完整回归在允许进程查询的环境重跑通过：Python 69 项、XCTest 20 项，Swift Testing 报告 276 项（未设置真实输入的 parity suite 显式跳过）。`make build` 与 release、app 主程序的 `codesign --verify --strict` 均通过。

输入 IM4P SHA-256：`7e9bd5c31b7649bd8e2bfb54a067b8585b039eb76b945f0fd08615ee09b6076b`。基础内核实现与本地比较已完成；原始样本完整性验收尚未完成。

C3 尚未整体完成，不扩大已有兼容性声明。
