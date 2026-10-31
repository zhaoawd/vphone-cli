# T52：绑定界面与环境更新路由（2026-10-21）

T51 的 rebase、两次真实启动和 Launchpad 状态验证已提交为 `4b5117d6634a0ccf84a63408a73de3ad7b6dcb9a`。本轮继续补齐 T52。新增实现、回归和实际界面验证均保留在工作区，未提交或推送。T52 不登记为 accepted。

## 实现

- 机器“更多”菜单新增“更改 Core Bundle…”；弹窗仅列出验证通过、支持目标功能的版本。首次绑定要求提供新备份目录，后端继续核对完整备份及 VM 停止条件。环境更新默认关闭，可单独提供 `--work-parent`。
- 绑定命令通过内嵌 CLI 执行，携带选择时的绑定摘要；首次绑定携带 `missing`。持久化入口继续在原 VM 锁内核对快照，保留客户机、内核和启动链来源。
- 环境更新通过普通启动器执行新绑定版本的 CLI。启动器保留 root-owned store 的收据、签名、所有权和锁核验，并要求 Bundle 的 `VPhoneEnvironmentUpdateProtocol` 为 `vphone.environment-update.v1`。旧 Bundle 未声明该协议时拒绝更新。此路由不增加权限提升功能；后续认证继续由 CFW 驱动处理。
- 环境路由仅接受既定选项，拒绝资源/组件来源覆盖、相对路径、重复选项及无效摘要。绑定在启动前、CLI 锁内准备时、Python 入口和实际写入前复查；不一致时拒绝。复查提前至证据文件创建之前。
- 需要环境更新时先检查磁盘持有者，再绑定，再启动环境更新子进程。更新失败或取消后保留已发布绑定，并报告该结果。实际取消回归确认子进程结束，命令历史无运行中项。

## 回归证据

| 实验设置 | 结果 | 证据文件 |
| --- | --- | --- |
| 原环境路由 | 新增测试复现启动器拒绝 `cfw update-environment`；修复后通过 | `route-red.log.gz`、`swift-library-r2.log.gz` |
| 定向 Swift | Kit 22 项、CLI 1 项、启动器策略 10 项通过；含参数化成功/失败及真实取消子进程 | `swift-library-r2.log.gz` |
| 扩展 Swift | Kit 256 项（跳过 11）；停止/锁 35 项；CLI 2 项；Bundle Store 42 项（跳过 1）通过 | `swift-expanded.log.gz` |
| Python 相关模块 | 218 项通过 | `python-expanded.log.gz` |
| 最终 Python 绑定复查模块 | 56 项通过，覆盖入口与实际受保护复制的绑定漂移拒绝 | `python-gate-final.log.gz` |
| 绑定漂移的证据创建顺序 | 首次回归发现仍创建空证据文件；提前复查后目标与证据均保持 | `python-binding-writer.log.gz`、`python-binding-writer-r2.log.gz` |
| 本地化、空白及构建脚本语法 | 本地化 307 键、0 issues；其他静态检查通过。保留既有 128 个 needs_review 项 | `static.log.gz` |
| 独立签名 CLI/VM 和 Launchpad | 构建及最终签名、资源、内嵌工具链、权限核对通过；两份打包 plan_gate 与最终源码摘要相同 | `build-*.log.gz`、`*-seal-final.log.gz`、`candidate-signatures.json` |

各组包含重复覆盖，数字不相加。Swift 跳过项依赖具名真实 CLI、独立父进程、签名归档或 smoke 选择器，本轮未提供这些选择器。最初 Python 沙箱测试出现 CFW staging 的 EPERM；相同模块在沙箱外使用隔离测试目录运行通过。新增库层夹具首轮使用无效来源版本，修正为有效版本后通过，未修改生产版本验证规则。Swift 构建首轮还发现嵌套 throwing 表达式和重复本地化符号；均已修正，日志保留。当前未解决测试失败为 0。

