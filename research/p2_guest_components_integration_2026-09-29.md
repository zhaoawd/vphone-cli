# P2 客户机组件构建与来源核对

日期：2026-09-29。固定输入为上游 `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3` 的 `VPhoneGuestComponents`，共 28 个文件。除 Makefile 的输出路径和本地 README 外，保留固定源码。来源 SHA-256 与本地差异记录在 `dependencies/guest-components-pins.json`，根许可证为 MIT。

`make guest_components_build` 构建并检查 `.build/guest-components-v2/stage`，不纳入当前 app 的默认 guest-resources，不安装到 VM。产物为 arm64e：LaunchHook、SystemHook、libvlocation、libcamfix、libvcamcaptured 的 deployment target 为 iOS 26.0；GPU compiler plugin 为 iOS 26.1。该目标不包含 Apple GPU 驱动。

检查覆盖源码摘要、普通文件、架构、IOS 平台、最低编译目标和 ad-hoc 签名。manifest 记录产物摘要、`activated:false`、`runtime_validated:false`。三项 Python 负向测试覆盖源码篡改、符号链接与缺件。签名检查不证明客户机加载通过。

`make test_guest_components` 运行上游 RootHide loader links 和 camera data plane 宿主测试：前者通过，后者 124 checks、0 failures。该入口已接到无固件 Swift runner。CI bundle job 增加 API daemon 和本候选的构建检查；本地检查通过不等于远程 CI 已执行。

## 相机 ABI

| 项目 | 本地 classic | 上游候选 |
| --- | --- | --- |
| publish header / 像素起点 | 256 字节 | 64 字节 |
| 身份与回执 | generation、presentation_id、独立 observe shm | 固定头中的 seq、frame_index 等；不能替代本地回执 |
| 路径 | 继续现有安装路径 | `/var/mobile/Media/SimulatedCamera` |
| 当前用途 | 默认后端 | 仅候选构建 |

证据为 `scripts/vphoned/vphoned_vcam.h` 与候选 `VCamCaptured/VCamFrameProtocol.h`。不能混用两个 publish header。P5 仍需统一 host/daemon/hook 的 v3 wire 与消费回执，再做真实应用验收。

上游 README 列出 `vpregister`，但固定版本源码目录和 Makefile 没有该构建目标。候选清单不包含它，本地 README 已按实际产物修正。

libvlocation 编译产生静态初始化器链接警告；编译成功，不将警告消失或宿主 C 测试视为 iOS 注入、授权、定位或 tweak 行为通过。没有执行真实安装、注入、Metal、相机或定位验收。

日志位于 `research/artifacts/upstream-remaining-2026-09-29/guest-components-*.log`。P2 的完整 Core Bundle/Launchpad/helper 布局仍未完成。
