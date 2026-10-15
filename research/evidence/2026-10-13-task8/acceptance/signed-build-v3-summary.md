# Task 8 第三版签名候选（2026-10-13）

第三版纳入真实 EXP producer 返回 alreadyApplied 时的已验证输出证据，以及 DSC 的准确 `.atlas` 文件分类修复。生产源码稳定后，构建副本统一同步当前工作区的 sources、scripts、vendor、dependencies、tools 和 tests，再执行完整 `make build`。

版本为 `2.6.20261015-local`，`CFBundleVersion` 为 `2026101310`。版本编号用于区分不可覆盖的本地版本，不表示日期。候选位于 `/private/tmp/vphone-task8-acceptance-build/core-candidate-v3/VPhone.bundle`，归档为同目录 `VPhone.zip`，SHA-256 为 `0f51dc797183f9236587e3ef85b7868840f1da553a05230e6a6a0708f55b3e1b`。

CLI CDHash 为 `f62699afdd673a2bca341c5414d524d232060b9c`，VM CDHash 为 `14d87bc3cf997469a27cb98514cf4b0e5c9a1e28`。`make build`、`check_bundle.py`、原生依赖闭包验证、严格递归签名验证、签名 CLI 的 generation-prepare 和 update-kernel 帮助命令均通过。

`build-source-v3-current-comparison.json` 记录工作区生产源与构建输入无不一致、无遗漏，显式版本和生成 BuildInfo 除外。构建后只有 `VPhoneBuildInfo.swift` 因脚本生成提交标识而改变；实际内容与 SHA-256 另存 `build-source-v3-generated-info.json`。`core-candidate-v3-manifest.json` 记录最终 Bundle 的逐文件哈希和验证命令。

首版和第二版 Bundle、ZIP、主要证据均逐文件复核一致，见 `v1-v2-preservation-after-v3.json`。第二版 app 另存为 `/private/tmp/vphone-task8-acceptance-build/signed-app-v2.app`。没有覆盖已安装的旧版本。

本构建子任务未安装系统存储，未执行 escalator，未改变 AMFI/TCC，也未操作 VM。真实更新及启动结果由主验收记录说明。
