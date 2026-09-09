# A2/B1/B2 与触控评审修复记录

## 范围与执行顺序

依据两轮评审及用户确认，在当前分支修复。本节所列 1–5 项执行时 B3 尚未开始；B3 已于 2026-09-09 实现，记录见文末「B3 停止目标身份复核（2026-09-09）」。保持目录 inode `flock` 协议，不修改二进制补丁。

1. CFW：限制属主恢复范围；启动与恢复属主前检查 VM 目录内的挂载；使用 attach plist 识别基础设备；解析失败保留原始记录；普通卸载最多尝试三次，失败时不分离基础设备、不翻转快照。
2. 缓存：区分已确认的无效元数据与工具、解析错误；后者保留缓存并停止；输出不含 AEA 密钥的错误；验证真实 SystemOS 专用副本。
3. 锁：运行记录写失败只告警，继续持锁；测试只读 bundle 导出、记录路径不可写、同一 VM 两个 Shell 安装入口互斥；可选固件清理失败不阻止后续步骤。
4. 触控：手势开始时固定注入路径与连接代次；断连后丢弃该手势后续事件；来宾会话结束时释放触点；禁止孤立 move/up 创建触点。
5. 完成快速测试、原生测试、主机及来宾构建；修正研究文档路径和证据限制。真实来宾交互与完整 CFW 安装分别记录，不能由单元测试替代。

## 实现与测试文件

- [CFW 驱动](../scripts/cfw_install_host.sh)、[入口回归](../tests/test_cfw_host_isolation.py)、[原生挂载回归](../tests/cfw_host_mount_native.py)。
- [缓存](../scripts/cache_systemos.py)、[缓存回归](../tests/test_systemos_cache.py)、[原生镜像验证](../tests/systemos_cache_native.py)。
- [Swift 锁](../sources/VPhoneCore/VPhoneVMLock.swift)、[Python 锁](../scripts/vm_lock.py)、[Swift 回归](../tests/VPhoneCoreTests/VMLockTests.swift)、[Python 回归](../tests/test_vm_lock.py)。
- [手势路由](../sources/vphone-cli/VPhoneTouchRoute.swift)、[路由回归](../tests/VPhoneCLITests/TouchRouteTests.swift)、[来宾 HID](../scripts/vphoned/vphoned_hid.m)、[IOKit 边界测试](../tests/test_guest_touch.py)。

## 缓存行为与真实镜像证据

校验仅确认工具可识别的文件系统及分区容量范围，不确认文件内容完整性，不确认缓存与源固件版本一致。

明确的空文件、加密标志、非法容量、分区越界、无可识别文件系统会触发重建。`hdiutil` 返回非零、plist 无法解析、预期键缺失或类型不符时，无法确定缓存损坏，保留缓存并停止。截断镜像可能触发工具失败，因此不能概括为所有截断均自动重建。

已在临时目录复制并校验以下两个实际文件；临时副本均已清理，未挂载 VM 磁盘：

| 输入 | 大小 | SHA-256（副本） | 结果 |
| --- | --- | --- | --- |
| `vm-2607/.cfw_temp/CryptexSystemOS.dmg` | 4,951,375,872 字节 | `9f884b58c33071a164c4242a8610947a95f1b35cdd4131de136f4f55d4747d7e` | 通过 |
| `vm-2607-rig2/iPhone17,3_26.1_23B85_Restore/043-54303-126.dmg.aea` | 4,951,375,872 字节 | `2bc28dbe8305a392ffd75e5fdfb5a904ce389c14296742b94dd00cced28f38dd` | 通过，输入已解密 |

该固件路径由 `iPhone-BuildManifest.plist` 的 `cryptex-paths` 解析结果确认。两者 `imageinfo` 均返回：`partition-scheme=none`、`block-size=512`、`partition-start=0`、`partition-length=9670656`、`partition-hint=Apple_APFS`、`partition-filesystems={APFS: Untitled}`。本次未验证 Apple FCS 密钥获取；两个文件哈希不同，未将缓存等同于原始输入。

复现方式：

```sh
.venv/bin/python3 tests/systemos_cache_native.py
.venv/bin/python3 tests/systemos_cache_native.py --firmware-source /path/to/SystemOS.dmg.aea
.venv/bin/python3 tests/cfw_host_mount_native.py
make test
make vphoned
make build
```

原生脚本须能访问 macOS DiskImages 服务。`--firmware-source` 只向临时目录输出，不改输入。原生测试不会被默认 unittest 收集。

## CFW 失败状态与恢复限制

安装会同时修改 System 卷和数据卷。清理失败且未翻转 System 快照时，已有数据卷修改不会回滚；可能形成旧 System 根与已修改数据卷的混合状态。失败不代表干净回滚。

恢复步骤：保留终端输出及 `.cfw_mount.*/attach.log`；用 `hdiutil info -plist` 和 `mount` 核对镜像、设备、挂载路径的对应关系；停止占用本次挂载的操作，然后普通卸载相关卷和镜像。无法确认设备归属时不得按猜测分离设备。确认 VM 目录下无残留挂载后，使用原 variant 重新运行 `cfw_install_host.sh`。这会重新执行安装，不是从失败阶段继续；完整的部分安装重跑仍未实机验证。不要在卷挂载期间直接运行离线快照工具。

驱动不强制卸载、不删除残留挂载目录内的数据；未知 attach 输出无法确认设备时保留记录并报错。未挂载的旧空目录不会自动清理。

清理的致命条件只包括卷卸载失败和镜像分离失败。所有挂载释放且镜像分离后，目录删除为尽力而为：`.cfw_mount.*` 内出现普通文件时保留该目录并输出 `[!]` 警告，安装继续翻转快照并以退出码 0 结束。安装完成后的属主恢复不再是致命断言：此时 VM 目录下若存在与本次无关的挂载，脚本跳过 `chown` 并输出手动恢复命令，退出码仍为 0。回归：`test_stray_file_in_mount_dir_is_retained_without_failing_install`、`test_late_mount_beneath_vm_only_skips_ownership_restore`；`test_ownership_restoration_never_recurses_over_bundle` 现由假安装器创建 `.cfw_temp` 和 `cfw_input`，断言 `chown -Rx` 只作用于这两个目录。以上三项在修复前脚本上前两项失败。

## 触控验证边界

路由测试覆盖原生手势中来宾连接、来宾手势中断连及重连、结束后新手势。Objective-C 测试直接编译实际 HID 实现，替换 IOKit 函数边界，确认释放事件使用最后坐标、重复 reset 不产生额外事件、孤立 move/up 被忽略。它不证明 BackBoard 接收或显示触控结果。

来宾新增 `vp_hid_touch_reset`，必须部署新 `vphoned` 才有会话结束释放行为。现有运行中的 `vm-2607` 有健康监控，本次未重启、未部署或注入触控。26.x 真实点击、拖动、边缘手势仍需验证；来宾协议仍不携带 VZ `swipeAim`，不能宣称两条路径等价。

### 26.x 来宾路径实机验证（2026-09-08）

实验设置：VM `rig-baseline`（iPhone17,3，iOS 26.6.1 + cloudOS 26.4，exp 变体），`vm launch rig-baseline -vv`，主机 macOS 26.5 25F71，`amfidont` 已运行。启动后主机按哈希把新构建的 `vphoned`（sha256 `99b4e493…`，含 `vp_hid_touch_reset`）推入来宾；`file_get` 取回 `/var/root/Library/Caches/vphoned` 与主机 `.build/vphoned.signed` 哈希一致，来宾进程 06:43:42 重启，握手 caps 含 `touch`。路由证据：`useGuestTouchInjection` 只取决于连接状态与 `touch` 能力，桥接 `shell` 命令可用即连接成立；启动器 stdout 重定向到文件后被缓冲，验证期间 `guest-side touch injection enabled` 行未出现；`vm stop rig-baseline` 停止 VM 后日志刷出，两次握手（vphoned 推送前后）各记录一行 `[control] guest-side touch injection enabled (iOS 26.6.1)`，第二行紧随含 `touch` 的 caps 握手行。来宾路径生效有日志直接证据。手势通过 `vphone.sock` 的 `tap`/`swipe` 注入，经 `mouseDown`/`mouseDragged`/`mouseUp` 进入同一触控路由；判定依据为 `screenshot` 全分辨率截图。

