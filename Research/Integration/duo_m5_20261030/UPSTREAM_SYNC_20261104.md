# Duo 分支同步记录（2026-11-04）

基线为 Duo `8e8e1345`，上游参考为 `90dc4a3f`。本次使用独立工作区，构建输入为 `d43758d6`。

| 上游内容 | Duo 提交 | 范围 |
| --- | --- | --- |
| #804 `f2b006e4` | `06189d11` | 恢复树发布使用 APFS 文件克隆及复制回退；Cryptex 合并用完即释放中间镜像 |
| #805 `1af7558a` | `0b7e21a3` | VM 窗口使用 `PushSymbolicHotKeyMode`，移除修改宿主设置的旧路径 |
| #812 `c9fe8071` | `d43758d6` | X1 共享缓存的字级撤销日志及旧日志转换；保留 Duo 对缓存外 AccessibilityBundles 的修复 |
| #819 `90dc4a3f`（虚拟机章节） | 本文所在提交 | 四语言操作与存储手册，加上 Duo 显示屏说明；沿用当前分支的其他指南和历史链接 |

手册未导入当前 CLI 不支持的 `vm create --bootstrap` 说明，也未把 #808 的 iOS 18 Standard 结果计为本分支验证。网站构建和发布流程另行处理。

## 验证

以下命令在 Duo 工作区执行。Xcode 命令另带 arm64 macOS 目标、独立派生目录和本地依赖目录；日志包含完整参数。

| 命令或检查 | 结果 | 工作区日志 |
| --- | --- | --- |
| `xcodebuild -project VPhoneKit/VPhoneKit.xcodeproj -scheme VPhoneCoreKitTests -only-testing:VPhoneCoreKitTests/ConfinedDirectoryTests test` | 12 项通过，含克隆后隔离、权限和符号链接行为 | `.build/confined-directory-tests.log` |
| `xcodebuild -workspace VPhone.xcworkspace -scheme FirmwarePatcherTests test-without-building`，限定 `DyldSharedCacheUndoLogTests`、`DyldSharedCacheUndoWordsTests`、`DyldSharedCacheOutdatedImplementationTests` | 23 项通过，含旧日志转换、新格式写入和还原 | `.build/dsc-undo-final-tests.log` |
| `xcodebuild -workspace VPhone.xcworkspace -scheme VPhone -configuration Debug build` | 构建和 bundle admission 通过 | `.build/first-batch-build.log` |
| `codesign --verify --deep --strict --verbose=2 <bundle>` | 通过 | `.build/first-batch-codesign.log` |
| `zsh Research/Integration/duo_m5_20261030/Regression/display-config.zsh <vphone-cli> <evidence-dir>` | `fold`、`outer`、`inner` 配置与拒绝路径通过 | `.build/first-batch-display-config.log` |
| `node .build/check-manual.mjs` | 48 页目录结构一致，280 个本地链接及显式锚点通过 | 脚本位于本地 `.build/` |

本次未启动 VM。尚未测量完整恢复的峰值磁盘占用，未验证真实宿主键盘焦点切换，也未在 Duo 客户机上转换既有 X1 日志并回滚共享缓存。以上单元测试和 CLI 检查不覆盖这些运行时行为。

后续分别验收 #788、#799、#800、#801 对 Duo 显示、AX 和锁屏的影响，以及 #808 的 iOS 18 支持。启动链以 #813 后的预设为准。
