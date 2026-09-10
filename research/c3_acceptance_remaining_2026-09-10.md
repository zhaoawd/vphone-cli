# C3 剩余验收范围

本轮 C3 已完成。最终验收状态以 [C3 完成验收记录](c3_completion_acceptance_2026-09-10.md) 为准；以下正文保留为历史记录。

日期：2026-09-10。本次核对代码、研究记录和本地产物，并扩展环境门控的真实内核测试。测试读取原始 IM4P，在内存中比较补丁结果；没有挂载镜像或操作 VM。既有证据与本轮结果分别记录。

## 已有证据

| 输入与设置 | 字节比较 | 必要项与产物检查 | 范围限制 |
| --- | --- | --- | --- |
| cloudOS 26.1 / 23B85 原始 research 内核；base regular / dev | 记录及 payload 相等，28 / 29 条记录 | 必要集合通过 | 仅内核组件，不是完整 iPhone 固件组合 |
| 同一 26.1 内核；JB，iOS 27 gate 关闭、Frida 关闭 | 84 条记录，记录及 payload 相等 | 必要集合通过 | 未覆盖所有 iOS 26.x 的完整输入 |
| 同一 26.1 内核；JB，iOS 27 gate 开启 | 91 条记录，字节相等 | 两个 IOMFB 方法失败 | catalog 为 iOS 27 配对 cloudOS 26.4；此项是负例，不作为支持组合 |
| 同一 26.1 内核；独立 EXP | 记录及 payload 相等 | EXP 必要项通过 | 没有据此证明 base → JB → EXP 顺序组合 |
| cloudOS 26.4 / 23E5207q 原始 research 内核；base regular / dev | 28 / 29 条记录，记录及 payload 相等 | 修正后必要集合通过 | 仅内核组件 |
| 同一 26.4 内核；JB：iOS 27 gate 关闭、开启、开启且 Frida 开启 | 分别 84 / 96 / 100 条记录，记录及 payload 相等 | 修正后必要集合通过 | gate 设置不能替代精确 iPhone 构建号及其 TXM、用户空间输入 |
| 同一 26.4 内核；base → JB → EXP，iOS 27 与 Frida gate 开启 | 133 条记录，记录及 payload 相等 | 顺序组合必要集合通过 | 未证明其他顺序组合设置；未启动该内核 |
| cloudOS 26.1 / 23B85、26.4 / 23E5207q 原始 DeviceTree；base / EXP | 分别 4 / 23 条记录，记录及 payload 相等 | 必要集合通过 | 仅 DeviceTree 组件 |
| 26.1 库存 iBSS / iBEC / LLB 与 iPhone 26.1 / 23B85 TXM | 既有记录称 9 项 parity 通过 | 覆盖各编排方法的比较 | 本轮已重新取得精确原始组件及来源哈希；旧方法级结果不等同于必要集合通过 |
| iPhone 26.1 / 23B85 restore 克隆；less Filesystem → Manifest，默认安装设置 | 未执行两次完整重建的输出字节比较 | 真实流程 applied；四组件 SHA-384、AEA 解密、内容及独立原始 root hash 检查通过 | 三份源输入与克隆哈希相同，但源来自已有 VM restore，未证明全为原始发行镜像；未覆盖完整 less 引导链或恢复启动 |

内核证据见 [内核迁移](patch_results_c3_kernel_2026-09-09.md)、[重新定位后的结果](c3_kernel_retarget_2026-09-09.md)、[EXP 迁移](patch_results_c3_exp_2026-09-09.md)。DeviceTree 与产物见 [产物迁移](patch_results_c3_artifacts_2026-09-09.md)、[less 验收](c3_less_acceptance_2026-09-09.md)。引导链见 [引导链迁移](patch_results_c3_bootchain_2026-09-09.md)。旧文档中的 26.4 匹配失败和 less 未执行描述属于历史状态，应结合后续修正记录阅读。

## 本轮真实内核验收

主控重新计算两份原始 research 内核的 SHA-256，均与既有记录相同：

| 输入 | IM4P SHA-256 |
| --- | --- |
| cloudOS 26.1 / 23B85 | `b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac` |
| cloudOS 26.4 / 23E5207q | `c853504319f27bfb3283253d8a5f36c3d0166ea7f4b178fca26fe6352b4de951` |

26.4 扩展矩阵与对齐检查退出码为 0；Swift Testing 报告 21 tests / 4 suites，通过耗时 501.736 秒。每个下列内核用例均比较旧调度与结构化调度的完整记录和完整 payload，并在 `VPHONE_REQUIRE_COMPLETE=1` 下确认 `failures=[]`。

| 补丁器 | 配置 | 记录数 |
| --- | --- | ---: |
| base | regular，EXC_GUARD 关闭 | 28 |
| base | dev | 29 |
| base | 非 dev，iOS 18 gate 启用 EXC_GUARD | 29 |
| base | 非 dev，forceExcGuard 启用 EXC_GUARD | 29 |
| JB | iOS 27 gate 关闭，Frida 关闭 | 84 |
| JB | iOS 27 gate 开启，Frida 关闭 | 96 |
| JB | iOS 27 gate 关闭，Frida 开启 | 88 |
| JB | iOS 27 gate 开启，Frida 开启 | 100 |