| 手势 | 输入 | 结果 |
| --- | --- | --- |
| 点按（休眠屏幕） | tap (645,1400) | 无反应；截图与 4 分钟前逐字节相同。电源键唤醒后时钟更新。来宾路径的点按不触发轻点唤醒 |
| 上滑解锁 | swipe (645,2720)→(645,1000) 250ms | 锁屏进入主屏幕 |
| 点按按钮 | tap 弹窗"以后" | 弹窗关闭 |
| 点按图标 | tap 设置 | 设置应用打开 |
| 拖动滚动 | swipe (645,2200)→(645,900) 300ms | 设置列表滚动 |
| 顶部右侧下滑 | swipe (1150,5)→(1150,1400) 300ms | 控制中心打开 |
| 底部边缘上滑回主屏 | (645,2790)→(645,1600) 250ms；(645,2795)→(645,1300) 150ms；(645,2795)→(645,1800) 600ms | 第一次只滚动列表，后两次无任何变化，均未回到主屏 |
| home 键 | key home | 回到主屏幕 |

结论：26.x 来宾路径的点按、拖动、顶部边缘手势已验证；底部边缘回主屏手势未触发，原因未查明。待验证假设：归一化坐标在底部边缘处未落入系统手势识别区；来宾 HID 事件缺少原生路径携带的 `swipeAim` 或边缘属性。原生 VZ 路径在同一来宾上未做对照，不能判断该差异是否为来宾路径独有。 停止方式为 `vm stop` 发送 SIGINT，启动器最后一行为 `Stopped with error: VZErrorDomain Code=1 "The virtual machine stopped unexpectedly."`，日志中未出现 `SIGINT — shutting down` 行；`vm stop` 用 `lsof -t -- Disk.img` 选取目标，本次得到的 pid 80614 不属于 `ps` 列出的两个 vphone-cli 进程（启动器 80577、GUI 80612）；推断 SIGINT 发给了 Virtualization 框架持有磁盘镜像的 VM 辅助进程，GUI 进程因此收到 `didStopWithError` 而非执行自身的 SIGINT 关机路径。该推断待在下次运行时用 `lsof -- Disk.img` 与 `ps -o ppid` 核对。`app_foreground` 在该来宾上始终返回 `source=unknown`，不能作为判定依据。

## 证据与文档可移植性

历史 231/237 是当时 Swift 与 Python 合计，不是当前 Python 用例数。原始 `research/artifacts/` 日志被 Git 忽略，存在与否取决于工作区，不保证其他机器可访问。本文保存关键输入、哈希、命令、结果与限制；历史文档链接改为仓库相对路径。历史测试结果保留原日期，不替换为当前计数。

## 已确认的运行限制

`make build` 与 `make vphoned` 成功，主机 release 与 app 的 `codesign --verify --strict` 均通过。但两者执行 `--help` 均返回 `-9`（SIGKILL），stdout 和 stderr 均为空。原因已查明：验收会话从内核日志取得 `AMFI: Code has restricted entitlements, but the validation of its code signature failed` 与 `AMFI: hook..execve() killing zsh: Attempt to execute completely unsigned code`；本机 `csrutil status` 为 Custom Configuration，`pgrep amfidont` 为空，即 README Option 2 所需的放行守护进程未运行。ad-hoc 签名无法满足 `com.apple.private.virtualization` 等受限权限，AMFI 在 execve 阶段终止进程，因此没有输出。这不是代码缺陷。2026-09-08 后续会话再次执行 release `--help` 得到退出码 137，`amfidont` 仍未运行；该会话的 `log show` 未检索到上述 AMFI 行，日志原文以验收会话记录为准。放行方式：以 root 运行 `scripts/start_amfidont_for_vphone.sh`（或 `make amfidont_allow_vphone`），守护进程按 `--path` 前缀匹配，不随开机启动。2026-09-08 已获批准并以 root 启动该守护进程（`--path` 项目根，两个 cdhash，`--spoof-apple`），随后 release 与 app 的 `--help` 均返回 0。守护进程重启后失效。此前 B2 已记录同类现象，本次未修改系统安全设置或移除生产二进制私有权限来绕过它。26.x 真实触控与完整 CFW 安装在本节记录时仍未完成；B3 已于 2026-09-09 实现（见文末「B3 停止目标身份复核（2026-09-09）」），其实机验证已部分完成（同节「实机验证（2026-09-09）」）。

原生 attach 测试曾发现 APFS plist 同时列出物理磁盘与合成容器。解析现优先选取 `GUID_partition_scheme` 等分区表实体；无分区表时只有唯一基础设备才接受，歧义时保留输出并停止。新增回归覆盖该实际输出形状。测试失败留下的临时设备已通过 `hdiutil info -plist` 确认归属并普通分离；原生测试也已补充异常退出后的镜像清理。

## 最终验证结果

| 验证 | 结果 |
| --- | --- |
| `make test` | 退出 0：Python 53、Swift Testing 196、XCTest 20，共 269 项通过 |
| `make test_python`（2026-09-08 cleanup/属主修复后） | 退出 0：Python 55 项通过，新增 2 项主机驱动回归；Swift 集未重跑 |
| 同一 VM Shell 入口及 CFW 回归 | 13 项通过，已包含在 Python 53 项内 |
| 原生 APFS/AEA | 通过；测试密钥解密、工具失败时保留缓存、错误输出不发布缓存 |
| 真实已解密 SystemOS | 上表两个专用副本通过；未验证 Apple 密钥获取 |
| 原生 APFS 挂载清理 | 通过；其他任务的挂载保留；退出 37 保留；真实 attach plist 识别物理磁盘并分离 |
| 来宾 HID 回归 | 通过，已包含在 Python 53 项内；IOKit 边界替身，不代表真实交互验证 |
| `make vphoned` | 退出 0，iOS arm64 交叉编译与 ldid 签名完成 |
| `make build` | 退出 0，release 与 app 构建完成 |
| 主机 `codesign --verify --strict` | release 与 app 均退出 0 |
| 四个修改后安装脚本 `zsh -n`、`git diff --check` | 通过 |
| 签名主机程序 `--help` | release 与 app 均 SIGKILL，返回 -9，无输出；原因为 AMFI 拒绝受限权限的 ad-hoc 签名且 `amfidont` 未运行，见「已确认的运行限制」 |

构建仍报告既有 `VPhoneMenuRecord.swift` 的 `shouldReveal` 未使用警告；本次未修改该文件。快速测试不包含固件夹具集，不能据此宣称固件补丁验证通过。

原始日志保存在当前工作区被 Git 忽略的 `research/artifacts/review-fixes-2026-09-08/`，其他 checkout 不保证具有这些文件。以上结果与样本元数据直接保存在本跟踪文档中，便于跨机器核对。

## `vm stop` 目标进程选取修复（2026-09-08）

问题：`vm stop` 用 `lsof -t -- <bundle>/Disk.img` 选取信号目标。磁盘镜像由 Virtualization 框架的 VM 辅助进程打开，不由 vphone-cli 打开，因此该命令把 SIGINT 发给辅助进程。现象：GUI/引导进程收到 `didStopWithError`，输出 `Stopped with error: VZErrorDomain Code=1 "The virtual machine stopped unexpectedly."` 并以失败退出，其自身 SIGINT 处理路径（打印 `[vphone] SIGINT — shutting down` 后 `NSApp.terminate`）不执行。本节修复该选取方式；上文「26.x 来宾路径实机验证」记录的同一现象与此为同一问题。

修复：

