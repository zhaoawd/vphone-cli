# T60：FIFO 导入与批量选择（2026-10-20）

当前源码已接入并发导入请求 FIFO 和多归档选择，相关验证通过。T60 整体尚未验收。独立 DSC 安装继续使用已有冻结应用，本轮未替换该应用或修改 VM 程序。

## 问题与复现

原 `importArchive` 直接调用 `perform`。当 `globalActivity` 非空时，第二个请求直接返回，没有启动命令，也没有等待。

新增 `ImportQueueTests` 先在原实现运行：2 项测试记录 4 个失败，分别确认第二项提前返回及后续请求未执行。命令：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache" SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache" swift test --disable-sandbox --cache-path "$PWD/.build/test-cache" --force-resolved-versions --filter ImportQueueTests
```

## 实现与范围

- `importArchive` 复用 `importArchives`。每次选择作为一个请求排队；同一选择中的归档按顺序执行。并发选择按到达顺序取得执行资格。
- 取消等待请求会恢复其 continuation，不等待当前导入完成，也不取消其他请求。取消活动请求仍通过现有命令执行器发送信号，并等待输出排空后释放下一项。
- 单项失败或取消后停止当前选择的剩余归档，其他独立选择仍可继续。错误由原有 `actionError` 显示。
- `beginTermination` 关闭命令入口后，等待请求及批次剩余项不启动新命令。原有 bounded drain 和超时取消退出行为保持。
- 打开归档面板支持多选，主窗口和无窗口回退均传递完整 URL 集合；中英文说明同步。

已阅读固定上游端点差异中的导入队列、导入行和 stopTransfers 实现。当前只交付 FIFO、批量选择和既有取消/退出入口的接线；上游逐项队列行、进度及取消 UI 尚未移植。本地保留现有排他发布和 staging 保护，未复制上游全局 Task 链。

## 验证

相关 `ImportQueueTests|EditLibraryTests|CommandTerminationTests|ExportOutputTests`：26 项、4 suites，通过。覆盖顺序、Unicode/空格归档名、无效项停止批次、等待项取消、活动批次取消后输出排空、退出后不启动下一项。

完整 LaunchpadKit：210 项、47 suites，通过，9.063 秒；6 个真实 CLI/烟测测试按现有配置跳过。首次沙箱运行有 4 个环境权限失败（进程列表、容量查询、子进程），同一已构建测试在沙箱外通过：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache" SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache" swift test --disable-sandbox --cache-path "$PWD/.build/test-cache" --force-resolved-versions --skip-build --filter VPhoneLaunchpadKitTests
```

Swift 测试构建包含 Launchpad 源码编译；本轮未执行签名 Launchpad 的真实多选交互、真实 VM 归档迁移、逐项队列 UI 或完整退出矩阵。上述测试不替代这些验收。

证据：`evidence/T60-import-queue-20261020/manifest.json`。源码和压缩日志摘要已保存；没有提升 T60 的 accepted 状态。


## 2026-10-20 后续：逐项状态、取消和退出接线

新增 `imports` 状态集合，区分 waiting/running/cancelling。主窗口在机器表格上方列出归档名称、状态及 Cancel，支持继续添加选择。当前 CLI 不向管道输出字节进度，因此 UI 仅显示不确定进度，不推断百分比。

逐项取消等待归档会直接移除该项，保留同一选择的其他归档；等待选择的全部条目取消后，调用方立即返回。取消活动项会发送现有 SIGINT，并保留 cancelling 行到输出排空；该选择的下一项可继续。取消调用方 Task 仍取消整个选择；一般失败仍中止该选择的剩余项。

应用退出先关闭命令入口，再执行 `cancelTransfers`，取消等待导入/导出及活动任务；既有 `waitForTermination` 负责有期限的输出和日志排空。超时保持 cancelling 行及活动命令，取消退出并重新开放命令入口；已取消的等待项不恢复。已发布导出不删除。创建流程及混合版本完整退出矩阵尚未重新验收。