日志：`research/artifacts/c3-gate-acceptance-2026-09-10/stock-264-and-alignment.log`。base 的 iOS 18 用例是在 26.4 内核上测试 EXC_GUARD 门控，不表示 catalog 的 iOS 18 + cloudOS 26.1 配对已完成全链验证。

26.1 扩展 base 与默认顺序组合退出码为 0；Swift Testing 报告 2 tests / 2 suites，通过耗时 49.777 秒。base 的 regular / dev / ios18 / forceExcGuard 四配置分别为 28 / 29 / 29 / 29 条记录，完整记录和 payload 均相等、`failures=[]`。默认 base → JB → EXP（iOS 27 gate 与 Frida 均关闭）为 117 条记录，完整记录及 payload 相等，所有步骤无失败。日志：`research/artifacts/c3-gate-acceptance-2026-09-10/stock-261-base-chain.log`。

26.4 默认 base → JB → EXP（iOS 27 gate 与 Frida 均关闭）同样为 117 条记录，完整记录及 payload 相等，所有步骤无失败。退出码为 0；Swift Testing 报告 1 test / 1 suite，通过耗时 52.888 秒。日志：`research/artifacts/c3-gate-acceptance-2026-09-10/stock-264-default-chain.log`。

26.4 的 base → JB → EXP 顺序组合补充验收：iOS 27 gate 开启、Frida 关闭时为 129 条记录，完整记录及 payload 相等，所有步骤无失败。Swift Testing 报告 1 test / 1 suite，通过耗时 156.853 秒。日志：`research/artifacts/c3-gate-acceptance-2026-09-10/stock-264-ios27-chain.log`。

26.4 的 iOS 27 gate 关闭、Frida 开启顺序组合也通过：121 条记录，完整记录及 payload 相等，所有步骤无失败；退出码为 0，1 test / 1 suite，95.959 秒。日志：`research/artifacts/c3-gate-acceptance-2026-09-10/stock-264-frida-chain.log`。26.4 的四种 iOS 27 gate / Frida 顺序组合均已有证据：均关闭 117 条、仅 iOS 27 gate 开启 129 条、仅 Frida 开启 121 条、均开启 133 条。

## 精确引导链输入准备

本轮重新取得 iPhone 26.1 / 23B85 与 cloudOS 26.1 / 23B85 的原始组件；来源 URL、归档成员路径、长度和 SHA-256 记录于 `research/artifacts/c3-full-pipeline-2026-09-10/stock/sources.json`。AVPBooter 来自宿主 macOS 26.5.1 / 25F80。regular / dev / jb / exp 非 less 引导链生产流水线及必要集合报告均通过，分别为 29 / 34 / 68 / 88 个声明方法、58 / 70 / 152 / 178 条记录。独立落盘 payload 验证已通过（六类二进制记录重放，DeviceTree 序列化 parity）；此结果不代表完整恢复镜像、less 或运行验收通过。详见 [精确引导链验收](c3_full_pipeline_acceptance_2026-09-10.md)。

生产覆盖规则使用 cloudOS TXM。本次 cloudOS 与 iPhone 的 `Firmware/txm.iphoneos.research.im4p` 均为 161043 字节，SHA-256 均为 `3912f361973d70090b1f15a6e4ec64bd12e457a06d73555ec8880b76c861aa3a`；因此既有使用 iPhone TXM 的测试输入字节与本次 cloudOS TXM 相同。该结论仅适用于此精确输入。

## C3 补丁产物验收缺口

1. 兼容性清单还包含 26.3 / 23D127 + cloudOS 26.3 / 23D128 的历史 `patch_verified` 组合，本轮没有对应原始样本和结构化必要集合证据。其余 `code_selectable` 项仅表示代码可选择，不表示通过 C3。
2. 26.1 与 26.4 已补齐非 dev 的 iOS 18 / 强制 EXC_GUARD 门控；26.4 已补齐 JB 的 iOS 27 gate 关闭且 Frida 开启组合。这些组件级设置不能替代对应完整固件组合验收。
3. EXP 顺序组合已有 26.1 默认和 26.4 四种 iOS 27 gate / Frida 组合证据。该范围的顺序组合缺口已补齐，但不能外推到其他固件输入。
4. 26.1 / 23B85 四种非 less 引导链已补齐精确来源、哈希和结构化必要集合报告；独立落盘 payload 验证已通过（六类二进制记录重放，DeviceTree 序列化 parity）。26.4 内核通过不能代替对应 iPhone 构建的 TXM 和完整流水线验收。LLB `patchRootfssBypass` 必要性仍为待验证假设。
5. less 已通过 Filesystem → Manifest 真实产物检查；完整流水线、可选安装开关及其他精确输入组合没有随该结果获得验证。跨文件回滚属于 C4，不能在 C3 结果中声明已具备。

## 可立即执行的最小验收

26.4 缺失的顺序组合已补齐。26.1 / 23B85 四种非 less 引导链也已通过生产流水线与必要集合检查；落盘 payload 已按六类二进制记录重放与 DeviceTree 序列化 parity 分别通过验证。

