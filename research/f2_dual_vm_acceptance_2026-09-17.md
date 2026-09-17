# F2 双 VM 实机验收

日期：2026-09-17。本记录只覆盖 `vm-2607` 与 `vm-2607-f2` 的本次运行组合，不扩展为其他固件、变体或实例数量。

## 实验设置

- 原实例：`vm-2607`，运行中的宿主进程保持不变。
- 新实例：`vm-2607-f2`，iOS 26.1（23B85），`restore-info.json` 记录 EXP。宿主沿用用户启动方式，未传 `--variant`，启动日志中的宿主 variant 为默认 `regular`。
- 两个实例分别使用各自 VM 目录中的 `vphone.sock`。
- 新实例首次设置期间停留在“数据与隐私”页面，按钮持续显示转圈。

## 首次设置阻塞

新实例的 VM、SpringBoard、Setup 和 `vphoned` 进程均保持运行。Setup 日志同时出现 `AKAuthenticationError Code=-7005`、`BuddyIntentAndChildSetupFlow` 长时间初始化和 TCP `SYN_SENT` 重传。抓包显示客户机向公网 443 端口发起连接，但未收到对应响应。

配置对比确认：`vm-2607` 的当前 `en0` 服务启用了 `192.168.64.1:10808` HTTP/HTTPS 代理，`vm-2607-f2` 的当前 `en0` 服务没有这些字段。只向新实例当前 `en0` 服务写入以下字段，没有复制整份主实例配置：

- `HTTPEnable = 1`
- `HTTPProxy = 192.168.64.1`
- `HTTPPort = 10808`
- `HTTPSEnable = 1`
- `HTTPSProxy = 192.168.64.1`
- `HTTPSPort = 10808`

原配置已保存到客户机 `/var/preferences/SystemConfiguration/preferences.plist.codex-before-proxy-20260917`。宿主临时证据目录为 `/tmp/vphone-f2-proxy-fix-20260917-run2`。`configd` 重载没有更新当前网络会话；客户机重启后配置摘要保持为 `da3b6a664dba856bc0625f46b181e7c8378ecb7400030b05334eb55ab781cb7b`。宿主随后观察到多条 `192.168.64.1:10808 -> 192.168.64.5:*` 的已建立连接，Setup 页面退出原阻塞状态并回到“你好”起始页。

上述结果支持本次阻塞由新实例缺少当前宿主环境所需的 HTTP/HTTPS 代理配置引起。没有验证未配置代理时的其他网络环境。

## 文件隔离复验

代理配置生效并完成客户机重启后执行：

```sh
.venv/bin/python3 scripts/f2_dual_vm_acceptance.py file-isolation \
  --left-name vm-2607 --left-socket vm-2607/vphone.sock \
  --right-name vm-2607-f2 --right-socket vm-2607-f2/vphone.sock \
  --output research/artifacts/f2-dual-vm-2026-09-17/file-isolation-after-proxy-fix
```

结果为 `PASS file-isolation: vm-2607, vm-2607-f2`。两个实例在相同客户机路径写入并读回不同标记，清理成功。摘要见 `research/artifacts/f2-dual-vm-2026-09-17/file-isolation-after-proxy-fix/summary.json`。

停止、重启及后台请求取消后，使用新路径再次执行文件隔离。最终摘要为 `file-isolation-final-restored/summary.json`，两个标记摘要仍不同，清理成功。

## 应用归属

`app_foreground` 在两端均返回 `source=unknown`，因此未用该接口推断前台应用。验收工具改用 `app_list(filter=running)` 的 bundle ID 和 PID，并要求目标应用在场景开始前未运行。

使用 `com.apple.calculator` 执行以下顺序：

1. 只在 `vm-2607` 启动，`vm-2607-f2` 没有该 bundle ID；
2. 在 `vm-2607-f2` 启动后，两端分别保持自己的 PID；
3. 停止 `vm-2607` 的应用，`vm-2607-f2` 的 PID 不变；
4. 清理 `vm-2607-f2` 的应用。

首次结果中的 PID 分别为 7695 和 92906。最终重启后，新实例停在锁屏，`uiopen` 返回后没有应用 PID；截图保存在 `final-f2-screen.png`。使用 A3 已验证的底边坐标上滑后复验通过，PID 分别为 11780 和 1529。重启恢复的 Calculator 和 Camera 进程在相应场景开始前显式停止；场景没有覆盖已有应用状态。

通过摘要：`app-isolation-calculator/summary.json`、`app-isolation-calculator-after-edge-swipe/summary.json`。Settings 初次尝试因新实例已运行该应用而拒绝，不计为通过证据。

## 相机归属

`vm-2607` 的客户机只声明 `vcam_status`，不声明 `vcam_receipt_v3`；`vm-2607-f2` 声明两者。当前组合采用非对称角色：新实例呈现，主实例查询状态并尝试跨实例停止。

