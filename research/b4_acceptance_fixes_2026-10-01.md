# B4 创建验收问题修复：所有权交还、取消传递、残留清理

日期：2026-10-01。起点 `a653938`。对应提交：`83dcb5d`（问题 1）、`876b477`（问题 2）、本记录所在提交（问题 3，`fix: clean create runtime record and control socket on completion`）。

范围与边界：未运行真实 `vm create`，未启动 VM，未使用 sudo，未发送合成键鼠事件；未读写 `~/.vphone/VMs` 与 `~/vphone-b4-accept`；未对 `vm-2607`、`vm-new` 执行命令或发信号。只读读取了 `~/Library/Logs/vphone-cli-launchpad/lp-b4-accept-1e6f774d-create.log`（无时间戳，只用于确认阶段输出）。测试只用临时目录。日志位于 `research/artifacts/b4-acceptance-fixes-2026-10-01/`（Git 忽略）。环境：worktree 的 `.venv` 为指向主仓库 `.venv` 的符号链接；递归初始化 `vendor/*` 子模块；按 Makefile 格式生成被忽略的 `sources/vphone-cli/VPhoneBuildInfo.swift`。

## 1. 输入事实

验收（任务说明，2026-10-01，Launchpad → `vm create lp-b4-accept --library-root ~/vphone-b4-accept --variant regular ... --root-popup`，一次成功）：

- 问题 1：创建结束后 `.cfw-history/`（drwxr-xr-x root）、其事务目录（drwx------ root）、`.vphoned.signed`（root）为 root 所有；`cfw_install_host.sh` 输出 `ownership of host-side artifacts NOT restored`。
- 问题 2：prepare 期间 `vm create`（pid 46201，pgid 46201，会话首进程）的进程组只含 `vphone-cli`；`fw_prepare.sh` 等子进程不在该组。Launchpad 的取消是 `killpg(pid, SIGINT)`。
- 问题 3：成功结束后 bundle 中保留 `.vphone-runtime.json`（`operation: create-checkpoint`，pid 46201，进程已退出）和 `vphone.sock`。

协调方补充的真实环境证据（2026-10-01 19:16，修复前构建 `a653938`，Launchpad → `vm create lp-b4-accept2 --library-root ~/vphone-b4-accept ... --root-popup`）：

- 运行中：`vm create` pid 94197（pgid 94197，ppid 43085 为 Launchpad）；`fw_prepare.sh` pid 94210，pgid 94210（ppid 94197）；`unzip` pid 94219，pgid 94210（ppid 94210），命令为 `unzip -oq ~/.vphone/ipsws/iPhone17,3_26.1_23B85_Restore.ipsw -d ~/.vphone/ipsws/iPhone17,3_26.1_23B85_Restore`（共享解包缓存目录）。
- Stop Creating 之后：`vm create` 退出；`fw_prepare.sh` 与 `unzip` 继续运行，ppid 变为 1；检查点 prepare 仍为 `running`，`updated_at` 为 2026-10-01T11:16:41Z。
- 约 30 秒后两个进程自行结束，并在 bundle 中留下 `iPhone17,3_26.1_23B85_Restore/`（mtime 19:17，晚于 `vm create` 退出），检查点无对应记录。
- 风险（协调方指出）：孤儿进程写的是共享解包缓存；T12 记录 script prepare 按名称复用该缓存且不校验内容，中途被结束的解包会留下不完整缓存。

## 2. 问题 1：`--root-popup` 下所有权未交还

### 2.1 原因（事实）

- `--root-popup` 的提权实现为 `VPhoneProcessRunner.runWithAdminPrivileges`（`a653938` `sources/VPhoneCore/VPhoneProcessRunner.swift:337-354`）：`osascript -e 'do shell script "<命令>" with administrator privileges'`。`do shell script` 的 shell 不继承调用者环境，只收到命令行中内联的 `KEY='value'`（同文件 `:334-336` 注释）。
- 调用方只内联了 `SUDO_USER=NSUserName()`：`vm create` 为 `a653938` `sources/vphone-cli/VPhoneCreateOrchestrator.swift:921-922`，`cfw install` 为 `sources/vphone-cli/VPhoneRestoreCLI.swift:163-164`。没有传 uid/gid。
- 驱动 `a653938` `scripts/cfw_install_host.sh:296-308`：`SUDO_USER` 非空时才交还，并要求 `SUDO_UID` 为数字；`SUDO_UID` 只由 sudo 设置。root-popup 路径下驱动已是 root（`:43` 的 `EUID -ne 0` 为假），不经过 sudo，因此 `SUDO_UID` 缺失，输出 `NOT restored: SUDO_UID is missing or not numeric`。
- sudo 路径（`exec sudo -E`，`:44`）由 sudo 设置 `SUDO_UID`/`SUDO_GID`；驱动只交还 uid（`chown -h "$SUDO_UID"`），不交还 gid。
- 失败与中断路径：`txn_abort`（`a653938` `:120-129`）只在 `SUDO_UID` 有效时交还 `.cfw-history`；`.vphoned.signed`、`.cfw_temp`、`cfw_input` 只在成功路径交还。
- 复现：新测试 `test_root_popup_path_returns_artifacts_without_sudo_variables` 在修改前驱动上记录到的 chown 调用为空（`p1-pre-change.log`、`p1-pre-change-popup.log`）。

