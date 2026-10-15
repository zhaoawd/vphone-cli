# Task 8 Data 切片索引修改独立审查

日期：2026-10-14。审查者：acceptance_audit。审查范围：只读检查 FirmwareComponentReceipt.verifyEffect 源码差异、FirmwareComponentEffectIndexTests、命令清单及 RED/GREEN 日志。仅写本审查文档及对应 JSON；未独立运行测试，未操作 VM、挂载或 AMFI。

结论：未发现阻断问题。修复保留原有边界和逐字节效果检查，以 payload.startIndex 计算 PatchRecord.fileOffset 对应的集合索引。可使用本次审查对应源码准备第七版冻结工件。正式磁盘提交、恢复和启动仍需真实验收。

## 源码检查

与独立构建目录中此前源码比较，本次生产差异仅涉及通用字节记录分支的区间计算。devicetree 与 plist 投影分支保持。record.fileOffset 非负、patchedBytes 非空、fileOffset 不超过 payload.count、patchedBytes.count 不超过 payload.count - fileOffset 四项守卫保持。减法守卫先于 index 调用，负数、超出尾部、长度超界及 Int.max 偏移均不会进入区间访问。

Data 切片可以保留非零 startIndex。PatchRecord.fileOffset 表示 payload 相对偏移，旧 subdata(in:) 将其直接当作集合索引。新实现从 payload.startIndex 前进 fileOffset 得到 start，再前进 patchedBytes.count 得到 end；既有守卫保证两次索引位于 payload 的合法边界内。最后仍要求 payload[start..<end] 与 record.patchedBytes 完全相等；错误信息保持。未增加忽略失配或跳过记录的路径，未修改补丁算法、来源资格、声明归属或事务提交顺序。

## RED→GREEN 证据

red.log 和 red-repeat.log 均实际调用旧生产 verifyEffect。三个 payload 分别来自 Data.dropFirst、Img4tool IM4P 解码和 Img4tool IMG4 解码，startIndex 为 17/31/41。每个 payload 与原始 256 字节输入内容相等，相对偏移 128 处具有期望字节；三项均错误返回 required effect absent。该 RED 是运行时行为失败，不是编译失败。XCTest 的“0 tests”行不代表该 Swift Testing 回归通过。

green.log 记录：

- 合法用例 12 项：plain/slice/im4p/img4 四种包装 × 偏移 0、128、252，均通过；覆盖首部、中部及恰好到达末尾的非空记录。
- 拒绝用例 28 项：四种包装 × wrong-offset、different-bytes、negative、past-end、overrun、overflow、empty，均按抛错通过。

IM4P/IMG4 用例使用合成字节经项目实际 Img4tool 编码、解码 API 返回 payload；这证明真实 API 的 Data 索引语义，不等于真实固件或磁盘提交验收。

## 定向回归范围

task8-targeted-green.log 完成，Swift Testing 汇总 82 个测试、14 个 suite，无失败；该汇总包含以下 4 项 fixture 跳过，不能表述为 82 项均实际执行：

- installedDSCWithAtlasValidatesThroughProductionPath
- reproducedEXPKernelAcceptsInstalledDSC
- liveCandidateSwapAndReadonlyReadback
- actualCandidateRegionUsesSourceFlow

同轮 XCTest 内存父测试通过，直接辅助入口按设计跳过；capture/validate/publish/reverse 四个独立子操作均实际执行通过。非跳过的 receipt、publication、installed origin、kernel update/recovery、swap、CLI 与路由回归结果无失败。回归日志由实施者运行，审查者仅复核记录。

## 来源与限制

独立计算源码/测试/日志摘要，与 manifest.json 一致：

| 对象 | SHA-256 |
| --- | --- |
| FirmwareComponentReceipt.swift | `420344494a44d4e7db56f376d98540a55c578471fa724a8d40685471dcba2bbd` |
| FirmwareComponentEffectIndexTests.swift | `e5ffed66c996bf842bedd2d6a8188c4e05a0cb14dfb631738f269b00b31ea9c1` |
| red.log | `906cdd2193382025edc61fa50c747bd6ebde4e3ef2f3b339a84cd3b6297dff51` |
| red-repeat.log | `de86c72b101f958490486eebb10c0e91ab3e52236ac7122314340ba6cbbcb030` |
| green.log | `78d4e65d0a7e07d75a2ccc4c53c378eb609da5d9fc45b562af291271f3b4a05c` |
| task8-targeted-green.log | `a659f9568cee89c0a04f670348c02cefe682302af1001fc748bfc5d234e16abc` |

本次确认修复了非零 Data 索引导致的合法效果误拒绝。实际候选必须用重新构建并冻结的工件重试。真实发布后中断恢复、正式提交和启动不能由本测试替代。提交后 kernel-only 回退入口尚未实现，Task 8/T34 保持未完整验收。此前 SIGKILL 的原因未查明，本次索引修复不解释该信号。
