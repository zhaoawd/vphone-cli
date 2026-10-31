# T15 CFW 写盘事务保护

日期：2026-10-01。基线提交 `7004e14`。范围：上游整合清单 T15 的代码与无 VM 测试。本项没有对任何真实 VM 磁盘执行 CFW 安装，没有读写 `~/.vphone/VMs`，没有使用 sudo。

## 1. 修改前现状对照

修改前文件均指 `7004e14`。上游指 `upstream-2.2.3:VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift`（下称“上游安装器”）。

| 项目 | 本地修改前 | 上游安装器 |
| --- | --- | --- |
| 写入对象 | 直接附加并写入 VM 的 `Disk.img`：`scripts/cfw_install_host.sh:186` 执行 `hdiutil attach ... "$IMG"`；离线快照改名同样写原盘（`:210` `apfs_snap_rename.py "$IMG"`）。没有副本 | 先在私有工作目录克隆 `Disk.img`（`:154` `work.directory.clone`），成功时只写克隆 |
| clone 失败 | 不适用（本地没有 clone 步骤） | 直接附加调用者的 `Disk.img`（`:158-168`），并清除已记录的安装变体（`:171` `clearRecordedInstall`）；快照改名写原盘（`:286-289`）。失败时原盘可能处于部分安装状态 |
| 发布 | 不适用（原盘就地修改） | 克隆路径用 rename 覆盖原名（`:292-297`），旧盘被替换后不保留 |
| VM 独占锁 | 有：`:60-64` 经 `scripts/vm_lock.py` 对 VM 目录 inode 取 `flock`，sudo 后重执行并以 `--check-inherited` 证明持有；各变体安装脚本在写入前再查一次（`scripts/lib/cfw_common.sh:81`）。锁只在开始时检查，挂载前、写入前、发布前不复核 | 未在本次范围核对 |
| 占用检查 | `:75` `lsof "$IMG"`，任何持有者即拒绝；只在开始时检查一次。驱动本身不持有磁盘描述符，因此不存在自身描述符误报 | `:127-133` `lsof -t`，排除自身 pid；安装期间持有已校验描述符 |
| 目标身份复核 | 无。`:45` 只检查 `-f`（跟随符号链接）；附加、安装、快照改名均按路径打开 | clone 失败路径在附加前用 `refersTo` 复核一次（`:165`），代码注释说明复核与 `hdiutil` 打开之间仍有窗口 |

结论（事实）：修改前本地安装始终就地写原盘，任一步失败都可能留下部分安装的原盘；锁存在但没有阶段性复核；没有 clone、复制校验或发布步骤。上游在 clone 失败时回退为原盘写入，本项按设计决定不采用。

## 2. 设计与实现

实现位置：主机驱动 `scripts/cfw_install_host.sh` 与新增辅助程序 `scripts/cfw_disk_txn.py`。四个变体（regular/dev/jb/exp）都由同一驱动附加磁盘并调用各自安装脚本（`Makefile` 的 `cfw_install*`、`vphone-cli cfw install`、`VPhoneCreateOrchestrator`、`setup_machine.sh` 均经该驱动），因此走同一保护路径；安装脚本本身未改。less 流程没有 CFW 安装步骤（`scripts/setup_machine.sh:710-722` 仅在非 less 时调用 `cfw_install_host`），记为不适用。

### 2.1 流程

驱动在取得 VM 锁后：