相关 31 项通过。完整 LaunchpadKit 216 项、47 suites 通过（9.100 秒），6 项按原配置跳过；该次完整运行发生在新增可选真实 CLI 队列测试之前，生产源码此后未变。

独立候选 `.build/t60-import-state-20261020.app` 完成 Release 构建、签名、资源、本机 Mach-O 依赖及嵌入工具链摘要/entitlement 检查。基于既有构建脚本生成限定副本，拒绝覆盖已有候选，不执行原脚本的目录删除。首次构建受 sandbox-exec 限制，第二次在 dSYM 阶段遇权限拒绝；保留日志后，沙箱外构建通过。原冻结应用和当前 VM 程序的摘要保持。

新增 `RealCLIImportQueueTests.concurrentImportsPublishBothArchivesAndPreserveTheirSources`，使用候选内嵌的已验证 CLI 创建两台全新离线 fixture，导出后并发导入另一个隔离库。最终定向复验退出 0、6.656 秒：两个导入均发布，源盘/目标盘完整 SHA-256 相等，归档摘要保持，两个命令退出 0 且输出排空，无 import staging。该测试不启动 VM。执行命令：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache" SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache" VPHONE_LAUNCHPAD_APP="$PWD/.build/t60-import-state-20261020.app" VPHONE_LIBRARY_ROOT="$PWD/.build/t60-import-state-debug/empty-library" swift test --disable-sandbox --cache-path "$PWD/.build/test-cache" --force-resolved-versions --filter RealCLIImportQueueTests
```

证据：`evidence/T60-import-state-20261020/manifest.json`。真实多选/取消 UI 操作、字节进度协议、真实 VM 归档迁移及完整混合版本退出矩阵未完成；T60 整体不提升为 accepted。

## 2026-10-20：真实导入中的退出协调

使用同一独立签名候选、新建临时源库/目标库和1GiB磁盘夹具，新增真实导入进入私有解包目录后退出的回归。先观察实际 `.import-` 目录和等待项，再执行生产 `beginTermination`、`cancelTransfers` 和 `waitForTermination`。确认活动CLI退出130、输出排空、等待项未启动、无最终发布/残留staging/子进程；源磁盘、两个归档和目标库已有config的完整SHA256保持。原并发两个归档正常导入回归同时通过。

首次新增测试错误匹配 `.vphone-import-`，未观察到实际解包而失败；源码明确采用 `.import-`，现已修正该等待条件与既有正常导入的残留目录断言。生产代码未修改，两个阶段断言保留。正式复验2项、9.065秒、退出0。命令见 `evidence/T60-real-import-termination-20261020/command.txt`，原失败和成功日志均保留。

本结果覆盖库与命令层的退出协调，尚未通过AppKit真实Quit操作；完整真实VM/混合版本创建退出矩阵和字节进度仍待验收。DSC冻结CLI和VM程序SHA256保持，独立DSC安装继续至第7/7步vphoned安装入口，未发布。本轮没有提交或推送。


## 2026-10-21：导出队列、源变化合同与实际多选验证

本轮先保存跨选择导出并发、取消调用方后仍继续导出的失败回归：2项测试4个失败。导入和导出分别使用FIFO选择队列；同一次选择保留执行资格直到活动子进程及输出排空。取消单行只跳过该项；取消调用方停止整次选择。取消等待选择可立即返回，保留其他独立选择。退出先关闭命令入口、再取消转移的顺序保持。

两个归档后端新增发布前源复查：导出记录未排除成员的dev/inode、类型/权限、owner、link count、size、flags、mtime/ctime和符号链接目标，完成写出后重读成员集合并比较；遍历过程中变化也拒绝。导入同时记录归档路径本身和跟随链接后的目标状态，并在名称竞争检查后的最终提交前复查。原始失败回归为两个参数化函数、25个失败。修复后覆盖同尺寸写入并恢复mtime、替换inode、成员增加、链接变化、输入归档追加/替换及最后提交前变化；稳定归档别名仍可导入。失败清理本次staging，最终目标不发布。

该合同依靠现有VM锁排除遵守锁的写入者，并检测普通外部元数据/身份变化。它不提供原子文件系统快照或对恶意并发写入的完整内容证明；目录元数据变化也会保守拒绝。

正式 `scripts/run_launchpad_cli_tests.sh` 纳入 `RealCLIImportQueueTests`，支持显式 `VPHONE_LAUNCHPAD_APP` 选择已验证候选。旧导出取消测试改为观察真实私有staging/output，保留中途取消及无残留断言，退出状态按CLI协议核对130。测试日志写入各自临时库；签名UI候选通过Info.plist内的 `VPhoneLaunchpadDiagnosticsDirectory` 隔离日志，正常Bundle保持原默认目录和工具链选择边界。

最终完整LaunchpadKit221项/49 suites、Core436项/47 suites通过；Python Bundle/本地化37项通过。正式CLI入口对上一签名候选 `.build/t60-import-state-20261020.app` 与本轮 `.build/t60-closeout-20261021.app` 各6项/3 suites通过，分别17.181秒、15.812秒。此兼容结果只覆盖这两个实际CLI候选，不等于全部历史Bundle组合。

实际NSOpenPanel确认两个归档同时被选中并提交；隔离库中两个16GiB稀疏磁盘夹具均已发布，源/目标各完整SHA256相等，源归档SHA256保持，无导入staging。两个归档按记录顺序各有成功日志。随后Computer Use的AX、截图、重新绑定及会话重置均报timeoutReached；1秒sample显示候选主线程处于正常事件循环，超时原因未查明。没有据此判定应用卡死，也没有执行其他技术的UI输入。UI活动行取消和AppKit实际Quit仍未验证。

构建/完整验证遇到的环境失败、期望失败和最终通过日志均保存。当前生成的BuildInfo仍含历史hash；候选来源以manifest中的HEAD、WIP源码摘要和产物摘要为依据。脚本执行中更新了候选脚本，首次进程在成功校验后报unmatched quote；保存脚本语法检查和后续独立最终签名/资源检查通过，不把首次构建命令记为退出0。

未覆盖：真实VM迁移、全部混合Bundle/创建退出矩阵、实际UI取消/Quit、管道字节进度协议。当前仍显示不确定进度，不推断百分比。T60整体保持未accepted；冻结DSC验收程序保持。证据：`evidence/T60-closeout-20261021/manifest.json`。


计数补充：完整LaunchpadKit框架报告221项，其中8项真实CLI/烟测按配置跳过；完整Core报告436项，其中1项实际资源探测按配置跳过。上述真实CLI6项随后在两个指定签名候选上分别显式执行并通过；其他配置性跳过不提升为已验收。具体命令与最终源码/产物证据索引见本轮manifest及commands.txt。

## 2026-10-21：剩余实现与最终离线矩阵

本轮完成创建退出协调、Finder 归档入口、版本化进度和 socket 排除。最终候选为 `.build/t60-remaining-r3-20261021.app`。T60 整体仍未 accepted：实际 GUI 活动取消/传输退出/Finder 打开验证因 Mac 锁定暂停，真实 VM 导入因容量预检拒绝而未开始。

创建原先使用独立 detached 子进程，未计入普通命令活动。确认退出后，AppKit 可能在创建子进程、日志和历史完成前返回 terminateNow。新增两项失败回归记录六个 issue；现在创建加入同一命令活动表，退出向创建进程组发送 SIGINT，并等待输出/日志完成。有期限等待超时仍取消退出，保留 reader 和日志；运行中的 VM 仍使用独立生命周期。两项创建回归使用受控替身，未执行真实下载、restore 或创建中实际 AppKit Quit。

Finder 的 `application(_:open:)` 接收整次归档选择；工具链验证完成前保存选择，验证完成后按顺序交给现有导入队列。只接受本地 `.tzst`/`.txz`，无效选择整组拒绝。Info.plist 声明 Alternate Viewer 和对应 UTI，不改变系统默认文件关联。冷启动排队、顺序、无效 URL 与 handler 不替换由正式测试覆盖；实际 Finder Open With 尚未完成。

进度使用独立的可选 JSONL 文件，记录 version=1、direction、bytes、可选 total 和 completed。文件位于日志目录下本次私有 0700 子目录，以 O_EXCL/O_NOFOLLOW 创建，权限 0600。旧 CLI 不写该文件时保持不确定进度；新 CLI 不依赖进度 reader 存活，进度失败不取消数据操作。reader 拒绝未知版本、无效数值、错误方向和倒退字节，忽略未完成行。导入报告压缩输入字节，native 导出报告逻辑 payload；system-tar 导出总量保持 unknown。最终成功仍由 CLI 退出和实际发布决定，completed 仅在发布后发出。

归档继续默认使用 system-tar。两后端排除运行时 socket；实际 AF_UNIX socket 回归覆盖 glob 字符名称，普通同名模式文件仍保留。源身份/成员集合复查和排他发布保持。

实际 GUI 多选触发 `tar: Error opening archive: Can't initialize filter; unable to run program "zstd -d -qq"`。最小 PATH 的签名 CLI 重现同一错误，确认 Finder 环境无法找到外部解压工具。构建现在打包 zstd/xz，依赖闭包改写为 Bundle 内路径，记录工具和动态库摘要，并包含 zstd、xz、LZ4 许可证。tar 子进程使用 Bundle 工具路径；shell 安装前置增加 xz。正式回归以 `/usr/bin:/bin:/usr/sbin:/sbin` 为 PATH，两个压缩格式的导出/导入均通过。没有修改默认归档后端。