### 2.2 修复

CLI（`83dcb5d`）：

- `VPhoneInvoker.environment()`（`sources/VPhoneCore/VPhoneProcessRunner.swift:408`）：本进程非 root 时取 `getuid()`/`getgid()`；本进程是 root 且 `SUDO_UID` 为非 0 数字时取 `SUDO_UID`/`SUDO_GID`；否则为 0。
- `VPhoneCreateOrchestrator.cfwInvocation`（`VPhoneCreateOrchestrator.swift:953`）：两条提权路径都带 `VPHONE_INVOKER_UID`/`VPHONE_INVOKER_GID`。root-popup 路径把它们与脚本变量一起内联（仍内联 `SUDO_USER`，供 `scripts/fetch_debs.sh` 使用）；sudo 路径把它们加入继承环境，由 `sudo -E` 保留。`--sudo-password`（askpass）优先于 `--root-popup` 的规则不变。`vm create` 与 `cfw install` 共用该函数。
- `VPhoneProcessRunner.adminPrivilegesCommand`/`adminPrivilegesScript`：从 `runWithAdminPrivileges` 拆出命令拼接，便于测试；行为不变。

驱动 `scripts/cfw_install_host.sh`：

- 调用者来源（`:54-89`）：`VPHONE_INVOKER_UID`（及 `VPHONE_INVOKER_GID`）优先；未设置时用 `SUDO_UID`（及 `SUDO_GID`）。值只与 bundle 目录所有者（`stat -f %u "$VM_DIR"`）比较，不从 bundle 内容推断。
- 拒绝与告警的选择：

| 情况 | 处理 | 理由 |
| --- | --- | --- |
| uid 或 gid 不是十进制数（非数字、负数、前导 0、超过 10 位） | 在取锁、暂存和挂载之前以退出码 2 拒绝，输出 `refusing before any change`；不创建 `.cfw_disk.*`、`.cfw_mount.*`、`.cfw-history` | 格式错误表示调用方错误；拒绝时 bundle 未改变 |
| 两个来源都未设置 | 安装照常；结束时告警 `NOT restored: invoker uid unknown ...`，不改所有者 | 与 T24 的“缺少 `SUDO_UID` 时不改所有权并报告”一致 |
| uid 为 0 | 安装照常；告警 `NOT restored: the invoker is root` | root 调用时产物本应为 root 所有 |
| uid 不等于 bundle 目录所有者 | 安装照常；告警 `... does not own <VM_DIR> (owner uid N)`，不改所有者 | 不把另一账户 bundle 中的产物交给调用者 |

- `hand_back_artifacts`（`:161`）：成功路径（`:359`）与失败、中断路径（`finish` 陷阱 `:300`）都调用。对象为 `.vphoned.signed`、`.cfw_temp`、`cfw_input`、`cfw_jb_input`、`.cfw-history`（含事务目录及其中的 `transaction.json`、保留的旧 `Disk.img`）和 `$PROJ/scripts/vphoned/vphoned`（原为按用户名 `chown`，现走同一遍历）。遍历规则不变：`find -x`（单设备）、`chown -h`（不跟随链接）、只改目录和单链接普通文件、只改 root 或调用者所有的条目、不进入第三方账户目录、不改 mode。所有者改为 `uid:gid`（有 gid 时）。VM 目录下存在挂载时整体跳过并告警（原有规则）。`txn_abort` 不再自行交还。
- 事务目录权限：保留 0700。理由：交还后所有者为调用者，0700 允许所有者读取 `transaction.json`；删除该目录取决于父目录 `.cfw-history` 的写权限，`.cfw-history` 同样交还给调用者；目录中保留安装前的完整磁盘，0700 不向其他账户开放；T15/T24 规定只改所有者、不改 mode。

### 2.3 测试

