# Task 8 第八版签名候选（2026-10-14）

第八版纳入 kernelcache 重打包时保留原始 IM4P description、PAYP 的修复，并在候选及发布后读回时比较整个替换 IM4P，proof 记录 `im4pSHA256`。支持来源压缩 NONE、LZFSE；LZSS 在调用 vendor decoder 前拒绝。此前启动失败的原因未查明，本次修复不能单独证明该失败的原因。

`payp-preservation/manifest.json` 的三项冻结源码已逐项核对：

| 对象 | SHA-256 |
| --- | --- |
| VPhoneKernelcacheSwap.swift | `03aafe9cdf1719a06c2eb531ba118188d21771c01f80744b099a862fe5f97b3f` |
| FirmwareKernelUpdate.swift | `2a8455d23b7601774caa833e24623b608053687a15aed515143bd61a7b18933b` |
| KernelcacheMetadataTests.swift | `f5df99ca4c9e879a119ec71e7a879f6b99301a4b5342f227cd21b2bc120cc3da` |

主任务已确认独立审查未发现阻断问题。`payp-preservation/summary.json` 记录最终定向回归退出 0，Swift Testing 汇总 37 tests / 6 suites，其中 `actualCandidateRegionUsesSourceFlow` 因指定 fixture 跳过；真实导出文件元数据测试实际执行。修复文件与基线逐字节重建验证通过，重建 IMG4 SHA-256 为 `5b90c5a0ee87bf810c7e90795d537265f39774fbf85c430263fd2f61fc41ce7a`。纯文件测试不代替真实更新、启动或提交后回退验收。

版本为 `2.6.20261020-local`，`CFBundleShortVersionString` 为 `2.6.20261020`，`CFBundleVersion` 为 `2026101403`。版本仅在独立构建目录 `/private/tmp/vphone-task8-acceptance-build` 覆盖，生产 `sources/Info.plist` 未由本代理修改。第七版 app 另存为该构建目录的 `signed-app-v7.app`，其逐文件 SHA-256 与复制前 app 一致。

冻结 Bundle 为 `/private/tmp/vphone-task8-acceptance-build/core-candidate-v8/VPhone.bundle`，ZIP 为同目录 `VPhone.zip`。ZIP SHA-256 为 `8d444a08377eb7a8e69ba011f56c30db7cabe11ce4a2f2a64fa15d00d98971c0`。

| 对象 | SHA-256 | CDHash |
| --- | --- | --- |
| CLI | `28192f56a228c856ecdda3f726d52f33e5ed3a0e852e772dd4855d32579c3b13` | `50708a1a65d7f81616c23fef1374ef9d1e93dee1` |
| VM | `a2da65a216de2dd184eaf64fc8e96b4badac26e0e66fac97852fa13b45bd9e77` | `ef76cc0baa68defb86e7b2edee8aee6acce46d87` |
| 历史 escalator | `12b964b4e2100110c525d68a677de26f62044e19fc1dc4ffe8b2ca6e1ce52fdc` | `67be7b719f9a643e8931b990ffc91dd4fed0a24a` |

获准的同范围提权完整 `make build` 退出 0，耗时 130.214 秒，证据为 `signed-build-v8.log/json`。打包退出 0，证据为 `core-candidate-v8-package.log/json`。完整构建包括 release 编译、CLI/VM 签名、guest payload 构建、资源封装、原生依赖闭包和最终签名。严格递归签名、单独入口签名、7 项 host Mach-O 闭包和资源检查均通过。ZIP 内 237 个文件的 SHA-256 与最终 Bundle 清单一致。

`build-source-v8-manifest.json` 记录 5635 个构建输入、生产源哈希、子模块和构建版本；清单 SHA-256 为 `5c31cad4b3cb9bf147d16d31865074e20cf8f9e7d0e54c9ec73382eac0b2cdd7`。相对第七版冻结生产源，仅上述三个文件改变。`build-source-v8-current-comparison.json` 记录生产源无遗漏或不一致。构建后只有自动生成的 `VPhoneBuildInfo.swift` 改为构建仓库实际提交 `0d22721f`，内容及 SHA-256 保存在 `build-source-v8-generated-info.json`；这是清单比较中明确允许的生成文件。其他输入未改变，无新增输入，生产源冻结后无变化，见 `build-source-v8-postbuild-comparison.json`。

`v1-v7-evidence-preservation-before-v8.json` 和 `v1-v7-preservation-after-v8.json` 证明既有候选证据、准备/复核脚本、七版 ZIP、Bundle 全部文件及文件集合均一致。`signed-app-v7-preservation-before-v8.json` 记录保存 app 的逐文件哈希，最终副本内容及文件集合复核通过。`core-candidate-v8-manifest.json` 记录完整签名、架构、命令和逐文件哈希；`core-candidate-v8-final-freeze.json` 记录最终冻结检查。新脚本为 `prepare-build-source-v8.py`、`package-core-candidate-v8.py` 和 `freeze-core-candidate-v8.py`，没有覆盖旧脚本。全部 Python 操作使用项目 `.venv` 并显式设置 `PYTHONDONTWRITEBYTECODE=1`。

本代理未安装第八版，未执行 VM，未操作测试 VM，未修改 AMFI 或 TCC。VM CDHash 未获本轮 AMFI 放行授权；第八版仅交给主任务用于正式离线更新。主任务计划通过正式 host 绑定切回已授权第四版，再执行启动验收。构建和打包成功不构成真实磁盘发布、事务恢复、启动或已提交后 kernel-only 回退的验收证据。
