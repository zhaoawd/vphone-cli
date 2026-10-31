# 项目空间清理评估（2026-10-24，本轮项目范围）

本轮只读核对，未删除文件、停止进程、启动 VM 或开启辅助窗口。路径均相对 `/Users/kolar/github/vphone-cli/`。按执行器同类 `statvfs` 口径，本轮记录可用 69.05 GiB，距 T32/T33 的 75 GiB 初始门槛约差 5.95 GiB；卷空间会随其他活动变化。

优先候选共 19 个目录，分配量合计 **4.05 GiB**：构建产物及缓存 2.64 GiB，保留 tar 中已有完整内容的旧解包目录 1.41 GiB。逐目录 lsof 未发现打开句柄；当前 T32/T33 续验计划的 571 项冻结输入未引用这些目录；这些目录内没有 Git 跟踪文件。实际删除仍需明确批准，并在执行前复核占用和挂载状态。

所有大小均为 `du` 或 `st_blocks` 分配量。APFS 克隆可能共享物理块，分配量不等于删除后实际可释放量，不能按表内总量承诺回收空间。仅此优先批次尚不足以保证达到 75 GiB。

构建产物及缓存可由后续构建重新生成。删除 `.build/out` 后，`.build/debug` 和 `.build/release` 指向的产物需要重建。当前运行的 VM 使用独立 `.build/vphone-cli.app/Contents/MacOS/vphone-vm`，该程序路径保留。

| 路径 | 分配量 GiB | 结果 |
| --- | ---: | --- |
| `.build/out` | 2.310 | 构建产品、编译中间文件及其内部缓存 |
| `.build/module-cache` | 0.086 | Swift/Clang 模块缓存 |
| `.build/test-module-cache` | 0.029 | 测试模块缓存 |
| `.build/test-cache` | 0.008 | SwiftPM 测试 manifest 缓存 |
| `.build/swift-cache` | 0.001 | 本轮 SwiftPM manifest 缓存 |
| `.build/daemon-api-icli086-20261021/Xcode/ModuleCache.noindex` | 0.060 | Xcode 模块缓存 |
| `.build/daemon-api-icli086-20261021/Xcode/SDKExplicitPrecompiledModules` | 0.145 | SDK 预编译模块 |
| `.build/daemon-api-icli086-20261021/Xcode/SDKStatCaches.noindex` | 0.0015 | SDK 状态缓存 |
| `.build/daemon-api-icli086-20261021/Xcode/CompilationCache.noindex` | 小于 0.0001 | 编译缓存 |
| `.build/t52-consumer-fix-20261022/daemon-api/Xcode/SDKStatCaches.noindex` | 0.0015 | SDK 状态缓存 |
| `.build/t52-consumer-fix-20261022/daemon-api/Xcode/CompilationCache.noindex` | 小于 0.0001 | 编译缓存 |

以下 8 份解包目录逐项核对了 tar 完整 SHA-256、2,152 个文件的内容/模式、成员类型及符号链接，全部匹配；各目录根部仅有 `VPhone.bundle`。清理范围仅为表内目录，保留同目录下对应 tar、候选 JSON、日志和证据。旧脚本如引用原解包路径，后续使用前须从 tar 恢复该路径。

| 可清理解包目录 | 保留的 tar 文件名 | 分配量 GiB |
| --- | --- | ---: |
| `.build/t32-t33-completion-20261023/package-r6` | `2.6.2-local.887b0069c62a.tar` | 0.181 |
| `.build/t32-t33-completion-20261023/producer-package-20261024` | `2.6.2-local.d697b5956356.tar` | 0.181 |
| `.build/t52-consumer-fix-20261022/package-r2` | `2.6.2-local.cc05d88f441f.tar` | 0.181 |
| `.build/t52-consumer-fix-20261022/package` | `2.6.2-local.3b5348f496ed.tar` | 0.181 |
| `.build/t52-camera-interface-20261022/package` | `2.6.2-local.93805a71796d.tar` | 0.172 |
| `.build/t52-camera-diagnostics-20261022/package` | `2.6.2-local.56be1ce20ded.tar` | 0.172 |
| `.build/t52-real-20261021/package` | `2.6.2-local.cd529f26a150.tar` | 0.172 |
| `.build/t52-api-proxy-deploy-20261022/package` | `2.6.2-local.266810c8ae29.tar` | 0.172 |

更大的对象需要单独决定退役范围。以下对象未被当前续验计划的冻结输入直接引用，但仍受既有“保留旧盘、备份和历史”要求约束。本轮没有批准或执行退役，也没有确认独占物理块数量。

| 对象 | 分配量 GiB | 清理影响 |
| --- | ---: | --- |
| `.build/t32r-20261023` | 14.40 | 丢失旧 GUI 诊断副本最后运行后的完整状态 |
| `.build/t32-t33-completion-20261023/display-runtime/pre-runtime-backup` | 约 14.13 | 丢失该轮显示诊断启动前恢复点；统计含父目录少量日志 |
| `.build/t32-t33-followup-20261023/pre-runtime-backup` | 13.70 | 丢失更早运行诊断的启动前恢复点 |
| `vm-t32-t33-20261018-r2` | 52.79 | 退役旧 26.1 验收 VM 及其固件/CFW 历史 |
| `.build/t32-t33-completion-20261023/fresh-library/t32-t33-file-acceptance-20261023` | 至少 127.60 | 丢失旧完整文件验收副本及其撤销重放能力；报告及另存证据仍可保留 |

当前必须保留的对象包括 `.build/t32q-20261024`、其绑定前备份、`pre-acceptance-backup`、已安装候选的本地副本 `producer-package-final-20261024`、修复候选 `origin-identity-package-20261024`、两个候选 tar、原始 IPSW、原 VM 内被冻结引用的 ROM、研究证据及任务记录。`.build/t52-provider-fix-20261023/package` 还是候选构建工具的基底，本轮未列为清理候选。

`vm-2607` 的 PID 33355 仍运行；`vm-new` 仍有关联健康监测进程。本轮未发现项目路径内的 hdiutil 附件。不得将 `.cfw-history` 中的 `Disk.img`、`guest-postimage.img` 或 `effect-blobs` 单独当作缓存删除，它们参与收据、磁盘身份和撤销核验。`SourcePackages`、依赖源码和 Python 环境也未列入优先批次。

枚举存在权限限制：原始 `du` 错误记录列出了 11 个不可访问目录，包括新旧隔离副本的 generation/Restore、锁定 Python 缓存及部分 RootHide 事务目录。相关统计是可读部分，未将不可读内容记作零。没有测量整个卷的独占 extent 或快照保留量；未重新构建或运行产品测试。

检查使用 `du -k -d 1/2/4`、`statvfs`、`git ls-files`、`ps`、逐目录 `lsof +D`、`hdiutil info -plist` 和只读归档比较脚本。归档比较命令为 `.venv/bin/python3 -B research/project_storage_review_20261024.py`，8 项全部通过。证据保存在 `research/evidence/project-storage-review-20261024/`，含逐路径分配量、tar 比较、句柄查询、权限错误和摘要清单。
