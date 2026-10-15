# Task 8 第二版签名候选（2026-10-13）

真实 IPSW 准备发现 Foundation URL 的目录末尾斜杠影响相等比较。第二版纳入 `FirmwareGeneration.swift` 的规范路径比较修复及对应回归测试。已重新构建并签名，版本为 `2.6.20261014-local`，`CFBundleVersion` 为 `202610139`。版本字符串中的数值用于区分不可覆盖的本地版本，不表示本记录日期。

最终目录为 `/private/tmp/vphone-task8-acceptance-build/core-candidate-v2/VPhone.bundle`；归档为同目录的 `VPhone.zip`，SHA-256 为 `102711d0db8f08aed749713fbc057e77304389e99ee0526b44c5537bd1cc9a17`。CLI CDHash 为 `4465083ba0e222ca5e94d59b223951c9d0adfca3`，VM CDHash 为 `e4260a03082ac4ffdf79eee2f7f96e1ecfd80361`。

`make build`、`check_bundle.py`、原生依赖闭包验证、严格递归签名验证及两个入口的帮助命令通过。`core-candidate-v2-manifest.json` 记录完整哈希和检查。`build-source-v2-current-comparison.json` 证明除版本和自动生成 BuildInfo 外，当前源码清单没有不一致或遗漏。

首版证据、Bundle 和 ZIP 均保留。`v1-preservation-after-v2.json` 记录第二版完成后对首版所有 Bundle 文件、ZIP 和主要证据的复核，结果全部一致。首版 app 另存为 `/private/tmp/vphone-task8-acceptance-build/signed-app-v1.app`。

首次合并准备和构建的调用被自动审批拒绝，理由是担心覆盖首版 manifest。该调用未执行。随后先单独冻结首版证据哈希，使用明确独立的 v2 文件路径准备新清单，复核旧哈希不变，再单独申请构建并获准。没有覆盖旧证据。

本构建子任务未安装系统存储，未执行 escalator，未改变 AMFI/TCC，也未操作 VM。真实准备、更新及启动结果由主验收记录另行说明。
