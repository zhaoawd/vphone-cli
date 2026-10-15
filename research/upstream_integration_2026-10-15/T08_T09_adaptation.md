# IcliKit 与补丁声明适配（2026-10-15）

本轮完成固定目标 `8a75092013eda87a4e30ed029b72028cb9279ac4` 的 IcliKit 调用合同、声明更名、适用性和默认值对账，并实施必要适配。ProMotion 保持默认关闭。当前未提交源码与原有证据保留，没有安装候选、改写真实 VM 选择或操作 VM。

证据入口：[调用合同](evidence/icli085-contract/call-contract.json)、[完整依赖源码差异](evidence/icli085-contract/dependency.diff)、[声明差异](T09_declaration_delta.json)、[148 项适用性决定](T09_target_applicability.json)、[语义对账摘要](evidence/T08-T09-adaptation/semantic-reconciliation.json)。

## 1. IcliKit 调用合同

| 对象 | 核对结果与处理 |
| --- | --- |
| 固定依赖 | `0.7.16 / 702990b59ca412ad975f9f0ea5dafe95c30fac21` → `0.8.5 / 815ef234df5461b8eb9455931d38cb1c37992fe6`；同一 daemon 图的其他六项 pin 不变。Xcode 要求继续使用 exactVersion |
| Swift 调用 | 从两端 IcliKit/IcliSystem 公开函数和本地 daemon 收集 120 个调用名候选，未发现所用函数名被移除或签名改变。同名本地定义可能出现在候选表，最终兼容性由实际 iOS 编译和链接验证 |
| 应用安装/注册 | 目标改用 registration plan，核对记录、container、group 和 app-extension；本地仍先签名，再调用依赖安装。`refreshAppRegistrations` 保留本地物理目录准入及 `IcliError.commandFailed` 结构化结果 |
| 应用进程/前台 | 目标补充 RunningBoard PID 和已在前台应用的等待处理。本地继续检查 `bundle_id`、`pid`、`verified` 并保留显式未确认状态，未把启动请求接受等同于前台已确认 |
| RootHide/dpkg | 目标补充实际 jbroot 查找与 `Library/dpkg` 回退。本地 bootstrap 完成标记、物理根校验、auth/Hook/Irisin 策略保持；portable RootHide 和 launchd 路径测试通过，真实 dpkg/安装路径仍需 guest 验收 |
| 截图/输入/错误 | 目标包含截图回退、方向/原生分辨率、按钮状态附加字段和结构化错误。本地调用签名与 APIWire 编译通过；未升级现有相机 ABI 或替换 classic 控制链。真实 iPad/前台/截图结果未在本轮验收 |
| JPEG overlay | 0.8.5 仍直接调用 UIImageJPEGRepresentation。将原 B22 独立 bitmap 复制 helper 原样绑定到新源码，仅替换新版本的两个 JPEG 调用；保留目标版本的回退、方向和质量策略，不重新引入已删除的旧循环。revision、base/patched/patch SHA-256 全部重算并校验 |
| daemon 角色 | classic 1337/相机与独立 API 1339 的既有组合保持，less 不扩大 API 安装范围；本轮生成两种配置的独立候选，均未安装或激活 |

实际构建目录为 `.build/daemon-api-8a75092`，通过 `VPHONE_DAEMON_API_BUILD_DIR` 指定。构建脚本增加独立 PackageCache，旧 `.build/daemon-api-v2` 及冻结 V9 工件没有替换。

Xcode 首次包解析在二进制下载阶段停滞；只中断本轮 PID/命令已确认的解析进程。通过原本地代理取得官方 libarchive ZIP，SHA-256 与包声明一致（`573fa72c…93537c`），放入独立标准包缓存后正常解析和构建。没有启用本地 BinaryTarget override，没有跳过包签名或候选来源检查。

两个候选均通过 arm64、iOS 15.0 deployment target、动态依赖、entitlements、固定 pin 和 overlay marker 校验。签名后来源见 [candidate 清单](evidence/T08-T09-adaptation/candidate-manifest.json)与 [candidate-v2 清单](evidence/T08-T09-adaptation/candidate-v2-manifest.json)，其 `activated=false`、`runtime_validated=false` 保持。

## 2. 声明、适用性与默认值

源声明从 141 项变为 148 项：140 个原 ID 的标题、适用条件和 bootEssential 元数据不变；1 项发布后更名；新增 7 项。148 项均保存固定 Git blob、SHA-256 和源码快照，并有唯一、明确的本地实现决定。

原有 140 项本地 declaration 与五模式/版本矩阵逐字段保持，11 项 local-only 声明保持；其中本地展示标题也保留。上游元数据不变不证明补丁实现字节不变，同 ID 的 IOMFB/DeviceHub 等实现迁移仍在 T32/T33/T53 单独处理。

| 新声明 | 上游声明的适用条件 | 本地决定 |
| --- | --- | --- |
| `system-locationd-cfw-disable_auto_cohort` | iOS major 27 | notImplemented；现有定位所有权/模拟不等于 cohorting 补丁 |
| `system-jetsamproperties-cfw-disable_allowed` | iOS major 27 | notImplemented；待精简/服务维护能力接入 |
| `system-preferences-exp-root_rows` | iOS release 27.0 | notImplemented；T58 策略待决定，不能据版本字段推定所有 build 的二进制发现均可用 |
| `dyld-exp-settings_software_update_row` | iOS release 27.0 | notImplemented；同上 |
| `system-installcoordination_proxy-cfw-persona_lookup` | iOS major 27 | notImplemented；待 T53 完整开发工具链 |
| `system-backboardd-cfw-gyroscope` | iOS ≥18.0 | notImplemented；待可选 T54 链路 |
| `system-apps-cfw-attitude` | iOS ≥18.0 | notImplemented；同上 |

