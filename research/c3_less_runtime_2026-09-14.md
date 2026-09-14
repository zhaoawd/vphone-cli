# C3 less 恢复与两次启动验收（2026-09-14）

**结果：恢复返回 0，连续两轮普通启动、客户机串口命令、版本读取、跨重启文件持久性和正常关机通过。** 用户选择先完成对应运行验收，再评估清理 C3 成功产物。本项仅覆盖 iPhone/cloudOS 26.1 / 23B85、less 默认安装选项的恢复、首次启动和第二次启动；不将结果扩展为整个 F1 或 C4 完成。

## 输入与隔离

- 原始成功产物：`research/artifacts/c3-less-pipeline-2026-09-10/vm`。
- 当前代码：`70159917c200ad089205b6013ea442b18be60911`；工作区既有 Makefile 和 Markdown 预览修改保留。
- 本轮逐文件 SHA-256 清单：`research/artifacts/c3-less-runtime-2026-09-14/input-sha256.json`，共 29 个文件。
- `new-filesystem.dmg.aea` 的 SHA-256 重新计算为 `3319c2a527539606db27b0e441a5abf84a778cba7c56eeec1709a23729775b05`，与 C3 成功记录一致。
- 原目录没有 VM 配置或磁盘。恢复须使用新建的独立 VM、独立磁盘、NVRAM、SEPStorage 和机器标识；现有两个 VM 不作为恢复写入目标。
- 最新空间检查：`df -k .` 可用 41,994,000 KiB，约 40.05 GiB；这是本轮检查值，不沿用此前约 20 GiB 的结果。实际恢复峰值待测。

## 验收步骤与状态

- [x] 核对成功镜像身份并保存全目录哈希清单。
- [x] `make build` 构建与签名完成；`codesign --verify --strict` 返回 0。
- [x] 用户授权启动项目 amfidont 后，宿主帮助命令及 preflight 通过。
- [x] 创建 `vm-c3-runtime-20260914`，64 GiB 稀疏磁盘、8 CPU、8 GiB RAM；29 个 APFS 克隆文件逐个 SHA-256 校验通过。
- [x] 启动 DFU，记录实例身份，指定 ECID 恢复，退出码为 0，完整日志保留。
- [x] 记录首次普通启动的客户机连接和串口 bash；修正验收接口后完成普通启动、命令、版本和正常关机检查。
- [x] 同一磁盘和身份的连续两轮普通启动通过，并验证 Library 文件跨重启保留；均由客户机正常关机。
- [x] 原目录 29 个文件未变；验收进程已退出，无相关挂载和待恢复事务；已保存大型镜像清理候选清单。

单独出现宿主启动成功或控制端口连通不作为客户机启动成功的充分证据。恢复失败、panic、客户机不可用或清理失败均保留失败阶段，不标记验收完成。执行过程及最终结果见下文；验收后经用户授权删除两份成功 AEA，见清理结果。

## 宿主执行阻塞

`make build` 首次因沙箱禁止写 Swift ModuleCache 失败；获准在沙箱外重跑后成功，编译耗时 113.36 秒，完整记录为 `research/artifacts/c3-less-runtime-2026-09-14/build.log`。

在沙箱外执行 `.build/vphone-cli.app/Contents/MacOS/vphone-cli --help` 返回 137。14:38:47 的系统日志明确报告 `AppleMobileFileIntegrityError Code=-424`、`The file is adhoc signed but contains restricted entitlements`，并拒绝该二进制执行。日志保存在同目录 `host-policy.log`；本轮阻塞发生在 VM 启动前，不能解释为固件或客户机启动失败。由于系统日志直接确认拒绝原因，本轮不通过固件修改或多轮构建排查该限制。

项目已有 `scripts/start_amfidont_for_vphone.sh`，会使用 sudo 启动 amfidont daemon，以项目路径及当前二进制 CDHash 配置签名放行，并使用 `--spoof-apple`。本机工具存在于 `/Users/qcz3840/Library/Python/3.9/bin/amfidont`。该动作改变宿主签名校验行为；此段记录授权前阻塞，后续已获用户明确允许并执行。

本轮期间检测到 `scripts/build.sh`、`.gitignore` 和 `Package.resolved` 的外部修改；本任务未修改这些文件。D1/D2 的实现与验收不由本记录声明完成。

## 授权后的执行

用户明确允许后，项目签名放行脚本返回 0（`amfidont started`）。固定本轮宿主副本为 `research/artifacts/c3-less-runtime-2026-09-14/host.app`，其帮助命令可执行；preflight 返回 0，系统临时目录的签名对照程序仍返回 137。该结果只证明所用程序的执行条件通过。

独立 VM 位于仓库下 `vm-c3-runtime-20260914`，ECID 为 `0x93A34B540C345C69`，UDID 为 `0000FE01-93A34B540C345C69`。DFU probe 与 SHSH 获取返回 0。恢复命令通过库根目录、名称、ECID 和 UDID 指定该实例；普通启动使用 `--variant less --headless` 和不存在的自动更新文件路径，以保留镜像内的客户机程序。

元数据、宿主 SHA-256、身份、克隆校验和日志均保存在 `research/artifacts/c3-less-runtime-2026-09-14/`。恢复已返回 0，记录 iOS/cloudOS 均为 26.1（23B85）。

## 运行结果与失败记录

