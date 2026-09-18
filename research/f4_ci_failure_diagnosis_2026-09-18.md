# F4-D：远端 `checks` workflow 三项 Swift 测试失败诊断（2026-09-18）

诊断对象：GitHub Actions `checks` workflow 最新失败运行 `35290927966`（提交 `2011bc7`）报告的 3 个 issue。

## 0. 环境与基线

| 项目 | 值 |
| --- | --- |
| 工作树 | `/Users/kolar/github/vphone-cli/.claude/worktrees/agent-af52f8572399c0da6` |
| 基线提交 | `7de013f`（`codex/autophone-location-multivm-integration` HEAD） |
| 主机 | macOS 26.5（25F71），`hw.ncpu` = 15（perflevel0 = 5，perflevel1 = 10） |
| 工具链 | Apple Swift 6.3.3（swiftlang-6.3.3.1.3），swift-driver 1.148.6 |
| CI runner | `macos-26`（workflow `.github/workflows/checks.yml`） |

工作树创建时处于 `06370de`，该提交不包含 `CreateLiveStagesTests.swift` 与 `DiagnosticsTests.swift`。已 `git reset --hard 7de013f` 并 `git submodule update --init --recursive`，随后执行 `make setup_venv`。

诊断结束后已执行 `git checkout -- .` 并删除生成文件，工作树 `git status --short` 为空，HEAD 为 `7de013f`。

## 1. 本机 `make test` 结果

### 第一次运行：环境前置缺失导致的失败（非 CI 失败项）

首次 `make test` 在 Swift 阶段编译失败：

```
sources/vphone-cli/VPhoneDoctorCLI.swift:53:66: error: cannot find 'VPhoneBuildInfo' in scope
sources/vphone-cli/VPhoneFWCLI.swift:199:26: error: cannot find 'VPhoneBuildInfo' in scope
error: fatalError
make: *** [test] Error 1
```

原因：`sources/vphone-cli/VPhoneBuildInfo.swift` 在 `.gitignore:326` 中被忽略，由 `scripts/build.sh:38-39` 或 `Makefile:257-258` 生成；`make test` 不生成该文件。CI 在 `Record toolchain and dependency identity` 步骤中显式生成它，因此 CI 不受此影响。本机按相同方式生成该文件后继续诊断。

此项属于本机执行前置条件，与 CI 的三项失败无关。

### 第二次运行：完整通过

`make test`（Python 3.14 来自项目 `.venv`）：

| 阶段 | 结果 | 耗时 |
| --- | --- | --- |
| Python `unittest` | `Ran 344 tests in 66.859s` / `OK` | 66.9 s |
| Swift XCTest | `Executed 144 tests, with 3 tests skipped and 0 failures (0 unexpected)` | 7.56 s |
| Swift Testing | `✔ Test run with 468 tests in 64 suites passed after 11.472 seconds.` | 11.5 s |

CI 失败运行在 `2011bc7` 上报告 325 个 Python 测试、462 个 Swift Testing 测试 / 63 个 suite；本机基线 `7de013f` 更新，数量分别为 344 与 468 / 64。差异来自 `2011bc7..7de013f` 之间新增的测试，不影响本次诊断的三项。

结论：三项失败在本机单次 `make test` 中均未复现。

## 2. 逐项诊断

复跑口径：

- **隔离复跑**：`swift test --disable-sandbox --cache-path .build/test-cache --filter <name>`。
- **整套复跑**：`python3 scripts/run_tests.py swift`，等价于 `swift test --disable-sandbox --skip FirmwareIntegrationTests`。
- **加载复跑**：整套或隔离复跑的同时运行 24 或 60 个 CPU 忙循环进程，用于模拟核数受限的 runner。

整套复跑合计 11 次（`make test` 内 1 次 + 无负载 5 次 + 24 忙循环负载 5 次）。

### 2.1 `SystemLocationControllerTests.testWatchdogHoldsLastAcceptedCoordinate`

**CI 原文**

