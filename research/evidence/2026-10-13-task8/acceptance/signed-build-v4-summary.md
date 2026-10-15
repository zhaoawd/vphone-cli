# Task 8 第四版签名候选（2026-10-13）

第四版纳入真实 APFS 卷关联修复。与第三版相比，同步内容只改变 `FirmwareInstalledReadback.swift` 及对应测试；另修改候选版本。构建与 Python 验证均显式使用 `PYTHONDONTWRITEBYTECODE=1`。没有为未改变的生产文件刷新时间戳。

版本为 `2.6.20261016-local`，`CFBundleVersion` 为 `2026101311`。版本编号用于区分不可覆盖的本地版本。候选目录为 `/private/tmp/vphone-task8-acceptance-build/core-candidate-v4/VPhone.bundle`，归档为同目录 `VPhone.zip`，SHA-256 为 `96b608f1ac3722516d02c41281c9d102cb4b983b4c306570c408056e425cf1c3`。

CLI CDHash 为 `eba1b73c59773863934410a182bfd92a640425d5`；VM CDHash 为 `43c00d51b4c7f07a5feba006f3c244edbac39cea`。完整 `make build`、`check_bundle.py`、原生依赖闭包、严格递归签名验证及入口帮助命令通过。

VM 通过 `VPhoneVMEntry -> vphone-cli -> FirmwarePatcher` 链接共享实现模块。本轮 VM 字节、CDHash 和 __text 内容均与第三版不同，entitlements 保持一致；`v3-v4-vm-identity-comparison.json` 记录实际证据。没有将第三版 VM 人工替回第四版 Bundle。第四版未执行 AMFI 放行，也未启动。

`build-source-v4-current-comparison.json` 记录工作区生产源无遗漏或不一致，显式版本和生成 BuildInfo 除外；构建后的源码清单也未改变，见 `build-source-v4-postbuild-comparison.json`。`core-candidate-v4-manifest.json` 包含最终逐文件哈希和完整验证命令。

第一版至第三版 Bundle、ZIP 和主要证据全部复核一致，见 `v1-v3-preservation-after-v4.json`。第三版 app 另存于 `/private/tmp/vphone-task8-acceptance-build/signed-app-v3.app`。本构建子任务未安装系统存储、执行 escalator、修改 AMFI/TCC 或操作 VM。