### 最终验证

| 实验设置 | 结果 |
| --- | --- |
| 完整 LaunchpadKit | 框架报告 227 项、51 suites，10 项配置性跳过；10.501 秒，退出 0 |
| 完整 Core | 框架报告 441 项、48 suites，1 项配置性跳过；14.477 秒，退出 0 |
| ArchiveCLITests | 2 个测试函数、含 2 个无效参数场景，退出 0 |
| Python 打包/本地化/依赖检查 | 62 项，10.712 秒，退出 0 |
| 真实 PTY/断管与 tar | 7 项，3.692 秒，退出 0；独立编译增加生产 VPhoneResources 依赖 |
| 最终 r3 签名候选 | 正式 CLI 入口 8 项，28.648 秒，通过；进度及最小 PATH 两种压缩格式通过 |
| 旧 `.build/t60-import-state-20261020.app` | 同一入口报告 8 项，16.972 秒，通过；无进度回退通过，最小 PATH 能力明确不声称支持 |
| 真实 CLI 两后端 × SIGINT/SIGTERM | 导入 4 场景、导出 4 场景通过；分别退出 130/143，无 staging/最终发布/存活 tar，原盘和已有归档保持 |
| r3 完整 Bundle/嵌套签名/资源/本机依赖 | 通过；VM CDHash 保持 `89b70a253cad2adea133b3e875519afaf72c5d17` |