1. 新增 [`VPhoneBootProcessLocator`](../sources/VPhoneCore/VPhoneLaunchLayout.swift)。输入 `ps -axo pid=,command=` 输出与 bundle 的 `config.plist` 路径，输出命令行为 vphone-cli 且含 `--config <该路径>`（或 `--config=<该路径>`）的 pid，去重并排序。可执行文件按路径末段等于 `vphone-cli` 判定，覆盖 `.build/.../vphone-cli` 与 `vPhone.app/Contents/MacOS/vphone-cli`。路径按原样、标准化、符号链接解析三种写法比对；`resolvingSymlinksInPath()` 在末段不存在时不解析，故额外比对「父目录解析后 + 原末段」一种写法。函数为纯字符串到 pid 数组，可单元测试。
2. 新增 [`VPhoneVMLockProbe.isLockHeld`](../sources/VPhoneCore/VPhoneVMLock.swift)：直接以 `O_RDONLY|O_DIRECTORY` 打开 bundle 目录并尝试 `flock(LOCK_EX|LOCK_NB)`，成功则立即释放并判定未运行。不使用 `VPhoneVMLock` 探测，因为获取该锁会用探测进程改写 `.vphone-runtime.json`。
3. [`VPhoneVMStopCommand`](../sources/vphone-cli/VPhoneVMLaunchCLI.swift) 移除 `lsof` 调用：先用上述 flock 探测判定运行状态，未持锁时输出 `<name>: not running`；持锁时用 `ps` 定位目标。运行记录 `.vphone-runtime.json` 只作为佐证：其 `pid` 仅在 `operation` 为 `boot`/`dfu`、`kill(pid, 0)` 成活且 `ps` 同样确认该 pid 为本 bundle 的 `--config` 进程时才算目标，此条件下该 pid 已在 `ps` 结果内，故记录不新增目标，仅用于「持锁但无目标」时说明持锁方（例如 export 等其他操作），此时输出错误并以非零码退出，不发送任何信号。目标存在时发送 SIGINT，按 `--timeout` 秒轮询 `kill(pid, 0)`（`ESRCH` 视为已退出），超时后对存活者发送 SIGKILL。输出格式不变。
4. `boot`/`dfu` 两个 operation 字符串改为 [`VPhoneVMRuntimeState`](../sources/VPhoneCore/VPhoneVMRuntimeState.swift) 常量，并新增 `isBootOperation` 与只读的 `read(in:)`；`VPhoneAppDelegate` 取锁处改用同一常量。SIGINT 处理本身未修改。

`VPhoneLsof` 保留（其单元测试仍在），当前无调用方。

验证：

| 验证 | 结果 |
| --- | --- |
| `make build` | 退出 0，release 与 app 构建并签名完成 |
| `swift test --filter LaunchLayoutTests` | 12 项通过（新增 5 项定位器用例：命中 `--config`、忽略其他 bundle 与仅提及路径的进程、忽略 `vm launch` 启动器行、`.app` 内二进制与 `--config=` 形式、去重排序与畸形行、符号链接路径） |
| `swift test --filter VMLockTests` | 10 项通过 |

实机验证（主机 macOS 26.5 25F71，`amfidont` 运行中 pid 79216，VM `rig-baseline`）：`vm launch rig-baseline --headless -vv` 输出重定向到文件。`ps` 显示启动器 pid 90083、引导进程 pid 90117（`.build/arm64-apple-macosx/release/vphone-cli --config /Users/kolar/.vphone/VMs/rig-baseline/config.plist --headless`）；`lsof -t -- Disk.img` 得到 pid 90118，其命令行为 `/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine`。这直接证实磁盘镜像持有者是框架辅助进程而非 vphone-cli，上文「待核对」的推断由此确认。`.vphone-runtime.json` 记录 `pid 90117`、`operation "boot"`。`vm stop rig-baseline` 输出 `rig-baseline: sending SIGINT to 90117` 与 `rig-baseline: stopped`，退出 0；未出现 force-killing。停止后日志最后的框架行为 `[vphone] SIGINT — shutting down`，日志中无 `Stopped with error`；启动器与引导进程均已退出，`lsof -- Disk.img` 无输出，`Virtualization.VirtualMachine` 辅助进程消失；再次执行 `vm stop rig-baseline` 输出 `rig-baseline: not running`。

未验证项：`--timeout` 超时后的 SIGKILL 分支、`dfu` 引导的停止、`.app` 内二进制的实机停止、「持锁但无引导目标」的错误分支均只有单元或代码级依据，未实机触发。本次运行前已存在的 `com.apple.Virtualization.EventTap` 进程（pid 80619，属于修复前那次会话）在本次停止后仍存在，本次未处理；其残留原因未查明。引导进程 stdout 重定向到文件时为块缓冲，`[vphone] VM started` 等 `print` 行只在进程退出后刷出，验证期间只能用 `ps` 与 `FileHandle` 直写的 `[vphone] VM lock acquired` 判断进度。

## 底部边缘回主屏手势：原生 VZ 路径与来宾路径对照（2026-09-09）

本节回答上文「26.x 来宾路径实机验证」留下的问题：底部边缘上滑回主屏失败是否为来宾 HID 注入路径独有。结论是不独有：两条路径在同一来宾上都不触发该手势。原因仍未查明。

### 实验设置

VM `rig-baseline`（iPhone17,3，iOS 26.6.1，exp 变体），`screenConfig` 为 `width=1290`、`height=2796`、`scale=3`，即 `VZVirtualMachineView` 的 `bounds` 为 430x932 点。主机 `amfidont` 运行中。全部手势通过 `~/.vphone/VMs/rig-baseline/vphone.sock` 的 `tap`/`swipe` 注入，判定依据为 `screenshot` 写出的全分辨率 PNG 文件。

两次启动：

1. `vm launch rig-baseline --no-vphoned -vv`。已确认：该模式下桥接 socket 仍然监听（`[hostctl] listening on …/vphone.sock`），`tap`/`swipe`/`screenshot` 可用且走原生路径；`key`、`type`、`shell`、`file_*`、`app_*` 不可用，因为 `--no-vphoned` 不配置 vsock 设备（`sources/vphone-cli/VPhoneVirtualMachine.swift:244`），`VPhoneHostControl` 的这些分支要求 `control.isConnected`（`sources/vphone-cli/VPhoneHostControl.swift:435`、`494`、`542`）。该次启动未取得有效手势数据：来宾到达锁屏后显示休眠，三次截图逐字节相同（sha256 `8f62d607…`），锁屏时钟停在 08:42 而来宾日志已到 08:43:39，可判定为陈旧帧；该模式下无法用 `key power` 唤醒，`osascript` 向 VM 窗口发送按键被系统拒绝（“osascript 不允许发送按键”，未授予辅助功能权限）。
2. `vm launch rig-baseline -vv`（正常启动）。用 `key power` 唤醒、来宾路径解锁并打开「设置」后，通过来宾 `shell` 启动后台循环 `killall -9 vphoned`（间隔 0.2 s，两段共约 250 s），使 `VPhoneControl.isConnected` 为假。此时 `touchSession` 为 nil（`sources/vphone-cli/VPhoneControl.swift:41`），`VPhoneTouchRoute` 在手势起点把该手势固定到 `.native`（`sources/vphone-cli/VPhoneTouchRoute.swift:11`），因此同一 bridge 的 `tap`/`swipe` 走 `_VZTouch` 原生路径。循环期间 `shell` 与 `key` 返回 `guest not connected`，与 `touchSession` 的判定条件同源，可作为路径切换的直接证据。循环结束后 launchd 恢复 vphoned，来宾路径恢复，日志共记录 3 行 `[control] guest-side touch injection enabled (iOS 26.6.1)`，握手 caps 含 `touch`。

启动器 stdout 重定向到文件时为块缓冲，`[control]`、`[vphone]` 行只在进程退出后刷出；验证期间的路径判定依据为 socket 响应，日志用于事后核对。

### 结果

应用为「设置」，起点 x=645；「回主屏」指截图变为主屏幕。