```
tests/VPhoneCoreTests/SystemLocationControllerTests.swift:1117: error: -[VPhoneCoreTests.SystemLocationControllerTests testWatchdogHoldsLastAcceptedCoordinate] : XCTAssertGreaterThanOrEqual failed: ("1") is less than ("2")
Swift/ContiguousArrayBuffer.swift:692: Fatal error: Index out of range
... xctest ... exited with unexpected signal code 5
```

**复跑结果**

| 方式 | 次数 | 结果 |
| --- | --- | --- |
| 隔离复跑 | 5 | 5 次通过，单次耗时 0.044 s（`Test Case ... passed (0.044 seconds)`） |
| 隔离 + 60 忙循环 | 8 | 8 次通过，单次耗时 0.042–0.045 s |
| 整套复跑 | 11 | 11 次未出现该失败 |

本机未复现。

**原因判定：测试缺陷（断言依赖执行速度）**

证据（`tests/VPhoneCoreTests/SystemLocationControllerTests.swift:1107-1123`）：

```swift
1110:        let started = try await controller.startStream(
1111:            owner: "route-1", watchdogSeconds: 0.01)
1113:        _ = try await controller.push(generation: generation, fix: fix(0))
1115:        try await Task.sleep(for: .milliseconds(40))
1117:        XCTAssertGreaterThanOrEqual(guest.deliveries.count, 2)
1119:        XCTAssertEqual(guest.deliveries[1].fix.speed, 0)
```

`sources/VPhoneCore/VPhoneSystemLocationController.swift:600` 处 `push` 结尾调用 `scheduleWatchdog(seconds: streamWatchdogSeconds)` 重新装载看门狗；`scheduleWatchdog`（同文件 1449-1453）以 `Task { @MainActor }` + `Task.sleep(for: .seconds(seconds))` 实现。测试在 `push` 返回后固定等待 40 ms，期间看门狗需完成 10 ms 休眠、`MainActor` 调度、`refreshHoldingHeartbeat` 与一次投递。整个断言的成立条件是"上述工作在 40 ms 内完成"，测试中没有任何同步机制保证这一点。本机隔离执行整例耗时 0.042–0.045 s，与 40 ms 睡眠相比余量约 2–5 ms。

`Index out of range` 的归属：属于第 1117 行断言失败后的连带崩溃，不是独立问题。`XCTAssertGreaterThanOrEqual` 失败后不终止用例，执行继续到第 1119 行 `guest.deliveries[1]`，而 `deliveries.count == 1`。

受控实验（已验证）：将第 1111 行 `watchdogSeconds: 0.01` 临时改为 `5.0`，使看门狗必然无法在 40 ms 内触发，单独运行该用例输出：

```
SystemLocationControllerTests.swift:1117: error: ... XCTAssertGreaterThanOrEqual failed: ("1") is less than ("2")
Swift/ContiguousArrayBuffer.swift:692: Fatal error: Index out of range
error: Process '.../xctest ...' exited with unexpected signal code 5
```

与 CI 原文逐行一致，包括 `signal code 5`。

附带影响：该崩溃使 xctest 进程终止，同一进程内其余 XCTest 用例不再执行。

CI 上 40 ms 未满足的具体成因未在本机复现，判定为**待验证假设**：CI runner 的可用核数与负载低于本机，`Task.sleep` 到期后的 `MainActor` 调度延迟超过了剩余余量。

### 2.2 `CreateLiveStagesTests.verifierWaitsForARealBundleLockHolderToRelease`

**CI 原文**

```
CreateLiveStagesTests.swift:286:9 — 期望 .rejected("bundle lock still held 10s after the verification boot")，实际未被拒绝
```

（CI 报告的是该期望失败，即 `verify` 返回了 `.rejected("bundle lock still held 10s after the verification boot")` 而非通过。）

**复跑结果**

| 方式 | 次数 | 结果 |
| --- | --- | --- |
| 隔离复跑 | 5 | 5 次通过，单次 0.536–0.561 s |
| 整套复跑 | 11 | 11 次未出现该失败 |

本机未复现。

