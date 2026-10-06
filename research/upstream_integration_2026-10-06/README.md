# 固定上游整合执行记录（2026-10-06）

本轮目标为 `2d21d21fbdd4f51f013616273ceda9b35a3e0789`。主工作区基线为 `e8d825b3723d9ec72d31b050a79d353acd4b59bf`，实施分支为 `codex/upstream-2d21d21-integration`，使用已经附加的隔离工作树。主工作区未修改，现有 VM 未操作。

`inputs/` 保存用户提供的三份附件原文；来源路径、摘要与大小见 `input_manifest.json`。附件内的历史状态、旧 sandbox 链接和实施授权字段仅表示原文状态。本轮授权来自用户“开始推进”“继续”；实际状态记录在 `tasks.json`。

## 结果与范围

| 任务 | 当前结果 | 限制 |
| --- | --- | --- |
| T00/T01 | 当前 Git 基线、干净主工作区和隔离工作树已固定 | 不替代 VM 恢复点 |
| T02 | 47 项能力、758 个任务路径条目、342 个提交的结构性台账已生成 | 文件名与摘要只能提供候选；逐项语义审查未完成 |
| T03 | 历史备份和验收 VM 路径不存在；用户清理后本次记录可用空间约 55.79 GiB | 本轮停机测试 VM 路径、备份目标目录及实际容量需求尚未确定 |
| T04 | 目标 Mach-O 文件唯一逻辑差异是保留 LC_UUID；定向签名与 codesign 检查通过 | 仍保留用户 10 月 1 日的决定；不能靠删除 UUID 接受空间不足的输入 |
| T05 | 保留 UTF-8 locale 与路径保护；修复归档遍历临时改变进程工作目录 | 当前高 UID 仅验证严格 ustar 拒绝；真实 VM 导入/导出未验收 |
| T06/T07 | 固定目标连接收尾、proxy 重试与 plist 已部分审查；18 项 Python、51 项相关 Swift 对照通过 | VSOCK、升级监听确认与每 VM 更新策略仍需审查和真实 VM 验证 |
| T08 | IcliKit 0.7.16、swift-collections 1.7.1 与其余五项 pin 已对齐；候选编译、签名与来源检查通过 | 未部署、未激活；客户机运行行为未验证 |
| T09 | 固定目标 141 个声明，比 2.2.3 新增 24 个，无删除；预设选择增量已记录 | 仅声明与 plist 元数据，未建立等价实现或配置迁移 |
| T10 | 实际记录归属、选择有效性和声明关系目标校验已修复；225 项模块测试、14 项真实固件测试通过 | C1 冻结执行输入、单个 patchID 归属、guest Gate 和固定上游二进制等价比较仍未完成 |
| T11 | 已核对只读 resolver、create selection SHA 与上游持久化入口 | VM/输入/target/schema 绑定及严格读写状态仍未实现 |
| T24 | 宿主入口已部分审查；隔离 CLI/VM Bundle、Launchpad 与未配置 helper 候选构建和签名检查通过 | 独立 launcher、每台 VM 的 Bundle 选择、真实授权行为和完整运行依赖闭包仍未完成；宿主 Swift 子集有一项 XPC 超时 |

`commit_ledger.json` 共 342 个提交，其中 280 个非合并、62 个合并提交。8 个合并提交的 remerge diff 非空，仍需审查；37 个提交只涉及文档路径，转入 T28 审查。不得据此把所有提交标记为已合入。

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
| T24 宿主 Swift 子集 | 50 项、7 个 suite、1 个 XPC 超时 issue | `evidence/T24-host-policy.log`、`evidence/T24-xpc-close-*.log` |
| 隔离 `make build` | 编译、完整资源、签名和 entitlement 检查通过 | `evidence/T24-complete-bundle-build.log` |
| 隔离 Launchpad 打包 | 红测试缺编译目录；修复后静态 Bundle 检查通过，546 个显式翻译值一致 | `evidence/T24-launchpad-build*.log`、`evidence/T24-launchpad-localizations.json` |
| T24 相关 Python 测试 | 41 项通过 | `evidence/T24-bundle-python.log` |
| 未配置 helper 候选 | 编译与签名检查通过；只读配置检查以退出码 78 拒绝 | `evidence/T24-helper-candidate-build.log`、`evidence/T24-helper-configuration-rejection.log` |

标准 `make test_swift` 尚未通过。默认并行运行产生 16 个 issues；此前单独套件与完整串行对照通过。具体原因未查明。没有修改标准测试入口或扩大超时时间；此前串行通过不能代替默认并行验收。新一轮串行采样显示 `APIHTTPFixture.stop → Process.waitUntilExit` 阻塞，采样时运行器已无存活子进程；该次运行没有完成。

候选 binary SHA-256 为 `70a488a63d93c9a2b8a5b6c62598036532b0ca28207ba8855305d9552172cc3f`。完整依赖和三项产物摘要见 `evidence/T08-candidate-manifest.json`；该文件明确记录 `activated=false`、`runtime_validated=false`。

## 调整与后续工作

继续使用已附加的 `codex/` 分支；按实际 SwiftPM/Make 与独立 Xcode 工程分别验证。T04 保留 LC_UUID，仅回收 LC_SOURCE_VERSION，随后明确拒绝。T08 补入七个具体 entitlement，但保留现有两项 keychain-access-groups，未增加上游的 `*` 和 `apple`；跨组 keychain 能力留待 T41 审查。这些调整及成本写入 `tasks.json` 的 `execution_rulings`。

本轮新增代码及测试提交为 `b6eb1873`、`4fd8dc87`、`6327738f` 和 `0531b903`。继续 T02 语义对账，并核对 T09/T10/T11 的补丁选择、模式策略与持久化接口；T24 后续连接 T40 每台 VM 的 Bundle 绑定及授权责任链。T03、真实客户机运行、最终集成验收和默认并行测试问题仍未完成。T45 按原方案延后。
