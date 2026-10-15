# 限定 AMFI driver 清理设计独立审查

日期：2026-10-14。审查者：acceptance_audit。仅阅读临时 driver、实际 amfidont runtime、Xcode LLDB Python API 文档及保存证据；未 import LLDB、attach、运行 VM、发送信号或暂停进程。依用户限定只读审查，本轮不执行真实复现或清理验证。

最新结论：补充 cleanup helper 和第二版 mock 后，未发现阻断问题。该临时 driver 可作为本次限定第四版单 exec 的成功路径方案；仍不证明所有路径可中断或真实 detach 已成功。实际运行须保留后文记录要求及缺失 hook 时的范围限制。

## 已有问题及授权范围

旧 driver 使用 SetAsync(False)，主线程调用 runtime.bypass_loop；该 loop 每轮同步 Continue。SIGINT 的 Python 异常可能等到原生调用返回才处理。runtime 的 validate/isApple hook 同样依赖同步 StepOutOfFrame 完成后才读取返回寄存器。只将 SetAsync 改为 true 会破坏这项时序，不能作为最小修复。

原 finally 还存在两个独立问题：IsValid 不代表 inferior 仍存活；Detach 失败抛错会跳过后续 Destroy。最新 amfi-cleanup-resolution.json 已记录旧 amfid 88460、driver 89299/debugserver 89316 均消失，未执行获准的旧 PID 暂停/恢复，新服务 PID 为 35998。旧 PID 的精确暂停授权不能用于新 PID；旧清理缺口不能据此转化为对当前服务的外部暂停授权。

## 不接受原 loop 直接移入 worker 的方案

runtime.bypass_loop 没有取消条件。主线程 Stop 使同步 Continue 返回后，worker 仍可能查找线程、执行 hook、再次 Continue，与主线程 DeleteAllBreakpoints/Detach 竞争。daemon 标记不会使其自动退出，join 也无法终止该 loop。未证明 LLDB API 并发调用安全之前，不能接受该方案，也不能以 mock 单独替代实际原生线程安全证据。

异步状态机可以作为较大后续修改，但必须同时改 Continue 和 StepOut 完成等待、表达式超时、停止事件识别与清理串行化；当前不建议扩大生产 runtime 修改。

## 一次 exec 后自然 detach 的范围

新 scoped-amfi-v4-once.py 保持原第四版 BINARY/SHA/CDHash/runtime SHA；paths=[]、allow_all=false，原 validate/isApple 两种 hook 均保留。它直接调用 hook，不调用读取或重载持久配置的 bypass_loop。删除 helper --help 线程，READY 后由正式限定副本 launch 触发，避免 --help 消耗单次流程。没有 Stop、外部 kill、重 attach 或服务重载。

run_one_exec 使用同步原 hook，捕获其实际 dump_validator 结果。只有 CDHash 匹配、hook 返回后 inferior 为 stopped、返回寄存器读回为 1，才将该种 hook 计入 seen；两种 hook 均计入后不再 Continue。在已有 stopped 状态下 DeleteAllBreakpoints → Detach(False)；detach 成功后 Destroy。Xcode 本地 Python API 明确 DeleteAllBreakpoints 返回 bool，Detach 返回 SBError，当前代码按这两种返回类型分别处理。

该方案可减少成功路径的附加持续时间，不增加新的暂停请求。旧 --help 日志证明同一第四版 CDHash 两种 hook 曾实际执行，但不能保证下一次 launch 恰好只需两次 hook，或保证此后不再发生代码验证。自然 detach 后若启动仍失败，应报告失败，不得自动重新附加、扩大 allowlist 或暂停新 PID。

这是成功路径方案，不是全路径可中断保证。若某种 hook 不出现，同步 Continue 仍可能等待；若 cleanup 时仍为 running，当前代码明确拒绝新的暂停并保留未清理状态。不得报告已保证最终清理。

## 当前 mock 覆盖及使用前条件

