# `vm launch` 诊断输出、Launchpad 日志轮转与 CI 静态组装（2026-10-01）

## 1. 输入与环境

| 项目 | 内容 |
| --- | --- |
| 起点 | `7004e14`（worktree 分支快进到该提交） |
| 来源 | `research/t26_b2_launchpad_2026-10-01.md` 第 10 节“观察到的现象”中的两条 |
| worktree 准备 | `.venv` 符号链接到主仓库；`git submodule update --init --recursive vendor`；`git submodule update --init scripts/resources`；`.tools/bin/{trustcache,insert_dylib}` 从主仓库复制；按 Makefile 格式生成 `sources/vphone-cli/VPhoneBuildInfo.swift`（`7004e14`）。均为 Git 忽略或子模块内容 |
| 日志 | `research/artifacts/launch-log-diag-2026-10-01/`（Git 忽略） |
| 边界 | 没有启动 VM；没有发送合成输入；测试只用临时库根与临时日志目录；没有对 `vm-2607`、`vm-new` 执行命令或发信号 |

提交：

| 提交 | 内容 |
| --- | --- |
| `fix: print host diagnostics only when vm launch fails to start` | 修改 1 |
| `feat: keep the previous Launchpad console log on restart` | 修改 2 |
| `ci: assemble and check Launchpad in the bundle job` | 修改 3 与本记录 |

## 2. 修改 1：`vm launch` 宿主诊断

### 触发条件（事实）

- 诊断文字由 `scripts/boot_host_preflight.sh` 输出（`=== Host ===`、`=== Entitlements ===`、`=== Policy ===`、`[release_help] exit=N`、`=== Result ===`）。
- `sources/vphone-cli/VPhoneVMLaunchCLI.swift` 的 `VPhoneVMLaunchCommand.run()` 以 `--assert-bootable` 运行该脚本，用 `VPhoneProcessRunner.runCapturing` 捕获 stdout。修改前，`print(pre.stdout)` 位于 `guard pre.succeeded` 之前，因此每次 `vm launch` 都输出该报告，与预检结果和 VM 结果无关。
- 预检失败时（例如 `vphone-vm --help` 被 AMFI 以 137 终止），脚本以该退出码结束，`vm launch` 输出报告和 stderr 后以同一退出码退出。该路径的输出含 `[release_help] exit=137`。第 10 节正常停止后看到的是 `[release_help] exit=0`，与预检成功路径一致。

### 输出位置在 `Guest stopped` 之后的原因（事实与推断）

- 事实：修改前的替身测试中，`vm launch` 的 stdout 为管道，捕获顺序为 `[vphone] runtime started`、`[vphone] SIGINT — shutting down`、`[vphone] Guest stopped`，然后才是 `=== Host ===` 段（`before.log`）。
- 推断：Swift `print` 写入 C stdio 的 `stdout`；stdout 不是终端时为全缓冲。子进程 `vphone-vm` 继承文件描述符 1 并直接写入。父进程缓冲区在退出时才写出，所以报告出现在子进程输出之后。Launchpad 把 `vm launch` 的 stdout 指向日志文件，属于同一情形。
- 推断（未在终端验证）：stdout 为终端时为行缓冲，修改前报告会出现在启动输出之前。

### 改法

- 预检成功时只保存报告，不输出。
- 以下情形输出报告，内容不变：预检失败（原有路径，先输出报告再输出 stderr）；`child.run()` 抛错；子进程以非 0 状态退出或被信号终止（`VPhoneVMLaunchCommand.childFailed`：`terminationReason == .exit && terminationStatus == 0` 以外的情形）。
- 正常停止（SIGINT 或 `vm stop` 后 `Guest stopped`，退出码 0）不输出。
- 启动子进程前执行 `fflush(stdout)`，使 `[trace] spawning` 等本进程输出位于子进程输出之前。
- 退出码不变：仍为 `ExitCode(child.terminationStatus)`。

### 测试

`tests/VPhoneCLITests/VMLaunchDiagnosticsTests.swift`（`VPhoneCLITests`）：复制 `.build/debug/vphone-cli` 到临时目录，旁边放 `vphone-vm` 替身脚本；`--project-root` 指向临时资源目录，其中 `scripts/boot_host_preflight.sh` 为替身；`--library-root` 指向临时库根；使用 `--no-vphoned`。

| 测试 | 设置 | 断言 |
| --- | --- | --- |
| `normalStopDoesNotPrintHostDiagnostics` | 预检退出 0；替身输出 `SIGINT — shutting down`、`Guest stopped`，退出 0 | 退出 0；stdout 不含 `=== Host ===` 与 `[release_help]` |
| `preflightRejectionPrintsHostDiagnostics` | 预检退出 137 | 退出 137；stdout 含报告与 `[release_help] exit=137`；stderr 含 `not launchable on this host (exit 137)`；替身未运行 |
| `runtimeExit137PrintsHostDiagnostics` | 预检退出 0；替身退出 137 | 退出 137；stdout 含报告 |
| `runtimeSignalTerminationPrintsHostDiagnostics` | 预检退出 0；替身 `kill -KILL $$` | 退出码非 0；stdout 含报告 |
| `childFailureRule` | 纯函数 | `(.exit, 0)` 为否；`(.exit, 137)`、`(.exit, 1)`、`(.uncaughtSignal, SIGKILL)` 为是 |