- `tests/test_cfw_host_isolation.py`（替身提权）：沿用 fixture，驱动副本把 `EUID -ne 0` 判断替换为假，`chown` 为记录调用的替身。sudo 路径以 `SUDO_USER`/`SUDO_UID`/`SUDO_GID` 运行；root-popup 路径以只含内联变量的环境运行（`bare_env`：无 `SUDO_UID`/`SUDO_GID`，`PATH=/usr/bin:/bin:/usr/sbin:/sbin`，与 `do shell script` 相同）。安装替身另写 `.vphoned.signed` 并记录看到的 `SUDO_UID`/`SUDO_USER`。新增或改写 9 项：两条路径成功交还（交还对象逐项相等，包括 `.vphoned.signed`、事务目录、`transaction.json`、旧盘）；显式来源优先于 `SUDO_UID`；两条路径失败（安装退出 37）交还；SIGINT 中断（退出 130）交还；5 种格式错误在任何改动前拒绝；uid 为 0；uid 与 bundle 所有者不一致（两条路径）；来源缺失。
- `tests/VPhoneCLITests/CFWInvocationTests.swift`（4 项）：popup 环境只含内联变量且含 uid/gid、不含 `SUDO_UID`；AppleScript 字面量转义；`inlineInvokerReachesABareShell` 把 popup 的 `/bin/sh` 命令行放在 `env -i` 下执行（`do shell script` 的替身），子进程读到本进程 uid/gid，`SUDO_UID`/`SUDO_GID` 未设置；sudo 路径与 askpass 优先；`VPhoneInvoker` 的 root/sudo 取值。
- 覆盖缺口：修改前“第三方账户条目不被交还”由“`SUDO_UID` 与 bundle 所有者不一致”间接覆盖；现在该情形在遍历前跳过。遍历中的第三方条目需要 root 才能构造，未再单独覆盖；遍历规则本身未改。

## 3. 问题 2：取消信号到不了 `vm create` 的子进程

### 3.1 原因（事实）

- Foundation `Process` 以新进程组启动子进程：探针（scratchpad `probe2.swift`）输出 `parent pgid 59875; child pid 59885 pgid 59885`；测试 `ChildCancellationTests.foundationProcessStartsANewProcessGroup` 断言 `getpgid(child) == child pid` 且不等于 `getpgrp()`。仓库已有同一说明（`a653938` `VPhoneProcessRunner.swift:276`）。本地代码没有调用 `setpgid`/`setsid`；新进程组由 Foundation 设置。
- `vm create` 的全部阶段子进程都经 Foundation `Process` 启动：`VPhoneProcessRunner.runStreaming`（fw prepare `a653938` `VPhoneCreateOrchestrator.swift:652`，restore-get-shsh `:786`，restore-update `:794`，less 启动 `:1062`，CFW askpass `:936`，root-popup 的 osascript），`runForeground`（CFW 终端 sudo），`runCapturing`（recovery-probe、ps、hdiutil），`VPhoneManagedProcess.start`（DFU、首启、验证启动），`VPhoneNativeRestoreProcess.supervise`（native restore worker）。
- `a653938` 的 `vm create` 没有 SIGINT/SIGTERM 处理；收到信号按默认处置终止，子进程所在进程组不受影响。
- 父进程把 SIGINT 设为 `SIG_IGN` 时，Foundation 子进程仍按默认处置响应 SIGINT（探针 `probe2.swift` 第二行）。因此 `vm create` 可以忽略并转发信号，不影响子进程。
- 修改前实测（`tests/VPhoneCLITests/CreateCancellationEndToEndTests.swift` 对 `a653938` 后的 CLI，`p2-e2e-pre-change.log`）：对 `vm create` 所在进程组发 SIGINT 后，`vm create` 被信号终止（terminationReason 2，status 2）；替身 `fw_prepare.sh`、其前台写入子进程、自建进程组的孙进程全部存活并继续写 bundle；bundle 锁仍被持有（`vm_lock.py` exec 成的 bash 持有）。共 10 处断言失败。
- 与 B4 记录的关系：`research/t26_b4_launchpad_2026-10-01.md` 第 8 节推断“真实子进程留在 `vm create` 的进程组内”，与上述事实不符；B4 第 2 节“`VPhoneCreate*.swift` 无 SIGINT 处理”属实。

### 3.2 修复（`876b477`）

`VPhoneChildCancellation`（新文件 `sources/VPhoneCore/VPhoneChildCancellation.swift`）：

