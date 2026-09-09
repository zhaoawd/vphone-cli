# B4 离线操作占用保护（2026-09-09）

统一每个离线 bundle 操作的占用保护入口，使不同入口的保护方式一致：一个操作在读写
bundle 文件时，另一个进程（含正在运行的 VM boot/dfu）不得同时修改同一 bundle。

本文分两部分：Swift 侧（`sources/`）与 Shell/Makefile 侧（`scripts/`、`Makefile`）。
两侧使用同一把对目录 inode 的 `flock`，因此互斥。

---

## 第一部分：Swift 侧

### 三层模型

保护分为三层，选择哪一层取决于操作在获取保护时“被保护对象是否已存在”以及操作
本身能否持有锁。

1. **bundle 锁（`VPhoneBundleGuard.withBundleLock`）**
   - 机制：对 bundle 目录 inode 的 `flock(LOCK_EX)`，由 `VPhoneVMLock` 持有，
     跨整个“检查—写入”窗口。
   - 适用：bundle 目录在操作开始时已存在的排他操作（config、rename、delete、
     clone、export、stage-vphoned、cfw-record、cleanup-firmware、fw prepare、
     fw patch、restore-decrypt）。
   - runtime 记录（`.vphone-runtime.json`）只用于解释拒绝原因，不参与是否允许的
     判定。判定完全由内核锁归属决定。
   - 拒绝行为：锁被占用时抛出 `VPhoneBundleGuardError.busy`，拒绝措辞与
     `VPhoneVMStopper` 一致（读记录识别持有者 pid/operation，仅当 pid 存活且非
     zombie 时才报告为持有者）。

2. **library-root 锁（`VPhoneBundleGuard.withLibraryLock`）**
   - 机制：对 library 根目录（VM 名字空间）inode 的 `flock(LOCK_EX)`，由
     `VPhoneLibraryLock` 持有。带 10s 重试预算（`defaultTimeout`），轮询间隔 0.02s。
   - 适用：放置或移除 bundle **名字**的操作（create、import，以及 rename 中对目标
     名字的检查+移动）。
   - 不写 runtime 记录：library 根不是 bundle，写在此处的记录不会被任何读 bundle
     记录的代码读取。

3. **协作式 DFU 校验（`VPhoneBundleGuard.requireDFUOwner`）**
   - 机制：不获取锁，而是校验当前锁的持有者。
   - 适用：restore。restore 驱动的设备只在 DFU boot 运行期间存在，因此 restore
     必须在一个已被锁定的 bundle 上工作，自身无法再取锁。
   - 校验条件（全部满足才返回持有者记录，否则抛
     `VPhoneBundleGuardError.dfuSessionRequired`）：
     1. bundle 锁被持有；
     2. runtime 记录可读；
     3. 记录的 operation 为 `dfu`（`isDFUOperation`）；
     4. 记录中的 pid 在内核中存在且非 zombie；
     5. 该 pid 仍是本 bundle 的 `vphone-cli --config <bundle>/config.plist` 进程
        （经 `ps` + `VPhoneBootProcessLocator` 确认）。

### 为什么 create/import 需要 library 锁（TOCTOU）

bundle 锁保护的是 bundle 目录 inode。create 与 import 在检查名字时，目标 bundle
目录尚不存在，没有可锁的 inode。若仅用“`fileExists` 检查 + `createDirectory`/
`moveItem` 放置”，两个同名 create 会同时通过 `fileExists`，随后在放置阶段竞争，
属于 time-of-check-to-time-of-use 竞态。

library-root 锁把“名字存在性检查”和“放置”合并为同一锁生命周期，使二者原子。
测试通过 `create(_:in:afterNameCheck:)` 的 `afterNameCheck` seam 验证：在检查与放置
之间探测 `VPhoneLibraryLockProbe.isLockHeld(root:)` 为 true。

锁采用重试而非立即失败：持有期短（create 是一个稀疏磁盘文件加两份 ROM 拷贝，
import 是同文件系统 rename），且两个**不同**名字的并发 create 都应成功，不应因锁
冲突而误报。两个**相同**名字时，后到者在先到者之后进入，得到 `alreadyExists`——
这是对实际状态的正确描述。

### 为什么 restore 校验持有者而不取锁

