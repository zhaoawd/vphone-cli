# F1：P 组合（26.1 / 23B85）自动步骤运行记录

日期：2026-09-17。方案：[F1 方案](f1_e2e_matrix_plan_2026-09-17.md)（含 §9 用户决定）。

状态：P 组合五个变体已完成自动步骤与人工步骤（2026-09-17 15:09–16:25 UTC），F1 新建的 dev/jb/exp/less 已按用户决定删除（16:26 UTC），regular 实例 d4-acc 保留。N（Frida）组合未开始；L（旧版本）按用户决定不纳入。F1 未完成。

## 实验设置

- 构建：独立工作树 `.build/f1/src`，HEAD `22a7c02`（含 restore 桥接修复），`make build` 签名。该工作树需 `git submodule update --init --recursive` 并复制 `.tools/bin/{trustcache,insert_dylib}` 才能构建。
- 输入：`ipsws/iPhone17,3_26.1_23B85_Restore.ipsw`、`ipsws/399b664d…-727c4f5e2432.ipsw`（cloudOS 26.1/23B85）；less 的 seal 工具 `~/.vphone/tools/apfs_sealvolume_26.1`（SHA-256 `3b1e1e71…a9d4`，与 C4 记录一致）。
- 实例：regular 复用 `.build/d4acc/lib/d4-acc`（由 `8b6365f` 加桥接修复的构建创建，源码与 `22a7c02` 一致；运行步骤用 `22a7c02` 构建）；dev/jb/exp/less 新建于库根 `.build/f1/lib`。
- 自动步骤：`scripts/f1_runtime_acceptance.py`（未提交前的工作树版本，随本记录提交），驱动 `.build/f1/runtime.zsh`：headless 启动 → 客户机连接 → 全部步骤（S4 write）→ 停止 → 再启动 → S4 verify → 停止。相机图像为 CoreImage 生成的 QR PNG（SHA-256 `787bfe33…fd6e`）。
- 证据：`research/artifacts/f1-matrix/`（Git 忽略）；创建日志 `.build/f1/logs/<name>/`（Git 忽略）。

## 创建结果

| 变体 | 实例 | 时间（UTC） | 整体状态 | patch 记录数 | 说明 |
| --- | --- | --- | --- | --- | --- |
| regular | d4-acc | 12:29:38–12:38:27（D4 桥接验收最后一次完整创建） | succeeded | 58 | |
| exp | f1-261-exp | 12:45:30–13:00:31 | completed_unverified | 178 | jb_finalize 按设计 unverified；首次正常启动 13:02:40 读到 `/var/mobile/.vphone_jb_setup_done` 与 `=== vphone_jb_setup.sh complete ===`；日志首行 `/cores/vphone_jb_setup.sh: line 28: /dev/fd/62: No such file or directory`（影响未查明） |
| jb | f1-261-jb | 13:02:05–13:06:53 | completed_unverified | 152 | 首次正常启动 13:08:12 读到完成标记 |
| dev | f1-261-dev | 13:09:57–13:17:14 | succeeded | 70 | |
| less | f1-261-less | 13:47:23–14:29:43 | completed_unverified | 26 | 整体以 root 运行；verification 为前台启动，create 在 VM 被停止前不返回（见“发现”） |

patch 记录数与方案 §3 S1 的历史值一致。less 的 restore 中 URLAsset 第 1 次请求出现真实 `SSLEOFError`，重试后完成。

## 自动步骤矩阵

由 `scripts/f1_support_matrix.py research/artifacts/f1-matrix` 生成（S1–S3 的证据在创建检查点中，生成器未读取，显示 not_run）：

| Combo | Device | iOS | cloudOS | Variant | Options | Commit | preflight | S1 | S2 | S3 | S4 | S5 | S6 | S7 | S8 | S9 | S10 | S11 | S12 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| P | iPhone17,3 | 26.1/23B85 | 26.1/23B85 | dev | - | 22a7c02b9334 | passed | not_run | not_run | not_run | passed | not_run | partial | failed * | not_run | partial | passed (negative) | not_applicable | partial (negative) |
| P | iPhone17,3 | 26.1/23B85 | 26.1/23B85 | exp | - | 22a7c02b9334 | passed | not_run | not_run | not_run | passed | not_run | passed | failed | not_run | partial | failed | not_applicable | partial |
| P | iPhone17,3 | 26.1/23B85 | 26.1/23B85 | jb | - | 22a7c02b9334 | passed | not_run | not_run | not_run | passed | not_run | passed | failed | not_run | partial | passed (negative) | not_applicable | partial (negative) |
| P | iPhone17,3 | 26.1/23B85 | 26.1/23B85 | less | - | 22a7c02b9334 | passed | not_run | not_run | not_run | passed | not_run | partial | failed * | not_run | partial | passed (negative) | not_applicable | partial (negative) |
| P | iPhone17,3 | 26.1/23B85 | 26.1/23B85 | regular | - | 22a7c02b9334 | passed | not_run | not_run | not_run | passed | not_run | partial | failed * | not_run | partial | passed (negative) | not_applicable | partial (negative) |