1. 以只读方式打开 `Disk.img`（`exec {DISK_FD}<"$IMG"`），整个运行期间持有该描述符；要求 `Disk.img` 是普通文件且不是符号链接。
2. `mktemp -d "$VM_DIR/.cfw_disk.XXXXXXXX"` 创建本次工作目录（与原盘同卷，满足 clone 与 rename 的同卷要求）。
3. `cfw_disk_txn.py stage`：记录原盘身份（dev、inode、size、mtime_ns、mode、uid、gid、blocks）与抽样 SHA-256；复核锁与占用；`fclonefileat` 从持有的描述符克隆到 `WORK/Disk.img`。clone 失败（任何非 `EEXIST` 错误）时：要求可用空间不小于磁盘逻辑大小 + 2 GiB，做保留空洞的完整复制，复制时计算原盘 SHA-256，复制后重新读取副本计算 SHA-256，两者不一致即删除副本并拒绝。clone 与复制都失败即拒绝。副本的 owner、group、mode 设为原盘的值。
4. `check --phase pre-mount`（附加前）与 `check --phase pre-install`（运行安装脚本前）：锁仍由本操作持有；持有的描述符仍是记录的原盘，size/mtime 未变；`Disk.img` 名称仍指向该 inode；工作目录中的副本仍是记录的 inode；除本操作外没有进程打开原盘。
5. 附加、安装、卸载与离线快照改名都只作用于副本。`hdiutil attach` 和安装脚本不继承原盘描述符。
6. `publish`：执行 `pre-publish` 检查（上述各项，另要求副本无持有者），然后 `renamex_np(RENAME_SWAP)` 交换副本与 `Disk.img`。卷不支持 `RENAME_SWAP`（`ENOTSUP`/`EINVAL`）时改用两次 `RENAME_EXCL`：先把 `Disk.img` 移到工作目录并核对 inode，再把副本移到空出的名称；第二步失败时把原盘移回。两种方式都不删除、不覆盖任何文件。改名与记录写入期间屏蔽 SIGINT/SIGTERM/SIGHUP。
7. `finish`：通过持有的描述符复核原盘（dev/inode/size/mtime 与抽样 SHA-256）；未发布时删除副本；把工作目录归档为 `.cfw-history/<UTC 时间>-<后缀>/`，其中 `transaction.json` 记录全部阶段、方法、错误与复核结果。

### 2.2 设计决定的落实

| 决定 | 实现 |
| --- | --- |
| 1 副本写入；clone → 校验完整复制 → 拒绝 | `stage`/`stage_copy`；没有原盘写入路径 |
| 2 锁与描述符复核；外部持有或运行中 VM 拒绝；自身描述符不误报 | `run_checks` 在 stage、pre-mount、pre-install、pre-publish 执行；`holders()` 只排除驱动 pid、辅助进程 pid，以及父进程为驱动的命令替换子 shell（`ps -o ppid=` 确认）；运行中的 VM 持有目录锁，`vm_lock.py` 取锁即失败 |
| 3 失败时原盘不变、副本清理、记录保留 | 驱动 `finish` 陷阱调用 `txn_abort` → `cfw_disk_txn.py finish`；卸载失败时以 `--retain-staged` 保留副本（可能仍附加）；记录保留在 `.cfw-history/<id>/transaction.json`，副本保留时记录在 `.cfw_disk.*/transaction.json` |
| 4 排他发布，旧盘保留 | `RENAME_SWAP`，或两次 `RENAME_EXCL`；旧盘保留为 `.cfw-history/<id>/Disk.img` |
| 5 不扩大特权 | 仍经现有 sudo 重执行入口；辅助程序不执行任意命令，只调用 `lsof`、`ps`；helper 注册与生产 Core Bundle 安装未改动 |

### 2.3 旧盘保留规则

选择：成功后旧盘保留在 `.cfw-history/<id>/Disk.img`，不自动删除。理由：

- 与现有固件事务的保留方式一致（`FirmwareTransaction.archive()` 把提交后的事务目录移入 `.firmware-history/<id>`，同样不自动删除）。
- 该文件是回退到安装前状态的唯一副本；T03 备份完成前不应由安装流程删除。
- clone 路径下旧盘与新盘共享未修改的数据块，发布时新增占用限于安装改动的块；VM 启动后新盘继续写入，旧盘保留的块会随之增加。复制路径下旧盘占用完整空间。

