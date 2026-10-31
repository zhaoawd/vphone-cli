# 构建产物与缓存清理（2026-10-23）

用户在当前聊天审阅约 5.3 GiB 的建议清单后回复“按建议清理”。本轮仅删除该清单中的十一处构建输出、测试生成物和缓存；未执行 `make clean`，未停止或重启 VM。

## 结果

十一项目标均已删除，执行退出 0。删除前目录累计占用统计为 5,674,721,280 字节，约 5.29 GiB。卷可用空间从 48,857,931,776 字节增至 54,471,884,800 字节，即约 45.50 GiB 至 50.73 GiB；即时增加 5,613,953,024 字节，约 5.23 GiB。卷空闲量受其他进程和 APFS 回收影响，该差值不作为独占块计量。

## 删除范围

```text
.build/out
.build/t51-commit-scope/swift-build
.build/test-daemon-pipe
.build/daemon-api-icli086-20261021/Xcode/Build
.build/t52-consumer-fix-20261022/daemon-api/Xcode/Build
.build/pip-cache
.build/build-module-cache
.build/test-module-cache
.build/release-module-cache
.build/t52-consumer-fix-20261022/daemon-api/Xcode/ModuleCache.noindex
.build/t52-consumer-fix-20261022/daemon-api/Xcode/SDKExplicitPrecompiledModules
```

## 验证与影响

- 准备与执行均检查真实路径、非阻塞排他目录锁、逐目标 lsof、hdiutil 挂载和 Git 跟踪状态。没有发现其他进程打开目标文件；没有发现目标中的已跟踪文件、已挂载镜像或指定 VM 状态文件。
- 删除前保存 55,135 项目录内元数据，执行后逐项确认十一项目标不存在。
- 保存并比较根级候选应用的 MacOS 可执行文件摘要、t52-v2 runtime/config 摘要、选定 VM 磁盘设备号/inode/逻辑大小、`.venv` 链接、选定候选及 SourcePackages 目录元数据，以及 T51 导出树的 VPhoneBuildInfo.swift 元数据，结果保持一致。未对运行磁盘计算完整摘要。
- 清理前后进程记录均保存；本轮没有发送停止、重启或终止信号。
- 保留各 VM、备份、候选应用、依赖源码、验收记录、原始 IPSW 和 Python 环境。未清理研究证据或 T51 导出树。
- `.build/debug`、`.build/release` 仍指向已移除的构建输出；后续使用这些产物前需要重新构建。缓存将在后续构建或测试中生成。

执行命令：

```sh
.venv/bin/python3 -B research/build_cache_cleanup_2026-10-23.py
.venv/bin/python3 -B research/build_cache_cleanup_2026-10-23.py --apply
```

两条命令均退出 0。证据位于 `research/evidence/build-cache-cleanup-2026-10-23/`，包括 plan.json、result.json、inventory.json.gz、protected-after.json 及清理前后进程记录。

本轮未修改产品代码，未重新执行产品测试或真实 VM 验收；没有通过重建验证后续恢复构建产物的行为。