| 手势参数 | 来宾路径 | 原生 VZ 路径 | 原生路径 `swipeAim` |
| --- | --- | --- | --- |
| (645,2790)→(645,1600) 250 ms | 未回主屏 | 未回主屏 | 2（底部） |
| (645,2795)→(645,1300) 150 ms | 未回主屏 | 未回主屏 | 2（底部） |
| (645,2795)→(645,1800) 600 ms | 未回主屏 | 未回主屏 | 2（底部） |
| (645,2600)→(645,1000) 100 ms | 未回主屏 | 未回主屏 | 0 |
| (645,2700)→(645,300) 400 ms | 未回主屏 | 未回主屏 | 0 |
| (645,2795)→(645,2000) 400 ms | 未测 | 未回主屏 | 2（底部） |
| (645,2796)→(645,1600) 250 ms | 未回主屏 | 未回主屏 | 2（底部） |
| `key home` | 回主屏 | 不可用（需 vsock） | — |

`swipeAim` 列为按代码计算的值，不是运行时观测值：`pixelToLocal` 把像素 y 映射为视图点（`sources/vphone-cli/VPhoneVirtualMachineView.swift:171`），`hitTestEdge` 的边缘阈值为 32 点（同文件 `:324`），底部边缘码为 2（同文件 `:341`）。按 scale=3：y=2796→距底 0 点、2795→0.33 点、2790→2.0 点、2750→15.3 点、2700→32.0 点、2600→65.3 点；阈值判定为严格小于 32，故 y=2700 与 y=2600 得 0。

同时测得的对照数据（灰度缩放到 48x104 后逐像素平均绝对差，数值越大表示画面变化越大）。列表先用两次 (645,1000)→(645,2400) 300 ms 滑到顶端并静置 1.5 s，两条路径使用同一协议：

| 手势 | 来宾路径 | 原生 VZ 路径 |
| --- | --- | --- |
| 中部上滑 (645,2000)→(645,800/1200) 250–300 ms | 12.41（列表滚动） | 12.03（列表滚动） |
| 边缘上滑 (645,2790)→(645,1600) 250 ms | 0.53 | 0.49 |
| 边缘上滑 (645,2750)→(645,1550) 250 ms | 0.56 | 0.53 |

两条路径的中部上滑都使列表滚动，两条路径的底部边缘上滑都既不回主屏也不滚动列表，数值差异在同一量级。

另一项已验证事实：来宾路径的锁屏上滑解锁 (645,2790)→(645,1600) 250 ms 成功进入主屏幕。同一坐标带的上滑在锁屏上完成，在应用内不触发回主屏手势。原生路径未在锁屏上做对照（第 1 次启动因显示休眠失败）。

### 代码差异（按当前分支）

已验证的事实：

1. 两条路径使用同一归一化结果。`sendTouchEvent` 先算 `normalizeCoordinate(localPoint)`，再选择路径（`sources/vphone-cli/VPhoneVirtualMachineView.swift:256`–`:296`）：来宾分支传该值（同文件 `:263`），原生分支把同一值放入 `_VZTouch`（同文件 `:281`）。`normalizeCoordinate` 先夹到 0..1 再翻转 y（同文件 `:300`–`:318`）。因此底部边缘的坐标取值在两条路径上相同，不存在只影响其中一条的取整或夹取差异。
2. 主机侧两条路径唯一的字段差异是 `swipeAim`：原生分支传 `currentTouchSwipeAim`（同文件 `:282`），该值在 `mouseDown` 时由 `hitTestEdge` 计算一次（同文件 `:55`），`mouseDragged`/`mouseUp` 不重算；来宾协议的 `touch` 消息只含 `v`、`t`、`id`、`phase`、`x`、`y`（`sources/vphone-cli/VPhoneControl.swift:392`–`:399`），不含边缘码，也不含时间戳。
3. 上表显示带 `swipeAim=2` 的原生手势同样不回主屏。因此「来宾 HID 事件缺少 `swipeAim` 或边缘属性」不足以解释该失败：补上等价属性不能由本次数据预期修复。
4. 来宾侧事件构造（`scripts/vphoned/vphoned_hid.m:105`–`:130`、`:143`–`:164`）：父事件为 `kIOHIDDigitizerTransducerTypeHand`，子事件为一个 finger（identifier=1），两者都置 `kIOHIDEventFieldDigitizerIsDisplayIntegrated=1`（`:113`、`:118`），sender ID 固定 `0x8000000817319372`（`:126`），经 `IOHIDEventSystemClientDispatchEvent` 派发。掩码：按下为 `TOUCH|IDENTITY`，range=1、touch=1（`:149`）；移动为 `POSITION`，range=1、touch=1（`:154`）；抬起为 `TOUCH|IDENTITY`，range=0、touch=0（`:139`）。
5. 原生路径经 `_VZTouch` + `_VZMultiTouchEvent` + `_multiTouchDevice sendMultiTouchEvents:`（同上视图文件 `:277`–`:294`）到 `_VZUSBTouchScreenConfiguration`（`sources/vphone-cli/VPhoneVirtualMachine.swift:233`）。已从 dyld 共享缓存导出 `Virtualization` 并确认存在符号 `-[_VZTouch initWithView:index:phase:location:swipeAim:timestamp:]`、`-[_VZTouch swipeAim]`、`-[_VZMultiTouchDevice sendMultiTouchEvents:]`。

推断与待验证假设（本次未验证）：

1. `swipeAim` 在 VZ 内部映射到哪个 USB HID 报告字段或 IOHIDEvent 字段：未追踪，含义待确认。它是否真正到达来宾同样未验证。
2. 与 WebKit `HIDEventGenerator` 单指路径相比，来宾实现的移动事件掩码不含 `kIOHIDDigitizerEventAttribute`，finger 事件的主半径与压力为 0，父 hand 事件携带手指坐标而非 0。这些差异是否影响手势识别未验证，本次不据此改代码。
3. 由于底部边缘上滑在两条路径上都不滚动列表（对照表 0.49–0.56，与中部上滑的 12 量级明显不同），推断该区域的触点被系统层拦截而未交给应用，但回主屏手势未完成。拦截方与未完成的原因未查明。

### 结论与未完成项

底部边缘回主屏手势在原生 VZ 路径与来宾 HID 路径上都不触发，失败不是来宾路径独有，原因未查明。因此本次未修改 `vphoned` 或主机归一化代码：没有证据支持任何具体改动。已排除的假设：底部边缘归一化坐标取值差异（两条路径同值，且 y=2796 即归一化 1.0 也失败）；来宾缺少 `swipeAim`（原生带 `swipeAim=2` 同样失败）。

自动化上仍可用 `key home` 回主屏。

停止方式为 `vm stop rig-baseline`，两次都输出 `sending SIGINT to <pid>` 后 `stopped`，随后 `vm stop` 报 `not running`，`pgrep` 无残留 vphone-cli 进程。修复前会话遗留的 `com.apple.Virtualization.EventTap`（pid 80619）本次仍存在，未处理。

本次截图、启动器日志与判定脚本保存在被 Git 忽略的 `research/artifacts/touch-native-vs-guest-2026-09-09/`，其他 checkout 不保证具有这些文件。

## `com.apple.Virtualization.EventTap`（pid 80619）核查

上一节记录的「修复前会话遗留」判断经本次核查不成立。以下区分事实、推断与未查明项。

### 服务定位与功能（事实）

`/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.EventTap.xpc` 是 Virtualization.framework 附带的 XPC 服务，`CFBundleVersion` 为 259.6.4。其 `Info.plist` 只声明 `XPCService.ServiceType = User` 与 `XPCService._ProcessType = Interactive`，没有 `RunLoopType`、`_AdditionalProperties` 或任何空闲退出相关键。`ServiceType = User` 表示每个用户一个共享实例。

该二进制的未定义符号包含 `_CGEventTapCreate`、`_CGEventTapEnable`、`_CGEventCreateKeyboardEvent`、`_CGEventCreateCopy`、`_CGEventGetFlags`、`_CGEventGetIntegerValueField`、`_CGEventSetIntegerValueField`、`_CFMachPortCreateRunLoopSource`、`_IOSurfaceLookupFromXPCObject`、`__LSCopyFrontApplication`。启动时它向 `tccd.system` 请求 `kTCCServiceListenEvent` 与 `kTCCServicePostEvent`，两次回复均为 `auth_value=2`（已授权）。因此它在主机侧创建 CGEventTap，用于监听并合成键盘事件。

