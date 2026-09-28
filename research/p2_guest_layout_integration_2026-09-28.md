# P2 第五批：预签名客户机载荷与资源布局

日期：2026-09-28。上一批 Restore 已提交为 `f546d2f`。本批根据固定上游 `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3` 的 guest-resources 布局，适配本地 daemon 构建、安装和更新路径。本批与第六批一并提交。

## 范围与映射

| 对象 | 本批行为 |
| --- | --- |
| 开发树载荷 | `make vphoned` 构建并签名到 `.build/guest`；`make build` 调用同一脚本 |
| 分发载荷 | `Contents/Resources/guest-resources`，包含 vphoned、vphoned-less、launchd plist、entitlements 策略及 manifest |
| 普通/dev/JB/EXP 安装 | 共用预签名 vphoned；普通/dev 脚本不再在安装阶段编译或重新签名 daemon，JB/EXP 通过其基底安装获得该载荷 |
| less 安装 | 预先以 `-DLESS=1` 构建 vphoned-less，Swift 文件系统安装器直接复制该载荷 |
| 宿主自动更新 | 根据变体选取同一预签名载荷；显式 `--vphoned-bin` 仍可覆盖；`vm launch --project-root` 选出的载荷路径传给子进程 |
| VM 暂存副本 | `.vphoned.signed` 继续用于兼容；不作为默认分发来源，不从损坏 app 回退到旧副本 |
| 资源检查 | `resources --json` 输出宿主资源根目录及普通/less 载荷路径；原有纯文本输出保持 |
| 本地 capability | 保留当前 Objective-C daemon、vsock 1337 协议、签名权限和原有 launchd 配置 |

上游 daemon 使用 SwiftNIO HTTP/WebSocket，监听 vsock 1339，并有 proxy/I/O worker 退出联动。本地宿主仍使用已有协议，因此本批没有替换 daemon 的协议或进程结构。后续需要将宿主 API、鉴权、事件、进程监控与退出行为成套迁入，不能仅替换 daemon 二进制。

## 构建检查

此前 `.build/vphoned.signed` 的 LC_BUILD_VERSION 显示 IOS/minos 26.4，构建命令未显式指定 deployment target。本批为普通和 less 两个目标显式传入 `-miphoneos-version-min=15.0`，且构建时强制重编译，避免沿用旧宏或旧版本标记的产物。

`check_guest_payloads.py` 在开发产物和最终 app 上检查：

- 普通文件、非符号链接、可执行位和固定载荷清单。
- 仅 arm64 架构，平台 IOS，deployment target 15.0。
- 未定义符号中不含 `_swift_initBorrow`。
- `ldid -e` 读取的 entitlements 与本地构建策略一致。
- launchd ProgramArguments 指向 `/usr/bin/vphoned`。
- manifest 中记录的 SHA-256 与实际文件一致。

这些检查不验证客户机中的动态链接、API 可用性或实际运行，也不证明支持所有 iOS 15+ 系统。签名仍使用本地原有 ldid 和证书；宿主 `codesign --verify` 对该客户机证书报告 `CSSMERR_TP_NOT_TRUSTED`，因此本记录仅声称签名构建及 entitlements 读取/比对通过，不声称客户机证书获得 macOS 信任。完整 app 的宿主签名另外由现有 bundle 检查验证。

包内不再复制 `scripts/vphoned/vphoned` 未签名产物。其他本地资源继续保留；guest dylibs、GPU compiler plugin、vphone-vm、vphone-escalator 及 Launchpad/helper 布局尚未迁入。

## 验证

| 检查 | 结果与范围 |
| --- | --- |
| guest 交叉编译 | 普通与 less 均通过；IOS/arm64/minos 15.0、entitlements、无 `_swift_initBorrow` 检查通过 |
| 初轮专项 | Python 6 项、Swift 26 项通过 |
| 缓存专项 | 补齐载荷夹具后 10 项通过 |
| 完整回归 | `make test` 退出 0；Python 375 项；Swift Testing 658 项、90 suites；XCTest 145 项，3 项跳过，0 失败 |
| 最后路径传递变更 | 完整回归后，增加资源目录向子进程传递的覆盖；相关 Swift 15 项、2 suites 通过，包括普通/less 暂存和 DFU/no-vphoned 参数路径 |
| 内存回归 | 两条 1 GiB 归档传输路径通过；file/producer 峰值 RSS 为 8,699,904 / 8,962,048 字节 |
| 构建 | `make build` 及最终 `zsh scripts/build.sh --no-vphoned` 均退出 0；完整 app 资源、宿主签名、entitlements 和 guest manifest 检查通过 |
| CLI 定位 | 临时 app 使用 debug 可执行文件，从外部 cwd 通过绝对路径、符号链接和 PATH 启动，三种方式均解析到同一包内 guest-resources |
| 安装夹具 | 从实际 app 加载 CFW helper，复制到临时普通目录；安装文件、VM 暂存副本和包内更新源 SHA-256 一致 |
| 损坏拒绝 | 临时载荷追加字节后，manifest 检查拒绝通过 |
| 来源快照 | 23 个本地变更文件和 6 个固定上游参考文件；包内载荷 SHA-256 与开发产物 manifest 一致 |

首轮完整 Python 回归有 6 个缓存测试失败：测试复制了安装脚本，但没有新增的预签名载荷夹具，安装器在缓存步骤之前退出。补齐夹具后专项和完整回归通过；未放宽安装器的载荷缺失检查。最终资源路径传递变更发生在完整 Swift 编译之后，因此单独重跑受影响套件，不能将最后新增的测试计入前述 658 项。

现有 camera 源码产生 packed member/atomic alignment 编译警告，本批没有修改这些实现。签名 app 的 VM 执行准入和客户机行为未重新验证；CLI 定位夹具使用 debug 可执行文件。

来源映射与本批文件快照见 [来源清单](p2_guest_layout_sources_2026-09-28.json)。日志和临时夹具输出位于 `research/artifacts/p2-guest-layout-2026-09-28/`（Git 忽略）。本批没有启动、恢复或导入真实 VM，没有挂载真实客户机磁盘或向客户机安装载荷。P1c 真实导入及导入后启动继续跳过。P2 保持部分完成。
