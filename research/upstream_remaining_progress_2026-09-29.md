# 上游整合剩余阶段进展

用户本轮明确要求完成整个上游整合计划，范围为 P0 收尾、P2 收尾及 P3–P8 共 8 个阶段。本文记录实际完成的批次与仍缺少的实现、输入和验收；不把新增入口或构建通过记为阶段完成。P1c 导入及导入后启动继续按此前要求跳过，不扩大为所有 VM 验收均跳过。

## 本轮实现

| 阶段 | 实现或证据 | 仍未完成 |
| --- | --- | --- |
| P0 | 固定 SHA 的 597 个源码/工程路径清单；同名候选路径及 SHA-256；相机 64/256 字节 ABI 差异 | 五变体逐补丁语义/二进制对比、完整 VM 备份、配套版本台账 |
| P2 | API 上传/下载；6 个 guest dylib 独立构建、签名和清单；保留 classic 安装路径 | 完整 Core Bundle/Launchpad/helper 布局及运行时装载 |
| P3 | 独立 VM executable、CLI exec 转交、停止/DFU 身份、签名分离、双程序检查点指纹；显式原生 Restore 后端接线 | helper/收据及受控安装；真实恢复与 VM 生命周期 |
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

- 最初 `make test_fixtures` 因缺 17 个文件失败；本轮后续找到原始缓存并生成夹具，存在性检查及 13 项固件测试通过，详情见后文。
- 本轮检查数据卷约有 37 GiB 空闲。该数值不证明足够新镜像恢复、完整状态备份或最终磁盘验收；未删除 VM 或用户数据。
- 新签名 CLI 的 `--help` 退出 0，VM 程序 `--help` 被 SIGKILL。amfid 日志明确为 `AppleMobileFileIntegrityError Code=-424`：ad-hoc 签名包含受限 entitlements。随后用户明确授权对当前 VM cdhash 临时放行；执行结果见下文。
- 缺少可运行的新 v2 镜像，因此 Hook 加载、Irisin、Metal、相机、定位和应用行为均没有本轮真实证据。
- 宿主 app 的 Info.plist 仍为本地 `1.0 / 1`，没有改成 2.0.8；固定上游版本用于来源追踪，不代表本地产物已完整实现该版本。

## 验证与下一项

文件传输专项、候选 daemon 和 6 个 dylib 构建、进程拆分专项及 API 应用操作专项通过。

最终验证：Python 388 项通过；Swift Testing 704 项、98 suites 通过；XCTest 178 项、3 项跳过、0 失败；归档内存检查、RootHide loader links 和 124 项 camera data plane 检查通过。`make test` 的后一轮曾因两条旧提示断言失败；同步断言后，相关 40 项和完整 `make test_swift` 复跑通过。脚本语法检查 133 文件通过，actionlint 通过；远程 CI 尚未运行。`make build` 和最终 bundle 校验通过。源码与产物摘要另见 `upstream_artifact_ledger_2026-09-29.json`。

提交：`d57de8e` 文件传输、`c493d0a` guest 候选构建、`dc1af20` VM 进程、`b6ba71a` schema 边界、`f502e04` 应用 API 映射。最初完整回归发现测试 runner 调用数量和工具变更提示断言未同步，已修正并复验；不归因于运行环境。

原生 Restore 在现有 checkpoint runner 中的显式后端接线已完成，见 [P3 原生恢复记录](p3_native_restore_integration_2026-09-29.md)。下一项实现是 Core Bundle/helper 的受控安装和收据检查。实际恢复仍需独立 bundle、明确 ECID/UDID、空间核算和宿主执行准入。随后继续 P4 的 v2 prepare/CFW；不能直接把候选载荷覆盖到现有 VM。

## AMFI 临时执行准入验证

用户明确授权后，仅对 `2a6254e342d9cf2e4e32b12519e62c0fa8f30993` 启用 amfidont 临时放行，并启用该匹配对象的 `--spoof-apple`。运行日志确认 `Allow all: False`、路径清单为空、cdhash 清单只有该值，并记录该 cdhash 的验证放行和 isApple 处理。没有添加持久化清单。

相同产物的 `vphone-vm --help` 退出码由此前的 -9 变为 0，stdout/stderr 为空。本项证明该命令在临时放行期间成功退出，不证明 VM 启动、恢复或客户机行为通过验收。检查结束后已停止本次 amfidont 进程，工具报告从 amfid 分离；后续真实验收可在相同授权范围内按需再次启用。重新构建后必须重新核对 cdhash，不能将本次验证归于新产物。

检查记录：`research/artifacts/upstream-remaining-2026-09-29/vm-execution-authorized.json`。固件夹具、新 v2 镜像和空间条件仍需解决。

## 原始固件缓存核对

2026-09-29 在 `/Users/qcz3840/.vphone/ipsws` 找到两份原始固件，无需重新下载这组 26.1 输入：

