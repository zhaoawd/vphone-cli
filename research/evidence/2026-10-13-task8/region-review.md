# Task 8：候选内核共享区域识别审查

日期：2026-10-13。

## 证据与范围

- 工件：`ipsws/patch_refactor_input/raw_payloads/kernelcache.bin`，由 `kernelcache.research.vphone600` 解包；`kernel-inspection.log` 记录两者 payload 一致。
- payload SHA-256：`b6846048f3a60eab5f360fcc0f3dcb5198aa0476c86fb06eb42f6267cdbfcae0`。
- 内核版本字符串：`Darwin Kernel Version 25.1.0: Thu Oct 23 11:11:48 PDT 2025; root:xnu-12377.42.6~55/RELEASE_ARM64_VRESEARCH1`。
- 本地 XNU 参考：`research/reference/xnu`，commit `f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`，tag `xnu-12377.1.9`。参考源码与目标内核版本不同；函数用途与参数对应关系属于源码关联推断。
- `osfmk/vm/vm_shared_region.c` 的 `vm_shared_region_create` 在 `CPU_TYPE_ARM64` 分支赋值 `base_address`、`size`；随后调用 `pmap_set_shared_region(config_pmap, nested_pmap, base_address, size)`。ARM64 ABI 对应 `x2=base_address`、`x3=size`。

## Reveal 方法

运行时只使用候选镜像。查找唯一 `pmap_set_shared_region\0` 字符串，用 Capstone 解码验证 ADRP/ADD 引用，再向前查找 `pacibsp` 函数起点。引用必须归属唯一函数。检查该函数直接调用点之前的 ARM64 CPU 类型构造、比较及不等分支，并沿相等分支追踪到调用点的寄存器和 SP 相对 spill。

目标镜像中观察到字符串引用所在函数的文件偏移为 `0xc3dd14`；符合条件的调用点为 `0xc043e8`。`0xc04300` 至 `0xc04318` 的 CPU 类型判断及常量路径经 SP `0x70` spill 和被调用者保存寄存器到达参数寄存器。文件偏移仅用于研究证据，未写入运行时识别逻辑。

## 修改

- 预检查 Mach-O load command 和 segment 长度，避免畸形输入进入现有宽松解析器后发生越界或整数转换异常。
- 通过 Capstone 的结构化 `shiftType`、`shiftValue`、`extender`、`writeback` 字段判断指令。没有使用 `operandString` 匹配。
- 拒绝未知指令、间接跳转、返回、SP 修改、内存 writeback、未支持的移位算术和区域参数无法确定的路径。
- 按实际宽度使重叠 spill 失效。32 位部分覆盖使原有 64 位 spill 失效；相邻且不重叠的写入保留 spill。
- BL 使调用者保存寄存器失效；被调用者保存寄存器按 ARM64 ABI 保留。
- `FirmwareKernelRegion.inspect(Data) throws -> Region` API 未变。`flow` 改为 internal，仅供相同模块测试直接覆盖数据流边界。

## 验证与限制

新增 `FirmwareKernelRegionTests`，覆盖常量、W 寄存器零扩展、MOVK、未知控制流、成对加载、SP writeback、移位算术、重叠 spill、调用者/被调用者保存寄存器和畸形 Mach-O。

历史 `region-green.json` 的实际退出码是 1，日志记录缺少 Capstone shift 字段等编译错误；文件名不能作为通过证据。`region-review-build.json` 记录沙箱无法写入 Swift 编译缓存。后续授权构建中 Region 与 Capstone 修改已通过编译，但整包测试分别被其他工作中的 `FirmwareTransaction` throwing 表达式以及旧测试调用已删除 API 阻断。最终结果以随后新增的验证记录为准。

识别器只支持已实现的有界数据流，不是任意 ARM64 程序的完整语义证明。它按标准调用 ABI 保留调用者栈中的 spill，不对被调用函数的任意副作用做跨过程分析。真实镜像参数识别仅证明候选共享区域数值，不证明 DSC 可加载、系统恢复、启动或应用行为。未知或歧义结果必须拒绝 kernel-only 更新。

`vendor/libcapstone-spm` 原先无未提交修改；此次新增的语义字段位于子模块工作区，需要与主仓库修改一起保存。`Sources/Capstone/Instruction.swift` SHA-256：`d3d6fa57f79c1c56bed08321fae8a64c479a340a2d761f322d9271452b9fa77a`。现有 evidence runner 的 sourceSHA256 不包含 vendor 文件，此处补充记录。

补充验证：`orchestration-verified.log` 中真实候选内核识别通过，五个区域单元测试中的 MOVK 用例失败。`region-movk-diagnostic.log` 显示 Capstone 对 `movk x2, #2, lsl #32` 返回 `writeback=true`，该字段也包含寄存器读改写。实现改为仅拒绝含内存操作数的 writeback，保留 MOVK 数据流支持及 SP pre/post-index 拒绝。

最终专项验证：`region-review-verified.json` 退出码 0；`region-review-verified.log` 记录五个 `FirmwareKernelRegionTests` 与真实候选内核测试全部通过，共 6 tests / 2 suites。真实候选返回 `base=0x180000000`、`size=0x180000000`，测试耗时 5.467 秒。此记录的 sourceSHA256 包含最终区域实现、测试和 Capstone vendor 语义字段。
