# F1 精确组合端到端验收矩阵：盘点与执行方案

日期：2026-09-17。代码基线：`c373a65`（分支 `codex/autophone-location-multivm-integration`）。

范围：本文是离线规划。本轮只读盘点文件、进程和磁盘，未启动、停止或连接任何 VM 控制 socket，未挂载镜像，未下载固件，未删除文件，未提交。工作项定义见 [迭代清单 F1](project_iteration_checklist_2026-09-08.md)。

标记约定：未加标记的陈述为本轮命令输出或仓库记录中的事实；“推断”为依据事实的推理；“待验证假设”为尚无证据的判断；“需用户决定”为执行前需要确认的事项。

## 1. 盘点结果

### 1.1 本地固件样本

来源命令：`ls -la ipsws ~/.vphone/ipsws`；`unzip -p <ipsw> BuildManifest.plist` 后用 `plutil -extract ProductVersion/ProductBuildVersion/SupportedProductTypes`。

| 文件 | 位置 | 大小（字节） | 版本 / 构建 | SupportedProductTypes | 角色 |
| --- | --- | --: | --- | --- | --- |
| `iPhone17,3_26.1_23B85_Restore.ipsw` | `ipsws/`、`~/.vphone/ipsws/` 各一份 | 10,778,507,403 | 26.1 / 23B85 | `iPhone17,3` | iPhone |
| `399b664dd623…-727c4f5e2432.ipsw` | `ipsws/`、`~/.vphone/ipsws/` 各一份 | 935,422,803 | 26.1 / 23B85 | `ComputeModule14,1/14,2`、`Mac14,14`、`iPhone99,11` | cloudOS（catalog `cloud261`） |
| `iPhone17,3_26.6.1_23G82_Restore.ipsw` | 仅 `~/.vphone/ipsws/` | 11,254,333,223 | 26.6.1 / 23G82 | `iPhone17,3` | iPhone |
| `c0ecdb4b310c…-b80d96a0b616.ipsw` | 仅 `~/.vphone/ipsws/` | 1,199,454,323 | 26.4 / 23E5207q | 增加 `ComputeModule17,2` | cloudOS（catalog `cloud264`） |

- D4 检查点记录的 SHA-256：iPhone 26.1 为 `fe83303ca9a68fa7759339bac37a75358638111da42bea48ef91e351fdac649a`，cloudOS 26.1 为 `9bc9114d9d968071e8457bec89d028c381ef0453956c166cb191bb4b5a4f8ba5`（`.build/d4acc/lib/d4-acc/.create-checkpoint/checkpoint.json`）。26.6.1 与 cloudOS 26.4 本轮未计算摘要。
- 两个目录中的 26.1 文件 inode 不同、大小相同、首 1 MiB 相同；是否为 APFS 克隆未确认。
- 与 catalog 的差异：`sources/VPhoneCore/VPhoneFirmwareCatalog.swift:58` 的 iOS 26.6.1 配对为 **23G83**；本地样本为 **23G82**。`research/firmware_compatibility.json` 中 `cap-2661-exp-rigbaseline` 记为 23G83，而该实例的 `~/.vphone/VMs/rig-baseline/restore-info.json` 记录 iOS 23G82、cloudOS 26.4 / 23E5207q。两处构建号不一致，清单条目需要更正（本轮未修改）。C3 的 `pv-2661-*` 使用 23G83 输入，该输入本地已不存在。
- catalog 其他配对（18.6.2、26.0、26.0.1、26.2–26.5.2、26.6、27.0 beta）及 cloudOS 26.2、26.3 本地无样本。
- less 的 seal 工具：`.tools/apfs_sealvolume_26.1` 存在（C4 记录 SHA-256 `3b1e1e71…a9d4`，来源 `.build/c4-seal/provenance.json`）。`apfs_sealvolume_26.6.1`、`apfs_sealvolume_18.6.2` 不存在；`CryptexFilesystemPatcher.swift:440` 按 `apfs_sealvolume_<iOS 版本>` 查找，`scripts/fw_prepare.sh:414` 的下载函数在缺失时联网获取，C4 记录该函数对 26.1 曾选错 beta 版本。
- `~/.vphone/debs` 只有 3 个 openssh 包，无 Frida deb；`~/.vphone/tools` 为空。`--frida` 创建时由 `scripts/fetch_debs.sh:75-87` 联网获取 GitHub 最新 Frida iOS 发布包。

### 1.2 现有 VM 与占用

来源命令：`du -sk`、`stat`、读取各目录 `restore-info.json` / `.vphone-runtime.json`、`ps axo pid,etime,command`。`du` 包含 APFS 克隆共享块，C5 记录中 `du` 83G 对应 `df` 只减少约 1 GiB，因此 `du` 不能当作删除后的释放量。

| 路径 | du 总计 | Disk.img du（逻辑 64 GiB） | 变体 / 版本记录 | 运行状态 | F1 可用性 |
| --- | --: | --: | --- | --- | --- |
| `vm-2607` | 40.87 GiB | 25.76 GiB | EXP，26.1 / 23B85（清理记录补写的 restore-info，当前目录无该文件，版本信息见 `vm_input_cleanup_2026-09-16.md`） | **运行中**：宿主 PID 41303（autophone 启动），健康监控 41825，rig agent 81291（声明 `frida` 能力） | 其他任务占用，不纳入 |
| `vm` | 37.81 GiB | 22.49 GiB | 无 restore-info，含 26.1 Restore 目录；变体含义待确认 | 运行记录 PID 70367（2026-09-10），ps 未匹配 vphone-cli 进程 | 构建与变体未知，不作为 F1 证据 |
| `vm-new` | 30.92 GiB | 20.56 GiB | 无 restore-info；D3 记录其 System 卷已有 Cryptex | 记录 PID 31998（操作 `d3-clone`），ps 未匹配 | 不作为 F1 证据 |
| `vm.backups/before-20260723-update` | 27.87 GiB | — | `vm-2607` 的 7 月备份 | 未运行 | 不作为 F1 证据 |
| `~/.vphone/VMs/rig-baseline` | 21.73 GiB | 21.70 GiB | EXP，iOS 26.6.1 / **23G82**，cloudOS 26.4 / 23E5207q | 记录 PID 26714（2026-09-08），ps 未匹配 | 创建构建早于 A3/E5/E6 修复；可做补充观察，不能作为当前构建的创建证据 |
| `.build/d4acc/lib/d4-acc` | 76.19 GiB | 14.32 GiB | regular，26.1 / 23B85，设备 `iPhone99,11` | 记录 PID 78373，ps 未匹配；关机 | **可复用**（见 §2.2） |
| 其中 `.firmware-history` | 61.84 GiB | — | D4 多次补丁事务归档 | — | 可在授权后清理 |
| `.build/d3/vm-exp` | 24.80 GiB | 14.39 GiB | exp，26.1 / 23B85；含 10.33 GiB Restore | 未启动过（D3 未验证启动） | 由 `fw_patch`+恢复+`cfw install` 生成，未经 `vm create`；可作为备选 |
| `.build/d3/vm-regular` | 24.27 GiB | 13.88 GiB | regular，26.1 / 23B85；含 Restore | 同上 | 同上 |
| `.build/c5/lib/vmA–vmD` | 各约 20.6 GiB，合计 103.77 GiB | 无 Disk.img | 仅 Restore 与 AVPBooter（补丁实验） | — | 不含磁盘，不适用 |
| `research/artifacts/c4-less-2026-09-11` | 18.59 GiB | — | less 事务输入 | — | 不含 VM |
| `research/artifacts/c3-less-pipeline-2026-09-10` | 9.39 GiB | — | 成功 AEA 已删除 | — | C3 less 恢复需重新生成 |