- `vm create`/`--resume` 安装 SIGINT、SIGTERM 处理（`VPhoneVMCreateCLI.swift:60`；`SIG_IGN` 加 DispatchSource），并以 TaskLocal `current` 绑定控制器。`VPhoneProcessRunner`（`track`，`VPhoneProcessRunner.swift:40`）、`VPhoneManagedProcess`、native restore supervise 启动子进程后向 `current` 登记 pid；未绑定时不登记（其他命令行为不变）。
- 首个信号（`request(signal:)`，`:219`）：向每个运行中的登记子进程、其全部后代（`KERN_PROC_ALL` 进程表按 ppid 展开，`table()` `:393`）及这些进程各自的进程组发送同一信号；后代用 setpgid/setsid 离开子进程组时也会收到。登记在信号之后的子进程立即收到信号。
- 升级：工具类子进程 10 秒、VM 进程 20 秒（`VPhoneShutdownPolicy.defaultStopTimeout`，与 `vm stop` 相同）后，对仍运行的已发信号进程（按 pid 与启动时间识别，包括已被收养到 launchd 的孤儿）及其进程组发送 SIGKILL。第二个信号立即 SIGKILL。
- 主路径：执行器因子进程结束而抛错后，runner 发现已取消，不写 `failed`；`interrupt`（`VPhoneCreateRunner.swift:561`）先 `settle()`（等待所有已发信号进程结束，超过升级期限加 10 秒仍有进程则报告），再在该阶段的 `error` 写入 `interrupted by SIGINT at <时间>; every stage process ended before vm create exited`，状态保持 `running`，总状态为 `interrupted`；然后抛 `VPhoneCreateRunError.interrupted`。信号在两个阶段之间到达时，下一个阶段写入 `running` 后立即按同样方式停止，执行器不运行。运行锁与 bundle 锁在 runner 返回时释放。
- CLI：退出码 128 + 信号（SIGINT 为 130）；stderr 为 `Error: interrupted by SIGINT during stage ...`；stdout 提示 `[-] vm create stopped by SIGINT during <stage>; its processes have exited ...`，随后是 `Inspect`/`Resume`。
- 主路径 90 秒内未返回时（例如进程内的 patch 或 native prepare 仍在运行），控制器 SIGKILL 已知进程，等待进行中的检查点写入结束（`withExitDeferred`，最多 35 秒），然后以 128 + 信号退出；检查点中该阶段仍为 `running`。
- 可取消的等待：`waitForRecovery` 循环、`readDeviceIdentity` 循环、CFW 前的 5 秒等待。VM 子进程停止时，若已取消则不再发送第二个 SIGINT（第二个 SIGINT 会使启动进程跳过关机等待）。
- `scripts/check_tar_pipe_memory.py` 单独编译 `VPhoneProcessRunner.swift`，现另编译它依赖的 `VPhoneChildCancellation.swift`、`VPhoneProcessIdentity.swift`、`VPhoneShutdownPolicy.swift`。

各阶段子进程的处理：

| 阶段 | 子进程 | 取消时 |
| --- | --- | --- |
| prepare（script） | `python vm_lock.py ... -- bash fw_prepare.sh`（exec 后为 bash）及其 unzip、curl/aria2c、ipsw | 信号送到 bash 的进程组与全部后代；10 秒后 SIGKILL |
| prepare（native）、patch | 无子进程，进程内执行 | 返回后下一阶段写入 `running` 即停止；90 秒内未返回则强制退出。patch 被强制退出时可能留下 `.firmware-transaction`，续跑按 C4 提示 `fw patch --recover` |
| restore（python） | DFU `vphone-cli --dfu`（VM 类）、recovery-probe、`pymobiledevice3_bridge.py restore-get-shsh/restore-update` | DFU 按其 SIGINT 关机流程停止，20 秒后 SIGKILL；python 收 SIGINT 后退出，10 秒后 SIGKILL。设备状态由续跑的 restore 探测判定 |
| restore（native） | DFU 与 `native-restore-worker` | worker 的 supervise 自身也处理 SIGINT（2 秒后 SIGKILL）；控制器同样转发 |
| cfw | `osascript`（root-popup）或 `sudo`（askpass、终端）及 root 的 `cfw_install_host.sh` | 见 3.3：不转发、不升级、不提前退出，等待其结束 |
| first_boot、verification、less 启动 | VM 进程 | 同 DFU |

### 3.3 CFW 阶段的选择

- 现有停止机制（事实）：驱动以 root 运行，自身对 INT/TERM/HUP 设有陷阱（`trap 'exit 130' INT` 等），退出时 `finish` 清理挂载并由 `txn_abort` 归档事务，原盘不被写入（T15）。能触发这些陷阱的信号来源是 root 进程或终端前台进程组（终端 sudo 路径下 `runForeground` 把终端交给 sudo 的进程组）。
- 事实（D4 场景 2）：主进程被 SIGKILL 后，root 的 `cfw_install_host.sh` 继续运行约 51 秒并持有 bundle 锁。
- 推断（未实测）：用户身份的 `vm create` 向 root 进程发信号返回 EPERM；结束其用户身份父进程（osascript 或 sudo）不会结束 root 驱动，驱动会脱离跟踪继续写 bundle。
- 选择：CFW 阶段收到取消时不转发信号、不发送 SIGKILL、不提前退出；输出 `... runs as root and cannot be stopped from this process; vm create waits for it to finish, then stops. (Cancel the authentication dialog if it is still shown.)`；CFW 子进程结束后，CFW 成功则记为 `succeeded`，下一阶段写入 `running` 后停止；CFW 以非 0 结束则 cfw 阶段保持 `running`（总状态 `interrupted`）。理由：本进程无法停止 root 子进程，而结束其父进程会重现 D4 场景 2 的无跟踪 root 进程。
- 限制：取消等待时间等于 CFW 剩余时间；认证对话框未作答时一直等待（用户可在对话框中取消，osascript 以非 0 退出，推断，未实测）。该阶段内 90 秒强制退出不生效。

