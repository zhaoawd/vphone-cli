# 固定上游整合执行记录（2026-10-06）

本轮目标为 `2d21d21fbdd4f51f013616273ceda9b35a3e0789`。主工作区基线为 `e8d825b3723d9ec72d31b050a79d353acd4b59bf`，实施分支为 `codex/upstream-2d21d21-integration`，使用已经附加的隔离工作树。主工作区代码未修改。当前验收结果见末尾 B27 记录；后续章节保留各批次当时的状态。

`inputs/` 保存用户提供的三份附件原文；来源路径、摘要与大小见 `input_manifest.json`。附件内的历史状态、旧 sandbox 链接和实施授权字段仅表示原文状态。本轮授权来自用户“开始推进”“继续”；实际状态记录在 `tasks.json`。

## B21 历史结果（2026-10-09）

本轮选定 T02–T08、T24、T40、T46 共10项，新增验收完成 T03/T04/T05；其余7项未满足完整接受条件。47项中5项accepted，41项必选尚未完成，T45可选延期。基础项目独立验收依据原方案“基础修复可单独验收”；342提交的全局语义核对保持未完成。

| 任务 | 结果 | 未完成范围 |
| --- | --- | --- |
| T03 | 65文件实际恢复一致；恢复副本启动、通信、Settings前台及SystemVersion摘要通过；正常停机退出0 | 同卷APFS写时复制不提供离盘故障保护；本EXP样本不代表五模式全组合 |
| T04 | 已有LC_UUID保留决定保持；签名、边界和最终产物检查通过 | 空间不足仍拒绝；不引入UUID回收 |
| T05 | 多语言、路径/链接保护、坏包及目标保留、归档互操作通过；真实CLI ustar UID/GID0往返通过 | 完整64GiB VM归档导入/导出未执行 |
| T02 | 实际路径与已审查能力处置更新 | 303提交仍pending_semantic_review，不按标题或路径判定等价 |
| T06 | 六组8/16KiB边界通过 | 1MiB间歇下载停在917504字节；8MiB慢读/提前断线矩阵未完成；原因未查明 |
| T07 | 真实proxy/worker退出及重启通过；未确认缓存spawn失败返回launchd修复通过 | 完整升级确认及daemon组合未验收 |
| T08 | 固定pin、构建和运行hash一致；40次launchd查询FD保持18 | 20次截图footprint约87→465MB；操作自动释放池未解决增长；位置返回400，RootHide/timezone矩阵待验 |
| T24 | 普通launcher、本地受控CLI、跨进程SHA/版本核对、未知VM协议拒绝、位置权限说明通过 | TCC真实责任链及依赖闭包；不执行会自动更新guest和扩大权限的官方CLI |
| T40 | 绑定经过launcher与本地wrapper冻结；旧官方Bundle并存证据保留 | 合法本地CoreBundle缺escalator、真实绑定启动、创建全流程和四层来源矩阵 |
| T46 | 真正helper安装/独立verify成功，61/60字节0600日志完整且关闭 | 完整UI即时退出、detached/create/后代writer和吞吐矩阵 |

独立审查发现4项Important，已在一轮修复中处理：执行sealed本地CLI而非官方CLI；传递预期binding SHA/版本；未知VM受控协议在preflight前拒绝；用无TTY真实子进程测试核验四种停止信号转发、最后输出和等待退出。没有声称完成第二次独立审查。审查者误尝试了含loopback的既有fixture，已停止，结果未用于完整验收。

原始编译日志包含尾随空白，按原文保存并核对摘要。源码、文档及非日志证据的暂存差异空白检查通过。

Python578项通过。首轮标准Swift1251项有1个新增fixture未满足5秒就绪条件；保留失败，并行运行时的启动时限原因尚未完全确定。将该测试加入既有计时组，原5/3秒时限不变；最终标准Swift常规1250项、计时6项、XCTest254项/3skip通过。四种停止信号红测试另复现三种信号留下VM stand-in；修复后四组通过。第二次标准Swift运行的归档清理断言失败：测试使用共享临时目录，观察到其他测试的staging文件。用无关标记稳定复现后改为专用归档父目录，保留清理断言；7项定向测试与最终标准入口通过。首次信号红测试因输出读取等待孤儿进程而阻塞，仅结束精确匹配的测试运行器和stand-in，随后改为先检查子进程退出再读尾部，保留清理记录。操作自动释放池已通过真实ObjC临时对象成功/异常路径测试。实际截图增长在修复候选上仍复现，不能宣称泄漏已修复。生产classic daemon、256字节/v3相机和原VM关键摘要保持；现代API_ONLY只在恢复副本的隔离目录运行。原VM和恢复副本均停机、磁盘释放；临时helper、授权项、AMFI驱动及debugserver均不存在，token已删除。AMFI清理脚本出现一次断言失败；后续独立readback确认进程和debugserver不存在、系统amfid由launchd管理，未将断言失败当作正常detach。

新宿主诊断候选CDHash `4cea360ca924a4c651a12aae7755545b492a59b6`、SHA256 `1d21a984f4621fcc291ebc6d48bc572ec1c316752183dbcf40469a7778a4eb80`已冻结，仅增加socket类型和字节计数。精确临时AMFI范围授权待回复，未启动该候选。权限请求依据executing-plans对security-sensitive action的要求；此前授权仅覆盖B16哈希。无持久安全设置修改。证据入口：`evidence/B21-summary.json`、`evidence/B21-source-review.json`、`evidence/B21-full-tests.log`、`evidence/B21-final-swift-retry.log`、`evidence/B21-final-readback.json`。

## 初始结果与范围（2026-10-06，历史记录）

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


### 2026-10-07 B08：T21、T18、T19、T20、T22、T26

本轮按用户要求推进 6 项，共 8 个实现提交。六项保留完整验收条件，均未标记 accepted。源码、修正记录、完整 SHA 与原始日志见 `evidence/B08-summary.json`。

| 任务 | 本轮结果 | 未完成范围 |
| --- | --- | --- |
| T21 | 64 KiB、regular file、O_NOFOLLOW 完成记录读取；非法主记录拒绝、主 tombstone 覆盖 legacy；保留原 RootHide checksum | 可信记录与根目录证明、服务/基础初始化、现有密码/host keys/包状态和真实重复安装验收 |
| T18 | 默认刷新绑定完成 bootstrap 的 Applications；缺目录拒绝；显式规范绝对目录保留；API 错误保留 Icli commandFailed 详情 | MIS/installd 与模式签名、实际应用安装/扩展注册/provider 启动、真实错误回复 |
| T19 | 分别比较 expected/guest/host；USB serial 规范化；缺失/非法/差异/匹配区分 | 真实身份采集、调用方接入、set/clear/reboot/USB/Hook 适配及宿主发现/信任 |
| T20 | 宿主与模拟来源缓存分离；有效且年龄绝对值小于 60 秒才复用；非法重放间隔拒绝、清理按来源代次核对 | 独立定位 helper 打包/签名/TCC、权限/退出/重连、真实新鲜定位及旧重放清理 |
| T22 | 排队帧独立 CLOEXEC 描述符、单项未完成帧和发送超时；晚失败核对连接/来源/描述符；保留本地 wire/回执 | 完整媒体组件组合、实际 socket/source 切换、持续内存与 guest 重启、预览和拍照 |
| T26 | 键盘可选字段贯通 manifest 报告、Launchpad 解码与设置；缺字段仍开启，只发明确编辑项；双语条目 | 其余目标管理/后台/网络/关闭项、真实签名 UI、多 VM 与实际硬件键盘输入 |

T21 的 3 项真实文件测试验证主 tombstone 不改写旧用户记录、非法/numeric/linked/oversized 主记录不回退，以及 RootHide checksum/目录范围。T18 的 3 项路径测试区分默认 bootstrap 与显式目录。两者首轮因新接口缺失编译失败。本轮只改变读取/default refresh，安装、marker 写入、密码、host keys 和包操作逻辑未改写。受限读并不证明 marker 来源可信或同长度并发写入的一致快照。

T18 初次封装保留了 IcliError，但复核 APIWire 发现输出仍被丢弃。新增错误详情 JSON 测试先失败，补齐 error.details 后 1 项通过；failed/unverified 与机器错误码在 JSON 往返中保留。该测试没有执行真实 HTTP/WebSocket 请求。固定 IcliKit 0.7.16 源码与锁定 checkout 核对，应用/plugInKitPlugins 接口已经存在；未宣称实际 .appex provider 已注册或启动。

T19 首轮因缺比较 API 编译失败，3 项 Swift 测试通过。比较输入由调用方提供，不采集真实身份，也不证明配对/信任；没有新增身份写入。T20 首轮因缺缓存/计时 API 编译失败，82 项定位相关 XCTest 通过；固定源和 replay 不再写宿主缓存。采用固定上游 60 秒缓存边界，但本地仍使用现有 CoreLocation manager，独立 helper 与权限职责尚未接入。

T22 首轮因缺描述符 lease 编译失败，真实 pipe 复用测试及相关范围 11 项 XCTest 通过。复核发现首个提交的晚失败回调仍只有 fd 检查，文本替换未匹配原代码；增加连接/来源匹配测试，排除 T26 缺 API 的编译干扰后，单独确认缺 isCurrent 接口。第二个提交补齐检查。测试覆盖真实 descriptor 复用、lease 关闭和纯匹配条件，不证明 VZ 真实晚回调已执行。原 v3 generation/presentation/消费回执协议保留，未替换为单个上游媒体组件。

T26 初始测试误用了不存在的 decodeInfo；改为现有 decodeList 后，确认 Settings 和键盘属性缺失的失败，再实现。最终测试使用实际 manifest/report 编解码，验证 false 传递、legacy nil 默认及仅明确编辑字段进入命令。与相机补充范围共同通过 3 项 XCTest 和 19 项 Swift Testing/4 suites；首个 ledger 计数 5 已更正为 3。SwiftPM 同时编译 UI，但未进行真实 GUI/键盘验收。

串行相关 Swift 范围为 Core、LaunchpadKit、定位、相机与传输/控制接口；清除真实固件选择器，排除 FirmwareIntegrationTests。XCTest 167 项（0 项跳过）无失败；Swift Testing 553 项/84 suites、137.172 秒通过，另报告 6 项测试/4 suites 跳过。Python 全套 571 项、254.700 秒通过。未重跑完整 API HTTP/WS 或固件对比；此前全量 Swift 与取消时限问题保留，原因未查明。

最终 daemon 候选按固定依赖构建，来源/架构/签名/清单核对通过，SHA-256 为 `1b76423d0d212972ad67cbc50e8119d571aa0a1584c8bda1d5eeb4d0f9d26962`。构建中的 dSYM 缓存模块警告保留；候选 activated=false、runtime_validated=false，未安装。本轮未重建签名 VM 宿主，也没有 VM 写入、amfid 或 vm-2607 操作。只读检查观察 vm-new PID 69566，现有宿主 SHA-256/CDHash、配置与客户机载荷摘要未变，签名验证通过；主仓库仍为 e8d825b3 且干净。

追加前逐项核对原有 387 份证据和 3 份输入副本的已提交字节。当前 47 项：2 已验收、40 部分推进、4 待对账、1 可选延期；46 项必选仍有 44 项未验收。未改写步骤、验收、回退、依赖和接口约束；固定上游提交覆盖台账未改变。

证据入口：`evidence/B08-summary.json`、`evidence/B08-source-review.json`。


### 2026-10-07 B09：签名候选与 vm-new 实际验收

本轮没有修改实现源码。基于 `2387af2015f3e86dbddca43d9ba1a9b06344c4b0` 执行 `make build`，完整 Bundle 的资源、嵌入权限和签名检查通过；`check_bundle.py --execute` 的仓库外工作目录及符号链接资源定位通过。Launchpad 构建与双语资源、嵌入 CLI/VM CDHash 一致性及外层签名检查通过。工件分别保存在 `.build/acceptance/B09/{baseline.app,candidate.app,launchpad.app}`，逐文件摘要为 196、197、206 个文件，具体清单见 `evidence/B09-artifact-manifest.json`。工件保存并不构成发布签收。

| 任务 | 结果 | 未完成范围 |
| --- | --- | --- |
| T03 | 新停机 APFS 检查点 65 文件摘要及源元数据一致性通过；旧宿主启动 vm-new 并连接 | Settings/Safari 仍无 PID；未通过应用与完整恢复验收 |
| T19 | 宿主 usbmux USB serial 与预测 UDID 一致；只读发现，不创建配对或信任 | guest 独立身份未采集，新比较接口未接入运行路径 |
| T22 | classic 摄像头通道连接、来源 off；定位来源 off | 当前运行旧宿主，不验证本轮写入 lease；预览、拍照和最终组件组合未测 |
| T26 | 本轮签名 Launchpad 及嵌入工具链校验通过 | 新 UI 操作、实际硬件键盘输入及其他管理场景未测 |
| T29 | CLI/VM/Launchpad 候选组装和摘要保存完成，保留上一完整 Bundle | 新 VM 可执行文件直接退出 137，限定临时放行授权待确认；版本矩阵、T28 前置验收未完成 |