- 历史实例 `vm-2607-rig2`（A3、E5、E6 使用）、`vm-2607-f2`（F2 使用）、`vm-c3-runtime-20260914` 当前均不存在。后者的删除有记录；前两者的删除或移动记录在本轮查阅的研究文档中未找到，原因未查明。
- 历史证据目录 `research/artifacts/{e5-primary-rig2-2026-09-15, rig2-setup-20260916-*, f2-dual-vm-2026-09-17, c3-less-runtime-2026-09-14, vm-cleanup-2026-09-16}` 当前不存在。`research/artifacts` 受 `.gitignore:331` 忽略。现存子目录只有 `c3-full-pipeline-2026-09-10`、`c3-less-pipeline-2026-09-10`、`c4-less-2026-09-11`、`d3-cfw-2026-09-17`、`touch-native-vs-guest-2026-09-09`。
- 其他进程：amfidont PID 19950，以 `--path /Users/kolar/github/vphone-cli` 和两个 cdhash 运行；未匹配到 restore 桥接进程。ChatGPT/Codex 沙箱进程以本仓库为工作目录运行（与本任务的关系未确认）。
- 签名应用：`.build/vphone-cli.app` 主程序 SHA-256 `80f23f1f…a22ac0`（`vm-2607` 使用路径）；D4 独立工作树 `.build/d4acc/src`（`8b6365f`）主程序 `662b1b7b…d4ba593`，与 d4-acc 检查点记录的 `tool.executable_sha256` 一致。`git diff --stat 8b6365f c373a65` 只涉及 3 个研究文档，源码无差异。

### 1.3 宿主与空间

| 项 | 值 | 来源 |
| --- | --- | --- |
| 数据卷可用 | 235,194,920 KiB ≈ **224.3 GiB**（容量 926.3 GiB，已用 76%） | `df -k /System/Volumes/Data` |
| 宿主 | macOS 26.5 / 25F71；15 核；48 GiB 内存；SIP 自定义配置（Debugging Restrictions disabled） | `sw_vers`、`sysctl`、`csrutil status` |
| Xcode | 26.6 / 17F113；`xcrun devicectl` 518.33，含 `device info ddiServices` | `xcodebuild -version`、`devicectl --help` |
| Frida 客户端 | 仓库 `.venv` 与系统 python 无 `frida` 模块；`/Users/kolar/github/autophone/.venv/bin/frida` 为 **17.16.1**（autophone 项目环境） | `frida --version` |

历史空间数据（均非严格峰值实测）：

| 来源 | 数据 |
| --- | --- |
| D4 regular 26.1 | restore 树 11,060,214,840 字节；安装后 Disk.img du 14.32 GiB；12 次尝试后 `.firmware-history` du 61.84 GiB；完整从 prepare 到 verification 一次约 4 分 20 秒（12:02:30–12:06:50，含管理员认证） |
| D3 四变体 26.1 | 四台 VM 的准备与恢复使 `df` 可用从约 380 降至约 328 GiB（约 52 GiB，含克隆共享）；清理后增加 85 GiB |
| C4 less 26.1 | 建议预算约 60 GiB，非峰值实测；历史一次运行中可用空间降至约 2.7 GiB 后中止；完整流水线 341 秒、26 条补丁记录 |
| C3 less 运行 | 恢复前可用 40.05 GiB，结束时 18.69 GiB（期间含其他写入） |

### 1.4 已有运行证据及可引用范围

判断规则：F1 支持矩阵的一个格子对应“iPhone 构建 + cloudOS 构建 + 变体 + 选项 + vphone-cli 构建”。不同构建、变体或选项的结果不能填入该格子，只能作为背景。

| 工作项 | 实例 / 组合 | 覆盖能力 | 构建 | 能否按同一精确组合引用 |
| --- | --- | --- | --- | --- |
| C3 less 运行 | `vm-c3-runtime-20260914`，less 26.1/23B85 | 恢复、两次普通启动、串口、版本、Library 文件持久性、正常关机；无 shell 能力 | `7015991` | 否：实例已删，构建早于 D3/D4，且未覆盖 GUI、应用、DDI、定位、相机 |
| C4 | less 26.1 补丁流水线 | 事务、Manifest、备份校验；无恢复与启动 | 2026-09-17 构建 | 仅补丁阶段背景 |
| D3 | `.build/d3/vm-*` 26.1 四变体 | 固件准备、恢复、CFW 首次与重复安装、System 卷清单 | D3 构建 | 否：未启动；未经 `vm create` |
| D4 | `d4-acc` regular 26.1/23B85 | `vm create` 全阶段、中断续跑、first_boot 提示符、verification | `8b6365f`（源码同 HEAD） | **创建、恢复、首次启动提示符可引用**到 regular 26.1 格子，条件是 F1 执行构建与 `8b6365f` 源码一致；GUI、第二次完整启动等未覆盖 |
| D5 | `d4-acc`、`vm-2607` | 只读诊断 | `8b6365f` | 作为前置检查工具 |
| A3 | `vm-2607-rig2` EXP 26.1/23B85 | 触控点击、拖动、长按、底部边缘手势、缩放、断线重连 | E3/A3 隔离构建 | 否：实例不存在，构建不同；证明协议与实现可行 |
| E5 | `vm-2607` + rig2，EXP 26.1 | 定位协议状态、交付确认、持久文件、双 VM 隔离；**不含应用内 CoreLocation 读数** | 修复版隔离宿主 | 否；且判据层级低于应用读数 |
| E6 | rig2 EXP 26.1 | 相机复制回执、QR 标准回调、视频、系统相机可见、服务/系统重启 | `.build/e6-final`（已不存在） | 否 |
| F2 | `vm-2607` + `vm-2607-f2` EXP 26.1 | 双 VM 文件、应用、相机、停止存活、占用保护 | F2 构建 | 否；另记录新实例需在客户机 `en0` 配置 HTTP/HTTPS 代理才能完成首次设置 |
| 兼容性清单历史条目 | 27.0/24A5408d + cloudOS 26.4 jb `--frida` | DDI auto-mount、jb-setup、frida-server 端口；**未运行宿主客户端** | 7–8 月构建 | 否；版本不在本地 |
| 兼容性清单历史条目 | rig-baseline EXP 26.6.1 | 客体触控、vm stop | 2026-09-08 构建 | 否 |

结论（事实归纳）：当前没有任何格子已具备 F1 要求的全部步骤证据。本轮查阅的记录中，没有 dev、jb、exp、less 通过 `vm create` 完成创建的记录；也没有宿主 Frida 客户端 instrumentation 的记录。

### 1.5 可复用自动化