配套改动：`.cfw_disk.*` 与 `.cfw-history` 加入 `VPhoneBundleOps.exportExcludePatterns` 和 `scripts/vm_package.sh` 的排除列表；诊断（`cfw_mount_residue`）与 `vm create` 的 CFW 阶段复核把残留的 `.cfw_disk.*` 与 `.cfw_mount.*` 同样报告。`vm clone`、`vm_backup.sh` 复制整个目录，会带上 `.cfw-history`（与 `.firmware-history` 现状相同），本项未改。

回退步骤（未执行，供人工使用）：确认 VM 停止且无 CFW 运行，把当前 `Disk.img` 移走，把 `.cfw-history/<id>/Disk.img` 移回 `Disk.img`。`restore-info.json` 中记录的变体不会随之回退，需要按回退后的实际状态处理。

### 2.4 原子性范围

只保证 `Disk.img` 这一个名称的替换是排他的。安装脚本写入的宿主侧文件（`.cfw_temp`、`cfw_input`、`.vphoned.signed`、`scripts/vphoned/vphoned` 的构建产物）以及 Swift 侧随后写入的 `restore-info.json` 变体记录不在同一事务内；失败时这些文件可能已经改变。两次 `RENAME_EXCL` 的回退路径中，两次改名之间 `Disk.img` 名称短暂不存在。

## 3. 改动文件

| 文件 | 内容 |
| --- | --- |
| `scripts/cfw_disk_txn.py`（新） | stage/check/publish/finish；clone、校验复制、身份复核、占用检查、交换或排他改名发布、按 inode 判定的中断恢复、记录与归档 |
| `scripts/cfw_install_host.sh` | 持有原盘只读描述符；副本附加与快照改名；三处复核；发布；失败陷阱调用 `txn_abort`；`.cfw-history` 的所有权交还；删除原先的单次 `lsof "$IMG"` 检查（由辅助程序的占用检查取代） |
| `scripts/check_bundle.py` | 包内必备资源加入 `scripts/cfw_disk_txn.py` |
| `scripts/vm_package.sh` | 排除 `.cfw_disk.*/`、`.cfw-history/` |
| `sources/VPhoneCore/VPhoneBundleOps.swift` | 导出排除 `*.cfw_disk.*`、`*.cfw-history*` |
| `sources/VPhoneCore/VPhoneDiagnosticChecks.swift`、`sources/vphone-cli/VPhoneCreateLiveStages.swift` | 残留检查包含 `.cfw_disk.*` |
| `tests/test_cfw_host_isolation.py` | 夹具抽出为 `HostDriverFixture`；替身记录附加的映像路径，安装替身向附加映像写入标记，快照替身写入另一标记；两项所有权测试的期望改为包含 `.cfw-history`（硬链接测试改为检查保留的旧盘） |
| `tests/test_cfw_disk_transaction.py`（新） | 18 项故障注入与中断恢复测试 |
| `tests/cfw_disk_txn_faults.py`（新） | 测试专用入口，替换 clone/copy/swap/改名函数以注入故障；生产脚本不含故障开关 |
| `tests/cfw_disk_txn_native.py`（新） | 手动运行的原生检查：在临时 APFS 与 HFS+ 映像卷上执行 stage→check→publish→finish |
| `tests/VPhoneCoreTests/BundleOpsTests.swift`、`tests/VPhoneCoreTests/DiagnosticsTests.swift` | 导出排除与残留诊断断言 |

## 4. 故障注入测试

测试运行驱动副本，只替换提权判断；`hdiutil`、`diskutil`、`umount`、`chown` 为替身，`lsof` 默认为替身，指定 `REAL_LSOF=1` 时调用 `/usr/sbin/lsof`。磁盘为 32 MiB 稀疏文件（头部 256 KiB 与尾部 32 KiB 随机数据）。安装替身向附加的映像偏移 512 写入 `CFW-PATCHED`，快照替身向偏移 1024 写入 `SNAPSHOT-FLIPPED`；写到原盘即表现为原盘 SHA-256 改变。