修改前结果（`before.log`）：`normalStopDoesNotPrintHostDiagnostics` 失败 2 项（stdout 含 `=== Host ===` 与 `[release_help]`）；其余 3 项通过（当时无 `childFailureRule`）。修改后（`after.log`）：5 项通过。

## 3. 修改 2：Launchpad 控制台日志轮转

### 规则

- 每次 Start（`VPhoneLaunchpadMachineLibrary.start`）在启动 `vm launch` 前调用 `VPhoneLaunchpadConsoleLog.rotate`，把 `<stem>.log` 重命名为 `<stem>.1.log`。只保留一份上一轮；已有 `<stem>.1.log` 被替换（`renameat` 原子替换目录项）。`<stem>` 与 `consoleLog` 相同：默认库为机器名，其他库为 `<name>-<digest>`。
- 只在 Launchpad 日志目录内操作：日志必须位于传入的 `logsDirectory`；该目录以 `O_DIRECTORY | O_NOFOLLOW` 打开（目录本身是符号链接时打开失败）；日志用 `fstatat(..., AT_SYMLINK_NOFOLLOW)` 检查，必须是普通文件；重命名用相对该目录描述符的 `renameat`。
- 拒绝情形（不重命名，返回 `.failed(reason)`）：日志是符号链接；日志不是普通文件；日志不在日志目录；日志目录无法以不跟随符号链接的方式打开；目标 `<stem>.1.log` 是另一台已列出机器的当前控制台日志（机器名为 `<name>.1` 时）；`renameat` 失败。
- 拒绝或失败不阻止启动。新日志第一行为 `Launchpad did not keep the previous console log: <reason>`（本地化，zh-Hans 为 `needs_review`），控制台视图从该行开始显示。`<reason>` 为英文技术说明（含 `strerror` 文本）。
- 日志不存在或日志目录不存在时返回 `.noPreviousLog`，与首次启动相同。
- 新日志仍由 `VPhoneLaunchpadChildProcess` 用 `FileManager.createFile` 新建（新文件号）；新增 `preamble` 参数只用于写入上面的第一行。日志为符号链接时，测试确认新建的是普通文件，链接目标内容未变。
- 控制台视图、Inspector 的“Show Console Log”、Machines 视图的“Show in Finder”仍调用 `library.consoleLog(machine.path)`，即当前 `<stem>.log`。
- 创建日志（`-create.log`）规则未改：新建替换、续跑追加（B4 现状）。

### 对需求的补充

- 机器名可以含 `.`（`VPhoneLibraryError.invalidName` 只禁止空名、`/` 和前导 `.`）。机器 `alpha` 的 `alpha.1.log` 与机器 `alpha.1` 的当前日志同名。为避免替换另一台机器的日志，`start` 把其他已列出机器的 `consoleLog` 作为 `reserved` 传入；冲突时拒绝轮转。未被列出的机器不在保护范围内。

### 测试

`tests/VPhoneLaunchpadKitTests/LaunchTests.swift` 新增 `ConsoleLogRotationTests`（7 项，使用现有 `LaunchpadStandIn` 替身与临时日志目录）：

| 测试 | 断言 |
| --- | --- |
| `previousLogNameKeepsTheStem` | `alpha.log` → `alpha.1.log`；`a.b-1a2b3c4d.log` → `a.b-1a2b3c4d.1.log` |
| `firstStartHasNoPreviousLog` | 无旧日志时 `rotate` 为 `.noPreviousLog`；启动后无 `alpha.1.log`；新日志无前置行 |
| `startKeepsThePreviousRunAsDotOne` | 第二次启动后 `alpha.1.log` 等于第一次的完整日志；`consoleLog` 仍为 `alpha.log`；新日志只含一次运行 |
| `existingDotOneIsReplaced` | 已有 `alpha.1.log` 被上一轮 `alpha.log` 替换；目录中只有这两个 `alpha*` 文件 |
| `symbolicLinkLogIsNotRotatedAndTheStartGoesOn` | `rotate` 为 `.failed("alpha.log is a symbolic link")`；启动继续；无 `alpha.1.log`；链接目标未变；`alpha.log` 变为普通文件，第一行为拒绝原因，第二行为替身输出 |
| `startDoesNotReplaceTheLogOfAMachineNamedDotOne` | 机器 `alpha.1` 的日志未变；`alpha` 新日志第一行为冲突原因 |
| `rotationStaysInTheLogsDirectory` | 日志目录为符号链接时拒绝（`cannot open`）且目标目录文件仍在；日志不在目录内时拒绝；`reserved` 冲突时拒绝；日志位置为目录时拒绝 |

## 4. 修改 3：CI bundle 任务

