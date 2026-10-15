# Task 8 第七版签名候选（2026-10-14）

第七版纳入 `FirmwareComponentReceipt.verifyEffect` 的 Data 切片索引修复。字节记录的 `fileOffset` 从 `payload.startIndex` 计算集合索引，保持既有边界守卫和逐字节效果检查。内核补丁算法未改变。生产源码 SHA-256 为 `420344494a44d4e7db56f376d98540a55c578471fa724a8d40685471dcba2bbd`，新增回归测试 SHA-256 为 `e5ffed66c996bf842bedd2d6a8188c4e05a0cb14dfb631738f269b00b31ea9c1`。构建清单包含上述精确内容。

`effect-index/independent-review.md` 记录独立审查未发现阻断问题。该目录的扩大定向回归退出 0，Swift Testing 汇总 82 tests / 14 suites，其中 4 项因缺少指定 fixture 跳过；四项内存子操作实际执行通过。上述测试不代替真实磁盘发布、恢复和启动验收。

版本为 `2.6.20261019-local`，`CFBundleShortVersionString` 为 `2.6.20261019`，`CFBundleVersion` 为 `2026101402`。版本仅在独立构建目录 `/private/tmp/vphone-task8-acceptance-build` 覆盖，生产 `sources/Info.plist` 未由本代理修改。第六版 app 另存为该构建目录的 `signed-app-v6.app`。

冻结 Bundle 为 `/private/tmp/vphone-task8-acceptance-build/core-candidate-v7/VPhone.bundle`，ZIP 为同目录 `VPhone.zip`。ZIP SHA-256 为 `fc76c6ff26fadfd6ae9eda9cfebabba15c0166bdbb83e6b19861f499ac9f15fc`。

| 对象 | SHA-256 | CDHash |
| --- | --- | --- |
| CLI | `28e87067ce7c569cf2d1bd72c33b045f3b9bdb151e2f6291db38b7fbbf452ef3` | `df8384e696521c8c4d47dd955b056642a6563878` |
| VM | `ee2b5f0682e2ab8851e1634705af4e3a7b0b992a84ead3f22a0f9317ee39a457` | `530654ea459feab3ea7a78fe515a62aac9bf4eaa` |
| 历史 escalator | `12b964b4e2100110c525d68a677de26f62044e19fc1dc4ffe8b2ca6e1ce52fdc` | `67be7b719f9a643e8931b990ffc91dd4fed0a24a` |

获准的同范围提权完整 `make build` 退出 0，耗时 132.432 秒，证据为 `signed-build-v7.log/json`。打包退出 0，证据为 `core-candidate-v7-package.log/json`。完整构建包括 release 编译、CLI/VM 签名、guest payload 构建、资源封装、原生依赖闭包和最终签名。严格递归签名、单独入口签名、7 项 host Mach-O 闭包和资源检查均通过。ZIP 内 237 个文件的 SHA-256 与最终 Bundle 清单一致。

`build-source-v7-manifest.json` 记录 5634 个构建输入、生产源哈希、子模块和构建版本；清单 SHA-256 为 `fad16f8746d8edfc847eb3e0708b6b31afe9c92df6d3bf797c6285ad3a58fa42`。相对第六版冻结生产源，仅组件效果读回文件及新增索引回归测试改变。`build-source-v7-current-comparison.json` 记录生产源无遗漏或不一致。构建后只有自动生成的 `VPhoneBuildInfo.swift` 改为构建仓库实际提交 `0d22721f`，内容及 SHA-256 保存在 `build-source-v7-generated-info.json`；这是清单比较中明确允许的生成文件。其他输入未改变，无新增输入，生产源冻结后无变化，见 `build-source-v7-postbuild-comparison.json`。

`v1-v6-evidence-preservation-before-v7.json` 和 `v1-v6-preservation-after-v7.json` 证明既有证据、六版 ZIP、Bundle 全部文件及文件集合均一致。`core-candidate-v7-manifest.json` 记录完整签名、架构、命令和逐文件哈希；`core-candidate-v7-final-freeze.json` 记录最终冻结检查。准备、打包及复核脚本分别为 `prepare-build-source-v7.py`、`package-core-candidate-v7.py` 和 `freeze-core-candidate-v7.py`，没有覆盖旧脚本。全部 Python 操作使用项目 `.venv` 并显式设置 `PYTHONDONTWRITEBYTECODE=1`。

本代理未安装第七版，未执行 VM，未操作测试 VM，未修改 AMFI 或 TCC。VM CDHash 未获本轮 AMFI 放行授权；第七版仅交给主任务用于正式离线更新。构建和打包成功不构成真实磁盘发布、事务恢复、启动或已提交后 kernel-only 回退的验收证据。
