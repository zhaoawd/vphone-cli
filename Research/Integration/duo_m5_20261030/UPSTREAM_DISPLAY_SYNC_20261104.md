# Duo 显示同步记录（2026-11-04）

基线为 `c51ae5ab`。本轮合入上游四项：

| 上游内容 | Duo 提交 | 合入范围 |
| --- | --- | --- |
| #788 | `1ebba9e6` | 由 backboardd 发布内屏 3× 缩放；保留 SpringBoard 对早期读值的处理 |
| #799 | `08345fbc` | 发布内屏为内建显示屏，供进程外的 FrontBoard 和 XCTest 读取 |
| #800 | `a6588534` | 处理 WebDriverAgent 发来的铰链事件 |
| #801 | `668bb10e` | 为支持常亮显示的 iPhone 添加设备树标记，并使 Duo 窗口区分常亮锁屏与熄屏 |

发布内屏缩放时复用 `VPhoneDuoInnerPointScale`；现有 AX 点击和自动锁屏文件未变。#801 沿用 `preboot-cfw-devicetree_iphone_product`，未新增补丁标识符或预设。补丁行为与上游运行结果记录在 [补丁比较](../../0_binary_patch_comparison.md#always-on-display-2026-11-02)。本分支未引入 HomeView、iOS 17 或 OpenGL ES 的相邻改动。

## 离线验证

| 命令或检查 | 结果 | 日志（工作区 `.build/`） |
| --- | --- | --- |
| `xcodebuild -workspace VPhone.xcworkspace -scheme FirmwarePatcherTests test`，限定 iPhone 产品描述、三组折叠设备树和补丁目录 | 39 项通过 | `duo-display-firmware-tests.log` |
| `make -C VPhoneGuestComponents test-hinge` | 铰链测试通过 | `duo-display-hinge-tests.log` |
| `zsh VPhoneDaemon/Tests/run-logic-tests.sh` | 403 项通过，含常亮显示的 MobileGestalt 答复 | `duo-display-logic-tests.log` |
| `zsh VPhoneDaemon/Tests/run-element-tap-tests.sh` | 原生显示和 AX 上下文检查、几何 31 项、API 236 项通过 | `duo-display-element-tap-tests.log` |
| `zsh VPhoneDaemon/Tests/run-auto-lock-tests.sh` | 81 项通过 | `duo-display-auto-lock-tests.log` |
| `xcodebuild -workspace VPhone.xcworkspace -scheme VPhone -configuration Debug build` | 构建和 bundle admission 通过 | `duo-display-build.log` |
| `codesign --verify --deep --strict --verbose=2 <bundle>` | 通过 | `duo-display-codesign.log` |
| `zsh Research/Integration/duo_m5_20261030/Regression/display-config.zsh <vphone-cli> <evidence-dir>` | 三种显示配置与拒绝路径通过 | `duo-display-cli-config.log` |

构建包为 `.build/XcodeDuoDisplay/Build/Products/Debug/VPhone.bundle`。Xcode 命令的完整参数见日志。工作区没有 `ipsws/ref_extract`，本轮未执行完整固件参考样本测试。

## 隔离副本与运行条件

从已停止的 iOS 27.1（24A94425）Duo 候选机通过同卷 APFS 文件克隆得到只用于复制的 seed，再用 `vm clone --new-identity` 创建 `duo-sync-storage` 和 `duo-sync-display`。它们位于 `.build/duo-display-acceptance/machines/`，分别使用首批和本批构建。原机与各副本的磁盘 inode 不同；原机的配置、补丁收据、SEP 和 NVRAM 哈希在复制前后相同。两个验收副本的 SEP 和 NVRAM 与 seed 一致，身份在首次启动时生成。

两版 `host preflight` 均报告 AMFI 拒绝。验收目录内的 `prepare-root.zsh --check` 已验证签名、二进制哈希、磁盘 inode 和停止状态。`--apply` 由用户在终端运行：仅更新这两个隔离副本的 guest 环境，并通过包内的 `vphone-escalator` 放行这两个签名，随后重跑宿主预检。脚本不会启动 VM。

## 运行时验收（2026-11-04）

管理员脚本执行成功，两台隔离副本均通过宿主预检并启动。两台客户机通过
`device.info` 回报的 vphoned SHA-256 均与各自 bundle 内的程序一致。原始证据
保存在工作区 `.build/duo-display-acceptance/`。