“修改前”列为同一测试对 `7004e14` 驱动的运行结果（日志 `pre-change.log`）。

| 用例 | 注入 | 修改前 | 修改后 |
| --- | --- | --- | --- |
| 成功路径，四变体，真实 `lsof` | 无 | 失败：原盘被写入，无 `.cfw-history` | 通过：`Disk.img` 含两个标记且 inode 为副本；`.cfw-history/<id>/Disk.img` 的 SHA-256 与 inode 等于原盘；记录 `method=clone`；驱动自身描述符未被判为占用 |
| clone 不可用 → 完整复制 | clone 报 `ENOTSUP` | 失败 | 通过：`method=copy`，记录的源与副本 SHA-256 均等于原盘；发布后磁盘仍为稀疏（分配小于逻辑大小一半） |
| clone 与复制都失败 | clone `ENOTSUP`，copy `EIO` | 失败（安装照常写原盘） | 通过：退出非零，未调用 `hdiutil attach`，原盘 SHA-256 与 inode 不变，无副本，失败记录含 `EIO` |
| 复制校验不一致 | 复制后翻转副本首字节 | 失败 | 通过：输出含 `copy verification failed`，未附加，原盘不变，副本已删 |
| 外部进程持有原盘，真实 `lsof` | 测试进程另起一个打开原盘的进程 | 失败（原驱动拒绝，但输出不含持有者 pid；本测试要求列出 pid） | 通过：拒绝并列出持有者 pid，未附加，原盘不变 |
| 目录锁被外部持有 | 测试进程对 VM 目录 `flock` | 通过（原有锁） | 通过：`VM lock unavailable`，未创建工作目录 |
| 挂载前目标被替换 | stage 成功后把 `Disk.img` 改名并放入新文件 | 失败 | 通过：`pre-mount check` 拒绝，未附加；被移走的原盘与替换文件内容均不变 |
| 安装期间目标被替换 | 安装替身替换 `Disk.img` | 失败 | 通过：`pre-publish check` 拒绝，替换文件未被覆盖，原盘不变 |
| 安装步骤失败 | 安装替身退出 37 | 失败（原盘已被写入） | 通过：退出 37，未改快照，原盘不变，副本已删，记录 `exit_code=37` |
| 快照改名失败 | 快照替身退出 5 | 失败 | 通过：原盘不变，副本已删 |
| 发布失败 | `RENAME_SWAP` 报 `EIO` | 失败 | 通过：原盘不变，副本已删，记录含 `EIO` |
| 不支持交换时排他改名发布 | `RENAME_SWAP` 报 `ENOTSUP` | 本用例修改前未单独运行（新增于原生检查之后） | 通过：两次 `RENAME_EXCL` 发布，旧盘保留 |
| 排他改名第二步失败 | `ENOTSUP` + 放置副本一步 `EIO` | 同上 | 通过：原盘移回 `Disk.img`，inode 与 SHA-256 不变 |
| 卸载失败 | `umount` 替身持续失败 | 失败 | 通过：不改快照、不发布，原盘不变，副本与记录保留在 `.cfw_disk.*` 且输出给出路径 |
| SIGINT | 安装期间向进程组发送 SIGINT | 失败 | 通过：退出 130，原盘不变，副本已删 |
| 交换后记录未写入即中断 | 直接交换后调用 `finish` | 新增（辅助程序级） | 通过：按 inode 判定为已发布，旧盘归档，不删除 |
| 第一次排他改名后中断 | 手工把原盘移入工作目录后调用 `finish` | 新增 | 通过：原盘移回 `Disk.img` |
| 工作目录中的名称指向原盘 inode | 用硬链接替换副本名称 | 新增 | 通过：`finish` 不删除，记录 `not the recorded staged image` |