| 入口 | 用途 | F1 复用限制 |
| --- | --- | --- |
| `vphone-cli vm create <name> -l <lib> -V <variant> -i <iPhone> -c <cloudOS> [--frida] [-b <build>] --root-popup [--keep-artifacts]` | 创建全流程及检查点 | restore 桥接挂起问题已于 2026-09-17 在桥接脚本中修复并实机验收（见 D4 记录） |
| `vphone-cli vm create-status <name> -l <lib> --json` | 阶段状态、证据、产物 | 只读 |
| `vphone-cli doctor [<name>] -l <lib> --json` | 宿主、签名、VM 运行状态诊断 | 不报告 JB 首启收尾 |
| `vphone-cli vm launch <name> -l <lib> [--headless] [-V <variant>]`、`vm stop <name> [--timeout N]` | 启动与停止 | less 需 `-V less` |
| 宿主控制 socket `<vm>/vphone.sock`（换行分隔 JSON，`t` 字段） | `capabilities`、`screenshot`、`tap`、`swipe`、`key`、`type`、`shell`、`file_get/put`、`app_launch/terminate/list/foreground`、`open_url`、`ipa_install`、`camera_present/status/stop`、`location_source_*`、`location`/`location_stop`（`VPhoneHostCommandExecutor.swift`） | `vphoned` 固定声明 `touch`、`vcam_status`、`vcam_receipt_v3`（`scripts/vphoned/vphoned.m:526-529`），声明本身不证明功能可用 |
| `scripts/f2_dual_vm_acceptance.py` | Endpoint/Evidence 记录、`capabilities` 预检、文件、应用、相机、占用保护场景 | 按双实例设计；可抽取单实例部分 |
| `research/probes/a3_input_matrix.py`、`a3_home_swipe.py`、`a3_screen_state.swift`、`display_state.c` | 触控矩阵、主屏判定 | 路径硬编码 `vm-2607-rig2`，坐标限 1290×2796，OCR 依赖简体中文布局 |
| `research/probes/camera_qr_probe.m`、`build_camera_qr_probe.sh` | QR 标准回调 | 需要图形用户客户端权限；仅 EXP 有相机注入 |
| `research/a3_rig2_probe.py` | 截图与请求记录 | 路径硬编码 rig2 |
| `research/d3_cfw_inventory.py` | 关机状态下只读挂载 System 卷，输出文件摘要 | 需管理员权限挂载，VM 必须关机 |
| `xcrun devicectl device info ddiServices --device <UDID>` | DDI 服务状态 | 仓库内无封装；26.x 客体上的行为未验证 |
| `make test`、`make test_fw_patches` | 无 VM 回归、补丁流水线 | 不代替运行验收 |

缺口：仓库没有单实例运行验收脚本、没有 `tests/runtime/`、没有 Frida 客户端验收脚本、没有 EXP 图形/计算探针、没有支持矩阵生成器。

## 2. 建议组合

### 2.1 组合定义

| 组合 ID | iPhone IPSW | cloudOS IPSW | 变体与选项 | 本地可得性 | 选择理由 |
| --- | --- | --- | --- | --- | --- |
| **P（主要回归）** | `iPhone17,3_26.1_23B85_Restore.ipsw`（SHA-256 `fe83303c…c649a`） | `399b664d…-727c4f5e2432.ipsw`，26.1/23B85（SHA-256 `9bc9114d…f8ba5`） | less、regular、dev、jb、exp；均不带 `--frida` | 全部本地；less seal 工具存在 | 与 C3/C4/D3/D4/A3/E5/E6/F2 同版本，历史问题可对照；d4-acc 可复用 |
| **L（旧版本）** | catalog `iPhone17,3_18.6.2_22G100_Restore.ipsw`（`VPhoneFirmwareCatalog.swift:44`） | 同 P 的 cloudOS 26.1/23B85 | regular、dev、jb、exp；less 暂不纳入 | **iPhone IPSW 本地缺失** | catalog 配对最旧版本；C3 已有 `pv-1862-c3-bootchain-20260910`；触发 `iosBaseIs18`（EXC_GUARD）和 18.x DSC SwapEnd 尺寸补丁，与 26.1 的代码路径不同 |
| **N（Frida 适用范围）** | `iPhone17,3_26.6.1_23G82_Restore.ipsw`（本地，**非 catalog 构建**） | `c0ecdb4b…-b80d96a0b616.ipsw`，26.4/23E5207q | jb `--frida`、exp `--frida` | 本地；less 缺 `apfs_sealvolume_26.6.1` | `FirmwarePipeline.swift:103-104` 只在 cloudOS 26.4 及以上应用 Frida 内核放宽；P 与 L 使用 cloudOS 26.1，不满足该门控 |

说明：

- N 的 iOS 版本高于 P，不能称为旧版本组合。F1 要求的“旧版本组合”只能由 L 满足，L 需要获取样本。
- 获取 L 所需内容（本轮未下载）：catalog URL `https://updates.cdn-apple.com/2025SummerFCS/fullrestores/093-20738/98758B5A-311E-4538-B365-FEE3D8792CDF/iPhone17,3_18.6.2_22G100_Restore.ipsw`；大小未知（推断：与 26.x 的约 10 GiB 同一量级）；下载后记录 SHA-256 与 BuildManifest 版本。若要纳入 L-less，还需 `apfs_sealvolume_18.6.2`，其 macOS 对应版本的选择规则待确认。
- N 的构建号问题（需用户决定）：选项 A 使用本地 23G82，矩阵中明确标注“非 catalog 配对，经 `-i` 本地路径指定”；选项 B 下载 catalog 23G83（`VPhoneFirmwareCatalog.swift:58`），与 C3 `pv-2661-*` 的补丁证据保持一致。若 N 改为 27.0/24A5408d（历史 Frida 记录版本），也需要下载。
- P 的 jb/exp 是否额外做 `--frida`：cloudOS 26.1 下只安装 frida-server，不应用内核放宽。建议不纳入主矩阵；如执行，单独记为 `P-jb-frida`，结果不外推到 N。

### 2.2 d4-acc 复用条件

- 事实：d4-acc 为 regular、26.1/23B85，使用与 P 相同的两份 IPSW（检查点 SHA-256 一致），检查点整体 `succeeded`，7 个阶段中 `jb_finalize` 为 `not_applicable`，其余为 `succeeded`；restore 树已按默认规则删除。
- 可引用：P-regular 的“创建、恢复、首次启动提示符”步骤，证据为检查点 JSON 与 `.build/d4acc/logs/`（Git 忽略，需复制摘要，见 §5）。
- 条件：F1 执行时使用的 vphone-cli 与 `8b6365f` 源码一致。若 restore 桥接修复改变了创建相关源码，推断该创建证据不再对应新构建，需用户决定是否在新构建上重新创建 P-regular。2026-09-17 更新：桥接修复只改 `scripts/pymobiledevice3_bridge.py`；`d4-acc` 已由 `8b6365f` 加该修复的构建重新执行 prepare 至 verification（D4 记录“实机验收”），与包含该修复的提交源码一致（Swift 与其他脚本未变）。
- 未覆盖：d4-acc 未完成过 GUI 首次设置，未做第二次完整启动后的能力检查。
- d4-acc 的 12 次续跑包含中断路径；最终状态来自 12:07:50 开始的 prepare 至 12:12:07 verification（4a–4c 续跑），而 12:02:30–12:06:50 的场景 3 是一次无中断的完整创建。矩阵中两者分别列出，不合并。

## 3. 每组合验收步骤与判据

### 3.1 步骤适用性

| 步骤 | less | regular | dev | jb | exp |
| --- | --- | --- | --- | --- | --- |
| S1 创建（prepare/patch/cfw） | 适用（cfw 适用性以检查点为准） | 适用 | 适用 | 适用 | 适用 |
| S2 恢复 | 适用 | 适用 | 适用 | 适用 | 适用 |
| S3 首次启动 | 适用 | 适用 | 适用 | 适用，含 JB 首启收尾 | 适用，含 JB 首启收尾 |
| S4 第二次启动 | 适用 | 适用 | 适用 | 适用 | 适用 |
| S5 GUI 输入 | 适用 | 适用 | 适用 | 适用 | 适用 |
| S6 文件 / S7 应用 | 按客户机能力声明；C3 less 无 `shell` | 适用 | 适用 | 适用 | 适用 |
| S8 DDI | 待验证假设：可能需开发者模式 | 适用 | 适用 | 适用 | 适用 |
| S9 定位 | 按 `location` 能力 | 适用 | 适用 | 适用 | 适用 |
| S10 相机 | 负向：应无注入 | 负向 | 负向 | 负向 | **正向**（`libvcamcaptured`、`libcamfix` 仅由 `scripts/cfw_install_exp.sh` 安装） |
| S11 Frida 客户端 | 不适用 | 不适用 | 不适用 | 仅 `--frida` 组合 | 仅 `--frida` 组合 |
| S12 EXP 身份 / 图形 / 计算 | 负向 | 负向 | 负向 | 负向 | 正向 |