推断（未直接验证）：本仓库触发该连接的位置是 `VZVirtualMachineView.capturesSystemKeys = true`（`sources/vphone-cli/VPhoneWindowController.swift:29`）。依据是连接由 vphone-cli 进程自身发起，且时间点与窗口创建相近；未做开关对照实验。

### 生命周期证据（事实）

pid 80619 由 launchd 在 2026-09-08 21:43:29 按需拉起，客户端是 vphone-cli 进程本身：

| 时间 | 记录 |
| --- | --- |
| 21:43:29.641 | `vphone-cli[80612]` `activating connection: ... name=com.apple.Virtualization.EventTap` |
| 21:43:29.649 | `launchd[1]` `Successfully spawned EventTap[80619] because ipc (mach)` |
| 23:23:57.149 | `invalidated because the client process (pid 80612) either cancelled the connection or exited` |

23:23:57 是异常停止的时刻，连接失效，但进程未退出。此后的每一次启动都复用同一个 pid 80619，没有产生新实例：

| 客户端 pid | 连接建立 | 连接失效 |
| --- | --- | --- |
| 92059 | 23:42:29.183 | 23:46:29.565 |
| 92398 | 23:47:21.655 | 2026-09-09 00:01:18.040 |
| 95429 | 00:19:47.333 | 00:20:59.586 |

由此得到两点事实：

1. pid 80619 不是异常退出产生的孤儿进程，而是当前用户唯一的常驻 EventTap 实例。正常停止之所以没有留下「额外的」EventTap 进程，是因为系统本来就只维持一个实例并复用它，不是因为正常路径回收了资源。
2. 该服务在最后一个客户端断开后不自行退出。00:01:18.040 到 00:19:47.333 之间 18 分 29 秒无任何 peer 连接，进程存活；00:20:59.586 之后同样无客户端，核查结束时（累计运行 2 小时 39 分）仍存活。

### 异常路径与正常路径的对比（事实）

两条路径上 EventTap 连接都在宿主进程退出的同一毫秒级时刻失效，没有可观测差异：

- 异常路径：launchd 在 23:23:57.144 记录 `pid/80614` 域内 `com.apple.Virtualization.VirtualMachine.70C4CBF7-…[80616]` `exited due to exit(0)`；EventTap 连接在 23:23:57.149 失效。
- 正常路径：launchd 在 23:46:29.563 记录 `service inactive: com.apple.xpc.launchd.unmanaged.vphone-cli.92059`；EventTap 连接在 23:46:29.565 失效。

因此 `virtualMachine(_:didStopWithError:)` 中的 `exit(EXIT_FAILURE)`（`sources/vphone-cli/VPhoneVirtualMachine.swift:388`）与 SIGINT 处理中的 `NSApp.terminate(nil)`（`sources/vphone-cli/VPhoneAppDelegate.swift:35`）对 EventTap 连接的回收没有差别。原假设「异常 `exit()` 跳过视图拆解从而遗留 EventTap」不成立。

### 原因未查明

该服务在无客户端时不退出的具体机制未查明。可能与它持有 CGEventTap 的 `CFMachPort` run loop source 有关，也可能是 launchd 对 `ServiceType = User` 的驻留策略，本次未验证，两者都属于待验证假设。`launchctl procinfo` 需要 root，未执行。

### 资源占用与影响（事实）

`%CPU` 0.0，RSS 4752 KB，3 个线程，状态 `S`。`lsof -p 80619` 只列出自身可执行文件、`/usr/lib/dyld`、`/usr/share/icu/icudt78l.dat`、日志配置缓存和三个指向 `/dev/null` 的标准描述符，没有 socket，没有 `~/.vphone` 或仓库内的文件。未观测到它对主机键盘输入或新建 VM 窗口造成干扰；相反，00:19:47 至 00:20:59 期间它正为运行中的 `rig-baseline`（vphone-cli pid 95429）提供服务。

### 代码结论

不建议为 EventTap 增加清理代码：该进程不是本仓库代码泄漏的资源，是系统按需拉起并复用的 per-user XPC 服务，异常与正常两条停止路径对它无差异。

本次核查中发现一项与 EventTap 无关的独立问题，未修改：`guestDidStop` 的 `exit(EXIT_SUCCESS)`（`sources/vphone-cli/VPhoneVirtualMachine.swift:381`–`:383`）与 `virtualMachine(_:didStopWithError:)` 的 `exit(EXIT_FAILURE)`（同文件 `:386`–`:388`）都绕过 `applicationWillTerminate`（`sources/vphone-cli/VPhoneAppDelegate.swift:298`–`:304`），因此在来宾自行关机或 VM 报错停止时不会执行 `hostControl?.stop()` 与 `ProcessInfo.processInfo.endActivity(hostSleepActivity)`。改为 `NSApp.terminate(nil)` 可让这两个清理动作执行。本次证据不显示该问题与 EventTap 有关，仅作记录。

### 处理结果

未终止 pid 80619。原计划的 `kill 80619` 以「遗留孤儿进程」为前提，该前提经上述证据不成立：它是会被下一次启动复用的常驻共享服务，且核查期间另一会话正在反复启停 `rig-baseline`，终止存在与新连接竞争的风险。若仍需清理，在没有 vphone-cli 运行时 `kill 80619` 是可逆的，launchd 会在下一次连接时按需重新拉起。

### 复现命令

```sh
ps -axo pid,ppid,pgid,sess,etime,lstart,%cpu,rss,command -p 80619
lsof -p 80619
launchctl print pid/80619
plutil -p /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.EventTap.xpc/Contents/Info.plist
nm -u /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.EventTap.xpc/Contents/MacOS/com.apple.Virtualization.EventTap
/usr/bin/log show --start '2026-09-08 21:40:00' --end '2026-09-09 00:40:00' \
  --predicate 'process == "com.apple.Virtualization.EventTap" OR eventMessage CONTAINS "EventTap" OR eventMessage CONTAINS "event-tap"' \
  --info --debug --style compact
```

注：`log` 在 zsh 中是内建命令，须使用 `/usr/bin/log` 绝对路径。

## SIGINT 优雅关机（2026-09-09）

### 变更内容

`vm stop` 与 Ctrl+C 通过 SIGINT 通知启动进程。原实现的 SIGINT 处理只打印一行并调用 `NSApp.terminate(nil)`，`VZVirtualMachine` 不被停止，进程退出后由 Virtualization.framework 辅助进程随之消失，来宾没有关机流程，也没有文件系统卸载。

现在启动进程收到 SIGINT 后按以下顺序处理，判定逻辑集中在 [`VPhoneShutdownPolicy`/`VPhoneShutdownPlan`](../sources/VPhoneCore/VPhoneShutdownPolicy.swift)：

1. VM 未运行：直接终止。
2. vphoned 已连接且通告 `shell` 能力：通过 vsock 下发来宾关机命令，日志 `[vphone] graceful shutdown via guest power-off command over vsock`。
3. 否则 `VZVirtualMachine.canRequestStop` 为真：调用 `requestStop()`，日志 `[vphone] graceful shutdown via VZVirtualMachine.requestStop()`。
4. 两者都不可用：日志 `[vphone] no graceful shutdown path available; stopping`，直接强制停止。

进入第 2 或第 3 步后等待 `guestDidStop`，上限 `VPhoneShutdownPolicy.gracefulTimeout = 10` 秒。超时打印 `[vphone] graceful shutdown timed out; stopping`，改为调用 `VZVirtualMachine.stop(completionHandler:)`，由框架完成拆解后退出。等待期间再收到一次 SIGINT，打印 `[vphone] second SIGINT — stopping now` 并跳过剩余等待。

`vm stop --timeout` 的默认值改为 `VPhoneShutdownPolicy.defaultStopTimeout`（`gracefulTimeout` 10 秒 + `stopMargin` 10 秒 = 20 秒），保证 SIGKILL 不会落在启动进程仍在拆解的窗口内；数值关系由 `ShutdownPolicyTests` 断言。同时新增 `vm stop --force`，跳过 SIGINT 直接发送 SIGKILL。