- 两端初始状态均为 `off`。
- 新实例启动 `com.apple.camera` 后呈现 SHA-256 为 `7a6cafd…470ef` 的测试图像。
- 最终 generation 为 `f2-fec40bb68346441396bb321e9a942874`，presentation ID 为 `07C87BE7-A2FD-4947-A5A5-1FC2D8D77CAD`；回执语义为 `presentation_frame_copied`。
- 主实例保持 `off`。主实例使用上述 generation 和 presentation ID 执行 `camera_stop`，返回 `generation does not own the camera source`。
- 拒绝后，新实例仍保持相同 generation、presentation ID 和复制回执。
- 新实例停止源并终止系统相机后，两端状态均为 `off`。

最终摘要为 `camera-isolation-cross-stop-final/summary.json`。首次未启动相机应用的负向对照没有复制回执，源已按 generation 和 presentation ID 清理；该结果不计为通过。

## 停止、重启和后台请求

两次只停止 `vm-2607-f2`。`vm-2607` 的宿主 PID 21605 保持不变。

- 第一次停止后，`vm-2607-f2/vphone.sock` 被移除，目录锁可获取；主实例完成临时文件写入、读回和清理。摘要为 `survivor-primary-after-f2-stop/summary.json`。
- 第二次停止前，向新实例发送 `/var/jb/usr/bin/sleep 60`。请求发送时间为 1789602503.1016471，停止后在 15.6953339 秒返回 `ok:false` 和 `not connected to vphoned`，没有等待满 60 秒。
- 第二次停止后，socket 和目录锁检查再次通过，主实例继续完成文件请求。摘要为 `survivor-primary-after-pending-cancel/summary.json`。
- 新实例每次恢复后均重新连接客户机；最终文件、应用和相机场景再次通过。

后台请求摘要为 `background-cancel-summary.json`。该场景证明宿主控制请求在实例停止时提前结束；VM 已关机，因此没有单独检查客户机内原 sleep PID。

## 重复启动、端口和失败清理

两个宿主均使用系统自动分配的 kernel debug stub 配置。`lsof -iTCP` 没有返回这两个宿主的 TCP 监听项，因此本次没有记录可比较的实际端口号。

对运行中的 `vm-2607-f2` 再次执行同配置启动，返回 1，错误为 `VM lock unavailable ... Resource temporarily unavailable`。拒绝发生在 VM 创建和端口配置前。拒绝后进程清单只包含原两台宿主，没有失败进程残留。摘要为 `duplicate-start-summary.json`。

路径别名使用 socket 设备号和 inode 在请求前拒绝；该场景由本地 Unix socket 集成测试覆盖，没有为运行中的 VM 创建 socket 别名。

## 离线占用保护

两实例运行时，针对 `vm-2607-f2` 执行以下入口：

| 入口 | 结果 |
| --- | --- |
| `vm export` | 返回 1，报告运行 PID 10723 持有 `boot` 锁 |
| `vm clone` | 返回 1，报告同一持有者 |
| `fw patch --variant exp --quiet` | 返回 1，报告同一持有者 |
| `vm_lock.py ... cfw -- /usr/bin/true` | 返回 1，`VM lock unavailable` |

四个入口均在写入前拒绝。未生成归档、克隆目录、`.firmware-transaction` 或新增 `.cfw_mount.*`；运行记录和 `config.plist` 摘要不变；拒绝后客户机能力查询通过。CFW 场景直接执行安装脚本在 sudo 后使用的共享锁入口，没有执行会触发管理员认证的完整 `cfw install` 命令。摘要为 `offline-guard-f2-running/summary.json`。

## 定位证据

定位使用 2026-09-15 的 E5 双 VM记录：`vm-2607` 与 `vm-2607-rig2` 分别使用不同 owner、坐标、generation 和持久文件；跨实例 generation 停止被拒绝；只重启 rig2 时主实例继续交付，rig2 使用新 generation 恢复自身固定位置。详见 `location_e5_dual_acceptance_2026-09-15.md`。

本次 `vm-2607` 客户机未声明 `location_owned`，因此没有在 `vm-2607` 与 `vm-2607-f2` 上重复定位所有权场景。F2 自动化准备记录允许 E5 双 VM 定位记录作为 F2 的定位证据，但不能替代应用、文件、相机和生命周期结果；这些范围已由本次流程分别覆盖。

## 自动化和回归

`scripts/f2_dual_vm_acceptance.py` 新增应用、相机和离线占用场景，并保留文件和 survivor 场景。应用场景以运行中 PID 判定归属；相机场景校验 generation、presentation ID、复制回执及跨实例停止拒绝；所有可启动的场景均执行清理。

`tests/test_f2_dual_vm_acceptance.py` 共 8 项通过。`make test_python` 共 121 项通过。

## 结果和范围

F2 按当前清单完成。完成范围为两个 VM 同时运行时的应用、文件、定位和相机归属，单实例停止/重启、存活实例、后台请求结束、重复启动、路径别名和离线占用保护。累计完成数更新为 20/28。

该结论只适用于上述两实例规模和已记录组合，不推导任意规模并发能力。相机呈现角色不对称，定位证据使用 `vm-2607` 与 rig2 的 E5 记录，实际 kernel debug stub 端口号未取得，完整 CFW 安装命令未执行。上述限制不扩展为其他固件版本、变体、相机应用或定位客户机组合已通过。

终态：`vm-2607` 和 `vm-2607-f2` 均在运行；运行记录 PID 分别为 21605 和 12736。最终文件、应用和相机场景均完成清理。