新增停机检查点为 `/Users/qcz3840/github/vphone-cli/vm.backups/b09-vm-new-stopped-20261007-second`。首次克隆的每个文件摘要一致，但最后源元数据比较失败；该次未记录具体变化项，原因未查明，`.staging` 失败样本保留。第二次在不降低检查条件的情况下记录差异，65 文件通过，`source_metadata_changes={}`。这属于同 APFS 卷的写时复制检查点，不证明物理介质独立；此前独立卷恢复与原备份继续保留。

本轮新 VM CDHash 为 `52b10bcbce6db82de6afa83b801eb95da55246c7`，直接 `--help` 退出 137。此前授权只覆盖 `61ea15c6739775b707d3a36fca082c4d97049be2`，没有自动扩大授权。已请求为新哈希使用独立空配置、`--spoof-apple` 的限定临时放行；回复尚未收到，新哈希辅助进程未运行。执行技能将 security-sensitive action 列为暂停确认项，具体来源为 `/Users/qcz3840/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/executing-plans/SKILL.md`。

实际运行使用旧宿主 `8777bc7e47795939badf222fbc4bbe7d8e3e6584`，PID 60709，显式指定 EXP 和 vm-new 原 `.vphoned.signed`。旧工件从保存路径直接启动也被系统终止，之后按已有精确哈希授权运行独立临时辅助进程，VM 启动并连接。实际 guest `/usr/bin/vphoned` 读回 SHA-256 为 `306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001`，与宿主原载荷一致。配置 SHA-256 保持 `e75cf6fa7170f3cc67fcc63077aa48ca43e6b3e2aa4d612c6878303b65053dee`。没有部署 API-v2 daemon 或 shared-components 候选，也未改写 kernel/Preboot。

错误 instance 请求返回 `target_mismatch` 与 `operation_may_continue=false`，匹配 instance 的请求通过。应用列表读取 235 项，classic 服务与 v3 摄像头能力可见；API transport 返回 `api_not_ready`。上述结果只验证旧组合。本轮曾发出不带 generation 的 camera_status，被参数检查拒绝；带测试 generation 的只读状态返回 connected=true、source=off，不证明发布、消费或拍照。

屏幕先显示欢迎页，随后显示外观页，再显示主屏幕。驱动只发送一次普通上滑；没有执行条款、账号或权限确认。完整页面转移过程尚未确定。主屏幕出现前后，Settings 与 Safari 程序化启动均返回 `uiopen ok but no pid`，对应进程查询无结果。一次 Settings 图标触控返回 ok，但截图仍为主屏幕，进程查询仍无结果；命令回复不作为应用启动证明。CUA 选择确切旧 Bundle 后观察到黑色 VM 显示区域，而 host-control 截图显示主屏幕，原因未查明；仅前置窗口，未在黑色区域执行坐标点击。CrashReporter/Retired 清单未列出对应应用崩溃文件；列出两项 Setup ExcUserFault，但未分析内容。guest `launchctl asuser` 探测返回不支持该子命令，没有执行该探测中的 uiopen，不能据此验证用户 bootstrap 假设。

临时旧哈希辅助进程退出码 1，报告 `Unexpected process state 10` 和 detach disconnect 失败。之后 launchd 显示 amfid 最近退出原因 `JETSAM_REASON_MEMORY_IDLE_EXIT`；最终进程检查无该 helper 或 debugserver。vm-new 继续运行、通信可用。未修改持久安全设置。首次最终进程快照误用 Darwin 截断的 comm 字段，已改用完整 command 字段并断言 PID/路径；最终证据记录了修正。

T29 提前准备工件，不视为 T28 已验收。本地 Info.plist 仍为 1.0，Core Bundle 代码最低版本仍为 2.2.0，目标计划的 >=2.6.0 与支持 major.minor series 策略尚未接入；版本数字不证明官方功能等价。没有重跑此前完整 Python/Swift 测试，也未把此前定向通过计为本轮新的用例。完整 Swift/API HTTP/WS 的既有失败与未测范围继续保留。

台账为 2 项 accepted、41 项部分推进、3 项待本地对账（T30/T31/T42）、1 项可选延期；44 项必选任务仍未验收。主仓库源码仍为 e8d825b3 且干净，vm-2607 未操作。证据入口：`evidence/B09-summary.json`。


### 2026-10-07 B10：新候选启动、正常停机与重启验收

用户回复“确认授权”后，按本次明确范围执行新候选的临时 amfid 操作。授权只覆盖冻结 VM 工件的 CDHash `52b10bcbce6db82de6afa83b801eb95da55246c7`。使用独立空临时配置、`--spoof-apple`、`paths=[]`、`allow_all=false`。没有扩大到其他工件或路径，没有修改持久 SIP/AMFI 设置。本轮 SIP 与 authenticated-root 观测输出和 B09 字节一致。

本轮没有修改实现源码或重新构建。实际运行的是 B09 完整签名候选，源码 SHA 为 `2387af2015f3e86dbddca43d9ba1a9b06344c4b0`，VM SHA-256 为 `fe835bab19e8f71338adf803ae496b5906c75ceb4f2b34b16963970edba25a87`；B10 文档追加前的提交为 `2d02850e8722d83df5c3d68205f882d62f2165c9`。baseline、candidate 和 Launchpad 保存工件共 599 个文件的摘要再次核对通过。文档提交不改变候选来源 SHA。

| 对象 | 结果 | 验收范围 |
| --- | --- | --- |
| 停机检查点 | 65 文件摘要一致，源元数据变化项为空 | 同 APFS 卷写时复制；不证明物理介质独立 |
| 新宿主与 classic guest | 首次启动、连接、正常停机退出 0；无辅助进程重启后再次连接 | 原 daemon 组合兼容检查；不验证未部署的 API-v2 daemon |
| 数据持久化 | 70 字节测试文件跨重启摘要一致，核对后清理成功 | 本轮测试文件；完整恢复和目标应用验收仍未完成 |
| instance 约束 | 上次启动 instance 被拒绝，`operation_may_continue=false`；当前 instance 请求通过 | 两次实际启动间的宿主控制约束 |
| HTTP 认证 | 缺失/错误令牌返回 401；重启后旧令牌返回 401 | 宿主代理认证与令牌轮换检查 |
| 客户机 API | 正确令牌健康请求返回 502；session 为 reconnecting/transport，environment_status 返回 api_not_ready | 健康验收未通过；未执行环境安装、更新或回退 |
| GUI 与应用 | 未观察解锁成功；Settings/Safari 返回 `uiopen ok but no pid`，对应进程查询无结果 | 本轮应用探测位于锁屏；不能据此确定启动失败原因 |

停机检查点保存在 `/Users/qcz3840/github/vphone-cli/vm.backups/b10-vm-new-stopped-20261007`，检查没有降低为只检查文件存在。它是本轮写入测试文件前的恢复点；重启前只再次核对配置、原 guest 载荷、空间和文件占用，不宣称修改后的整个磁盘仍与检查点相同。此前原备份、独立卷恢复记录及 B09 失败样本继续保留。

第一次新候选运行 PID 为 87653，instance 为 `5F7970EC-0380-448B-ADDF-A0F11FD0F543`。测试文件写入前确认目标不存在，读回 SHA-256 为 `8c9377cc74e3e190b6934b8b0e6767daf488a79ec9f2e9ce60ccbb00313a5beb`。随后向核对过命令路径的该 VM PID 发送 SIGINT，日志记录 graceful shutdown、guest power-off 请求连接结束及 `Guest stopped`，父驱动退出 0。停机后同一 VM 工件 `--help` 明确返回 0。第二次启动没有重新运行 amfid 辅助进程，PID 为 92943，instance 为 `068574F6-DEF3-4910-88AB-57F5330C7A02`。测试文件读回摘要一致，之后删除并验证路径不存在。vm-new 在本轮最终检查时继续运行。

两次启动均显式指定 EXP 与 vm-new 原 `.vphoned.signed`。实际客户机 `/usr/bin/vphoned` 读回为 240352 字节，SHA-256 保持 `306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001`；配置与身份预测文件摘要未变。嵌入签名读取列出 250 个 entitlement，预期键缺失项为空。该读取只证明签名中的字段，不证明运行时权限授予。没有安装 API-v2 daemon、shared-components 或修改 kernel/Preboot。

CUA 选择确切 candidate.app，观察并操作 Home 工具栏按钮、垂直拖动和 Return。屏幕仍显示锁屏；原生窗口捕获在部分检查中为黑色，原因未查明。命令返回不证明解锁、触控或实际硬件键盘输入成功，没有输入凭据或执行设置条款确认。`apps-after-home`、`home-before-launches` 等文件名沿用旧驱动命名，本轮这些文件不证明已进入主屏幕。B09 在已观察主屏幕时也出现 Settings/Safari 无 PID，两个实验设置分别保留。

临时辅助进程 PID 87460 在 SIGINT 后未退出；核对同一进程命令后发送 SIGTERM，父会话退出 143。随后进程快照没有该 helper/debugserver，amfid 为 PPID 1、状态 Ss。记录清理结果，不宣称 Python finally 或 detach 流程成功。首次启动令牌在服务器停止后删除；运行中的重启令牌保留于本机 0600 私有文件。令牌值没有写入研究证据，监听限定为 127.0.0.1。

原始失败尝试与修正均保留：测试驱动首次 file_put 使用 `data` 被拒绝，改为 `data_b64` 后写入；首次 rm 因 guest PATH 找不到命令，显式使用已有 PATH 后清理通过；不带 generation 的 camera_status 被拒绝，补字段后只读状态为 connected/source off；guest shasum 不可用，实际 daemon 摘要改由 file_get 字节计算。没有把这些驱动错误记录为产品修复。原始 help-before/help-after 文本没有保存明确退出码，不据此推断状态；停机后的 restart-help-result 单独保存 returncode=0。

T03 与 T29 保持部分推进。T28 前置验收、目标 Core Bundle >=2.6.0、支持 major.minor series 策略、完整混合版本升级/回退矩阵，以及已恢复样本的目标应用仍未通过。此前完整 Swift/API HTTP/WS 的失败与未测范围保留，本轮未重跑测试套件。47 项台账仍为 2 项 accepted、41 项部分推进、3 项待本地对账（T30/T31/T42）、1 项可选延期，44 项必选任务未验收。固定上游提交覆盖台账未改变。

追加前核对 471 份原证据与 3 份输入副本的已提交字节；新增 53 份证据后清单为 524 项。重启日志保存有界快照，私有原日志继续写入。主仓库源码仍为 e8d825b3 且干净，vm-2607 未操作。证据入口：`evidence/B10-summary.json`、`evidence/B10-session-results.json`、`evidence/B10-restart-check.json`。


### 2026-10-07 B11：T42 音频算法与应用启动排查

T42 从待本地对账进入部分推进。本轮实现提交为 `7e0503df4be0408108e3a4ca14597dee4cecc0c3`，导入固定目标 `2d21d21fbdd4f51f013616273ceda9b35a3e0789` 的 Ring、Clock、Converter、Filter、Latency、Protocol 六个模块，共 12 个源码/头文件和四个宿主测试程序。逐文件来源在 `dependencies/virtio-sound-pins.json`；只有延迟周期算法及其测试含本地差异。音频来源清单独立于现有六个 dylib 来源清单，不扩大其激活范围。

首次测试确认本地算法源码缺失。导入后，`testPeriodsSaturateBeforeAdditionOverflow` 在 UINT64_MAX、周期 32768 和 UINT32_MAX 两个输入上失败。原因已确认：原实现先计算 `bytes + periodBytes - 1`，uint64 加法溢出发生在取整和 UInt32 饱和之前。改为商加非零余数，再执行原饱和逻辑；回归与原用例通过。保留两个失败日志，不将缺源码编译失败计为数值问题的复现。

| 对象 | 本轮结果 | 未验证范围 |
| --- | --- | --- |
| 宿主组件入口 | RootHide loader-link、相机 124 次检查和四个音频程序通过 | 实际客户机组件加载与媒体行为 |
| 音频算法 | PCM 选择、ring 生命周期、输入积压/重启、44.1/48 kHz 转换、时钟竞争、高通和延迟用例通过 | HAL 调用、采集期间控制和音频设备 |
| 内存检查 | 四个程序在 AddressSanitizer/UndefinedBehaviorSanitizer 下通过 | 未运行 ThreadSanitizer；不据此证明所有并发场景 |
| iPhoneOS 编译 | 六个算法模块以 arm64e、iOS 26.0 编译为目标文件 | 未链接 HAL driver，不证明实际 OS/设备兼容 |
| Python | 完整套件 571 项、268.152 秒通过 | 此前完整 Swift/API 与固件/VM 未测范围保留 |

