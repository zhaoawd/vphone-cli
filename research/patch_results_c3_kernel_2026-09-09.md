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

## JB 内核：实现与判据

基础内核提交：`dcc7268`。JB 声明 33 个结构化方法，按旧 `findAll()` 顺序执行。24 个方法始终必要，7 个受 `iosBaseIs27` 控制，2 个受 Frida 开关控制。门控关闭在执行器中产生 notApplicable，不调用方法。

`patchCredLabelUpdateExecve` 增加 Bool 返回值，只有完成所有 trampoline 和所有跳转写入才返回 true；中途退出保留已有记录并报告失败。原定位、分配和写入序列不变。扩展 Sandbox 对已声明且非 NULL 的回调全部要求编码成功；超出表范围或任一非 NULL 回调编码失败时，方法返回 false。NULL 表项表示未安装回调，保持原来的跳过行为。

`patchPostValidationAdditional` 与 `patchBsdInitAuth` 的原实现会在明确识别已修改分支后返回 true、且不写记录；结构化包装对此返回 alreadyApplied。没有增加幂等记录，因此记录列表不变。其他方法 true + 零记录不据此推断为已应用。

兼容性清单内 JB 方法从旧 Python 名称对齐到 Swift 名称；删除当前 `findAll()` 未调用的 `patch_amfi_execve_kill_path`。该方法的实现未删除，也未加入调度。此修正描述当前 Swift 流程，不新增补丁。

单组件 `patch-component` 改为执行结构化路径，支持方法级消融。必要失败时先写诊断报告、返回非零并保留已有输出文件；消融默认不写 payload。此前该入口仍使用旧路径并聚合为 legacy 报告。

JB 现有 VM 样本：26.x 门控 49 条记录、27.x 门控 56 条记录，旧路径与结构化路径的记录和最终 payload 相等。原始 cloudOS 26.1 样本：基础 regular/dev 为 28/29 条记录，JB 26.x 门控为 84 条；这些路径必要项全部通过，记录和最终 payload 均相等。

额外运行 cloudOS 26.1 + iOS 27 门控，记录为 91 条且字节比较相等，但 `patchIomfbSwapEndVariableSize`、`patchIomfbSwapEndHandlerSize` 失败。本次最初对该组合施加“全部必要项成功”断言，测试如实失败。该组合不作为支持范围；项目 catalog 为 iOS 27 选择 cloudOS 26.4，后续在对应原始样本上独立验证。没有放宽这两个方法的必要性，也没有为通过断言修改补丁字节。

原始 cloudOS 26.1 内核 IM4P SHA-256：`b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac`。来源为 `VPhoneFirmwareCatalog.cloud261` 中的 Apple URL。`ipsw dl pcc --info` 因 release leaf missing metadata 失败；`ipsw extract` 长时间未返回，已结束本次进程。实际使用 HTTP Range 读取同一 ZIP 的中央目录和目标成员，未下载完整 IPSW。

## 原始 cloudOS 26.4：结果与未完成验收

26.4 / 23E5207q 的旧路径与结构化路径在全部已运行用例中记录、payload 相等：regular 28 条，dev 28 条，JB 26.x 83 条，JB 27.x 95 条，JB 27.x + Frida 99 条。regular 必要集合通过；dev 的 `patchExcGuardBehavior` 失败；三种 JB 设置均有 `patchVmMapProtect` 失败。严格完整性测试因此出现 4 条失败断言，不能把字节一致性通过表述为完整性通过。

顺序组合 base → JB → EXP（iOS 27 + Frida）产生 132 条记录，旧路径与结构化路径的记录和 payload 相等；必要集合仍因 `patchVmMapProtect` 失败。EXP 层自身通过。

`KernelGateDiagnosisTests` 通过显式 `VPHONE_DIAG_KERNEL_IM4P` 启用，直接调用这两个实际步骤；26.4 上 2 项均失败，总耗时约 7.4 秒。单步骤 CLI 消融其他方法后重复得到相同结果。该 suite 是当前缺陷的失败复现，默认跳过，不属于已通过的原始固件验收。

已验证的历史证据：提交 `81b0cd8` 明确停用 `vm_map_protect` Shape B，因为其命中 COW 写权限剥离而非预期 RWX gate，并记录了 SPTM 崩溃与隔离实验。提交说明写的是“26.5+ 停用、26.1–26.4 Shape A 保留”；这不足以解释当前 26.4 原始内核缺少 Shape A 的结果。版本范围与原始内核实现之间的对应关系待确认。EXC_GUARD 输出 `thread_guard_violation not found via anchor chain`，原因未查明。

本次不恢复 Shape B、不把方法改为 optional，也不根据匹配失败推断 notApplicable。后续须分别核实原始内核中的函数/调用链与适用范围，再独立提交定位或规则修正。新补丁定位前必须记录语义锚点、XNU 对应关系和验证步骤。C3 保持进行中。

## 可重复验证命令

以下环境变量的路径均指向只读原始 IM4P。未设置输入变量时，真实样本 suite 显式跳过；设置后文件缺失或解码失败会使测试失败。

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache"

# 26.4 / 23E5207q：regular、dev、JB（26.x/27.x）、Frida、EXP。
VPHONE_TEST_KERNEL_IM4P="$PWD/research/artifacts/c3-kernel-2026-09-09/stock-264-ranged/kernelcache.research.vphone600" VPHONE_REQUIRE_COMPLETE=1 VPHONE_TEST_FRIDA=1 swift test --disable-sandbox --cache-path .build/test-cache   --filter 'KernelStructuredParity|ExpStructuredParity'

# 顺序组合：base → JB → EXP，包含 iOS 27 与 Frida。
VPHONE_TEST_KERNEL_IM4P="$PWD/research/artifacts/c3-kernel-2026-09-09/stock-264-ranged/kernelcache.research.vphone600" VPHONE_TEST_KERNEL_CHAIN=1 VPHONE_TEST_CHAIN_IOS27=1 VPHONE_TEST_FRIDA=1 swift test -c release --disable-sandbox --cache-path .build/test-cache   --filter KernelPipelineParityTests
```

对 26.1 / 23B85 的额外 iOS 27 负例，设置 `VPHONE_EXPECT_IOS27_FAILURES=patchIomfbSwapEndVariableSize,patchIomfbSwapEndHandlerSize`，精确断言这两个失败；未设置时 `VPHONE_REQUIRE_COMPLETE=1` 要求全部必要项成功。该变量只控制测试期望，不影响补丁器或流水线。

两个构建号已从对应 ZIP 的 `BuildManifest.plist` 核实。原始 cloudOS 26.4 内核 IM4P SHA-256：`c853504319f27bfb3283253d8a5f36c3d0166ea7f4b178fca26fe6352b4de951`。输入与日志位于 Git 忽略的 `research/artifacts/c3-kernel-2026-09-09/`。

后续诊断已定位 26.4 两项匹配失败的机制，并核对 less 输入与缺失工具；见 [C3 验收失败诊断](c3_acceptance_diagnosis_2026-09-09.md)。这是诊断结果，不表示修复或验收通过。
