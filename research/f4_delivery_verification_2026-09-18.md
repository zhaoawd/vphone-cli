# F4：文档与交付核对记录（2026-09-18）

清单定义见 [项目迭代清单 F4](project_iteration_checklist_2026-09-08.md)。本轮核对分三部分只读审计加一次文档修改，未启动 VM，未刷写固件。

本文中"事实"指本轮命令输出或文件中可直接读到的内容；"推断"指由事实推出但未经测量的结论；"待验证假设"需要进一步实验确认。

## 1. 核对范围与方法

| 部分 | 对象 | 方法 |
| --- | --- | --- |
| 文档一致性 | `README.md`、`docs/README_{zh,ja,ko}.md`、`AGENTS.md`、`CONTEXT.md` | 文档中的目录、模块、命令、变体、权限与依赖说明逐条对照 `Package.swift`、`Makefile`、`sources/`、`requirements.txt`；文档中出现的仓库内路径逐个 `test -e` |
| 支持范围与计数 | `firmware_compatibility.json/.md`、`f1_support_matrix_2026-09-17.json/.md`、`f1_known_limits_2026-09-17.json`、`0_binary_patch_comparison.md`、`.github/workflows/` | 按来源分列计数，不合并口径不同的数字 |
| 工作项证据 | 清单 A1–F4 共 28 项 | `git log`、`git show --stat`、`git merge-base --is-ancestor` 定位提交；验收文档逐个 `test -e` |

## 2. 结果

### 2.1 文档与代码一致

事实：模块目录、`make` 目标、CLI 子命令与选项、五个变体到 `fw_patch*`/`cfw_install*` 的映射、平台与语言版本、entitlements 与 venv 依赖说明，与代码和构建系统一致。六份文档中出现的仓库内路径 `test -e` 全部存在。

### 2.2 本轮修改的偏差（提交 `6d9dd03`）

| 问题 | 现象 | 处理 |
| --- | --- | --- |
| 失效在页锚点 | 四份 README 的 `~/.vphone/venv/` 行链接到 `#python-runtime`（zh/ja/ko 为本地化变体），四份文件均无对应标题 | 去链接保留文字。该锚点的历史来源未查明 |
| 本地化 FAQ 缺条目 | `README.md` 有 7 条 FAQ，zh/ja/ko 各 6 条，缺 `ldid-procursus` 重签名卡死条目 | 按英文原条目翻译补齐，保留全部证据要点 |
| 变体计数表无口径标注 | 四份 README 变体表的引导链 4/42/53/113/141 与 CFW 2/10/12/14/18 未标注适用固件组合与日期 | 表下加口径说明并链接带日期的证据文档。**表内数字未改动**：其来源与适用组合未查明，改动会引入原文没有的事实 |
| headless 能力未记录 | 四份 README 未区分 GUI 与 headless 启动 | 补充：`--headless` 启动时能力快照报告 `screen_available=false`，screenshot、touch、swipe 不可用；硬件按键与剪贴板可用。`camera_present` 的门控为 `cameraServer?.isConnected` 与 `vcam_receipt_v3`，与 `screen_available` 无关，未列入 |
| 故障恢复命令未记录 | 四份 README 未记录 `doctor`、`vm stop --force`、`fw patch --recover`、`vm create --resume`/`create-status` | 新增 Recovery/恢复章节，命令名与参数逐条对照源码确认。离线操作占用保护无独立用户命令，以散文说明其作用范围 |
| 支持范围未记录 | 四份 README 无按证据日期陈述的支持范围 | 新增 Support Scope/支持范围章节，来源为 2026-09-09 兼容性清单与 2026-09-17 F1 矩阵，均标注日期 |
| CLI 帮助文案与产物不符 | `vm export`/`vm import` 的 abstract 写 `.tgz archive`，实际产物为 `.tzst`（fast）或 `.txz`（max），见 `VPhoneBundleOps.swift:243-244` | 改为与实际一致的表述，`swift build` 通过 |

### 2.3 计数与支持范围

三套计数口径不同，不合并：

| 来源 | 口径 | 数值 |
| --- | --- | --- |
| `firmware_compatibility.md` §6（2026-09-09） | 变体 × 阶段组合数 | code_selectable 各 23；patch_verified less 1、regular 7、dev 7、jb 10、exp 7；boot_verified 全 0；capability_verified jb 3、exp 1 |
| `f1_support_matrix_2026-09-17.md` | 创建阶段补丁记录数 | P 组 regular 58、dev 70、jb 152、exp 178、less 26；N 组 jb-frida 157、exp-frida 183 |
| `0_binary_patch_comparison.md` Summary（2026-09-10） | 引导链总计 / 含 CFW 总计 | 46/58/117/132 与 56/70/132/163（regular/dev/jb/exp） |

事实：N 组 iOS 构建为 `23G82`（非 catalog，本地路径指定），与兼容性清单中 exp capability 记录的 `23G83` 是不同构建，两处不合并。