### 3.4 共享解包缓存与本地复制（协调方补充）

- 原因（事实）：`a653938` `scripts/fw_prepare.sh:398-415` 的 `extract` 以“缓存目录存在且非空”判定可复用，`unzip` 直接写入最终名称；中断后不完整的缓存会被下次运行复用。本地来源的 `fetch`（`:385-388`）用 `cp "$src" "$out"` 直接写最终名称，中断后下次运行输出 `Skipping: already exists` 并使用不完整文件。
- 修复（`876b477`）：复制与解包先写 `.<名称>.partial.<pid>`，完成后 rename 发布；解包缓存在发布前写入完成标记 `.vphone-extract-complete`，没有标记的已有缓存目录被丢弃并重新解包；进程已不存在的 partial 在下次运行时删除；另一运行先发布了完整缓存时（rename 失败且目标有标记）使用该缓存并删除自己的 partial。标记不复制到 bundle 的 restore 树。下载（curl/aria2c 续传）路径未改。
- 影响：修改前留下的无标记缓存（包括完整的）会重新解包一次。

### 3.5 测试

- `tests/VPhoneCLITests/CreateCancellationEndToEndTests.swift`（1 项，真实 CLI）：`.build/debug/vphone-cli vm create` 在临时库根与 `--project-root` 下运行，`fw_prepare.sh` 为替身（前台 python 写入子进程；后台 python 孙进程 `setpgid(0,0)` 自建进程组、恢复 SIGINT 默认处理，持续写 bundle）。测试对 `vm create` 的进程组执行 `killpg(pid, SIGINT)`（Launchpad 的方式），断言：`vm create` 以 130 退出；3 个替身进程与其进程组全部结束；bundle 不再被写入；`create-status` 为 `interrupted`、`create_run_in_progress=false`、`bundle_lock_held=false`；prepare 为 `running` 且 `error` 含 `interrupted by SIGINT`；运行记录已删除（问题 3）。宿主为 VM（`kern.hv_vmm_present=1`）或无 python3 时跳过。修改前 10 处失败，修改后通过。
- `tests/VPhoneCoreTests/ChildCancellationTests.swift`（11 项，2 个 suite）：进程组事实；子进程树（忽略 SIGINT 的后台子 shell、`setpgrp` 自建组且忽略 SIGINT 的 perl 孙进程）经升级 SIGKILL 全部结束；信号后启动的子进程立即停止；第二个信号不等待宽限；CFW 延迟区内子进程收不到信号、延迟结束后才强制退出；强制退出等待进行中的写入；`complete()` 后不再退出；进程表；runner 层：阶段中取消（阶段 `running`、`error` 记录、子进程全部结束、运行锁与 bundle 锁释放、续跑把该记录移入历史并完成）、阶段之间取消（执行器不运行）、CFW 延迟（cfw `succeeded`，first_boot `running`）。
- `tests/test_fw_prepare_partials.py`（5 项）：从脚本中取出函数，用替身 `unzip`/`cp`：中断的解包不出现在缓存名下且下次重做；无标记缓存被丢弃；有标记缓存被复用；并发发布保留先发布者；中断的本地复制不出现在 IPSW 名下。对修改前脚本（`FW_PREPARE_SCRIPT=fw_prepare.pre-change.sh`）4 项失败。

## 4. 问题 3：创建结束后的残留

### 4.1 运行记录 `.vphone-runtime.json`

- 来源（事实）：`VPhoneCreateCheckpointStore.commit` 每次写检查点都取 bundle 锁（操作 `create-checkpoint`）；`VPhoneVMLock.init` 写运行记录，`deinit` 只解锁不删除（D4 缺陷 2 的决定）。创建的最后一次写入（verification 成功或 restore 树清理后的写入）留下 `create-checkpoint` 与 `vm create` 的 pid，与验收事实一致。修改前 D4 测试 `checkpointWritesReleaseTheBundleLockAndLeaveOnlyADiagnosticRecord` 断言的正是这一残留。
- 修复：`VPhoneVMLock.removeRecord`（`VPhoneVMLock.swift:98`）非阻塞取同一目录 flock，只有记录的 pid 为本进程且操作为 `create-checkpoint` 时删除，删除在持锁期间完成；之后取锁的持有者写自己的记录，不会被删除（D4 缺陷 2 所述“解锁与删除之间被其他进程取锁并写入”的顺序问题由持锁删除避免）。runner 的 `create` 与 `resume` 在返回时（成功、失败、中断）调用（`VPhoneCreateRunner.swift:253`、`:274`、`:638`）。其他操作的记录行为不变。
- 异常退出（SIGKILL、强制退出）留下的记录：现有“pid 不存在即视为过期”的判断存在于 `VPhoneBundleGuard.holderDetail`（`VPhoneBundleGuard.swift:182-193`）、`VPhoneVMStopper`、诊断 `vmOccupancy`（`record_pid_alive`）与 `vm create` 拒绝提示。本次把拒绝提示的判断提取为 `VPhoneCreateOrchestrator.liveHolder`（`:381`），并新增一条：记录写入时间早于该 pid 当前进程的启动时间时视为 pid 复用，不报告为持有者。
- 测试：`CreateCheckpointTests.checkpointWritesReleaseTheBundleLockAndTheRunRemovesItsRecord`（替换原 D4 测试：运行中阶段之间记录为 `create-checkpoint`；成功、写入失败、续跑结束后记录均已删除，锁未被持有）、`runKeepsARecordWrittenByAnotherProcess`（其他 pid、持锁中的记录、其他操作的记录保留）、`StaleRuntimeStateTests`（真实已退出 pid 的记录不被报告为持有者且不阻止取锁；`removeRecord` 只删除本进程本操作的记录）、`CreateLeftoverTests.recoveryHintIgnoresARecordOfAnExitedOrReusedPid`。