“负向”步骤的目的是确认非 EXP 变体未获得 EXP 改动，结果计入 S12/S10 的负向记录，不计为相机或身份功能通过。

### 3.2 步骤清单

每步记录：开始/结束时间（UTC）、命令原文（去除凭据）、退出码、证据文件路径与 SHA-256、判定（`passed`/`failed`/`partial`/`blocked`/`not_applicable`/`not_run`）、失败时的阶段与日志行。截图或端口连通等间接信号只作为附属证据。

| 步骤 | 命令 / 入口 | 证据 | 通过判据 | 失败判据 | 人工环节 |
| --- | --- | --- | --- | --- | --- |
| S0 前置 | `git rev-parse HEAD`、`git status --porcelain`（独立工作树）；`make build`；`make check_bundle`；`vphone-cli doctor --json`；`df -k`；`ps` 核对无同 bundle 进程 | `preflight.json`：提交、主程序 SHA-256、vphoned SHA-256、宿主版本、可用空间 | 工作树干净；签名检查通过；doctor 无 error；可用空间满足 §4 | 任一不满足即不开始 | 启动 amfidont 放行新 cdhash 需管理员密码（`make amfidont_allow_vphone` 或 `scripts/start_amfidont_for_vphone.sh`） |
| S1 创建 | `vphone-cli vm create <name> -l .build/f1/lib -V <variant> -i <iPhone> -c <cloudOS> [--frida] --root-popup -v` | `create.log`、`vm create-status --json` 输出、`checkpoint.json` 副本、`.firmware-history` 中事务 journal 的补丁记录数 | 检查点整体 `succeeded`；prepare 证据中 iOS/cloudOS 版本与构建和组合定义一致；patch 记录数与同输入历史值一致或差异已解释（26.1：regular 58、dev 70、jb 152、exp 178，less 26）；`restore-info.json` 的 variant 一致 | 整体为 `failed`/`interrupted`/`recovery_required`/`incomplete`；版本不一致；补丁 `failedRequired` 非空 | CFW 阶段 macOS 管理员认证窗口 |
| S2 恢复 | S1 内 restore 阶段 | 检查点 restore 证据（`restore_update_exit`、`post_restore_dfu_outcome`、ECID/UDID） | `restore_update_exit = 0` 且 DFU 结果 `matched` | 非零退出；restore-update 超过约定上限（建议 30 分钟）无输出按 `blocked` 记录并保留进程列表 | 若出现桥接挂起，需人工终止（§6） |
| S3 首次启动 | S1 内 first_boot/verification；随后 `vm launch <name> -l <lib>`（GUI 窗口） | 检查点证据；宿主启动日志；控制 socket `capabilities` 响应；JB/EXP 另取 `/var/log/vphone_jb_setup.log`（经 `shell` 或 `file_get`） | first_boot `prompt matched`、verification 成功；GUI 启动后 `capabilities` 返回且 `ios` 字段版本匹配；JB/EXP 首启日志显示收尾完成且无重复 respring | 宿主启动成功但客户机未连接；panic；首启脚本失败 | **首次设置助理**（语言、地区、年龄段等）；按 F2 结论配置客户机 `en0` HTTP/HTTPS 代理；需记录人工选择的项目 |
| S4 第二次启动 | `vm stop <name>`（客户机正常关机优先）后 `vm launch` | 两次启动的 `kern.boottime`（`shell` 或文件接口读取）、`capabilities`、首次写入 `/var/mobile/Library/f1-<run>.txt` 的标记在第二次启动后读回 | boottime 变化；标记逐字节一致；连接成功 | 标记丢失；启动失败 | 无（若屏幕锁定，需按 A3 流程唤醒） |
| S5 GUI 输入 | 控制 socket `key power` 唤醒 → `tap`/`swipe`/`type`；参数化后的 `a3_input_matrix.py basic` | `requests.jsonl`、每步前后截图、宿主窗口截图（人工） | 点击进入设置、列表拖动滚动、长按出现菜单、底部边缘上滑回主屏；截图双帧判定 | 截图无变化或停留原页面；`touch_edge` 未声明时边缘手势记 `not_applicable` 而非通过 | VZ 窗口内鼠标点击与键盘输入的人工抽查（原生路径） |
| S6 文件 | `file_put` → `file_get` → `file_list` → `file_rename` → `file_delete` | 请求记录、读回内容摘要 | 读回摘要一致；删除后 `file_get` 返回不存在 | 摘要不一致或残留 | 无 |
| S7 应用 | `app_list` → `app_launch com.apple.Preferences` → `app_foreground`/截图 → `app_terminate`；jb/exp 另做 `ipa_install` 测试包 | PID、截图 | 启动后 running 列表出现对应 PID，截图为设置；终止后 PID 消失；`ipa_install` 后应用可启动 | PID 不变化或截图不符 | 测试 IPA 来源需用户指定（历史记录用过 `com.vphone.vptest`） |
| S8 DDI | `xcrun devicectl list devices`；`xcrun devicectl device info ddiServices --device <UDID> --json-output ddi.json` | `ddi.json`、客户机串口中的 `Xcode_iOS_DDI` 挂载行（`-vv`） | JSON 报告 DDI 服务可用；客户机有 DDI 卷挂载记录 | 设备不可见、DDI 不兼容或挂载失败 | 可能需在客户机信任宿主、开启开发者模式（vphoned 声明 `devmode`）；26.x 客体上的具体交互待验证 |
| S9 定位 | `location_source_set` 固定坐标 → `location_source_status` → 客户机应用读数 → `location_source_stop` | 请求记录、generation、应用读数截图或探针输出 | 协议层：generation/交付确认正确；**应用层**：CoreLocation 读数与设定坐标一致（误差阈值需事先写定） | 协议通过但应用读数不符时记 `partial`，不记 `passed` | 首次定位授权弹窗；应用层探针当前不存在，需新建（E5 未覆盖该层） |
| S10 相机 | EXP：`camera_present source=image`（QR 图）→ `camera_status` 回执 → 系统相机或 `camera_qr_probe` 读取 → `camera_stop`；非 EXP：同样请求并检查客户机 `/var/jb/usr/lib/libvcamcaptured.dylib` 不存在 | 回执、QR 回调输出、截图；非 EXP 为文件检查结果与请求响应 | EXP：同 `presentation_id` 的复制回执 + QR 文本正确 + 相机画面截图；非 EXP：无注入文件且无有效复制回执 | EXP 缺任一层；非 EXP 出现注入文件或有效回执 | 相机权限弹窗；QR 探针需签名部署 |
| S11 Frida 客户端 | 宿主：固定版本 Frida 客户端（建议在仓库 venv 或独立 venv 安装，与客户机 frida-server 主版本一致）；`frida-ps -H <host:port>` 或经 usbmux；`frida -H … -n SpringBoard -l hook.js` 执行一个可观察的 hook（例如对 `open` 计数并回传消息）；另做 Stalker 跟随现有线程的会话 | 客户端与服务端版本、脚本原文、消息输出 | 附加成功，脚本回传预期消息，卸载后目标进程存活；Stalker 会话产生事件 | 仅端口连通或仅 `frida-ps` 成功记 `partial`；附加失败或目标崩溃记 `failed` | 客户端安装来源需用户决定（§7）；autophone venv 17.16.1 不属于本仓库 |
| S12 EXP 专项 | 客户机 `shell`：`sysctl kern.hv_vmm_present`、`sysctl kern.Xv_vmm_present`；读取 DeviceTree 的 `model`/`target-type`/`compatible` 与 MobileGestalt 相关值；`/usr/libexec/watchdogd` 运行状态；`-b <build>` 时读 `SystemVersion.plist`；图形：VZ 窗口正常显示、`AppleParavirtGPU` 加载、系统相机与动画截图；计算：Metal compute 探针（**需新建**） | 命令输出、截图、探针结果；非 EXP 同命令输出 | EXP：`kern.hv_vmm_present` ENOENT 且 `kern.Xv_vmm_present` 为 1；DT 身份字段为 EXP 改写值；图形与计算探针通过。非 EXP：`kern.hv_vmm_present` 存在、无 `Xv_vmm_present`、DT 保持原值、无 EXP 注入文件 | 任一预期不符；失败绑定组合、阶段与日志 | 无（计算探针构建与签名需准备） |

