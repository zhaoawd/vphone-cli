# T16 旧 VM 停机更新资格

日期：2026-10-01。基线提交 `18ae989`。范围：上游整合清单 T16 的代码与无 VM 测试。本项没有对任何真实 VM 执行判定或替换，没有读写 `~/.vphone/VMs`、`~/vphone-b4-accept`、`/Volumes/vphone-t03-restore`，没有使用 sudo，没有对 `vm-2607`、`vm-new` 执行命令或发信号。日志位于 `research/artifacts/t16-offline-update-eligibility-2026-10-01/`（Git 忽略）。环境：worktree 的 `.venv` 为指向主仓库 `.venv` 的符号链接；递归初始化 `vendor/*` 子模块；按 Makefile 格式生成被忽略的 `sources/vphone-cli/VPhoneBuildInfo.swift`。

## 1. 对照表

上游指 `upstream-2.2.3`。“安装器”指 `VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift`；“上游 daemon”指 `VPhoneDaemon/Daemon/GuestAPI+Environment.swift`；“上游宿主在线更新”指 `VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControlEnvironment.swift`。本地行号为本项提交后的位置。

### 1.1 停机更新（`cfw update-environment`）

| # | 上游行为 | 上游位置 | 本地结论 | 本地位置 |
| --- | --- | --- | --- | --- |
| 1 | `cfw update-environment [name]`；需要 root；VM 必须停机 | `Restore/VPhoneRestoreCommand.swift:294-325`；安装器 `:80-91`、`:110-113` | 已等价。判定以调用者身份运行；替换经现有 sudo 或 `--root-popup` 入口 | `sources/vphone-cli/VPhoneCFWEnvironmentCLI.swift`；`scripts/cfw_install_host.sh:61-64` |
| 2 | 无独立判定；遇到缺失的库跳过并继续 | 安装器 `:340-348` | 本地有意不同。先做只读判定，输出四类之一；只有 `offline_update` 执行 | `scripts/cfw_env_update.py:210-348`（`assess`）、`:431-509`（`check_vm`、`assess_disk`） |
| 3 | 以 `System/Library/xpc/launchd.plist.bak` 证明完整安装做过；缺失即拒绝 | 安装器 `:328-336` | 已等价。缺失归入 `full_migration_required` | `cfw_env_update.py:268-272`、`:309-310` |
| 4 | 重装 `vphoned`、`vphoned.plist`，重新注入 `launchd.plist` | 安装器 `:338-339`、`:855-884` | 本地有意不同。不替换 vphoned 及其 plist。依据：设计决定 3 只允许替换已存在的库与其签名产物；本地 vphoned 由启动时的 `--vphoned-bin` 自更新路径维护 | — |
| 5 | 五个库逐个处理：存在则替换（0755 root:wheel），缺失则输出“left out”并继续 | 安装器 `:340-348` | 本地有意不同。任一本地库缺失或不是普通文件即 `full_migration_required`，整体拒绝；只替换摘要与候选不同的库；保留原文件的属主、属组与权限 | `cfw_env_update.py:230-255`、`:335-346`、`:512-539`、`:548-600` |
| 6 | 库清单 5 项：launchdhook、SystemHook、libvcamcaptured、libcamfix、libmisfix | `VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestEnvironment.swift:8-15` | 本地有意不同。本地 5 项以 `libvlocation.dylib` 代替 `libmisfix.dylib`（T20 决定）；`libmisfix.dylib` 记为 `upstream_only`（T18） | `scripts/guest_environment.json` |
| 7 | `libmisfix.plist` 只在缺失时写入 | 安装器 `:352`、`:947-956` | 缺失（属于 T18/T19）。本项不写 | — |
| 8 | 不执行补丁、不注入加载命令、不做 cryptex/GPU、不改 Preboot、不翻转快照 | 安装器 `:270-289` | 已等价。环境模式不运行变体安装脚本与 `apfs_snap_rename.py` | `cfw_install_host.sh:346-367`、`:371-376` |
| 9 | 记录的 variant 不变 | 安装器 `:312-325`（注释） | 已等价，并增加前后摘要比较（上游无）：`config.plist`、NVRAM、SEP、`*.shsh`、`udid-prediction.txt`、`restore-info.json`、`.create-checkpoint/checkpoint.json` | `cfw_env_update.py:187-207`、`:561`、`:612-630`；`cfw_install_host.sh:381-386`、`:401-406` |
| 10 | clone 失败时附加调用者的原盘就地写入，并清除 variant 记录 | 安装器 `:148-172` | 本地有意不同。沿用 T15：clone → SHA-256 校验的完整复制 → 拒绝，不写原盘，不清除 variant | `scripts/cfw_disk_txn.py`；`cfw_install_host.sh:210-345` |
| 11 | 发布：rename 覆盖原名，旧盘不保留 | 安装器 `:292-297` | 本地有意不同。`RENAME_SWAP` 或两次 `RENAME_EXCL`；旧盘保留在 `.cfw-history/<id>/Disk.img` | `cfw_disk_txn.py:415-482` |
| 12 | `lsof` 占用检查，排除自身 | 安装器 `:122-131` | 已等价。替换走 T15 的 stage/pre-mount/pre-install/pre-publish 四点复核；只读判定另取目录锁并查占用 | `cfw_disk_txn.py:234-309`；`cfw_env_update.py:435-453` |
| 13 | 写宿主副本 `.vphoned.signed`，属主为调用者 | 安装器 `:298-302`、`:886-894` | 本地有意不同。不改 vphoned，因此不写 | — |
| 14 | 结束时提示 “start the VM to pick it up” | 安装器 `:307-308` | 已等价并细化：逐库输出加载者；声明不自动重启、不请求 respring | `cfw_env_update.py:351-366`、`:621-629` |
| 15 | 已知调用者时检查 bundle 属主，root 创建的文件交还调用者 | 安装器 `:112-121`、`:298-302` | 已等价。沿用 T15/B4 的 `VPHONE_INVOKER_UID/GID` 与 `SUDO_UID/GID` 规则，`.cfw-history`（含 `environment-update.json`）在成功、失败、中断路径交还 | `cfw_install_host.sh:73-106`、`:179-202` |
| 16 | Launchpad 控制命令与 helper 调用 `cfw update-environment` | `VPhoneLaunchpad/Control/VPhoneLaunchpadControlCommands.swift:60`；`VPhoneLaunchpadHelper/VPhoneLaunchpadHelperFirmwareRequest.swift:64`；`Machines/VPhoneLaunchpadMachineLibrary.swift:378` | 缺失。本项未接 Launchpad | — |

