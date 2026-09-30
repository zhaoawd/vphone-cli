# 上游 2.2.3 差异分析与本地对账

核对日期：2026-10-01（Asia/Shanghai）。固定目标：`a969cd5d9206932dc1a2797348027fbc7d0ee347`。本报告与[实施计划](upstream_implementation_plan.md)、[执行清单](upstream_execution_tasks_2026-10-01.md)配套。

## 1. 结果与证据范围

上游 `main` 与 `2.2.3` 在本次 Git 获取时指向同一提交。本地 HEAD 为 `ef6f40842e1b53524cd038a84038c36d892f7031`，分支为 `codex/upstream-4bab3b7-integration`。原生 classic prepare、创建检查点及相关测试仍有未提交变动。实施目标更新为 2.2.3；本地产物版本和支持范围不能由该目标推定。

引用对话为[修订整合计划](chatgpt-conversation://6abd281d-82a8-83ee-adde-df7806a26f7a)。本次读取了对话记录，但没有取得其中 sandbox 下载链接对应的原始 Markdown、ZIP、`tasks.json` 和采集脚本。本文及执行清单由当前仓库和固定上游源码重新建立；不声称逐字复现原执行包。

本次完成 Git 统计、关键源码核对及旧计划对账。没有执行代码迁移、构建、工程测试、VM 备份、恢复或启动。引用的历史测试结果保留原日期和范围。本次没有逐一分析 482 个文件的运行语义，也没有进行内核指令、符号或逐补丁二进制分析。

## 2. 固定基线与统计

| 对象 | 结果 | 证据 |
| --- | --- | --- |
| 原目标 2.0.8 | `9d218dedf58d4b19db5e51c8b584c1f14a96eee3` | tag 对象 `03b6bbe72838f6393e7335e42f2e8134e5566ab8` 解引用 |
| 上次对话目标 2.2.2 | `d3403e510fd1126e9d99e7686f39465e5ab586e8` | 固定 tag 与提交对象 |
| 本次目标 2.2.3 | `a969cd5d9206932dc1a2797348027fbc7d0ee347` | 固定 tag 与提交对象 |
| 当前本地 HEAD | `ef6f40842e1b53524cd038a84038c36d892f7031` | 当前工作区 `git rev-parse HEAD` |
| 本地与目标共同祖先 | `87f796c62a7cb385cd37afce121f6e222d83e5b5` | 临时裸仓库 `git merge-base` |
| 本地/上游各自独有提交 | 212 / 348 | `git rev-list --left-right --count HEAD...目标`；不是待移植任务数量 |
| 暂存区 | 本次采集时无差异 | 未暂存和未跟踪文件另列于基线 JSON |

统计使用端点差异 `git diff --find-renames --numstat -z`，排除仓库根目录 `TODO.md`。提交数使用 `git rev-list --count`，不按路径过滤。

| 比较范围 | 提交 | 非合并提交 | 变更文件 | 新增行 | 删除行 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 2.0.8 → 2.2.2 | 119 | 117 | 482 | 40,281 | 12,020 |
| 2.2.2 → 2.2.3 | 5 | 5 | 5 | 313 | 2,833 |
| 2.0.8 → 2.2.3 | 124 | 122 | 482 | 37,656 | 11,915 |

最新端点净增加 25,741 行，文本增删合计 49,571 行。文件数仍为 482 是本次实测结果；不是沿用旧值。端点统计不能逐段相加，文件可能在多个范围重复变化。

另以 `--no-renames` 交叉采集：2.0.8 → 2.2.3 为 567 个文件、新增 52,870 行、删除 27,129 行。两种口径的差异来自重命名识别设置，不据此判断功能数量或工作量。完整路径、统计和提交清单见[基线证据](artifacts/upstream-review-2026-10-01/baseline.json)。

## 3. 2.2.2 → 2.2.3 的五个提交

| 提交 | 变化 | 本地安排 |
| --- | --- | --- |
| `ded81cb2` | 当前 Launchpad sheet 关闭后再打开下一 sheet | P7 / T26，核对关闭与安装进度时序 |
| `0b463433` | 补齐 Launchpad 残留英文的翻译 | P7 / T26，迁入实际使用的字符串 |
| `f57adf67` | Check for Updates 排在 Install Local Build 前 | P7 / T26 |
| `caebc24f` | 删除无调用者的 Launchpad 字符串 | P7 / T26，按本地调用者检查后删除 |
| `a969cd5d` | 发布 2.2.3 元数据 | P8 / T29，记录来源，不将本地产物直接标为该版本 |

五个文件为 Launchpad app、Core Bundle view、字符串目录和两份版本配置。[上游发布说明](https://github.com/Lakr233/vphone-cli/releases/tag/2.2.3)称 Core Bundle 2.2.3 除版本号外与 2.2.2 相同，已有 2.2.2 的机器无需更新 guest 环境；该说明不证明本地旧 VM 已具备 2.2.2 能力。发布页区分公证 Launchpad 与未签名 CI 包。本次未下载或验证这两个分发产物。

## 4. 2.0.8 → 2.2.3 的关键行为变化

下表记录固定源码或提交历史中的变化，以及本地处理决定。上游记录的故障解释不提升为本地已验证原因。

| 问题 | 上游现象或结果 | 本地安排与证据 |
| --- | --- | --- |
| 补丁组织与 ID | 新增 PatchKit、patch set、preset、plan；`ae5e4531` 将 ID 改为 `{component}-{effect}-{name}` | P0/P4，建立旧 ID、新 ID、记录前缀、五变体及版本条件映射，保留 PatchOutcome 和消融历史 |
| 默认预设 | `standard.plist` 排除 Frida 两项、hv_vmm 三项、DeviceTree/Preboot 身份九项及 MIS trust-auth 一项，共 15 个 ID；`experimental` 选择全部，仍受版本条件限制 | `standard` 与本地 regular/jb、`experimental` 与本地 exp 均需逐项对照，不能按名称等同；预设源码含上游黑屏/定位故障记录，本地尚未复验 |
| 未声明记录 | `VPhonePatchPlan.isRecordEnabled` 对未声明记录返回 false；`VPhonePatchGate.allows(record:)` 在同类情况下返回 true | P4 / T11，声明完整性及实际写入记录均需严格检查；不能只验证 resolver |
| 重跑来源 | `a3d2382e` 从保存的固件原件重新打补丁 | P4 / T12，对照本地 prepare 备份、工具摘要、restart-from 及 retain_until；原件、临时树、已补丁树分开记录 |
| DSC 选项 | `d930e502` 删除 `--force-dsc-maxslide`；MIS 实现经历多次调整 | P4 / T13，记录版本条件与替代要求，先核对本地调用者；本次未验证 DSC 补丁字节 |
| 签名空间 | `ee8b70ca` 增加命令区不足时移除 LC_SOURCE_VERSION 的处理 | P2 / T04，对照本地 Mach-O 签名实现和破坏性输入测试 |
| UTF-8 归档 | `7f746eed` 新增线程局部 UTF-8 LC_CTYPE 包装 `withArchiveLocale` | 本地归档库未发现该包装；P2 / T05，在 C locale 下验证中文成员名、链接目标和 IPA |
| 连接与 worker | `1df6c43c` 调整连接关闭；`2e2ed0a8` 调整 worker 重试及日志 | 本地已有 worker 监护和有界停止；P2/P5 的 T06/T07 做具体差异与故障对照，不按文件存在认定完成 |
| IcliKit | 固定目标 workspace 与 daemon lockfile 为 0.7.7 / `9e9a6ca940ac4142771eb34cf7e052e35a7b7987` | 本地 daemon 工程仍固定 0.6.9；P2 / T08，验证 API 适配、UTF-8 IPA、卸载释放端口和无 altitude 定位 |
| GPU/缓存 | `835c4db2` 共享 IPSW/GPU 缓存；`cb924c91` 分块下载；`9a1018bd` 稀疏扫描；磁盘尺寸显示改用十进制 GB | P4 / T14，核对缓存身份、容量、取消及残留；本地经典原生 prepare 不覆盖这些变化 |
| 写盘回退 | 安装器 clone 返回 false 时直接挂载调用者 Disk.img，并清除安装标记 | P3/P4 / T15，采用验证过的完整复制回退或拒绝；失败不能自动转为原盘写入 |
| 停机环境更新 | `cfw update-environment` 要求 `launchd.plist.bak`，只替换已存在的环境库；不执行完整 CFW 的 DSC/Mach-O/GPU/Preboot 工作 | P4 / T16，建立旧 VM 资格与迁移路由。缺库或加载路径时不能将跳过记为功能升级成功 |
| 在线环境更新 | 更新 MISFix/SystemHook 后重启 MIS daemon，明确不自动重启 SpringBoard | P5 / T17，分别记录文件替换、进程重新加载和应用行为；需要的 respring/reboot 单列 |
| MISFix/UDID | 新增 libmisfix、SystemHook spawn 注入、配置及 UDID 状态；`88120ff0` 返回配置 UDID | P4/P5 / T18/T19，核对注入目标、签名安装、SpringBoard 激活、配置保留和真实应用启动 |
| guest 库清单 | 最新清单为 launchdhook、SystemHook、libvcamcaptured、libcamfix、libmisfix 五项 | 本地五项列表仍以 libvlocation 作为第五项，构建另含 GPU 候选；需统一宿主、daemon、打包和文档清单 |
| 定位路径 | `23527267` 删除 libvlocation 及应用层 Hook；location.set/clear/current 重新调用 IcliKit；`1df4088c` 用独立 VPhoneLocation.app 获取 Mac 定位 | 取消旧计划“libvlocation 必须先迁入”的要求。保留本地 owner/generation/sequence，已有应用层覆盖单列兼容决策；应用业务结果仍需验收 |
| RootHide | loader links、bootstrap base、PAM 和 LaunchDaemons 加载调整 | 本地已有 loader-link 检查；P6 / T21 验证 rootless/RootHide、服务和 tweak，继续固定 Irisin 输入 |
| 相机/输入 | 相机编译单元、泄漏和第三方 capture client 调整；trackpad/normalized touch 与方向、剪贴板、文件拖放变化 | P5 / T22/T23，保留本地 v3、256 字节头及回执；成套迁移并分项验收 |
| 宿主/管理 UI | 多系统宿主策略、独立 Launchpad CLI、并发/headless socket、多选/搜索/排序、日志、sheet 流程变化；删除 UI Inspector | P3/P7 / T24–T27，保留同用户控制和窗口安全约束；按真实调用者判断删除范围 |

关键源码链接均固定到本次目标：[Gate](https://github.com/Lakr233/vphone-cli/blob/a969cd5d9206932dc1a2797348027fbc7d0ee347/VPhoneExecutable/VPhoneCommand/VPhonePatchKit/PatchSet/VPhonePatchGate.swift)、[Plan](https://github.com/Lakr233/vphone-cli/blob/a969cd5d9206932dc1a2797348027fbc7d0ee347/VPhoneExecutable/VPhoneCommand/VPhonePatchKit/PatchSet/VPhonePatchPlan.swift)、[默认预设](https://github.com/Lakr233/vphone-cli/blob/a969cd5d9206932dc1a2797348027fbc7d0ee347/VPhoneExecutable/VPhoneVirtualization/Resources/patches_presets/standard.plist)、[CFW 安装器](https://github.com/Lakr233/vphone-cli/blob/a969cd5d9206932dc1a2797348027fbc7d0ee347/VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift)、[guest 更新](https://github.com/Lakr233/vphone-cli/blob/a969cd5d9206932dc1a2797348027fbc7d0ee347/VPhoneDaemon/Daemon/GuestAPI+Environment.swift)、[定位路径变更](https://github.com/Lakr233/vphone-cli/commit/235272673a811814606f7e2067c77b4f83a78261)。

原对话称 API 文档仍列四项库；本次尚未逐段复核该文档差异，不将该陈述记为本次已确认结果。T28 要求以源码统一更新 API 文档和测试。

## 5. 本地阶段对账

| 阶段 | 已有实现与历史证据 | 当前结果与剩余范围 |
| --- | --- | --- |
| P0 | 2.0.8 来源清单；23B85 四变体流水线和 13 项固件对比的历史记录 | 2.2.3 Git 基线已核实；五变体语义映射、相机 ABI 与完整恢复备份待完成 |
| P1 | catalog 25 条；DSC 预检查；NVRAM/clone；9 月 30 日原生导出内容对比 | catalog 不提升为新组合已支持；真实 DSC、导入及导入后启动仍未验收 |
| P2 | Sign/Archive/Restore、API 会话及文件传输、guest 候选构建已提交 | 对照签名、UTF-8、IcliKit 0.7.7 和新 guest 布局；完整运行时装载未验收 |
| P3 | 独立 VM 进程、显式原生 Restore、root 存储、helper 签名候选及授权实现已提交 | helper 注册和生产安装按 9 月 30 日记录暂缓；原生 CFW 受控执行及真实恢复未验收 |
| P4 | 原生 classic prepare 及检查点实现已在工作区；9 月 30 日记录 Swift Testing 753 项、XCTest 178 项（3 项跳过）；第一批真实组件对照 | 未提交；不覆盖 v2/GPU、原生 CFW、恢复/启动；新增 patch plan 要先对照 |
| P5 | 应用列表/前台/启动/终止、文件传输及本地控制合约已有实现 | 定位路径重新决策；MISFix/UDID、环境激活、相机 v3 及真实业务验收待完成 |
| P6 | 候选 guest 构建、loader-link 检查 | 固定 Irisin、rootless/RootHide、服务、tweak 与卸载尚未完成 |
| P7 | 本地已有 VM UI 和窗口规则 | Launchpad、CLI、最新 sheet/翻译、Inspector 范围待实施 |
| P8 | fast runner、候选构建及 bundle 校验已有历史证据 | 最终分发、版本台账、F1/F2/F3、故障注入与整组恢复待完成 |

历史结果来源：[剩余阶段记录](upstream_remaining_progress_2026-09-29.md)、[原生 prepare 与检查点](p4_native_prepare_2026-09-30.md)、[导出验收](vm_export_acceptance_2026-09-30.md)、[helper 记录](p3_helper_xpc_2026-09-29.md)。本次未复跑这些测试。9 月 29 日 helper 默认调度失败的原因未查明；9 月 30 日 Swift 全量通过不证明此前 Python 时间相关失败已统一关闭。

## 6. 执行顺序与约束

先完成 T01 本地变动保存、T02 对账收束及 T03 容量与完整备份，再推进 T04–T08 和 T09–T14。T00 Git 采集本次已完成。写盘任务另需 T11 严格计划和 T15 写盘保护通过。P7 独立 UI 工作可在接口与源码固定后推进；涉及 guest 写入和系统服务激活的验收依赖不能省略。

9 月 30 日记录的 helper/生产 Core Bundle 暂缓、P1c 导入及导入后启动跳过继续作为实施约束。新报告不构成恢复这些操作的授权。原生 prepare 的保留目录只包含固件树，不代替停机后的完整 VM 状态备份。

本次卷可用空间约 29.1 GiB（`df -k` 采样），未核算下一次解包、GPU 提取、完整备份或恢复所需峰值；执行前重新采样。沿用记录中的 10 GiB 暂停阈值，不把当前余量视为写盘准入已通过。

## 7. 证据与复现

[证据目录](artifacts/upstream-review-2026-10-01/baseline.json)包含本地 HEAD、分支、变动路径及文件 SHA-256、原有 tracked diff、FETCH_HEAD、三个范围的提交清单和重命名口径文件清单。[源码摘要](artifacts/upstream-review-2026-10-01/inspected-sources.json)记录固定目标的关键文件 SHA-256。[任务 JSON](upstream_execution_tasks_2026-10-01.json)与 Markdown 清单同步。

Git 获取和统计在临时裸仓库进行，本地 remote、分支和索引没有改变。`local-before.diff` 及摘要仅用于保留修改证据，不能代替包含未跟踪文件内容的工作区备份或 VM 备份。

```sh
git rev-list --count 9d218dedf58d4b19db5e51c8b584c1f14a96eee3..a969cd5d9206932dc1a2797348027fbc7d0ee347
git rev-list --count --no-merges 9d218dedf58d4b19db5e51c8b584c1f14a96eee3..a969cd5d9206932dc1a2797348027fbc7d0ee347
git diff --find-renames --shortstat 9d218dedf58d4b19db5e51c8b584c1f14a96eee3 a969cd5d9206932dc1a2797348027fbc7d0ee347 -- . ':(exclude)TODO.md'
```

以上命令要求所在仓库具有固定提交对象。本次没有将新上游对象写入本地项目仓库。