`guestDidStop` 与 `virtualMachine(_:didStopWithError:)` 原先直接调用 `exit()`，绕过 `applicationWillTerminate`（本文档上一节记录的独立问题）。现在两者改为记录退出状态后经 `NSApp.terminate(nil)` 退出，`applicationWillTerminate` 执行 `hostControl?.stop()` 与 `endActivity(hostSleepActivity)`，并在最后 `exit(VPhoneExitStatus.pending)` 保留成功/失败状态区分。

涉及文件：[`VPhoneShutdownPolicy.swift`](../sources/VPhoneCore/VPhoneShutdownPolicy.swift)（新增）、[`VPhoneAppDelegate.swift`](../sources/vphone-cli/VPhoneAppDelegate.swift)、[`VPhoneVirtualMachine.swift`](../sources/vphone-cli/VPhoneVirtualMachine.swift)、[`VPhoneControl.swift`](../sources/vphone-cli/VPhoneControl.swift)、[`VPhoneVMLaunchCLI.swift`](../sources/vphone-cli/VPhoneVMLaunchCLI.swift)、[`ShutdownPolicyTests.swift`](../tests/VPhoneCoreTests/ShutdownPolicyTests.swift)（新增）。

### 生效的来宾关机命令

命令为 `for h in /var/jb/sbin/halt /sbin/halt /usr/sbin/halt; do [ -x "$h" ] && exec "$h"; done; exit 127`，经 vphoned 的 `shell`（`/bin/sh -c`，实际为 `/var/jb/bin/sh`，`id` 显示 `uid=0(root)`）执行。

在 `rig-baseline`（iOS 26.6.1，exp 变体，已越狱）上实测的路径存在情况：

| 路径 | 结果 |
| --- | --- |
| `/var/jb/sbin/halt` | 存在，为 `/var/jb/sbin/reboot` 的符号链接（procursus） |
| `/var/jb/sbin/shutdown` | 存在（procursus） |
| `/var/jb/usr/bin/launchctl` | 存在（procursus） |
| `/sbin/halt`、`/sbin/shutdown`、`/sbin/reboot`、`/bin/launchctl`、`/usr/bin/launchctl`、`/usr/sbin/halt` | 均不存在 |

因此该命令在带 procursus 的 jb/exp 变体上通过 `/var/jb/sbin/halt` 生效；基础 iOS 系统内不存在上述任何一个路径，命令返回 127，启动进程回退到 `requestStop()`。regular/dev 变体上的 127 回退本次未实测（这些变体的 `shell` 能力本身依赖 `/var/jb/bin/sh`）。`launchctl reboot halt` 未测试，因为 `halt` 已生效。

命令生效的证据取自来宾串口日志：

```
[vphone] SIGINT — shutting down
[vphone] graceful shutdown via guest power-off command over vsock
System shutdown initiated by: reboot[507]<-vphoned[69]
shutdown UNINITIALIZED -> COMMITTED
...
apfs_vfsop_unmount:3710: all done.  going home.  (numMountedAPFSVolumes 0)
"AppleSEPKeyStore":pid:0,:4079: Ready for System Shutdown
ApplePSCI - system off
[vphone] Guest stopped
```

`System shutdown initiated by: reboot[507]<-vphoned[69]` 表明关机由 vphoned 派生的 `reboot`（即 `halt`）触发；`numMountedAPFSVolumes 0` 表明卷已卸载。

### 测量结果

| 场景 | 命令 | 耗时 | 走过的路径 |
| --- | --- | --- | --- |
| vphoned 已连接（headless） | `vm stop rig-baseline` | 4.12 s | 来宾关机命令 → `guestDidStop` → 退出 0 |
| vphoned 已连接（带窗口） | `vm stop rig-baseline` | 4.13 s | 同上 |
| `--no-vphoned` 启动 | `vm stop rig-baseline` | 11.15 s | `requestStop()` → 10 s 超时 → 强制停止 → `[vphone] VM stopped` |
| `--no-vphoned` 启动，2 s 后第二次 SIGINT | `kill -INT` ×2 | t0 后 3 s 退出 | `requestStop()` → 第二次 SIGINT → 强制停止 |

`vm stop` 的耗时包含其 1 秒粒度的存活轮询，因此来宾关机路径的实际耗时约 3–4 秒。`gracefulTimeout` 取 10 秒即为该测量值的约 2.5 倍余量，同时使超时回退在交互式 Ctrl+C 下仍可接受。

`canRequestStop` 在该 iOS 来宾上为真，但 `requestStop()` 后来宾在 10 秒内没有关机，最终由强制停止结束。来宾不响应该请求的原因未查明（推断 iOS 侧没有对应的电源请求处理，属待验证假设）。

### 验证

- `make build` 通过。`swift test --filter 'ShutdownPolicyTests|LaunchLayoutTests|VMLockTests'`：3 个 suite、28 个测试全部通过。未修改 vphoned，未重新构建。
- 正常路径两次运行日志中均出现 `[vphone] Guest stopped`，没有 `[vphone] Stopped with error`；退出后 `ps` 中没有 `vphone-cli --config` 进程，也没有 `com.apple.Virtualization.VirtualMachine` 辅助进程；再次执行 `vm stop rig-baseline` 输出 `rig-baseline: not running`。
- 带窗口运行停止后 `~/.vphone/VMs/rig-baseline/vphone.sock` 被删除，说明 `applicationWillTerminate` 已执行；对照：更早一次用改动前的二进制、由来宾自行关机结束的运行留下了该 socket 文件。
- 本次多轮启停期间没有新增 `com.apple.Virtualization.EventTap` 进程，全程仍是同一个 pid 80619 实例（与上一节结论一致）。
- 已连接时的来宾关机请求在主机侧以 `[vphone] guest power-off request ended with: not connected to vphoned` 结束，随后来宾仍完成关机。这说明该错误是等待响应期间连接被来宾关机切断所致，不能作为“命令未送达”的判据；实现因此把传输错误视为已送达并继续等待 `guestDidStop`。

### 未验证项

- regular/dev/less 变体上的 127 回退与 `requestStop` 行为。
- 关闭 VM 窗口（非 SIGINT）退出路径。
- 强制停止失败时 `stop(completionHandler:)` 返回错误的分支。
- `vm stop --force` 未实测。

### 构建陷阱（本次遇到，非代码问题）

裸 `swift build -c release` 会重新链接 `.build/release/vphone-cli`，签名退化为 `adhoc,linker-signed` 且 entitlements 丢失；此后 `make build` 因产物比源文件新而跳过签名步骤，二进制保持无 entitlements 状态。表现为启动进程报 `[vphone] Fatal: PV=3 hardware model not supported`，而 `--help` 仍返回 0（AMFI 不再看到受限 entitlements，故不 SIGKILL），`boot_host_preflight.sh` 的 `=== Entitlements ===` 段为空。判定方法：`codesign -d -vvv .build/release/vphone-cli` 出现 `flags=0x20002(adhoc,linker-signed)`。恢复方法：删除产物后重新 `make build`（`codesign -d --entitlements -` 应列出 5 个键）。amfidont 无需重启，其 `--path` 前缀规则同时覆盖签名校验与 `isApple`（见 `amfidont/bypass_runtime.py`），与重建后的 cdhash 无关。

## B3 停止目标身份复核（2026-09-09）

对应清单 B3。上文「`vm stop` 目标进程选取修复」解决的是「信号发给哪个进程」；本节解决「升级信号前该 pid 是否还是同一个进程」和「停止是否确认成功」。

### 问题（基线 `0b52b5f`，代码级事实）