| 步骤 | 结果要点 |
| --- | --- |
| preflight | 五个变体客户机均连接；headless 启动下 `screenshot/tap/swipe/camera_present` 不可用，`screen_available=false` |
| S4 | 全部 passed。jb/exp 以 `kern.boottime` 变化为证据；regular/dev/less 无 shell，以宿主运行记录 pid 与 startedAt 变化为证据（宿主进程重启证据，不等同客户机内核 boottime）；标记文件在第二次启动后逐字节一致 |
| S6 | jb/exp passed（shell 完成列表、改名、删除）；regular/dev/less 仅 put/get 通过，列表/改名/删除无接口，partial |
| S7 | 全部 failed。regular/dev/less：`uiopen unavailable`（见“发现 1”）；jb/exp：`uiopen ok but no pid`，原因未查明 |
| S9 | 全部 partial：协议层 set/status/generation/stop 通过；应用层读数无探针 |
| S10 | 非 exp：注入 dylib 不存在、无回执，负向记录 passed。exp：相机消费应用 `com.apple.camera` 启动失败（`uiopen ok but no pid`），failed，未进入 present/回执检查 |
| S12 | exp：`kern.Xv_vmm_present=1`、`hv_vmm_present` 不存在、`hw.machine=iPhone17,3`，与 EXP 判据一致；jb：`hv_vmm_present` 存在、`Xv` 不存在、`hw.machine=iPhone99,11`，负向一致；regular/dev/less 无 shell，身份项 blocked，仅注入文件负向检查通过。DeviceTree target-type/compatible、图形、计算三项无接口或探针，blocked |
| S5/S8 | not_run，需人工 |
| S11 | not_applicable（P 不含 --frida） |

## 发现

