# Task 8 磁盘扫描内存修改独立审查

日期：2026-10-14。审查者：acceptance_audit。范围：只读检查生产代码、回归测试和已有日志；仅写本审查文档及对应 JSON。未运行测试、真实 VM、挂载或 AMFI 操作。

最新结论：capture/validate/publish/reverse 四个循环的每轮 autoreleasepool 修改未发现阻断问题。现有 RED→GREEN 证据支持这四条路径的块读取暂存内存增长问题已修复。定向行为回归日志已经通过，可以冻结本次审查对应源码。旧真实进程 SIGKILL 的原因未查明，不能据此认定为 OOM。真实磁盘更新仍须使用包含修复的冻结工件重新验收。

以下前四节记录首次 capture/validate 审查；publish/reverse 的补充审查及最新源码摘要见文末。

## 实现检查

将当前 FirmwareKernelDisk.swift 与第五版独立构建目录中的源码比较，差异仅为 capture 和 validate 的逐轮 autoreleasepool。capture 的两份 4 KiB 读取、长度比较、EOF、差异偏移收集和最终完整摘要核验保持原逻辑。validate 的三份读取、pending 前缀检查、已中断块关系、offset/change 更新及 EOF 检查保持原逻辑。异常仍从 autoreleasepool 传播，已有 FileHandle defer 清理仍有效。循环外只保留差异偏移及标量状态。

FirmwareGeneration.readFile 已使用逐轮 autoreleasepool，因此本次修改与项目已有流式摘要实现一致。capture 的 offsets 仍随差异块数增长；本结论只涉及块读取暂存数据，不宣称整个操作对任意差异分布具有常量内存。

## 回归证据

FirmwareKernelDiskMemoryTests 在独立 xctest 子进程内执行真实 helper。输入为 64 MiB + 3 字节，候选仅最后一字节不同。capture 同时检查完整大小及唯一末块偏移，覆盖末块不足 4 KiB 的路径；validate 使用预先构建的恢复关系，避免将 capture 的内存增长计入 validate。准备过程在测量前独立排空 autoreleasepool。

| 操作 | 实验设置 | RED 峰值 RSS 增量（字节） | GREEN 峰值 RSS 增量（字节） | 结果 |
| --- | --- | ---: | ---: | --- |
| capture | 67,108,867 字节；阈值 67,108,864 字节 | 137,740,288 | 1,687,552 | RED 断言失败，GREEN 通过 |
| validate | 同上 | 204,144,640 | 65,536 | RED 断言失败，GREEN 通过 |

数值来自 red-repeat-cached.log 和 green.log。red.log 的 capture 增量同为 137,740,288 字节，validate 为 204,161,024 字节。GREEN 日志中父测试成功，两个子测试实际执行成功；直接运行 testScanChild 时的 skip 属于辅助入口设计，不能将 Swift Testing 的“0 tests”行当作本回归结果。

Darwin ru_maxrss 是进程峰值 RSS，测试比较操作前后的高水位；独立子进程降低历史高水位遮蔽回归的风险。阈值与观察值有明显间隔，能够检出本次复现的增长。该单尺寸试验不能直接证明 64 GiB 输入下的峰值，也不代替真实 VM 验收。

## 范围限制及后续检查

- 本次审查未独立重跑日志命令。现有定向行为测试结果由实施者继续补充，特别是 pending、发布中断、反向恢复和外部修改拒绝路径。
- 首次审查版本尚未覆盖 publish/reverse。其后新增有效 RED、逐轮释放及 GREEN，详见补充审查。
- 应保留失败日志及明确的冻结工件摘要。修复后的离线工具与此前第五版工件不是同一组字节，必须分别记录来源；VM 启动仍限已授权第四版。
- 提交后 kernel-only 回退入口尚未实现，本次内存回归不改变 Task 8/T34 未完整验收的状态。

## 审查输入摘要

- FirmwareKernelDisk.swift：`67a22064c1a2e18c6b38530263d15a2452c40fc0bfd5c8f1248216ce66f5dc20`
- FirmwareKernelDiskMemoryTests.swift：`37230e3992881462cffb432ec74c45dab07634bddfd75a25ddfcad42ec5944a4`
- red-repeat-cached.log：`70d1f4f54cf4373ed59b379842e76903a83600a6ebee9ab8046c59b745dbce0d`
- green.log：`c8cec2b260deebbb130cfc4eb2d661ff6cdb6f075de9f8118e955e8c840eb871`

