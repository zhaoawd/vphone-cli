# 第一阶段测试计数补充

日期：2026-10-14。审查者：signed_v6。本记录纠正 timers-stage1-independent-review.md/json 中 Swift Testing 的执行口径，旧审查及 review-v2 保留。

timers-stage1-regressions-02 退出 0；Swift Testing 汇总为 38 个选中测试、4 个 suite，其中 36 个实际通过，2 个真实 fixture 入口跳过：

- actualPublicForceExcGuardPlansProduceDifferentPayloads
- actualCandidateRegionUsesSourceFlow

旧 JSON 的 swiftTestingPassed=38 应解释为汇总选中数，不能解释为 38 项全部实际执行。本补充明确以 selected=38、passed=36、skipped=2 为准。9 项 KernelIOTrace XCTest 均实际执行通过，独立分析器 10 项纯 Python 测试均实际执行通过。

这两项跳过不影响已单独核对的合成生产 trace；本次没有把 fixture 跳过改记为通过。baseline 的 7 项 direct equivalence 和 4 项 memory 子操作属于未插桩旧算法证据，不能提升为尚未运行的优化算法结果。