随后为一个明确 iPhone 构建与 cloudOS 构建建立完整组件输入集，按 less / regular / dev / jb / exp 分别保存必要集合报告。缺失的版本保持未验证；不要把单个 cloudOS 内核在 iOS 27 gate 下通过写成所有 iOS 27 构建全链通过。

## 本地产物与 VM 运行验收

原始 kernel、DeviceTree、BuildManifest 位于 `research/artifacts/c3-kernel-2026-09-09/stock-261-ranged/` 和 `stock-264-ranged/`。修正后的日志位于同目录 `retarget/`。less 最终 AEA、Manifest、metadata 与校验报告位于 `research/artifacts/c3-less-2026-09-09/`；独立解密验证副本已按既有记录删除。`ipsws/`、`~/.vphone/ipsws/` 与 `~/.vphone/VMs/` 当前为空。

仓库有 `vm-2607`、`vm-2607-rig2`。后者 `restore-info.json` 标记 iPhone 26.1 / 23B85、cloudOS 26.1 / 23B85、exp；这些是已有 VM，不能仅凭目录存在或名称认定为可改写的独立验收实例。运行占用和实验隔离尚未核实。新运行验收需先建立明确独立的实例并核对来源、身份与占用。

修正后内核启动、调试器行为，以及 less 产物恢复、首次和第二次启动均未完成。它们是后续运行证据，需与 C3 静态补丁和产物结论分别记录。F1 还要求 GUI 输入、应用与文件、DDI、定位、相机及适用的 Frida 客户端 instrumentation，不能用端口连通替代。

## 本轮回归结果

以下命令从仓库根目录执行。使用 `--skip-build` 前先编译 release 测试；这一步未设置真实样本变量。命令清除 Frida 和顺序组合的继承设置，再显式启用本次需要的门控。`VPHONE_EXPECT_IOS27_FAILURES` 也清除，避免继承负例期望。

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache"

env -u VPHONE_TEST_KERNEL_IM4P -u VPHONE_TEST_KERNEL_CHAIN \
  -u VPHONE_TEST_FRIDA -u VPHONE_TEST_CHAIN_IOS27 \
  swift test -c release --disable-sandbox --cache-path .build/test-cache \
  --filter C1AlignmentTests

# 26.4：base 四配置、JB 四组合与对齐检查。
env -u VPHONE_TEST_KERNEL_CHAIN -u VPHONE_TEST_CHAIN_IOS27 \
  -u VPHONE_TEST_FRIDA -u VPHONE_EXPECT_IOS27_FAILURES \
  VPHONE_TEST_KERNEL_IM4P="$PWD/research/artifacts/c3-kernel-2026-09-09/stock-264-ranged/kernelcache.research.vphone600" \
  VPHONE_REQUIRE_COMPLETE=1 VPHONE_TEST_FRIDA=1 \
  swift test -c release --skip-build --disable-sandbox --cache-path .build/test-cache \
  --filter 'KernelStructuredParityTests|C1AlignmentTests|ArtifactStructuredTests'

# 26.1：base 四配置与默认 base → JB → EXP。
env -u VPHONE_TEST_FRIDA -u VPHONE_TEST_CHAIN_IOS27 \
  -u VPHONE_EXPECT_IOS27_FAILURES \
  VPHONE_TEST_KERNEL_IM4P="$PWD/research/artifacts/c3-kernel-2026-09-09/stock-261-ranged/kernelcache.research.vphone600" \
  VPHONE_REQUIRE_COMPLETE=1 VPHONE_TEST_KERNEL_CHAIN=1 \
  swift test -c release --skip-build --disable-sandbox --cache-path .build/test-cache \
  --filter 'baseKernelRecordsAndPayloadMatch|KernelPipelineParityTests'

# 26.4：默认 base → JB → EXP；该测试始终要求无失败。
env -u VPHONE_TEST_FRIDA -u VPHONE_TEST_CHAIN_IOS27 \
  -u VPHONE_EXPECT_IOS27_FAILURES \
  VPHONE_TEST_KERNEL_IM4P="$PWD/research/artifacts/c3-kernel-2026-09-09/stock-264-ranged/kernelcache.research.vphone600" \
  VPHONE_TEST_KERNEL_CHAIN=1 \
  swift test -c release --skip-build --disable-sandbox --cache-path .build/test-cache \
  --filter KernelPipelineParityTests
```

首次 `make test` 的 Python 73 项通过；Swift 的 VMStop 测试出现 9 条断言失败，同一沙箱拒绝执行 `ps`。该次 Swift 运行不记为通过。随后在允许进程查询的环境重跑 `make test_swift`，退出码为 0：XCTest 20 项、Swift Testing 298 项 / 46 suites 全部通过，后者耗时 25.525 秒。日志：`research/artifacts/c3-gate-acceptance-2026-09-10/swift-regression-unsandboxed.log`。

本轮完成新增内核门控、26.1 默认及 26.4 四组合的 EXP 顺序验收和回归验证；精确固件全流水线与运行验收仍未完成，C3 保持进行中。