**原因判定：测试缺陷（依赖全局并发队列的调度时机）**

证据（`tests/VPhoneCLITests/CreateLiveStagesTests.swift:274-287`）：

```swift
284:        stages.lockReleaseTimeout = 10
285:        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { holder.lock = nil }
286:        #expect(isVerified(stages.verify(.verification, context: w.context(), evidence: ["boot_analysis": "prompt_detected"])))
```

被测实现 `sources/vphone-cli/VPhoneCreateLiveStages.swift:226-233`：

```swift
    func waitForLockRelease(_ bundleURL: URL) -> Bool {
        let deadline = Date().addingTimeInterval(lockReleaseTimeout)
        while lockHeld(bundleURL) {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: lockPollInterval)
        }
        return true
    }
```

拒绝消息由 `lockStillHeld` 与 `seconds(_:)`（同文件 235-241）拼成，`lockReleaseTimeout = 10` 时正是 `bundle lock still held 10s`。因此 CI 的失败文本表示：第 285 行排入 `DispatchQueue.global()` 的释放块在 10 秒内没有执行。

`DispatchQueue.global()` 是非 overcommit 的并发队列，宽度受活动核数限制。仓库中已有同类记录：`tests/VPhoneCoreTests/DiagnosticsTests.swift:679` 的注释为 `// A dedicated thread: the global queue can be saturated by parallel tests.`，该处正是为规避同一问题改用独立线程。第 2.3 项在本机取得了同一原语被延迟 3.8–4.5 s 的直接观测。

判定：测试缺陷，测试自身把"释放锁"这一必须发生的动作交给可能被饱和的全局队列。**待验证假设**：CI 上该块被延迟超过 10 秒；本机未直接观测到 10 秒级延迟，只观测到同一原语的秒级延迟（见 2.3）。

### 2.3 `DiagnosticsTests.boundedRunnerTimesOutAndClosesStdin`

**CI 原文**

```
DiagnosticsTests.swift:699-700 — timedOut 为 false（期望 true），耗时 5.079 秒超过断言上限 4 秒
```

**复跑结果**

| 方式 | 次数 | 结果 |
| --- | --- | --- |
| 隔离复跑 | 5 | 5 次通过，单次 0.204–0.218 s |
| 整套复跑（无负载） | 5 | 4 次通过，1 次失败 |
| 整套复跑（24 忙循环） | 5 | 4 次通过，1 次失败 |
| 饱和全局队列的定向探针 | 1 | 失败，与 CI 数值一致 |

本机复现，间歇失败，整套复跑 11 次中失败 2 次。失败原文：

```
✘ Test boundedRunnerTimesOutAndClosesStdin() recorded an issue at DiagnosticsTests.swift:700:9: Expectation failed: (Date().timeIntervalSince(start) → 4.0451929569244385) < (4 → 4.0)
✘ Test boundedRunnerTimesOutAndClosesStdin() recorded an issue at DiagnosticsTests.swift:700:9: Expectation failed: (Date().timeIntervalSince(start) → 4.710264086723328) < (4 → 4.0)
```

这两次 `slow.timedOut` 仍为 true，只有耗时断言失败；CI 那次 `timedOut` 也为 false，耗时 5.079 s。

**原因判定：产品缺陷**

证据（`sources/VPhoneCore/VPhoneProcessRunner.swift:89-97`）：

```swift
        let expired = DeadlineFlag()
        if let timeout {
            let target = process
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard target.isRunning else { return }
                expired.set()
                target.terminate()
            }
        }
        process.waitUntilExit()
```

超时的唯一执行路径是排入 `DispatchQueue.global()` 的一个块。该队列被占满时该块延后执行：延后但仍在子进程存活期内，则进程被迟终止（本机观测 4.045 s、4.710 s，超过 4 秒断言上限）；延后到子进程自行退出之后，则 `target.isRunning` 为 false，函数直接返回，`expired` 从未置位，`timedOut` 为 false（CI 观测 5.079 s，与 `/bin/sleep 5` 自然退出一致）。

