# C3 第三组：KernelJBPatcher 结构化结果迁移

> 历史记录：本文保留远程分支迁移时的实现与测试结果。2026-09-10 合并后的必要性以本地已验收定义为准：`patchVmMapProtect`、`patchCredLabelUpdateExecve` 均为 `.required`，不采用下文历史 optional 定义。基础内核仅 CMP 返回 `RawStepResult`，其余方法保留本地 Bool 接口及完整性判据。原始固件样本和 24 个非 less 场景、less 默认场景的既有证据见 [C3 完成验收](c3_completion_acceptance_2026-09-10.md)。这些既有结果不替代合并后复验；合并取舍与复验见 [远程合并记录](c3_remote_merge_2026-09-10.md)。

## 范围与设计

当前 `findAll()` 调用 33 个编排方法；清单中的 59 是历史统计，不能作为 Swift step 数量。保持 33 个方法的顺序、匹配、emit 和补丁字节。standalone `patchAmfiExecveKillPath` 未被 `findAll()` 调用，不新增执行。

必要性：22 个无门控核心方法 required；7 个 iOS 27 方法 conditional(iosBaseIs27)；2 个 Frida 方法 conditional(cloudOSFridaCapable)，按 applyFrida 快照判定；`patchCredLabelUpdateExecve`、`patchVmMapProtect` 按现有清单 optional。后两者的缺失允许跳过；有明确编码或部分写入失败时仍报告 failed（optional 不计入必需失败，遵守现有模型）。

PatchID 使用管线组件名 `kernelcache`，保留组件级和 patcher 级消融语义。清单中的本组方法名统一为 Swift 名称；Frida gate 与现有规则名称 `cloudOSFridaCapable` 对齐，其值仍为 enableFrida && cloudOSIsFridaCapable。

门控 step 无条件声明，run 内检查 applyIOS27/applyFrida。空 Data 的 buildSteps 不解析内核。setup 使用每实例一次的 ensurePrepared，顺序为 parseMachO、ADRP 索引、BL 索引、符号表、panic。

方法直接返回 RawStepResult，避免把 Bool 的“成功但无记录”一律当成命中。postValidationAdditional、bsdInitAuth 的已有显式幂等分支返回 idempotent，不新增记录。编排方法内的显式唯一性校验保留候选数量；仍返回 nil 的私有匹配辅助方法不新增失败原因推断。代码洞、编码和部分写入失败返回 encodeFail，保持已发生的 emit 和后续搜索顺序。

DiskImages2 的两个 ABI gate 必须成功；notification-port 的既有结构缺失跳过语义保持，其编码失败仍失败。Sandbox 扩展中 NULL hook 保留跳过语义；非空指针无法重编码或表项越界报告失败。Frida 无锚点返回 noMatch，由门控规则决定是否失败。

## 验证计划

- EXC_GUARD P2：真实工厂 + runner 的门控/失败回归。
- JB：33 step 声明顺序、必要性、空输入四组门控、首步消融后 setup、完整消融不解析不写入。
- 合成指令输入：歧义、幂等、部分成功结果及数据保持。
- 真实 kernelcache.research.vphone600：同输入 legacy/structured 的记录和最终数据对比，明确 fixture 和门控范围；与修改前结果另作对比。
- make build、相关 Swift 测试及 fast suite；记录环境限制。

## 验证结果

- `make build` 通过，完成 release 构建、entitlements 签名及 app 打包。
- `make test` 在沙箱外通过：69 个 Python 测试、20 个 XCTest 测试；Swift Testing 报告 284 个测试、39 个 suite 通过。新真实内核测试未配置环境变量时显式 skipped，本次已单独配置并执行。
- 新增 11 个结构化测试覆盖 P2 门控、清单名称与规则、33 step 顺序、四组门控、延迟 setup、完整/首步消融、组件级消融、唯一性与歧义、幂等无新增记录、Sandbox 部分写入、DiskImages2 的必需 ABI gate 与允许缺失的 notification 结构。参数化用例另外覆盖各开关组合。
- `patchVmMapProtect` 的可选性要求保留歧义信号：其私有辅助方法现返回原有候选数组，调用方仅在唯一候选时写入，多个候选返回 ambiguous。单/双候选合成测试通过，多个候选不会映射为 notApplicable。
- 32 个修改的 JB patch 文件中，所有 `emit(...)` 参数及源码顺序与 `9500f87` 完全一致。未修改 `KernelJBPatcherBase` 或 EXP patcher；未新增二进制补丁。
- `git diff --check` 通过。

### 真实内核字节比较

输入：`vm/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vphone600`（IM4P）。容器 SHA-256：`7e9bd5c31b7649bd8e2bfb54a067b8585b039eb76b945f0fd08615ee09b6076b`。这是本机 VM 样本，不能作为库存内核全部必需补丁成功的证据。目录名不用于推断混合固件的 cloudOS 版本。

先运行 base KernelPatcher（isDev=false、applyExcGuard=false），再对同一 base 输出执行 JB。迁移前在 `9500f87` 的 JB 实现上捕获四组 PatchRecord JSON 及最终数据到 `/tmp/vphone-jb-before-{ios27}-{frida}.{json,bin}`。迁移后通过 StructuredExecution 比较完整记录列表和最终 Data，并检查 recordIndices 覆盖全部记录。

| applyIOS27 | applyFrida | JB 记录数 | 记录与最终数据一致 | 必需失败数 |
| --- | --- | ---: | --- | ---: |
| false | false | 49 | 通过 | 14 |
| false | true | 51 | 通过 | 15 |
| true | false | 56 | 通过 | 16 |
| true | true | 58 | 通过 | 17 |

公共必需失败：taskConversionEvalInternal、ioucFailedMacf、procPidinfo、convertPortToMap、dounmount、ioSecureBsdRoot、loadDylinker、macMount、nvramVerifyPermission、spawnValidatePersona、taskForPid、thidShouldCrash、vmFaultEnterPrepare、syscallmaskApplyToProc（方法名均以 patch 开头）。Frida 开启另有 vmMapDeleteImmutableCode；iOS 27 开启另有两个 IOMFB SwapEnd 方法。这些结果表明此输入未满足全部必需步骤；缺失原因未逐一调查。本次未修改匹配器以追求该输入的全部通过。

四组比较用时约 251 秒。随后对 vm_map_protect 增加歧义信号；该变更保留原有候选生成和“仅唯一候选写入”条件，并通过单/双候选测试验证。没有再次执行四组完整扫描。

复验命令（已有迁移前捕获文件时）：

```sh
VPHONE_TEST_KERNELCACHE_IM4P="$PWD/vm/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vphone600" \
VPHONE_TEST_JB_BASELINE_PREFIX=/tmp/vphone-jb-before \
CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache" \
SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache" \
swift test --disable-sandbox --cache-path .build/test-cache --filter KernelJBParityTests
```

不设置 baseline prefix 时，测试会用当前版本的独立 `findAll()` 实例作比较；两种比较的证据范围不同。强制打开 iOS 27/Frida 的组合用于分支字节比较，不代表该固件组合受支持。

## 完成范围与限制

P2 修复及第三组实现完成。未执行 VM 启动验证，未证明库存内核或全部受支持版本的必需步骤均成功。没有向 VM 写入补丁固件，没有推送。EXC_GUARD 修复详见第二组文档 §8。