首版 5 个纯 mock 只调用 run_one_exec，覆盖两种顺序、非匹配 CDHash、不正确返回值、非 stopped 状态和 dump_validator 恢复。未 import LLDB、未 attach，适合验证有限的分支及 allowlist 参数；没有覆盖 main/finally 清理。

首次审查提出在使用前补齐以下纯 mock；后续结果见补充审查：

- stopped 下 DeleteAllBreakpoints 返回 true/false；Detach 成功/失败；失败不误报完成。
- running 状态拒绝且不调用 Stop/信号；exited/detached 状态不再 Stop/Detach。
- Destroy 仅在安全的已 detach/已终止状态执行，清理顺序和 bool/SBError 用法符合本地 API。
- 重复匹配 hook 不提前完成；缺失一种 hook不被标记为成功；异常恢复临时 dump wrapper。

原 hooks 的 StepOut 和寄存器处理继续依赖既有 runtime；本次 mock 不证明原生 LLDB StepOut/Detach 的实际成功。未来 live 结果必须保存两个实际 CDHash 命中、返回值、最后停态、删除/Detach 返回值、driver/debugserver 最终状态。任何未清理结果保留为未完成。

首版 driver SHA：`98ff09f602bacc5bff48c8375e7c5fc4300f1b34f40a057165d59ee14b0f9506`。首版 mock SHA：`e1e61e28bb8940439b75869ceb9fb62965482867f452356b33edb92bcf3957c1`。结果 SHA：`93e5bd9d4648021c4a929f49c36f996bf26545548c32588580f96a732577241d`。

以上结论是静态审查与使用前验证条件，不是对任何扩大系统操作的批准，也不将旧 PID 暂停授权迁移给新 PID。生产 PAYP 修复的冻结审查独立记录，不因本 driver 尚待验证而扩大修改范围。

## cleanup helper 和 mock 第二版补充审查

最终 driver 抽出 cleanup_existing_stop。仅 stopped 状态尝试删除断点；删除返回 false 或抛异常仍继续 Detach(False)，避免删除失败直接跳过 detach。只有 Detach 成功或状态明确为 exited/detached 时 safe_destroy=true；main 仅在该标记为 true 时 Destroy。Detach 失败/异常、running、invalid 或 attached 状态无法读取时保留失败结果，不发起 Stop，不在状态不明时 Destroy，不误报 CLEANUP_DONE。

第二版纯 mock 日志/JSON 报告 7 项 loop 场景和 8 项 cleanup 场景通过。loop 增加缺失 hook、同种 hook 重复但缺另一种的拒绝场景；缺失场景由 mock 的输入结束异常模拟，不证明真实同步 Continue 会自行超时。cleanup 覆盖删除 true/false/异常、detach 成功/错误、running/invalid 拒绝，以及 exited/detached 的安全 Destroy 条件。mock 没有 Stop 方法；代码分支也没有 Stop、kill、信号或服务操作。Destroy 在 mock 中为调用记录，main 的实际 safe_destroy 分支另经源码检查，两者一致。

本地 LLDB 文档确认 DeleteAllBreakpoints→bool、Detach(bool)→SBError、Continue→SBError，最终代码返回类型处理正确。原 runtime 文件及两个 hook 未改，固定第四版许可参数保持；没有扩大到第八版 VM 或新 amfid 的外部暂停。未发现新增清理竞争，原 worker 并发方案继续不接受。

最终审查摘要：

- scoped-amfi-v4-once.py：`f99f3c92d6ef68d3cf0f18d295622603ed72991950da9c39fdecd8a0da37c219`
- scoped-amfi-v4-once-mock.py：`31955d363e073eee138cdeb8120cb4aec7634df43c78694abb6fab90011e8b35`
- scoped-amfi-v4-once-mock-v2.json：`e8fd08accc8502e6e150178650e4347d1d4c62045ab2ac181aef007f18e98fa7`

审查者未执行上述 mock。真实挂钩及 detach 结果仍需本次实际日志；如果新 exec 未出现两项匹配 hook，或之后代码验证失败，只能报告该结果，不能添加外部暂停或自动重 attach 兜底。
