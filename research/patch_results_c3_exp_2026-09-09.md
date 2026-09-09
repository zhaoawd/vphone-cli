# C3 EXP 内核迁移

日期：2026-09-09。使用 `kernelcache.research.vphone600`，沿用基础内核迁移记录中的样本和分析范围。

## 实现与验证

EXP 声明 `patchHvVmmRename` 必要步骤。原来的 Part A 或 Part B 任一发生修改即返回成功，改为 OID 唯一性/改名和全部已发现调用者改写均完成才返回成功。已改名 OID 和已改写调用者的既有幂等记录保留，全部原字节等于目标字节时返回 alreadyApplied。找不到调用者时不推断为不适用。

合成测试覆盖两部分完整、缺任一部分、重复 OID、完整幂等与方法级消融。原始 cloudOS 26.1 的 EXP 记录与最终 payload 比较、必要项判定均通过。方法定位与字节未改变。

原始 cloudOS 26.4 的独立 EXP 记录、payload 比较和必要项检查通过。base → JB → EXP 顺序组合（iOS 27 + Frida）共 132 条记录，记录和 payload 相等；组合必要集合因 JB 的 `patchVmMapProtect` 失败，不能标记为完整通过。详细输入哈希与复现命令见 [内核记录](patch_results_c3_kernel_2026-09-09.md)。
