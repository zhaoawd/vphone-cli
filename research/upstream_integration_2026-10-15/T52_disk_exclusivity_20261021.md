# T52：磁盘互斥、进程归属与 CFW 工作区（2026-10-21）

本轮完成交接源码核对、离线回归和两处修正。新增 `setBundle` 编排已在库层实现；本地 GUI 和 Launchpad 控制命令尚未调用该接口。真实外置卷、VM 安装和启动未验收，T52 不登记为 accepted。

## 实现和证据

| 对象 | 结果 | 证据 |
| --- | --- | --- |
| 进程归属 | `VPhoneProcessHolder` 通过 `proc_pidpath` 区分 `vphone-vm`、Virtualization 服务和普通文件持有者；磁盘占用错误包含 PID 和程序名称 | `VPhoneLaunchLayout.swift`、`VPhoneBundleActivity.swift`、`ProcessHolderTests` |
| 停止保护 | 复用本地 `VPhoneVMStopper` 的内核 argv/config 识别与 `(pid, startedAt)`；升级 SIGKILL 前重新核对身份及目标列表，普通磁盘持有者不取得发信号资格 | `VMStopTests`：普通持有者、PID 复用、目标退出、强制停止和磁盘释放确认 |
| 绑定持久化 | 持有原有 VM 锁，磁盘仍打开时拒绝备份和绑定发布；保留本地首次迁移完整备份、来源保持及旧快照拒绝条件 | `VPhoneMachineBindingPersistence.swift`、`BindingPersistenceTests` |
| Launchpad 编排 | 需要环境更新时，先检查其他磁盘持有者，再绑定，再更新；更新失败保留已发布绑定并明确报告；`onStart` 在子进程成功启动后调用 | `VPhoneLaunchpadBundleChange.swift`、`VPhoneLaunchpadMachineLibrary.setBundle`、`BundleChangeTests` |
| 缺失 Core Bundle 的删除 | 本地删除入口使用嵌入式 CLI；新增绑定不存在版本的回归，确认删除命令仍能发起 | `EditLibraryTests.deletionDoesNotRequireTheBoundCoreBundle`，使用命令替身 |
| 工作目录 | `cfw install` 和 `cfw update-environment` 接受并转发 `--work-parent`；显式父目录须绝对路径、有效 uid 所有且私有或 sticky。每次创建独立的 0700 挂载目录 | `CFWWorkParentTests`、`test_cfw_work_parent.py` |
| 事务边界 | Disk.img staging 保留在 VM 内，并校验与原磁盘同设备。外部挂载根的路径/dev/inode/uid 写入 VM 内 journal，`plan_gate` 核对身份后才允许使用 | `cfw_disk_txn.py`、`plan_gate.py`、外部挂载根替换拒绝及驱动回归 |
| 容量 | VM 卷及显式工作卷使用 `statvfs.f_bavail * f_frsize`，同设备去重；容量未知或低于 50 GiB 时拒绝。未使用 Foundation 容量元数据 | 容量不足/查询失败回归；未实测物理外置卷 |
| 长 socket | 现有 `mkdtemp` 返回路径在 `withUnsafeMutableBufferPointer` 生命周期内读取；新增超过 `sun_path` 长度的实际 bind/connect、活跃/陈旧 socket 检测 | `BundleActivityTests.aLongControlSocketPathCanBindConnectAndDetectAStaleSocket` |

上游核对对象来自隔离仓库 `.build/u0-20261021/input.git`：`5a9db709`、`b4f59638`、`2745535e`、`c36e7d62`、`f9c69800`、`42548540`、`4bd1d3bf`、`b36dbaa9` 和新目标增量 `d3a959de`。固定审阅目标为 `2a0d3aca9fb79344d939365cc337b915ae9f2f97`。

本地 `vm update-kernel` 使用 `FirmwareKernelUpdate` 的独立事务，当前没有上游同名 `cfw update-kernel` 或向其传递工作父目录的 Launchpad helper。此次未增加无实际用途的同名选项，也未声称该入口已与上游工作目录合同等价。

## 本轮修正