restore 需要一个正在 DFU 中的设备。该设备只在 `vphone-cli --dfu` boot 进程运行
期间存在，而该 boot 进程在整个会话中持有 bundle 锁。restore 若尝试再取同一 bundle
锁必然失败（`flock` 按 open file description 计，同进程的另一次 open 也会冲突）。
因此 restore 改为校验：锁必须被一个“本 bundle 的、存活非 zombie 的 DFU boot 进程”
持有。runtime 记录本身不足以证明（记录永不删除，可能指向被复用的 pid），故记录中的
pid 需再经内核状态与 `ps` 双重确认。

### cfw-record 锁与 `holding:` 编译期证明

CFW 安装脚本在其自身进程内持有 bundle 锁，脚本退出时释放。安装完成后，Swift 侧要
记录 variant（`recordVariant`）并可选删除已构建固件（`removeBuiltFirmware`）。此时
脚本的锁已释放，需要重新获取一个 `cfw-record` 锁再写入。

`recordVariant` 与 `removeBuiltFirmware` 的签名要求一个 `holding _: VPhoneVMLock`
参数，把“调用方必须持有 cfw-record 锁”从约定变为编译期要求：没有锁对象就无法调用。
`removeBuiltFirmwareIfIdle` 是内部封装，自身通过
`withBundleLock(operation: .cleanupFirmware)` 取锁。

调用点（`VPhoneRestoreCLI`、`VPhoneCreateOrchestrator`）在 CFW 安装成功后用
`withBundleLock(operation: .cfwRecord)` 包裹 record/cleanup，并把 `lock` 传入。
锁不可用（VM 正在运行）时，仅跳过记账（`try?`），向 stderr 打印一条 warning，不
中止进程——因为 CFW 安装本身已经成功。

### operation 词表

所有可能写入 bundle runtime 记录的 `operation` 字符串集中在 `VPhoneVMOperation`，
使写入方与读取方比较的值不会漂移。

| operation | 常量 | 分组 |
| --- | --- | --- |
| boot | `boot` | VM 生命周期 |
| dfu | `dfu` | VM 生命周期 |
| stage-vphoned | `stageVphoned` | Swift 离线 |
| config | `config` | Swift 离线 |
| rename | `rename` | Swift 离线 |
| clone | `clone` | Swift 离线 |
| delete | `delete` | Swift 离线 |
| export | `export` | Swift 离线 |
| import | `importArchive` | Swift 离线 |
| create | `create` | Swift 离线 |
| fw-patch | `fwPatch` | Swift 离线 |
| cfw-record | `cfwRecord` | Swift 离线 |
| restore-decrypt | `restoreDecrypt` | Swift 离线 |
| cleanup-firmware | `cleanupFirmware` | Swift 离线 |
| fw-prepare | `fwPrepare` | Swift + shell（见第二部分） |
| cfw | `cfw` | shell（host driver sudo 后）/ Swift |
| backup | `backup` | shell |
| restore-backup | `restoreBackup` | shell |
| switch | `switchVM` | shell |
| package | `package` | shell |

`vmLifetime = {boot, dfu}`。`isBootOperation` 判定 operation 是否属于 `vmLifetime`；
`isDFUOperation` 判定 operation 是否等于 `dfu`（dfu 同时满足 isBootOperation 与
isDFUOperation）。`all` 列出完整词表，供测试与诊断使用，不含重复项。

### 每操作对照表（操作 → 锁类型 → 拒绝行为）

| 操作 | 锁类型 | 被占用时的拒绝行为 |
| --- | --- | --- |
| create | library-root 锁 | 重试至 10s；同名放置得到 `alreadyExists` |
| import | library-root 锁（+ 目标名检查） | 同上；已存在名 `alreadyExists` |
| rename | bundle 锁（源）+ library-root 锁（目标名检查+移动） | 源忙 `busy`；目标名已存在 `alreadyExists` |
| config | bundle 锁 | `busy`（运行中的 VM 拒绝改配置，不排队） |
| delete | bundle 锁 | `busy` |
| clone | bundle 锁（源） | `busy`（运行中拷贝 Disk.img 不一致，无 opt-out） |
| export | bundle 锁 | `busy`（同 clone 原因） |
| stage-vphoned | bundle 锁 | `busy` |
| cfw-record | bundle 锁 | `busy`，仅跳过记账并打印 warning，不中止 |
| cleanup-firmware | bundle 锁（`removeBuiltFirmwareIfIdle` 自取） | 跳过可选清理，打印 warning |
| fw prepare / fw patch | bundle 锁 | `busy` |
| restore-decrypt | bundle 锁 | `busy` |
| restore（设备操作） | 不取锁，`requireDFUOwner` 校验持有者 | 非 DFU 会话 `dfuSessionRequired` |

