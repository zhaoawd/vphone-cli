# Task 8 第五版签名候选（2026-10-13）

第五版纳入系统路径别名修复。签名工件代理作为未实施该修改的审查者，独立核对了第四版与当前生产差异、精确设备/UUID/读写状态/目录身份约束、拒绝矩阵和完整真实候选读写链 GREEN。未发现阻断问题，见 `mount-path-alias-independent-review.md` 与同名 JSON。

版本为 `2.6.20261017-local`，`CFBundleVersion` 为 `2026101312`。候选目录为 `/private/tmp/vphone-task8-acceptance-build/core-candidate-v5/VPhone.bundle`，ZIP 为同目录 `VPhone.zip`，SHA-256 为 `bd489d3cb1828d1868118a7bba9a82fdb668f4a0b981f7164bc81a61731b4008`。

CLI CDHash 为 `1e220b779807696d8189206a4a83d097e60c4018`；VM CDHash 为 `5ab540e7f73f17d68aefa20838326456a5178d48`。完整 `make build`、最终资源检查、原生依赖闭包、严格递归签名验证均通过。`core-candidate-v5-manifest.json` 记录完整结果及逐文件哈希。

全部 Python 构建与打包操作显式使用 `PYTHONDONTWRITEBYTECODE=1`。生产源与当前工作区比较无遗漏或不一致，版本和生成 BuildInfo 除外；构建后源码文件哈希也无变化。第一至第四版 Bundle、ZIP、关键证据全部复核一致，见 `v1-v4-preservation-after-v5.json`。第四版 app 另存为 `/private/tmp/vphone-task8-acceptance-build/signed-app-v4.app`。

按用户交接要求，本代理只收尾现有第五版构建与证据。所有构建和打包进程已结束。第五版未安装系统 store，未用于真实更新，也未执行 VM 或 AMFI。后续计划是使用第五版可信离线工具更新内核，正式重新绑定已授权第四版 host/VM，保留第五版 kernel 来源，再执行启动验收；此计划尚未由本代理实施。