1. 最终只读挂载根创建后，原代码先执行 `txn bind-mount`，再将 `CLEANUP_DONE` 置为 0。绑定失败时，退出处理会跳过新挂载根的清理。现改为先重置清理状态。测试在一次性驱动副本中恢复原顺序后，稳定捕获残留目录；修复后的实际驱动测试通过，原磁盘摘要/inode 保持，未执行发布，失败 journal 已归档。
2. 扩展 Python 回归发现 Undo 驱动夹具没有复制新增预检所需的 `cfw_disk_txn.py` 及其依赖。补齐隔离脚本后，原实际 Undo、发布、来源与输入保留断言通过。未增加生产绕过条件。

## 验证结果

| 实验设置 | 结果 | 日志 |
| --- | --- | --- |
| Swift 最终定向：LaunchLayout/ProcessHolder、BundleActivity、BundleChange、EditLibrary、CFWWorkParent | 55 项通过，退出 0 | `swift-targeted-final.log.gz` |
| 完整 `VPhoneLaunchpadKitTests` 加停止/锁套件 | Kit 239 项（跳过 11 项），VMStop/VMLock/LibraryLock/FirmwareRecoveryLock 35 项；退出 0 | `swift-expanded.log.gz` |
| Python 11 个相关模块 | 235 项，234 项通过，1 项因 Undo 夹具缺少模块失败 | `python-expanded.log.gz` |
| 修正夹具后的 Undo 驱动补验 | 1 项通过，退出 0；上述唯一失败已解决，未重复其余 234 项 | `python-undo-driver-final.log.gz` |
| 最终挂载绑定失败回归 | 修复前副本 1 项失败；正式驱动 1 项通过 | `python-bind-mount-before-fix.log.gz`、`python-bind-mount-final.log.gz` |
| 首轮沙箱 CFW 事务/隔离测试 | 50 项运行失败，含 staging 的 EPERM；相同测试无沙箱运行 50 项通过 | `python-sandbox.log.gz`、`python-transaction-unsandboxed.log.gz` |
| zsh/Python 语法及相关文件空白检查 | 通过 | `static.log.gz`、`ledger-check.log.gz` |

Swift 各组与 Python 补验存在重复覆盖，表中数字不相加。Kit 跳过项需要具名签名 CLI、smoke 或父进程场景；此次没有提供这些选择器。Python 沙箱失败日志保留，不将其记为产品回归通过；单项无沙箱验证和后续套件使用相同生产代码及磁盘命令替身。

执行命令（Swift 使用仓库内 module cache；涉及 socket、进程身份及 CFW staging 的测试在沙箱外运行）：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache" SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache" swift test --disable-sandbox --filter 'LaunchLayoutTests|BundleActivityTests|BundleChangeTests|EditLibraryTests|CFWWorkParentTests'
CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache" SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache" swift test --disable-sandbox --skip-build --filter 'VPhoneLaunchpadKitTests|VMStopTests|VMLockTests|LibraryLockTests|FirmwareRecoveryLockTests'
PYTHONPATH=tests .venv/bin/python3 -B -m unittest test_cfw_work_parent test_cfw_disk_transaction test_cfw_host_isolation test_patch_plan_gate test_cfw_env_update test_cfw_env_install test_cfw_guest_undo_driver test_guest_undo_transaction test_cfw_guest_publication test_cfw_runtime_publication test_vm_lock -v
PYTHONPATH=tests .venv/bin/python3 -B -m unittest test_cfw_guest_undo_driver -v
/bin/zsh -n scripts/cfw_install_host.sh
```

## 验证限制和下一步

- 测试使用一次性目录、磁盘文件和 APFS 命令替身；外部工作目录实际位于同一宿主文件系统。没有挂载物理外置卷、devfs 或网络卷，不能据此宣布跨设备运行通过。
- 本轮未操作真实验收 VM，未重新打包或修改冻结 `.app`，未执行真实 install/update/restore/boot；没有新增固件补丁。
- `setBundle` 的顺序、实际 lsof 与启动回调分别有回归；GUI/控制命令尚未接线，也未执行实际 Core Bundle 重绑后的环境更新。后续须保留本地备份、来源与认证约束。
- snapshot/clone 已在前轮接入共同门控；rebase/template/trim 尚待各自任务接线。T51 继续按独立范围推进，不能从本轮回归推定其互斥和物理计量已通过。
- 台账保留历史 `status`、`target_review`、依赖及其他任务记录；此次结果仅写入 T52 的新目标执行记录。未提交或推送。

证据清单：[`evidence/T52-20261021/manifest.json`](evidence/T52-20261021/manifest.json)。源码快照包含已有未提交改动，不表示全部文件差异都由本轮产生。