`make test_guest_components` 已包含音频来源检查和四个程序，原 fast Swift 入口会调用该目标。六个既有签名 dylib stage 的来源、签名与记录摘要核对通过，stage 内容没有改写；新音频模块不加入该安装包。HAL 插件、VirtualAudio 路由与麦克风链、DeviceTree/kernel 资格、宿主 TCC/采集生命周期、宿主延迟同步和完整部署/升级/回退仍待实现。T42 的原依赖和验收条件保留，算法用例不能代替真实录放、双工、静音、权限拒绝或其他机型验收。

vm-new 继续运行 B09 冻结的源码 `2387af20` 候选，PID 92943、instance `068574F6-DEF3-4910-88AB-57F5330C7A02`。本轮没有 VM 宿主重建、daemon/shared-components 安装、kernel/Preboot 写入或 amfid 操作。最终再次核对保存工件 599 个文件摘要，实际客户机 daemon、配置和身份预测摘要未变，主仓库源码仍为 e8d825b3 且干净。新源码提交与当前 VM 工件来源分别记录。

最新 host-control 截图显示主屏幕，但不证明哪次输入完成了解锁。Settings 程序化启动仍返回 `uiopen ok but no pid`。应用注册信息指向存在的 `/Applications/Preferences.app/Preferences`；uiopen 帮助中的参数与 classic bridge 一致。Safari 注册路径位于 application container，旧假定 `/Applications/MobileSafari.app` 的缺失不能证明已注册 Safari 不存在。一次主屏幕 Settings 图标触控返回 ok，之后未观察目标进程，稍后的彩色截图摘要与触控前一致。原因未查明，未据此改写安装、签名或权限逻辑。

客户机没有 notifyutil 和 log。日志采集中的 `log show | tail` 最终退出 0，但 stderr 为 log not found，不能记为日志读取通过。另在确认 su 与 uid=501(mobile) 存在后，以 mobile 身份运行一次 uiopen，命令退出 0，立即进程样本无 PID；最终独立样本仍没有 Settings/Safari 进程。用户 ID 变化没有证明可用启动路径，Mach bootstrap 或运行时权限原因仍未确定。没有输入密码或更改账号、服务配置。classic 通信仍可用，API 为 reconnecting/transport，environment_status 为 api_not_ready。

追加前核对原有 524 份证据与 3 份输入副本的已提交字节；本轮新增 18 份证据。47 项台账为 2 项 accepted、42 项部分推进、2 项待本地对账（T30/T31）、1 项可选延期，44 项必选仍未验收。固定上游提交覆盖台账未改变，vm-2607 未操作。证据入口：`evidence/B11-summary.json`、`evidence/B11-source-review.json`、`evidence/B11-app-boundary.json`。


### 2026-10-07 B12：五项状态管理与宿主接入

本轮推进 T36、T37、T39、T40、T46，仍为部分完成。实现终点 `c1cb3099ee62be0f4fc1ce9e17052252cb0ca762`，固定上游目标保持 `2d21d21`。本轮七个本地提交分别记录五项实现及两处复查修正，不据此调整上游语义提交覆盖数量。

| 任务 | 本轮结果 | 剩余范围 |
| --- | --- | --- |
| T36 自动解锁 | direct boot 新增默认关闭的 `--unlock-at-startup`；可信 instance/hash/generation 去重；启用不立即解锁当前实例；Setup Assistant unknown/pending 跳过；停止、断线、换连接和关闭后旧任务失效；与手动宿主输入共用队列 | 当前 daemon 缺少 setup_pending 提供方；持久配置、菜单/Launchpad/vm launch 转发和真实锁屏、密码、启动/重启验收 |
| T37 停止 | CLI Stop 失败后不再追加 SIGINT；成功时保留 launch wrapper 清理；真实测试子进程与既有关机策略通过 | API guest-first、更新/备份冲突与磁盘释放、真实关机和旧 guest/DFU/panic |
| T39 剪贴板 | 窗口焦点与连接观察接入 classic；本连接可靠计数基线；连接、修改和焦点代际及 Mac changeCount 淘汰旧回复；自动 type/set 后重建基线；原文本 1 MiB/图片 16 MiB 限制保留 | Cmd C/X/V 传输入口、API 分开图片下载的第二次 await、真实图片/rich text/快速切窗/重启 |
| T40 绑定 | 快照冻结 SHA-256、device/inode、mtime/ctime；检测读取期间同长度改写和路径替换；同字节重写也使旧快照失效；现有来源读取复用该检查 | 执行路由/可执行文件校验、持久化/迁移备份/创建冻结、clone/export 和四层更新收据；快照不是原子事务 |
| T46 日志 | 分开退出码、同步 reader callback 排空和显示列表省略行数；启动/创建/命令历史接入完成状态；并发归属、尾部、EOF/读取错误与即时 pipe 输出通过 | 异步批量 writer、完整 helper/client 协议与 ACK、30 秒超时/断线/写失败/应用退出、UI 和真实 VM 吞吐 |

最终联合验证命令覆盖完整 VPhoneLaunchpadKitTests、Clipboard、StartupUnlock、APIWire、HostCommandExecutor、HostRPC、VMStop/Shutdown 以及两项模拟 API 会话测试。XCTest 47 项、Swift Testing 报告 217 项/49 个 suite，退出 0。单项还运行了 classic guest transport 全部 18 项。没有运行完整 Swift/Python/固件套件；此前完整 Swift/API 的未解决结果保留，未声称通过。来源和本地适配见 `evidence/B12-source-review.json`，8 个上游参考文件都来自固定 SHA，24 个本地变更文件分别记录摘要。

本轮保留全部失败记录。T37 初始用例以 3 个断言复现停止拒绝后的多余 SIGINT。T40 同字节重写最初仍匹配旧快照，回归失败后加入 mtime/ctime。T46 首次接口改动遗漏 collector.lines，已修正；另一个并行用例未在最初等待期限内生成 child.pid，等待期限扩大，调度原因未确定。T39 初次异步读取闭包缺少 MainActor 标注，T40 初次 #require 缺少 try；修正后通过。缺新类型的编译 RED 只证明接口尚未存在，不作为行为缺陷复现。

首次完整 Kit 联合运行卡在原用例 `failedStopIsReportedAndOwnChildStillInterrupted`：它等待新的拒绝语义不会发送的 SIGINT。已终止该次测试 runner（退出 143），清理该用例的独立子进程；旧用例改为先验证仍运行且日志无 SIGINT，再显式清理夹具。该次运行不计为通过。新增 pipe 用例随后在 2 秒内收不到 ready 行，确认本轮 Foundation read(upToCount:) 等待更多字节导致即时输出退化；改为 POSIX read，保留 EINTR、EOF、读取失败区分。错误夹具直接读取已关闭 FileHandle 的 descriptor 时发生 NSException；现在在关闭前保存 descriptor，用 POSIX 读取复现失败，生产 reader 由 child 持有打开的 FileHandle。异常测试留下的 PID 45991 经完整命令和脚本摘要核对后 SIGINT 清理。最终实时输出等 32 项和最终联合验证通过，没有向 VM 发送信号。

vm-new 的本轮操作为有 PID/instance 限制的只读 capabilities、environment_status、进程采样和 daemon 文件摘要核对。VM 仍为 B09 冻结源码 `2387af20`、PID 92943、instance `068574F6-DEF3-4910-88AB-57F5330C7A02`；classic 连接与原 daemon 摘要匹配，API 仍 reconnecting/transport、environment_status 为 api_not_ready。599 个冻结文件以及配置、身份预测和客户机载荷摘要保持一致。新源码没有打包/签名/部署，没有新的 amfid/helper/security 操作、guest/kernel 写入或 vm-2607 操作；主仓库仍为 e8d825b3 且干净。因此本轮测试不证明新代码在当前运行 VM 上生效，也没有补齐此前应用启动问题的验收。

追加前再次验证原 542 份已提交证据和 3 份不可变输入副本，保留原任务依赖、步骤、接口、验收与回退条件。47 项状态保持 2 项 accepted、42 项部分推进、2 项待本地对账（T30/T31）、1 项可选延期，44 项必选仍未验收。证据入口：`evidence/B12-summary.json`、`evidence/B12-related-green.log`、`evidence/B12-final-state.json`。


### 2026-10-08 B13：五项功能接入、签名候选与客户机 API 验收

本轮从 `dd3c8002` 推进 T36、T37、T39、T40、T46，实现提交为 `55fd8ef57a6731e42cba0727f477bc9b25f0c9ca`。固定上游目标仍为 `2d21d21`。五项主要接入已经实现，原依赖和完整验收条件尚未全部满足，状态继续为部分推进。

| 任务 | 本轮结果 | 未完成范围 |
| --- | --- | --- |
| T36 自动解锁 | 每 VM 默认关闭的持久设置、CLI/菜单/Launchpad、共享输入队列、guest setup_pending 提供方已接入；临时 API 在熄屏锁定、respring 后及已解锁重复请求中通过 | 新宿主 cold boot、同实例重连、userspace reboot、设置生命周期和密码路径；RPC 成功不能证明未启动的新 worker 生效 |
| T37 有序停止 | API guest-first、旧 guest 回退和完成分类；停止及绑定前严格检查磁盘无占用；不向磁盘占用进程发信号；实际 force:false 请求拒绝 | 新宿主真实关机、磁盘释放、DFU/panic/超时/旧 guest、更新/备份冲突和完整权限矩阵 |
| T39 剪贴板 | Cmd C/X/V 入口及异步状态校验；相同文本/图片不重写 Mac pasteboard；命名 pasteboard 测试保留 rich text 和 changeCount | API 分开图片下载的第二次 await 接入；真实长按 Copy、图片、快速切窗、慢回复、type、重启及新 UI 验收 |
| T40 Bundle 绑定 | Core 持久化、已停机及磁盘释放门禁、旧 VM 完整可读回备份、verified Bundle 执行租约；最低执行版本 2.6 和 series/local/CI 策略；已绑定宿主不自动更新 guest；CLI 五项拒绝且配置不变 | 创建工具链冻结、真实多版本并存、kernel-only 来源收据、guest 显式升级/回退及混合版本 hash/instance；缺 Bundle 的运行时错误目前为通用 store 错误，恢复提示仍待完善 |
| T46 日志完成确认 | 独占完整日志、串行批量写入、finish 排空及 fsync/close；协议 2 与 operation UUID ACK；30 秒默认超时、断线、写失败及旧协议拒绝；两条真实匿名 XPC 连接归属通过 | 注册系统 helper 后的权限/代码身份/实际 XPC；脱离 UI 的 VM/create raw log、后代 writer、立即退出应用、panic/取消/轮换、UI 响应与 VM 吞吐 |

绑定、版本与日志 writer 放入 VPhoneCore，CLI 没有新增 VPhoneLaunchpadKit 依赖。旧 VM 第一次绑定的备份使用同 APFS 卷写时复制，并流式核对源、备份和源的摘要；不证明物理介质独立。持久化使用 VM 协作锁、快照校验及独占临时文件发布，不宣称对不遵守锁的外部写入者实现原子 CAS。操作建议是先恢复或安装绑定记录指定的 Bundle；确需改变来源时，对已停机且磁盘无占用的 VM 执行显式绑定，不能仅因 Bundle 缺失自动选择其他版本。完整工具链和四层来源验收仍待完成。

最终 Python 全套 571 项、268.219 秒通过。最终源码的 Swift 非固件覆盖分两次运行：排除 FirmwareIntegrationTests/APIHTTPTests 的串行分组为 XCTest 251 项（3 项跳过）和 Swift Testing 1233 项/197 suite；APIHTTPTests/APIWebSocketTests/OutputXPCTests 分组为 17 项/3 suite。第二组新增 5 项 HTTP 用例，去重后的 Swift Testing 覆盖为 1238 项。两条命令均退出 0，不记为一次完整运行通过。

默认并行全套仍有 20 个 issue；相关 56 项隔离运行通过，原因未查明。严格磁盘门禁修改前的串行全套曾通过 1234 项；最终串行全套在 APIHTTPFixture.stop 的 Foundation waitUntilExit 等待处卡住，直接 OS 子进程查询为空。已保存进程采样并只终止核对过身份的测试 helper，该次运行不计通过。保留默认并行失败、两次完整串行等待、误用直接测试 helper --help 导致运行用例及其受控清理记录。没有通过修改测试入口或降低断言把完整运行记为通过。

