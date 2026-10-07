# 固定上游整合执行记录（2026-10-06）

本轮目标为 `2d21d21fbdd4f51f013616273ceda9b35a3e0789`。主工作区基线为 `e8d825b3723d9ec72d31b050a79d353acd4b59bf`，实施分支为 `codex/upstream-2d21d21-integration`，使用已经附加的隔离工作树。主工作区未修改，现有 VM 未操作。

`inputs/` 保存用户提供的三份附件原文；来源路径、摘要与大小见 `input_manifest.json`。附件内的历史状态、旧 sandbox 链接和实施授权字段仅表示原文状态。本轮授权来自用户“开始推进”“继续”；实际状态记录在 `tasks.json`。

## 结果与范围

| 任务 | 当前结果 | 限制 |
| --- | --- | --- |
| T00/T01 | 当前 Git 基线、干净主工作区和隔离工作树已固定 | 不替代 VM 恢复点 |
| T02 | 47 项能力、758 个任务路径条目、342 个提交的结构性台账已生成 | 文件名与摘要只能提供候选；逐项语义审查未完成 |
| T03 | 用户指定 vm-new；运行基线已记录，稀疏复制准备检查通过 | 原 VM 仍运行；签名候选启动检查退出 137，临时 amfid 操作待单独授权；实际备份和恢复启动未执行 |
| T04 | 目标 Mach-O 文件唯一逻辑差异是保留 LC_UUID；定向签名与 codesign 检查通过 | 仍保留用户 10 月 1 日的决定；不能靠删除 UUID 接受空间不足的输入 |
| T05 | 保留 UTF-8 locale 与路径保护；修复归档遍历临时改变进程工作目录 | 当前高 UID 仅验证严格 ustar 拒绝；真实 VM 导入/导出未验收 |
| T06/T07 | 固定目标连接收尾、proxy 重试与 plist 已部分审查；18 项 Python、51 项相关 Swift 对照通过 | VSOCK、升级监听确认与每 VM 更新策略仍需审查和真实 VM 验证 |
| T08 | IcliKit 0.7.16、swift-collections 1.7.1 与其余五项 pin 已对齐；候选编译、签名与来源检查通过 | 未部署、未激活；客户机运行行为未验证 |
| T09 | 固定目标 141 个声明，比 2.2.3 新增 24 个，无删除；预设选择增量已记录 | 仅声明与 plist 元数据，未建立等价实现或配置迁移 |
| T10 | Swift 写入路径已使用冻结计划；250 项相关模块测试、15 项固件测试通过 | 当前 catalog 为历史本地版本；单个 patchID、组合步骤必需项、guest Gate 和固定上游二进制比较仍未完成 |
| T11 | 现有事务 journal 已保存冻结计划和版本 manifest 字节摘要；暂存输入必须一致 | 仍未形成绑定稳定 VM 身份、catalog/target、schema、planDigest 的 C2 持久化计划及兼容导入 |
| T24 | 宿主入口已部分审查；隔离 CLI/VM Bundle、Launchpad 与未配置 helper 候选构建和签名检查通过 | 独立 launcher、每台 VM 的 Bundle 选择、真实授权行为和完整运行依赖闭包仍未完成；宿主 Swift 子集有一项 XPC 超时 |

`commit_ledger.json` 共 342 个提交，其中 280 个非合并、62 个合并提交。8 个合并提交的 remerge diff 非空，其冲突解决内容已核对；父提交其余变更和本地适配仍需审查；37 个提交只涉及文档路径，转入 T28 审查。不得据此把所有提交标记为已合入。

## T05 证据

旧实现回归测试失败：另一个线程观察到遍历中的进程工作目录变化。新实现使用绝对路径与 `archive_read_disk_entry_from_file` 读取元数据，自己遍历物理目录；仍保留 libarchive 的硬链接解析、ACL、扩展属性和稀疏信息读取，不跨 `await` 使用线程 locale。