| 项目 | 结果 | 证据目录或文件 |
| --- | --- | --- |
| X1 旧日志迁移 | 两台副本均从 215449 个页记录迁移出 24834397 条指令记录。两台启动后，客户机的 `.vphone-dsc-undo.words` 均为 298012849 字节，JSON 为 3260 字节 | `root-*/{storage,display}-update.log`、`{storage,display}-dyld-cache-list.json` |
| 窗口、折叠、旋转 | `vm-smoke.zsh` 通过 6 轮折叠、6 个受支持的旋转组合、2 个预期拒绝和熄屏折叠保持锁定。SpringBoard 与 backboardd 的 PID 未变 | `display-smoke/` |
| 内屏类型与缩放 | vphoned 在内屏启用时读取到 `displayType=0`、`pointScale=3`，原生画布为 669×951 点 | `display-tap-native/02-open-flat/portrait-displays.json` 及对应 TapProbe 回执 |
| AX 点击 | `element-tap.zsh` 对原生布局和 SDK 26.4 声明的兼容布局分别通过 18 组旋转与姿态、162 次真实控件点击；每种布局另有 6 个预期拒绝，未计入通过数。兼容布局的内外屏画布均为 375×667 点 | `display-tap-native/`、`display-tap-compat/` |
| WDA 的 HID 铰链请求 | 无私有 HID 权限的本地探针按 WDA 的格式发出三个事件；角度依次为 120°、0°、180°，写回的接受计数从 0 到 3，发送失败计数仍为 0。没有运行 WDA HTTP 端点 | `hinge-client-probe/main.m`、`display-hinge-client/` |
| 常亮锁屏和唤醒 | 第一次启动后缓存含两项常亮显示答复，没有写入 flipbook 答复。重启后锁屏第 10 秒，SpringBoard 报告锁定和屏幕关闭，面板状态为 1，宿主轮询使用的 `display.orientation.screen_off` 为 false。截图显示调暗的锁屏；唤醒并解锁成功 | `display-first-gestalt.plist`、`display-reboot-verdict.json`、`display-always-on/` |

两台隔离副本均已正常关机，未发现仍占用磁盘、SEP 或 NVRAM 文件的进程。
已保存 [常亮锁屏回归脚本](Regression/always-on.zsh)。本轮未对共享缓存执行
真实回滚，未测量完整固件恢复的峰值磁盘占用。宿主窗口日志确认负责启动的
进程没有辅助功能权限，覆盖了未授权路径；已授权时快捷键的焦点切换尚未验证。

## X1 回滚与恢复树发布验证（2026-11-04）

从 `duo-sync-storage` 只读导出 80 个真实缓存文件及两个撤销日志；逐文件核对
传输大小。以下命令仅对工作区内的导出副本运行：

1. `cfw patch-dsc-revert --dry-run` 识别出 228326 条启动闭包和 24606071 条
   其余 X1 指令记录。
2. `cfw patch-dsc-revert` 只指定这两个 X1 补丁，重算 34 个分片的
   215442 个签名槽，并移除这两个补丁的撤销记录。
3. 依次运行 `cfw patch-arm64e-x1-bootstrap-cache` 和
   `cfw patch-arm64e-x1-cache`，对比初始 SHA-256。80 个文件中 78 个
   一致，分片 `.01` 和 `.40` 不一致。
4. 从隔离客户机重新导出两个分片，确认它们仍与初次导出哈希一致。差异由以下
   4 个指令和各分片一个 32 字节签名槽组成：

| 分片 | 文件偏移 | 补丁 |
| --- | --- | --- |
| `.01` | 1897532、1897536、1897540 | `dyld-boot-xpc_lwcr` |
| `.40` | 103076044 | `dyld-boot-lockdown_mode` |

原始 JSON 记录将这 4 条指令归于表中两个补丁，但迁移后的
`.vphone-dsc-undo.words` 同时将它们归于 `dyld-boot-arm64e_x1_bootstrap`。
`convertingRunsToWords` 把旧 X1 页记录与当前缓存的每处差异都归于 X1，
其中包含同页其他补丁的修改。只回滚 X1 时也撤销了这 4 条指令。
对照实验仅补跑 `cfw patch-xpc-lwcr` 和 `cfw patch-lockdown-mode`，
随后全部 80 个文件的 SHA-256 与初始值一致。此缺陷未修复；现有日志已迁移的
VM 也需要覆盖。证据见 `.build/duo-display-acceptance/real-cache-roundtrip/`
中的 `difference-details.json`、`reapplied-diff.txt` 和 `control-diff.txt`。
隔离副本已关机，回滚实验没有写入其客户机磁盘。

恢复树发布使用 Duo 实际恢复树的 232 个文件，共 13,441,690,754 字节。
用 #804 前后的 `VPhoneConfinedDirectory.replaceFile` 分别写回同一 APFS
卷上的两个预先克隆的目录，并通过 `df -k` 采样卷可用容量：

| 实现 | 发布时间 | 观测到的峰值额外占用 |
| --- | ---: | ---: |
| #804 前，复制 | 3.36 秒 | 13.52 GB |
| #804 后，克隆 | 0.062 秒 | 未观察到增加 |

两个输出目录的 232 个文件均与输入 SHA-256 一致。该测量覆盖文件发布，不
覆盖 Cryptex 解密与合并、DFU 恢复或创建 VM 的总磁盘峰值。采样日志和工具
源码见 `.build/duo-display-acceptance/restore-publication/`。

WDA HTTP 尚未执行：未在工作区、本机搜索索引或 Appium 缓存找到可启动的
WebDriverAgentRunner，本机未查到有效的代码签名身份。后续使用一套能在
显示隔离副本运行的 Runner，依据 [WDA 铰链端点文档](https://github.com/appium/WebDriverAgent/blob/master/docs/hinge-angle.md)
逐个 POST 120、0、180，同时核对 WDA GET 与 vphoned `display.orientation`。
宿主快捷键仍待在授权辅助功能的终端中启动显示副本，分别在 VM 窗口获得焦点、
切到宿主应用、退出 VM 后测试已配置的 Spotlight 快捷键。