新增磁盘释放用例先复现无 VM 锁但磁盘被打开、原 VM 退出后磁盘仍被打开、旧 VM 首次绑定磁盘被打开三个失败场景。生产实现改为有界 lsof 检查；检查异常或占用均拒绝成功。原测试曾预期外部磁盘占用不影响 stopped，已改为期望 failed，同时继续验证不向占用者发送信号；最终 54 项/8 suite 通过。其他失败及修正包括 Cmd C/X/V 无可靠旧计数时仍应发送 HID、相同 plain text 不应覆盖 rich text、绑定宿主不应自动更新 guest、日志创建或 child 初始化失败不能遗留 running 历史，以及匿名 XPC 断线不能确认日志完整。全部 RED、编译失败、修正和最终结果保留。

`make test_guest_components` 的 RootHide loader-link、相机数据平面 124 次检查和四个 VirtIOSound 算法程序通过；这不证明现代客户机组件加载或音频运行。1 GiB tar 文件/producer 内存探测通过。单次本地 100000 行、13488890 字节日志比较中，逐行 FileHandle.write 为 0.535912 秒，批量 writer 为 0.054696 秒；没有测量 UI 响应和真实 VM console 吞吐。本轮没有运行固件验收或应用新 kernel patch。

vm-new 的宿主继续为 B09 源码 `2387af20`、PID 92943、instance `068574F6-DEF3-4910-88AB-57F5330C7A02`。API-only 候选实际上传到独立 `/var/root/vphone-b13-api/vphoned` 并读回摘要；没有覆盖 `/usr/bin/vphoned`、原 cache 或宿主 `.vphoned.signed`。该模式跳过 cache 引导、camera 启动和 Irisin 更新，并拒绝 camera 与 agent.apply_update 调用；保留 classic 256 字节 camera ABI，未单独部署现代 64 字节媒体组件。健康 HTTP 200、setup_pending=false、API instance `67449773-367D-4774-AD7D-239FEDD0A7CC`，daemon SHA-256 `152dc35bd219ebccffb71623cb9e732a8e88d9f257b87f42ac0e38258f7e1749`。环境状态为 full_migration_required，现代 shared-components 缺失；没有执行完整环境安装。

实际 API 熄屏锁定后解锁及已解锁重复请求通过；respring 使用 frontboard_relaunch，SpringBoard PID 从 39 变为 55146，API instance 和摘要保持不变，随后解锁通过。Settings 启动 PID 51992，foreground 查询验证为 true。SpringBoard apps.launch 请求失败，主屏幕 foreground 查询 PID 0/source unavailable/verified false，不能记为可靠主屏幕 PID 验收。截图含上次或过渡帧，不能单独证明当前解锁状态。未提供密码或修改配置；缺失/错误 HTTP token 返回 401，force:false 的关机请求拒绝且 VM 仍运行。

临时 launchd bootstrap 输出 session 错误，print 查询确认 job 没有加载，原因未查明；随后以独立进程运行 API 试验。清理先对代理 50710 和 worker 50711 核对 PID、父进程、启动时间及路径后发送 SIGTERM，二者仍存在，原因未查明。再次在发送信号的同一 shell 中核对完整身份后 SIGKILL 两个临时进程，最终确认二者消失、job 不存在、原 daemon PID 70 与 VM 继续运行。临时文件保留供后续授权验收。清理后 API 恢复 reconnecting/transport，environment_status 为 api_not_ready。保留失败清理日志及最终成功记录。

新宿主、Launchpad 与协议 2 helper 已构建、签名和冻结于 `.build/acceptance/B13/`，共 607 个文件；B09 的 599 个文件摘要保持一致。候选来源仍为实现提交 `55fd8ef5`，后续证据提交不改变该来源。新 VM SHA-256 为 `db62e750f65208a662708c155cf1ac3dec2aac68d2de14684fcef6bf5293a548`，CDHash 为 `6ae3461ec4dae85f9375bdba4f8b7052ea9257ff`。VM --help 被 SIGKILL，amfid 日志记录 AppleMobileFileIntegrityError -424：The file is adhoc signed but contains restricted entitlements。CLI --help 返回 0，不将日志中的 CLI -423 写为 CLI 无法运行。

签名 helper 的 TeamIdentifier 为 `3AA3QL69MQ`，CDHash 为 `30ce6ce220a60617b6ae42066372bf3ac2e8ebe6`，严格签名检查与 --check-configuration 返回 0。系统服务 com.vphone.cli.helper、对应 PrivilegedHelperTools/LaunchDaemons 路径不存在；正确 authorization right com.vphone.cli.helper.privileged 只读查询返回 NO (-60005)。初次查错 right 名称的记录保留，不能用作正确名称的基线。没有注册 helper、写授权数据库或操作 amfid。旧授权只覆盖 B09 CDHash `52b10bcbce6db82de6afa83b801eb95da55246c7`，新 VM 的临时 AMFI 授权及系统 helper 注册需要明确的新授权。

追加前核对原 577 份已提交证据及 3 份不可变输入，8 个上游参考的固定 SHA 字节和 54 个本地提交文件摘要通过。原依赖、步骤、接口、验收与回退条件不变；上游语义提交覆盖台账不变。47 项仍为 2 项 accepted、42 项部分推进、T30/T31 待本地对账、T45 可选延期，44 项必选未验收。主仓库 HEAD e8d825b3 且干净，vm-2607 未操作。证据入口：`evidence/B13-summary.json`、`evidence/B13-final-partition-results.json`、`evidence/B13-artifact-manifest.json`、`evidence/B13-final-state.json`。


### 2026-10-08 B14：授权后的真实宿主与系统 helper 验收

用户回复“授权”后，执行前一轮列出的两项临时安全操作。VM 仅允许冻结 CDHash `6ae3461ec4dae85f9375bdba4f8b7052ea9257ff`，独立空配置、paths=[]、allow_all=false、spoof_apple=true。helper 仅注册 com.vphone.cli.helper，TeamIdentifier `3AA3QL69MQ`、CDHash `30ce6ce220a60617b6ae42066372bf3ac2e8ebe6`，right 为 com.vphone.cli.helper.privileged。没有改变实现源码或重新构建，所有实际工件仍来自 `55fd8ef5`；工作分支起点为末尾空行修正提交 `bcc1f871`。

旧 B09 VM92943/instance068574F6 正常 SIGINT 停机，原 daemon 执行关机，父驱动退出0，磁盘释放。随后制作 `/Users/qcz3840/github/vphone-cli/vm.backups/b14-vm-new-stopped-20261008`：65 个文件逐一摘要一致，源元数据变化项为空；方法为同 APFS 卷 clonefile 写时复制，不证明物理介质独立。该检查点位于本轮配置修改之前。

| 对象 | 实际结果 | 未完成范围 |
| --- | --- | --- |
| T36 新宿主启动 | 首次70577/E7F7D876 使用 CLI unlock flag；第二次84587/09F69011 仅持久设置且无 amfid helper；两次未发送手动 RPC 的观察均 unlocked | userspace reboot、密码路径、完整 guest cohort 与依赖；没有密码绕过结论 |
| T36 设置与菜单 | off/on 写入false/true；当前锁定实例在启用后仍 locked/off；同 guest API instance 的12秒暂停/恢复中观察到 reconnecting，恢复后仍锁定；手动菜单立即重测 unlocked；CLI config 成功，无 API 的 launch 拒绝64 | 第一次延迟菜单观察仍锁定，直接 RPC 成功，原因未查明；重测通过不证明第一次现象的原因 |
| T37 实际停止 | 菜单与生产 CLI 两次均 apiAccepted、Guest stopped、父退出0、磁盘释放，未触发超时强停 | 新代码的旧 guest/DFU/panic/未ready/超时、更新/备份冲突及完整 root/权限负向矩阵 |
| T39 实际剪贴板 | 测试文本/RTF已准备；立即解锁与 guest tap 后 Settings 搜索激活；CUA Cmd V 未确认传入文本，guest仍items0/types[]/change_count0 | Cmd V 原因未查明；Cmd C/X、长按Copy、图片、快速切窗、慢响应、type及重启；API图片第二次await接入仍待实现 |
| T40 实际拒绝 | 已停机vm-new请求缺失2.6.0 Bundle，拒绝且没有 binding/backup/config变化；两次新host配旧guest摘要保持 | 缺Bundle恢复提示仍为通用错误；实际多Bundle/创建冻结/kernel-only来源及显式环境升级/回退 |
| T46 系统 helper | 正常签名CLI注册成功，root68514、协议2、安装字节一致；管理员规则user/admin/authenticate-user=true/allow-root=false/shared=false/timeout300；两客户端收到各自输出和缺Store错误 | 没有成功安装或验证Bundle；真实完整文件writer排空与fsync/close、UI退出、全部操作集与VM吞吐未验收 |

首次 VM instance 为 `E7F7D876-BA0B-4E08-BD53-B1F48E877AD4`，API instance 为 `963EA9A0-3DFA-45DF-B950-8C0A79031E9C`；第二次分别为 `09F69011-7199-40F7-BDF6-1894709D42D9` 与 `BFC08178-9E34-46DB-895F-F620D7FC8871`。第二次没有CLI unlock flag，由持久设置启用；没有再次启动amfid helper。两次均显式 --no-vphoned-update，独立临时 API-only daemon 沿用 `/var/root/vphone-b13-api/vphoned`，未部署现代64字节相机/shared-components，保留classic256字节协议和原Irisin/Hook边界。实际 /usr/bin/vphoned 和cache均为240352字节，SHA-256保持306ed42b…1401f9001。

第二次HTTP缺失/错误/上次启动token/当前token分别返回401/401/401/200，force:false关机拒绝。菜单 Stop 没有由观察驱动另发信号。生产 CLI Stop 核对 instance09F69011 后只向84587发送SIGINT，宿主执行API guest-first并正常退出，两次均记录 apiAccepted。accepted、Guest stopped和磁盘无占用分别以不同证据核对，未将请求接受当作关机完成。

系统helper通过正常 `sudo -n frozen-helper-client helper register` 路径安装。两条并发签名客户端各执行 verify-bundle 2.6.0，实际Store不存在，因此两次都是错误结果。根据冻结源码的 streaming 路径，底层操作错误回复发生在 output.finish ACK 成功之后；这是实现与运行响应结合的推断，未单独捕获ACK遥测，不能记为成功Bundle安装或完整writer实际持久化验收。ad hoc同bundleIdentifier客户端返回connection interrupted，未获版本；具体拒绝原因未单独捕获。没有创建或安装尚未完成的Bundle。

Mac原剪贴板全部items/types/data保存至本机0600临时备份，没有把值写入证据。测试文本和RTF在Cmd V后保持；原内容恢复后逐项读回一致，原changeCount无法恢复。guest原clipboard为空，前后仍为空。测试内容未进入搜索框，剪贴板真实接入不记为通过。原生截图还出现黑色或锁屏画面，不能独立证明当前状态；窗口焦点或键盘路由尚未确定。CUA操作记录标明为人工转录，原始工具输出在本聊天历史中。

临时amfid驱动SIGINT未退出，核对同一PID69847完整身份后SIGTERM清理，终端会话退出1；没有清理完成/正常detach日志，不宣称finally成功。采样确认driver/debugserver消失，amfid当时PPID1。最终amfid未运行，系统job明确为JETSAM_REASON_MEMORY_IDLE_EXIT，未强制重启该系统服务。签名helper的root文件属性、原始缺失基线、摘要与rule核对后，bootout服务，移除本轮right和两个root安装文件；最终service不存在、right为NO(-60005)、安装文件不存在。没有修改持久安全配置；没有声称清除了AMFI缓存。csrutil显示Custom Configuration，authenticated-root查询为No macOS installations found，不能据此确认该项状态。

最终vm-new已停机。持VM目录协作锁且磁盘无占用时恢复原config字节；config、原classic载荷、UDID预测以及AVPBooter/AVPSEPBooter/restore-info摘要与检查点匹配。B09/B13冻结工件共1206文件再次校验，严格签名检查通过。Mac私有剪贴板备份、guest空剪贴板备份以及已停止三个服务器的临时token已清理；未注册的guest临时API工件保留供后续验收，不会作为launchd job启动。当前磁盘正常启动/关机的数据变化未回滚，不宣称整个Disk.img恢复到检查点。

本轮未重跑Swift/Python/固件套件，没有把B13结果计作新的测试通过；B13默认完整Swift失败与最终串行等待继续保留。本轮主要验证真实宿主和注册后的XPC行为。五项仍有原合同未满足，保持部分推进；47项仍为2项accepted、42项部分推进、T30/T31待本地对账、T45可选延期，44项必选未验收。原760份证据、3份输入、全部原任务依赖/步骤/接口/验收/回退与语义提交覆盖台账保持不变。主仓库e8d825b3干净，vm-2607未操作。证据入口：`evidence/B14-summary.json`、`evidence/B14-final-state.json`、`evidence/B14-helper-probe.json`、`evidence/B14-stop-result.json`、`evidence/B14-second-stop.json`。


