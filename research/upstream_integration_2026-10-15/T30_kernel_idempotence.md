# T30：postValidation 幂等记录回归

日期：2026-10-15。范围：合成 ARM64 fixture 的 JB post-validation、结构化声明证据；未读取或修改真实 kernel 工件，未执行 VM 验收。

## 问题与复现

使用 `diagnosing-bugs` 与 `kernel-analysis-vphone600` 指引。读取 `CONTEXT.md` 与现有 2026-10-13 Task 8 已应用输出证据记录。

初始命令：`swift test --disable-sandbox --cache-path .build/test-cache --filter KernelJBStructuredTests/postValidationRecognizesIdempotenceWithoutEmitting`。模块缓存为仓库 `.build/test-module-cache`，首次调用清除 `VPHONE_TEST_`、`VPHONE_LESS_`、`VPHONE_C4_` 验收选择器。

`red.log` 确认失败位于第二次调用后的第 197 行：`ready.emittedRecords.count → 2`，期望 1。第一次 `.matched` 和记录数 1 均通过；原问题描述中的“第一次产生 2 条记录”与实测不符。此 fixture 已仅包含字符串、调用关系及比较位置；测试执行约 0.005 秒。

## 假设与证据

1. 旧测试未同步合法的已应用输出记录契约。预测第二条记录位于同一位置，原字节等于输出字节，buffer 不变。
2. 重复调用执行第二次实际修改。预测第二条记录表示字节变化或 buffer 发生变化。
3. 扫描命中额外位置。预测第二条记录位置与第一条不同。

定向探针 `probe.log` 复现原失败：两条记录的文件偏移均为合成 fixture 的 520（0x208）。第一条原字节 `1f040071`、输出 `1f00006b`；第二条原字节和输出均为 `1f00006b`，buffer 不变。假设 1 获得支持，假设 2、3 与观测不符。上述地址与字节仅标识测试数据，不代表真实内核地址或运行补丁锚点。

提交 `4ffa37bf` 将已应用路径由直接返回 `.idempotent` 改为 `emitVerifiedOutput`。该函数核对当前字节并追加相等字节记录。2026-10-13 研究记录要求这种观察证据，以便 `StructuredExecution` 关联当前输入和已验证输出摘要。测试仍要求第二次不增加任何记录，因而与已有契约不一致。

## 修改与验证

仅修改 `tests/FirmwarePatcherTests/KernelStructuredMergeTests.swift`：

- 原测试改名为 `postValidationRecognizesIdempotenceWithVerifiedOutputWithoutWriting`。分别验证恰好一条实际修改和恰好一条已应用观察，检查相同位置、patch ID、实际原字节、预期输出、零新增字节变化及完整 buffer 不变。
- 增加 `postValidationAlreadyAppliedBindsEvidenceToCurrentPayload`。在全新 patcher 上输入已修改的合成 payload，经正式 `StructuredExecution` 路径，验证 `.alreadyApplied`、唯一记录、声明归属、记录索引、范围、输入摘要、输出摘要及最终数据不变。
- 提取共享 fixture 构造函数。未更改生产补丁逻辑。

反证实验：临时将生产已应用路径恢复为直接返回 `.idempotent`，两个增强测试均失败（`missing-evidence-red.log`）。随后恢复生产源码；生产文件无最终 diff。此实验验证回归测试能识别缺失的已应用证据，未仅放宽旧记录数断言。临时探针已从测试源码删除。

最终定向命令：`swift test --disable-sandbox --cache-path .build/test-cache --filter 'KernelJBStructuredTests|RequiredDeclarationEvidenceTests'`。结果见 `evidence/T30-kernel-idempotence/regression.log`。两个新增/更新测试先单独通过，相关两组共 21 项通过。

## 限制与后续

本次验证为 firmware-free 合成 fixture，不能证明真实固件匹配、restore 或 VM 启动。完整 Swift 回归由并行任务协调者统一运行。未来更改记录契约时应同步无固件测试，区分实际修改记录与已验证输出观察。