事实：`0_binary_patch_comparison.md` 的 Summary 表、Cross-Version Snapshot 表与 Ramdisk Variant Matrix 表无逐格日期与证据链接。该文档引用的 `.md` 链接经存在性核对全部存在。

### 2.4 28 个工作项的提交与验收

事实：清单引用的各项主验收文档 `test -e` 全部存在，未发现引用但不存在的文件。清单写出的 21 个显式提交短 hash 经 `git log -1` 全部命中。未发现清单状态与证据不符需要标注差异的项。逐项表见本轮审计记录（工作项 | 清单状态 | 关键提交 | 验收记录 | 证据缺口）。

## 3. 远端工作流证据（对清单旧表述的修正）

清单第 54 行记"D1/D2 远端 checks/release 仍缺实际运行证据"，2026-09-14 的条目记"远端工作流未运行"。本轮用只读 GitHub API 查询（`gh run list -R zhaoawd/vphone-cli`）得到的事实与该表述不同：

| 项目 | 事实 |
| --- | --- |
| `checks` workflow | **有实际运行记录**。最近 7 次运行失败（2026-09-12 至 2026-09-18），最后一次成功为 2026-09-12 的 run `34679220172` |
| 最新失败运行 | `35290927966`，2026-09-18T00:22Z，`headSha` = `c6b38c7`，即 `origin/codex/autophone-location-multivm-integration` 当前 head |
| `release` workflow | 在 `zhaoawd/vphone-cli` **无运行记录**（`gh run list --workflow=release` 返回空）。上游 `Lakr233/vphone-cli` 的 v1.0.x 发布运行不是本仓库的证据 |
| 本地未推送提交 | `codex/autophone-location-multivm-integration` 领先 origin 22 个提交（F3 批次 `e0dfc04..7de013f`）；`autophone-location-multivm-integration` 领先 2 个。这些改动在远端未经过 `checks` |

因此"远端 checks 无实际运行证据"不成立，应改为"远端 checks 自 2026-09-12 起持续失败"；"远端 release 无运行证据"仍成立。

失败内容（run `35290927966`）：Python 套件通过（`Ran 325 tests ... OK`）；`swift test --skip FirmwareIntegrationTests` 的 462 个测试报 3 个 issue。诊断见 [F4-D CI 失败诊断](f4_ci_failure_diagnosis_2026-09-18.md)，结论摘要：

| 失败项 | 判定 | 本机复现 |
| --- | --- | --- |
| `SystemLocationControllerTests.testWatchdogHoldsLastAcceptedCoordinate` | 测试缺陷：断言前的固定 40 毫秒等待无同步保证；`Index out of range` 是断言失败后继续执行到 `deliveries[1]` 的连带崩溃，该崩溃终止 xctest 进程 | 未自然复现；受控实验逐行复刻了 CI 原文 |
| `CreateLiveStagesTests.verifierWaitsForARealBundleLockHolderToRelease` | 测试缺陷：用 `DispatchQueue.global().asyncAfter` 释放锁，依赖全局并发队列调度时机 | 未复现。CI 上延迟超过 10 秒为待验证假设 |
| `DiagnosticsTests.boundedRunnerTimesOutAndClosesStdin` | **产品缺陷**：`VPhoneProcessRunner.swift:89-97` 的超时唯一执行路径排入 `DispatchQueue.global()` 并带 `guard target.isRunning else { return }`；队列饱和时超时被延后或完全不生效 | 整套 11 次复现 2 次；定向饱和实验得到 `timedOut=false elapsed=5.0118`，与 CI 数值一致 |

事实：三项失败与 F3 批次的六个提交无关。`git merge-base --is-ancestor 2011bc7 799d168` 成立，失败运行所在提交是 F3 批次最早提交的祖先；F3 批次改动的文件不含这三项涉及的文件。

推断：第 2、3 项涉及的代码由 2026-09-17 的 `99da011`（D4）与 `c2fac55`（D5）引入，晚于最后一次成功运行，与失败起始时间一致。第 1 项的测试自 2026-08-19 起即为现状，其在本次被触发的具体条件未查明。

事实：`VPhoneProcessRunner` 的同一实现还用于 `VPhoneCreateLiveStages.swift` 的 `recoveryReachable`、`attachedImages` 等探测路径，该缺陷的影响不限于测试。

## 4. 本轮未完成

1. `VPhoneProcessRunner` 的超时缺陷未修复。诊断记录中有经本机验证的改法（超时改由独立 `Thread` 轮询），未应用。
2. 三项测试失败的改法未在 CI 上验证。
3. 变体计数表 4/42/53/113/141 与 2/10/12/14/18 的来源与适用组合未查明。
4. `0_binary_patch_comparison.md` 的三个汇总表仍无逐格日期与证据链接。
5. `release` workflow 在本仓库无运行证据。取得该证据需要发布流程实际运行，本轮未执行。
6. F1 的未解决问题 O1–O3 与 F3 的遗留项需要 VM 与客户机，不在本轮范围。