### 2026-10-08 B15：剪贴板、Bundle 恢复提示、完整日志及停止回退

本轮实现提交为 `ee7b9ec2c6be7a0402291afbf6e2eae0136c7f3b`，起点为 `268fe330`，固定上游目标仍为 `2d21d21`。新增三项修正，并补充真实 classic-only、DFU 停止和注册 helper 日志验收。五项原合同尚未全部满足，保持部分推进。

| 任务 | 结果 | 未完成范围 |
| --- | --- | --- |
| T36 | 冻结 B13 宿主携带启动解锁标志，未发送手动解锁 RPC 的观察为 locked=false、screen_off=false | 密码、userspace reboot、完整客户机组件组合及原依赖验收 |
| T37 | 生产 CLI 对 classic-only 实例停止返回 0；宿主记录 classicAccepted、Guest stopped、VM 退出 0。DFU 无 guest 连接，framework requestStop 超时后强制停止，CLI 与 VM 均退出 0；最终磁盘无占用 | panic、未 ready、非 DFU 超时、更新/备份冲突和完整权限矩阵 |
| T39 | 同一连接中 Mac changeCount 未变时不重复写 guest 剪贴板，保留后续 guest 复制；Mac 变化或新连接仍发送。新增 3 项回归通过 | 新工件真实 Cmd C/X/V、触摸 Copy、图片、切窗、慢回复、type、重启；API 分开图片下载后的第二次 await 尚未接入 |
| T40 | 缺失或校验失败的绑定 Bundle 明确提示恢复指定版本或显式重新绑定。B15 CLI 在停机 vm-new 上实际显示恢复提示，拒绝后配置未变，无绑定或备份发布 | 创建工具链冻结、实际多 Bundle 并存、kernel-only 来源收据及四层来源升级/回退矩阵 |
| T46 | helper 两命令接入 --log-file；新签名 CLI 与冻结 B13 helper 的两条真实 XPC 请求分别保存完整 122 字节、0600 日志，返回后文件关闭；已有日志拒绝覆盖 | 成功安装/验证完整 Bundle、完整操作集、立即退出 UI、后代 writer、panic/取消/轮换和真实 VM 吞吐 |

最终完整串行 Swift 命令退出 0：Swift Testing 1243 项、198 个 suite、225.460 秒；XCTest 251 项、3 项跳过、0 失败。52 项/7 suite 的相关并行验证通过。项目默认 `make test_swift` 仍失败：1243 项、61.013 秒、7 个 issue，涉及 VMRuntimeEntry 状态/输出 2 项、取消耗时 1 项、helper 身份拒绝超时 1 项、HTTP 截止/取消耗时 1 项、IPSW 续传 Range 断言 2 项。串行通过不作为默认并行通过。没有重跑 Python 或固件测试，也没有应用新 kernel patch。

HTTP 夹具的先前串行等待采样位于 APIHTTPFixture.stop 的 Foundation waitUntilExit，直接子进程查询为空。现在在启动前安装 terminationHandler，并以有界 DispatchGroup 等待退出。保留编译失败和旧等待记录。默认并行的两次采样显示多个协作线程同步等待 Security 签名验证，并有归档 I/O。签名/HTTP/XPC 最小组合为 18 项、42.049 秒、5 个 issue；将测试签名验证移到独立线程后，52 项相关组合全部通过，没有放宽断言或截止时间。完整并行仍有上述失败，其完整原因未查明。首次 B15 完整串行有 2 个 issue，两项隔离复跑通过，最终完整串行也通过；保留全部结果，不宣称间歇失败原因已经确定。

本轮真实 VM 宿主仍为冻结源码 `55fd8ef5`，不是 B15 新工件。普通启动 PID30749、instance66D34CB6-9764-4ACE-A35F-5B5C592898C6；classic-only CLI Stop 耗时 6.612 秒。独立 API-only 代理/worker 核对身份后清理，原 classic daemon 保留，随后验证旧 guest 回退。DFU PID58582、instanceB338CD8C-248D-498E-A53F-D347A41A948A；CLI Stop 耗时 11.951 秒，包含框架请求超时。DFU 未执行 restore 或刷写。首次 DFU 驱动误用 --no-graphics，退出 64、未启动 VM；修正为实际支持的 DFU 参数后完成验收，失败样本保留。

真实 Cmd V 仍未确认传入测试文本。独立诊断窗口观察到 command=true、charactersIsV=true、keyCode9、keyWindow=true；该结果不能证明 VM 窗口回调执行。classic 的直接 type 后，GetClipboard UI 读回 B15-control-direct/public.utf8-plain-text/changeCount1，同阶段 API-only 读回仍为空。两个通道的观测不同，原因未查明；没有用 API-only 空结果推断 classic 写入失败，也没有据此修改键盘路由。原生观察是从聊天工具结果转录，未伪造为原始工具输出。

Mac pasteboard 的 changeCount 从测试设置后的 234 变为 237，当前内容不再匹配已知测试值。恢复守卫拒绝写入，随后保持独立变化后的当前剪贴板。原 items/types/data 备份以 0600 保留在 `/private/tmp/vphone-b15-private-pasteboard.plist`，值未写入研究证据；未声称原 changeCount 可恢复。guest classic 测试文本在停机前清空，原 changeCount 未恢复。临时按键探针已停止；已停机服务器的 token 和空 guest 私有备份已清理。

B15 宿主、Launchpad、签名 helper 客户端构建成功，607 文件冻结于 `.build/acceptance/B15/`。资源、严格签名、权限声明、仓库外和符号链接资源定位检查通过。新 VM SHA-256 为 `01f584eb815f9c853494f9165d4c6d5d782308441fff823938e33315d8cb363c`，CDHash 为 `343c11ebfeab191227fe5e6b849897282c2289c7`。CLI --help 返回 0，VM --help 被 SIGKILL；精确路径的 amfid 日志记录 AppleMobileFileIntegrityError -424：The file is adhoc signed but contains restricted entitlements。尚未运行 B15 VM 验收。已请求仅对这个新哈希进行独立空配置、paths=[]、allow_all=false、spoof_apple=true 的临时放行；记录时尚未收到回复，未启动新的 amfid 驱动。具体暂停来源为执行技能中的 security-sensitive action 要求，技能路径为 `/Users/qcz3840/.codex/plugins/cache/openai-curated-remote/superpowers/6.4.2/skills/executing-plans/SKILL.md`。

签名客户端源码为 B15 ee7b9ec2，内嵌 helper 沿用 B13 冻结字节 SHA-256728b0353…383b60ce、CDHash30ce6ce2…a8ebe6、Team3AA3QL69MQ、协议2；没有制造或注册新的 helper 哈希。沿用已有精确授权临时注册，分别验证2.6.0与2.6.1，操作结果均为 Store 不存在。日志包括开始行和错误行，首次驱动只预期开始行而失败，原样本保留；修正预期并使用新日志路径后通过。底层错误回复位于 finish ACK 之后，是实现顺序与实际回复结合的推断；文件完整且关闭有独立检查，没有记录 ACK 报文或 fsync 系统调用。未计为成功 Bundle 安装。服务、right、两个 root 文件与 helper 进程均已清理，原缺失基线恢复。

最终 vm-new 停机、磁盘释放，原配置、classic 载荷、UDID 预测摘要未变；B09/B13 原冻结工件1206文件再次核对。保留 classic 256 字节相机协议及原 Hook/Irisin 边界，未单独部署现代64字节组件，未改写 kernel/Preboot。磁盘正常启动/停止的数据变化未整体回滚，不宣称恢复了完整磁盘检查点。主仓库仍为 e8d825b3 且干净，vm-2607 未操作。

追加前核对原847份证据和3份输入；新增100份后清单为947项。全部原依赖、步骤、接口、接受与回退条件、固定上游语义提交覆盖台账不变。47项仍为2项accepted、42项部分推进、T30/T31待对账、T45可选延期，44项必选未验收。证据入口：`evidence/B15-summary.json`、`evidence/B15-source-review.json`、`evidence/B15-post-fix-serial-swift.log`、`evidence/B15-post-fix-full-swift.log`、`evidence/B15-artifact-manifest.json`、`evidence/B15-helper-log-probe.json`、`evidence/B15-final-state.json`。


### 2026-10-08 B16 新宿主验收与键盘事件修正

用户授权的 B15 VM CDHash `343c11ebfeab191227fe5e6b849897282c2289c7` 已按独立空配置、paths=[]、allow_all=false、spoof_apple=true 执行。新的停机恢复点 `vm.backups/b16-vm-new-stopped-20261008` 共65个文件逐一摘要一致，源元数据无变化；同卷 APFS 写时复制不证明物理独立性。

B15宿主ee7b9ec2实际运行PID8231，实例24DC2EA6-EAA8-4E18-B386-2E78A1EA8566。classic连接建立前的失败检查保留，重试完成原daemon/缓存/API_ONLY摘要核对。启动解锁观察locked=false、screen_off=false，未发送手动unlock RPC；Settings PID676且frontmost_verified=true。停止分类为apiAccepted，随后Guest stopped，CLI/VM退出0，8.712秒，磁盘释放。API_ONLY精确PID SIGTERM后没有独立退出读回，不能将该结果列为classic-only；旧回退证据保持。

真实Cmd V后设置搜索框显示v，classic剪贴板仍为空，Mac测试文本和RTF保持。LLDB观察key window和VM view first responder存在；performKeyEquivalent命中0次，VZ keyDown命中1次，modifierFlags1048576、keyCode9。所有断点删除，调试器分离。修正f2331b7a为keyDown补齐同一同步回调，保留原焦点/连接/变化计数保护。事件回归3项在旧实现失败1项，修正后3项全部通过，相关Swift Testing13项通过。

标准make test_swift：XCTest254项、跳过3项、0失败；Swift Testing1243项/198suite，54.849秒，3项问题（Library取消耗时、HTTP取消耗时、helper未配置身份请求超时），原因未查明。完整串行：XCTest254项/跳过3项/0失败；Swift Testing1243项/198suite，239.086秒，退出0。Python和真实固件比较本轮未重跑。

新签名候选为 `.build/acceptance/B16/candidate.app`，源码f2331b7a6b3a577642f2a0cccb4ec623395f5352，CDHash `ab7682cd27dce3d64dbf1233c98975d4dab392b5`，SHA256 `cde831706e0239c51c5c7fde5d1e328e04585c57b4ce6ec984195543a8ef72bf`。资源、签名、权限、外部工作目录与符号链接执行检查通过；未启动该新候选VM。本轮既有授权仅覆盖B15精确哈希。

vm-new已停机，配置/原classic载荷/UDID摘要保持，vm-2607未操作。AMFI辅助进程SIGINT未退出，核验PID5503后SIGTERM清理，debugserver退出，amfid PPID1。Mac原始剪贴板项目/类型/数据恢复并读回一致，变化计数不可恢复，0600私有备份保留。停止后API token已删除。未替换guest/kernel/boot-chain，也未执行整盘回滚。

原947份证据和3份输入副本校验一致；本轮新增45份证据。T36/T37/T39/T40/T46均保持局部验收状态，完整计划仍为2项accepted、42项partial、2项待本地审计、1项可选延后，44项必需任务未完成验收。原依赖、步骤、接口、接受条件、回退及342提交覆盖台账保持。

构建后仅清理隔离工作树可重建debug中间产物和release ModuleCache，释放1,435,779,072字节；清理后可用13,609,791,488字节，通过12 GiB启动门槛。B15/B16共806个冻结文件摘要再次一致。恢复点、日志、源文件及冻结候选均保留。


### 2026-10-08 B18：继续推进 T39、T24、T36、T37、T40、T46

固定上游目标保持2d21d21。本轮实现提交ee4a27eb、f604f5ad、fd12d738。六项均保留未覆盖的原接受条件，未增加完整验收任务数。