补充：关机后可用 `research/d3_cfw_inventory.py` 做 System 卷只读清单，作为 S12 负向检查的离线证据；该操作需要管理员权限挂载镜像，需单独授权。

## 4. 执行顺序、空间预算与清理

### 4.1 预算（推断）

依据 §1.3：非 less 单台创建完成后，默认清理条件下保留 Disk.img（约 14–15 GiB，首次设置和应用使用后增长，`vm-2607` 为 25.76 GiB）与至少一个 `.firmware-history` 归档（约 10 GiB 量级）；创建过程中另有约 10.3 GiB restore 树。建议每台非 less 创建前可用空间不低于 **80 GiB**，less 不低于 **100 GiB**（C4 建议 60 GiB 加余量）。同时保留的 F1 VM 不超过 2 台。这些阈值未经峰值实测，执行时应在每个阶段结束记录 `df -k`，形成实测峰值。

当前 224.3 GiB 可以满足逐台执行，无需先清理。以下为可选释放项，均需用户逐项授权：

| 候选 | du | 删除影响 |
| --- | --: | --- |
| `.build/d4acc/lib/d4-acc/.firmware-history` | 61.84 GiB | 失去 D4 补丁事务归档；D4 已关闭，检查点与日志保留 |
| `.build/c5/lib/vmA–vmD` | 103.77 GiB（实际释放量应小得多，含克隆共享） | 失去 C5 补丁实验输入；记录 JSON 在 `.build/c5/records` |
| `.build/d3/vm-regular`、`vm-exp` | 24.27、24.80 GiB | 失去 D3 保留的两台未启动 VM |
| `research/artifacts/c4-less-2026-09-11` | 18.59 GiB | 失去 C4 事务输入 |
| `~/.vphone/ipsws` 中与 `ipsws/` 重复的 26.1 两个文件 | 约 10.9 GiB（是否克隆未确认） | 需先确认 `vm create` 默认缓存路径不依赖该目录 |

### 4.2 执行顺序

| 顺序 | 组合-变体 | 实例 | 前置 | 预计新增占用 | 结束后处理（需授权） |
| --- | --- | --- | --- | --- | --- |
| 0 | S0 前置 | 独立工作树 `.build/f1/src`、库根 `.build/f1/lib` | restore 桥接修复已合入（2026-09-17 已完成）；amfidont 放行 | 构建约数 GiB | — |
| 1 | P-regular | 复用 `d4-acc`（S3 起执行 GUI 步骤） | §2.2 条件成立 | Disk.img 增长 | 保留至 P 组完成 |
| 2 | P-exp | 新建 `f1-261-exp` | 可用 ≥ 80 GiB | 约 25–35 GiB | 保留，作为 S12 正向对照 |
| 3 | P-jb | 新建 `f1-261-jb` | 同上 | 同上 | 验收后释放或保留，询问 |
| 4 | P-dev | 新建 `f1-261-dev` | 释放 3 或空间足够 | 同上 | 验收后释放，询问 |
| 5 | P-less | 新建 `f1-261-less` | 可用 ≥ 100 GiB | 峰值未实测 | 验收后释放，询问 |
| 6 | N-exp-frida、N-jb-frida | 新建 `f1-2661-exp-frida`、`f1-2661-jb-frida` | §7 决定 N 的构建与 Frida 客户端；创建需联网获取 frida deb | 各约 25–35 GiB | 逐台释放，询问 |
| 7 | L-regular/dev/jb/exp | 新建 `f1-1862-*` | 用户授权下载 18.6.2 IPSW | IPSW 约 10 GiB + 每台 25–35 GiB | 逐台释放，询问 |

顺序理由：先复用已有 regular，再做能力面最大的 EXP，使相机、身份正向证据尽早可用；jb/dev/less 依次作为对照。每台 VM 独占执行，不与 `vm-2607` 共用 socket、端口或锁；两台 VM 同时运行时内存需求为 16 GiB（宿主 48 GiB）。

### 4.3 每步所需授权

| 动作 | 授权类型 |
| --- | --- |
| 启动 amfidont 放行新构建 | 管理员密码；改变宿主签名校验行为 |
| `vm create` 的 CFW 阶段 | macOS 管理员认证窗口，每台一次 |
| 启动 / 停止 F1 专用 VM | 本任务范围内需用户确认开始执行 |
| 首次设置助理、权限弹窗、信任与开发者模式 | GUI 人工操作 |
| 客户机网络代理配置 | 修改客户机系统配置 |
| 下载 18.6.2（及可选 23G83、seal 工具、Frida deb） | 网络下载授权 |
| 安装宿主 Frida 客户端 | 修改 Python 环境 |
| `d3_cfw_inventory.py` 只读挂载 | 管理员权限 |
| 删除 F1 VM 或 §4.1 候选 | 逐项删除授权 |
| 修改 `research/firmware_compatibility.json`、提交 | 单独确认 |

## 5. 支持矩阵生成

### 5.1 运行记录（建议结构，未实现）

每个组合-变体一次运行写一份 `run.json`，完整证据放在 `research/artifacts/f1-matrix/<run_id>/`（Git 忽略）。由于历史证据目录已有多个不在本地，建议另把去除大文件后的摘要提交到 `research/f1_runs/<run_id>.json`，使 `firmware_compatibility.json` 的 `evidence.source` 指向仓库内存在的文件（`tests/test_firmware_compatibility.py` 要求来源路径存在）。

```json
{
  "schema_version": 1,
  "run_id": "f1-261-exp-20260918T0100Z",
  "host": {"macos": "26.5/25F71", "xcode": "26.6/17F113", "cpu": 15, "memory_gib": 48},
  "tool": {"git_commit": "<sha>", "worktree_clean": true,
           "vphone_cli_sha256": "<sha>", "vphoned_sha256": "<sha>"},
  "combination": {
    "device": "iPhone17,3",
    "ios": {"version": "26.1", "build": "23B85", "ipsw_sha256": "fe83…", "catalog_pairing": true},
    "cloudos": {"version": "26.1", "build": "23B85", "ipsw_sha256": "9bc9…"},
    "variant": "exp",
    "options": {"frida": false, "spoof_build": null, "force_dsc_max_slide": false, "force_exc_guard": false}
  },
  "vm": {"name": "f1-261-exp", "library_root": ".build/f1/lib", "ecid": "0x…", "udid": "…",
         "cpu": 8, "memory_mb": 8192, "disk_gb": 64, "reused_from": null},
  "steps": [
    {"id": "S1_create", "status": "passed", "started_at": "…", "finished_at": "…",
     "commands": ["vphone-cli vm create …"], "exit_code": 0,
     "criteria": "checkpoint overall succeeded; prepare build matches; patch_records=178",
     "observed": {"patch_records": 178},
     "evidence": [{"path": "create-status.json", "sha256": "…"}],
     "manual": ["admin authentication"],
     "failure": null,
     "reused_evidence": null}
  ],
  "disk": [{"at": "after S1", "df_available_kib": 0}]
}
```