### 相关不变量（回归测试覆盖）

新增测试文件 `tests/VPhoneCoreTests/VMOperationTests.swift`、`BundleGuardTests.swift`、
`LibraryLockTests.swift`，覆盖：

- `VPhoneVMOperation.all` 无重复；`vmLifetime == {boot, dfu}`；dfu 记录同时满足
  isBoot/isDFU，boot 仅 isBoot，config 二者皆否。
- 同目录嵌套 `withBundleLock` 抛 `busy`（flock 按 open file description 计）；单次
  获取正常运行 body 并返回值。
- 排他操作被拒绝时不部分修改 bundle：以 delete 被拒后 bundle 文件字节不变验证。
- 锁按解析后的 inode 定键，与路径写法无关：经符号链接父目录或含 `/./` 的
  非规范化路径访问同一目录，仍视为已持有（验证
  `resolvingSymlinksInPath` + `standardizedFileURL` 规范化）。
- create 在 `afterNameCheck` 窗口内 library 锁为 held；同名二次 create 得
  `alreadyExists`，不同名 create 成功；空闲探测为 false。
- `requireDFUOwner` 七条拒绝路径与完整成功路径（返回记录），全部用注入的替身
  （`lockHeld`/`readRecord`/`identity`/`bootPIDs`），不起真实进程。

### --force 与锁的关系

现状：离线锁定命令上没有任何 `--force`/`-f` 能绕过锁。

- `vm delete --force`（`VPhoneVMDeleteCommand`）的 `--force` 只跳过确认提示
  （help 文案 “Do not prompt”），随后仍无条件调用 `VPhoneBundleOps.delete`，后者
  照常取 `withBundleLock`。因此锁被持有时 `--force` 仍拒绝。
- 其余 `force*` 命名（`--force-exc-guard`、`--force-dsc-maxslide`、`vm stop --force`、
  setup 的 `--force`）与 bundle 锁无关。
- 结论：无需为“绕过锁”新增测试；delete 被锁拒绝这一路径由
  `refusedDeleteLeavesBundleBytesUnchanged` 覆盖，即 `--force` 到达的同一代码路径。

---

## 第二部分：Shell/Makefile 侧

### vm_lock.py 如何把 shell 入口桥接到 Swift 的 flock

`scripts/vm_lock.py` 与 Swift 的 `VPhoneVMLock` 使用同一把锁：对**目录 inode** 执行
`flock(LOCK_EX | LOCK_NB)`（`open(dir, O_RDONLY|O_DIRECTORY|O_CLOEXEC)` 后加锁）。
两侧因此互斥：同一 bundle 目录上，一个 shell 操作与一个 Swift 操作不能同时持锁。

CLI 形式（唯一的 exec 包裹式）：

```
vm_lock.py VM_DIR OPERATION -- COMMAND [ARGS...]
```

行为：

- 解析并 `resolve(strict=True)` 目标目录（**目录必须已存在**），加独占非阻塞锁；
- 写诊断记录 `.vphone-runtime.json`（字段 `operation`、`pid`、
  `bundleIdentifier=dev:ino`、`bundlePath`、`instanceID`、`startedAt`）。记录仅供
  诊断，陈旧记录不阻止加锁；
- `os.set_inheritable(fd, True)` 后 `execvpe` 运行 `COMMAND`，并在子进程环境注入
  `VPHONE_VM_LOCK_FD=<fd>`。锁随该 fd 存活：`COMMAND` 及其未设置 CLOEXEC 的后代
  退出后才释放；
- 另有 `--check-inherited VM_DIR`：校验继承的 fd 是否指向同一目录 inode
  （`cfw_install_host.sh` 在 sudo 重执行后用它避免二次开 fd 造成的自死锁）。