定向复现实验（已验证）：临时新增一个 Swift Testing 用例，先向 `DispatchQueue.global()` 排入 512 个阻塞在信号量上的块，再以 `timeout: 0.2` 调用 `runCapturing(/bin/sleep, ["5"])`：

```
STARVATION_PROBE timedOut=false elapsed=5.01180899143219
✘ Expectation failed: (slow → VPhoneProcessResult(exitCode: 0, stdout: "", stderr: "", timedOut: false)).timedOut → false
✘ Expectation failed: (elapsed → 5.01180899143219) < (4 → 4.0)
```

与 CI 的 `timedOut = false`、5.079 s 一致，机制确认。

因此本项不是断言写得过紧的问题：`#expect(slow.timedOut)` 是对 `runCapturing` 超时语义的正确要求，实现无法在全局队列拥塞时兑现该语义。该实现同时用于 `sources/vphone-cli/VPhoneCreateLiveStages.swift` 中的 `recoveryReachable`、`attachedImages` 等探测路径，超时失效不限于测试场景。

**2026-09-18 修正**：上一句关于影响范围的判断有误。复核 `sources/` 下全部 `runCapturing` 调用点，`VPhoneCreateLiveStages.swift` 第 299、303、308 行的三处调用**均未传 `timeout` 参数**，不进入超时分支，因此不受该缺陷影响。`sources/` 下传 `timeout` 的调用点只有 `sources/VPhoneCore/VPhoneDiagnosticChecks.swift` 第 93、111、117 行，均在 `vphone-cli doctor` 的顺序检查中。该缺陷的实际影响范围是 `doctor` 的外部命令探测与测试，不是创建流程的探测路径。

补充观测：本机同一次整套运行中 512 阻塞块之外的常规并行负载已足以把该块延迟 3.8–4.5 秒，说明拥塞在正常测试并行度下即可发生。

## 3. 建议改法与验证结果

以下三处改动均已在本机实际应用并验证，随后已全部撤销，未提交。

### 3.1 第 1 项：轮询代替固定睡眠，并阻断越界访问

```diff
--- a/tests/VPhoneCoreTests/SystemLocationControllerTests.swift
+++ b/tests/VPhoneCoreTests/SystemLocationControllerTests.swift
@@ -1112,9 +1112,13 @@ final class SystemLocationControllerTests: XCTestCase {
         let generation = try XCTUnwrap(started["generation"] as? String)
         _ = try await controller.push(generation: generation, fix: fix(0))
 
-        try await Task.sleep(for: .milliseconds(40))
+        for _ in 0..<200 {
+            if guest.deliveries.count >= 2 { break }
+            try await Task.sleep(for: .milliseconds(5))
+        }
 
         XCTAssertGreaterThanOrEqual(guest.deliveries.count, 2)
+        guard guest.deliveries.count >= 2 else { return }
         XCTAssertEqual(guest.deliveries[0].fix.speed, 10)
         XCTAssertEqual(guest.deliveries[1].fix.speed, 0)
         XCTAssertEqual(guest.deliveries[0].fix.latitude, guest.deliveries[1].fix.latitude)
```

轮询上限 200 × 5 ms = 1 s，与同文件 `waitForState`（240-254 行）现有写法一致。

验证：

- 正常条件下通过，耗时从 0.044 s 降至 0.014 s。
- 保留该改法、同时把 `watchdogSeconds` 临时改为 `5.0`（使看门狗必然不触发）时，输出为 `SystemLocationControllerTests.swift:1120: error: ... XCTAssertGreaterThanOrEqual failed: ("1") is less than ("2")`、`Executed 1 test, with 1 failure (0 unexpected)`，无 `Fatal error: Index out of range`，无 `signal code 5`。即真实缺陷仍被捕获，且不再使 xctest 进程崩溃。

### 3.2 第 2 项：用独立线程释放锁

