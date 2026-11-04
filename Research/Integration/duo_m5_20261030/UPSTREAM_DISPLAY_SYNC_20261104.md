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

未验证：Duo 实际折叠和旋转后的 AX 点击、WDA 铰链事件、常亮锁屏和唤醒、实际键盘焦点切换、真实 guest 的 X1 日志迁移和共享缓存回滚、完整固件恢复的峰值磁盘占用。
