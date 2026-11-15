# 验证缺口与执行准备（2026-11-15）

本轮处理 TASKS.md 第 5 项，证据位于 `.build/followup-3-5-20261115/`。可执行的离线回归及环境预检已完成；实际 CFW 安装／System 卸载、Linux FUSE、物理 USB／DFU、完整恢复空间峰值和 27.2 候选仍未验收。未将准备工作改记为这些项目通过。

## 已执行的验证

| 验证 | 结果与日志 | 范围 |
| --- | --- | --- |
| CryptexFileOps、DSC mapping lifetime、undo words、CustomFirmwareDaemons | 4 个 suite、47 项通过，`filesystem-cache-tests.log` | 包括真实 DSC 导出查询后的映射释放；不替代真实 System 卸载 |
| 原生恢复 | 7 个 suite、72 项通过，`restore-tests.log` | 恢复 runner、布局、identity、ticket、options 等契约；不连接或擦除真实目标 |
| 生产 recovery open 例程 | libusb 7/7、IOKit 8/8，`recovery-clients.log` | fake USB backend 的错误清理与重试；不替代实际 USB／DFU |
| 缓存 worker | 身份 12/12、生产确认 3/3，`cached-identity.log`／`cached-confirmation.log` | 路径别名、inode、pending marker；不替代 Linux FUSE／并发 |
| 保存版摄像头脚本前置检查 | 7 个记录回复复放场景通过，`camera-guard-tests.log` | 原脚本字节未修改，复制至独立假工作区：候选通过前置检查，原库、可写根、其他库变化、缺库、错误 daemon 和会话越界被拒绝。假 socket 不连接真实 VM，不计为新一轮摄像头实机验收 |
| 显示／启动证据处理 | 12 项通过，`evidence-tests-final.log` | 见 [诊断记录](DISPLAY_BOOT_DIAGNOSIS_20261115.md) |

两个用于下一阶段的 Bundle 深度严格签名检查通过：`mixed-runtime-signature.log`／`cfw-bundle-signature.log`。这些是现有构建的复核，本轮没有修改生产源码或重建完整 Bundle。

## 环境预检

| 项目 | 本轮结果 | 继续条件 |
| --- | --- | --- |
| 当前新宿主 | CDHash `974031b523fa25f5975784700b5030123213efdd` 被 AMFI 拒绝，`host-preflight.log` | 需要对此具体程序重新准入；此前通过记录仍保留，本轮没有更改 allowlist |
| 基线宿主 | CDHash `d85f81edab6cc06b9589205ecec130585ac941e8` 也被拒绝，`baseline-host-preflight.log` | 不用于绕过当前批准范围；未启动原副本 |
| 独立候选 | RPC `142b5a77…`、GLES `1482f753…`、27.2 `e926dc10…` 均被 AMFI 拒绝 | 各自另行准入；本轮不把当前 27.1 测试算作这些候选的验收 |
| Linux | 本机为 macOS；Docker CLI 存在，但当前 OrbStack daemon socket 不存在，`docker info` 无法连接；没有可用 sshfs | 需要可用的 Linux FUSE／SSHFS 测试环境。未启动服务、安装包或创建 Linux 系统 |
| USB／DFU | 正常宿主环境列出 1 个连接设备，与本轮 foundation 副本的预测 UDID 不匹配 | 该设备不是本轮授权目标，未操作。需要明确的可擦除目标、身份及恢复批准 |
| 27.2 | 既有源码和 Bundle 存在，但 AMFI 拒绝；本轮未找到可直接进入验收的已准入运行条件 | 仍需独立 24B91020 VM、WDA 与铰链／音频／锁屏等既有验收方案 |
| 恢复空间峰值 | 宿主空闲空间只作准备信息，未执行恢复 | 完整恢复后才能报告峰值；`df` 空闲值不能替代峰值测量 |

## CFW 实测对象已准备

仅从已停机的 `duo-rpc-foundation-20261115` 创建 `duo-cfw-followup-20261115`，使用原生 `vm clone --new-identity`。库目录为 `.build/duo-runtime-84e3ce54/machines`，源与新副本 Disk.img 均为 64,000,000,000 字节，inode 分别为 354916162 与 355300409。新副本尚未启动或安装 CFW。

`cfw-clone-normal-host.log`、`cfw-clone-metadata.json`、`cfw-patches-before.json` 保存准备结果。沙箱内首次 clone 因运行状态检查拒绝，在正常宿主环境重试成功；没有删除或修改源磁盘。当前新副本为 standard、installed=true，目录含 240 项，已有两个 boot-component pending 项：`kernel-cfw-paravirt_gles_renderer`、`devicetree-cfw-homeview_touch`。本轮 CFW guest 测试不更新这些 boot components，也不能以全局 pending=0 作为验收条件。

候选资源来自 `.build/duo-sync-20261113/XcodeBundle/Build/Products/Debug/VPhone.bundle`：vphoned 为 `c04e362a…`，SystemHook 为 `6aa02df8…`。原副本保持原 daemon／标记和原库。下面是尚未执行、需要批准的具体安装步骤：

```zsh
bundle="$PWD/.build/duo-sync-20261113/XcodeBundle/Build/Products/Debug/VPhone.bundle"
library="$PWD/.build/duo-runtime-84e3ce54/machines"
sudo "$bundle/Contents/MacOS/vphone-cli" cfw install duo-cfw-followup-20261115 --keep-artifacts -l "$library"
sudo "$bundle/Contents/MacOS/vphone-cli" cfw update-environment duo-cfw-followup-20261115 -l "$library"
```

`--keep-artifacts` 保留准备好的恢复树；不运行 `fw restore` 或擦除设备。安装会由项目工具以 root 在私有临时目录挂载并修改新副本的 System／Preboot 等 guest 内容，写入 guest 收据。需在每次返回后核对安装警告、收据、实际卸载及无映射／文件句柄；退出码 0 不能代替逐项结果，因为安装器可能隔离非关键补丁失败。安装前后保存源磁盘元数据和小型状态文件摘要，确认未修改源副本；新副本保留供审阅。`hdi-before.plist` 已保存安装前宿主 image 状态。

获准准入后，才可启动新副本核对实际 daemon／库、根只读、AX／RPC 与正常关机。完整安装和 environment update 的 guest 状态只在新副本验收，不对原副本或 foundation 副本做全量部署。

## 仍需运行的步骤

1. 准入当前 `974031b5…` 宿主后，仅在 foundation 副本做冷启动／方向检查与保存版摄像头实测；临时使用已验证的 SystemHook 时仍按原方案回滚、核对 21 项库并正常关机。
2. 获准在新 CFW 副本执行上述两条安装命令，核对 System 实际卸载、收据与冷启动；保留源副本和全部数据。
3. Linux FUSE／并发、明确 USB／DFU 恢复目标及独立 27.2 候选按对应条件单独执行。当前没有相应实测结果。

依据用户在本对话提供的执行约定第 4、7 条，宿主 allowlist 修改和扩大到完整 CFW 安装的动作范围需明确确认。本轮先完成了目标、候选、签名、计划、回归和环境核对，再提交这些具体动作。