| 任务 | 本轮结果 | 未验证内容 |
| --- | --- | --- |
| T39 | B16宿主真实Command-V传入classic测试文本；重复V保留后来通过菜单设置的guest文本；Mac RTF及changeCount保持 | 实际输入框粘贴、选区C/X、触摸Copy、图片、切窗、慢回复、type/重启和API图片第二次await |
| T24 | 采样确认协作执行器中的阻塞ACK等待，移至独立线程；相关105项和完整串行通过 | 最终默认并行仍4 issues，完整原因未查明；独立launcher及完整运行依赖闭包 |
| T36 | B16启动后手动RPC之前locked=false、screen_off=false；后来锁定及手动解锁均观察到 | 密码、userspace reboot、完整设置/停止/实例取消及依赖 |
| T37 | 菜单停止apiAccepted，Guest stopped，VM退出0，独立核对磁盘释放 | 当前新宿主classic-only、panic、未ready、超时、更新/备份协调和权限矩阵 |
| T40 | 官方2.6.0/2.6.1安装校验和并存；修正内存积累后vm-new完整备份及首次绑定通过；显式切换通过 | 实际本地Core Bundle打包、创建冻结全流程、kernel-only及guest升级回退四层来源矩阵 |
| T46 | 两条真实签名XPC请求成功验证官方Bundle，分别保存完整60字节0600日志，返回后关闭 | 成功streaming install、UI立即退出、后代writer、panic/取消/轮换和运行吞吐 |

B16 VM源码f2331b7a、CDHash ab7682cd27dce3d64dbf1233c98975d4dab392b5，按用户精确授权使用独立空配置、paths=[]、allow_all=false、spoof_apple=true。实际PID61914，实例86C9E1B1-4E37-4445-964C-CB7E071C264F。首次解锁观察早于手动RPC；后续锁屏与手动解锁单独记录。API_ONLY进程清理请求超时，未独立核对停止前退出；实际关机仍为apiAccepted，不列为classic-only。VM已停机，磁盘释放，临时令牌、AMFI驱动及debugserver清理，amfid由launchd管理。未操作vm-2607，未更新guest/kernel/boot-chain或部署modern相机。

剪贴板传输及不重复写入已验证。C/X没有确认客户机选区，Mac剪贴板保持测试RTF和changeCount，不能计为实际复制剪切通过。复核确认classic tap使用了430x932缩略图坐标，接口要求1290x2796完整分辨率，因此输入框焦点验收无效；API输入路径原因未查明。本轮未按修正坐标重启VM复验。Mac原项目、类型及数据已恢复并读回一致，0600私有备份保留；guest测试文本通过type空字符串清除，最终类型为public.utf8-plain-text，变化计数不能恢复。

旧CLI两次首次绑定分别在97.055及106.711秒以-9退出，未生成备份或绑定。系统终止原因未独立确认；vmmap记录峰值physical footprint66.6G，采样期间目标退出。独立512MiB摘要实验原循环最大RSS545292288B，逐块autoreleasepool后8470528B，SHA-256一致。VPhoneFileDigest现在供绑定清单和创建指纹共用，保留原摘要、描述符和读前/读后身份检查。生产内存检查输入536870912B，峰值RSS8421376B，结果正确。

新CLI候选`.build/acceptance/B18/binding-cli.app`仅CLI源码为f604f5ad，199个文件冻结核验；资源和VM可执行文件保留B16，没有启动此候选VM。修正后的64GiB vm-new完整备份与首次绑定2.6.1耗时130.584秒，最大RSS27754496B。恢复点`vm.backups/b18-vm-new-fixed-binding-20261008`保留，生产代码在发布绑定前核对完整清单；同卷APFS写时复制不证明物理独立性。配置、原classic载荷和UDID摘要保持，host切换2.6.0/2.6.1后guest/kernel/boot-chain来源仍unknown。验收后原无绑定状态和系统Bundle store缺失状态均恢复，没有执行guest升级或上游VM。