参考惯用法：`scripts/cfw_install_host.sh:60-63`——
`exec "$PY" vm_lock.py "$VM_DIR" cfw -- /bin/zsh "$0" ...`，用 `--check-inherited` + 一个
`VPHONE_CFW_LOCK_REEXEC` 哨兵防止无限重执行。

差异（与 Swift）：Swift `create`/`import` 用 `VPhoneLibraryLock`（锁库根、不写记录、
带超时重试），因为下单时 bundle 目录尚不存在；`vm_lock.py` 只提供目录 flock +
非阻塞，语义等价于 `VPhoneVMLock`（bundle 锁）。flock 按每个打开文件描述符计一把，
同一目录二次开 fd 加锁会失败/死锁，故一个已在 `vm_lock.py` 内运行的进程不得再
自包裹（用 `VPHONE_VM_LOCK_FD` 判定）。

### setup_machine.sh：force-kill 预检 → 优雅 `vm stop`

**改动前**：变量 `AUTO_KILL_VM_LOCKS` 与函数 `collect_vm_lock_pids`/
`check_vm_storage_locks`（`lsof` 扫描 `nvram.bin/machineIdentifier.bin/Disk.img/
SEPStorage` 占用者后 `kill`，最终 `kill -9`）、`kill_stale_vphone_procs`
（`pgrep -f <release 二进制>` 后 `kill`）、`force_release_vm_locks`（DFU 停止后 lsof
占用者再 kill）。

**改动后**：

- 删除上述变量与四个函数。
- 新增 `vm_stop_target()`：调用
  `"$VPHONE_BIN" vm stop --library-root "${VM_DIR_ABS:h}" "${VM_DIR_ABS:t}"`。
  `VPHONE_BIN` 默认 `${PROJECT_ROOT}/.build/release/vphone-cli`（`make build` 产物）。
  `vm stop` 按 bundle 身份定位 boot 进程（非按磁盘 fd），请求 guest 关机、等待、
  超时后经框架强停并确认终止（提交 35404b5/e2f89a0/0b52b5f）。目标未运行时返回
  “not running” 且退出码 0，故可无条件调用。**任何非零退出即 `die` 退出，无
  force-kill 回退**。
- 调用点替换：`start_first_boot`、`run_boot_analysis`、CFW 安装前（原
  `check_vm_storage_locks`）→ `vm_stop_target`；`start_boot_dfu`（原
  `kill_stale_vphone_procs` + `check_vm_storage_locks`）→ 单个 `vm_stop_target`；
  `stop_boot_dfu`（原 `force_release_vm_locks`）→ 先 `vm_stop_target` 优雅停 DFU
  虚机，再 `stop_process_tree "$DFU_PID"` 回收本脚本拉起的 `make boot_dfu` 包装进程。
- 保留 `list_descendants`/`kill_descendants`/`stop_process_tree`：它们只管理本脚本
  自身的后台子进程（`BOOT_PID`/`DFU_PID`，即 `make boot`/`make boot_dfu`），用于
  `cleanup` 陷阱、panic/超时分支和 DFU 回收，不是“按 lsof 杀外部占用者”的路径。

**为什么优雅停替换强杀**：`vm stop` 向 boot 进程发 SIGINT，触发 guest 关机后再经
框架强停并确认；`lsof`→`kill -9` 是对持有磁盘 fd 的任意进程直接强杀，可能在
teardown 中途落刀。按已裁决决策，优雅停为唯一路径。

### Makefile 目标：Swift 内锁 vs shell 自包裹 vs 与 DFU 协作

包裹方式以**脚本内自包裹**为主（与 `cfw_install_host.sh` 一致），故这些目标的
Makefile recipe 不改；`fw_prepare` 是唯一例外，见表下说明。