主要命令：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache" SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache" swift test --disable-sandbox --filter 'BundleChangeLibraryTests|BundleChangeTests|LaunchRouteTests|LauncherPolicyTests|EnvironmentBindingTests'
CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache" SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache" swift test --disable-sandbox --skip-build --filter 'VPhoneLaunchpadKitTests|VPhoneBundleStoreTests|EnvironmentBindingTests|CFWWorkParentTests|BindingPersistenceTests|VMStopTests|VMLockTests|LibraryLockTests|FirmwareRecoveryLockTests'
PYTHONPATH=tests .venv/bin/python3 -B -m unittest test_cfw_work_parent test_cfw_disk_transaction test_cfw_host_isolation test_patch_plan_gate test_cfw_env_update test_cfw_env_install test_vm_lock test_launchpad_bundle test_bundle_validation
PYTHONPATH=tests .venv/bin/python3 -B -m unittest test_patch_plan_gate
```

## 实际界面

候选：`.build/t52-entrypoints-launchpad-20261021.app`，内嵌 CLI CDHash `e347a55812c818777d9fc973dfb7b976ef3ad52e`、VM CDHash `7bddc387f8580896d89b5f7e881968f869b51d83`。界面使用隔离库 `.build/t51rt/lib`。候选包含当前工作区其他已保留 WIP，不能等同于 T51 提交产物。

Computer Use 首次打开被自动批准审核拒绝，原因是新构建候选属于未识别来源软件，要求运行当次确认。用户随后明确回复“允许，仅本次候选界面检查”。本轮严格限定为界面检查；未启动 VM、安装 Bundle、发布绑定或修改 AMFI。

保存的回归脚本为 [`tools/accept_t52_binding_ui.cua.mjs`](tools/accept_t52_binding_ui.cua.mjs)，通过 cua_repl 运行。最终 `ui-r2/result.json` 为 passed，AX 和截图包含以下结果：

- 机器菜单存在绑定入口；弹窗识别 target 尚无绑定。
- 本机 root-owned Core Bundle store 不存在，界面显示未安装已验证兼容版本。“应用”禁用；输入备份路径后仍禁用。
- 完整备份提示可见；环境更新默认关闭，开启后显示工作父目录和管理员认证提示。
- 取消返回已停止机器，未创建输入的备份目录；重新打开后更新选择关闭、备份路径为空。
- 最终机器仍已停止、`launchpad.json` 仍缺失。base/target 所检查的 Disk.img、config.plist、nvram.bin、sepStorage 和 launchpad.json 的文件身份、大小、mtime 及小文件摘要与检查前相同；不存在的路径保持不存在。这不是完整目录哈希校验。

首轮回归已完成默认选项、提示和取消检查，重开菜单时未观察到菜单项，因而未记通过。最终脚本最多重新观察三次菜单，每次使用新 AX 索引，不复用已失效索引。菜单消失原因未查明；最终完整回归通过。

## 验证限制

- 没有 root-owned 已安装 Bundle，真实认证、成功绑定及由新绑定 Bundle 执行的真实环境替换尚未验收。子进程替身回归验证编排和参数，不能替代上述验收。生产 Core Bundle 安装继续保留既有批准门，未修改仓库外存储。
- T51 的两次真实启动证据仍绑定其原具名候选；本轮新候选未重新启动 VM。没有扩大之前 AMFI 放行范围。
- 用户没有连接物理外置盘，已要求暂缓。真实外置卷、devfs/网络卷及相应故障矩阵未验收。
- GUI 已接入 `setBundle`。本地未发现独立 Launchpad 控制协议入口，本轮没有新增该协议。后续 template/trim 入口仍由各自任务验证共同门控。
- 证据源码快照包含先前未提交改动，不表示每个文件的完整差异均由本轮产生。历史任务 status、target_review、依赖和 accepted 保持。

证据清单：[`evidence/T52-entrypoints-20261021/manifest.json`](evidence/T52-entrypoints-20261021/manifest.json)。