### 1.2 在线更新

| # | 上游行为 | 上游位置 | 本地结论 | 本地位置 |
| --- | --- | --- | --- | --- |
| 17 | 宿主 `updateEnvironment`：要求 `environment_update` 能力，读 `environment.status` 摘要，上传摘要不同的库，调用 `environment.install` | 上游宿主在线更新 `:17-57` | 缺失（T17）。本地宿主 RPC 放行 `environment.status`，拒绝转发 `environment.install` | `sources/vphone-cli/VPhoneHostRPC.swift:68`、`:79` |
| 18 | 每次连接自动执行 `syncEnvironment`，输出重启提示 | `VPhoneGuestControl.swift:189-191`；上游宿主在线更新 `:60-74` | 缺失（T17）。本地不自动同步 | — |
| 19 | daemon `environment.status` 返回各库 SHA-256 与 `root_read_only` | 上游 daemon `:23-36` | 已等价（API daemon 候选，未在客户机激活） | `sources/VPhoneDaemon/Daemon/GuestAPI+Environment.swift:23-36` |
| 20 | `environment.install`：名称在清单内、staging 摘要匹配、可写重挂 `/`、同卷临时文件后 rename、恢复只读、删除 staging | 上游 daemon `:43-71` | 已等价（同上） | 本地 daemon `:43-71` |
| 21 | 替换 libvcamcaptured 或 SystemHook 后结束 `cameracaptured` | 上游 daemon `:73-77` | 已等价 | 本地 daemon `:73-78` |
| 22 | 替换 libmisfix 或 SystemHook 后结束 `misagent`、`installd`、`lockdownd`、`remoted`；不重启 SpringBoard | 上游 daemon `:78-87`；`GuestAPI+DeviceIdentity.swift:53` | 缺失（T17/T18）。本地无 libmisfix 与该进程列表 | — |
| 23 | `reboot_required`：`/` 未恢复只读，或替换了 launchdhook | 上游 daemon `:93` | 已等价 | 本地 daemon `:83` |
| 24 | daemon 清单与宿主清单一致（注释约定） | 上游 daemon `:11` | 已等价并由测试约束：本地以 `scripts/guest_environment.json` 为唯一来源，测试比对 daemon 列表、guest 组件构建产物与 SystemHook 加载路径 | `tests/test_cfw_env_update.py` `ManifestConsistencyTests` |