| Makefile 目标 | 调用 | 加锁方式 | operation 串 |
| --- | --- | --- | --- |
| `fw_patch` / `_dev` / `_jb` / `_exp` / `_less` | Swift `patch-firmware` | Swift 进程内已锁 | `fw-patch` |
| `fw_prepare` | shell `fw_prepare.sh` | **recipe 层经 `vm_lock.py` 加锁**（见下） | `fw-prepare` |
| `restore` / `restore_get_shsh` / `restore_offline` | Python pmd3 桥（DFU 会话内） | **不加锁**（与 DFU 持有者协作，取独占锁会死锁/拒绝） | —（DFU 持有者为 `dfu`） |
| `cfw_install` / `_dev` / `_jb` / `_exp` / `_host` | `cfw_install_host.sh` | 脚本内已自包裹（既有） | `cfw` |
| `boot` / `boot_less` / `boot_dfu` | Swift `--config` 引导 | Swift 整个虚机生命周期持锁 | `boot` / `dfu` |
| `vm_new` | `vm_create.sh` | 新增自包裹（仅当目录已存在时加锁） | `create` |
| `vm_backup` | `vm_backup.sh` | 新增自包裹 | `backup` |
| `vm_restore` | `vm_restore.sh` | 新增自包裹（仅当目标目录已存在时加锁） | `restore-backup` |
| `vm_switch` | `vm_switch.sh` | 新增自包裹（仅当活动目录已存在时加锁） | `switch` |
| `vm_package` | `vm_package.sh` | 新增自包裹；保留其 lsof 活机检查作次级门 | `package` |
| `vm_list` | 纯读 `vm.backups` | 只读，不加锁 | — |
| clone/export/import/rename/delete | 仅 Swift 子命令，无 Makefile 目标 | Swift 进程内已锁 | — |

所有 operation 串均取自 `VPhoneVMOperation`，逐字匹配。

**fw_prepare 的处理（recipe 层加锁，而非自包裹或改走 Swift）**：`make fw_prepare` 直接
`cd VM_DIR && bash fw_prepare.sh`，原本不取任何锁。三种可选方案的取舍：

1. **自包裹 `fw_prepare.sh` 本身**——不可行。Swift `fw prepare` 子命令已先取
   bundle 锁，再 `spawn` 同一个 `fw_prepare.sh`；若脚本自包裹会二次开 fd 加锁，与
   Swift 持有的锁冲突而死锁。Swift 不参与 `vm_lock.py` 的 `VPHONE_VM_LOCK_FD`
   继承协议，故 `--check-inherited` 也救不了这种情形。
2. **改走 Swift `fw prepare` 子命令**——会改变行为。Swift `fw prepare` 把
   `VPHONE_PYTHON`、`IPSW_DIR`、`VPHONE_SEAL_DIR` 重定向到用户可写缓存目录（处理
   只读 bundle），而 Makefile 目标仅靠导出的 PATH 运行脚本。改走 Swift 会改变
   IPSW 下载与缓存位置，超出“仅加锁”的范围。
3. **recipe 层用 `vm_lock.py` 包裹**（采用）——只在 `make fw_prepare` 这一直接入口
   加 `fw-prepare` 锁，执行环境（cwd、PATH、python、缓存位置）完全不变；Swift
   `fw prepare` 路径不经过 Makefile，不受影响，无双重加锁。`vm_lock.py` 用
   `LOCK_NB`，故运行中的虚机会使 `make fw_prepare` 立即失败并拒绝。

recipe 形如：

```makefile
fw_prepare:
	"$(PYTHON)" "$(CURDIR)/$(SCRIPTS)/vm_lock.py" "$(VM_DIR_ABS)" fw-prepare -- \
		/bin/bash -c 'cd "$(VM_DIR_ABS)" && exec bash "$(CURDIR)/$(SCRIPTS)/fw_prepare.sh"'
```

`restore*` 走 Python 桥而非 Swift `restore` 子命令；因 restore 必须在 DFU 会话内、
与 DFU 持有者协作，不取独占锁是**正确**的（取锁会死锁），故不包裹。

### 自包裹实现要点（vm_backup/restore/switch/package/create）

- 脚本顶部在参数解析**之前**用 `typeset -a _VPHONE_ORIG_ARGS; _VPHONE_ORIG_ARGS=("$@")`
  捕获原始 argv，供重执行原样回放（`make` 走 env 传参，直接 CLI 走 argv，两者都保住）。