### 4.2 `vphone.sock`

- 来源（事实）：VM 进程的 `VPhoneHostControl.start` 创建 `<bundle>/vphone.sock`，`stop()` 删除（`VPhoneHostControl.swift:142-157`），`applicationWillTerminate` 调用 `stop()`（`VPhoneAppDelegate.swift:427-430`）。VM 进程收到 SIGINT 后向客户机请求关机，最多等待 `VPhoneShutdownPolicy.gracefulTimeout`（10 秒）再强制停止，然后经 AppKit 终止。`vm create` 停止 VM 子进程用 `VPhoneManagedProcess.terminate()`（`a653938` `VPhoneManagedProcess.swift:148-158`）：SIGINT 后 2 秒发送 SIGKILL。SIGKILL 下 `applicationWillTerminate` 不执行，socket 不被删除。verification 是最后一个 VM 阶段；DFU 与首启留下的 socket 会被下一个 VM 进程的 `start()` 作为过期 socket 替换（`VPhoneHostControl.swift:80-107`）。
- 推断（未直接观测）：B4 验收中 verification 启动在 SIGINT 后 2 秒内未退出而被 SIGKILL。依据：`VPhoneShutdownPolicy` 注释记录 rig-baseline 从 halt 到 `guestDidStop` 约 3 秒；B4 创建日志无时间戳。负对照测试复现了该机制：替身 VM 关机需 3 秒，2 秒宽限下被 SIGKILL，socket 残留。
- 修复：VM 子进程的停止宽限改为 20 秒（`VPhoneCreateOrchestrator.vmStopGrace`，`:742`，等于 `vm stop` 默认值）；DFU、首启、验证启动、less 启动结束后调用 `removeStaleControlSocket`（`:760`）→ `HostControlClient.removeStaleSocket`：只删除本用户所有、connect 返回 `ECONNREFUSED`（无监听者）且 inode 未变的 socket，有监听者时保留。
- 测试：`CreateLeftoverTests`（替身 VM 获得完整关机宽限并自行删除 socket、退出码 0；2 秒宽限的负对照被 SIGKILL 且 socket 残留，随后被删除；有监听者时保留）、`StaleRuntimeStateTests.staleSocketIsDeletedAndALiveOneIsKept`。

## 5. 改动文件

| 文件 | 提交 | 内容 |
| --- | --- | --- |
| `scripts/cfw_install_host.sh` | 1 | 调用者来源与校验；`hand_back_artifacts` 在成功、失败、中断路径交还；`uid:gid` |
| `sources/VPhoneCore/VPhoneProcessRunner.swift` | 1、2 | `VPhoneInvoker`；`adminPrivilegesCommand/Script`；子进程登记 `track` |
| `sources/vphone-cli/VPhoneCreateOrchestrator.swift` | 1、2、3 | `cfwInvocation`；CFW 延迟取消；可取消等待；中断提示；`vmStopGrace`；`removeStaleControlSocket`；`liveHolder` |
| `sources/vphone-cli/VPhoneRestoreCLI.swift` | 1 | `cfw install` 使用 `cfwInvocation` |
| `sources/VPhoneCore/VPhoneChildCancellation.swift`（新） | 2 | 取消控制器、进程表 |
| `sources/VPhoneCore/VPhoneCreateRunner.swift` | 2、3 | `interrupted` 错误、中断记录；返回时删除运行记录 |
| `sources/VPhoneCore/VPhoneCreateCheckpointStore.swift` | 2 | 写入在 `withExitDeferred` 内 |
| `sources/VPhoneCore/VPhoneManagedProcess.swift` | 2、3 | 登记为 VM 类子进程；`terminate(grace:)` |
| `sources/vphone-cli/VPhoneVMCreateCLI.swift` | 2 | 安装信号处理；退出码 128 + 信号 |
| `sources/vphone-cli/VPhoneCreateLiveStages.swift`、`VPhoneNativeRestoreWorker.swift` | 2 | 可取消的 5 秒等待；worker 登记 |
| `scripts/fw_prepare.sh` | 2 | partial 写入与发布、完成标记 |
| `scripts/check_tar_pipe_memory.py` | 2 | 编译列表加入依赖文件 |
| `sources/VPhoneCore/VPhoneVMLock.swift` | 3 | `removeRecord` |
| `sources/VPhoneCore/HostControlClient.swift` | 3 | `removeStaleSocket` |
| 测试 | 1–3 | `tests/test_cfw_host_isolation.py`、`tests/VPhoneCLITests/CFWInvocationTests.swift`、`tests/VPhoneCLITests/CreateCancellationEndToEndTests.swift`、`tests/VPhoneCoreTests/ChildCancellationTests.swift`、`tests/test_fw_prepare_partials.py`、`tests/VPhoneCoreTests/CreateCheckpointTests.swift`、`tests/VPhoneCoreTests/StaleRuntimeStateTests.swift`、`tests/VPhoneCLITests/CreateLeftoverTests.swift` |

