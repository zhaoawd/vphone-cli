# 测试临时文件清理记录

日期：2026-09-08。

修复 `tests/VPhoneCoreTests/BundleOpsTests.swift`：导入导出辅助函数在断言闭包执行后清理源目录、目标目录和测试 ROM；导出到目录测试清理输出目录；进度测试补齐 ROM 清理。上述清理失败通过 `Issue.record` 报告，不再静默忽略。

最终 BundleOpsTests 23 项通过。测试前后临时目录对比未发现新增测试磁盘、归档或测试 ROM 残留。第一轮验证发现的一个导入目录残留原因未查明；补充清理错误报告后，最终一轮未复现。

已删除此前逐项确认的 91 个测试目录（约 39.05 GiB 已分配空间）和 `/private/tmp/vphone-a2-probe`（约 193 MiB）。另删除首轮检查发现的一个测试导入目录、两个三字节测试 ROM，以及最终测试前已存在的六个同类目录。额外目录均重新核对配置、ROM 内容及无文件占用。合计删除 98 个测试目录，另有 A2 专用测试目录。删除前核对测试配置、ROM 内容、进程占用；原批次另检查磁盘挂载状态。

最终可用空间约 48.29 GiB。临时目录下剩余 orig/copy 测试磁盘数量：0。真实 VM 目录、运行程序、固件缓存和其他 worktree 未删除。其他已暂存的工作区修改未调整。

本次测试修复与此记录一并提交至 `codex/autophone-location-multivm-integration`。日志和原批次删除清单位于 `research/artifacts/test-cleanup-2026-09-08/`（Git 忽略目录）。