结论：停机更新 16 项中已等价 7 项（1、3、8、9、12、14、15），本地有意不同 7 项（2、4、5、6、10、11、13），缺失 2 项（7、16）。在线更新 8 项中已等价 5 项（19–21、23、24），缺失 3 项（17、18、22），均属 T17/T18。

## 2. 判定规则与库清单来源

### 2.1 清单来源

`scripts/guest_environment.json` 是唯一来源，判定与替换都由 `scripts/cfw_env_update.py` 读取：

- 本地 5 项（`libraries`）：`launchdhook-vphone.dylib`、`SystemHook-vphone.dylib`、`libvcamcaptured.dylib`、`libcamfix.dylib`、`libvlocation.dylib`，客户机路径 `/usr/lib/<name>`，候选路径为 guest 组件 stage 中的相对路径。
- `upstream_only`：`libmisfix.dylib`（T18）。
- 加载路径：`/vh` 符号链接指向 `/usr/lib/launchdhook-vphone.dylib`；`/sbin/launchd` 含 `/vh` 的加载命令。
- 完整安装标记：`/System/Library/xpc/launchd.plist.bak`。
- classic 标记：`/b`（jb/exp 的 BaseBin launchdhook 别名，`scripts/cfw_install_jb.sh:190`、`:347-353`）。

宿主侧没有另一份 Swift 清单；`vphone-cli cfw update-environment` 只解析判定 JSON。guest 侧 API daemon 的清单（`GuestAPI+Environment.swift:12-18`）编译在客户机二进制中，不能在运行时读该文件，由测试约束一致。期望摘要来自 `make guest_components_build` 产出的 `.build/guest-components-v2/stage`：每个候选必须是普通文件、SHA-256 与该 stage 的 `manifest.json` 记录一致、含 `LC_CODE_SIGNATURE`，否则判定拒绝。替换写入的字节就是这些候选，不重新签名。

### 2.2 四类结果

| 分类 | 条件 |
| --- | --- |
| `not_applicable` | `restore-info.json` 或 `.create-checkpoint/checkpoint.json` 记录的 variant 为 `less` |
| `full_migration_required` | 以下任一：缺完整安装标记；launchd 有未知的非系统加载命令，或 `/b` 与 `/vh` 同时存在（`unknown`）；launchd 加载 `/b` 或存在 `/b`（`classic`）；launchd 没有环境加载命令（`none`，regular/dev 的 classic 安装）；磁盘为 v2 但记录的 variant 属于 classic（regular/dev/jb/exp）；`/vh` 缺失或指向其他位置；launchd 没有 `/vh` 加载命令；任一本地库缺失或不是普通文件 |
| `already_current` | 以上都不成立，且 5 个本地库的 SHA-256 都等于候选 |
| `offline_update` | 以上都不成立，且至少一个本地库的 SHA-256 不等于候选；`replace` 列出这些库 |

`libmisfix.dylib` 只出现在 `libraries`（`scope: upstream_only`，`state: upstream_only_absent` 或 `upstream_only_present_not_managed`）与 `notes` 中，不进入 `reasons`，不改变分类，不进入 `replace`。磁盘检查已决定 `full_migration_required` 时不需要候选；磁盘检查全部通过而候选不可用时，判定以退出码 2 失败，不输出 `already_current` 或 `offline_update`。