1. SIGINT 之后最长等待 `--timeout` 秒（默认 20）再对存活者发送 SIGKILL，期间不重新确认目标身份。pid 号可在该窗口内被内核分配给其他进程。
2. 存活判定为 `kill(pid, 0)`，只能判断 pid 号是否存在，不能区分原进程与复用同一号码的新进程。
3. SIGKILL 之后以及 `--force` 路径都不检查目标是否消失、bundle 锁是否释放，仍无条件输出 `<name>: stopped`。
4. 运行记录 `.vphone-runtime.json` 只用于「持锁但无引导目标」分支的错误文本，`isBootOperation` 无调用方。该记录在正常退出时不删除（锁由内核随进程退出释放），因此每次 VM 退出后都是过期记录，不能作为判据。

### 变更

1. 新增 [`VPhoneProcessIdentity`](../sources/VPhoneCore/VPhoneProcessIdentity.swift)：`(pid, startedAt, uid, isZombie)`。`VPhoneProcessInfo.identity(of:)` 通过 `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, pid)` 读取 `kinfo_proc`，`startedAt` 取 `kp_proc.p_starttime`（秒，含微秒小数）。pid 不存在时返回 nil：本机实测 `sysctl` 对不存在的 pid 返回 0 且 `size` 为 0，返回 -1（`ENOENT`/`ESRCH`）同样按不存在处理。`p_stat == SZOMB` 记为 `isZombie`——僵尸进程仍有内核记录，但不再运行，也不再持有文件和锁，停止逻辑按已退出处理。
2. 新增 [`VPhoneVMStopper`](../sources/VPhoneCore/VPhoneVMStopper.swift)：目标判定、信号发送和结果确认从 CLI 移出，依赖以闭包注入（`listTargets`、`identity`、`send`、`lockHeld`、`sleep`、`readRecord`、`diskHolders`、`report`）。生产装配仍是 `ps` + `VPhoneBootProcessLocator` 选目标、`VPhoneVMLockProbe` 判占用、`lsof` 仅列 Disk.img 持有者。结果为 `.notRunning`、`.noBootTarget(detail:)`、`.stopped(signalled:forceKilled:)`、`.failed(survivors:reason:)`。
3. 流程：
   - 未持锁直接返回 `.notRunning`。
   - 目标快照记录为 `(pid, startedAt)` 对，`identity` 返回 nil 或僵尸的 pid 直接丢弃。
   - 快照为空且持锁时返回 `.noBootTarget`，不发送任何信号；detail 取运行记录（`operation` 为 boot/dfu 时附 `instanceID`）并附上 `lsof` 得到的 Disk.img 持有者，标注为仅诊断。
   - 正常路径对快照发送 SIGINT，按 1 秒粒度轮询至 `--timeout`；存活判据是 `identity(pid)?.startedAt` 与快照相同，`startedAt` 不同、记录缺失或已成僵尸一律按已退出处理，不再收到任何信号。
   - SIGKILL 之前重新执行 `listTargets()` 并按 `(pid, startedAt)` 与快照求交集，只对交集发送 SIGKILL。`--force` 跳过 SIGINT 与等待，其快照即当次列举结果，因此不再重复列举。
   - 之后按 0.5 秒粒度、最长 3 秒轮询，直到快照内所有身份消失且 `lockHeld()` 为假才返回 `.stopped`；否则返回 `.failed`，reason 列出存活 pid、`send` 的 errno（`EPERM` 与 `ESRCH` 分别以 `strerror` 文本给出）以及锁是否仍被持有。
4. 运行记录的用法：`isBootOperation` 为真且记录的 pid 确实在本次快照内时，输出该 `instanceID`；记录本身从不新增目标。
5. [`VPhoneVMStopCommand`](../sources/vphone-cli/VPhoneVMLaunchCLI.swift) 只保留参数解析、输出和退出码，退出码取 `Outcome.exitCode`（`.notRunning`/`.stopped` 为 0，`.noBootTarget`/`.failed` 为 1）。
6. `VPhoneLsof` 恢复调用方（此前只有测试）。

### 与 `vm launch` 锁生命周期的关系

事实（代码路径）：`vm launch` 的 `stage-vphoned` 锁在其 `if` 作用域内声明，`defer { withExtendedLifetime(stagingLock) {} }` 也在同一作用域，锁在派生引导子进程之前释放；启动器在 VM 运行期间不持锁，只 `waitUntilExit`。引导进程在 `VPhoneAppDelegate.startVirtualMachine()` 自行取锁，描述符为 `O_CLOEXEC`，不被其派生的子进程继承（B2 已记录并测试）。

推断：SIGKILL 之后待释放的只有引导进程自己的 flock，内核在进程退出时释放，启动器的退出时序不影响锁释放。因此 3 秒确认窗口只需覆盖进程退出与回收的延迟。该推断由代码路径与 B2 的锁测试得出，未在实机计时验证。

### 输出

保留原有全部输出串：`not running`、`sending SIGINT to N`、`force-killing N`、`stopped`、`bundle lock is held but ... — not signalling anything`。新增两条：

| 输出 | 条件 |
| --- | --- |
| `<name>: boot instance <id>` | 运行记录为 boot/dfu，且其 pid 在本次目标快照内 |
| `<name>: stop failed: <reason>`（stderr，退出码 1） | 结果为 `.failed` |

进度行经 `report` 回调在等待之前输出，与改前的输出时序一致。

### 验证

| 验证 | 结果 |
| --- | --- |
| `swift test --filter 'VMStopTests\|LaunchLayoutTests\|VMLockTests\|ShutdownPolicyTests'` | 4 个 suite、41 项通过（其中 VMStopTests 13 项） |
| `make test` | Python unittest 55 项、Swift Testing 220 项、XCTest 20 项，共 295 项通过 |
| `make build` | 退出 0；`codesign -d --entitlements -` 列出 7 个键 |
| `git diff --check` | 无输出 |

VMStopTests 覆盖的场景：

| 场景 | 手段 | 断言 |
| --- | --- | --- |
| 定位器能识别替身引导进程 | `<tmp>/vphone-cli` 指向 `/bin/sh` 的符号链接，参数含 `--config <tmp bundle>/config.plist`，用真实 `ps` 定位 | 定位结果恰为该 pid |
| 其他程序打开 Disk.img | `/bin/sh` 子进程 `exec 3< Disk.img` 并 `trap '' INT` | 该 pid 收到的信号数为 0，结束时仍存活；仅引导替身收到 SIGINT |
| 进程不响应 SIGINT | 替身 `trap '' INT`，`--timeout` 2 秒 | 信号序列为 `[SIGINT, SIGKILL]`，结果 `.stopped`，进程已消失 |
| `--force` | 同上，`force: true` | 信号序列为 `[SIGKILL]`，`signalled` 为空 |
| 目标已退出且无人持锁 | 先 SIGKILL 替身再执行 | `.notRunning`，零信号 |
| 持锁方不是引导进程 | Python `flock` 持有者 + 指向它的 boot 运行记录 | `.noBootTarget`，detail 含该 pid 与 instanceID，零信号，退出码 1 |
| pid 被复用 | 注入 `identity`：快照时 `startedAt` 为 T，等待期间变为 T+100 | 只发送 SIGINT，无 SIGKILL，结果 `.stopped` |
| 等待期间目标离开进程列表 | 注入 `listTargets` 第二次返回空 | 只发送 SIGINT，无 SIGKILL |
| 停止失败 | 注入身份恒定、锁恒被持有 | `.failed`，survivors 含该 pid，reason 含存活与锁两项，退出码 1 |
| 信号返回 `EPERM` | 注入 `send` 恒返回 `EPERM` | reason 含 `Operation not permitted`，不含 `No such process` |
| 进程身份 API | 真实 `/bin/sleep` 子进程 | 存活时 `startedAt` 在 `now-60 ≤ t ≤ now` 内、`uid == getuid()`；回收后返回 nil |
| 结果到退出码映射 | 纯函数 | `.notRunning`/`.stopped` 为 0，`.noBootTarget`/`.failed` 为 1 |

替身引导进程的实现约束（本次确认的两点事实）：