修改前运行：当时共 32 项（新增 13 个测试方法 + 19 项既有主机隔离测试），结果 14 个失败、1 个错误，全部来自新增方法（成功路径的 4 个变体子测试分别计数）；新增方法中只有“目录锁被外部持有”通过；既有主机隔离测试在夹具重构后全部通过。排他改名与中断恢复的 5 项在实现过程中加入，未对修改前驱动运行。

### 原生检查（`tests/cfw_disk_txn_native.py`）

用 `hdiutil create -type SPARSE -size 3g` 创建临时 APFS 与 HFS+ 映像并附加到临时目录（不需要 root），在其中用 96 MiB 稀疏 `Disk.img` 执行 stage→check→publish→finish（抽样 SHA-256 路径：>64 MiB）。

| 卷 | 结果 |
| --- | --- |
| APFS | `method=clone`，`RENAME_SWAP` 发布，旧盘 SHA-256 与 inode 等于原盘 |
| HFS+ | clone 报 `ENOTSUP`，完整复制且 SHA-256 一致；`RENAME_SWAP` 报 `ENOTSUP`，两次 `RENAME_EXCL` 发布；旧盘 SHA-256 与 inode 等于原盘。HFS+ 不保留空洞：原盘与副本均为 196608 块（96 MiB 全部分配） |

首次原生运行发现两个问题并已修正：HFS+ 上 `lseek(SEEK_DATA)` 返回 `ENOTTY`（原实现只处理 `EINVAL`/`ENOTSUP`，复制失败）；HFS+ 不支持 `RENAME_SWAP`（原实现只能拒绝发布）。第二项促成了排他改名回退。

## 5. 命令与结果

日志位于 `research/artifacts/t15-cfw-write-protection-2026-10-01/`（Git 忽略）。环境：worktree 的 `.venv` 为指向主仓库 `.venv` 的符号链接；初始化 `vendor/*` 子模块；按 Makefile 格式生成被忽略的 `sources/vphone-cli/VPhoneBuildInfo.swift`。

| 命令 | 结果 |
| --- | --- |
| `.venv/bin/python3 -B -m unittest tests.test_cfw_disk_transaction tests.test_cfw_host_isolation`（修改前驱动） | 32 项，14 失败，1 错误（`pre-change.log`） |
| 同上（修改后） | 37 项通过 |
| `.venv/bin/python3 -B tests/cfw_disk_txn_native.py` | 退出 0；APFS、HFS+ 两行 PASS（`native.log`） |
| `swift test --filter "exportExcludesRegenerableStagingFiles\|retainedCFWDiskStagingDirectoryIsResidue"`（临时恢复修改前的两个 Swift 源文件） | 2 项失败，5 个问题（`swift_pre_change.log`）；随后恢复修改后源文件 |
| `swift test --filter "BundleOpsTests\|DiagnosticsTests\|CreateLiveStagesTests"` | Swift Testing 65 项（6 个 suite）通过、30 项（1 个 suite）通过（`swift_filter.log`） |
| `make test_python` | 471 项通过，1 项跳过（`test_daemon_api_icli`：IcliKit checkout 缺失）；其中 18 项为本项新增（`test_python.log`） |
| `make test_swift` | 退出 0；Swift Testing 11 次运行共 956 项通过；XCTest 按各 `.xctest` 汇总行共 217 项执行、3 项跳过、0 失败；tar pipe 两条 1 GiB 路径峰值 RSS 8,945,664 / 8,028,160 字节；`test_guest_components` 124 项检查 0 失败（`test_swift.log`） |
| `zsh -n` 五个 CFW 脚本与 `vm_package.sh`；`py_compile` 新 Python 文件；`git diff --check` | 通过 |

## 6. 真实写盘验收步骤建议

前提：T03 完成，并有可恢复的完整备份。不要使用 `vm-2607`、`vm-new` 或任何在用 VM。