约束：

- `status` 取值 `passed`/`failed`/`partial`/`blocked`/`not_applicable`/`not_run`。`failure` 包含 `stage`、`exit_code`、`log`（路径与行号）。
- `reused_evidence` 只允许引用同一 `combination` 且同一源码提交的记录（如 d4-acc），并写明原运行 ID。
- S11 必须包含 `client_version`、`server_version`、`attach_target`、`script_sha256`、`messages`；缺少 `messages` 时生成器不得判为 `passed`。
- S10、S12 的负向检查使用 `expectation: "absent"` 字段，与正向功能分开统计。

### 5.2 生成器（建议位置，未实现）

- `scripts/f1_support_matrix.py`：读取 `research/f1_runs/*.json`，输出 `research/f1_support_matrix.json` 与 `research/f1_support_matrix.md`。矩阵行为精确组合（含构建号、选项、工具提交），列为 S1–S12；只填入运行记录中存在的格子，其余显示 `not_run`，不按版本或变体推导。
- 可选 `--update-compatibility`：将全部适用步骤 `passed` 的组合写成 `firmware_compatibility.json` 的 `capability_verified` 条目，部分通过写 `capabilities[].result = partial`。需用户确认后执行。
- 测试：`tests/test_f1_support_matrix.py`（由 `make test_python` 发现）覆盖：未运行格子不升级；不同构建记录不合并；仅端口连通的 Frida 记录判为 `partial`；负向检查不计入功能通过；证据摘要缺失时拒绝。
- 运行脚本：`scripts/f1_runtime_acceptance.py`，单实例子命令 `preflight`、`boot-cycle`、`gui`、`files`、`apps`、`ddi`、`location`、`camera`、`frida`、`exp-identity`，从 `f2_dual_vm_acceptance.py` 抽取 Endpoint/Evidence/request 逻辑，socket 与输出目录均为参数。清单中设想的 `tests/runtime/` 可放需要 VM 的测试，但不应被 `run_tests.py` 的 `tests/test_*.py` 发现规则纳入无 VM 回归。

## 6. 风险与前置阻塞

2026-09-17 更新：下表“restore 桥接进程挂起”已修复（URL 资源超时重试、后台任务失败时非零退出），真实 restore 注入验收通过；该项不再阻塞。

| 问题 | 现象 / 事实 | 影响 | 处理建议 |
| --- | --- | --- | --- |
| restore 桥接进程挂起 | D4 记录：`pymobiledevice3_bridge.py restore-update` 经 127.0.0.1:10808 代理请求 `fcs-keys-pub-prod.cdn-apple.com` 出现 SSLError 后约 17 分钟无输出、不退出；`VPhoneProcessRunner.runStreaming` 无超时。代理连接中断的来源原因未查明 | 每次 S2 均可能无限等待；F1 需创建至少 6–11 台 | 以修复合入作为 S1 前置；若决定提前执行，设置无输出上限并按 D4 场景 1 补充流程人工终止后续跑，记录为 `blocked` 后重试 |
| 执行构建与 d4-acc 不一致 | 修复会改变源码 | P-regular 复用失效 | §2.2 决定是否重建 |
| 客户机网络 | F2 新实例缺代理配置时首次设置阻塞 | S3 首次设置 | 每台新 VM 按 F2 字段配置代理，记录配置摘要 |
| 构建号不一致 | 本地 26.6.1 为 23G82，catalog 与清单为 23G83 | N 组合定义、清单错误条目 | §7 决定；另行更正 `cap-2661-exp-rigbaseline` |
| 旧版本样本缺失 | 18.6.2 IPSW 不在本地 | F1“旧版本组合”无法执行 | 授权下载或记录为 `not_run` 并说明 |
| Frida 客户端 | 仓库环境无 frida；服务端版本在创建时取 GitHub 最新 | S11 版本不匹配风险（待验证假设：主版本一致即可附加） | 创建前固定服务端 deb 版本并在宿主安装同版本客户端 |
| 缺少应用层探针 | 定位应用读数、EXP 计算路径、DDI 封装均无现成脚本 | S8、S9、S12 只能部分通过 | 在执行前实现并用无 VM 测试覆盖请求格式 |
| 触控探针硬编码 | 路径、分辨率、中文 OCR 固定 | S5 自动化不能直接复用 | 参数化；非中文或其他分辨率组合以截图人工判定 |
| `vm-2607` 与 autophone 占用 | 运行中，rig agent 声明 frida 能力，使用共享 `.build/vphone-cli.app` | 替换共享应用或端口冲突可能影响其他任务 | F1 使用独立工作树与库根；不写 `.build/vphone-cli.app`；Frida 端口使用非 27042 的宿主转发端口（待确认可配置） |
| amfidont 放行 | 新构建 cdhash 变化 | 启动被 SIGKILL（历史记录） | 每次构建后重新放行，需管理员密码 |
| 历史证据缺失 | A3/E5/E6/F2/C3 运行证据目录本地不存在 | 无法复核历史原始数据 | F1 运行摘要提交到仓库（§5.1） |
| 空间 | 峰值未实测 | 创建中途空间不足导致失败（C4 历史出现） | §4.1 阈值与每阶段 `df` 记录 |

## 7. 需要用户决定的事项

1. （已解决，2026-09-17）restore 桥接修复已完成。
2. P-regular 是否复用 d4-acc（需执行构建与 `8b6365f` 源码一致）。
3. 旧版本组合：是否授权下载 iOS 18.6.2 / 22G100；L 是否纳入 less（另需 seal 工具）。
4. N 组合：使用本地 23G82（非 catalog），还是下载 23G83；或改用 27.0 / 24A5408d。
5. Frida 客户端安装位置与版本（仓库 venv、独立 venv，或使用 autophone 的 17.16.1），以及 frida-server 版本的固定方式。
6. 测试 IPA、QR 样本、定位应用层探针与 EXP 计算探针的来源或是否新建。
7. 首次设置助理的统一选项（语言、地区、是否登录 Apple 账号），以及客户机代理配置是否作为标准步骤。
8. 每台 VM 验收后保留或删除；§4.1 可选释放项是否清理。
9. 结果是否回写 `research/firmware_compatibility.json`，以及运行摘要是否提交到仓库。

## 8. 自动化实现（未提交，未实机运行）

日期：2026-09-17。基线 `22a7c02`。本节记录的脚本只在本地假 Unix socket 服务端上测试，未连接任何真实 VM 控制 socket，未启动或停止 VM，未提交。

### 8.1 入口与文件

| 文件 | 作用 |
| --- | --- |
| `scripts/host_control_client.py` | 从 `f2_dual_vm_acceptance.py` 抽取的公共客户端：`Endpoint`、socket 校验、单连接单请求收发、`require_ok`、`decode_file`、`running_app`、`camera_status`。新增 `HostControlTransportError`（`AcceptanceFailure` 子类，带 `timed_out`），F2 的异常类型与消息不变 |
| `scripts/f2_dual_vm_acceptance.py` | 改为从公共模块导入上述函数；场景逻辑未改，`tests/test_f2_dual_vm_acceptance.py` 8 项通过 |
| `scripts/f1_runtime_acceptance.py` | 单实例运行验收 |
| `scripts/f1_support_matrix.py` | 支持矩阵生成器 |
| `tests/test_f1_runtime_acceptance.py`、`tests/test_f1_support_matrix.py` | 假服务端继承 F2 测试的 `HostControlFixture`，由 `make test_python` 发现 |