- 在参数解析完成、破坏性动作之前插入自包裹块：

  ```zsh
  if [[ -z "${VPHONE_VM_LOCK_FD:-}" && -d "${VM_DIR:A}" ]]; then
      exec "${VPHONE_PYTHON:-python3}" "${0:a:h}/vm_lock.py" "${VM_DIR:A}" <op> -- \
          /bin/zsh "$0" "${_VPHONE_ORIG_ARGS[@]}"
  fi
  ```

- **只在目录已存在时加锁**：不存在的目录无运行中虚机可冲突，且 create/restore
  本就会创建它；源缺失时由脚本自身的校验给出清晰报错（而非锁错误）。
- 删除 `vm_backup.sh`/`vm_restore.sh`/`vm_switch.sh` 中基于
  `pgrep -f "vphone-cli.*--config.*VM_DIR"` 的运行中检查——锁已提供该拒绝，且更
  可靠（flock 不依赖进程命令行匹配）。
- `vm_package.sh` 原用 lsof 检查活机（非 pgrep），予以保留作次级门。
- `python3` 经 Makefile 的 PATH（venv 优先）解析；`vm_lock.py` 仅用标准库，任意
  python3 皆可。可用 `VPHONE_PYTHON` 覆盖。

### 已知限制

- `vm_switch.sh` 末尾 `replace_dir_with_tmp` 会把 `VM_DIR` 换成新 inode，flock 覆盖
  的是破坏性拷贝阶段而非最后的原子 rename 尾巴；对“排除并发 boot”已足够。
- `vm_create` 的 shell 锁取 **bundle 目录锁**，而 Swift 全流程 `vm create` 取
  **库根锁**；二者不互斥。本低层目录创建器要防的是“在活动 bundle 上重建”，bundle
  锁即可覆盖该关键情形。
- 自包裹取锁后写入的 `.vphone-runtime.json` 会被 `vm_backup`/`vm_package` 一并拷入
  产物；诊断性质，陈旧记录不阻塞，影响可忽略。
- `vm stop` 对 **DFU 模式** 的“guest 关机请求”可能不适用；但其超时后“经框架强停 +
  确认终止”的兜底覆盖该情形。此点未在真机验证。
- `make vm_new` 之前 setup_machine 不再有 kill 预检；若存在陈旧运行中的虚机，
  `vm_new` 会经自包裹锁**拒绝**（fail-closed），而非旧的强杀后继续。这是行为收紧。

---

## 验证

Swift 侧：

- `swift build` → Build complete。
- `swift test` → 253 tests，43 suites。B4 相关 suite（VMOperationTests、LibraryLockTests、
  BundleGuardTests、RestoreInfoTests、BundleOpsTests、VMLockTests、VMStopTests）全部通过。
  13 项失败为既有且与 B4 无关：FirmwarePatcher 的固件二进制对比测试依赖
  `ipsws/patch_refactor_input/` fixture，本 checkout 无此目录（该目录不存在，仅
  `tests/FirmwareIntegrationTests/Fixtures.swift` 引用，且 B4 diff 未触及
  FirmwarePatcher 源码）。
- `make build`（签名 release）→ Build complete，signed OK，bundled 到
  `.build/vphone-cli.app`（ad-hoc codesign，无需 sudo）。

Shell 侧：

- `zsh -n`：`setup_machine.sh`、`vm_backup.sh`、`vm_restore.sh`、`vm_switch.sh`、
  `vm_package.sh`、`vm_create.sh` 全部通过。`make -n fw_prepare` 展开正确。
- `shellcheck`：本机不可用（脚本为 zsh，支持有限）。
- 未执行真实脚本（涉及真机/固件操作）。

集成验证（合并 Swift 与 Shell 两侧后，主会话执行）：

- `make build`（签名 release）→ Build complete，signed OK，bundled →
  `.build/vphone-cli.app`。release 二进制此前停留在 B3，本次已更新为 B4。
- `make test`（`run_tests.py fast`）→ Test run with 240 tests in 32 suites passed。
  含 VMLockTests、RestoreInfoTests、LibraryLockTests、BundleOpsTests、VMStopTests、
  CreateOrchestratorTests，全部通过。fast 子集不含依赖缺失 fixture 的固件集成测试。
- `make -n fw_prepare` 展开为经 `vm_lock.py` 加 `fw-prepare` 锁的调用，语法正确。