| 场景 | 结果 | 证据与限制 |
| --- | --- | --- |
| DFU 恢复 | 退出 0；`verify-restore` 100%；版本信息写入成功 | `restore.log`、`run-metadata.json`；恢复后的自动重启出现系统进程活动，未单独算作普通启动验收 |
| DFU 会话结束 | 宿主退出 0 | `requestStop` 超时后由框架停止；不记为客户机正常关机 |
| 首次显式普通启动 `first` | 22.181 秒连接客户机，串口出现 bash；脚本失败 | vphoned 未声明 `shell`，宿主接口明确拒绝；未执行客户机自动更新。关机请求超时后框架停止 |
| 串口复验 `first-serial` | 34.436 秒连接，串口写入与文件读回、23B85 版本通过；客户机正常关机 | `first-serial-boot.json`；通过 `shutdown -h now` 关机，宿主退出 0 |
| 临时目录持久性复验 `second-serial` | 24.218 秒连接，当前命令和版本通过；上一轮 `/var/tmp` 文件不存在，脚本失败 | 原因未查明；不将临时目录文件作为后续持久性判据，该失败记录保留 |
| 最终连续第 1 轮 `first-persistent` | 20.286 秒连接；23B85、串口写入 `/var/mobile/Library` 并读回通过；正常关机 | 宿主退出 0，日志含 `[vphone] Guest stopped`，socket 移除 |
| 最终连续第 2 轮 `second-persistent` | 26.583 秒连接；同样检查通过；上一轮 Library 文件内容一致；正常关机 | 同一磁盘、UDID/ECID；宿主退出 0，socket 移除 |

最终脚本通过串口 bash 执行唯一标识写入，再通过客户机 `file_get` 读取并逐字节比较，避免只根据串口命令回显判断执行成功。系统版本由客户机文件接口读取并解析 plist。两次正常关机均由客户机执行 `shutdown -h now`，没有使用宿主强制停止作为成功判据。

首次启动已发生，因此最终两轮称为“连续两轮复验”，不将它们重新标作恢复后的第一次启动。最终汇总为 `result.json`；初版及两次修正脚本、所有失败结果保留在同一证据目录。源码未增加或修改二进制补丁。

本轮没有验证 GUI 显示、完整触控、应用工作流、DDI、定位、相机或 Frida；不标记整个 F1 完成，也不改变 C4 的完整 less 成功路径待验收状态。

## 清理条件与保留对象

用户选定的恢复和重复启动验收已有上述证据，无需等待整个 F1 完成才能评估清理本次 C3 成功 AEA 镜像。`cleanup-candidates.json` 列出两个路径及相同 SHA-256：

1. `research/artifacts/c3-less-pipeline-2026-09-10/vm/iPhone17,3_26.1_23B85_Restore/new-filesystem.dmg.aea`
2. `vm-c3-runtime-20260914/iPhone17,3_26.1_23B85_Restore/new-filesystem.dmg.aea`

两份是 APFS 克隆，单份统计约 **9.13 GiB**，不能相加为 18.26 GiB 的可释放量。保留任一克隆可能继续占用共享块；两份都清理后的实际释放量仍须以 `df` 为准。删除后无法直接再次恢复这份成功镜像，需要重新生成；现有已恢复 VM 的普通启动使用其磁盘。

日志、报告、逐文件哈希和差异组件继续保留；本轮额外复制了全部 plist 到 `retained-manifests/`。C4 输入不在本次清理范围内。两份选定 AEA 已按后续授权删除，C3 其余文件与 `research/artifacts` 目录保留。

新建的 `vm-c3-runtime-20260914/Disk.img` 最终占用约 **14.30 GiB**，VM 已关闭。若后续用它做 F1 的 GUI/应用等检查，应保留 VM 磁盘、配置、NVRAM、SEPStorage 和身份文件；若不再使用，可另行清理这个新建实例。其用途决定与成功 AEA 镜像的删除分别记录。

最终可用空间为 19,597,396 KiB（约 **18.69 GiB**）。终态进程检查仅匹配到检查命令自身，无本轮宿主/恢复进程；`hdiutil info` 只有系统 Simulator 挂载。签名放行进程按本轮授权启动，未在结束时停止。

## 2026-09-14 授权清理结果

用户发出“开始清理”后，删除上述两个 `new-filesystem.dmg.aea` 文件。删除前持有两个 VM 目录的非阻塞排他 flock，确认无控制 socket、待恢复事务和相关镜像挂载；逐文件重新计算 SHA-256，与已验收值相等后核对 inode、设备号和大小，再删除精确路径。

| 结果 | 数值或状态 |
| --- | --- |
| 删除文件 | 两个路径，各 9,797,894,144 字节，均确认不存在 |
| 删除前可用空间 | 20,597,080 KiB，约 19.64 GiB |
| 删除后可用空间 | 30,164,888 KiB，约 28.77 GiB |
| 实测可用空间增加 | 9,567,808 KiB，约 **9.12 GiB**；为两次 `df` 的差值 |
| C3 实验目录剩余占用 | 约 9.68 GiB；其余 28 个原文件存在 |
| 保留 | 原报告、日志、哈希、Manifest、差异组件；C4 约 9.47 GiB 输入；新验收 VM 磁盘约 14.30 GiB 及身份文件 |

逐文件身份、删除结果与前后 `df` 原文保存在 `research/artifacts/c3-less-runtime-2026-09-14/cleanup-execution.json`，清理清单状态已更新为 `deleted`。此后原 C3 Restore 与验收 Restore 均缺少成功 AEA，不能直接用于再次恢复或完整组件校验；历史验证结果按执行日期保留，需要重跑时须重新生成镜像。普通 VM 启动仍使用保留的磁盘。本次未重启 VM，未修改二进制补丁。
