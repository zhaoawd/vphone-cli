# C3 远程迁移合并

日期：2026-09-10。合并输入：本地 `ea129ab` 与远程 `5cdb42c`（包含 `9500f87`）。状态：冲突复核、完整回归、构建签名与产物比较全部通过。提交和推送由主控执行。

## 合并取舍

- 保留本地已经验收的匹配算法、写入位置与替换表达式。基础内核 CMP 接入明确歧义信号，其余方法保留 Bool 接口和本地完整性判断。
- JB 的 33 个编排方法采用 `RawStepResult`，保留远程明确的歧义数量、编码失败、部分写入及已存在补丁信号。`patchVmMapProtect` 与 `patchCredLabelUpdateExecve` 保持 required；门控沿用本地清单。
- 基础内核和 JB 的 `findAll()`、结构化步骤共用 `ensurePrepared()`。`buildSteps()` 仍可用空输入枚举；完整消融不进行准备，首步消融不影响后续步骤准备。
- 只有明确 matched 且新增记录非空、全部原始字节等于新字节时，记录适配器返回 idempotent。明确失败不因已写入记录而变为成功。
- `firmware_compatibility.json` 保留本地 38 条证据及验证阶段。合并后的强对齐测试发现 C1 旧清单在 JB/EXP 的 `patchVmMapProtect`、`patchCredLabelUpdateExecve` 四项仍记为 required=false，与本地生产步骤的 required 不一致；现统一 required=true 并清空 expected_not_applicable，不修改历史组合阶段。远程两份迁移文档作为历史记录保留，顶部注明最终定义与既有原始样本证据。

## 测试整合

本地 `KernelStructuredTests.swift` 全部保留。远程独有用例放入 `KernelStructuredMergeTests.swift`，覆盖真实工厂 EXC_GUARD 门控、清单与方法顺序、四组 JB 门控、延迟准备与消融、IOMFB 歧义、显式幂等、Sandbox 部分写入、DiskImages2 两个 ABI gate 和允许缺失的 notification 结构、vm_map_protect 唯一与歧义候选。vm_map_protect 用例改为验证 required，缺失不得作为非适用通过。

`FullPipelineParityTests` 增加可选 `VPHONE_TEST_PIPELINE_OUTPUT_VM`，将当前结构化输出与合并前 CLI 实际产物的完整解包 payload 比较。矩阵脚本 `--output-run-name` 检查历史场景、配对和输入来源摘要一致，再将只读基准目录传给测试。未提供参数时清除继承的基准变量，保持原始运行语义。

## 验证结果

- Python 矩阵脚本语法检查通过。
- 初次沙箱内 Swift 编译被 Clang ModuleCache 写权限阻止，尚不构成代码编译结果；主控将统一执行 release 构建与测试。
- 24 个非 less 场景的合并前实际产物比较全部通过，最终提交和推送由主控执行。

既有 C3 验收范围见 [完成记录](c3_completion_acceptance_2026-09-10.md)。本次合并未修改 Filesystem/Manifest 镜像构建流程；不新增 less 恢复、启动或 F1 运行证据。

C1 被移除的历史非适用说明原文分别是：`JB Enabled=N：待启动验证（JB-03）` 和 `Shape A(26.1-26.4) 生效；Shape B(26.5) 已停用（0_binary_patch_comparison.md:157，JB-25）`。它们记录的是旧清单状态，不能覆盖当前生产步骤必要性；未因此获得新的启动或 26.5 验证结论。

### 主控复验进度

- 最终 `make test` 退出码为 0：Python 73 个测试通过；XCTest 21 个测试，1 个 skipped、0 个失败；Swift Testing 314 个测试通过。
- `make build` 通过，签名完成。
- less 真实产物只读 legacy/structured 比较通过，用时 77.047 秒。Filesystem 实现未变化，本次没有重新构建镜像；既有完整产物验证保持原证据范围。
- 主控逐文本核对 35 个变动的既有 kernel 文件，emit 调用块未改变；EXC_GUARD、Filesystem、Manifest 及 Core 文件与本地合并前 HEAD 完全相同。Pipeline 仅提取等价的 gateSnapshot。
- 非 less 矩阵 24/24 个场景通过，最终运行退出码为 0；261、263、2661、270b5、1862 五份 `parity-summary.json` 已齐全。每个场景均确认当前 legacy/structured 完整记录相等，并逐字节比较当前结构化输出与合并前 CLI 实际产物的全部 9 个组件 payload；矩阵脚本同时确认 9 项基准比较均执行。
- 完整测试初次编译发现新增用例使用不存在的 `PatchRecord.newBytes`；改为实际字段 `patchedBytes` 后，上述最终完整测试通过。