```diff
--- a/tests/VPhoneCLITests/CreateLiveStagesTests.swift
+++ b/tests/VPhoneCLITests/CreateLiveStagesTests.swift
@@ -282,7 +282,8 @@ struct CreateLiveStagesTests {
         stages.lockReleaseTimeout = 10
-        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { holder.lock = nil }
+        // A dedicated thread: the global queue can be saturated by parallel tests.
+        Thread { Thread.sleep(forTimeInterval: 0.3); holder.lock = nil }.start()
         #expect(isVerified(stages.verify(.verification, context: w.context(), evidence: ["boot_analysis": "prompt_detected"])))
```

与 `tests/VPhoneCoreTests/DiagnosticsTests.swift:679-688` 已有做法相同。

验证：60 忙循环负载下隔离复跑 5 次全部通过（`✔ Test verifierWaitsForARealBundleLockHolderToRelease() passed after 0.532 seconds.`）。

限制：该项失败在本机始终未复现，因此这 5 次通过不能证明改法修复了 CI 上的失败，只能证明改法不引入回归，并移除了对全局队列调度的依赖。

### 3.3 第 3 项：超时改由独立线程执行（生产代码）

```diff
--- a/sources/VPhoneCore/VPhoneProcessRunner.swift
+++ b/sources/VPhoneCore/VPhoneProcessRunner.swift
@@ -89,11 +89,19 @@ public enum VPhoneProcessRunner {
         let expired = DeadlineFlag()
         if let timeout {
             let target = process
-            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
-                guard target.isRunning else { return }
-                expired.set()
-                target.terminate()
-            }
+            // A dedicated thread: a block queued on the global concurrent queue
+            // can be starved by pending work, so the deadline never runs.
+            Thread {
+                let deadline = Date().addingTimeInterval(timeout)
+                while target.isRunning {
+                    if Date() >= deadline {
+                        expired.set()
+                        target.terminate()
+                        return
+                    }
+                    Thread.sleep(forTimeInterval: min(0.05, max(0.005, timeout / 10)))
+                }
+            }.start()
         }
         process.waitUntilExit()
```

轮询而非一次性 `Thread.sleep(timeout)`，使子进程提前退出时该线程随即结束，避免长 `timeout` 调用留下长时间休眠的线程。

验证：

- 饱和探针（512 个阻塞块）由 `timedOut=false elapsed=5.012` 变为 `timedOut=true elapsed=0.221`，用例通过。
- 三处改动同时应用后，24 忙循环负载下整套 Swift 复跑 5 次全部通过（`✔ Test run with 468 tests in 64 suites passed`，18.9–22.8 s）。
- 三处改动同时应用后，完整 `make test` 通过：Python `Ran 344 tests` / `OK`，XCTest `Executed 144 tests, with 3 tests skipped and 0 failures (0 unexpected)`，Swift Testing `✔ Test run with 468 tests in 64 suites passed after 11.267 seconds.`

未验证：该改动对 `Process.terminate` 之外的取消路径、以及对高频调用 `runCapturing` 场景的线程数影响，未做专门测量。

### 3.4 不属于上述三项的建议

`make test` 在缺少 `sources/vphone-cli/VPhoneBuildInfo.swift` 时会在 Swift 编译阶段失败。CI 通过额外步骤生成该文件绕过。本机执行者需先生成该文件，或由 `scripts/run_tests.py` 在 Swift 阶段前生成。本项未做改动。

## 4. 与 F3 批次提交的关系

**结论：三项失败与 `a6161e2`、`0239cf2`、`77524de`、`96d5857`、`799d168`、`a78630a` 均无关。**

### 4.1 提交顺序证据

CI 失败运行 `35290927966` 的提交为 `2011bc7`。

```
$ git merge-base --is-ancestor 2011bc7 799d168
2011bc7 is ancestor of 799d168 (oldest F3 code commit)
```

`799d168` 是六个提交中最早的一个，`2011bc7` 是它的祖先。即该次 CI 运行的代码中**不包含**这六个提交中的任何一个。

### 4.2 文件改动范围证据

`git show --stat` 结果：