官方工件来自[2.6.1发布](https://github.com/Lakr233/vphone-cli/releases/tag/2.6.1)和[2.6.0发布](https://github.com/Lakr233/vphone-cli/releases/tag/2.6.0)，下载字节数及SHA-256与GitHub资产摘要一致；完整元数据与收据保存在B18证据中。2.6.1摘要651224d58064c59159e47b4a5fb066ca6dc758bdd221a346d43465cd34df5420；2.6.0摘要ea389bba953eeff6d75f54c42d100dde6ffa6907adac84a40d56a35d08e78761。

沿用已授权B13 helper CDHash30ce6ce220a60617b6ae42066372bf3ac2e8ebe6。注册请求超时保留，之后独立确认protocol2及两次成功verify-bundle；各返回官方2.6.1收据及完整60字节日志，0600，返回后关闭。ACK/fsync以实现顺序、成功结果和完整关闭文件核对，未独立抓取协议包或系统调用。临时helper服务、right、二进制及plist已清理，未放宽管理员规则；成功streaming install未验证。

最终完整串行：Swift Testing1243项/198suite，230.171秒通过；XCTest254项、跳过3项、0失败。Python571项、275.167秒通过。归档内存、摘要内存及guest组件检查通过。最终标准make test_swift：Swift Testing1243项/198suite，48.696秒，4 issues（未授权XPC超时、Library取消耗时、HTTP取消耗时、NativeRestore未生成worker.pid）；完整原因未查明，原阈值未放宽。真实固件比较本轮未重跑。

原992份证据、3份输入副本及B15/B16共806个冻结文件校验一致。主检出的未跟踪`research/vm_backup_cleanup_2026-10-08.md`不是本轮生成，未修改。台账保持47项：accepted2、partial42、待本地审计2、可选延后1；44项必选任务未完成验收。原依赖、步骤、接口、接受条件、回退及342提交覆盖记录不变。


### 2026-10-08 B19：默认测试入口修正与六项运行验收

实现提交82649fe7。T39、T24、T36、T37、T40、T46继续推进，六项整体接受条件尚未满足。

| 任务 | 结果 | 未完成范围 |
| --- | --- | --- |
| T24 | 默认Swift入口分组后1238+5项通过，XCTest254项/3skip/0fail；独立审查无阻塞发现；递归审计非系统依赖 | 工具依赖外部Homebrew libcrypto/libplist，本地缺vphone-escalator；系统共享缓存未递归审计，原整组并行失败原因未完全查明 |
| T36 | 冷启动解锁观察、真实respring通过；respring后API instance保持且屏幕锁定 | userspace reboot实际返回Input/output error，原因未查明；原生命周期及依赖矩阵尚未完成，密码路径未验证 |
| T37 | 新B16宿主classic-only菜单Stop为classicAccepted，随后Guest stopped、VM退出0、磁盘释放；缺force请求拒绝 | panic、未ready、非DFU超时、更新/备份协调及完整权限矩阵 |
| T39 | 完整分辨率坐标修正，真实Cmd V文本显示在Settings搜索框；整段选区和Cmd X删除可见 | Cmd C/X、触摸Copy未同步到Mac；客户机剪贴板读取unavailable，原因未查明；图片/切窗/慢响应及API图片路径仍待验收 |
| T40 | 原Bundle/绑定证据保持，原无绑定与store缺失状态保持 | 合法本地Core Bundle构建和并存、创建冻结全流程、四层来源升级回退矩阵 |
| T46 | 原两次成功verify证据保持；本轮helper注册被自动审批拒绝，未执行 | 精确注册权限待回复；成功streaming install和完整输出生命周期尚未验收 |

原默认整组运行有5项issue。5项隔离运行全部通过；现将其从常规组排除后单独并行运行，原断言及截止时间不变。最终默认make test_swift退出0：常规Swift Testing1238项/198suite、54.135秒；计时组5项/5suite、2.481秒；XCTest254项、3项跳过、0失败。Python571项通过。调度修改没有证明原整组并行失败的完整原因，Range断言失败原因仍未查明。独立审查确认前后测试选择一致、环境选择器清理和失败传播保持；minor暂缓：尚无“第一组通过、第二组失败”的专门退出码回归，当前check=True实现正确传播。真实固件比较未重跑。

真实VM复用冻结B16源码f2331b7a、CDHash ab7682cd27dce3d64dbf1233c98975d4dab392b5，PID18728、实例47A910CF-34D6-48D4-8568-260E6E9E9225。API_ONLY使用已有载荷，未重新部署现代组件；classic 256字节/v3相机协议保持。启动解锁观察早于手动RPC。respring实际将SpringBoard39重启为6360，API实例462A8727-A889-4C4F-A712-66FF1108D78E保持；随后观察锁屏和熄屏。userspace reboot两次失败，直接API保留Input/output error，不列为重启通过。缺force的shutdown/respring/userspace reboot均拒绝。临时API worker TERM后仍在，核对精确路径与PID后KILL，独立确认不存在，API变为reconnecting/rpc=false；菜单Stop记录classicAccepted。VM退出0来自工具会话完成记录，boot日志另有Guest stopped；最终磁盘无占用。

剪贴板本轮使用1290x2796完整分辨率坐标，真实Cmd V粘贴可见。原生三击确认整段选区；Cmd A曾插入字母a，未列为全选成功。Cmd X删除选中文本可见，Cmd C及触摸Copy执行后Mac保持测试plain text/RTF及changeCount。classic读回有类型和计数，无文本；API一次读到已知测试文本，随后直接错误为Clipboard text is unavailable to this process。不能将这些结果列为复制同步通过。经典载荷已含相关pasteboard权限，未据此假定只是缺少权限。固定IcliKit0.7.16源码702990b5的相应错误分支保留用于诊断。Finder getApp耗时601秒，未独立确认窗口失焦。Mac原项目/类型/数据恢复并读回一致，0600私有备份未进入公开证据；changeCount不能恢复。guest测试文本已通过classic type空字符串清除。

独立AMFI配置仍为paths=[]、allow_all=false、spoof_apple=true，仅已有精确B16哈希。驱动退出1，记录unexpected process state与detach错误；清理脚本因进程已不存在而断言失败。后续独立确认驱动和debugserver均不存在，正确launchd服务com.apple.MobileFileIntegrity运行、amfid PPID1。首次错误查询com.apple.amfid未找到服务，已保留并修正；没有声称驱动正常detach。

helper注册命令被自动审批拒绝，原因为该操作改变系统特权访问状态，而当前可信授权未明确该helper、注册方式及权限范围。已询问对com.vphone.cli.helper、Team3AA3QL69MQ、CDHash30ce6ce220a60617b6ae42066372bf3ac2e8ebe6的临时注册、按管理员规则安装官方2.6.1及清理范围授权，记录时未收到回复；未通过其他途径重试。

最终vm-new停机、磁盘释放，config.plist、原classic载荷和UDID摘要与B18一致；临时token删除，原无绑定、无系统Bundle store、无helper服务/文件状态保持。恢复点B18保留；同卷APFS写时复制不证明物理独立性，本轮未整盘回滚。vm-2607未操作。原1084份证据、3份输入和806个B15/B16冻结文件重新核验；47项原合同、依赖及342提交覆盖保持，44项必选仍未完整验收。证据入口：evidence/B19-summary.json、evidence/B19-final-state.json、evidence/B19-dependency-audit.json。


### 2026-10-08 B20：明确授权后的 helper 注册与系统认证等待

用户回复“授权，继续推进”，明确覆盖B19已列明的helper身份、注册方式、官方2.6.1安装及清理范围。原helper SHA256728b0353…383b60ce、CDHash30ce6ce220a60617b6ae42066372bf3ac2e8ebe6、Team3AA3QL69MQ再次核对，官方归档摘要保持651224d5…5420。缺失基线核对后，sudo原签名CLI helper register退出0，独立查询protocol2、服务运行。管理员规则仍为authenticate-user=true、allow-root=false、shared=false、group=admin。

安装进入正常macOS管理员认证。工具禁止操作受保护SecurityAgent，已请求用户在本机认证，未索取聊天密码。首次150秒认证等待超时，确认未生成操作日志、未创建Bundle store；重试延长至900秒，记录时仍待认证，不能列为安装成功。已启动有界收尾进程：成功返回后通过原签名helper verify，核对收据、日志尾部、0600和文件关闭，记录安装清单，再清理本轮匹配身份的官方2.6.1 Bundle、helper服务/文件和授权项；超时且确认未安装则恢复缺失基线，状态不确定时保留检查。最终结果预计写入/private/tmp/vphone-b20-finalization.json；本条记录时该文件尚未产生，不声称系统已清理。

日志/ACK相关15项、4suite通过，缺失ACK实际30.005秒后失败；父进程退出、取消、panic和日志轮换相关22项、6suite通过。它们使用真实子进程夹具，不启动VM，不能扩展为真实VM全部生命周期通过。本轮未重复完整Swift/Python套件，没有源码行为修改，vm-new未启动、vm-2607未操作。

固定IcliKit提交702990b59ca412ad975f9f0ea5dafe95c30fac21的Sources/IcliPrivate/System.m显示：icli_reboot先清零errno，reboot3返回非零后返回errno ?: EIO。因此B19错误文本不能区分实际errno=EIO与errno仍为零时的包装回退；原始返回值和errno尚未记录，重启失败原因未查明。未据此修改guest或kernel。

原1156份证据摘要核对；新增13份。原47项合同、依赖及342提交覆盖保持，44项必选仍未完整验收。入口：evidence/B20-summary.json。


### 2026-10-09 B22：传输修复、截图内存和本地绑定运行

本轮选定T02、T06、T07、T08、T24、T40、T46。T06满足原接受条件，新增accepted1项；原T00、T01、T03、T04、T05保持接受。共6项accepted、40项必选尚未完整验收，1项可选延后。其余6项继续推进，不改变原合同、依赖和回退要求。

| 任务 | 结果 | 未完成内容 |
| --- | --- | --- |
| T02 | 62个合并提交重新核对，54个无附加解决，8个与冻结差异一致；完整审查T06及23个发布提交 | 218个pending提交及全局能力映射；Release2.1.3含菜单实现，按T27适配 |
| T06 | 边界及1/4/8MiB快慢读摘要完整，WebSocket完整，提前关闭和取消上传回收，FD15→15；按原合同接受 | 后续跨模块变更须复验 |
| T07 | 停止信号与文件身份缓存确认修复；同摘要显式更新后手动启动监听确认通过 | 真实launchd及不同binary升级/回退、坏缓存完整矩阵 |
| T08 | 固定IcliKit精确overlay及运行marker；40次截图稳定内存降至4,555,256字节，FD15→15；location/timezone验证 | 90度旋转未生效，原因未查明；RootHide服务和图像视觉核验 |
| T24 | 本地root-owned Bundle经受控普通launcher实际启动；19个Mach-O当前机器依赖解析；含空格路径停止修复 | 完整TCC及安全拒绝矩阵；Homebrew依赖不构成可移植封装 |
| T40 | 本地local后缀Bundle完整打包，停机备份139.067秒后实际绑定启动，classic摘要保持 | 创建冻结、clone/export/rename及四层来源升级/回退矩阵 |
| T46 | 实际wrapper/VM正常停机，classicAccepted与Guest stopped尾部保留，退出0 | 全UI立即退出、detached/create/后代writer及UI吞吐矩阵 |

实现提交b5c4e482、9a75de14、1dfa2fb2。客户机传输改用有界阻塞VSOCK与NIO管道桥接，修复输出EOF未唤醒接收线程及注册错误后重复关闭；独立复核未发现剩余问题。后续宿主argv修复与测试fixture修改未独立审查，不扩大审查范围。截图overlay固定IcliKit0.7.16/702990b5，编译source marker和运行binary SHA83075a0c均核对。位图复制后JPEG不再保留原screen image；本轮证据仅针对记录的恢复副本与候选。

最终Python597项、Swift常规1251项和计时6项、XCTest254项(跳过3项)通过。首次全量出现fixture权限问题，umask000定向复现后修正fixture，生产权限拒绝未放宽；第二次全量有Range间歇失败，原用例10次单独通过，第三次完整通过，原因未查明。保留所有失败日志，不把最后通过写成间歇问题已修复。真实固件比较本轮未重跑。

恢复副本已正常停机、原vm-new关键摘要保持，原classic及缓存SHA306ed42b恢复；测试绑定和系统Bundle store恢复缺失，helper服务/文件/right保持缺失，两个临时令牌删除。临时AMFI驱动结束时身份断言失败；独立确认驱动/debugserver不存在、amfid由launchd管理，不声明正常detach。B18和本轮停机恢复点保留；同卷APFS写时复制不证明物理独立。未操作vm-2607、未执行escalator、未升级kernel/boot-chain或部署modern相机。

B21原待确认的4cea360c临时AMFI范围已由当前用户授权，按paths=[]、allow_all=false限定使用并收尾。先前B20认证等待的最终结果见B21-summary.json，系统已恢复缺失基线；README中的历史进行中状态不表示当前仍在等待。当前入口：evidence/B22-summary.json、B22-source-review.json及B22-final-readback.json。

## 2026-10-09 B23 当前结果

选定7项为T02/T06/T07/T08/T24/T40/T46。T06保持B22验收结果，本批新增T07 accepted；其余5项未满足原接受条件。全台账7项accepted、39项必选未完成、T45可选延期。原步骤、依赖、接受条件及历史证据保持。源码提交为`f45be6c6e79d393e99ecbbe1c891536b214ae2bf`。

| 任务 | 结果 | 未完成范围 |
| --- | --- | --- |
| T02 | 新增16个完整差异审查，342条覆盖保持，待审218→202 | 202条全局语义核对及47项能力对账 |
| T07 | 临时launchd job下worker KILL/TERM、proxy KILL、显式不同签名binary更新确认/回退、未确认缓存失败和不可执行缓存回退通过 | 不同binary只有签名改变；53个Mach-O section载荷相同，不代表功能升级或环境迁移 |
| T08 | Safari 90/270度读回及横向JPEG视觉检查通过；RootHide路径纯算法测试通过 | 当前客户机rootless，缺实际RootHide样本；services.start状态144、Settings及180度旋转未生效，原因未查明 |
| T24 | 修复空argv[0]误读env；跨UID argv不可读时合法存活记录保持busy；实际launcher四组拒绝通过 | TCC责任链与旧helper协议真实拒绝仍待验；链接替换本次由严格签名拒绝 |
| T40 | 实际clone/rename后65文件大小/摘要/权限一致；身份保持，未并发启动 | 缺失binding/receipt保持unknown，未验已存在收据；四层更新依赖能力尚未完整接入；21GiB已分配磁盘与约20GiB空闲不足以确认完整归档往返空间 |
| T46 | 两项detached输出竞态RED复现后修复；44项相关测试及复审通过；签名UI空库启动/列出/关窗退出0 | 未验活动writer后立即退出UI、完整create取消及实际UI吞吐；进程组外写入者不由本次检查证明 |

T07的显式更新和回退分别在1.674/0.639秒取得新实例和预期hash，并确认pending移除及确认标记。无效exec缓存2.705秒回到bundled binary，后续稳定，无无界坏缓存循环。卸载响应曾断开，独立查询确认job未加载且进程消失；classic和缓存恢复原摘要。VM通过SIGINT正常停机11.352秒，日志保留classicAccepted及Guest stopped。原VM未改写，原VM和恢复副本磁盘均释放，token删除，临时helper/store/authorization right缺失。

初次AMFI清理断言失败后，早期readback只查服务与PPID，遗漏旧amfid 41252处于Ts状态；该readback不足以证明正常恢复。完整测试曾阻塞，采样观察到内核查询/posix_spawn等待，原因未查明。随后恢复旧进程执行状态，精确结束旧amfid并由launchd启动原系统服务，新PID63532、PPID1、Ss；独立状态读回通过，无debugserver或临时AMFI驱动。保留失败、阻塞、清理和最终通过记录，不将初次清理写成正常detach。

最终标准Swift入口：常规1254项/201套件、计时9项/8套件通过；既有3个短时限测试移入已有计时组，时限不变。相关输出44项/12套件、Python测试入口6项通过。make build、make launchpad、make check_bundle check_launchpad通过；编译仍有既有警告，字符串检查needs_review为129。最新签名产物未用于本批VM启动，不能把旧固定候选的运行证据归给新hash。完整Python和固件未在B23重跑。

证据入口：`evidence/B23-summary.json`、`evidence/B23-source-review.json`、`evidence/B23-worker-matrix.json`、`evidence/B23-swift-final-after-tail.log`、`evidence/B23-final-readback.json`。


## B24 执行记录（2026-10-09，继续 T02/T08/T24/T40/T46）

本批在 `11064b07` 基础上继续执行。T02 的202项逐提交语义审查、342项历史处置覆盖和47项全局能力对账已完成，按台账合同验收。47项中8项accepted，38项必选尚未完成，T45可选延期。计划适配不计为能力已实现或验收通过。T08/T24/T40/T46的原验收合同保持不变，尚未整项验收。

| 任务 | 本批结果 | 剩余工作 |
| --- | --- | --- |
| T02 | 202项逐提交语义审查完成、pending0；342项历史覆盖与47项合同/依赖/实际位置/验证入口对账完成；按台账合同验收 | 175项计划适配继续归属各能力任务，不计accepted |
| T08 | 对保留 rootless 副本尝试启动；首次连接前 VM compressor panic，一次重试未建立客户机连接；两次均 SIGINT 退出0 | 实际 RootHide 路径缺失；状态144和部分旋转未生效，原因未查明 |
| T24 | 生产客户端连接受控 v1 XPC 服务，verify/install × 三种日志设置共6行均拒绝，未调用旧方法，日志没有新增或改写 | 完整 TCC 责任链、可移植依赖闭包；历史 helper 实物矩阵未由受控服务证明 |
| T40 | 每个未完成创建阶段前重新检查 CLI/VM 摘要；两种归档后端的合成小样本保留8个持久文件及构造 binding/历史 receipt | 全流程资源冻结、新机 binding、可信 receipt、四层升级/回退与混合版本；64GiB VM完整归档往返空间不足 |
| T46 | 实际签名 UI 取消创建后，已观察到的进程退出、锁释放、最终尾部写入；3项生产输出链路受控测试通过 | 普通活动 writer 立即退出 UI、完整 ACK/断连/超时/写入失败、实际 VM 和 UI 吞吐矩阵 |

创建检查只覆盖阶段边界的 CLI/配对 VM 字节，不使阶段内工具不可变，也未覆盖脚本、Python、客户机载荷及外部缓存。合成归档样本为0GiB磁盘；其中历史 receipt 仅作为持久文件保存，不提供可信 store 授权。首次 system-tar 探针的 runtime 文件失败及成功重试均保留。

实际 UI 创建取消使用不完整 HTTP 输入，没有执行真实固件构建或 VM 启动。应用消失至已观察进程退出和最终日志尾部为1.044854秒，日志新增3064字节，最终SHA256为 `e50741560982861d01663d3a098b334d01e824dbd2613e7801f0b523ff72a972`，状态为 interrupted，两项锁释放。该结果不证明普通 CommandLine 活动 writer 的应用终止消费顺序。

受控真实进程输出100001行，输入12,788,934字节，持久化11,788,926字节，最终一次标准运行用时5.796955秒，持久化吞吐约2.03MB/s。精确摘要、最后无换行 panic、4000行显示上限及96001行省略计数均验证；没有性能门槛或既有基线，不推断 UI 渲染或实际 VM 吞吐。

最终 `make test_swift` 退出0：XCTest 254项（跳过3项）、Swift Testing常规1262项/202套件、计时9项/8套件通过，guest camera 124检查及 sound 算法测试通过。此前一次 XPC 超时、一次 HTTP/WebSocket/父进程退出时序失败的日志均保留，原因未查明；定向复验和最终标准入口通过，不宣称间歇失败已经修复。`make launchpad` 退出0，CLI及Launchpad Bundle校验通过；280项字符串检查无问题，129项翻译仍标记 needs_review。

本批实际 UI/helper 验收使用的签名客户端及最终重新构建的产物分别记录摘要，不能互相替代。最终构建基于本批未提交源码，元数据保留基础提交 `11064b07`。本批未应用新的二进制补丁。源码及测试提交为 `a45c9191`；最终签名构建和标准测试已覆盖该源码。

本批临时 helper 服务已卸载，两份令牌已删除；已观察到的 VM、UI、创建和工作进程均已退出，实际恢复副本磁盘没有打开句柄。宿主已有 amfid/debugserver 不归本批管理；本批未启动 AMFI 绕过，不推断其全局状态。

证据见 [B24-summary.json](evidence/B24-summary.json)、[源码摘要](evidence/B24-source-review.json)、[最终状态](evidence/B24-final-readback.json)、[最终产物摘要](evidence/B24-signed-artifact-manifest.json) 与 `evidence/B24/` 下的原始日志和矩阵。独立代码审查初轮发现1项Important（nil/nil摘要通过）及1项Minor（运行中错误被归为未写入拒绝）；修复后复审无剩余发现，受影响118项/6套件通过。审查者读取测试日志，未独立启动验证。详见 [初审](evidence/B24-code-review.json) 与 [复审](evidence/B24-code-review-final.json)。


B24 的202项处置为：175项 adaptation_planned、11项 already_equivalent、10项 intentionally_not_adopted、6项 superseded。历史140项（78个非合并、62个合并）保留原处置及理由，不宣称本轮重新逐项阅读；62个合并中54个空remerge、8个非空冲突解决，8份差异摘要与B22一致。T02对账源码冻结于 `11064b07`，后续 `a45c9191` 创建检查修复另有测试和独立审查。

机器校验覆盖202/342唯一SHA及精确集合、47项合同/依赖/入口、原状态保留、计划适配未提升、路径实有和摘要一致；全部检查通过。独立结构检查不代表第二次完整语义审查。冻结源码对象和删除记录位于 `evidence/B24/T02/evidence-objects/`，完整diff及审查时源码压缩档位于 [source-evidence.tar.gz](evidence/B24/T02/source-evidence.tar.gz)。当前台账见 [逐提交审查](T02_commit_semantic_reviews.json)、[342提交台账](commit_ledger.json)、[47能力台账](capability_ledger.json)、[本地路径映射](local_path_map.json)。

独立审查修正后的一次全量运行仍出现12项HTTP/WebSocket/XPC连接或超时失败；隔离17项/3套件通过，最终同一标准入口1262项/202套件及计时9项/8套件通过。7项WebSocket失败用例使用内存传输，不据此归因为网络；原因未查明。失败与成功日志均保留。最终客户端另通过两种归档后端的合成往返，8个持久文件一致，native/system-tar归档分别1272/1416字节；该结果不替代真实64GiB VM或可信store receipt验收。


## B25 结果（2026-10-09）

本轮继续 T02–T08、T24、T40、T46 共10项。已验收6项（T02–T07）；T08/T24/T40/T46仍未完成，没有新增整项验收。47项仍为8项accepted、38项必选尚未完成、1项可选延期。

| 任务 | 本轮结果 | 未完成范围 |
| --- | --- | --- |
| T08 | 只读核对固定IcliKit的domain顺序和144状态说明，未更改权限或添加fallback | 缺实际RootHide路径；服务144和部分旋转未生效，原因未查明 |
| T24 | 宿主Mach-O依赖递归封装、相对引用、嵌套签名顺序和Bundle验证；禁止读取Homebrew时ldid/trustcache实际运行通过 | 完整TCC责任链、历史helper实际XPC拒绝；Python/PATH不在本轮闭包内 |
| T40 | 每attempt私有CLI/VM与资源副本、聚合摘要、resume整体接受/拒绝；最多8份/2GiB并预留64MiB；失败副本保留 | Python/SDK/JB现场编译/既有cfw_input/可信新机binding未形成不可变依赖闭包；完整四层升级回退矩阵及64GiB往返仍未验 |
| T46 | 普通命令同步终止入口及有界排空实现、相关与标准测试通过；最终release实际日志精确匹配，UI退出操作被锁屏中断 | 解锁后重跑最终普通/escaped两组退出；helper组合及实际VM吞吐仍待验收 |

T40独立审查发现3项Important：开发debs.list遗漏、Disk.img链接别名绕过、复制期间来源增长可超过容量预检。三项均建立行为RED，修复后定向与相关测试通过，静态复审无新增Critical/Important。创建取消替身曾因来源revision变化提前拒绝，独立运行也复现。fs_usage确认QzhddrSrv在清单检查与复制之间对fixture requirements.txt执行setxattr，ctime变化而其余所记录revision字段相同。夹具预读及有界稳定等待未解决问题，已撤销。经复审，ctime/ACL/扩展属性/所有者未进入manifest；去掉ctime-only额外拒绝，保留inode、mode、size、mtime、逐文件SHA及全来源二次清单检查。确定性测试覆盖两个元数据变更时点、恢复mtime的内容改写与链接替换；原失败和诊断保留。

本轮标准Swift曾失败两次。首轮在新增终止门控测试中观察到quick命令执行成功，日志没有确定终止任务启动、超时和quick执行的准确先后；同步begin关闭入口后再异步wait已通过定向检查。第二轮在旧StopRefusal/ParentExit测试中记录5个issues；两个受控实验分别用50ms子进程存活时间和暂停周期输出复现相应断言失败。最终fixture改为停止拒绝后的存活回执、父进程退出后UUID请求与原日志回执，并保留存活、session、PPID、隔离和尾部断言。条件等待使用既有10秒上限；Suite时间限制和性能断言不变。上述两个fixture调整未修改生产停止信号或标准测试分组。受控实验不证明第二轮实际失败的完整原因，原原因仍未查明。原失败、采样和定向检查保留在B25及t46/legacy-fixtures中。

早期隔离UI的普通和escaped两组退出验收通过，各10002行/138939字节，属于同步门控修改前快照，不能替代最终release复验。最终53580180的签名隔离副本与生产主程序在移除签名后字节一致，已启动doctor并记录writer PID51919存活；随后CUA报告Mac已锁定且自动解锁失败，未执行退出操作。writer自释放后10002行/138939字节与预期精确一致，SHA256为`f972c4a3f4ffda6f317183c1cb66bc06522e5f6f454d6bf19c545c8ae69eedad`，包含panic尾部。隔离应用PID51581仍打开，待手动解锁后退出并重跑两组最终UI；未通过shell操作该UI。早期界面选择调用分别耗时约2564秒和865秒，未计为应用性能。最终UI的当前限制见`B25/ui-acceptance.json`。

首次签名构建中，CLI Bundle检查通过，Launchpad新校验器拒绝内部`@loader_path`；进一步核查发现外层两个宿主程序保留Xcode绝对rpath。校验器修复对loader/executable相对路径解析后进行Bundle包含检查，未知token、相对穿越、符号链接越界和非系统绝对路径仍拒绝；Launchpad在最终封存前对外层宿主程序执行native staging。独立复审要求补齐裸token实际依赖解析、拒绝修改Helpers嵌入Bundle，以及拒绝同一来源库在不同宿主程序上下文解析出不同依赖的行为测试。该修复未修改Swift源码，最终标准Python及签名构建结果另行记录，保留首次构建失败。

历史v1 helper实物SHA256为`bbc0917c2d5551de48b2eff7db8396c1c1d9a7d62f48eecdacf66a82da48b3c4`，内嵌版本1、签名团队空。只读配置检查退出78，未安装或启动服务。该结果不替代历史helper与最终客户端的XPC矩阵。TCC目前只有静态责任链和不记录坐标的验收步骤。

开发资源副本CLI resources与VM --help只读探针通过。最终安装布局副本235个条目、161310727字节；CLI resources及静态签名通过，原VM及副本VM --help均退出9，原因未查明；外部Python探针不可用。签名通过不代表VM可执行。本轮未启动VM、未修改AMFI或TCC，保留客户机载荷摘要。

本批源码提交为`0d1dc844`、`53580180`，最终构建基线为`53580180`。标准Python 611项（2项跳过）；Swift Testing常规1285项、计时9项；XCTest 254项（3项跳过）。签名构建、Bundle检查、实际内嵌CLI 4项及安装资源副本探针1项通过；最终原生依赖检查89条命令完成，2项Homebrew读取拒绝对照及8项沙箱工具操作符合预期。结果见[B25-summary.json](evidence/B25-summary.json)。测试原始输出、独立审查、实际UI记录和失败诊断保存在[evidence manifest](evidence/B25-evidence-manifest.json)。原始日志按`* -text`保全，最终测试结果不能替代未执行的实际VM接受条件。


## B26 结果（2026-10-09）

继续T08/T24/T40/T46，未新增整项验收。47项保持8项已验收、38项必选未完成、1项可选延期。

| 任务 | 本轮结果 | 未完成范围 |
| --- | --- | --- |
| T08 | 用户指定vm-new已只读检查；System脚本和Preboot标记提供rootless布局证据 | Data/User加密锁定，不能排除后来另装RootHide；实际服务、状态144及部分旋转仍待验 |
| T24 | B25与当前冻结VM均取得精确AMFI -424拒绝证据；当前subprocess返回-9 | 完整TCC责任链、历史v1实际XPC矩阵；新AMFI范围已准备并询问，尚未执行 |
| T40 | 两ROM纳入attempt快照与摘要，新建/prepare refresh共用副本；标准Swift、签名构建和安装布局smoke通过 | Python/SDK/JB/既有CFW输入闭包、可信binding/receipt和四层升级回退矩阵、完整64GiB往返 |
| T46 | 解锁后普通/escaped两组实际UI退出通过；两进程生产输出链正常ACK/30秒无ACK/断线/真实写失败通过 | 系统特权Mach服务与生产Client组合、完整UI/实际VM吞吐矩阵 |

T40源码提交为`b4e80c57`。行为RED为27项/2套件、29 issues，定向GREEN为27项/2套件（实际签名smoke当时跳过）。标准入口XCTest254项/3skip，Swift Testing常规1294项/205套件、计时9项/8套件通过；独立审查无发现。签名重建、Bundle与Launchpad校验通过。之后显式运行最终安装副本smoke：238条目、161819103字节，两ROM共503624字节与系统源摘要一致，Bundle签名有效，已有项目Python锁检查通过。原VM与副本VM的--help均被终止，smoke通过只证明副本结果一致，不证明VM可运行。

T46实际UI使用53580180最终签名Launchpad的隔离副本及受控签名CLI，保留生产AppDelegate、CommandLine、reader/writer链。两组各10002行/138939字节，SHA256为`f972c4a3f4ffda6f317183c1cb66bc06522e5f6f454d6bf19c545c8ae69eedad`。普通writer活动时退出；setsid后代持管道时取消退出，释放后退出。B25锁屏失败记录保留，本轮补齐最终退出操作。

临时跨进程harness使用Apple Development同团队签名、双方identifier/Team要求及生产audit-token校验，直接复用生产service/output/receiver/writer；正常ACK、生产默认30秒无ACK、客户端连接失效及O_RDONLY描述符的真实EBADF错误均有明确结果。它未经过固定privileged Mach入口、生产Client.request和真实Store。初次框架副本签名失败及临时回调隔离SIGTRAP均保留；修复只在harness，显式@Sendable回调后重跑四行，没有关闭actor运行期检查。断线行不证明服务器worker已退出。

vm-new只读挂载已清理，磁盘无打开句柄；8个所记录文件元数据与7个小文件摘要保持，Disk.img未做全量64GiB摘要。没有启动VM、修改AMFI/TCC或注册系统helper。当前冻结VM CDHash为`62a1f395413f6878c4de0042f6e77962aa2b1219`，SHA256为`c8e8be423f47c2bc85a7bca5715c306a49cbacba1442a5882416493660a5f8ff`。临时单哈希AMFI范围已生成并单独询问；此前范围只覆盖旧哈希，当前未执行。具体限制与证据见[evidence/B26-summary.json](evidence/B26-summary.json)。


## B27 结果（2026-10-09）

用户明确授权冻结源码`b4e80c57`的VM单一CDHash `62a1f395413f6878c4de0042f6e77962aa2b1219`，范围为`paths=[]`、`allow_all=false`、`spoof_apple=true`。本轮没有修改持久SIP/AMFI设置。没有新增整项验收，T08/T24/T40/T46仍未完成。

`vm-new`已通过实际客户机串口及classic shell确认采用rootless布局。`/var/jb`指向Preboot下的`jb-vphone/procursus`；在`/private/var/containers/Bundle/Application`搜索`.jbroot-*`，退出0且无结果；`/private/var/db/vphoned/bootstrap.json`及`/cores/.vphoned-boostrap-completed`不存在。该样本不满足T08实际RootHide客户机验收的前提。服务状态144和部分旋转未生效的原因仍未查明。

冻结VM的授权后`--help`退出0。首次无界面启动的标准输入为`/dev/null`，classic在框架停机请求期间连接，最终停机超时后强制停止、进程退出0。第二次通过独立FIFO提供串口输入；classic v1连接后实际读回布局，停机记录`classicAccepted`、`Guest stopped`及进程退出0。启动均使用`--no-vphoned-update`；未部署现代API，配置及宿主`.vphoned.signed`摘要保持。现有vm-2607未停止，vm-new的Disk.img已无打开句柄。

真实guest classic shell到无界面host的三组输出分别为18944、303104、888000字节，逐字节及SHA一致，均退出0、无截断、无超时；请求往返约0.0127、0.0361、0.0876秒。初次客户机缺少awk、退出127，失败保留；最终改用shell内建printf。这仅验证该通道的有界输出完整性及一次测量，不替代UI、helper日志、console、panic/取消/轮换或端到端吞吐验收。完整TCC责任链、历史helper实际XPC矩阵、可信binding/receipt及四层升级回退矩阵保持未完成。可用空间约18.6GiB，完整64GiB归档往返未执行。

AMFI清理未观察到正常detach：SIGINT后驱动未退出，SIGTERM后退出143，驱动及debugserver均不存在。`kickstart -k`被系统以150拒绝；TERM没有替换原amfid PID。随后仅结束本轮附加过的系统amfid，launchd启动新PID92181，独立核对PPID1、STAT Ss及系统服务running。空配置文件仍为空。驱动清理后及新amfid下，同工件`--help`仍返回0，原因未查明；不能据此宣称原AMFI拒绝已恢复或放行结果已完全撤销。没有重启宿主或执行缓存修改，失败记录均保留。

本轮仅新增运行证据与台账，没有修改产品源码。证据入口：[B27-summary.json](evidence/B27-summary.json)、[B27-evidence-manifest.json](evidence/B27-evidence-manifest.json)。