1. 把 `/bin/sh` 复制到临时目录再执行会被 AMFI 终止（本机实测退出码 137），因此替身改用指向 `/bin/sh` 的符号链接，`execve` 解析到系统二进制，而 `ps` 中的 argv[0] 仍是符号链接路径，满足定位器「末段等于 `vphone-cli`」的条件。
2. `/bin/sh` 只有在其前台子进程也死于 SIGINT 时才终止脚本，因此需要优雅退出的替身显式写 `trap 'exit 0' INT`，与真实引导进程自装 SIGINT 处理的行为一致。

管道输出时 `ps -axo pid=,command=` 未截断（实测单行 325 字符完整输出），因此长临时路径不影响定位。

### 实机验证（2026-09-09）

环境：主机 macOS 26.5 25F71，`amfidont` 运行中（pid 79216）；VM `rig-baseline`（iOS 26.6.1，exp 变体，已越狱，bundle 内有 `.vphoned.signed`）。二进制为 `.build/arm64-apple-macosx/release/vphone-cli`，本次未重新构建、未修改源文件。每个场景独立启动一次 `vphone-cli vm launch rig-baseline --headless -vv`，stdout/stderr 重定向到文件。

观测条件（事实）：

- `--headless` 不创建 `vphone.sock`。`VPhoneHostControl` 的创建与 `start` 位于 `if !cli.noGraphics` 分支内（`sources/vphone-cli/VPhoneAppDelegate.swift:144`、`:200`–`:211`），因此 headless 下没有可用来实时探测 vphoned 连接状态的主机接口。实测 300 秒内该 socket 始终不存在。
- 引导进程 stdout 重定向到文件时为块缓冲，`[control] connected to vphoned …`、`[vphone] …` 行只在进程正常退出（`NSApp.terminate` 路径）时刷出；`[vphone] VM lock acquired` 由 `FileHandle` 直写，实时可见。来宾串口输出实时写入同一文件。
- 因此场景 1、2、5 用「`VM lock acquired` 之后再等 370–400 秒」作为「vphoned 已连接」的操作判据（上一节记录的 90 秒下限之上取余量）。该判据是假设，不是观测；事后确认见下。

判据的事后确认：场景 1 与 5 的刷出日志含 `[control] connected to vphoned v1 (…) iOS 26.6.1, caps: ["hid", …, "shell", "touch", …]`，假设成立。场景 2 因 SIGKILL 未刷出 stdout，改由来宾串口的 `System shutdown initiated by: reboot[1987]<-vphoned[69]` 确认——该行只能由 vphoned 派生的 halt 产生，说明 SIGINT 到达时 vphoned 已连接且来宾关机命令已送达。

「停止后状态」四项检查：`pgrep -fl vphone-cli` 无输出、`lsof -t -- ~/.vphone/VMs/rig-baseline/Disk.img` 无输出、`pgrep -fl com.apple.Virtualization.VirtualMachine` 无输出、再次执行 `vm stop rig-baseline` 输出 `rig-baseline: not running` 且退出码 0。

| 场景 | 命令 | 输出 | 退出码 | `time` 实耗 | 停止后状态 |
| --- | --- | --- | --- | --- | --- |
| 1 优雅回归 | `vm stop rig-baseline` | `boot instance 6090B33D-…`／`sending SIGINT to 26036`／`stopped` | 0 | 4.193 s | 四项均符合 |
| 2 SIGKILL 分支 | `vm stop rig-baseline --timeout 1` | `boot instance F405BC40-…`／`sending SIGINT to 26414`／`force-killing 26414`／`stopped` | 0 | 1.685 s | 四项均符合 |
| 3 `--force` | `vm stop rig-baseline --force` | `boot instance 590F2EAF-…`／`force-killing 26593`／`stopped` | 0 | 0.603 s | 四项均符合 |
| 4a 未运行 | `vm stop rig-baseline` | `rig-baseline: not running` | 0 | 0.011 s | — |
| 4b 持锁但无引导目标 | `vm stop rig-baseline`（Python `flock` 持有 bundle 目录） | stderr `error: rig-baseline: bundle lock is held but no vphone-cli boot process is running for it — not signalling anything` | 1 | 0.227 s | 持锁进程仍存活 |
| 5 两次强杀后复检 | `vm stop rig-baseline` | `boot instance 1A626636-…`／`sending SIGINT to 26714`／`stopped` | 0 | 4.214 s | 四项均符合 |

逐场景观测：

1. 场景 1：`ps` 中启动器 pid 26001、引导进程 pid 26036；`.vphone-runtime.json` 的 `pid` 与 `instanceID` 与输出的 `boot instance` 一致。未出现 `force-killing`。刷出日志依次为 `[vphone] SIGINT — shutting down`、`[vphone] graceful shutdown via guest power-off command over vsock`、`[control] read loop ended`、`[vphone] guest power-off request ended with: not connected to vphoned`、`[vphone] Guest stopped`；全文无 `Stopped with error`。这与上一节「SIGINT 优雅关机」记录的 4.12 s 与路径一致，B3 的目标身份改动未改变优雅路径的行为。
2. 场景 2：`--timeout 1` 触发 SIGKILL 分支。来宾串口停在 `shutdown UNPEND_REQUESTS -> DOMAIN_DEACTIVATE`，没有 `apfs_vfsop_unmount … going home` 与 `ApplePSCI - system off`，即来宾关机被中途终止（本次接受该结果）。SIGKILL 使 stdout 缓冲丢失，文件中只剩 `[vphone] VM lock acquired` 一条主机行。总耗时 1.685 s 由 1 秒 SIGINT 等待加确认轮询组成，据此推算确认窗口约 0.6 s（0.5 秒粒度的一跳），远小于 3 秒上限；锁由内核在引导进程退出时释放，未出现 `stop failed`。
3. 场景 3：`--force` 在 `VM lock acquired` 后约 28 秒执行（不等待 vphoned）。输出无 `sending SIGINT`，日志全文 `grep -c SIGINT` 为 0，与「`--force` 跳过 SIGINT 与等待」的实现一致。0.603 s 内完成确认。
4. 场景 4b：持锁方为 `python3 -c "… fcntl.flock(f, LOCK_EX|LOCK_NB); time.sleep(120)"`，对象为 bundle 目录 `~/.vphone/VMs/rig-baseline`（与 `VMLockTests` 同一写法）。`vm stop` 未发送任何信号，持锁进程在命令返回后仍存活，随后由本次验证显式终止。错误文本未附带 `instanceID` 与 Disk.img 持有者：此时 `.vphone-runtime.json` 是场景 3 留下的过期记录（其 pid 已不存在），`lsof` 也无持有者，符合「记录只作佐证、不新增目标」的实现。
5. 场景 5：经场景 2、3 两次 SIGKILL 后，VM 仍能正常引导（来宾走 `fsck` 引导任务，`nx_mount` 检查点搜索正常）。优雅停止完整走完卸载序列直到 `apfs_vfsop_unmount:3710: all done.  going home.  (numMountedAPFSVolumes 0)` 与 `ApplePSCI - system off`，日志无 `Stopped with error`。

其他观测：全程 `com.apple.Virtualization.EventTap` 始终只有既有的 pid 80619，未新增；本次未处理该进程。所有场景结束后主机上无 vphone-cli 进程、无 Virtualization 辅助进程、无 Disk.img 持有者。

### 未验证项

- `dfu` 引导的停止、`.app` 内二进制的实机停止、`.failed` 分支（`stop failed: …`、退出码 1）在实机未触发，其结论仍来自单元测试与代码路径。SIGKILL 分支与 `--force` 已于 2026-09-09 在 `rig-baseline` 上实测（见上一小节）。
- pid 复用只用注入的身份序列模拟，未在真实 pid 回绕条件下验证。
- 「所有目标已退出但 bundle 锁在 3 秒内未释放」判为 `.failed` 属保守判定：若另一入口恰在此刻取得该 bundle 的锁，也会判为失败。该情形未在实机观察到，属待验证假设。
- `ResourcesTests` 在并行执行下因 `VPHONE_ROOT` 的 `setenv`/`unsetenv` 竞争间歇失败，为既有问题，与本项无关：单独执行 `swift test --filter ResourcesTests` 6 次中 5 次失败，失败断言全部位于 `ResourcesTests.swift`。本次未修改该文件。
