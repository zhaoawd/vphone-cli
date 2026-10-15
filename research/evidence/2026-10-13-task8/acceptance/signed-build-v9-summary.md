# Task 8 第九版签名候选（2026-10-14）

第九版纳入提交后 kernel-only 回退实现，包括公开历史选择、预览和 canonical UUID 回退入口、同 producer 资格校验、schema 4 双计划、当前磁盘候选发布与读回，以及回退事务自身的中断恢复。`VPhoneKernelRollbackProtocol=vphone.kernel-rollback.v1` 独立声明回退能力。旧 V8 缺新证据合同与跨 Bundle producer 回退继续拒绝。完整设计、约束及测试范围见 `kernel-rollback/implementation.md`、`summary.json` 和 `code-independent-review.md/json`。

`kernel-rollback/manifest.json` 冻结于 `2026-10-14T03:31:38.166905+00:00`，其 16 个源码和测试文件在构建前逐项核对大小与 SHA-256，全部一致。相对 V8 冻结生产输入，全部新增和变化集合恰好为这 16 项。独立代码和需求审查未发现阻断项，允许进入完整签名构建及限定范围真实验收。

既有定向回归退出 0：101 个选中函数中 98 个执行通过、3 个 fixture 跳过，共 13 个 suite；rollback suite 实际执行 9 个函数、34 个场景。Python Bundle protocol 7 项通过。实际两计划产生不同 payload，当前 System DSC 检查在单独证据中通过。本构建代理未重复测试，也未使用共享测试 scratch。

版本为 `2.6.20261021-local`，`CFBundleShortVersionString` 为 `2.6.20261021`，`CFBundleVersion` 为 `2026101404`。版本仅在独立构建目录 `/private/tmp/vphone-task8-acceptance-build` 覆盖。生产 `sources/Info.plist` 已由实施者加入 rollback marker，本代理未修改生产文件。此前第八版 app 另存为该构建目录的 `signed-app-v8.app`，逐文件 SHA-256 与复制前 app 一致。

冻结 Bundle 为 `/private/tmp/vphone-task8-acceptance-build/core-candidate-v9/VPhone.bundle`，ZIP 为同目录 `VPhone.zip`。ZIP SHA-256 为 `0506d85339229a1691a43bbac105ca63185afa1ccfccf5d1bd195d7bced58d56`。

| 对象 | SHA-256 | CDHash |
| --- | --- | --- |
| CLI | `e1c6ca75c19966ec8bcada05ca235c1e5019c572570b64e8ebed041f0d14da76` | `ffe84ffa603342fd36fd67c12b8b262d0b81493b` |
| VM | `3072203a8f8846dfd3239fb14b825523e6230bfa16da08de8f65e0b2dfaea74c` | `36ad5d8d001392beec52411123190ae5560fc6bf` |
| 历史 escalator | `12b964b4e2100110c525d68a677de26f62044e19fc1dc4ffe8b2ca6e1ce52fdc` | `67be7b719f9a643e8931b990ffc91dd4fed0a24a` |

获准的同范围提权完整 `make build` 退出 0，耗时 139.351 秒，证据为 `signed-build-v9.log/json`。打包退出 0，证据为 `core-candidate-v9-package.log/json`。完整构建包括 release 编译、CLI/VM 签名、guest payload 构建、资源封装、原生依赖闭包和最终签名。严格递归签名、单独入口签名、7 项 host Mach-O 闭包和资源检查均通过。Bundle checker 强制核验 update 和 rollback 两项协议；最终冻结额外核对两项实际 Info.plist 值。ZIP 内 237 个文件的 SHA-256 与最终 Bundle 清单一致。

`build-source-v9-manifest.json` 保存 5638 个构建输入及全部生产输入 SHA-256、子模块、Capstone 未提交差异、rollback 冻结清单摘要和构建版本；清单 SHA-256 为 `944b0641fe5f69c8f76315d6e84f6d0833893cb44efd6e9879232b7771c757c8`。`build-source-v9-current-comparison.json` 记录生产源无遗漏或不一致。构建后只有自动生成的 `VPhoneBuildInfo.swift` 改为构建仓库实际提交 `0d22721f`，内容及 SHA-256 保存在 `build-source-v9-generated-info.json`；这是清单比较中明确允许的生成文件。其他输入未改变，无新增输入，生产源冻结后无变化，见 `build-source-v9-postbuild-comparison.json`。

`v1-v8-evidence-preservation-before-v9.json` 和 `v1-v8-preservation-after-v9.json` 证明既有候选证据、准备/复核脚本、八版 ZIP、Bundle 全部文件及文件集合均一致。`signed-app-v8-preservation-before-v9.json` 记录保存 app 的逐文件哈希，最终副本内容及文件集合复核通过。`core-candidate-v9-manifest.json` 记录签名、架构、命令和逐文件哈希；`core-candidate-v9-final-freeze.json` 记录最终冻结检查。新脚本为 `prepare-build-source-v9.py`、`package-core-candidate-v9.py` 和 `freeze-core-candidate-v9.py`，没有覆盖旧脚本。全部 Python 操作使用项目 `.venv` 并显式设置 `PYTHONDONTWRITEBYTECODE=1`。

本代理未安装第九版，未执行 VM，未操作 Store、测试 VM、共享测试 scratch、AMFI 或 TCC。第九版仅交给主任务作为离线 CLI producer；真实验收仅使用已授权第四版 VM。签名构建成功不构成真实不同 payload 发布、提交后回退、回退后正常启动或 guest marker 保持的验收证据。