事实：本地现有的 regular/dev/jb/exp 安装脚本都不在 `/usr/lib` 放置这 5 个库，也不创建 `/vh`。exp 把 classic 相机库 `libvcamcaptured.dylib`、`libcamfix.dylib` 装到 procursus 的 `Library/MobileSubstrate/DynamicLibraries`（`scripts/cfw_install_exp.sh:569-609`，源码为 `scripts/vcamcaptured`、`scripts/camfix`，不是候选 stage）；jb/exp 的 launchdhook 来自 BaseBin，以 `/b` 加载（`cfw_install_jb.sh:183-192`、`:347-353`）；`libvlocation.dylib` 只出现在候选构建、daemon 与检查脚本中。推断：任何由本地 `cfw install` 建立的现有 VM，判定结果为 `full_migration_required`（regular/dev 为 `bootstrap: none`，jb/exp 为 `classic`），less 为 `not_applicable`。该推断尚未在真实 VM 上验证（见第 6 节）。

### 2.3 进程激活提示

`offline_update` 与替换报告带 `activation`：`automatic_restart: false`、`respring_requested: false`，逐库列出加载者（launchd 在启动时经 `/vh` 加载 launchdhook；SystemHook 由 launchdhook 插入此后启动的进程；相机与定位库由 SystemHook 在对应进程启动时加载）。替换在 VM 停机时进行，“下次启动加载新文件”为推断，未在客户机验证。运行中客户机的进程激活属于 T17。

## 3. 实现

| 文件 | 内容 |
| --- | --- |
| `scripts/guest_environment.json`（新） | 清单，见 2.1 |
| `scripts/cfw_env_update.py`（新） | `check-vm`：取 VM 目录 flock（非阻塞，不写运行记录）、只读打开 `Disk.img` 并记录 dev/inode/size/mtime 与抽样 SHA-256、`lsof` 占用检查、`hdiutil attach -readonly -nomount`、`diskutil apfs list -plist` 找名为 System 的卷、`mount_apfs -o rdonly,nobrowse` 挂到 bundle 外的临时目录、`assess`、卸载与分离、复核磁盘未变；less 不附加磁盘。`apply`：在暂存副本上读写挂载、重新判定、校验候选、逐个以同目录临时文件 + rename 替换差异库、替换后再判定必须为 `already_current` 且未选中的库摘要不变；记录 `environment-update.json`。`identity --compare`：发布后比较身份文件摘要。Mach-O 加载命令解析支持 thin 与 fat |
| `scripts/cfw_install_host.sh` | `--update-environment` 模式：沿用锁、只读描述符、T15 暂存与四点复核、发布与所有权交还；安装步骤改为 `cfw_env_update.py apply`；不翻转快照；发布后、归档前做身份比较，失败时退出码 3；拒绝未知选项（修改前未知参数被当作 VM 路径，随后被下一个参数覆盖，默认 exp 安装照常运行，见第 4 节） |
| `sources/vphone-cli/VPhoneCFWEnvironmentCLI.swift`（新） | `vphone-cli cfw update-environment [name] [--check] [--components DIR] [--root-popup]`。先以调用者身份运行 `check-vm` 并打印 JSON；`--check` 到此结束。否则：`already_current` 退出 0 不写；`full_migration_required`、`not_applicable` 退出 3 并列出原因与迁移要求；VM 忙（4）或输入错误（2）原样退出；只读检查无法读盘（5）时交给 root 驱动在暂存副本上重新判定。`offline_update` 经 `cfwInvocation` 调用驱动 `--update-environment`，传 `VPHONE_PYTHON`、`VPHONE_GUEST_COMPONENTS` 与调用者 uid/gid；不写 variant |
| `sources/vphone-cli/VPhoneRestoreCLI.swift` | 注册子命令 |
| `sources/VPhoneCore/VPhoneResources.swift` | `cfwEnvUpdateScript`、`guestComponentsStage` |
| `scripts/check_bundle.py` | 包内必备资源加入两个新脚本文件 |
| `tests/test_cfw_env_update.py`（新） | 31 项，见第 4 节 |
| `tests/cfw_env_update_harness.py`（新） | 测试专用入口：以 tar 文件充当磁盘映像，替换挂载与卸载；`CFW_ENV_FAULTS=replace-second` 让第二次替换报 `EIO`。生产脚本不含故障开关 |
| `tests/VPhoneCLITests/CFWEnvironmentUpdateTests.swift`（新） | 4 项：分类到动作的映射、检查失败的处理、驱动参数、子命令注册 |
| `tests/cfw_env_update_native.py`（新） | 手动运行的原生检查，见第 4.3 节 |

