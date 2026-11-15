# 其余上游差异清单（2026-11-15）

本轮完成 TASKS.md 第 3 项的范围与依赖评估。当前代码为 `6b2988d6`；上游固定为 `1316940501398ea279f960ee7d838f93885730d4`，未刷新远端。没有直接合入本表中的生产改动。#924 与 #919／#923 单独见 [X1／TXM 预检](X1_TXM_PREFLIGHT_20261115.md)。

使用 `Regression/remaining-upstream-inventory.mjs` 保存 9 组最终合并差异、当前树至固定上游的对应文件差异，以及 blob 对照。证据位于 `.build/followup-3-5-20261115/upstream/`。文件不同可能包含本地适配或其他上游改动，不能把 blob 不同等同于整个 PR 未实现。以下结论另核对具体实现、调用点和声明。

| 项目与来源 | 当前差异与适用范围 | 依赖／处理方案 | 验收目标 |
| --- | --- | --- | --- |
| #867 `edaa02f0`；#877 `c7d096d9`，DriverKit | 缺少 iPhone／iPad 的 `DeviceTreeVirtualUSBDriverKit.swift`、`devicetree-cfw-virtual_usb_driverkit` 及对应 Preboot 修复。已有 HomeView／watch DriverKit 路径不能代替它。与 Duo 的虚拟 USB 输入直接相关，是否为本地启动失败原因未查明 | 同步安装后树和 Preboot 修复两个声明，保留 restore 树排除及设备族校验；同时带上 #877 的 TV-family 排除，不能只加 supports-driverkit 属性 | 原始树缺失／已有属性、重复应用、restore 角色、iPhone／iPad 与 TV／watch 排除；再验证实际 dext、触摸及启动。不得以 DriverKit 错误日志单独证明 RPC 故障原因 |
| #900 `6f57024a`，trusted darwinOS／Cryptex | 当前没有 persistent Cryptex RPC、宿主 Cryptex 菜单、`VPhonePCCCryptexctl` 或 trusted darwinOS feature。已有 sealed Cryptex 合并／重装能力属于另一条路径。上游对 iPhone／iPad iOS 27 明确拒绝 trusted darwinOS | 保持为 minimal／独立环境评估；涉及 restore-image 选择、trust-cache categories、cryptexctl 来源、AEA fallback、RPC 目录与新旧宿主能力，需完整依赖组。不得作为 Duo 27.1 默认补丁同步 | 先验证版本拒绝、标准预设隔离、串行安装及持久化契约；实际运行需要支持的独立系统与恢复目标。上游首启结果不计为本地验收 |
| #909 `b41ad87c`，SE 3 iOS 18／PCC GPU | 缺少从 PCC OS image 提取 GPU 的新 helper 与测试，固件目录／版本匹配和 AEA 数据入口也有差异 | 其他设备／旧固件组；直接 OS image 提取优先、临时恢复回退须一起核对。主要目标为 iOS 18，不将其归为当前 Duo 27.1 必需修复 | 对应 major/minor、镜像含／不含 bundle、AEA 回退、输出签名与缓存；实际 SE 3 iOS 18 独立验收 |
| #910 `0fadfde4`，local pairing | 缺少 `RemotePairing/CustomFirmwareRemotePairing.swift` 及 `system-remotepairingdeviced-cfw-local_connections`。上游最终实现覆盖 arm64e.x1 与旧版普通 arm64e 路径 | 对 Duo 配对／开发工具工作流直接相关；先补完整 Mach-O 发现与目标版本证据，单独声明和撤销，不与 Trust 提示点击混为一项问题 | 27.1／iOS 18 的发现、缺失／歧义拒绝、签名、重复应用和撤销；使用明确授权的配对目标进行真实连接 |
| #911 `12378954`，PCC 恢复 vCPU | 当前 `VPhonePCCGPURecovery` 使用固定 8 vCPU；上游对 cloudOS major <26 使用 1 vCPU，其他版本仍用 8 | 与 #909 的恢复回退共用路径，也影响 #900 的 cryptexctl 回退；不修改普通 Duo VM 的 CPU 配置 | 版本解析和临时 VM 配置回归；cloudOS 18 与 26 的恢复目标分别验证，涉及擦除另行批准 |
| #920 `1518293c`，鼠标模式 | 当前没有 `VPhoneGuestMouseMode`、持久化菜单或 iPad pointer／touch 切换 | 以 iPad 为主要目标，但修改共享 view／menu。移植时保留 Duo 的旋转输入、触摸和 capture 路径；全局偏好影响需明确 | iPad pointer／touch、绝对指针与滚轮、窗口切换／偏好；Duo 两面板及旋转后的点击／拖动回归 |
| #921 `bb82a72a`，SPTM | 缺少 `.sptm` patch target、pipeline 组件、`SPTMSecondaryCPUPatcher` 和测试。上游声明限 cloudOS 18 | 独立启动链组；需要 PatchKit／Launchpad 目录认识新增组件、IM4P PAYP 保留、预设及 drift 表配套。当前 Duo 27.1／cloudOS 26.4 不在该版本门槛内 | 语义锚点、唯一性与拒绝路径、PAYP round trip、预设匹配；再在 cloudOS 18 多 vCPU 独立目标验证 |
| #926 `69d45fb7`，未旋转 framebuffer | 缺少 QuartzCore planner、声明、CLI verb、安装调用和测试。上游声明限 iOS 27，并在通用 27.x dyld 安装列表接入；不能仅按 PR 的 iPad 标题假定对 Duo 无影响 | 与 #920 的 iPad 横屏指针相关；可能改变 Duo 渲染路径，需独立候选，保留已有 FoldDisplay／Snapshot 行为。不得直接套用为约 432 ms 亮度区间的修复 | 实际 DSC 试运行／应用／撤销、同页归属、iPad 横屏 shape layer；Duo 两面板旋转、交接、原生截图与录制对照 |

建议移植顺序：先处理直接相关且范围可限定的 DriverKit 和 local pairing；SE 3／PCC GPU／恢复 vCPU 为独立旧固件组；SPTM 按启动链单独处理；鼠标模式与 framebuffer 以独立 iPad／Duo 对照候选验证；trusted darwinOS 不进入当前 Duo 27.1 默认方案。这个顺序是基于本轮代码依赖的实施建议，不表示尚未验收的补丁已被证明必需。

重跑清单：

```zsh
node Research/Integration/duo_m5_20261030/Regression/remaining-upstream-inventory.mjs \
  "$PWD/.build/followup-3-5-20261115/upstream"
```

本轮未更改固件声明、预设、PatchKit API 或 Bundle 版本。实际移植时仍需补丁规范回归、完整 Bundle、严格签名与对应目标验收；涉及 Launchpad 依赖的协议／目录变化时单独核对系列兼容规则。
