# Task 8 第六版签名候选（2026-10-14）

第六版纳入 `FirmwareKernelDisk.swift` 四个块扫描循环的 autorelease pool 修复。生产源码 SHA-256 为 `d166b6493d976b171e74eca4fe73d578f3256017f1ea20eab4256fb93e46db62`，最终内存回归测试源码 SHA-256 为 `8b313330b3e7a8672ce1c05942f7f4f1c9a661e813b1cc2aee44d23f0047f023`。主任务已确认四循环独立审查、Swift Testing 53 tests / 11 suites 和四项内存子操作通过；证据位于 `capture-memory/`。构建清单包含上述精确文件内容。

版本为 `2.6.20261018-local`，`CFBundleShortVersionString` 为 `2.6.20261018`，`CFBundleVersion` 为 `2026101401`。版本仅在独立构建目录 `/private/tmp/vphone-task8-acceptance-build` 覆盖，生产 `sources/Info.plist` 未由本代理修改。第一至第五版工件保留，第五版 app 另存为 `signed-app-v5.app`。

冻结 Bundle 为 `/private/tmp/vphone-task8-acceptance-build/core-candidate-v6/VPhone.bundle`，ZIP 为同目录 `VPhone.zip`。ZIP SHA-256 为 `dd7cb63100e41966fc89226ba58a8a8e343077a2de261541eb35497c02ea5aef`。

| 对象 | SHA-256 | CDHash |
| --- | --- | --- |
| CLI | `ac7693162b669acde744fc66c2ec208554d0060ee8ba7d3c66b9a5010efee656` | `f73340bba9178a85933b69d4b021191031808b1a` |
| VM | `a9b5fb28b32cf236ffb1fddf51e57d36a10bafbf7a181f52533eb653f87280f1` | `eb667b4c294a63584c6f5163028802a05f1fdfc4` |
| 历史 escalator | `12b964b4e2100110c525d68a677de26f62044e19fc1dc4ffe8b2ca6e1ce52fdc` | `67be7b719f9a643e8931b990ffc91dd4fed0a24a` |

首次沙箱构建因 Swift ModuleCache 写权限限制退出，原始失败保存在 `signed-build-v6.log/json`。获准的同范围提权完整 `make build` 退出 0，耗时 147.971 秒，证据为 `signed-build-v6-escalated.log/json`。打包退出 0，证据为 `core-candidate-v6-package.log/json`。完整构建包括 release 编译、CLI/VM 签名、guest payload 构建、资源封装、原生依赖闭包和最终签名。严格递归签名、单独入口签名、7 项 host Mach-O 闭包及资源检查均通过。ZIP 内 237 个文件的 SHA-256 均与最终 Bundle 清单一致。

`build-source-v6-manifest.json` 记录 5633 个构建输入、生产源哈希、子模块和构建版本；清单 SHA-256 为 `b5cd2fea6e2bd3fc16d8d2cf6819e16df6c9b505254ab1567fce9b919b8e050f`。`build-source-v6-current-comparison.json` 记录生产源无遗漏或不一致。构建后只有自动生成的 `VPhoneBuildInfo.swift` 改为构建仓库实际提交 `0d22721f`，内容及 SHA-256 保存在 `build-source-v6-generated-info.json`；这是清单比较中明确允许的生成文件。其他输入未改变，生产源冻结后无变化，见 `build-source-v6-postbuild-comparison.json`。

`v1-v5-evidence-preservation-before-v6.json` 和 `v1-v5-preservation-after-v6.json` 证明既有证据、五版 ZIP、Bundle 全部文件及文件集合均一致。`core-candidate-v6-manifest.json` 记录完整签名、架构、命令和逐文件哈希；`core-candidate-v6-final-freeze.json` 记录最终冻结检查。新打包脚本为 `package-core-candidate-v6.py`，没有覆盖旧脚本。

本代理未安装第六版，未执行 VM，未操作测试 VM，未修改 AMFI 或 TCC。VM CDHash 未获本轮 AMFI 放行授权；第六版仅交给主任务用于正式离线更新。构建和打包成功不构成真实磁盘发布、事务恢复、启动或已提交后 kernel-only 回退的验收证据。
