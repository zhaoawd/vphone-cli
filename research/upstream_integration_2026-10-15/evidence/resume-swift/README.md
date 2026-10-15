# T30 恢复执行证据

所有 SwiftPM 命令使用仓库 `.build/test-module-cache`、`.build/test-cache`，`--disable-sandbox`，经授权在宿主执行；未启动 VM。常规定向命令格式：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache" \
SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache" \
swift test --disable-sandbox --cache-path .build/test-cache --filter '<以下筛选>'
```

| 文件 | 筛选与结果 |
| --- | --- |
| focused-baseline.log | `APIHTTPTests\|APIWebSocketTests\|deferredChildIsNotSignalledAndTheForcedExitWaitsForIt\|twoConnectionsReceiveOnlyTheirOwnPersistedOutputBeforeReply\|escapedPipeWriterTimesOutWithoutLosingTailAndReopensCommandGate`；修改前 18 项通过 |
| socket-poll-red.log | `fixtureRetainsOnTimeMessageWhenObserverResumesAfterDeadline\|fixtureRejectsMessageActuallySentAfterDeadline`；2 项，1 issue；按时发送但晚观察的正例失败 |
| socket-poll-green.log | `APIWebSocketTests`；12 项通过 |
| child-observer-red-native.log | `deferredChildIsNotSignalledAndTheForcedExitWaitsForIt\|NativeTransferTests`；16 项，1 issue；Child 人为晚观察失败，Native 15 项通过 |
| http-poll-red-child-green.log | `fixtureRetainsTimelyServerWhenObserverResumesLate\|fixtureRejectsServerThatActuallyStartsAfterDeadline\|deferredChildIsNotSignalledAndTheForcedExitWaitsForIt`；3 项，1 issue；HTTP 正例失败，负例和 Child 双参数通过 |
| readiness-green.log | `APIHTTPTests\|APIWebSocketTests\|deferredChildIsNotSignalledAndTheForcedExitWaitsForIt`；20 项通过；随后补了 HTTP 负例诊断断言和失败清理 |
| launchpad-export-red.log | `cancellingExportPreservesCommittedOrConcurrentOutput`；1 项双参数，2 issues；并行 T60 任务的请求，修复由该任务实施 |
| final-focused.log | `NativeTransferTests\|EditLibraryTests\|ExportOutputTests\|APIHTTPTests\|APIWebSocketTests\|deferredChildIsNotSignalledAndTheForcedExitWaitsForIt\|twoConnectionsReceiveOnlyTheirOwnPersistedOutputBeforeReply\|escapedPipeWriterTimesOutWithoutLosingTailAndReopensCommandGate`；54 项、8 suites 通过，21.266 秒；最终源码 |
| runner-tests.log | `.venv/bin/python3 -B -m unittest discover -s tests -p test_test_runner.py`；6 项通过 |
| standard-final.log | `make test_swift`；完整两组及后续检查，最终结果见下方 |

`source-manifest.json` 是标准执行开始时相关源码的 SHA-256。前一轮标准失败原始日志位于相邻 `T30-swift-followup/standard-complete.log`：常规 Swift Testing 1514 项、14 issues，详见独立 T30 报告。

第一轮标准：`standard-final.log` 自然退出 2；XCTest 321 项、跳 7、0 失败；常规 Swift Testing 1507 项、235 suites、140.742 秒、1 issue（T60 新增末次进度回调导致进度回落）。随后 `--skip-build --filter LATENCY_TESTS` 的 `latency-green.log`：26 项、10 suites、8.294 秒全部通过。旧 `source-manifest.json` 已重命名为 `standard-first-source-manifest.json`，不代表后续 T60 修复版本。

最终结果：`export-progress-green.log` 的 BundleOpsTests/NativeTransferTests 41 项通过后，`standard-complete.log` 对应 `make test_swift` 自然退出 **0**。XCTest 321 项、跳过 7 项、0 失败；常规 Swift Testing 1507 项、235 suites、146.340 秒；时限组 26 项、10 suites、10.990 秒；两组均无 issues。tar pipe 内存、文件摘要内存、guest 组件宿主检查均由该入口顺序执行并通过。

`standard-result.json` 保存结构化结果。`source-manifest.json` 是最终版本相关源码，执行后摘要全部匹配；`archive-manifest.json` 保存各日志原文及 gzip 副本摘要。最终结论以 `standard-complete.log` 为准，保留的 `standard-final.log` 是进度回归修复前的失败。
