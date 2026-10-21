# T51 提交范围与隔离验证（2026-10-21）

本次提交包含磁盘rebase、事务恢复、物理共享计量、Launchpad检查器及必要的停止状态/快照journal基础。快照基础提供rebase的既有快照提示、pending门控及恢复入口。首次绑定备份和归档传输等其他未提交工作继续保留。

共享文件按功能生成索引内容：MachineLibrary只提交计量接线；旧单次导入由globalActivity拒绝计量，工作区的多项导入队列仍使用其imports门控。BundleOps只提交快照/rebase历史排除。固件资格测试只提交rebase后旧inode拒绝。README、文案和台账仅提交T51范围。原工作区895个具名文件摘要保持。

将索引完整导出到.build/t51-commit-scope/tree，在独立scratch目录构建。正常构建生成的VPhoneBuildInfo.swift未受版本管理，首次导出构建因此失败；补入同一生成文件后，DiskRebase/DiskUsage/VMRebaseCLI/BundleSnapshots/BundleActivity/FirmwareDesiredPlanStore共78项通过。隔离Python Launchpad边界23项通过。验证命令：

```sh
CLANG_MODULE_CACHE_PATH=$PWD/.build/test-module-cache SWIFT_MODULECACHE_PATH=$PWD/.build/test-module-cache swift test --package-path .build/t51-commit-scope/tree --scratch-path .build/t51-commit-scope/swift-build --disable-sandbox --filter 'DiskRebaseTests|DiskUsageTests|VMRebaseCLITests|BundleSnapshotsTests|BundleActivityTests|FirmwareDesiredPlanStoreTests'
.venv/bin/python3 -m unittest discover -s .build/t51-commit-scope/tree/tests -p test_launchpad_bundle.py -v
```

此前两次真实启动和实际界面证据绑定于其保存的WIP候选摘要，并不声称隔离提交产物再次完成VM启动。rebase/事务/物理映射核心保持该候选实现；提交范围的独立构建与回归另行保存。未推送，不代替人审accepted。证据：evidence/T51-commit-scope-20261021/manifest.json。
