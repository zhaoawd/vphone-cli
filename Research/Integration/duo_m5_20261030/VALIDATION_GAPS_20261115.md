# 验证缺口与实际结果（2026-11-15）

本轮处理 TASKS.md 第 5 项。用户已明确批准当前宿主准入、foundation 副本的方向／临时 SystemHook 摄像头复测，以及新身份 CFW 副本的完整安装、环境更新和冷启动。CFW 安装／System 卸载及保存版摄像头实测已完成；Linux FUSE／并发、物理 USB／DFU、完整恢复空间峰值和 27.2 独立候选未验收。

证据目录为 `.build/followup-3-5-20261115/` 与 `.build/host-webcam-distribution-20261115/`。本轮没有修改生产补丁源码、声明或预设；完整 Bundle 来自既有构建，严格签名已复核。

## CFW 安装与卸载

仅从已停机的 `duo-rpc-foundation-20261115` 使用 `vm clone --new-identity` 创建 `duo-cfw-followup-20261115`。创建时源／目标 Disk.img 均为 64,000,000,000 字节，inode 为 354916162／355300409；源副本未执行全量安装。原副本 `duo-rpc-accept-205443` 未启动。

用户批准后，以下两条命令经系统管理员认证实际执行，均返回 0。管理员调用显式保留调用者 `SUDO_UID=501 SUDO_GID=20`。

```zsh
bundle="$PWD/.build/duo-sync-20261113/XcodeBundle/Build/Products/Debug/VPhone.bundle"
library="$PWD/.build/duo-runtime-84e3ce54/machines"
sudo "$bundle/Contents/MacOS/vphone-cli" cfw install duo-cfw-followup-20261115 --keep-artifacts -l "$library"
sudo "$bundle/Contents/MacOS/vphone-cli" cfw update-environment duo-cfw-followup-20261115 -l "$library"
```

| 验证 | 实际结果 | 证据 |
| --- | --- | --- |
| 完整安装 | 明确输出 `CFW system install complete`；未发现 `[!]` 或 failed 警告 | `cfw-full-install.log`、`cfw-full-install-dialog.log` |
| 环境更新 | 明确输出 `Guest environment updated`；未发现上述警告 | `cfw-environment-update.log`、`cfw-environment-update-dialog.log` |
| System／工作镜像卸载 | 安装前、完整安装后、环境更新后均为相同的 5 个既有 simulator 镜像；无 `vphone-cfw.*` 工作镜像残留，状态文件句柄为空 | `hdi-before.plist`、`hdi-after-full.plist`、`hdi-after-update.plist`、`cfw-image-inventory.json`、`cfw-handles-after-update.txt` |
| 收据与目录 | installed=true、240 项；补丁状态与安装前相同 | `cfw-patches-before.json`、`cfw-patches-after-update.json` |
| 实际冷启动 | daemon `c04e362a…`；21 项库与候选资源一致（17 项存在、4 项不存在）；根只读 | `cfw-cold.oOJWgOQf/summary.json` |
| 正常关机 | `system.shutdown` 接受；会话退出 0；最终状态文件句柄为空 | `cfw-cold.oOJWgOQf/shutdown.json`、`final-handles.txt` |
| 保存版入口再次冷启动 | `Regression/cfw-followup-runtime.zsh` 实际执行，daemon、21 项库和根只读再次通过 | `cfw-cold.ayt7RfkO/check.log` |

第二次启动完成方向、录制与对照后，`final-check/summary.json` 再次核对候选 daemon／21 项库和根只读。原 trace=0、合盖纵向、锁屏、旋转锁及 Auto-Lock 已在各回归恢复读回中核对；最终正常关机与无句柄记录见该会话 `shutdown.json`、`final-handles.txt`。方向矩阵最终 8/8 通过，但此前失败、测试前提修正和仍未查明的问题分别保留，见 [诊断记录](DISPLAY_BOOT_DIAGNOSIS_20261115.md)。

最终 `hdi-final.plist` 与安装前相同，为 5 个既有 simulator 镜像；原副本、foundation 和 CFW 副本的状态文件句柄均为空，见 `runtime-closeout.json`、`final-all-state-handles.txt`。新 CFW 副本正常关机，候选安装保留。

原收据已有两个 boot-component pending 项：`kernel-cfw-paravirt_gles_renderer`、`devicetree-cfw-homeview_touch`。本轮 guest 安装未更新 boot components，不以全局 pending=0 作为验收条件。新副本保留候选安装及恢复树；不执行擦除或回滚为源副本。

## 宿主准入与保存版摄像头

当前宿主 CDHash `974031b523fa25f5975784700b5030123213efdd` 经批准加入 amfid allowlist，随后 `host-preflight-approved.log` 明确通过。混合 Bundle 与 CFW Bundle 的 `vphone-vm` SHA-256 同为 `e3cd22d52239d1b597d26520995c7bbdcec1087d04b3568e1419a453b1f1f3ed`。初始拒绝保留在 `host-preflight.log`，不再作为当前阻塞。