## 6. 命令与结果

| 命令 | 结果 |
| --- | --- |
| `.venv/bin/python3 -B -m unittest tests.test_cfw_host_isolation`（修改前驱动，新测试） | 25 项，16 失败（`p1-pre-change.log`） |
| `.venv/bin/python3 -B -m unittest tests.test_cfw_host_isolation tests.test_cfw_disk_transaction`（修改后） | 43 项通过（`p1-post-change.log`） |
| `swift test --filter CFWInvocationTests` | 首次 1 项断言写错（环境变量按键排序，`IPSW_DIR` 在前），改断言后 4 项通过 |
| `make test_python`（提交 1 后） | `Ran 477 tests`，`OK (skipped=1)` |
| `swift test --filter CreateCancellationEndToEndTests`（修改前 CLI） | 1 项失败，10 处断言（`p2-e2e-pre-change.log`）；替身进程由测试清理 |
| `swift test --skip-build --filter Cancellation`（修改后） | `ChildCancellationTests`、`CreateRunnerCancellationTests` 11 项通过；`CreateCancellationEndToEndTests` 通过（同一过滤另匹配既有 suite 中 3 项，均通过） |
| `FW_PREPARE_SCRIPT=<修改前脚本> .venv/bin/python3 -B -m unittest tests.test_fw_prepare_partials` | 5 项，4 失败 |
| `.venv/bin/python3 -B -m unittest tests.test_fw_prepare_partials -v`（修改后） | 5 项通过 |
| `swift test --skip-build --filter <suite>`：CreateCheckpointTests、CreateLiveStagesTests、ManagedProcessTests、ProcessRunnerTests、NativeRestoreCLITests、CreateOrchestratorTests、NativeFirmwarePrepareTests | 51、30、5、9、4、18、13 项通过（提交 2 后） |
| `make test_python`（提交 2 后） | `Ran 482 tests`，`OK (skipped=1)` |
| `make test_swift`（提交 2 后首次） | 退出 2：`check_tar_pipe_memory.py` 单独编译 `VPhoneProcessRunner.swift` 失败（找不到 `VPhoneChildCancellation`）；修正编译列表后并入提交 2 |
| `.venv/bin/python3 scripts/check_tar_pipe_memory.py` | 退出 0；峰值 RSS 7,913,472 / 8,093,696 字节 |
| `swift test --skip-build --filter <suite>`：CreateLeftoverTests、StaleRuntimeStateTests、CreateCheckpointTests、CreateLiveStagesTests、ManagedProcessTests、BundleGuardTests、DiagnosticsTests | 4、3、52（首次 1 项失败：测试内锁对象释放时机，改为显式置 nil）、30、5、11、40 项通过 |
| `make test_swift`（最终） | 见第 7 节 |
| `make test_python`（最终） | 见第 7 节 |

`make build` 未运行（本任务不要求签名构建）。

## 7. 最终验证

三个提交全部完成后的工作树（提交 3 的内容）：

| 命令 | 结果 |
| --- | --- |
| `make test_swift` | 退出 0；Swift Testing 11 次运行共 992 项通过；XCTest 按各 `.xctest` 汇总行共 217 项执行、3 项跳过、0 失败；`✘` 计数 0；tar pipe 两条 1 GiB 路径峰值 RSS 7,913,472 / 8,093,696 字节；`test_guest_components` 124 项检查 0 失败（`test-swift.log`） |
| `make test_python` | `Ran 482 tests`，`OK (skipped=1)`（跳过项为 `test_daemon_api_icli`，IcliKit checkout 缺失）；本任务新增 11 项（`test_cfw_host_isolation` 19 → 25 个测试方法，`test_fw_prepare_partials` 5 项）；起点 `a653938` 未单独运行，按此推算为 471 项（`test-python.log`） |
| `zsh -n scripts/cfw_install_host.sh`、`bash -n scripts/fw_prepare.sh`、`git diff --check a653938 HEAD` | 通过 |

