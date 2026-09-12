# 资源路径测试的环境变量隔离

日期：2026-09-12。发现于 E2 完整快速回归；失败发生在既有 `ResourcesTests`。

现象：`userCacheDirHonorsVPHONERoot` 预期 `/tmp/vphone-test-root` 下的 tools/debs/venv，实际部分字段回退到 `~/.vphone`；隔离复现时还读到另一测试设置的 `/tmp/custom-venv`。

复现命令：`swift test --disable-sandbox --skip-build --filter 'ResourcesTests|LibraryTests'`。首次隔离运行即失败；只运行 `ResourcesTests` 也失败，单独运行 `userCacheDirHonorsVPHONERoot` 通过。上述命令均未执行 E2 命令测试。

原因：这些测试通过 setenv/unsetenv 修改进程共享环境。ResourcesTests 中的用例并行运行，LibraryTests 的组内串行约束不能隔离其他组。断言之间的环境值可被另一用例覆盖或删除；检查环境后再决定是否跳过也不能消除该竞争。

修复：为实际路径解析增加 internal 环境参数，测试传入各自的字典。公开初始化、userDataRoot 和 defaultRoot 仍读取进程环境；未改变公开调用方式和覆盖优先级。移除测试的全局环境修改及已无必要的组内串行约束。现有断言继续验证默认目录、VPHONE_ROOT 和专用覆盖变量。

结果：资源/库 14 个测试通过；相同隔离命令随后连续 8 次通过。原始完整回归将在 E2 验收中重跑。该修复单独提交，不视为 D1/D2 构建或依赖工作已经完成。

日志将保留在 `research/artifacts/e2-control-2026-09-12/`，包括首次失败、单测/测试组隔离和修复后的重复验证。此类测试应显式传入配置，避免改变其他并行用例的进程状态。