保存的 `Regression/camera-web-runtime.mjs install/accept/safari` 已在 foundation 副本实际执行，宿主使用生成测试图案。会话 `mixed-session.yXsrIAl0` 的最终结果为：

| 路径 | 帧与不同摘要 | 尺寸／上下文 |
| --- | --- | --- |
| 原生 AVCaptureSession | 14 帧／14 个不同摘要 | 1280×720 |
| WKWebView | 10／10 | 480×640，secure=true |
| Safari | 10／10 | 480×640，安全上下文 |

证据为 `camera-saved-accept-final.log`、`camera-saved-safari.log`、会话内 `camera-accept-summary.json` 及 Safari modal 结果。首次原生 accept 在 phase=requested 超时，随后完成测试 App／localhost 提示处理，原命令重跑通过；保留 `native-permission-timeout.json`，不计首次为通过。此安装走 `apps.install`，不验证 installd。

该会话恢复前已退出，退出方式未确认；本轮未向它发送停止信号，也不记为正常关机。重新启动 `mixed-session.7SVzfs6E` 后，测试 App `com.vphone.tests.camera-web` 已注销并归档为 `/var/root/Library/Caches/CameraWebProbe-followup-20261115-archived.app`，保留数据容器和先前归档。SystemHook 恢复原摘要 `755f089d…`，mixed Bundle 对应资源同时恢复并重新封装签名；其余 20 项原库未变。该会话正常关机、无状态句柄。

回滚后 `foundation-cold.vcjedef1` 冷启动核对原 daemon `446925b6…`、原标记、21 项原库、根只读、Auto-Lock 120 秒／never=false、合盖纵向，通过后正常关机，最终句柄为空。证据为该会话 `summary.json`、`auto-lock-final.json`、`orientation-final.json`、`shutdown.json` 和 `final-handles.txt`。临时库回滚完成。

## 离线回归

| 验证 | 结果与日志 | 范围 |
| --- | --- | --- |
| CryptexFileOps、DSC mapping lifetime、undo words、CustomFirmwareDaemons | 4 个 suite、47 项通过，`filesystem-cache-tests.log` | 包括真实 DSC 导出查询后的映射释放 |
| 原生恢复 | 7 个 suite、72 项通过，`restore-tests.log` | runner、布局、identity、ticket、options；不连接或擦除真实目标 |
| recovery open | libusb 7/7、IOKit 8/8，`recovery-clients.log` | fake USB backend 的清理与重试 |
| 缓存 worker | 身份 12/12、生产确认 3/3，`cached-identity.log`／`cached-confirmation.log` | 路径别名、inode、pending marker |
| 保存版摄像头前置检查 | 7 项记录回复复放场景通过，`camera-guard-tests.log` | 独立假工作区验证原库、可写根、其他库变化、缺库、错误 daemon 和会话越界拒绝；不计为 VM 结果 |
| 显示／启动证据处理 | 12 项通过，`evidence-tests-final.log` | 见 [显示与启动诊断](DISPLAY_BOOT_DIAGNOSIS_20261115.md) |

实际运行后，`node --test` 再次执行 `test-followup-evidence.mjs` 和 `test-f5-source-report.mjs`：12 项证据检查及 3 项来源窗口检查通过，日志为 `evidence-tests-runtime-final.log`。新增脚本语法、`git diff --check` 与回滚后 mixed Bundle 的深度严格签名检查通过；`git ls-files '*.py'` 为空。实际方向失败及连续原生采样轮的 presentation check 失败仍保留，不包含在这些离线通过数中。

## 仍未验收的环境

| 项目 | 观察结果 | 继续条件 |
| --- | --- | --- |
| Linux FUSE／并发 | 本机 macOS；Docker CLI 存在，OrbStack daemon socket 不存在，`docker info` 失败；无 sshfs | 可用 Linux FUSE／SSHFS 环境。离线映射与 macOS 卸载不能替代 |
| USB／DFU | 1 个连接设备与本轮 foundation 预测 UDID 不匹配，未操作 | 明确的独立目标、身份及恢复批准；擦除需明确批准 |
| 完整恢复空间峰值 | 未执行完整恢复 | 需记录真实恢复全过程；空闲空间不能代替峰值 |
| 独立 RPC／GLES／27.2 | CDHash `142b5a77…`／`1482f753…`／`e926dc10…` 仍被 AMFI 拒绝 | 各自准入及对应独立副本；27.2 需 24B91020、WDA 和铰链／音频／锁屏验收 |

本轮 27.1 的安装与运行结果不替代上述独立环境。显示近似静止、方向失败和冷启动故障仍按诊断记录单独跟踪。