1. **能力声明与应用启动不一致（事实）**：regular、dev、less 的 vphoned 声明 `apps`，但 `app_launch` 返回 `uiopen unavailable`。`scripts/vphoned/vphoned_apps.m` 只在 `/var/jb/usr/bin/uiopen` 或 `/usr/bin/uiopen` 存在时能启动应用，`apps` 能力按 `gAppsAvailable` 声明，不检查 uiopen。未修改。
   - 修正（未提交，未部署到客户机）：按方案 A 只修正声明。vphoned 新增始终声明的 `apps_v2`，`app_launch` 仅在 apps 可用且 uiopen 可执行时声明，`url` 改为仅在 uiopen 可执行时声明；宿主 app_launch 对 `apps_v2` 客户机要求 `app_launch`，对旧客户机沿用 `apps`。F1 S7 在 `apps_v2` 且无 `app_launch` 时将启动相关检查记为 not_applicable，S10 整步 not_applicable；F2 预检失败信息列出缺失命令与原因。映射表见 [E2 能力发现](host_control_e2_2026-09-12.md#应用与-url-能力映射2026-09-17-修正未提交未部署到客户机)。客户机 vphoned 需重新构建并部署后本矩阵的 regular/dev/less 才会反映新声明；未做真实 VM 验证。
2. **jb/exp 应用未启动（原因未查明）**：`uiopen` 返回成功但未出现进程。待验证假设：客户机停在首次设置助理，或 headless 启动没有显示。需在 GUI 首次设置后复跑 S7、S10。
3. **less 创建的前台 verification**：`vm create -V less` 的 verification 阶段前台启动 VM 并等待其退出；非交互运行时 create 不会自行结束，需要 `vm stop`（root）后才记录 `unverified` 并返回（事实）。
4. **less 实例属主为 root**：bundle 文件与 `vphone.sock`（权限 0600）属主为 root；普通用户的 doctor 报 `host_control_unreachable: Permission denied`，验收脚本、停止与删除均需 root（事实）。
5. **root 运行写入应用包字节码缓存**：见 D4 记录“其他发现”；本轮 less 以 root 运行，同类问题预期出现（未检查）。

## 待人工步骤（按 VM）

所有 F1 VM 需以 GUI 启动（`vphone-cli vm launch <name> -l <lib>`；less 需 root）后执行：

| 步骤 | exp | jb | dev | less | regular(d4-acc) |
| --- | --- | --- | --- | --- | --- |
| 首次设置助理（统一选项待定） | 需要 | 需要 | 需要 | 需要 | 需要 |
| 首次设置后复跑 S7（GUI 启动，`--launch-mode gui`） | 需要 | 需要 | 需要（预期仍因 uiopen 失败） | 同左 | 同左 |
| S10 正向（相机应用 + QR 识别） | 需要 | — | — | — | — |
| S5 GUI 输入与 VZ 窗口鼠标键盘抽查 | 需要 | 需要 | 需要 | 需要 | 需要 |
| S8 DDI（`xcrun devicectl`，信任/开发者模式） | 需要 | 需要 | 需要 | 需要 | 需要 |
| S12 图形（VZ 窗口显示）人工确认 | 需要 | 负向 | 负向 | 负向 | 负向 |

## 空间

创建与运行后 `.build/f1/lib`：dev 24 GiB、exp 27 GiB、jb 27 GiB、less（root，未统计）；数据卷可用约 133 GiB（less 创建前）。按用户决定，F1 新建 VM 在人工步骤完成后删除。

## 人工步骤结果（2026-09-17）

实验设置：逐台以 `vm launch`（less 以 root 直接启动 `--variant less`）GUI 启动；首次设置前经宿主控制 `file_get`/`file_put` 向客户机 `/var/preferences/SystemConfiguration/preferences.plist` 的 en0 服务写入 F2 代理字段（`192.168.64.1:10808`），原文件备份为同目录 `.f1-before-proxy-<时间>`，读回摘要一致后重启生效（`.build/f1/proxy_prep.zsh`、`guest_proxy.py`）。首次设置按 §9.1 选项。人工判定来自用户观察；每台的结构化结果在 `.build/f1/logs/<name>/manual/manual_results.json`（Git 忽略）。

| 步骤 | regular (d4-acc) | dev | jb | exp | less |
| --- | --- | --- | --- | --- | --- |
| 首次设置 | passed | passed | passed | passed | passed |
| S5 点击/滚动/长按/键盘 | passed | passed | passed | passed | passed |
| S5 底部上滑回主屏（鼠标） | failed | passed | failed | passed | failed |
| S5 底部上滑回主屏（宿主注入 swipe 645,2790→1600） | passed | 未测 | failed（两次，前后截图相同） | 未测 | not_run（见下） |
| S7 首次设置后（GUI） | failed（uiopen 缺失） | failed（uiopen 缺失） | partial：launch/terminate passed | partial：launch/terminate passed | failed（headless 结果；GUI 复跑无效） |
| S8 DDI | blocked：Developer Mode 未能开启 | passed（先 `devicectl manage pair`） | passed | passed | blocked：Developer Mode 未能开启 |
| S10 | 负向 passed | 负向 passed | 负向 passed | partial：画面与复制回执 passed，系统相机识别提示未观察到 | 负向 passed |
| S12 图形 | — | — | — | passed（人工） | — |

补充事实：

- **jb/exp 应用启动失败的原因**：首次设置前 jb/exp 的 `app_launch` 返回 `uiopen ok but no pid`；首次设置完成后 exp 启动通过。jb 在屏幕熄灭锁定期间连续 3 次返回同一错误且 `screenshot` 返回 `encodingFailed`，用户确认窗口黑屏锁定，解锁后复跑通过。验收脚本 S7 前缺少屏幕唤醒/解锁检查（待改进）。
- **exp QR**：方形 QR 被取景拉伸裁切；改为 1080×1920 白边竖屏图（文本与 URL 两种内容）后二维码完整位于取景框，12 秒 12 张宿主截图完全相同且无识别提示。用户决定暂不用 E6 探针复测。原因未查明。
- **Developer Mode（regular、less）**：设置中默认无该项；`pymobiledevice3 amfi reveal-developer-mode` 后出现，用户开启并重启后该项消失，`developer-mode-status=false`，无确认弹窗。regular 上另试 `amfi enable-developer-mode`（报 Failed）、直接 action=1（`success=1`，180 秒内未见重启）、action=2（`An unknown error has occured`）、宿主停止并重新启动（状态仍 false，无弹窗）。原因未查明。
- **less 注入补测无效（测试方法错误）**：`less_gui.zsh` 为让普通用户连接，把 root 进程的 `vphone.sock` 属主改为 kolar；普通用户连接得到 `no valid JSON response`，root 运行的客户端又因 socket 属主不是当前用户而拒绝（`scripts/host_control_client.py` 的属主检查）。该次运行已移至 `.build/f1/logs/f1-261-less/manual/invalid-runs/`。用户决定不补测。
- **观察**：用户报告三指从底部上滑可以回主屏（具体 VM 未确认，未计入判定）。
- **发现 5 确认**：F1 应用包 `Contents/Resources/scripts/patchers/__pycache__/*.pyc` 属主为 root（less 以 root 运行后）。
- **删除**：`vm delete` 删除 f1-261-dev（29 GiB）、f1-261-jb（29 GiB）、f1-261-exp（30 GiB），less 以 sudo 删除；数据卷可用由 86 GiB 变为 202 GiB（`.build/f1/logs/delete.log`）。

结论：P 组合 regular/dev/jb/exp/less 完成 F1 规定步骤的一轮执行，S1–S4、S6、S9（协议层）、S12（可判定部分）按上表；S7 在 regular/dev/less 因 uiopen 缺失失败（能力声明修正见 `5fd007c`，未部署）；S8 在 regular/less 阻塞；jb 底部回主屏手势与 exp 系统相机 QR 识别提示原因未查明。P 组合不满足全部步骤通过。