1. 用 T03 生成的恢复副本建立一台专用测试 VM，放在独立的映像卷上（例如 `hdiutil create -type SPARSE -fs APFS` 创建并挂载的卷），使写满或误删不影响其他 VM。记录 `Disk.img` 的 SHA-256、inode、大小与 `stat` 输出。
2. 正向：对该 VM 分别执行 `make cfw_install VM_DIR=...`（regular）及 dev/jb/exp。每次检查：输出包含 `staged copy` 与 `previous Disk.img retained`；`.cfw-history/<id>/Disk.img` 的 SHA-256 与安装前记录一致；`transaction.json` 的 `method`、`publish_method`、`original_check.unchanged=true`；`.cfw_disk.*`、`.cfw_mount.*` 无残留；`hdiutil info` 无该卷映像；所有权交还给调用用户。随后启动 VM，验证启动与 CFW 内容（D3 的清单脚本可复用）。
3. 故障：安装运行中按 Ctrl-C；在安装期间让另一进程以只读方式打开原盘（预期 `pre-publish` 拒绝）；用一台磁盘位于 HFS+ 卷的 VM 验证复制与排他改名路径。每次核对原盘 SHA-256 与 inode 不变。
4. 回退：把 `.cfw-history/<id>/Disk.img` 移回，确认 VM 回到安装前状态，并按实际状态处理 `restore-info.json`。
5. 记录空间：clone 路径发布后与首次启动后分别记录卷可用空间与旧盘的独占块变化。

## 7. 事实、推断与未验证

事实：

- 修改后，四个变体的 CFW 安装在测试替身下只写副本。第 4 节各失败与中断用例中原盘 SHA-256 与 inode 不变；成功与已发布用例中旧盘以原 inode 保留在 `.cfw-history/<id>/Disk.img`，SHA-256 等于安装前。
- 自身持有的原盘描述符在真实 `lsof` 下未被判为占用；外部进程持有时被拒绝并列出 pid。
- 在本机（macOS 27）APFS 卷上 `fclonefileat` 与 `RENAME_SWAP` 可用；HFS+ 卷上二者均返回 `ENOTSUP`，`RENAME_EXCL` 可用，`SEEK_DATA` 返回 `ENOTTY`。

推断（待验证假设）：

- 以 root 运行时，副本的 owner/group/mode 设置与所有权交还行为与测试一致。测试为普通用户运行，`chown` 为替身。
- 在 64 GiB 级别的真实磁盘上，抽样 SHA-256（头尾各 16 MiB 与 64 个 1 MiB 窗口）与完整复制路径的耗时可以接受。完整复制路径会对原盘与副本各做一次完整 SHA-256（空洞按零计入）。

未验证：

- 真实 `hdiutil attach`、`mount_apfs`、安装脚本、`apfs_snap_rename.py` 作用于副本的完整流程（需要 root 与真实 VM 磁盘，留给 T03 之后的验收）。
- 运行中的 VM 实际持有目录锁时的拒绝（测试用外部 `flock` 代替运行中 VM）。
- SIGTERM、SIGHUP 路径；SIGKILL 或断电后的残留（副本与工作目录保留，原盘未被写入，但没有自动清理）。
- `pre-publish` 检查与改名之间仍有短窗口；该窗口内被替换的 `Disk.img` 会被交换进工作目录而不是被删除。

## 8. 需要决定的问题

- 旧盘保留是否需要数量上限或清理命令（当前不自动删除，与 `.firmware-history` 相同）。
- `vm clone` 与 `vm_backup.sh` 是否排除 `.cfw-history`（当前与 `.firmware-history` 一样随目录复制）。
- 完整复制路径的空间门槛使用“逻辑大小 + 2 GiB”。非 APFS 卷上这一门槛对稀疏能力未知的文件系统偏保守；是否调整。
