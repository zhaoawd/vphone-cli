# C3：26.4 内核补丁重新定位

范围：`kernelcache.research.vphone600`。保留 C3 和必要性规则；承接 [失败诊断与 reveal 过程](c3_acceptance_diagnosis_2026-09-09.md)。没有恢复已停用的 vm_map_protect COW mask 修改。

## 实现

EXC_GUARD 使用 Capstone 类型化操作数恢复 entitlement 所属函数与调用目标。保留 26.1 的中间调用路径，并识别 26.4 的 reason 6 包装函数和认证后的外部尾调用。两条路径汇总所有候选，必须唯一。目标需保存线程、code、subcode、fatal 参数，向线程相邻字段写入 code/subcode，写入 XNU 的 `(OS_REASON_GUARD=23, EXC_GUARD=12)` 常量对，并使用 `LDSET` 设置 AST bit `0x1000`。数据地址从 ADRP/LDR 解码恢复，不使用符号转储或固定结构偏移。

vm_map_protect 保留 26.1 主函数 gate；26.4 从主函数的 `ADRP + ADD + PACIA + STR` 恢复已认证并存入回调结构的函数指针。只在候选回调中接受掩码 6、entry bit 22、BIC/CMP/CCMP(eq)、前向分支、执行权限清除和回写共同成立的唯一 gate。只改写分支为同目标 B，不改 `mov #5` 或 COW WRITE 处理。

重复应用时保留并检查原有语义结构，允许入口已为 RET 或 gate 已为同目标 B，生成既有字节记录并返回 alreadyApplied。定位、组完整性失败仍为 failed。

## 原始样本断言

测试 `KernelGateDiagnosisTests` 通过输入 IM4P SHA-256 选择人工核实的期望地址；地址仅在测试中用于独立核对，不参与补丁器定位。

| 样本 | EXC_GUARD 目标 VA | vm_map_protect 分支 VA |
| --- | --- | --- |
| 26.1 / 23B85 | `0xfffffe0007b53fcc` | `0xfffffe0007bc424c` |
| 26.4 / 23E5207q | `0xfffffe0008d595c8` | `0xfffffe0008dcaea0` |

每项测试要求首次匹配、一条 4 字节记录、完整输出只包含该记录的修改；第二次执行要求 alreadyApplied 且字节不变；把实际输入中的 AST LDSET 或 WRITE|EXECUTE mask 装载替换为 NOP 后必须失败且零写入。NOP 来自项目指令助手。

初次 26.4 两项通过，耗时 7.576 秒。增加地址/唯一写入/幂等/负例断言后，26.4 两项通过（22.845 秒）、26.1 两项通过（25.221 秒）。最终版本增加异常类型常量对校验并统一全部候选的唯一性判定后，26.4 专项通过（25.779 秒）、26.1 专项通过（25.404 秒）。

尚未进行修正后 VM 引导和调试器实机测试，不能把静态写入验证表述为运行验收。less 单独记录。

完整 26.4 内核矩阵：regular 28、dev 29、JB 26.x 84、JB 27.x 96、JB 27.x + Frida 100 条记录，必要方法均通过；旧调度与结构化调度记录和 payload 均相等。base → JB → EXP（iOS 27 + Frida）顺序组合为 133 条记录，也通过完整性及字节一致性检查。该轮共 5 项测试通过，耗时 277.565 秒；最终候选唯一性收紧后的顺序组合已重跑通过，仍为 133 条记录，耗时 145.933 秒。
