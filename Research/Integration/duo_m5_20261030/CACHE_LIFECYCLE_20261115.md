# DSC 映射和缓存 worker 集成，2026-11-14–15

集成与本地验收完成。起点为 `03813395`，集成目标固定为本地 `origin/main` 的 `13169405`，未推送或发布。29 项固件测试、15 项 C 检查、完整 Bundle 构建及严格签名通过。新隔离副本已恢复原 daemon 和标记，第二次冷启动核对后正常关机。

## 来源与范围

| 来源 | 最终提交 | 内容 |
| --- | --- | --- |
| [#853](https://github.com/Lakr233/vphone-cli/pull/853) | `2fdcf16c` | 每个镜像规划后清理 mappedChunks；Linux 并发上限 4，macOS 保留原 CPU 上限 |
| [#897](https://github.com/Lakr233/vphone-cli/pull/897) | `aa3d1ed9` | 符号导出查询和 guest volume 操作范围使用 autoreleasepool |
| [#865](https://github.com/Lakr233/vphone-cli/pull/865) | `ea5990ec` | 按已打开缓存与执行路径的设备号／inode 判断路径别名，验证 pending 标记与镜像后确认 |

读取了 PR 正文及本地最终合并差异。#865 的最终版本没有扩大到任意早期启动标记修复；历史 pending-marker 故障的全部原因没有由该 PR 确认。本轮也不将先前缓存路径实际是目录的问题归因于路径别名。

使用 `Skills/authoring-patch-sets/SKILL.md` 核对声明与撤销要求。本轮没有新增 patch、preset 或替换指令；必须保留 Duo `31933ff2` 的 X1 撤销归属行为，并更新补丁对照记录。

## 已有验证

证据目录：`.build/cache-lifecycle-20261114/`。

- 新增 macOS 自身 VM region 观测，同时保留 Linux `/proc/self/maps` 观测。合成缓存的每镜像范围在成功与抛错后均复现残留映射，日志 `mapping-before.log`。基线只增加透传 scope 入口以编译测试，未执行任何清理；最终实现已替换为上游 defer 清理。
- 真实只读 DSC 为 `.build/duo-next/gles-cache-24A94425/`。导出符号查询完成并释放 resolver 后，旧实现仍持有映射；`resolver-before-suite.log` 共记录三个失败断言。测试环境需使用 `TEST_RUNNER_VPHONE_DSC_LIFETIME_REFERENCE` 传入 Xcode 测试进程。
- 修复后，映射、实际符号查询、X1 bootstrap、普通 undo 及过时实现判定共 18 项通过：`mapping-after.log`。
- 独立补跑实际名称 `DyldSharedCacheUndoWordsTests`，11 项通过，包括同页其他补丁归属保持和已有 X1 sidecar 修复：`undo-words-after.log`。前一条命令中的 `DyldSharedCacheWordUndoTests` 名称不匹配，未计为该组执行证据。
- 上游身份 helper 12/12 通过。提取生产确认函数的额外 fixture 在旧函数失败 2/3，修复后 3/3 通过；检查路径别名、不同 inode 和符号链接 pending 标记。fixture 只将 UID 谓词改为测试文件所有者，真实 mode/type/no-follow 操作保留；生产 UID 0 要求未放宽。日志 `identity-helper.log`、`confirmation-before.log`、`confirmation-after.log`。
- 完整 Bundle 构建、构建内 admission、深度严格签名通过。候选 daemon SHA-256 为 `8572e0f9c69bc319d85d1d59c1d441dd2d2c4dc41d68ed675dec47d7df9e63ab`。

## 真实 DSC 副本比较

证据目录：`.build/cache-lifecycle-20261114/cache-compare.RCooFNnB/`。将参考缓存 APFS 克隆为两份，分别运行旧、新 CLI 的 X1 bootstrap dry-run 和 undo words 归一化。

- 两份规划日志完全相同：38 个镜像、0 次重写、0 个未遍历候选。参考缓存已经过 X1 降级；本项不覆盖真实缓存的非零指令重写，非零写入由 X1 bootstrap 合成测试覆盖。
- 归一化后全部 82 项文件的旧、新 SHA-256 完全相同，缓存 chunk 未变，其他补丁的 22 条记录保持不变。日志记录 1 个旧 X1 page run 转为 24,834,393 条指令记录。
- 参考缓存全部 82 项摘要仍与比较前保存的清单一致。Duo `31933ff2` 的同页其他补丁归属保持逻辑未改动。

## 实际缓存 worker 验收与恢复

仅使用新身份隔离副本 `duo-cache-worker-20261114`。原验收副本 `duo-rpc-accept-205443` 本轮未启动。宿主程序使用既有已准入的基线 `vphone-vm`，guest 库使用原版本。启动参数 `--vphoned-bin` 指向不存在的专用路径，禁用宿主 daemon 自动更新，避免其覆盖冷启动结果；未修改宿主 AMFI。

| 阶段 | 证据目录后缀 | launchd start_time | 结果 |
| --- | --- | --- | --- |
| 更新 | `worker-install.nhq11PUk` | `1794676822.028108` | 原 worker 经 `agent.apply_update` 替换为候选；确认标记为候选 SHA-256，pending 不存在 |
| 冷启动 | `worker-cold.P4ebb7Yl` | `1794676890.022307` | worker 119 为候选；确认标记保持候选 SHA-256，pending 不存在 |
| 恢复 | `worker-rollback.CzUw7XvF` | `1794676979.054051` | 原 daemon 和原标记恢复 |
| 恢复后冷启动 | `worker-restored.5XmzPYqE` | `1794677086.018145` | worker 116 为原 daemon；标记与初始快照相同 |

四阶段均核对 21 项库不变、根文件系统只读，随后通过 RPC 正常关机，状态文件无打开句柄。最终另行用 `lsof` 核对原副本和测试副本的 `Disk.img`、`nvram.bin`、`SEPStorage`，均无打开句柄。原 daemon SHA-256 为 `446925b66b983e6395bc2c6715885f1eae1d1836cee014a3df136f468540419b`。

冷启动进程清单中，worker 119 和 proxy 67 的可执行路径均报告为 `/private/var/root/Library/Caches/vphoned`；配置缓存路径为 `/var/root/Library/Caches/vphoned`。这是进程接口报告的路径，不将其等同于未经单独记录的 `_NSGetExecutablePath` 返回值。路径别名对确认函数的影响另有旧实现失败、修复后通过的 fixture 证据。

## 回归入口

身份 helper 与生产确认函数：

```zsh
zsh VPhoneDaemon/Tests/run-cached-binary-identity-tests.sh
zsh VPhoneDaemon/Tests/run-cached-binary-confirmation-tests.sh
```

映射、符号与撤销回归（本地真实 DSC 路径需存在；CI 未设置该变量时跳过真实 DSC 项）：

```zsh
TEST_RUNNER_VPHONE_DSC_LIFETIME_REFERENCE="$PWD/.build/duo-next/gles-cache-24A94425" \
xcodebuild -workspace VPhone.xcworkspace -scheme FirmwarePatcherTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/duo-sync-20261113/XcodeBundle \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO -jobs 4 test \
  -only-testing:FirmwarePatcherTests/DyldSharedCacheMappingLifetimeTests \
  -only-testing:FirmwarePatcherTests/DyldSharedCacheArm64eX1BootstrapTests \
  -only-testing:FirmwarePatcherTests/DyldSharedCacheUndoLogTests \
  -only-testing:FirmwarePatcherTests/DyldSharedCacheUndoWordsTests \
  -only-testing:FirmwarePatcherTests/DyldSharedCacheOutdatedImplementationTests
```

正式保存入口位于同目录 `Regression/`：`dsc-lifecycle-compare.zsh`、`cache-worker-runtime.zsh`、`cache-worker-check.mjs`。更新、冷启动与恢复使用 `.build` 中的工作驱动；恢复后冷启动实际使用正式入口。VM 驱动固定测试副本、候选和基线摘要；依次接受 `install`、`cold`、`rollback`、`restored`，每轮均正常关机，原标记快照重复执行时不覆盖。运行前须保留当前明确对象与动作的授权。大体积证据和候选保留在 `.build`，不随源码提交。

CI 已加入 5 个准确名称的固件测试 suite 和两项 C 测试入口。完整 Bundle 日志为 `bundle-build.log`，严格签名日志为 `bundle-signature.log`。

本轮未执行实际 CFW 安装／System 卸载，也未运行 Linux 的 FUSE/SSHFS 及并发上限验收。新构建宿主 VM 程序未另行准入运行；实际 VM 验收使用已准入宿主程序和新 daemon。上述上游其他设备实测不计为本地结果。