| 提交 | 涉及文件 |
| --- | --- |
| `a6161e2` | `sources/vphone-cli/VPhoneHostCapabilities.swift`、`VPhoneHostCommandExecutor.swift`、`VPhoneHostScreenAdapter.swift`、`VPhoneTouchRoute.swift`、`VPhoneVirtualMachineView.swift`、`tests/VPhoneCLITests/HostCommandExecutorTests.swift`、`tests/VPhoneCLITests/TouchRouteTests.swift` |
| `0239cf2` | `sources/vphone-cli/VPhoneVirtualMachineView.swift` |
| `77524de` | `docs/.../f3_performance_baseline_plan_2026-09-18.md`、`scripts/f3_benchmark.py`、`tests/test_f3_benchmark.py` |
| `96d5857` | `scripts/f3_benchmark.py`、`tests/test_f3_benchmark.py` |
| `799d168` | `scripts/f3_benchmark.py` |
| `a78630a` | `docs/.../f3_performance_baseline_plan_2026-09-18.md`、`scripts/f3_benchmark.py`、`scripts/f3_host_sampler.py`、`scripts/f3_stats.py`、`tests/test_f3_benchmark.py`、`tests/test_f3_host_sampler.py` |

三项失败涉及的测试文件与实现文件均不在其中。

### 4.3 各文件最后改动证据

`git log -3 -- <path>`：

| 文件 | 最近提交 |
| --- | --- |
| `tests/VPhoneCoreTests/SystemLocationControllerTests.swift` | `bb9233c` 2026-09-12 test(location): verify persistence isolation and record E5 runtime progress |
| `sources/VPhoneCore/VPhoneSystemLocationController.swift` | `e2dcd53` 2026-09-16 fix(location): preserve persistence errors during headless startup |
| `tests/VPhoneCLITests/CreateLiveStagesTests.swift` | `8b6365f` 2026-09-17 fix(create): allow restart-from to regenerate removed artifacts (D4) |
| `tests/VPhoneCoreTests/DiagnosticsTests.swift` | `c2fac55` 2026-09-17 feat(diagnostics): add read-only vphone-cli doctor (D5) |
| `sources/VPhoneCore/VPhoneProcessRunner.swift` | `c2fac55` 2026-09-17 feat(diagnostics): add read-only vphone-cli doctor (D5) |

### 4.4 引入时间

`git log -S`：

| 失败点 | 引入提交 |
| --- | --- |
| `testWatchdogHoldsLastAcceptedCoordinate` 与其中的 `milliseconds(40)` | `6630ab9` 2026-08-19 refactor: move system location control into VPhoneCore |
| `VPhoneProcessRunner.swift` 中的 `DispatchQueue.global().asyncAfter` | `c2fac55` 2026-09-17 feat(diagnostics): add read-only vphone-cli doctor (D5) |
| `CreateLiveStagesTests.swift` 中的 `DispatchQueue.global().asyncAfter` | `99da011` 2026-09-17 fix(create): wait for stage children before verifying (D4) |

最后一次成功运行为 2026-09-12 的 `34679220172`。第 2、3 项涉及的测试与代码在 2026-09-17 由 D4/D5 相关提交（`99da011`、`c2fac55`）引入，晚于该次成功运行，与"9 月 12 日之后开始连续失败"的时间线一致。第 1 项的测试自 2026-08-19 起即为现状，其在本次失败中被触发的具体条件未查明。

## 5. 未完成与限制

1. 第 1 项与第 2 项在本机未复现（合计 11 次整套复跑、5 次隔离复跑、第 1 项另有 8 次加载隔离复跑）。原因判定基于源码读取与受控实验，不基于本机自然复现。
2. 第 1 项在 CI 上 40 ms 未满足的具体调度成因未查明，标记为待验证假设。
3. 第 2 项"释放块被延迟超过 10 秒"在本机未直接观测到，标记为待验证假设；本机只观测到同一原语被延迟 3.8–4.5 秒。
4. 本次未执行 `make build`、未启动 VM、未提交、未推送。
5. 未在 CI 上验证任何改法。
