# P2 第一批：原生签名库与构建映射

提交记录（2026-09-28）：按用户要求，将本记录对应的代码、测试及相关文档纳入本次整合提交。下文的“未提交”描述保留各阶段记录时的状态；验收范围和未验证项目不变。

日期：2026-09-28。固定上游为 `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3`，本地 HEAD 为 `bc3bfa8`，P1a/P1b/P1c 及本轮变化均尚未提交。用户已要求跳过 P1c 真实导入和导入后启动验收，本轮继续该决定。

## 实施结果

迁入 `VPhoneSign` 的 10 个 Swift 文件、5 个上游测试文件及固定夹具，接入本地 SwiftPM 独立 target `VPhoneSign`、`VPhoneSignTests`。CLI 新增 `sign` 与 `dump-entitlements`。库使用 Foundation、MachO、CryptoKit、CommonCrypto 和 Security，无新增远程包依赖。原始文件映射、Git blob 与本地 SHA-256 见 [来源清单](p2_sign_sources_2026-09-28.json)。上游和本地根 LICENSE 均为 MIT，保留原有版权与许可文本。

来源路径：

- `VPhoneExecutable/VPhoneCommand/VPhoneSign/` → `sources/VPhoneSign/`
- `VPhoneExecutable/VPhoneCommand/VPhoneSignTests/` → `tests/VPhoneSignTests/`
- `VPhoneExecutable/VPhoneCommand/VPhoneSignTestFixtures/` → `tests/VPhoneSignTestFixtures/`
- `VPhoneExecutable/VPhoneCommand/VPhoneCommand/Signing/VPhoneSignCommand.swift` → `sources/vphone-cli/VPhoneSignCLI.swift`

本地适配：

1. `Package.swift` 增加库、测试目标以及 CLI 依赖；保留现有 Makefile、VPhoneCore、固件快速测试/真实夹具测试隔离。
2. `VPhoneCLI` 注册两条显式命令。帮助说明当前迁移范围，拒绝 `--apple-adhoc` 与 `--pkcs12` 同时指定。
3. `VPhoneSigner.sign(fileAt:)` 要求普通文件，拒绝符号链接。使用随机名称、独占创建的 `0700` staging 目录，不再删除固定 `.文件名.vphonesign` 路径。暂存文件权限设置失败向上传递，成功后 rename 到目标；只清理本次创建的 staging。
4. 现有 build/CFW 脚本仍使用原有 ldid/codesign；本轮没有替换 guest 自动更新和安装资源，没有修改 VM 格式、进程或恢复后端。

例子：`vphone-cli sign --apple-adhoc /path/to/copied-arm64-binary`，或 `vphone-cli sign --merge --entitlements /path/to/entitlements.plist /path/to/copied-guest-binary`。`sign` 原地替换指定文件；无 `--merge` 时已有 entitlements 被替换。签名兼容结论仅覆盖固定夹具，不能推导所有 Mach-O 和所有 entitlement 类型。

## 本地与上游构建目标映射

| 模块 | 上游目标或源码 | 本地入口与处理 | 状态 |
| --- | --- | --- | --- |
| CLI | VPhoneCommand → vphone-cli | sources/vphone-cli；SwiftPM executable | 保留现有 CLI，本批增加签名命令 |
| VM/UI | VPhoneVirtualization → vphone-vm | 当前仍在 vphone-cli；VPhoneVirtualMachine/宿主控制 | P3 再拆分，VM 锁与停止身份须由实际 VM 进程持有 |
| Core | VPhoneKit/VPhoneCore | sources/VPhoneCore | 保留本地锁、状态和恢复包装 |
| Sign | VPhoneCommand/VPhoneSign | sources/VPhoneSign | 本轮迁入 |
| Archive | VPhoneKit/VPhoneArchiveKit | 当前 VPhoneBundleOps/VPhoneProcessRunner 使用 tar | 未迁入，继续保留 staging、manifest、库锁及权限约束 |
| Restore | VPhoneCommand/VPhoneRestore，MobileRestoreCore/MobileRecoveryCore | 当前 sources/VPhoneCore 与 restore CLI/脚本 | 未迁入，保留旧恢复后端与设备身份约束 |
| daemon、代理与 I/O worker | VPhoneDaemon；IcliKit/IcliSystem | scripts/vphoned ObjC daemon | 未迁入，需维护本地控制协议和资源依赖 |
| guest dylibs | guest-resources | 当前 scripts/resources、vphoned.signed 等 | 未迁入新布局，须保持相机、定位和 GPU 载荷完整 |
| Launchpad/helper | VPhoneLaunchpad；VPhoneEscalator → vphone-escalator | 本地无对应管理器/helper 接线 | P3/P7 处理授权、收据、生命周期 |
| 资源、字符串、entitlements | 各 Xcode 工程及 StageBundle.sh | scripts/build.sh、check_bundle.py、VPhoneResources | 本轮保持原路径；完整新 bundle 适配未完成 |