## publish/reverse 补充审查

当前生产源码与第五版冻结源码的完整差异仍限于四个循环的 autoreleasepool。publish 的 pending=true→save→writeBlock（pwrite/fsync）→afterWrite→cursor增加→pending=false→save 顺序保持。reverse 的已知字节检查→pending=true→save→writeBlock→afterWrite→cursor减少→pending=false→save 顺序保持。反向恢复前的 validate、pending 块保存、方向切换以及两条路径末尾的完整摘要核验均未改变。pool 内抛错仍传播至调用方，持久游标没有提前更新，未发现恢复语义变化。

新增测试使用 16 MiB + 3 字节、每个字节均不同的候选，共 4,097 个差异块。reverse 在同一磁盘 inode 上原地写入候选并设置完整 forward cursor，恢复关系有效。save 和 afterWrite 均为空操作，使测量范围不包含生产 journal 持久化；测试仍执行真实 validate、块读取、pwrite/fsync 和末尾完整摘要核验。短末块被实际发布及恢复，成功后检查 cursor 终值。

| 操作 | 实验设置 | RED 峰值 RSS 增量（字节） | GREEN 峰值 RSS 增量（字节） | 结果 |
| --- | --- | ---: | ---: | --- |
| publish | 16,777,219 字节全差异；阈值 16,777,216 字节 | 42,106,880 | 196,608 | RED 内存断言失败，GREEN 通过 |
| reverse | 同上 | 59,129,856 | 196,608 | RED 内存断言失败，GREEN 通过 |

有效 RED 来源为 publication-red-valid-fixture.log；早期编译失败或恢复关系错误日志不作为内存回归证据。GREEN 来源为 operations-green.log，该轮 capture/validate 增量分别为 1,703,936/65,536 字节，四个子操作均通过。

上述证据直接支持 helper 在空持久化回调下存在且修复了暂存内存增长。生产 journal 回调也处于新 pool 内，但其实际内存峰值未由此试验单独量化。内存测试未覆盖故障注入；该行为范围由现有 FirmwareKernelUpdateTests 等定向回归提供证据。

后续读取 task8-targeted-green.log 确认测试完成：XCTest 内存父测试成功（2 个测试、1 个辅助入口 skip、0 failures，capture/validate/publish/reverse 四个独立子操作均实际执行）。Swift Testing 汇总为 53 个测试、11 个 suite、无失败；其中 4 项 fixture 测试跳过：installedDSCWithAtlasValidatesThroughProductionPath、reproducedEXPKernelAcceptsInstalledDSC、liveCandidateSwapAndReadonlyReadback、actualCandidateRegionUsesSourceFlow。不能将该汇总写为 53 项均实际执行。日志包含 FirmwareKernelUpdateTests、FirmwareKernelOrchestrationTests、FirmwareInstalledOriginTests、FirmwareInstalledReadbackTests、KernelcacheSwapTests、CLI 及路由测试的非跳过回归结果。四项 fixture 跳过不影响本次内存修改的源码冻结结论，但本轮不新增对应真实输入覆盖；该日志不是新增真实挂载或 VM 验收证据。测试由实施者运行，审查者只读复核日志。该轮 publish RSS 增量 1,261,568 字节，仍低于阈值；其余三项与 operations-green.log 的量级一致。

最新审查输入摘要：

- FirmwareKernelDisk.swift：`d166b6493d976b171e74eca4fe73d578f3256017f1ea20eab4256fb93e46db62`
- FirmwareKernelDiskMemoryTests.swift：`8b313330b3e7a8672ce1c05942f7f4f1c9a661e813b1cc2aee44d23f0047f023`
- publication-red-valid-fixture.log：`6ff7c4a273062653ec68249c5e776d3615cccfffffabcf88cff708a79711bea0`
- operations-green.log：`e1ad8c824594932517b49f4d561b73e0df3c264176c8fe180240ac91511f0d0e`
- task8-targeted-green.log：`691febac06423ea9c1b19b51cba3458907b64183acc97b0afc04d0f9e12390c8`