## 8. 需要真实环境复核的步骤

前提：专用库根（不是 `~/.vphone/VMs`），本构建 `make build` 与 `make launchpad`，amfidont 放行；不使用 `vm-2607`、`vm-new`。

1. root-popup 所有权：Launchpad 新建一台 regular 机器直到 cfw 完成。检查 `.cfw-history`、事务目录（仍为 0700）、`transaction.json`、`.vphoned.signed`、`.cfw_temp` 的所有者为调用者 uid/gid；输出含 `restored ownership of host-side artifacts to uid <uid>`；调用者能读取 `transaction.json`，`vm delete` 能删除该机器。另做一次在认证后让 CFW 失败（例如安装期间让 VM 目录被锁占用以触发 `pre-publish` 拒绝），确认失败路径同样交还。
2. sudo 路径：`vphone-cli cfw install <name>`（终端 sudo）与 `make cfw_install VM_DIR=...`，检查同上。
3. 取消 prepare：解包或下载运行中点 Stop Creating。记录 `ps -axo pid,ppid,pgid,stat,command` 中 `fw_prepare.sh`、`unzip` 结束所需时间；`vm create` 退出码 130；`create-status` 为 `interrupted`，prepare 的 `error` 含 `interrupted by SIGINT`，两把锁均为 false；`~/.vphone/ipsws` 下没有不带 `.vphone-extract-complete` 的缓存目录，只可能有 `.<名称>.partial.<pid>`（下一次运行删除）。随后续跑。
4. 取消 restore：DFU 与 `restore-update` 运行中取消，记录 DFU 进程与 bridge 进程的退出时间、是否需要 SIGKILL、`create-status` 的 `firmware_transaction` 与续跑的 `probe.restore`。
5. 取消 cfw：认证对话框显示时取消（预期 osascript 结束，cfw 记为 `running`/`interrupted`）；认证后取消（预期输出 `cannot be stopped from this process`，CFW 结束后才退出，cfw 为 `succeeded`，first_boot 为 `running`）。
6. 取消首启或验证启动：记录 VM 进程是否在 20 秒内自行退出，`vphone.sock` 是否删除。
7. 残留：一次完整成功创建后，bundle 中无 `.vphone-runtime.json`、无 `vphone.sock`；`vm list`、`doctor` 不报告占用。
8. Launchpad 退出确认（G8）：创建中 ⌘Q → Quit，确认子进程全部结束，重新打开后检查点为 `interrupted`。

## 9. 事实、推断与未验证

事实：

- Foundation `Process` 的子进程是新进程组的组长；子进程不继承父进程对 SIGINT 的 `SIG_IGN`（本机探针与测试）。
- 修改前，对 `vm create` 进程组的 SIGINT 只结束 `vm create`，prepare 替身及其后代继续运行并写 bundle，bundle 锁仍被持有（端到端测试）；修改后全部结束，`vm create` 以 130 退出，检查点 prepare 为 `running`（总状态 `interrupted`）并带中断说明，两把锁释放，运行记录删除。
- 修改前，root-popup 路径（无 `SUDO_UID`）驱动不交还任何产物；失败路径不交还 `.vphoned.signed` 等。修改后两条路径在成功、失败、中断时都交还（替身提权测试）。
- 修改前 `fw_prepare.sh` 把中断的解包或本地复制留在最终名称下，并在下次运行复用（替身测试）。
- 修改前 `vm create` 停止 VM 子进程的宽限为 2 秒；`VPhoneShutdownPolicy.gracefulTimeout` 为 10 秒。

推断（待验证假设）：

- B4 验收中 `vphone.sock` 残留来自 verification 启动被 SIGKILL（见 4.2）。
- 用户身份进程无法向 root 的 CFW 驱动发信号；认证对话框中的取消使 osascript 以非 0 退出。
- `sudo -E` 在本机 sudoers 下保留 `VPHONE_INVOKER_UID/GID`（`-E` 原已使用；sudo 拒绝时整个安装失败，不会静默丢弃）。

未验证：

- 真实 root 下的 `chown`（测试中 `chown` 为替身，进程为普通用户）；真实 `osascript` 认证对话框的环境与进程树。
- 真实 DFU、python restore、VM 启动进程在转发 SIGINT 下的退出时间与设备状态；20 秒 VM 宽限、10 秒工具宽限、90 秒强制退出的实际余量。
- native prepare 与 patch 阶段（进程内）取消时的等待时间；patch 被强制退出后的 C4 恢复路径未在本次重跑。
- 第三方账户条目不被交还的规则在 root 下的行为（需 root 构造）。
- 下载（curl/aria2c 续传）被中断后的部分文件仍按原设计保留续传，未改。
- `fw_prepare.sh` 以 root 运行（less）时 partial 与缓存目录的所有权。
- `scripts/patchers/__pycache__` 在 root CFW 后写入应用包（D4 记录的另一 root 残留）不在本次范围，未处理。
