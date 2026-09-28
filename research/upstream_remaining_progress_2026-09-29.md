# 上游整合剩余阶段进展

用户本轮明确要求完成整个上游整合计划，范围为 P0 收尾、P2 收尾及 P3–P8 共 8 个阶段。本文记录实际完成的批次与仍缺少的实现、输入和验收；不把新增入口或构建通过记为阶段完成。P1c 导入及导入后启动继续按此前要求跳过，不扩大为所有 VM 验收均跳过。

## 本轮实现

| 阶段 | 实现或证据 | 仍未完成 |
| --- | --- | --- |
| P0 | 固定 SHA 的 597 个源码/工程路径清单；同名候选路径及 SHA-256；相机 64/256 字节 ABI 差异 | 五变体逐补丁语义/二进制对比、完整 VM 备份、配套版本台账 |
| P2 | API 上传/下载；6 个 guest dylib 独立构建、签名和清单；保留 classic 安装路径 | 完整 Core Bundle/Launchpad/helper 布局及运行时装载 |
| P3 | 独立 VM executable、CLI exec 转交、停止/DFU 身份、签名分离、双程序检查点指纹 | 原生 Restore 阶段接线、helper/收据及受控安装；真实 VM 生命周期 |
| P4 | 明确拒绝带 schemaVersion 的配置被旧后端误读；扫描返回原因且不改写配置 | 显式新建 v2 bundle、原生 prepare/CFW、配套恢复镜像及验收 |
| P5 | 显式 API app_launch/app_terminate；保留前台验证、屏幕响应及失败后的操作不确定性 | IPA/TIPA、shell、输入、定位 owner 协议、相机 v3、其余接口与业务验收 |
| P6 | 固定组件候选和宿主 loader-link 测试提供部分前置输入 | Irisin 固定 release、可信安装/卸载范围、Rootless/RootHide 与 tweak 实测 |
| P7 | 本轮没有完成检查面板、Launchpad 或本地化迁移 | 检查面板、版本诊断、日志、窗口生命周期及多 VM 验收 |
| P8 | fast runner 加入客户机 C 测试；CI 增加两个独立候选构建 | 完整分发/收据、公证或明确未公证说明、最终产物 F1/F2/F3 与真实验收 |

阶段数量仍为 8 个未全部完成；部分阶段已有新增代码。后续必须继续按实施计划，而不是把本轮批次标成整个计划完成。

## P0 来源与测试映射

来源为 `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3`。清单 [upstream_source_inventory_2026-09-29.json](upstream_source_inventory_2026-09-29.json) 覆盖 VPhoneDaemon 35、VPhoneExecutable 395、VPhoneGuestComponents 28、VPhoneKit 80、VPhoneLaunchpad 59 个路径。清单生成时，285 个路径找到本地同名候选，其中 158 个存在字节相同候选。这是文件名和字节比对，不能据此推断语义兼容、全部迁移或应用可用。

| 上游对象 | 本地入口 | 保留条件或差异 |
| --- | --- | --- |
| VPhoneCommand 的 FirmwarePatcher | sources/FirmwarePatcher | 五变体、PatchOutcome、事务和消融保留；逐补丁验证未完成 |
| VPhoneCommand 的 Sign/Restore 与 VPhoneKit Archive | VPhoneSign、VPhoneRestore、VPhoneArchiveKit | 原有显式入口及默认恢复后端保留 |
| VPhoneVirtualization | vphone-vm + 现有 VM 实现 | 迁入独立进程边界；没有整体替换运行层 |
| VPhoneCoreKit | VPhoneCore | 本地锁、PID/启动时间、检查点、离线保护保留 |
| VPhoneDaemon | sources/VPhoneDaemon | 1339 候选，未安装；本地增加身份和文件事务 |
| VPhoneExternalAccessKit | VPhoneAPIKit + HostAPICommands | 本地显式协议适配，不能宣称 SDK 产品等价 |
| VPhoneGuestComponents | 同名 sources 子目录 | 输出隔离；camera ABI 尚未统一 |
| VPhoneLaunchpad/Helper/Shared | 尚未迁入 | 不把 CLI app 当作完成 Launchpad 融合 |

上游五个测试 scheme 分别为 FirmwarePatcherTests、VPhoneSignTests、VPhoneRestoreTests、VPhoneArchiveKitTests、VPhoneCoreKitTests。本地前三个名称对应 SwiftPM 目标；ArchiveKit 为本地 VPhoneArchiveKitTests；CoreKit 对应的保留合约由 VPhoneCoreTests 验证，不能据同类模块名认为测试内容完全相同。`FirmwareIntegrationTests` 始终独立于 fast suite，Python suite 与 F1/F2/F3 工具保留。daemon 的 Wire 测试在 SwiftPM 执行，iOS 候选由 Xcode 独立构建。

## 实际阻塞与未验证范围

- `make test_fixtures` 失败：默认目录缺全部 17 个要求文件，固件测试未执行。已向用户询问可用输入路径。
- 本轮检查数据卷约有 37 GiB 空闲。该数值不证明足够新镜像恢复、完整状态备份或最终磁盘验收；未删除 VM 或用户数据。
- 新签名 CLI 的 `--help` 退出 0，VM 程序 `--help` 被 SIGKILL。amfid 日志明确为 `AppleMobileFileIntegrityError Code=-424`：ad-hoc 签名包含受限 entitlements。没有修改 AMFI 策略，已询问是否允许对最终 VM cdhash 临时放行。
- 缺少可运行的新 v2 镜像，因此 Hook 加载、Irisin、Metal、相机、定位和应用行为均没有本轮真实证据。
- 宿主 app 的 Info.plist 仍为本地 `1.0 / 1`，没有改成 2.0.8；固定上游版本用于来源追踪，不代表本地产物已完整实现该版本。

## 验证与下一项

文件传输专项、候选 daemon 和 6 个 dylib 构建、进程拆分专项及 API 应用操作专项通过。

最终验证：Python 388 项通过；Swift Testing 704 项、98 suites 通过；XCTest 178 项、3 项跳过、0 失败；归档内存检查、RootHide loader links 和 124 项 camera data plane 检查通过。`make test` 的后一轮曾因两条旧提示断言失败；同步断言后，相关 40 项和完整 `make test_swift` 复跑通过。脚本语法检查 133 文件通过，actionlint 通过；远程 CI 尚未运行。`make build` 和最终 bundle 校验通过。源码与产物摘要另见 `upstream_artifact_ledger_2026-09-29.json`。

提交：`d57de8e` 文件传输、`c493d0a` guest 候选构建、`dc1af20` VM 进程、`b6ba71a` schema 边界、`f502e04` 应用 API 映射。最初完整回归发现测试 runner 调用数量和工具变更提示断言未同步，已修正并复验；不归因于运行环境。

下一项实现是原生 Restore 在现有 checkpoint runner 中的显式后端接线，以及 Core Bundle/helper 的受控安装和收据检查。实际恢复仍需独立 bundle、明确 ECID/UDID、可用固件、空间和宿主执行准入。随后继续 P4 的 v2 prepare/CFW；不能直接把候选载荷覆盖到现有 VM。