`StageBundle.sh` 用 `xcodebuild -project` 分别构建 Restore、Command、daemon、Escalator，再组装 `Contents/MacOS` 和 `Contents/Resources/guest-resources`。因此不能用 workspace 一份 lockfile 替代各工程实际解析结果。

## 固定依赖核对

本轮重新读取固定 2.0.8 的全部 7 个 Package.resolved（workspace、daemon、Command、Restore、Virtualization、Kit、Launchpad），完整路径及 pins 存于来源清单。

| 依赖 | 固定版本 / revision | 后续模块 |
| --- | --- | --- |
| ArchiveKit（包 libarchive.xcframework） | 1.0.0 / `82687c75e530917b7fbeb15cd5f9369524637155` | VPhoneArchiveKit |
| AppleMobileDeviceLibrary | 1.0.1790243523 / `553a0bf1b55812b1a08c727b1a3084e88871343b` | Restore |
| openssl-spm | 3.6.2 / `9f3b525d960fe71e534482310e96cd9c4f2faa17` | Restore；VPhoneSign 不依赖该包 |
| IcliKit/IcliSystem（包 icli） | 0.6.9 / `74843a56df54936c3949239a4ffb3ddcbe37dee4` | daemon |
| SwiftNIO | 2.83.0 / `34d486b01cd891297ac615e40d5999536a1e138d` | daemon/VM |
| Swift Collections | workspace/daemon 为 1.6.0；Virtualization 为 1.7.0 | 后续按实际构建图核对 |

Archive/Restore 的外部依赖源码、许可证和二进制产物验收尚未完成；此表只记录上游固定输入，不代表这些依赖已引入或通过本地验证。

## 验证与限制

| 检查 | 结果与范围 |
| --- | --- |
| 上游 Sign 专项 | 原始 25 项通过；固定 ldid 摘要、entitlements、重复签名、损坏/不支持输入、只读文件权限、系统 codesign 验证 |
| 新增本地测试 | 5 项库集成及 2 项 CLI 测试通过；同名文件保护、符号链接拒绝、损坏 PKCS#12、仓库证书 CMS 验证、普通程序执行、命令注册、冲突参数拒绝 |
| Python 完整套件 | make test 的 Python 阶段 369 项通过 |
| Swift 完整套件 | 首轮新增测试的 #expect 注释类型导致编译失败；修正为字符串插值后 make test_swift 退出 0：Swift Testing 529 项/72 suites；XCTest 145 项、3 项跳过、0 失败 |
| 归档内存回归 | file/producer 两条 1 GiB 路径通过，峰值 RSS 为 8,765,440 / 7,847,936 字节 |
| CLI 临时副本验收 | apple-adhoc 签名后 codesign --verify --strict 返回 0；程序执行返回 0、stdout 为 1 p；merge/dump 保留原有 32 键并增加测试键；损坏输入退出 1 且原内容不变 |
| make build | 退出 0；Release 编译、宿主/guest 签名和完整 bundle 资源/entitlements 校验通过 |
| 源码来源 | 逐文件本地 SHA-256 复核与来源清单一致；7 份锁文件 pins 已记录 |

日志与 CLI 结果位于 [research/artifacts/p2-sign-2026-09-28](artifacts/p2-sign-2026-09-28/cli-smoke.json)。该目录被 Git 忽略，不随报告提交自动分发。`otool -L` 输出已保存；新增 Sign target 使用系统框架，未增加 Homebrew 动态依赖。宿主签名 app 的受限权限执行准入未重新验证，普通测试程序成功不代表该 app 可启动 VM。

本轮只在临时副本上签名和执行普通测试程序，不进行 guest 安装、VM 启动或真实恢复。P2 保持部分完成：Archive/Restore、daemon/guest、新资源布局与完整交付接线尚未迁入。