未改动：`research/0_binary_patch_comparison.md`。本项不新增、不修改任何二进制补丁，只替换已存在的文件。

只读判定的写入范围（事实）：不写 `Disk.img`（附加为只读，前后比较 inode、大小、mtime 与抽样 SHA-256）；不在 bundle 内创建文件（不调用 `vm_lock.py`，因此不写 `.vphone-runtime.json`；挂载点在系统临时目录）。以 root 运行判定时也遵守同样规则，且没有需要交还所有权的产物。

## 4. 测试

### 4.1 Python（`tests/test_cfw_env_update.py`，31 项）

合成系统卷为目录树：5 个本地库与候选为带 `LC_CODE_SIGNATURE` 的最小 64 位 Mach-O，`/sbin/launchd` 为带 `LC_LOAD_WEAK_DYLIB` 的 Mach-O，`/vh` 为符号链接。驱动测试把目录树打成 tar 写入 `Disk.img`，沿用 T15 的 `HostDriverFixture`（只绕过提权；`hdiutil`、`diskutil`、`umount`、`chown` 为替身）；挂载替身把附加映像的 tar 解到挂载点，读写挂载在卸载时写回同一 inode。

| 类 | 用例 | 修改前 | 修改后 |
| --- | --- | --- | --- |
| `AssessTests`（15） | 四类各至少一例：`already_current`；`offline_update` 只列差异库；5 个库分别缺失 → `full_migration_required`；`/vh` 缺失、指向错误、launchd 无 `/vh` → `full_migration_required`；classic `/b`（jb）；regular 无 hook（`none`）；未知加载命令（`unknown`）；无 `launchd.plist.bak`；v2 磁盘但记录 variant 为 exp；库为符号链接；less（restore-info 与 checkpoint 两种来源）→ `not_applicable`；缺 libmisfix 不进入原因、不进入 `replace`、分类仍为 `offline_update`；磁盘上存在 libmisfix 时不被替换；候选与 stage manifest 不一致、候选无签名 → 拒绝 | 错误（模块不存在） | 通过 |
| `ApplyMountedTests`（3） | 替换后整棵树只有两个目标库变化且权限保留、libmisfix 未被替换、替换后判定为 `already_current`；`full_migration_required` 与 `already_current` 返回 3 且树不变 | 错误 | 通过 |
| `ManifestConsistencyTests`（4） | daemon 列表与清单逐项相等；stage 路径都在 `check_guest_components.ARTIFACTS`；SystemHook 的 `#define` 加载路径覆盖清单中除 launchdhook 外的库，别名目标等于 launchdhook 路径；本地与上游 2.2.3 清单的差集只有 libvlocation 与 libmisfix | 4 项失败或错误（清单文件不存在） | 通过 |
| `CheckVMTests`（4） | 只读判定：调用顺序为 attach → locate → 只读 mount → unmount → detach；`Disk.img` inode、mtime、SHA-256 不变；bundle 目录项不变；身份摘要覆盖 5 个文件；目录锁被持有 → 退出 4 且不附加；另一进程打开 `Disk.img`（真实 `lsof`）→ 退出 4 并列出 pid；less 不附加 | 错误 | 通过 |
| `DriverUpdateTests`（5） | 成功：发布后的映像相对原映像只有两个目标库变化，内容等于候选；旧盘以原 inode 与 SHA-256 保留；`identity_unchanged: true`；身份文件摘要不变；`restore-info.json` 无 variant 写入；未调用 `apfs_snap_rename.py`；输出含 respring 提示；`.cfw-history` 交还调用者。缺库 → 拒绝（非 0），原盘 inode、SHA-256、mtime 不变，未发布，记录 `refused`。第二次替换失败 → 非 0，原盘不变，暂存副本已删，`original_check.unchanged: true`，记录 `failed`。root-popup 环境（无 `SUDO_*`）下 `environment-update.json` 交还 `uid:gid`。拼错的选项 → 退出 1，无任何调用与产物 | 5 项失败（使用修改前驱动与新模块，日志 `pre-change-driver.log`）。修改前驱动把 `--update-environment` 当作 VM 路径后被下一参数覆盖，按默认 exp 运行变体安装（替身）并发布，退出 0 | 通过 |

