# T52 APIProxy 停止竞争：原因、修复与混合回归（2026-10-22）

APIProxy 混合测试中的非空响应已定位并修复。代理将“已停止”和“连接尝试达到上限”都表示为 `false`，调用方因此在停止竞争期间错误返回 HTTP 503。修复将两种拒绝原因在同一互斥区内区分：已停止直接结束本连接；真正达到上限继续返回 503。完整 APIProxy 13 项通过；原混合组合增加 2 项竞争/阶段回归后，每轮 110 项，连续 3 轮通过，均未将失败测试单独分组。本报告、对应源码、回归与证据构成本次 APIProxy 修复提交的范围。此处记录的是提交前本地验证结果，验证期间没有重建、安装或替换系统 Bundle，没有启动 VM 或修改 AMFI。

## 问题与最小复现

此前失败位置为 `APIProxyTests.testActiveConnectionLimitAndStopDuringConnect` 的停止后空响应断言，单项与 11 项套件曾独立通过。本轮保持原断言，只补充实际响应字节后，原混合组合再次失败，捕获 `HTTP/1.1 503 API unavailable`、`Content-Length: 0` 和 `Connection: close`。

单独运行原测试 12 个独立进程，其中 1 次同样失败。失败不要求先运行其他测试。进一步复用原测试的真实 loopback socket 路径，保存 100 轮停止竞争回归：建立 16 个客户端并发起有效请求，第 17 个无请求连接仍验证活动连接上限；随后停止代理，要求原客户端只收到 EOF/reset。另保存 10 轮对照，唯一阶段差异是在停止前等待全部 16 个客户端进入连接器。

在原实现上，100 轮产生 20 个非空 503 响应，来自 20 个迭代，失败时只有 14 或 15 个客户端进入连接器。10 轮阶段对照全部通过。该回归不依赖固件、VSOCK 设备或客户机程序。

## 原因

| 执行对象 | 顺序与结果 |
| --- | --- |
| 停止调用方 | `Clients.stop()` 持锁设置全局 `stopped=true` 并取得客户端快照，然后逐个执行 `Client.stop()` |
| 请求 worker | 已读完有效请求，但尚未取得连接尝试资格；此时自己的客户端可能仍未关闭 |
| 原准入逻辑 | `reserveAttempt()` 看到全局已停止，返回 `false`；同一个返回值也用于 `attempts >= 16` |
| 原调用方 | 将所有 `false` 都处理为容量耗尽并发送 503；个别仍可写入的客户端因此在关闭前读到响应 |

唯一标记的临时探针在拒绝分支记录到 `stopped=true、clientStopped=false`，与失败阶段一致。等待全部连接进入连接器后，不再经过这一准入分支，因此对照通过。该结果说明仅增加测试同步会避开已证实的生产竞争；本轮保留竞争断言并修复生产分支。

本轮检查的假设包括准入与逐客户端停止的竞争、测试阶段同步、前序测试资源生命周期。独立进程复现排除了“必须有前序混合测试”这一条件；源码、状态探针和反证确认了错误 503 的具体路径。本轮结论不扩展为所有描述符生命周期行为均无缺陷。

## 修改与反证

`Clients.reserveAttempt()` 返回 `.reserved`、`.stopped`、`.capacityReached`，判断和计数仍在原互斥区内完成。调用方在 `.stopped` 分支直接返回，通过现有 defer 关闭与释放连接；`.capacityReached` 保持原 503 响应。连接上限、未返回回调占用的尝试上限、令牌检查、外部 API 准入和超时均未调整。

原测试保留并提取共同步骤；新增 100 轮竞争回归与 10 轮阶段对照。失败说明记录迭代序号、停止前进入连接器的数量和实际响应。原容量测试继续断言真实上限返回 503，迟到回调释放和停机关闭检查保持。

修复后 APIProxy 13 项通过。随后仅把调用方改回“所有非 reserved 原因都发送 503”的旧策略，其余新枚举、计数、测试均保持，且没有诊断日志。100 轮再次产生 55 个错误 503 响应，命令退出 1；反证脚本在 finally 中恢复修复源码，并核验恢复前后摘要一致。最终生产源码已移除所有临时探针。

这次缺陷可以通过在返回值中保留拒绝原因来预防：停止和容量限制分别决定“直接关闭”和“返回错误”。现有 loopback 测试能够覆盖实际调用路径，未发现需要重构模块才能建立回归的限制。

## 验证命令与结果

```sh
swift test --skip FirmwareIntegrationTests --filter APIProxyTests
swift test --skip FirmwareIntegrationTests \
  --filter 'VPhoneAPIKitTests|GuestShutdownTests|APIProxyCLITests|ShutdownPolicyTests|VMWindowCloseTests|HostControlLifecycleTests|GuestWriteCoordinationTests'
```

第二条命令运行 3 轮；第 2、3 轮增加 `--skip-build`，使用第一轮的修复构建。每轮包含 XCTest 58 项及 Swift Testing 52 项，共 110 项，退出码均为 0。100 轮竞争和 10 轮对照是其中两个测试方法的内部迭代，不额外计入 110 项数量。单独 APIProxy 的 13 项与混合组合重叠，不相加。

| 实验设置 | 结果 | 证据 |
| --- | --- | --- |
| 原混合组合，补充失败消息 | 非空 503，退出 1 | mixed-diagnostic.log.gz |
| 原单项独立进程 12 次 | 1 次失败，11 次通过 | isolated-red-results.json、isolated-red-08.log.gz |
| 原策略，100 轮竞争与 10 轮对照 | 20 个迭代各出现一个错误 503；对照通过 | stop-race-red.log.gz |
| 无探针，仅恢复旧发送策略 | 55 个错误 503；退出 1，随后源码已恢复 | counterfactual-result.json、counterfactual-no-instrumentation.log.gz |
| 修复后完整 APIProxy | 13 项通过 | proxy-green.log.gz |
| 修复后原混合组合及新增回归 | 110 项 × 3 轮，全部通过 | mixed-green-results.json、mixed-green-1/2/3.log.gz |

所有证据及最终源码摘要见 [证据清单](evidence/T52-APIProxy-stop-race-20261022/manifest.json)。未运行全量 Swift/Python、真实 VM、系统 Bundle 安装或新的临时放行。本轮修复尚未进入已安装候选；先前默认 GUI 正常关机验收的工件和证据保持原样。