运行示例（以 d4-acc 为例，需 VM 已由用户按 §4.3 授权启动）：

```sh
python3 scripts/f1_runtime_acceptance.py --socket .build/d4acc/lib/d4-acc/vphone.sock \
  --variant regular --combo P --vm-name d4-acc --ios-version 26.1 --ios-build 23B85 \
  --cloudos-version 26.1 --cloudos-build 23B85 --out research/artifacts/f1-matrix/<run_id> \
  --steps all --second-boot-phase write
# vm stop / vm launch 后
python3 scripts/f1_runtime_acceptance.py ... --steps S4 --second-boot-phase verify \
  --s4-state research/artifacts/f1-matrix/<run_id>/steps/S4/s4_state.json --out <新目录>
python3 scripts/f1_support_matrix.py research/artifacts/f1-matrix --json-out <json> --md-out <md>
```

退出码：有步骤为 `failed` 时为 1；输出目录已存在或参数错误时为 2；其他为 0（含 `blocked`）。

### 8.2 步骤覆盖与判定规则

通用规则：

- 每步先按 `capabilities.commands` 判断命令可用性。客户机已连接且 `guest_capabilities` 不含对应能力时记 `not_applicable`；客户机声明了能力但宿主命令不可用、预检失败或 socket 不可用时记 `blocked`。
- 请求超时或连接错误记 `blocked`，`failure.timed_out` 标明是否为超时。响应 `ok=false` 且错误含 “not connected” 记 `blocked`，其他 `ok=false` 或判据不符记 `failed`。
- 每步由若干子检查汇总：任一 `failed` → `failed`；全部 `passed`（忽略 `not_applicable` 与可选项）→ `passed`；部分通过 → `partial`；无通过且有 `blocked` → `blocked`。清理失败会把 `passed`/`partial` 改为 `failed`。

| 步骤 | 实现 | 最高自动判定 |
| --- | --- | --- |
| preflight | `capabilities`；记录 `protocol_version`、`boot_mode`、`guest_capabilities`、可用/不可用命令、`limits`。判据为响应有效、`guest_connected=true`、`boot_mode=normal`；能力声明不计为功能通过 | `passed` |
| S4 | `write`：`file_put` 标记到 `/var/mobile/Library/f1-<run>.txt` 并读回；有 `shell` 时记录 `sysctl -n kern.boottime`；给 `--bundle` 时只读记录 `<bundle>/.vphone-runtime.json` 的 `pid`、`startedAt`（及 `instanceID`、文件摘要）；写 `s4_state.json`，结果 `partial`。`verify`：标记逐字节一致，且 `restart_evidence` 通过才判 `passed`。重启证据优先用 boottime 是否变化（`source=kern.boottime`）；boottime 不可用时要求运行记录的 `pid` 与 `startedAt` 都变化（`source=host_runtime_record`，记录中注明这是宿主进程重启证据，不等同客户机内核 boottime）。两者都有时都记录，以 boottime 判定。两者都没有时 `restart_evidence=blocked`，结果 `partial`；未给 `--second-boot-phase` 时为 `not_run` | `passed`（verify） |
| S5 | 不判定 | `not_run` |
| S6 | `file_put` → `file_get` 摘要比对；`ls -1 /tmp`、`mv`、`rm` 经 `shell` 执行；改名后新路径摘要一致且旧路径 `file_get` 报 ENOENT；删除后 `file_get` 报 ENOENT | `passed`；无 `shell` 时 `partial` |
| S7 | `app_list filter=running` 原始列表记为观察值（含空列表）→ 若目标已运行先终止 → `app_launch` → running 列表 PID 与启动 PID 一致 → `screenshot` 存入证据目录 → `app_terminate` → PID 消失。jb/exp 且给 `--ipa` 时：`file_put load` 到客户机 `/tmp`、`ipa_install`、启动与终止安装包。`app_launch` 错误文本含 `uiopen unavailable` 时仍判 `failed`，`failure.classification=capability_declared_but_uiopen_missing`。无 `screenshot` 时截图子检查为 `blocked` 并注明 `screen_available` | `partial`（截图是否为目标应用需人工确认） |
| S8 | 不判定 | `not_run` |
| S9 | 初始 `location_source_status` 若已有活动源则 `blocked`（不替换）；`location_source_set`（fixed、wgs84、`persist=false`、`replace=false`）→ 轮询状态至 `running`、generation 相同、`applied.last_fix` 坐标一致、`last_delivery_sequence>0` 且有 `last_ack_at` → `location_source_stop` → 状态 `off`、generation 为 null | `partial`（应用层读数无探针） |
| S10 exp | `camera_present` 不可用时记 `blocked`，原因注明 `screen_available` 与“需要 GUI 启动”；否则启动 `com.apple.camera` → `camera_present`（image、role `qr`）要求同 generation/presentation_id 的 `transport_receipt` → 带 presentation_id 的 `camera_status` 要求 streaming、`matches_requested` 与回执一致 → `camera_stop keep_last` → 状态停止 → 终止消费应用 | `partial`（QR 识别与画面截图需外部探针或人工） |
| S10 非 exp | `expectation=absent`。`file_get`（`save` 到证据目录）检查 `/var/jb/usr/lib/libvcamcaptured.dylib` 与 `/var/jb/Library/MobileSubstrate/DynamicLibraries/libcamfix.dylib` 报 ENOENT；新 generation 的 `camera_status` 无回执；给 `--camera-image` 时发送 `camera_present` 并原样记录响应，出现有效回执记 `failed` | `passed`（负向记录） |
| S11 | 非 jb/exp 或未带 `--frida` 为 `not_applicable`；否则 `not_run` 并列出 §5.1 要求的字段 | `not_run` |
| S12 | `shell` 执行 `sysctl -n kern.hv_vmm_present`、`kern.Xv_vmm_present`、`hw.machine`；`file_get` 读取 `SystemVersion.plist`（给 `--spoof-build` 时比对 `ProductBuildVersion`）；非 exp 同时检查 S10 的注入文件不存在。exp 判据：hv 为 unknown oid、Xv 为 1、`hw.machine=iPhone17,3`；非 exp：hv 存在、Xv 不存在、`hw.machine=iPhone99,11`。sysctl 缺失为 `blocked`；DT `target-type`/`compatible` 直接读取、exp 图形与计算探针固定为 `blocked`；watchdogd 状态不判定 | `partial` |

`run.json` 顶层 `launch` 记录 `--launch-mode`（操作者声明，脚本不核实）、预检得到的 `screen_available` 与 `boot_mode`。

生成器规则：行键为 combo、设备、iOS 与 cloudOS 版本/构建、变体、选项、工具提交；不同键不合并。同一格取 `finished_at` 最新的非 `not_run` 记录，历史保留在 `history`；无记录显示 `not_run`。`passed`/`failed`/`partial` 缺证据摘要、状态值非法时拒绝生成。S11 `passed` 缺 `client_version`、`server_version`、`attach_target`、`script_sha256`、`messages` 任一字段时降为 `partial`。`expectation=absent` 的格子在 Markdown 中标 `(negative)`；带 `failure.classification` 的格子标 `*`。表后 Notes 列出每次运行的启动模式与 `screen_available`，以及各格的 classification 与 S11 降级说明。