修改前首次运行（新模块与修改前驱动都不存在，30 项）：22 个错误、4 个失败（`pre-change.log`）。

### 4.2 Swift

`CFWEnvironmentUpdateTests`（4 项）。修改前：编译失败，`cannot find 'VPhoneEnvironmentDecision' in scope` 等 5 类错误（`swift_pre_change.log`，临时恢复修改前的 `VPhoneRestoreCLI.swift`、`VPhoneResources.swift` 并移除新文件后运行，随后恢复）。

### 4.3 原生检查（`tests/cfw_env_update_native.py`，手动运行）

在系统临时目录用 `hdiutil create` 建 64 MiB GPT + 区分大小写 APFS 卷 `System`，转为 raw 映像作为 `Disk.img`，写入合成布局（2 个库旧于候选）。以普通用户、真实 `hdiutil`/`diskutil`/`mount_apfs` 运行：

1. `check-vm`：`offline_update`，`replace` 为 `launchdhook-vphone.dylib`、`libcamfix.dylib`；`Disk.img` SHA-256、inode、mtime 不变。
2. 驱动副本（仅关闭 sudo 重执行）`--update-environment`：`method=clone`、`RENAME_SWAP` 发布，替换 2 个库；旧盘保留原 SHA-256 与 inode；身份文件 5 个不变。
3. 再次 `check-vm`：`already_current`。

结果：三步 PASS（`native.log`）。该检查说明：在本机（macOS 27）上，用户附加的 raw APFS 映像可由该用户以只读和读写方式挂载。真实 iOS 系统卷（sealed、含快照）是否允许非 root 只读挂载未验证。

## 5. 命令与结果

| 命令 | 结果 |
| --- | --- |
| `.venv/bin/python3 -B -m unittest tests.test_cfw_env_update`（修改前） | 30 项：22 错误、4 失败（`pre-change.log`） |
| `.venv/bin/python3 -B -m unittest tests.test_cfw_env_update.DriverUpdateTests`（修改前驱动） | 5 项：5 失败（`pre-change-driver.log`） |
| `.venv/bin/python3 -B -m unittest tests.test_cfw_disk_transaction tests.test_cfw_host_isolation tests.test_cfw_env_update` | 74 项通过 |
| `.venv/bin/python3 -B tests/cfw_env_update_native.py` | 三步 PASS（`native.log`） |
| `swift test --filter "CFWEnvironmentUpdateTests\|CFWInvocationTests"`（修改前源文件） | 编译失败（`swift_pre_change.log`） |
| `swift test --filter "CFWEnvironmentUpdateTests\|CFWInvocationTests"` | Swift Testing 8 项（2 个 suite）通过（`swift_filter.log`） |
| `make test_python` | 见第 5.1 节 |
| `make test_swift` | 见第 5.1 节 |
| `zsh -n scripts/cfw_install_host.sh`；`py_compile` 新 Python 文件；`git diff --check` | 通过 |

### 5.1 全量结果

| 命令 | 结果 |
| --- | --- |
| `make test_python`（第一次） | 513 项：1 错误、1 跳过（`test_python.log`）。错误为 `test_cfw_disk_transaction.DiskTransactionTests.test_interrupt_keeps_original_and_removes_copy`：发送 SIGINT 后驱动 30 秒内未退出（`TimeoutExpired`）。该用例走 install 模式，本项在该路径上的改动只有把变体安装子 shell 放进 `if/else` |
| 同一用例单独运行 5 次；4 个进程并行各运行 6 次 | 29 次全部通过 |
| `make test_python`（第二次） | 513 项通过，1 项跳过（`test_python_rerun.log`）。跳过项与 T15 记录相同类型（`test_daemon_api_icli`：IcliKit checkout 缺失） |
| `make test_swift` | 退出 0；Swift Testing 11 次运行共 996 项通过；XCTest 按各 `.xctest` 汇总行共 217 项执行、3 项跳过、0 失败；tar pipe 两条 1 GiB 路径峰值 RSS 10,059,776 / 10,289,152 字节；`test_guest_components` 124 项检查 0 失败（`test_swift.log`） |

