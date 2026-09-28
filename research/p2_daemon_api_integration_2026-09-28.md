# P2 第六批：上游 API daemon 独立构建

日期：2026-09-28。固定上游为 `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3`。本批在第五批资源布局基础上，接入上游 Swift API daemon、native proxy/I/O worker 和独立 Xcode 构建。第五、六批变更一并提交。

## 入口与范围

```sh
make daemon_api_build
```

产物位于 `.build/daemon-api-v2/candidate`。该目标不会安装、启动或激活候选 daemon，也不会将其加入默认 app。目录中的 `manifest.json` 记录 `activated: false`、`runtime_validated: false`、依赖、动态库和载荷 SHA-256。

默认 `make build`、CFW 安装及宿主自动更新继续使用第五批的普通/less Objective-C daemon。本地现有 vsock 1337 长度前缀 JSON 协议保持不变。上游候选 daemon 使用 vsock 1339 HTTP/WebSocket，health 声明 `api_version: 1`；`daemon-api-v2` 是构建目录名，不是线上协议版本。

## 迁入与适配

| 对象 | 本批结果 |
| --- | --- |
| VPhoneDaemon | 迁入固定上游 daemon/native/configuration/Xcode 工程及锁文件 |
| VCamFrameProtocol.h | 迁入候选 daemon 编译所需的共享摄像头协议头；未迁入或安装其他 guest component 实现 |
| iOS VPhoneSign | 复用本地已整合的 `sources/VPhoneSign`，独立编译为 iOS 静态库；不复制第二套 signer 实现 |
| Xcode Build Guest Signer | 调用本地脚本，采用独立产物路径和清理后的构建环境；不依赖尚未迁入的上游 Command 工程 |
| APIRequest | 从 APIWire 提取 Foundation 请求解析，Xcode daemon 与 SwiftPM 无固件测试编译同一源文件；保留字段/长度及错误文本行为 |
| proxy/I/O worker | 保留上游实现；新增 macOS 测试 harness，直接编译同一份 C 源码 |
| 构建入口 | 显式 `daemon_api_build`；默认 build 与安装入口没有选用候选 daemon |

## 依赖和产物检查

daemon 使用独立的 Xcode 依赖图，不与宿主 SwiftPM 依赖图合并。

| 依赖 | 固定版本 | 提交 |
| --- | --- | --- |
| IcliKit/IcliSystem | 0.6.9 | `74843a56df54936c3949239a4ffb3ddcbe37dee4` |
| SwiftNIO | 2.83.0 | `34d486b01cd891297ac615e40d5999536a1e138d` |
| Swift Collections | 1.6.0 | `a0cb0954ecb21e4e31b0070e6ed5674e8556685a` |
| Swift Atomics | 1.3.1 | `0442cb5a3f98ab802acb777929fdb446bda11a34` |
| Swift System | 1.8.1 | `869129b7bf4ecc57b97d0193ad29690ca2134750` |
| Swift Argument Parser | 1.3.1 | `46989693916f56d1186bd59ac15124caef896560` |
| ArchiveKit | 1.0.0 | `82687c75e530917b7fbeb15cd5f9369524637155` |

`dependencies/daemon-api-pins.json` 保存固定基线。检查器对比依赖种类、URL、提交、版本与数量，拒绝重复 pin、checkout 修改和 ArchiveKit 本地二进制覆盖。Xcode 使用 `-onlyUsePackageVersionsFromResolvedFile` 和 `-disableAutomaticPackageResolution`。单独为 daemon 的 Package.resolved 加入 `.gitignore` 例外，避免已有 `*.resolved` 规则丢失该锁文件。

候选产物为 arm64、IOS、minos 15.0，未定义符号不含 `_swift_initBorrow`。ldid 签名后的 entitlements 与上游 daemon 配置一致；launchd plist 与上游配置一致。动态依赖限定为系统或 Swift 路径，包含弱链接的 `@rpath/libswiftCompatibilitySpan.dylib`。这些结果不证明客户机上的动态库可用性或运行兼容性。

许可证保存于 `dependencies/licenses/daemon-api/`，保留上游 MIT、依赖 LICENSE/NOTICE、llhttp 和 libarchive 声明。二进制归档的 URL、校验和、依赖 Package.swift 摘要、共享 signer 源码摘要与逐文件映射见 [来源清单](p2_daemon_api_sources_2026-09-28.json)。前五批来源清单保留当时快照，本清单记录本批继续修改的文件。

## 验证

- proxy 宿主测试 7 项通过：非法参数、成功退出、失败重启、SIGTERM 停止、父进程 SIGKILL 后 worker 退出、停止升级为 SIGKILL、pending-update 失败返回 launchd。
- harness 使用临时 macOS 可执行文件和普通目录，不运行 UIKit、vsock 服务或客户机更新代码；pending-update 的存在检查由测试替身提供，不读取真实客户机缓存。测试证明本机 POSIX 进程行为，不证明 iOS launchd/Jetsam 行为。
- 请求解析 6 项通过，含 11 组非法输入及 method 长度边界、可选字段、标识符保留和错误文本。
- 依赖检查专项 3 项通过；候选副本验证通过，追加字节后 manifest 检查拒绝通过。
- 固定依赖 iOS 交叉编译、候选签名与产物检查通过；默认 app 签名构建通过。

| 完整检查 | 结果 |
| --- | --- |
| `make test` | 退出 0；Python 385 项；Swift Testing 665 项、91 suites；XCTest 145 项，3 项跳过，0 失败 |
| 归档传输内存回归 | 两条 1 GiB 路径通过；file/producer 峰值 RSS 为 8,749,056 / 8,962,048 字节 |
| `make daemon_api_build` | 退出 0；iOS 交叉编译、依赖 checkout、候选签名权限和产物 manifest 检查通过 |
| `make build` | 退出 0；默认 app 的资源、签名和 entitlements 检查通过，包内仍只有普通/less 载荷，没有 API daemon 候选产物 |
| 来源快照 | 36 个上游文件（2 个适配）和 24 个本地接线文件核对通过，共享 signer 源码摘要一致 |

本批完整测试覆盖上一批最后增加的资源路径传递测试，因而 Swift 总数由上一批完整运行的 658 加上后补的 1 项，再加本批 6 项，合计 665 项。

日志位于 `research/artifacts/p2-daemon-api-2026-09-28/`（Git 忽略）。未执行真实 VM 导入、启动、恢复或客户机安装。P1c 真实导入及导入后启动继续跳过。

## 后续范围

P2 仍为部分完成。候选 daemon 的宿主 HTTP/WebSocket 客户端、鉴权、事件、文件传输、API/capability 对照及真实客户机验收尚未接入；guest dylibs、GPU compiler plugin 和完整 bundle 布局也未完成。默认协议切换必须保留本地 capability 合约，并验证 proxy/worker 在 iOS 上的生命周期和更新行为。