- `.github/workflows/checks.yml` 的 `bundle` 任务在“Build complete app and verify final signature”（`make build`、`make check_bundle`）之后新增步骤“Assemble and check Launchpad”：`zsh scripts/build_launchpad.sh`、`make check_launchpad`。
- 未使用 `make launchpad`（依赖 `bundle`，会再次构建）；未加入 `make test_launchpad_cli` 与 UI 冒烟。
- `scripts/build_launchpad.sh` 与 `scripts/check_launchpad_*.py` 只用 Python 标准库；构建所需子模块与 `make build` 相同。
- `tests/test_launchpad_bundle.py::test_build_and_ci_do_not_include_launchpad` 改为：除 `checks.yml` 外的 workflow 不含 `launchpad`；`checks.yml` 中含 `launchpad`（不区分大小写，排除注释和 `- name:` 行）的行恰为上述两条命令；`bundle` 任务内顺序为 `make build`、`make check_bundle`、`zsh scripts/build_launchpad.sh`、`make check_launchpad`；`scripts/build.sh` 与 Makefile `bundle` 目标不含 `launchpad`；原有 `test_launchpad_cli` 与 `test`/`test_python`/`test_swift` 断言保留。

## 5. 命令与结果

| 命令 | 结果 |
| --- | --- |
| `swift test --filter VMLaunchDiagnosticsTests`（修改前） | 4 项中 1 项失败（2 个 issue，见第 2 节）；`before.log` |
| `swift test --filter VMLaunchDiagnosticsTests`（修改后） | 5 项通过；`after.log` |
| `swift test --filter VPhoneLaunchpadKitTests` | Swift Testing 152 项、34 个 suite 通过；`rotation.log` |
| `python3 scripts/check_launchpad_strings.py` | `271 keys, 271 source literals, 2 Info.plist keys, languages en, zh-Hans; 0 issues; needs_review: 129` |
| `.venv/bin/python3 -B -m unittest tests.test_launchpad_bundle -v` | 22 项通过 |
| `/usr/bin/ruby -ryaml` 解析 `.github/workflows/*.yml` | 3 个文件解析成功；`bundle` 任务步骤顺序与第 4 节一致。本机 Python 无 `yaml` 模块，无 `actionlint` |
| `make test_python` | 退出 0；453 项，`OK (skipped=1)`；`test_python.log` |
| `make test_swift` | 退出 0；Swift Testing 11 次运行共 967 项通过；XCTest 共 217 项执行、3 项跳过、0 失败；`test_guest_components` 124 项检查 0 失败；tar pipe 两条 1 GiB 路径峰值 RSS 7,880,704 / 9,125,888 字节；`test_swift.log` |
| `make build` | 未执行：本会话的自动权限检查拒绝在 worktree 运行 `make build`（理由为可能干扰正在运行的工作负载） |
| `zsh scripts/build_launchpad.sh`、`make launchpad`、`make check_launchpad`、`make test_launchpad_cli` | 未执行：均依赖 `make build` 产生的 `.build/vphone-cli.app`（`make launchpad` 本身包含 `bundle`）。`make check_launchpad` 中的字符串检查已单独执行，见上 |

## 6. 事实、推断与未验证

事实：

- 修改前 `vm launch` 在预检成功时无条件输出预检报告；stdout 为管道时该报告位于子进程全部输出之后。
- 修改后正常停止（退出 0）不输出报告；预检失败、子进程非 0 退出、子进程被信号终止时输出报告，内容与修改前相同。
- Launchpad Start 前把上一轮控制台日志保留为 `<stem>.1.log`；符号链接、非普通文件、目录外日志、符号链接日志目录与其他机器日志冲突时拒绝轮转并在新日志第一行说明原因，启动继续。

推断：

- stdout 为终端时，修改前报告出现在启动输出之前（libc 行缓冲行为，未在终端测试）。
- 子进程运行一段时间后才非 0 退出或被信号终止（例如 `vm stop --force` 发 SIGKILL、运行中崩溃）时也会输出报告。`vm launch` 没有子进程“已进入运行状态”的信号，规则无法区分启动失败与运行后失败。

未验证：

- 真实 VM 下正常停止后不再输出报告：待下次真实启停复核（Launchpad Start → Stop，检查日志末尾 `Guest stopped` 后无 `=== Host ===`）。
- 真实 Launchpad 中二次 Start 后 `<machine>.1.log` 的内容与控制台显示。
- CI 中 `zsh scripts/build_launchpad.sh` 与 `make check_launchpad` 的实际运行（GitHub Actions 未在本地运行；`macos-26` runner 上 `swift build -c release --product vphone-launchpad` 与 `codesign` 结果未知）。
- 本地 `make build`、`zsh scripts/build_launchpad.sh`、`make launchpad`、`make check_launchpad`（bundle 部分）、`make test_launchpad_cli` 未执行，原因见第 5 节。
- zh-Hans 新字符串 `Launchpad 未保留上一次的控制台日志：%@` 标记为 `needs_review`。