### 8.3 与 §3、§5 的差异

- 输出结构：`--out/run.json`，每步 `steps/<id>/step.json` 与 `steps/<id>/requests.jsonl`。请求与响应中键名匹配 password/token/secret 等的值替换为 `<redacted>`；`data`、`data_b64`、`image` 替换为字节数与 SHA-256。
- `run.json` 与 §5.1 相比：`combination` 增加 `combo_id`，选项只有 `frida`、`spoof_build`（`force_dsc_max_slide`、`force_exc_guard` 未提供参数）；`tool.vphoned_sha256` 固定为 null；`vm` 只含名称与 socket（无 ECID/UDID/CPU/内存）；`disk` 为空数组；另增 `invocation`、`script`、`started_at`、`finished_at`。步骤增加 `title`、`checks`、`reason`、`record`；`exit_code` 为 null（socket 请求无进程退出码，shell 退出码在 `observed` 或子检查中）；`failure` 字段为 `stage`、`reason`、`timed_out`、`log`（requests.jsonl 路径与行数）。
- 步骤 ID：`preflight` 为控制 socket 能力预检，与 §3 的 S0 宿主前置检查不同；S0–S3 不由本脚本生成，矩阵中显示 `not_run`，需另行从 `vm create-status` 检查点整理。
- S6：宿主控制 socket 未提供 `file_list`、`file_rename`、`file_delete`（`VPhoneHostCommandExecutor.swift` 只处理 `file_get`、`file_put`；这三个命令只由 `VPhoneControl.swift` 直接发给 vphoned），因此列表、改名、删除经 `shell` 的 `ls`/`mv`/`rm` 执行，`observed.list_rename_delete_method=shell`。
- S7：§3 的 `app_foreground` 只记录不判定；截图判定留给人工，因此自动结果最高为 `partial`。
- S10 非 exp：§3 只列出 `libvcamcaptured.dylib`，脚本另检查 `cfw_install_exp.sh` 中 `libcamfix.dylib` 的安装路径。
- S12：§3 要求读取 DeviceTree `model`/`target-type`/`compatible`；脚本用 `hw.machine` 间接判断 `model`，其余两项记 `blocked`。

### 8.4 未验证内容

- 全部步骤未在真实 VM 上运行。以下为待验证假设：客户机存在 `/usr/sbin/sysctl` 或 `/var/jb/usr/sbin/sysctl`；不存在的 OID 在 stderr 输出 “unknown oid”；`kern.boottime` 输出格式为 `{ sec = N, usec = N }`；`hw.machine` 在非 exp 为 `iPhone99,11`、在 exp 为 `iPhone17,3`（依据 `cfw_install_exp.sh` EXP-JB-6 注释与 DT 改写脚本，未经客户机读取）；less 与 regular 的 `/bin/ls`、`/bin/mv`、`/bin/rm` 可用性。
- `file_get` 不存在文件的错误文本依据 `vphoned_files.m` 的 `open failed: strerror(errno)`，宿主是否原样透传未实机确认。
- S9 的状态轮询默认最长 15 秒；真实交付耗时未测。S10 依赖系统相机应用作为回执消费者，与 F2 场景一致，未在单实例脚本中实机验证。
- 2026-09-17 首次实机运行（P-regular，`d4-acc`，headless，构建 `22a7c02`，证据 `research/artifacts/f1-matrix/f1-P-regular-20260917T125810Z/`）暴露并据此修正的问题：
  - S9 请求缺 `timestamp`，宿主返回 `timestamp must be > 0`。按 `VPhoneHostCommandExecutor.systemLocationFix` 与 `VPhoneSystemLocationController.preflightFixedSource/validateFix`，fixed 源要求 `producer_sequence=0`、`timestamp>0`（Unix 秒数值或 ISO-8601 字符串；缺省按 0 处理），`heartbeat_s` 在 0.01–86400 秒。脚本改为发送 `producer_sequence=0` 与当前 Unix 秒；假服务端按相同顺序校验这些字段。修正后的请求未实机复验。
  - regular 客户机不声明 `shell`，S4 只能 `partial`；增加 `--bundle` 宿主运行记录证据（见 8.2）。
  - regular 上 `app_launch` 返回 `uiopen unavailable to launch com.apple.Preferences`：`vphoned_apps.m` 只在 `/var/jb/usr/bin/uiopen` 或 `/usr/bin/uiopen` 存在时能启动应用，而 `apps` 能力按 `gAppsAvailable` 声明。判定保持 `failed`，增加 classification。
  - headless 下 `screenshot`、`tap`、`swipe`、`camera_present` 不可用。代码中前三者依赖 VM 窗口（`VPhoneHostScreenAdapter.isAvailable`）；`camera_present` 的可用条件是相机 vsock 已连接且客户机声明 `vcam_receipt_v3`，与屏幕没有直接代码依赖。该次 regular 运行中 `camera_present` 不可用的原因未查明（regular 无 `libvcamcaptured` 也可能影响相机连接，待验证假设）；GUI 启动能否使 exp 的 `camera_present` 可用待验证。
- 支持矩阵的“最新记录优先”规则尚未经用户确认；是否回写 `firmware_compatibility.json` 仍按 §7 第 9 项待决定，生成器未实现 `--update-compatibility`。
- S5、S8、S11 的自动化、定位应用层探针、QR 探针集成、EXP 图形与计算探针仍为缺口。

## 9. 用户决定（2026-09-17）

| 事项 | 决定 | 对执行的影响 |
| --- | --- | --- |
| 旧版本组合 L（18.6.2/22G100） | 暂不纳入，不下载 | L 全部记为 `not_run`；F1 “旧版本组合”条目不满足，F1 不能按原定义完全关闭 |
| Frida 组合 N 的 iOS 构建 | 使用本地 `iPhone17,3_26.6.1_23G82_Restore.ipsw` | 矩阵标注“非 catalog 构建（catalog 为 23G83）” |
| 验收后的 VM | F1 新建的 VM 在该 VM 的全部步骤（含人工步骤）完成后删除，保留日志与 `run.json` | 旧实验数据（d4-acc 事务归档、C5/D3 VM、C4 less 输入）不在授权范围内，不删除 |
| 人工环节 | 自动步骤先执行，人工步骤（首次设置、权限弹窗、DDI 信任/开发者模式、VZ 窗口输入抽查）集中列出后由用户统一处理 | 待人工的 VM 需保留到人工步骤完成；同时保留的 F1 VM 按空间控制在 2–3 台 |

执行构建：独立工作树 `.build/f1/src`，HEAD `22a7c02`（含 restore 桥接修复），`make build` 签名；该工作树需要 `git submodule update --init --recursive` 并提供 `.tools/bin/{trustcache,insert_dylib}`（从既有工作树复制）后才能构建。

### 9.1 用户决定（2026-09-17，第二批）

| 事项 | 决定 |
| --- | --- |
| 人工步骤 | 立即开始，逐台 GUI 启动 |
| 首次设置助理 | 简体中文；客户机 en0 配置 HTTP/HTTPS 代理 `192.168.64.1:10808`（F2 字段，经宿主控制 `file_put` 预先写入并重启生效）；定位服务开启；Apple ID、分析、屏幕使用时间、Siri、面容 ID、密码等全部跳过或关闭 |
| Frida 客户端 | 复用 autophone venv 中的 frida 17.16.1；客户机 frida-server 版本在创建后读取并记录，主版本不一致时 S11 记为 blocked 并说明 |
| regular/dev/less 的 `apps` 能力 | 方案 A：修正能力声明，没有 uiopen 时不声明应用启动能力；为非 JB 变体补启动方式另行评估 |