第一次运行中的超时：原因未查明，之后 30 次运行（含一次全量）未复现。与本项改动是否相关未确认。

## 6. 在 `lp-b4-accept2` 上的真实验收步骤建议

前提：用户授权；`lp-b4-accept2`（`~/vphone-b4-accept`，regular）停机；该 VM 不是 `vm-2607`、`vm-new`。

1. 记录基线：`stat -f '%i %z %m' Disk.img`、`shasum -a 256 Disk.img config.plist nvram.bin SEPStorage *.shsh restore-info.json`、`ls -la` bundle 目录。
2. 只读判定（调用者身份）：`vphone-cli cfw update-environment lp-b4-accept2 --library-root ~/vphone-b4-accept --check > report.json; echo $?`。预期：退出 0；`classification: full_migration_required`；`bootstrap.kind: none`；5 个本地库 `missing`；`libmisfix.dylib` 为 `upstream_only_absent`；`disk.unchanged: true`。若退出 5（非 root 无法挂载 sealed 系统卷），记录 stderr，再以 `sudo` 运行同一命令并记录。
3. 复核第 1 步各值不变，bundle 目录无新增文件（含 `.vphone-runtime.json`、`.cfw_disk.*`、`.cfw-history`）。
4. 不带 `--check` 运行同一命令。预期：退出 3，输出拒绝原因与迁移要求，不出现 sudo 或认证对话框，bundle 无新增文件。
5. 判定期间另开终端启动该 VM 或以 `python3 -c 'open(...)'` 持有 `Disk.img`，预期退出 4。
6. `offline_update` 的真实验收需要一台已有 v2 环境（`/usr/lib` 5 个库、`/vh`、launchd `/vh` 加载命令）的 VM。本地没有建立这种 VM 的流程（P4 v2 创建尚未接入），因此该步骤待 v2 创建可用后在独立副本上进行：判定 → 替换 → 比对 `.cfw-history/<id>/environment-update.json` 与身份摘要 → 启动 → 记录各库实际加载（T17）。

## 7. 事实、推断与未验证

事实：

- 本地 classic 安装脚本不放置 v2 环境库与 `/vh`；`scripts/guest_environment.json` 是判定与替换的唯一清单来源，daemon 列表与其一致（测试约束）。
- 合成目录与 tar 映像上：缺任一本地库或加载路径时判定为 `full_migration_required` 且替换拒绝；缺 libmisfix 不改变分类且不计入替换；替换中途失败时原盘 inode、SHA-256、mtime 不变；成功时只有目标库变化，身份与配置文件摘要不变，旧盘保留。
- 本机 raw APFS 合成映像上，非 root 的只读判定与驱动替换路径（clone、`RENAME_SWAP`）均完成。

推断（待验证假设）：

- 现有本地 VM 都会判为 `full_migration_required`（regular/dev/jb/exp）或 `not_applicable`（less）。
- 停机替换后的首次启动加载新库，不需要额外 respring。

未验证：

- 真实 iOS 磁盘：系统卷名称是否为 `System`、非 root 能否只读挂载 sealed 卷、`mount_apfs -o rw` 对暂存副本的行为（root）。
- 以 root 运行时 `replace_file` 保留 root:wheel 属主（测试为普通用户，属主为测试用户）。
- 替换后的库在客户机上的加载与功能（T17）；候选 stage 的 64 字节相机协议与 classic 相机不兼容（`sources/VPhoneGuestComponents/README.md`），本项不改变这一点。
- Launchpad 入口；在线更新（T17）；libmisfix 与 `libmisfix.plist`（T18/T19）。

## 8. 需要决定的问题

- 是否把判定结果接入 `vm info`/诊断或 Launchpad（上游 Launchpad 有 `cfw.update-environment` 入口；本项未接）。
- 停机更新是否也应替换 vphoned 与 `launchd.plist` 中的 vphoned 条目（上游会做；本项按设计决定 3 未做）。
- 记录的 variant 属于 classic 而磁盘为 v2 时判为 `full_migration_required`。v2 创建流程接入后，需要为 v2 VM 定义 variant 记录值，否则这类 VM 的判定结果取决于该记录。
- `already_current` 当前退出 0（不写任何内容），其余拒绝退出 3；是否统一为非 0。