参考：[libarchive 读取磁盘接口](https://raw.githubusercontent.com/libarchive/libarchive/v3.8.1/libarchive/archive_read_disk.3)、[官方实现](https://github.com/libarchive/libarchive/blob/v3.8.1/libarchive/archive_read_disk_entry_from_file.c)。测试验证普通打包和取消时工作目录不变，并覆盖原子发布、路径穿越、符号链接、硬链接、稀疏文件、decmpfs 和多语言名称。

当前 UID 为 `2035870432`。严格 ustar 的数字 UID/GID 使用六位八进制；当前账号超出其范围。测试在该条件下验证明确拒绝及 staging 清理，保留可表示 UID 环境下的正向分支。没有修改源文件所有者或截断 ID。[官方 ustar 数字字段实现](https://github.com/libarchive/libarchive/blob/v3.8.1/libarchive/archive_write_set_format_ustar.c)

## T09/T10/T11 证据

`T09_declaration_delta.json` 保存所有 141 个声明、旧本地映射候选、来源位置及预设选择。`standard` 与 `experimental` 分别增加 23/24 个选中 ID，尚未计算版本门。中间 `kernel-exp-paravirt_user_clients` 在 `74629ee9` 更名为 `kernel-cfw-paravirt_user_clients`；声明及预设差异已保存。当前运行目录仍使用历史 catalog，显式选择迁移尚未实施。

旧 Gate 在回归测试中产生 8 个 issues：无归属记录、越界或重复索引、失败步骤发出的未声明记录，以及 ablated/notApplicable 结果携带记录均未被拒绝。修复依据 `StructuredExecution` 的记录数量增量归属，保留 alreadyApplied 无记录、多记录属于同一步骤、失败步骤已发出记录等情况。事务测试验证拒绝后原件不变。检查仍基于步骤与声明的映射，组合步骤内部每个 patchID 的声明归属及必需项核验仍需实现。

本轮 resolver 修复拒绝四类无效输入：同一 ID 同时 select/block、variant 与 gates 不一致、关闭当前适用的必需声明，以及组合步骤仍启用时只关闭其中部分声明。组合步骤内的独立开关尚未实现；独立可选步骤、全部可选共享声明一起关闭、模式或版本条件不适用时的关闭仍允许。结构校验同时拒绝不存在的 `conflicts` 和 `after` 目标，保留已存在但当前未启用的关系目标。

现有固件 fixture 预检查通过 17 个非空必需文件。标准 `make test_firmware` 在新增实际 boot-chain 记录 Gate 后通过 14 项、12 个 suite；新增参数覆盖 AVPBooter/iBSS/iBEC/LLB/TXM/TXMDev，并验证删除结果归属后拒绝实际记录。已有内核比较中 regular 28 项、JB 84 项均与本地 Python 参考一致。该证据覆盖当前本地参考，不能据此认定与固定上游目标的二进制输出等价，也不能认定 restore 或 boot 通过。19 个输入文件的大小和 SHA-256 见 `evidence/T10-firmware-fixture-manifest.json`。

现有 create selection SHA 对 variant、gates、声明及步骤排序后摘要，可用于后续绑定；它没有包含 VM 身份、输入摘要和固定上游目标，不能作为完整 C2 计划。上游 preset store 将 selection 读取或解码失败回退到默认值，plan/receipt 使用可选结果；这些行为与本轮缺失、损坏、未知 schema 的分别表达要求不一致。

### 2026-10-07 冻结计划与版本输入

`0c73f59f` 在 Swift 实际写入路径中，先从真实 variant、版本 manifest 和选项解析一次计划，再建立事务。暂存执行复用该计划的 gates 和 enabledSteps；执行器在调用步骤前排除未选步骤，提交 Gate 另校验报告、结果与计划的身份和允许步骤。低层独立调用接口保留原行为；新接口要求调用方传入刚解析的计划，解码后的任意计划不取得写入资格。

版本号和 SHA-256 来自同一次读取的字节。读取只把 ENOENT 归为缺失，权限错误、损坏 plist、非字典根、非字符串或无法识别的 ProductVersion、符号链接及目录均拒绝。暂存后重新核对两份 manifest，新增、删除或修改均拒绝。当前支持无符号 ASCII 十进制分段版本号；带其他限定符的版本需另行定义兼容规则。基线版本未知时，不把未知的必需 EXC_GUARD 条件当作 false；dev 或强制启用时，该激活条件可独立确定。启用 Frida 且 cloudOS 版本未知时，在事务建立前拒绝；未启用 Frida 的计划不依赖该条件。

现有 journal 新增可选 plan 和 versionInputs，继续使用 vmPath、输入目录摘要及原恢复流程。历史 journal 缺少新字段时仍可恢复；恢复按 journal 状态校验已提交产物或恢复未提交原件，不重新执行补丁。这些字段是本次事务证据，尚未形成 C2 的稳定 VM 身份、schema、catalog/target、planDigest、desired 配置及兼容导入。当前运行 catalog 仍为 119 项（96 Swift、22 guest、1 notImplemented）。固定目标的 141 项声明及迁移尚未接入；可写 CLI 的显式 select/block 接口也尚未接入。

回归测试先确认旧行为：未保存冻结计划或未知版本放行产生 3 issues；恢复旧全局 Gate 的对照产生 8 issues；未选步骤仍调用并改字节产生 5 issues；版本输入最小对照产生 19 issues；未知 EXC_GUARD 条件产生 2 issues；Frida 的未知 cloudOS 放行产生 3 issues。严格 manifest 读取曾使两个故障注入测试提前拒绝其无效输入；已将这两个实验的输入改为合法 plist，再保留原 EIO、部分写入 ENOSPC 和恢复断言。解析器签名变更时曾遇到旧调用方对象引用旧符号的链接失败；重新编译调用方后才完成行为回归测试，未将链接失败计入行为红测试。

最终相关模块 249 项、39 个 suite 通过；标准固件测试 15 项、12 个 suite 通过。实际 Gate 参数新增 regular/JB kernel，合计八组组件；关闭实际 iBSS serial label 声明后，对应字节保留输入值，其他记录与基线相同。现有 regular 28、JB 84 内核比较仍与本地 Python 参考一致；补丁算法未修改。这些结果不建立固定上游目标的二进制等价或真实 VM 验收。

本次 `make build`、`make launchpad` 和最终 `make check_bundle check_launchpad` 均通过。CLI/VM 与 Launchpad 内嵌可执行文件的 cdhash 一致；七个可执行文件的摘要、直接动态库与 entitlement 见 `evidence/T10-frozen-signed-artifact-manifest.json`，源码为 `0c73f59f`。这是隔离重建候选，未部署、未启动；helper 未在本次重建，完整传递动态依赖闭包及最终发布候选仍未验收。历史 T24 manifest 保留其原提交与摘要。

本次默认 `make test_swift` 的 XCTest 为 234 项、3 跳过、0 失败，Swift Testing 为 1074 项、166 个 suite、14 issues、61.485 秒。问题分布为 HTTP 5、WebSocket 7、进程取消 1、helper XPC 1；相关套件定向对照 40 项、6 个 suite、2.667 秒全部通过。原因未查明。标准入口因 Swift Testing 失败退出，后续 tar 管道及 guest 检查没有在此次入口中运行；既有证据单独保留。

### 2026-10-07 基线版本与 boot-args 参数

`8777bc7e` 补充实际写入的预检：所有 variant 的 iBEC/LLB factory 都根据 iosBaseIs18 设置 extraBootArgs。EXC_GUARD 激活条件在 dev 或强制模式可独立确定，但不能据此决定未知的 boot-args 参数。因此，实际写入在建立事务前要求已识别的基线版本；只读 resolver 的独立条件判断保留。历史 VM 缺少元数据时，仍需明确的识别或导入流程，不能自动写入。

回归测试在 dev 与强制 regular 中产生 4 issues，确认两条路径此前会提交缺基线 manifest 的合成输入。首轮模块验证另有一项组件停止测试提前失败，因为其输入没有版本 manifest；补齐合法基线 plist 后保留原停止执行、原件不变及 dev Gate 断言。最终相关模块 250 项、39 个 suite、1.387 秒通过；该提交的固件复验 15 项、12 个 suite、42.743 秒通过。首次提交说明曾错误记录首轮模块通过，已在真实复验通过后修订本地提交与台账；失败日志保留。

该提交的默认 `make test_swift` 复验：XCTest 234 项、3 跳过、0 失败；Swift Testing 1075 项、166 个 suite、2 issues、58.478 秒。helper XPC 仍超时，HTTP 取消断言记录 6.621596667 秒超过 1 秒。与前次 14 issues 的差异不能建立修复或原因结论；原因未查明。采样流程未取得本轮子进程的采样文件，未据此提出堆栈结论。标准入口后续 tar/guest 检查仍未执行。

该提交的 `make build`、`make launchpad` 和最终 Bundle 校验全部通过；重新打包后的 CLI/VM cdhash 与 Launchpad 内嵌文件一致。最终本次源码与七个可执行文件摘要见 `evidence/T10-base-signed-artifact-manifest.json`。产物未部署，helper 未在本次重建，真实 VM 及完整动态依赖闭包仍未验收。

## T24 证据

`T24_host_entry_review.json` 保存固定目标与本地入口的源码摘要。本地公开 CommandLine 构造入口只接受已验证的嵌入工具链；核验包括路径组件、内外签名、manifest schema 和 CLI/VM cdhash。root helper 按 audit token 与签名要求核验 caller；协议仅提供 Bundle install/verify，install 另验证管理员 authorization form。本轮未注册服务或操作系统 Bundle store。

本地尚无上游独立 launcher；Core Bundle 面板目前只列出和核验版本。固定目标 `throughLauncher` 在 launcher 缺失、不可执行以及策略检查失败时都回退原 command。本轮记录该差异，后续接入时必须分别表达合法普通开发入口和策略拒绝。上游 launcher 的隐私权限传递不表示该 launcher 自身取得 root 权限。

正式隔离构建先后暴露两项工作树输入问题：Capstone 嵌套 `.git` 相对路径失效，资源子模块未初始化。前者仅修复独立工作树文件，并验证源码与 `905d2d29` 一致；后者从与 Gitlink 一致的 `2ef6b06a` 导出四个独立资源文件。主仓库 Git 配置和源码未修改。补齐后 `make build` 通过资源、签名、entitlement 和客户机载荷清单检查。

Launchpad 的构建脚本原先依赖 SwiftPM 生成 `Contents/Resources/*.lproj`；当前工具链仅复制 `.xcstrings` 原件，实际构建失败。`0531b903` 改为先验证目录，再使用 Xcode `xcstringstool` 显式编译现有英文和中文目录。实际打包后 546 个显式翻译值与目录原文一致；嵌入 CLI/VM 的 cdhash 与来源 Bundle 相同，内层 entitlement 与外层签名检查通过。翻译源文件未改动，UI 运行行为未验证。

七个 Bundle 可执行文件的架构、摘要、entitlement 和直接动态库记录见 `evidence/T24-signed-artifact-manifest.json`。当前直接依赖的 Homebrew libcrypto/libplist 文件存在并已记录摘要；完整传递依赖闭包尚未验收。嵌入可执行代码来源为 `6327738f`，字符串打包脚本修复为 `0531b903`；这些产物尚未作为最终不可变发布候选签收。未配置团队的 ad hoc helper 候选在只读 `--check-configuration` 检查中以退出码 78 明确拒绝；没有注册或安装。

50 项宿主 Swift 子集仍有一项 XPC 超时。监听端已记录签名拒绝；独立探测观察到 interruption/invalidation 并通过，但同样探测在子集中未于超时前观察到关闭通知。原因未查明。探测代码已撤回，没有放宽身份规则或修改超时时间。

## 验证

| 实验设置 | 结果 | 证据 |
| --- | --- | --- |
| 签名与归档定向测试 | 78 项、12 个 suite 通过 | `evidence/T04-T05-green.log` |
| `make test_swift` 默认测试间并行 | XCTest 234 项、3 项跳过、0 失败；Swift Testing 1031 项、159 个 suite、16 issues；归档测试通过，未出现 getcwd 错误 | `evidence/T05-full-swift.log` |
| 相关失败套件单独并行 | 51 项、8 个 suite 通过 | `evidence/T05-isolated-control.log` |
| 完整 Swift，显式 `--no-parallel` | Swift Testing 1031 项、159 个 suite 通过，180.602 秒；仍包含各测试内部并发场景 | `evidence/T05-serial-control.log` |
| 1 GiB tar 管道，两种模式 | 通过；峰值 RSS 8601600 / 7847936 字节 | `evidence/T05-tarpipe.log` |
| guest components | 124 项检查、0 失败 | `evidence/T05-guest-components.log` |
| proxy 与 daemon 构建校验 | 18 项 Python 测试通过 | `evidence/T06-T07-python.log` |
| 0.7.16 pin 校验 | 旧 0.7.7 红测试失败；更新后 6 项通过 | `evidence/T08-pins-*.log` |
| 固定依赖 jsonSafe 源码，macOS 纯数据探测 | NaN、无穷值、嵌套 Data/日期、多语言字符串等通过 | `evidence/T08-json-safe.log` |
| `make daemon_api_build` | iOS arm64 候选编译、精确 checkout、签名、动态依赖与 manifest 检查通过 | `evidence/T08-candidate-build.log` |
| T10 记录归属回归 | 旧实现 8 issues；首轮修复 22 项通过 | `evidence/T10-ownership-*.log` |
| T10 FirmwarePatcher 无固件模块 | Swift Testing 185 项、31 个 suite 通过；XCTest 5 项、3 跳过、0 失败 | `evidence/T10-firmware-free.log` |
| T10 新一轮完整 Swift 串行对照 | HTTP fixture 清理阻塞；采样后仅结束本轮运行器，退出码 143 | `evidence/T10-full-serial-interrupted.log`、`evidence/T10-serial-stall.sample.txt` |
| T10 选择与关系校验 | 红测试分别复现 4/2 个 issues；最终模块 225 项、34 个 suite 通过 | `evidence/T10-selection-*.log`、`evidence/T10-references-*.log` |
| `make test_firmware` | 14 项、12 个 suite 通过；含六组实际 boot-chain Gate 参数 | `evidence/T10-firmware-gate.log` |
| 冻结计划与版本输入相关模块（0c73f59f） | 249 项、39 个 suite 通过 | `evidence/T10-frozen-final-module.log` |
| 冻结计划的实际固件 Gate（0c73f59f） | 15 项、12 个 suite 通过；八组组件，含内核与 serial label 关闭对照 | `evidence/T10-frozen-final-firmware.log` |
| 冻结计划后的默认完整 Swift（0c73f59f） | XCTest 234/3 跳过/0 失败；Swift Testing 1074/166、14 issues | `evidence/T10-frozen-default-swift.log` |
| 本次失败套件定向对照 | 40 项、6 个 suite 全部通过 | `evidence/T10-frozen-failure-control.log` |
| 冻结计划提交的隔离构建与打包（0c73f59f） | build、Launchpad、最终 Bundle 校验通过；未部署 | `evidence/T10-frozen-bundle-build.log`、`evidence/T10-frozen-launchpad-build.log`、`evidence/T10-frozen-final-bundle-check.log` |
| 基线 boot-args 参数保护（8777bc7e） | 250 项模块 / 39 个 suite，15 项固件 / 12 个 suite 通过 | `evidence/T10-base-parameters-final-module.log`、`evidence/T10-base-final-firmware.log` |
| 基线参数保护后的默认 Swift（8777bc7e） | XCTest 234/3 跳过/0 失败；Swift Testing 1075/166、2 issues，尚未通过 | `evidence/T10-base-default-swift.log`、`evidence/T10-base-validation-summary.json` |
| 最终源码的构建与打包（8777bc7e） | build、Launchpad、Bundle 校验全部通过；未部署 | `evidence/T10-base-build-driver.json`、`evidence/T10-base-signed-artifact-manifest.json` |
| T24 宿主 Swift 子集 | 50 项、7 个 suite、1 个 XPC 超时 issue | `evidence/T24-host-policy.log`、`evidence/T24-xpc-close-*.log` |
| 隔离 `make build` | 编译、完整资源、签名和 entitlement 检查通过 | `evidence/T24-complete-bundle-build.log` |
| 隔离 Launchpad 打包 | 红测试缺编译目录；修复后静态 Bundle 检查通过，546 个显式翻译值一致 | `evidence/T24-launchpad-build*.log`、`evidence/T24-launchpad-localizations.json` |
| T24 相关 Python 测试 | 41 项通过 | `evidence/T24-bundle-python.log` |
| 未配置 helper 候选 | 编译与签名检查通过；只读配置检查以退出码 78 拒绝 | `evidence/T24-helper-candidate-build.log`、`evidence/T24-helper-configuration-rejection.log` |

标准 `make test_swift` 尚未通过。历史默认并行运行产生 16 个 issues，`0c73f59f` 为 14 个，`8777bc7e` 为 2 个；本次相关套件定向对照和历史完整串行对照通过。具体原因未查明。没有修改标准测试入口或扩大超时时间；此前串行通过不能代替默认并行验收。新一轮串行采样显示 `APIHTTPFixture.stop → Process.waitUntilExit` 阻塞，采样时运行器已无存活子进程；该次运行没有完成。

候选 binary SHA-256 为 `70a488a63d93c9a2b8a5b6c62598036532b0ca28207ba8855305d9552172cc3f`。完整依赖和三项产物摘要见 `evidence/T08-candidate-manifest.json`；该文件明确记录 `activated=false`、`runtime_validated=false`。

## 调整与后续工作

继续使用已附加的 `codex/` 分支；按实际 SwiftPM/Make 与独立 Xcode 工程分别验证。T04 保留 LC_UUID，仅回收 LC_SOURCE_VERSION，随后明确拒绝。T08 补入七个具体 entitlement，但保留现有两项 keychain-access-groups，未增加上游的 `*` 和 `apple`；跨组 keychain 能力留待 T41 审查。这些调整及成本写入 `tasks.json` 的 `execution_rulings`。

本轮代码及测试提交包括 `b6eb1873`、`4fd8dc87`、`6327738f`、`0531b903` 、`0c73f59f` 和 `8777bc7e`。继续 T02 语义对账，并核对 T09/T10/T11 的补丁选择、模式策略与持久化接口；T24 后续连接 T40 每台 VM 的 Bundle 绑定及授权责任链。T03、真实客户机运行、最终集成验收和默认并行测试问题仍未完成。T45 按原方案延后。


### 2026-10-07 vm-new 验收准备

用户指定当前项目的 `vm-new` 做验收。旧记录中排除该 VM 的范围不适用于本轮新授权；`vm-2607` 不参与本轮验收。`vm-new` 的宿主进程为 29288，Virtualization.framework 进程仍持有 Disk.img、NVRAM 和 SEPStorage 的写入句柄。原 VM 尚未停止，实际备份与恢复启动尚未执行。

恢复信息记录 EXP、iPhone17,3、iOS/cloudOS 26.1 / 23B85。客户机连接与应用列表查询通过，共 235 个应用，含 Settings 和 Safari；前台查询返回空 bundle_id、source=unknown，不能据此认定前台应用验收通过。未导出应用列表到受版本管理的证据。现有 Shell 会话的 PATH 无法找到 cat、uname、ls、sw_vers 和 uptime；仅为本次摘要命令指定 PATH 后，客户机内的 sha256sum 执行成功，没有修改持久环境。

容量采样为 66 个普通文件，逻辑大小 68,789,917,697 字节，实际分配 20,160,262,144 字节；可用 60,620,800,000 字节（56.46 GiB）。两份稀疏副本按当前分配估算 40,320,524,288 字节，另计启动及映像元数据 2 GiB、最低可用空间 10 GiB，估算可容纳。备份拟放在主项目 `vm.backups/`，恢复目标拟使用新建的独立 APFS sparsebundle。两者仍在同一内部磁盘，不具备离盘故障保护；实际复制期间需持续核对容量。

验收复制脚本已用合成稀疏文件、UTF-8 文件、空文件和带 UF_COMPRESSED 的 ROM 副本验证。128 MiB 稀疏测试副本分配 32,768 字节，压缩 ROM 按普通读取计算的 SHA-256 与源相同。目录锁冲突和空间不足均拒绝；实际 VM 复制未执行。脚本保留文件字节、mode、mtime 和目录结构，记录 uid/gid 差异，未复制 ACL 与扩展属性；源 `.ssh_forward` 为 root 所有，不能把用户所有的副本描述为所有元数据一致。

候选源码为 `8777bc7e`，签名 VM CDHash 为 `61ea15c6739775b707d3a36fca082c4d97049be2`。现有宿主启动检查中，未签名 debug --help 退出 0，签名 release 与签名 debug 对照均退出 137，原因未查明。没有启动 amfidont，也没有停止原 VM。临时系统 amfid 操作已单独询问用户；授权前保留当前运行实例。

专用恢复测试文件为客户机 `/private/var/tmp/vphone-t03-acceptance-20261007.txt`，禁止覆盖创建成功；内容为本轮验收标记，SHA-256 为 `2324d2917ab7a74eb8c163a493894ccf87ae21a6298db4b6a34810f11e154e80`。恢复后将验证该文件；验收结束后只清理本轮创建且摘要匹配的标记。原 VM 已有这一项明确的临时测试写入。

自动审批拒绝下载完整 SpringBoard 私有配置用于宿主侧摘要，理由为可能包含敏感用户数据，未获该特定导出授权。替代操作在客户机内计算 SHA-256 并只返回摘要，审批通过且命令退出 0。私有配置没有导出；其摘要仅为观测基线，不能假定正常停机与启动后该配置的字节保持不变。

当前 VM 不含 FirmwareOriginals 或 Restore 输入目录；历史 journal 为 version 1、phase committed、2 个 entries，没有 plan/versionInputs。旧事务记录不能自动取得 C2 写入授权。该 VM 的 EXP 26.1 样本不能代表五模式和全部固件组合。实际恢复启动、通信、应用启动、数据读回与 C2 兼容识别均待验证。


### 2026-10-07 显式选择约束与合并冲突审查

`ccda7f46` 修复解析器静默忽略显式请求的问题。已知 ID 的 select 仍须符合模式、版本和 opt-in，并绑定至少一个当前实际 Swift 步骤；不满足时返回 selectionNotEnabled。客户机步骤尚无执行 Gate，显式选择或关闭当前模式适用的 guest 声明返回 guestOverrideUnsupported。关闭当前模式不适用的 guest 声明仍允许。默认选择、Frida opt-in、必需声明和共享步骤关闭规则保留；不改变补丁算法，也不接入 guest 写入。

红测试 8 项中有 6 个 issues：模式越界、缺 Frida opt-in、版本条件不满足、无 live step、guest select、适用 guest block。修复后完整相关模块 258 项、40 个 suite 通过（1.285 秒）；标准固件入口 15 项、12 个 suite 通过（37.947 秒）；只读 fw plan 的 5 个离线 CLI 用例通过，包括全部五模式、有效 serial 选择、Frida 明确 opt-in 及两个拒绝用例。最初定向命令以 DeclarationGateTests 子串过滤，误包含 StructuredDeclarationGateTests，没有 fixture 环境时产生 9 个缺文件 issues；按模块筛选及标准固件入口分别重跑后通过，该失败记录保留。

标准 make test_swift 本次退出 2。XCTest 为 234 项、3 跳过、0 失败；Swift Testing 为 1083 项、167 个 suite、16 issues、84.568 秒。HTTP 5、WebSocket 7、进程取消 3、helper XPC 1；原因未查明。网络和 helper 定向对照为 23 项、3 个 suite、0.284 秒通过；Launchpad Library 为 4 项、1 个 suite、1.675 秒通过，包含取消用例。额外运行 Core Library 6 项通过，该套件不是取消用例所属模块；之后按唯一测试名运行取消用例，1 项、0.321 秒通过。定向对照存在重叠，不相加为独立用例数。采样命令退出 255，原因是目标测试进程已退出，没有取得采样文件。未放宽超时或删除断言；标准入口后续 tar/guest 检查没有运行。

T02 的 8 个非空 remerge diff 已逐一核对原始字节摘要，并记录冲突解决内容及后续任务依赖。原件保存、board/device 分类、Preboot 分组修复、guest 撤销与 receipt 在合并结果中相互关联。固定目标仍从 pristineInput 读取 board tree；Info.plist 为 2.6.1 并保留麦克风说明；Installer 按配置识别设备，按 presentsBoard 选择 audio 或 iPhone product 修复；BoardDeviceTree.need 支持 iPhone17,3 原件恢复。8 项审查仅覆盖冲突解决内容，全部提交的处置仍保留 pending_semantic_review，不据此认定本地能力已覆盖。

本次未重建或部署签名 Bundle，没有执行 VM 操作。当前供 T03 使用的签名候选仍为 8777bc7e；不能将新源码修复的测试结果描述为该旧候选的运行结果。C1 单个 patchID/必需项、guest Gate、C2 持久化、可写入口的显式选择及目标 catalog 迁移仍待后续执行；本轮整合未完成。


### 2026-10-07 授权与剩余任务

用户明确回复“授权，现在还有哪些TODO”，授权仅针对前述候选 CDHash `61ea15c6739775b707d3a36fca082c4d97049be2` 的临时 amfid 操作，使用 `--spoof-apple` 和独立临时配置。不得继承路径放行或广泛允许列表，不修改持久 SIP/AMFI 设置；验收结束后停止辅助进程。授权已记录，操作尚未执行，原有启动检查失败尚未解决。

台账共 47 项：T00/T01 已验收；T02–T11 与 T24 共 11 项部分推进；T12–T23、T25–T44、T46 共 33 项待本地对账；T45 为可选延期项。46 项必选任务中仍有 44 项未完成验收。“待本地对账”不能解释为本地完全未实现。当前优先完成 T03 停机一致备份与实际恢复验收，以及 T09–T11 共同约束；标准 Swift 测试仍有 16 个 issues，原因未查明。


### 2026-10-07 T03 实际备份与恢复

T03 尚未验收。原 vm-new 正常停止，恢复点为主项目 `vm.backups/t03-vm-new-20261007-recovery-point`。65 个普通文件的备份摘要与独立 APFS 卷恢复摘要全部一致。备份实际分配 20,125,147,136 字节。ACL 与扩展属性未复制，所有者差异已记录；两份工件位于同一内部磁盘。

临时 amfid 操作仅使用已授权 CDHash 和独立空配置。签名候选 --help 退出 0，未允许的签名 debug 对照仍退出 137。SIGINT 未完成辅助进程停止；只对本轮辅助进程 PID 51380 发送 SIGTERM。随后 debugserver 退出，amfid 的 PPID 为 1、状态为 Ss；未修改持久 SIP/AMFI 设置。当前签名候选仍为 8777bc7e，不包含 ccda7f46 新代码。

首次恢复的 /private/var/tmp 测试标记缺失，失败记录保留。随后在两个客户机卷内创建相同内容的文件并 sync，停机后以 APFS 写时复制生成新副本，65 文件摘要通过。新副本启动后，mobile/Library 文件读回摘要为 `15aefbeaf947f76ad669d0708ce18323ea5c98459f5bbe6929a3e8a2a1605f87`，与写入前一致；var/tmp 文件仍缺失。该行为已观察，机制未查明，不能用临时文件缺失直接认定完整磁盘备份失败。

Settings 启动接口返回“uiopen ok but no pid”；Safari 验收未运行。SpringBoard 与 backboardd 进程存在。GUI 显示首次设置界面；普通滑动与边缘滑动返回成功，画面未推进，原因未查明。基础设置没有完成。截图和完整客户机控制台保留在 Git 忽略的私有工件目录，提交证据只记录截图摘要。

所有恢复副本已正常停止，映像已卸载并保留失败样本。原 vm-new 已恢复 GUI 运行，PID 69566，客户机连接正常。其配置与旧客户机载荷摘要未变；宿主进程使用隔离工作树的 8777bc7e 候选，主树 Bundle 未替换，API 0.7.16 客户机未激活。原 VM 的唯一专用临时标记在重启后已不存在。

复制与测试启动保持空间保护。空间不足的两次拒绝记录保留；只清理本轮隔离工作树的可重建编译缓存、中间产物和调试符号，候选字节未变，make check_bundle 与签名检查通过。五模式只读计划已保存；真实 VM 范围仅覆盖当前 EXP 26.1 样本。详细路径、命令驱动、限制及状态见 `evidence/T03-actual-summary.json`。T02/T09 源码对账继续推进。


### 2026-10-07 T09 只读迁移预览

实现提交 `698314e2` 新增 `fw selection-preview`，输入显式 select/block 与本地 variant，可单独提供 bundled-preset。识别 117 个旧点号别名、1 个 paravirt 中间别名和 143 个规范 ID（上游 141、本地 less 2）。`extended` 仅在内置预设名称空间迁为 `experimental`；五模式保持原名。新默认值不补入显式选择，显式禁用保持禁用。未知 ID、重复 ID、同一目标的多个别名和相互矛盾选择均拒绝。`fw plan` 在转为 Set 前也拒绝重复输入。

迁移输出携带固定 target 和映射 revision，并单独列出当前执行 catalog 未声明的 ID。识别 ID 不建立实际实现、适用性或启动证明；当前执行 catalog 仍为 119 个，guest Gate 和未实现声明的既有执行限制保留。该入口不读取或改写 VM，不迁移配置文件。T09 的原文件备份、原子提交、C2 持久化绑定及声明语义复验仍待执行。

第一轮 11 项测试先报告 23 个失败断言，实现后通过。预设和 CLI 第二轮 14 项先报告 6 个 issues，实现后通过。全部 FirmwarePatcher 与新增 CLI 定向测试为 242 项、41 个 suite 通过，0.883 秒。真实 debug CLI 的 13 个离线用例通过：五模式、全部 117 旧 ID、空选择及六类拒绝。生成器 --check 确认源映射与 Swift 表字节一致。

标准 make test_swift 退出 2：XCTest 234 项、3 跳过、0 失败；Swift Testing 1097 项、169 个 suite、14 issues、89.480 秒。失败为 HTTP 5、WebSocket 7、进程取消 1、helper XPC 1；原因未查明。后续 tar/guest 检查未运行。原始日志与具体失败名称保存在 `evidence/T09-default-swift.log`，没有将定向通过改写为全局通过。

T02 已完整读取两个签名单文件提交：ee8b70ca 的 SOURCE_VERSION 回收已等价实现；cd45b8fa 的 UUID 回收按既有用户决定不采纳。固定目标 Mach-O 文件唯一逻辑差异仍是保留 UUID。全局 T02 及 T04 接受依赖尚未解除。

固定目标的 PatchSelection 与 PresetStore 源码审查表明：Set 解码丢弃重复输入；损坏/缺失选择可回退标准预设；plan/receipt 的 try? 加载以及 updateReceipt 空值替代不能直接用于本地 C2/C7 写入授权。当前只读预览已采用严格输入校验，持久化和 receipt 处理另行实现。

本步未重建签名 Bundle。原 vm-new 仍由 8777bc7e 候选运行；配置、旧客户机载荷与签名 VM 二进制摘要均保持 T03 记录值。T03 应用和输入验收仍未完成，T09 也未标记 accepted。

复现入口：`python -B scripts/generate_patch_id_migration.py --check`；`.build/debug/vphone-cli fw selection-preview --variant jb --bundled-preset extended --select ibss.serial_label --block kernel-exp-paravirt_user_clients`。Python 使用项目 .venv。


### 2026-10-07 T09 显式选择文件迁移

实现提交 `dbe635c9` 新增 `fw selection-migrate <PatchSelection.plist>`。默认输出只读 JSON 预览；应用要求 `--apply --expected-source-sha256 <预览摘要>`。仅接受已审查的上游 XML 格式及三个完整字段 Preset、AllowedPatches、BlockedPatches；仅处理已知内置预设。未知字段、缺失字段、损坏、二进制格式、重复 ID、歧义或冲突均拒绝，不补入标准预设默认值。

应用复用目录独占 flock，拒绝未结束的固件事务，并核对目录及源文件身份。原字节备份先写入、读回并同步；发布前再次核对源、备份及暂存文件身份与字节，随后原子替换并读回。备份冲突不覆盖；重复应用不重写。异常清理仅删除本次创建的 inode。重命名后的异常返回 publicationUncertain，不声称已回滚。输出保留 uid、gid 和权限位，没有复制 ACL 或扩展属性。目录锁为协作式锁。

红测试发现缺少命令、二进制格式错误分类、备份被修改后仍发布、暂存字节被修改后仍重命名、清理删除同名替换文件等问题。编译阶段另出现 FoundationXML 模块不可用及测试缺 try，均修正，失败日志保留。最终 37 项迁移测试、4 个 suite 通过；相关模块 265 项、43 个 suite 通过。真实 debug CLI 的 13 个合成目录用例通过，含预览、摘要过期、目录锁、缺摘要、备份冲突、未结束事务、未知字段、损坏、实体、符号链接、幂等及原备份字节恢复；配置哨兵未变。

标准 make test_swift 退出 2：XCTest 234 项、3 跳过、0 失败；Swift Testing 1118 项、171 个 suite、16 issues，76.806 秒。HTTP 5、WebSocket 7、取消 3、helper XPC 1；原因未查明。暂存校验修复之前的串行测试为 1118 项通过，181.076 秒，不能作为最终源码的全量通过证据。最终源码串行测试日志停止更新，采样显示 APIHTTPFixture.stop 等待 NSConcreteTask.waitUntilExit；辅助进程运行 5 分 2 秒后被 SIGTERM 停止，入口退出 1。原因未查明，完整 Swift 测试尚未通过。标准入口未到达的 tar 内存检查和 guest 检查已单独运行，前者通过，后者 124 检查、0 失败。

生成器 --check 通过，仍为 118 个别名、143 个识别 ID 和 119 个执行声明。迁移只修改 desired overrides，不生成冻结计划，也不赋予写固件资格。原 vm-new 没有 PatchSelection.plist，本步没有创建默认文件或执行真实 VM 迁移。签名候选、VM 配置和旧客户机载荷摘要保持既有值；没有重建签名 Bundle 或部署新载荷。T09 的 141 声明适用性、T24 入口约束以及 C2 绑定仍待执行。

T11 的 8 次独立只读 fw plan 调用得到 8 种 enabledSteps 数组顺序和同一集合摘要。模型使用 Set 的合成 Codable，序列化顺序不固定。现有创建检查点 identityText 已对 selectedIDs 与 enabledSteps 排序；没有证据表明该摘要存在回归。后续持久化需要明确规范序列化，再绑定 VM、输入、catalog、schema 和 planDigest；当前事务 journal 与版本 manifest 不能直接作为重新执行授权。

证据入口：`evidence/T09-file-summary.json`、`evidence/T09-file-related-swift.log`、`evidence/T09-file-serial-sample.txt`。T09 与 T11 均未标记 accepted。


### 2026-10-07 T11 计划规范序列化

实现提交 `3cd5b594` 保留 VariantPlan 的原有字段，将 enabledSteps 排序后编码。解码先读取数组并拒绝重复步骤，再转换为 Set；无重复的旧乱序数组仍兼容，字段缺失仍拒绝。未新增计划文件、修改事务 schema 或授予持久化记录执行资格。现有创建检查点 identityText 的字段与排序规则不变。

4 项回归先出现 7 个 issues，修复后通过。第一次测试编译误用了 Variant.allCases 和简化 Gate 初始化，修正为已有五模式与完整 Gate 测试数据，编译错误日志保留。相关模块 269 项、44 个 suite 通过，0.891 秒；创建检查点和准备流程 43 项、2 个 suite 通过，1.293 秒。两组测试范围分别记录，不相加为整套独立测试数。

真实 debug CLI 的 8 个独立 regular 计划进程均输出排序的 enabledSteps，集合、数组顺序和完整 JSON 的摘要各只有一个值。初始驱动误将 CLI 的数组输出当作对象，发生 TypeError；修正解析与显式 variant 后通过，原驱动保留。此前 8 种顺序的只读探测与本次结果分别存档。

完整 Swift 测试没有在本次序列化修正后重跑；前一步标准 16 issues 和串行 HTTP 夹具 waitUntilExit 阻塞记录保留，不能表述为全量通过。没有签名重建、部署或 VM 操作。C2 仍需 VM/输入 build 与摘要、catalog/target/schema/planDigest 绑定，记录状态分类及原子迁移；T11 未标记 accepted。下一步复用 FirmwareTransaction.Journal、FirmwareVersionInputs 和 VPhoneCreateBundleIdentity，审查首次启动前后及 legacy VM 的身份边界，不另建平行配置源。

证据入口：`evidence/T11-canonical-summary.json`、`evidence/T11-canonical-related.log`、`evidence/T11-canonical-checkpoint.log`。


### 2026-10-07 B03：T11、T12、T14

本轮按用户要求推进三项任务，分别提交；三项均保留未完成的整项验收条件。

T11 实现提交 `345a7969`：新解析事务在现有 journal 内保存 binding schema 1，journal 使用 version 2。绑定目录 dev:ino、配置原字节 SHA-256、mode/gates、规范计划摘要、真实 catalog 摘要与 revision、固定 target、输入根原字节摘要和 manifest version/build/摘要。catalog 仍为 119 项，revision 仍为 upstream-2.2.3；记录固定目标不代表 141 项实现已接入。缺失、不可读、损坏、未知 schema 和 binding 不匹配分别表达。配置缺失时只保存目录身份，不能据此确认运行 VM 的完整更新资格。

发布前核对当前目录、配置与 catalog；恢复核对记录内部一致性、目录与配置，但不要求当前 catalog 相同，因为恢复不运行补丁算法。version 1 仍按已知输入/备份的显式恢复处理，不自动升级。version 2 缺 binding、字段不一致、摘要不一致、同路径新目录、配置变化均拒绝。目录/配置变化后的记录没有自动兼容导入。本次没有建立独立 desired-plan 配置源；稳定运行身份、磁盘/generation 对应和原子导入仍待执行。摘要是内容一致性证据，不是密码学签名。

T12 测试提交 `fea969e9`：固定目标的 pristineInput 首次保存当前文件，prepare 会在新输入解析验证前删除旧 Originals；本地不直接采纳这两项处理。现有本地 checkpoint 要求计划改变后从 prepare 重新提取归档，成功发布新树后保存旧树。新增 A→A→B→A 与坏归档保全验证通过。A→A 使用显式 prepare，补丁阶段使用合成实现；不能认定直接重复 fw patch 幂等，也不能认定真实 VM 行为通过。FirmwareOriginals 的可信输入/generation manifest、device/GPU/planDigest 绑定仍待实现。checkpoint 的 source 字符串摘要与归档内容摘要分开；本地 sourceState 核对 dev/ino/size/mtime/ctime。

T14 修复提交 `de12a679`：测试复现 marker 可预测临时文件跟随符号链接并截断外部文件，以及非法摘要仅按长度通过。修复采用 UUID 专属 O_EXCL/O_NOFOLLOW 文件、目录 fd 限定、写后读回、原子替换、目录 fsync 和创建 inode 限定清理；保留已有 marker 格式。摘要要求 64 个 ASCII 十六进制字符。保留现有 source marker、同源并发、PID 存活清理与 Range/If-Range 全包续传；不采用上游按一小时 mtime 删除 partial 的规则。缓存复用通过 size/inode/mtime 和 marker 检查，不逐次重新计算整包摘要；下载和显式 adoption 会计算整包摘要。adopted/source_verified=false 不改写为来源已验证。GPU 派生缓存、remote ZIP 成员 Range 接口、设备 catalog 与宿主权限复核仍待执行。

验证：绑定红测试 5 项、8 issues；build 红测试 2 项、4 issues；marker 红测试 3 项、8 issues。修复后三项集中 40 项、4 个 suite 通过；扩大相关范围 694 项、89 个 suite 串行通过，88.855 秒；标准固件入口 15 项、12 个 suite 通过，41.764 秒。固件比较采用本地历史 Python 参考，不等同固定上游二进制等价。测试编译中缺内层 try、Any 参数不满足 Sendable，以及标准入口误用 --suite 的错误均修正，原日志保留。完整 Swift 套件本轮未重跑；此前标准 16 issues 与串行 HTTP 等待阻塞仍未查明，不能表述为全量通过。

没有签名重建、部署或 VM 操作。vm-new PID 69566 仍运行，配置摘要、旧客户机载荷摘要和签名 VM 二进制摘要保持既有值，codesign 验证通过。未执行 amfid 操作。台账仍为 47 项：2 已验收、13 部分推进、31 待对账、1 可选延期；必选任务仍有 44 项未验收。221 份既有原始证据与 3 份原附件已逐项核对提交字节，新证据单独追加。

证据入口：`evidence/B03-summary.json`、`evidence/B03-source-review.json`、`evidence/B03-related.log`、`evidence/B03-firmware.log`。


### 2026-10-07 B04：T13、T15、T17、T32、T28

本轮按用户要求推进 5 项；各项保留完整验收条件，均未标记 accepted。代码和文档提交见 `evidence/B04-summary.json`。

| 任务 | 本轮结果 | 未完成范围 |
| --- | --- | --- |
| T13 | classic prepare 发布前检查单一生成 identity 和全部引用路径/普通文件；失败保留旧树 | GPU 恢复、缓存和编译器、vphone600 输入来源、真实固件与 restore |
| T15 | 固件根提交窗口摘要复核、全部输出读回、独占 rename；已有隔离写盘事务复验 | owner/hardlink、磁盘/配置/分组件 receipt 共同恢复及真实 VM |
| T17 | 安装回复字段、组件、摘要、集合和状态严格核对；安装后读回；异常结果保留 unknown | 客户机日志写入失败、rollback 回复、写操作协调、模式允许集合和混合版本 VM |
| T32 | 在现有 journal 保存可选 reportSHA256；提交/恢复核对报告，复用必需失败与声明检查 | 分组件 PatchReceipt、实际字节证明、generation/磁盘/客户机激活与验收 |
| T28 | 源码白名单和接口文档对账；本地 5 库、固定上游源码 7 库、上游旧文档 4 库 | 其余任务最终文档、支持矩阵、交付及 VM 执行证据 |

T15 的 3 项红测试为 12 issues；T13 的 2 个函数/7 个案例为 14 issues；T17 的 13 种回复变形在 1 项 XCTest 中产生 64 failures，非对象回复另产生 2 failures；T32 的 3 个函数/4 个案例为 11 issues。原始失败日志独立保存。T13 正向测试改用生成的合成 plist，保留原提取、合并与失败保全断言。

集中测试为 Swift Testing 113 项/7 个 suite 与 XCTest 19 项。扩展测试为 Swift Testing 719 项/92 个 suite、90.464 秒与 XCTest 117 项、3 跳过、0 失败。标准固件入口 15 项/12 个 suite、42.004 秒通过；参考为本地历史 Python 输出，不证明固定上游等价或 VM 行为。已有隔离写盘事务 18 项 Python 测试、42.670 秒通过，使用临时稀疏文件及挂载/安装命令替身。最后 T17 非对象回复字段修复另以全部 20 项宿主更新 XCTest 验证；此前扩展结果不直接覆盖该最后修改，固件源码没有后续变化。

T32 的 reportSHA256 只关联原报告字节与宿主事务；缺历史字段保留未知证据，没有创建 PatchReceipt.plist，没有从 plan.enabled 推定客户机 applied，也没有更新客户机版本。T15 复用已有 clone/完整副本/拒绝与旧盘保留逻辑；大文件 clone 检查是抽样摘要，不能表述为全文件摘要通过。

没有签名重建、部署、VM 写入或 amfid 操作。只读检查观察到 vm-new PID 69566 仍运行；配置、旧客户机载荷与签名 VM 可执行文件摘要保持既有值，codesign 验证通过。主仓库仍为 e8d825b3 且源码干净。完整 Swift 套件本轮未重跑；此前默认失败和串行 HTTP 等待仍未查明，不能表述为全量通过。

原有 238 份证据与 3 份输入副本均逐项核对已提交字节后追加本轮证据。台账为 47 项：2 已验收、18 部分推进、26 待对账、1 可选延期；46 项必选任务仍有 44 项未验收。

本轮接口说明：`T28_environment_contract.md`。复算入口：`audit_environment_contract.py`。证据入口：`evidence/B04-summary.json`、`evidence/B04-source-review.json`。


### 2026-10-07 B05：T36、T37、T38、T39、T46

本轮按用户要求推进 5 项。各项完成本轮实现与相关验证，保留完整验收条件，均未标记 accepted。六个实现/验证提交见 `evidence/B05-summary.json`。

| 任务 | 本轮结果 | 未完成范围 |
| --- | --- | --- |
| T36 | 手动 screen.unlock；screen_unlock 能力及输入队列；RPC 晚回复核对 instance/hash/generation | 自动启动选项、可信实例与 SetupAssistant/readiness 状态机、Stop/禁用取消、真实锁屏/密码/冷启动/respring |
| T37 | system.shutdown 保留 force/root/API 认证；专用能力；重复 force stop 和晚失败重复请求防护 | Launchpad/菜单 guest-first、目标超时和错误状态核对、更新/备份协调、真实停机和磁盘释放 |
| T38 | 嵌套请求参数与显式回复契约；旧 flat 回复拒绝；默认 flat 保留 | native AX walker、entitlements、前台/锁/重试、图关系诊断及真实客户机 |
| T39 | 固定上游共享策略；classic 文本 1 MiB UTF-8/图片 16 MiB；入站图片分配前限制；计数不可靠保留 unknown | Cmd C/X/V、触摸复制和失焦基线、第二段图片 await 核对、实例/输入队列/Mac rich-text 及 VM 行为 |
| T46 | 分块扫描和 CSI 扫描，保留 whitespace 与 panic 语义；分块/尾部/轮换等价测试和本地基准 | 批量 writer、操作日志归属、完整 helper 版本与 ACK/writer 排空、超时/断线/写错/退出、UI 响应 |

T36 红测试 2 项 XCTest/8 failures；T37 红测试 1 项 XCTest/4 failures 与 1 项 Swift Testing/2 issues；T38 红测试 2 项 XCTest/7 failures；T39 4 项 XCTest 中 3 项失败、11 failures；T46 红验证因缺 strippingEscapes 编译失败。分别保存原始失败和通过日志。T39 整个传输 suite 18 项 XCTest 与共享策略 4 项 Swift Testing 通过，覆盖容量边界、UTF-8、未知计数和图片头长度。T46 分行/console/轮换/follower 16 项、4 个 suite、6.225 秒通过；12 组确定性随机切块、单字节切块、Unicode/非法 UTF-8/ANSI/CRLF/未结束尾部与原实现精确输出一致。panic matcher 未修改。

相关范围为 Core、LaunchpadKit、HostRPC、GuestTransport、HostCommandExecutor、HostControlProtocol。XCTest 156 项无失败；Swift Testing 报告 530 项/78 个 suite、136.891 秒通过，另报告 6 项测试/4 个 suite 跳过，包含真实 CLI/父进程角色及 checkpoint 夹具。本轮没有重跑完整 API HTTP/WS 套件或固件对比，不能表述为全量 Swift 通过；此前全量失败和串行 HTTP 等待原因仍未查明。

候选 daemon 在 T37 后的客户机源码上用 iOS SDK 构建成功，固定依赖、架构、entitlements、动态库和清单摘要核验通过，候选二进制 SHA-256 为 `75ea2fac2921be48a0b73bf0928486a72051512a45f371e24005258ae24eab94`。构建日志含 dSYM 缺缓存模块的警告；最终 BUILD SUCCEEDED。候选保留 `activated=false`、`runtime_validated=false`，未安装。新增 unlock/halt native 方法没有在宿主或真实 VM 上执行。

补充 Python 验证最初在固定 IcliKit 0.7.16 ArchiveLocale harness 编译失败：缺 IcliLaunchPrivate.h；补齐后还缺 JSONSafe.swift，且 harness 的运行参数已增加安全夹具。按固定 checkout 的 scripts/test-archive-locale.sh 补齐头文件、JSONSafe、hard-link 与 symlink escape 夹具，保留原 Unicode/metadata/locale 断言，并输出编译诊断。10 项 Python 构建、归档与组件检查、5.110 秒通过；固定依赖源码没有修改。

分行基准采用 `swiftc -O`、3,300,000 字节输入、10 万行、每次 1 MiB 切块，各运行 3 次。原实现中位耗时 2.3098135 秒，新实现 0.039958542 秒；两端均输出 10 万行、2,200,000 字节。该结果只证明本机合成输入分行耗时，不证明 UI、VM、日志 writer 或 helper 的性能。驱动及两端源码分别保存在 B05 证据中。

固定上游仍有需要本地适配的接口边界：自动解锁把缺 instance 当作新启动，缺 setup_pending 默认 false；本地后续自动路径需按 C9 拒绝这种不完整证据。上游 clipboard 图片读取 await 后直接写 Mac pasteboard，未再次核验 instance/generation/Mac change count；C10 后续实现须补齐。上游 helper callback ACK 立即回复，服务端忽略 30 秒 wait 结果，异步 LogWriter 使用 try? 且没有 writer-drained 契约；不能直接将 ACK 表述为日志完整。这些属于固定源码审查结果，未宣称真实运行后果。

没有签名宿主重建、候选部署、VM 写入、amfid 操作或 vm-2607 操作。只读检查观察 vm-new PID 69566 仍运行；config、既有客户机载荷与签名 VM 摘要不变，codesign 验证通过。主仓库仍为 e8d825b3 且干净。磁盘可用约 11.5 GiB，本轮候选保存在隔离构建目录。

追加前逐项核对原有 267 份证据与 3 份输入副本的已提交字节。台账为 47 项：2 已验收、23 部分推进、21 待对账、1 可选延期；46 项必选仍有 44 项未验收。源码路径审查不等同于上游整个提交的语义等价，原提交覆盖台账保持待审。

证据入口：`evidence/B05-summary.json`、`evidence/B05-source-review.json`。接口约束以以上本轮范围为准；`T28_environment_contract.md` 的五库环境接口对账再次通过。


### 2026-10-07 B06：T40、T23、T41、T25、T27

本轮按用户要求推进 5 项，各项分别提交实现。五项均保留完整验收条件，未标记 accepted。完整提交 SHA 与原始日志见 `evidence/B06-summary.json`。

| 任务 | 本轮结果 | 未完成范围 |
| --- | --- | --- |
| T40 | 四类记录来源；missing/invalid/loaded 区分；带构建摘要的 local 后缀；同发布版本的两个临时 Bundle 并存；目标接口最低版本与同 series 策略 | 逐 VM 执行来源、持久化/迁移备份、创建冻结、clone/export 来源、kernel-only 与客户机同步/回退及真实混合版本 |
| T23 | 每 VM 硬件键盘开关；`vm config --hardware-keyboard` 的 on/off 选项；缺字段保持旧行为；其他编辑与机器标识更新保留设置 | 旋转坐标版本、特殊键、headless、真实 iPad/iPhone 与签名运行时验收 |
| T41 | 纯 IPv4 TCP/UDP 转发规划；protocol 序列化；默认 127.0.0.1；端口与重复/wildcard 冲突校验 | 统一网络持久化/CLI/UI、tunnel/监听/转发后端、IP/DNS/mDNS、客户机同步、真实路由与释放 |
| T25 | 拒绝重叠 global import，保留首个状态；取消后启动异常不写 actionError；原导出队列和取消清理复验 | 完整新入口、创建冻结、多 VM 部分失败/断线/重试及日志归属；并行取消时限失败原因未查明 |
| T27 | Inspector 显示四类记录来源、缺失/非法原因，实际运行版本 Unknown；按选择路径和取消隔离旧结果；保留现有自动化 RPC | 实际 receipt/wanted/planned/applied/health、缺安装 Bundle 与能力状态、AX 诊断 UI、真实选择/VM 验收 |

T40 的版本语法保持本地已识别的 release/CI 名称，并新增 `X.Y.Z-local.<8..64 位小写十六进制>`，整体仍限制 64 字节。legacy store 最低 2.2.0 保留；目标接口最低 2.6.0 和默认同 major.minor 策略分别表达，不要求 patch 数字相同。这些策略目前没有接入逐 VM 执行。绑定只读取 launchpad.json，不保存或选择可执行文件，不以 host/boot-chain 相同推断 kernel 来源。O_NOFOLLOW、regular-file 和 64 KiB 限制用于读取；尚未证明同长度并发写入时的完整快照一致性。

T40 首轮 2 项测试/10 issues 复现后缀拒绝；绑定模型缺失产生编译失败。中间验证发现测试夹具重复使用不可覆盖的 archive，随后发现 receipt 的 ISO8601 持久化丢弃 Date 小数秒；分别改为独立夹具和 canonical encoded 字节比较。30 项/5 suites 最终通过。并存测试在临时 store 中安装真实签名测试 Bundle，资源摘要不同；没有写实际生产 Bundle store。

T23 红测试 1 项/2 issues 复现键盘字段在旧 manifest 读取/更新时被丢弃。新选项明确支持 on/off，未传选项时不修改原值。运行时机器标识替换改用 updating，避免重构造丢失新增字段。18 项 XCTest 与 47 项 Swift Testing/6 suites 通过，包含 manifest、BundleOps、CLI 解析、触摸路由和传输。固定上游 manifest 已为 schema v2；本轮只适配键盘字段，旧后端仍拒绝 v2。特殊键映射仅审查，未移植。

T41 红验证因缺规划接口编译失败；随后单项测试复现 JSON 字段 transport 与固定上游 protocol 不一致，已修正。规划和原 networking 共 11 项/2 suites 通过。规划中的 tunnel 字符串允许规则不表示本地后端已有 tunnel 支持，没有监听或网络配置写入。上游 resolvesMacName 缺字段默认 true；本轮没有修改本地现有默认值。

T25 红测试 1 项/2 issues 复现并发导入覆盖 globalActivity 且执行两个导入；补充取消后缺失临时 CLI 的启动异常测试，复现 actionError 不应产生却产生（1 项/1 issue）。普通预取消测试在旧代码已经通过，不列为新增修复证据。T27 红验证因缺来源模型编译失败。最终 T25/T27 合并范围 17 项 XCTest 与 54 项 Swift Testing/11 suites 通过。SwiftPM 同时编译 Launchpad；没有进行真实 GUI 或 USB 键盘验收。

联合检查范围为 Core、BundleStore、LaunchpadKit，以及 HostRPC、GuestTransport、HardwareKeyboardCLI、CoreBundleCLI。清除真实固件验收环境选择器，排除 FirmwareIntegrationTests。首次联合运行 XCTest 128 项无失败；Swift Testing 569 项/84 suites 有 1 issue：LibraryTests.cancellingARunInterruptsOnlyItsChild 的退出状态符合 SIGINT，但耗时 30.427 秒超过 10 秒断言。原因未查明，相关子进程实现和该测试本轮未修改。单项复验 0.326 秒通过；同范围显式 --no-parallel 复验 XCTest 128 项无失败、Swift Testing 569 项/84 suites、155.831 秒通过，另报告 6 项测试/4 suites 跳过。保留失败日志，不以复验通过删除失败记录。本轮未重跑完整 API HTTP/WS、固件对比或真实 VM 验收；此前全量验证问题仍保留。

没有 Python 或客户机源码变化，未重复构建 daemon。现有 B05 候选摘要未变且未激活。只读检查观察 vm-new PID 69566 仍使用隔离 worktree 的签名 vphone-vm；其 SHA-256、CDHash、配置和既有客户机载荷摘要与 B05 一致，签名验证通过。初次宿主路径核对读取了主 checkout 的另一个二进制，原读数保存在 vm-state/host-codesign 日志；随后按进程实际路径核对，权威记录为 running-host/final-state。没有 VM 写入、amfid 操作或 vm-2607 操作。主仓库仍为 e8d825b3 且干净。

追加前逐项核对原有 313 份证据与 3 份输入副本的已提交字节。台账为 47 项：2 已验收、28 部分推进、16 待对账、1 可选延期；46 项必选仍有 44 项未验收。固定上游提交覆盖台账保持原状态，源码路径审查不等同于整个提交已合入。

证据入口：`evidence/B06-summary.json`、`evidence/B06-source-review.json`。


### 2026-10-07 B07：T35、T34、T33、T43、T44、T16

本轮按用户要求推进 6 项，分别提交实现；另提交上一轮 Inspector 的翻译目录修复。六项均保留完整验收条件，未标记 accepted。提交 SHA、原始失败和通过日志见 `evidence/B07-summary.json`。

| 任务 | 本轮结果 | 未完成范围 |
| --- | --- | --- |
| T35 | DSC 超过传入内核容量时拒绝，覆盖 maxSlide 为零、force、dry_run；容量参数校验，保留默认 6 GiB | 实际内核 base/size 证明、最终 DSC 映射与 maxSlide 成组验证、7 GiB 补丁、调用接入与启动验收 |
| T34 | 纯 krnl IMG4 载荷替换；目标 IM4M 和附加 DER 元素字节保留；重复更新返回 nil；边界和溢出拒绝 | 原件/generation/plan 校验、唯一 Preboot 文件、DSC 兼容、停机挂载、事务/receipt、CLI/UI 与保留数据验收 |
| T33 | generation、记录范围/重叠、请求 ID 和当前 patched bytes 校验后产生撤销副本；返回代码页处理所需范围 | 可信首份原件、undo 持久化/合并、DSC/Mach-O/Preboot 接入、代码页重新证明、磁盘事务及 off/on 验收 |
| T43 | 重复安全开关任一值为 1 即禁用；超过 4096 项按禁用处理；来源摘要核对、候选构建和宿主验证 | 完整 Hook 门控清单、VCam 线程/页保护、版本相关 paravirtual I/O 适配、环境资格、部署与真实模式验收 |
| T44 | 受限清单与 board DeviceTree 成员读取；身份字段、regular file、路径、容量和歧义检查 | 产品/board 配对独立验证、dtre IM4P、设备目录/restore/runtime/scale、可信原件存储/缓存与迁移/启动验收 |
| T16 | 拒绝非法或矛盾的环境更新报告、空/重复/路径替换列表；保留 root driver 复检和旧五库接口 | 完整 replace/migrate/rebuild/reject 资格、安装/loader/plan 证据、内核/DSC 配对、停机事务和真实旧 VM 验收 |

T35 的容量来自调用参数，本轮没有实际内核解析证明。显式传入 7 GiB 不证明 VM 已扩容；默认 6 GiB 保留。红测试为 16 项中 1 failure、1 error；首轮修复后，旧测试仍将超容量且 maxSlide 为零描述为 no-op，导致 1 error。按原 C8 拒绝条件改为超容量拒绝并检查字节未变，最终 16 项通过。补丁比较文档记录此次拒绝行为，没有新增内核指令补丁。固定上游安装器在缺 kernel receipt 时使用 27.x 版本推断容量，并可跳过不可读取的 region header；本地后续接入须遵守 C8 的实际证明和 unknown 拒绝要求。

T34、T33、T44 首轮均因缺失新接口编译失败。T34 三项测试验证原始 IM4M/附加元素字节、幂等和畸形 DER；保留字节不等于签名或启动验证。T33 三项测试验证选择性撤销、同页其他补丁保留、JSON 往返、错误 generation/当前字节/缺记录/非法范围/重叠拒绝；它只生成内存副本，不认证调用方原件。T44 三项合成归档测试验证多 board、重复相同来源、冲突和不安全路径；测试使用固定目录中的 d47ap/iPhone17,3 与 j717ap/iPad16,3，不证明真实 IPSW 或设备启动兼容。

T43 红测试 3 项中 2 项失败，修复后 3 项通过。来源检查还发现历史提交 5d1bdaf8 的 LocationFix 修改未记录 local_sha256；当前字节与该已提交修改一致。补齐 local 摘要和说明，保留原 upstream revision/hash；同样记录本轮共享头文件摘要。iOS SDK 候选构建与来源/架构/签名/清单核对通过，构建包含现有 LocationFix 静态初始化警告。RootHide loader link 测试通过，摄像头宿主路径 124 次检查无失败。候选继续保持 activated=false、runtime_validated=false，保留 64 字节摄像头协议头且不兼容 classic camera，未安装。

T16 红测试 1 项产生 9 issues；环境更新和提权复检相关 10 项、3 suites 最终通过。该修复检查报告结构与状态一致性；固定目标七库接口尚未替换本地五库接口，不能据此声明新环境具有更新资格。

串行联合 Swift 范围为 FirmwarePatcher、Archive、Core，以及 CFWEnvironment、GuestEnvironmentUpdate、HostRPC；清除真实固件选择器，排除 FirmwareIntegrationTests。XCTest 135 项，其中 3 项跳过，无失败；Swift Testing 714 项/99 suites、88.107 秒通过，另报告 12 项测试/8 个 suite 跳过，包含真实固件/less 验收。未重跑完整 API HTTP/WS 或真实固件对比；此前全量 Swift 与并行取消时限问题仍保留，原因未查明。

Python 全套首轮运行 564 项、256.960 秒，只有字符串目录测试失败。原因是 B06 提交 cffd033a 新增的 7 个 Inspector 文本缺少翻译目录条目。补齐 en/zh-Hans 条目后，14 项字符串测试通过；完整复验 564 项、260.889 秒通过。保留首轮失败日志及修复提交。

没有签名 VM 宿主重建、候选部署、VM 写入、amfid 或 vm-2607 操作。只读检查观察 vm-new PID 69566 仍使用隔离 worktree 的既有签名 vphone-vm；其 SHA-256/CDHash、配置和既有客户机载荷摘要未变，签名核验通过。主仓库仍为 e8d825b3 且干净。

追加前逐项核对原有 348 份证据与 3 份输入副本的已提交字节。台账为 47 项：2 已验收、34 部分推进、10 待对账、1 可选延期；46 项必选仍有 44 项未验收。步骤、验收、回退、依赖和接口约束未改写。固定上游提交覆盖台账保持原状态，源码路径审查不等同于整个提交已合入。

证据入口：`evidence/B07-summary.json`、`evidence/B07-source-review.json`。