完整 Swift 命令如下；签名 CLI 正式入口另对上述两个具名候选分别运行。完整套件中跳过的真实 CLI 8 项已在具名候选上显式执行，另两项烟测未执行。

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache" SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache" swift test --disable-sandbox --cache-path "$PWD/.build/test-cache" --force-resolved-versions --filter 'VPhoneLaunchpadKitTests|VPhoneCoreTests|CLIArchiveTests'
# 上一条过滤器中的 CLIArchiveTests 不匹配实际名称，归档 CLI 另行明确执行：
CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache" SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache" swift test --disable-sandbox --cache-path "$PWD/.build/test-cache" --force-resolved-versions --filter ArchiveCLITests
VPHONE_LAUNCHPAD_APP="$PWD/.build/t60-remaining-r3-20261021.app" zsh scripts/run_launchpad_cli_tests.sh
.venv/bin/python -m unittest tests.test_bundle_validation tests.test_bundle_native_dependencies tests.test_launchpad_bundle tests.test_launchpad_strings
.venv/bin/python -m unittest tests.test_progress_pipe -v
.venv/bin/python research/upstream_integration_2026-10-15/evidence/T60-import-cancellation/accept_cli.py .build/t60-remaining-r3-20261021.app/Contents/Helpers/vphone-cli.app/Contents/MacOS/vphone-cli
.venv/bin/python research/upstream_integration_2026-10-15/evidence/T60-export-cancellation/accept_cli.py .build/t60-remaining-r3-20261021.app/Contents/Helpers/vphone-cli.app/Contents/MacOS/vphone-cli
```

### 实际 GUI 与真实 VM 范围

前一候选实际 Command-Q 已通过：PID78563 退出，观察先于任何可能重启应用的 AX 调用。Finder 激活后 UI 工具一度恢复；随后工具明确报告 Mac 锁定，自动解锁失败，已请求用户手动解锁。不能以此前 idle Quit 代替新候选活动取消、传输中 Quit/超时、创建中 Quit 或 Finder 冷打开验收。私有测试库仍为空。实际 GUI 解压错误虽已通过正式 CLI 回归修复，最终候选的实际 GUI 复验仍待完成。

真实归档选择已停机的旧 `vm-new`。脚本持源目录锁、核对无 hdiutil 附件，对源只读取/完整摘要及创建 APFS 克隆，后续导出只操作克隆。64GiB Disk.img 和七个其他持久文件摘要已保存。native 导出成功，归档 15,564,157,664 字节，SHA256 `8a3cdc9ce63a5350ce05f6f4658e1434b5ca48d8a1d218fb8c01051b1b82bd9d`。此前 8GiB/12GiB 上限尝试按保留空间规则发送 SIGINT，均退出130并清理私有 staging，最终归档保留。

导入在创建 staging 前被容量预检拒绝。补计归档辅助 payload 后，需要空闲 30,044,004,352 字节，其中含4GiB保留；本次采样空闲27,688,960,000字节，差2,355,044,352字节。需先释放至少3GiB，且执行前重新检查。没有降低保留量、删除已有数据、启动该 VM 或操作当前 DSC 验收 VM。当前只证明真实导出，未证明真实导入、源/目标完整磁盘相等或导入后启动。

恢复命令如下；同一 work 的目标必须仍未创建，脚本会重新核对归档摘要和容量。

```sh
.venv/bin/python research/upstream_integration_2026-10-15/tools/accept_t60_real_vm_archive.py import --source vm-new --work .build/t60-remaining-20261021/real-vm-r3 --cli .build/t60-remaining-r3-20261021.app/Contents/Helpers/vphone-cli.app/Contents/MacOS/vphone-cli --backend native
```

证据：`evidence/T60-remaining-20261021/manifest.json`。已归档的初始失败、环境拒绝及最终通过日志均保留。最终候选来源以 HEAD+WIP 源码摘要、产物摘要和签名记录为准；不使用历史 BuildInfo 作为当前源码证明。冻结 DSC CLI/VM 与此前摘要一致。本轮未提交、推送或发布。

## 2026-10-21：用户解锁并清理空间后的实际验证

最终r3候选完成了实际等待导入Cancel、活动导入Cancel、批量等待导出Cancel、活动导出Cancel、传输中Command-Q超时取消退出，以及及时恢复子进程后的排空退出。故障注入只暂停本次隔离库拥有的CLI，应用保持响应；90秒上限自动恢复。各取消场景均未发布未完成目标，等待项未启动，私有staging清理。应用退出通过外部进程观察确认，观察先于任何可能重新启动应用的AX调用。另一次尝试因进程检查的执行审批延迟而超过5秒，按超时场景记录，没有将其记为正常排空。

Finder选择归档后使用Open With指定r3候选。冷打开先显示内嵌工具链检查，之后发布ui-first；运行中打开ui-second显示实际进度行，之后发布第二台。没有改变系统默认关联。两个16GiB盘的源/目标完整SHA256相等，两个源归档SHA256保持，最终无import staging。两台夹具均未启动。批量导出观察到第一台正在导出和第二台等待导出；分别取消后均恢复已停止，隔离导出目录为空。

真实旧VM的默认system-tar导入完成：64GiB Disk.img与另外七个持久文件逐一完整SHA256匹配，原VM和输入归档保持，无import staging，未启动VM。native两次真实导入均触及4GiB保留量并退出130，未发布。源盘分配约23.3GiB，system-tar目标约62GiB；分配差异原因未查明，细节与已检查的位置见`T60_archive_allocation_20261021.md`。

新增独立正式`RealCLISparseTests`并纳入`scripts/run_launchpad_cli_tests.sh`。新/旧具名签名候选分别9项/4 suites通过（31.013秒/18.575秒），其中native 1GiB稀疏盘源/目标均16KiB分配、完整摘要相等，两个硬链接共享inode。该用例不替代真实64GiB native验收。最终完整LaunchpadKit报告228项/52 suites、10.741秒通过，11项按配置跳过；其中9项真实CLI随后在两个具名候选上显式执行，另2项烟测未执行。生产归档实现未因分配量猜测修改，既有Core441项及Python62+7项结论保持其原范围。

真实native后续导入容量预检改为逻辑payload上界加4GiB，需73,766,043,199字节。当前已有已验证system-tar测试副本占约62GiB，已请求用户确认清理该具名副本；未删除。source VM、归档和所有验证结果保留。native失败留下的空目标目录已改名保留，不覆盖旧结果。

证据：`evidence/T60-resume-20261021/manifest.json`。GUI与默认真实往返限制已消除；native真实大盘、实际create/restore退出和更广历史组合继续明确为未验证，T60不提前登记accepted。没有提交、推送、启动真实VM或修改冻结DSC验收程序。

## 2026-10-21：批准清理后完成native真实往返

用户批准删除本次已完成验证的`import-system-tar/restored`测试副本，实际仅删除该具名目录；原VM、归档及system-tar完整结果保留。空闲空间恢复至77.824GB后，通过73.766GB保守预检，使用同一r3签名CLI和同一归档完成native真实导入。

最终两个后端均完成具名旧VM的归档往返：64GiB Disk.img及另外七个持久文件逐一完整SHA256一致，原VM与归档摘要保持，无import staging，未启动VM。native本次目标盘分配29,551,001,600字节，运行采样最低空闲47,923,200,000字节。该结果消除了本次native大盘容量阻塞；没有修改生产归档实现，也没有把分配量差异写成已查明或已修复。

本轮指定矩阵已完成：最终r3 GUI等待/活动导入及导出取消、传输中Quit超时/排空、Finder冷/热打开；两个具名签名CLI各9项；受控创建子进程组/日志退出回归；真实停机旧VM的native导出后由system-tar和native分别导入并比较完整摘要。签名候选及冻结DSC输入复查保持。当前native测试副本保留供检查，没有继续清理其他数据，也没有提交、推送或发布。

验证限制继续保留：本轮不证明导入后启动、实际restore阶段中的AppKit退出、全部历史Bundle组合、跨主机文件系统或任意并发恶意写入。T60的历史accepted状态不由本轮代替人审；当前实现及上述具名矩阵可提交评审。最终证据：`evidence/T60-final-20261021/manifest.json`。