本地 catalog 合计 159 项（148 上游 + 11 local-only）。生成器要求每个 ID 都有源摘要、上游预设成员信息、五模式和 18/26/27/other 的决定；缺项或来源不符均拒绝生成。上游预设只作对照，不导入为本地默认值。

### ProMotion 更名

`kernel-exp-display_refresh_120hz` → `kernel-cfw-display_promotion`。上游 standard 默认开启；本地继续默认关闭，覆盖五模式，且当前仍为 notImplemented，显式启用会被 resolver 拒绝。

迁移词表从 118 个 alias/152 个 canonical ID 扩为 119/159。旧显式关闭迁移为新 ID 的关闭；旧显式开启只在预览中保留意图，不取得执行权限。旧/新 ID 重复或开关矛盾时拒绝，重复迁移幂等。mapping revision 升为 `/2`，没有自动改写真实 VM 配置。

### 目标绑定与恢复

Swift migration 与事务 binding 统一引用 catalog 的固定目标；Python guest gate 同步为同一目标。当前执行同时检查 upstreamTarget、catalogRevision 和 catalog 摘要，避免记录中的来源目标与实际声明不一致。

已保存的旧目标日志继续按原有内容摘要、稳定身份、generation/原件关系进行恢复；旧目标不能取得新写入资格。本轮测试覆盖“旧 target + 当前 catalog”和“旧 target + 旧 catalog”两种记录：均拒绝当前执行，允许受验证的恢复。真实 VM 的 desired/generation/Receipt 未迁移，新写入仍需重新核对资格。

## 3. 验证与限制

| 验证 | 结果 |
| --- | --- |
| 固定 catalog 与 migration 生成校验 | 通过；148/159 声明、119 alias，与已审阅决定一致 |
| 本地行为保持 | 140 项 declaration/适用性矩阵和 11 项 local-only 逐字段一致；Swift 验证五模式默认 enabledSteps 不扩大 |
| Xcode Release iOS daemon 候选 | 构建、签名及两种配置来源校验通过，未部署 |
| IcliKit 宿主回归 | 2 项通过，编译并运行固定依赖的 Archive/Deb/JSON/launchd 路径 harness；RootHide C harness 全部检查通过 |
| Python catalog/pin/overlay/guest gate 专项 | 9 + 9 + 7 + 43 项通过；guest gate 首轮一项 clonefile 被沙箱拒绝，原断言重跑通过 |
| 最终相关 Swift | 131 项、11 suites 通过；含更名、默认值、适用性、事务绑定、历史恢复、generation 和 Receipt |
| 标准 Swift 首轮 | 1502 项、234 suites，20 issues；没有写为全量通过。首轮时部分构建/验证并行，未据此确认失败原因 |
| 失败套件定向复验 | 126 项、14 suites，剩 2 issues；API/worker/退出时限项未在该次复现，其首次原因未查明 |
| 适配前源码对照 | 两项剩余失败分别在适配前完整源码副本中复现；原工作区未回退。见下一段 |
| 标准 Python | 最终完整重跑 779 项通过，跳过 1 项；404.548 秒 |
| 固件比较、恢复、启动、应用与内存验收 | 本轮未执行；没有新增 kernel/DSC/Mach-O 指令补丁，JPEG overlay 的新 guest 内存表现仍需真实验收 |

两项既有 Swift 失败分别是 `postValidationRecognizesIdempotenceWithoutEmitting`（第一次调用的 emittedRecords 为 2，断言为 1）和 `failedStopDoesNotInterruptLaunchpadChild`（launchedProcess 为 nil）。相关生产文件和测试文件与适配前摘要一致，在适配前源码副本各运行一次也失败。没有修改它们的实现或断言，原因未查明。

标准 Python 首轮为 779 项、1 项失败、1 项跳过。失败是已有 operation-pool 夹具仍用旧调用签名，遗漏 `externalProxy` 参数；本轮 APIWire 生产源码没有改变。已将夹具调用和替身签名对齐现有接口，成功/失败响应与 autorelease 释放断言保持，单项复验通过，并重跑标准套件。普通沙箱执行该单项曾被 Swift 模块缓存权限阻止，相关记录保留。

完整日志及初始失败记录保存在 [验证证据](evidence/T08-T09-adaptation/semantic-reconciliation.json)旁的 `logs/`，最终源摘要和保护核对见 [修改保留检查](evidence/T08-T09-adaptation/preservation.json)。原始失败不覆盖、不提升为通过。

## 4. 后续范围

T08 的源码调用合同和候选构建已完成，真实新 guest 组合、应用注册/RootHide、截图及重复调用仍待验收。T09/T10 本轮完成声明层适配，不代表新上游固件输出等价或全部旧任务通过。T45 继续延后并默认关闭。

后续优先处理 T32/T33 的同 ID 实现代际与可信 Undo，及 T15/T24/T37/T40/T52 的共同操作边界。已有 kernel 更新/回退和 I/O 工作保留；不覆盖冻结 V9，不将旧历史通过记录外推到当前候选。