- `iPhone17,3_26.1_23B85_Restore.ipsw`：10,778,507,403 字节，SHA-256 `8b72a4f0394ef49d63346eaf37a442751f70c5ec49ae0db7843c5e3b843cd85b`，与 Apple CDN HTTP 响应的摘要一致。
- `399b664dd623358c3de118ffc114e42dcd51c9309e751d43-727c4f5e2432.ipsw`：935,422,803 字节，SHA-256 `399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349`，与 Apple CDN 地址中的摘要一致。

两份 ZIP 的 BuildManifest 均可读取，版本为 26.1 / 23B85。此前缺少 `ipsws/patch_refactor_input` 的检查结果只适用于夹具目录，不证明原始固件不存在。本次未重新下载，也未解包恢复镜像。当时待完成的是夹具提取、参考记录来源确认，以及独立 v2 镜像的创建和验收；夹具已在后续步骤补齐，见下一节。此批数据不代表其他版本组合均具备输入。

检查证据：`research/artifacts/upstream-remaining-2026-09-29/firmware-cache-check.json`。本次磁盘检查约 35 GiB 空闲；待清理的 VM 目录报告分配量约 21 GiB 和 28 GiB，APFS 共享块使这两个数值不能直接作为可释放空间之和。

## 已授权 VM 清理与固件夹具恢复

用户明确确认后，持有三个目录的独占锁并检查打开文件，删除 `vm-2607-rig2`、`vm-2607-p1c-20260926` 和空目录 `vm-p1c-import-validation`。占用检查排除清理进程自身用于持锁的目录描述符，未排除其他进程。`vm-2607` 保留，其根级文件 inode、大小和 mtime 未变；未重新计算整个磁盘内容摘要。可用空间从 37,666,824,192 增至 62,267,236,352 字节，本次观测增加 24,600,412,160 字节（约 22.9 GiB）。原始固件缓存和既有研究记录保留。证据为 `vm-cleanup.json`。

新增 `scripts/prepare_firmware_fixtures.py`，从已核对的 PCC 26.1 / 23B85 缓存提取输入，在临时目录中运行固定提交 `08eb9d260f6494549220c3109eafd18da9fa75f4` 的 Python 参考实现。AVPBooter 来自当前宿主 Virtualization.framework，摘要单独记录。Python 实现不恢复到生产脚本目录；输出目录已存在时拒绝覆盖。`provenance.json` 记录来源、工具包版本及 17 文件摘要。

首次对比发现历史导出脚本使用 `IBootPatcher` 默认大写标签，与当时 `fw_patch.py` 显式传入的 `Loaded iBSS` / `Loaded iBEC` 不同；生成器改为实际入口参数。AVP 使用真实 `patch_avpbooter` 的写入记录，未使用历史导出器的另一套锚点。没有修改当前 Swift 补丁字节，也没有用 Swift 输出生成参考结果。最终 `make test_firmware`：13 项、11 suites 全部通过；普通内核 28 条、JB 内核 84 条逐字节匹配。该结果只覆盖本批固定输入，不证明恢复、启动或所有固件组合可用。

## 显式原生恢复与本轮回归

`vm create --restore-backend native` 已接入，默认 Python 路径及旧检查点编码保持兼容。身份限制、隔离子进程、超时/取消、重跑规则及未验证范围见 [P3 原生恢复记录](p3_native_restore_integration_2026-09-29.md)。

完整无固件回归：Python 388 项、Swift Testing 711 项/100 suites、XCTest 178 项通过（其中 3 项跳过）；归档内存检查、RootHide loader-link 检查和 124 项相机 data-plane 检查通过。后补的 3 项夹具生成拒绝路径测试单独通过。最后调整 worker 继承信号处理后，91 项相关 Swift 测试复跑通过。

PCC 26.1 / 23B85 在独立测试目录执行 regular/dev/jb/exp 四变体完整补丁流水线，结构化报告均通过；分别为 29/34/68/88 个方法、58/70/152/178 条字节记录。less 是独立的根权限/ramdisk 路径，本轮没有执行，不从上述四变体推导通过。其他 cloudOS 版本未下载、未测试。

新增证据：`remaining-regression.log`、`native-restore-tests-final.log`、`firmware-variants.log` 及 `firmware-variants/23B85/*/report.json`。本批提交为 `37e5518` 和 `b31f109`。这些测试均未恢复或启动 VM；v2 镜像、helper 安装和其余上游阶段继续保持未完成。

`b31f109` 的 `make build` 和 bundle 签名/资源/entitlements 校验通过；138 个脚本语法检查通过。打包 CLI 的 create 帮助包含原生后端选项；native worker 对 ECID 0 返回 64，在临时 bundle 中未产生文件。产物与日志摘要见 [本批产物记录](upstream_native_restore_artifacts_2026-09-29.json)。新 VM cdhash 为 `775621e731b754b9d8a1862b77fbbd114353b5d9`；本轮未对它执行 AMFI 放行或 VM 启动，此前旧产物的执行准入证据不适用于它。
