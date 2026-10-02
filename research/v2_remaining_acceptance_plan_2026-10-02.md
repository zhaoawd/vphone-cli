# v2 R5–R9 与 T17 验收准备

日期：2026-10-02。前置：R1–R4 和 launchdhook 的 T16 替换已通过；`aea7315`。本批仅准备候选、脚本和批准范围，未操作客户机。

执行状态（2026-10-02 更新）：用户已批准本文件所列整批范围。首次 R5 窗口启动未通过宿主预检；签名 `vphone-vm --help` 在沙箱外返回 137，进程检查未发现 amfidont。未启动该测试 VM，未执行 R5 客户机写入、定位或触控。已请求用户重新运行独立工作树的 amfidont 启动脚本；此操作不改变本批批准范围。R6 `offline-check` 已发起，macOS 管理员认证尚未完成，尚无检查结果。R6 写入及 R7–R9 未执行。

## 对象和边界

- v2 对象：`/Users/kolar/vphone-v2-accept-20261002/VMs/lp-v2-accept-20261002`，停机；保留 T15/T16 旧盘。
- R9 新对象：同一测试库的 `lp-classic-accept-20261002`，无选项创建 regular classic，64 GB 稀疏盘；名称存在时拒绝。使用现有 26.1 本地 IPSW 和独立测试缓存。
- 不操作 vm-2607、vm-new、rig-baseline 或其他用户 VM。R8 仅回退本次在线事务，不删除任何 VM 或旧盘。
- 不执行 B6/B7、T18/T19 或新增内核补丁，先取得剩余真实验收结果。

## 候选与验证

候选根 `/private/tmp/vphone-v2-build-20261002/.build/acceptance-r567-20261002`：

| 候选 | 来源与差异 | libcamfix SHA-256 | libvcamcaptured SHA-256 |
| --- | --- | --- | --- |
| baseline/stage | 当前候选，-Os | fbf94136a3d47d0222e455248afc0362d1dfa2b2265f7bd05ab0ef2970ab3fea | 2e94e0d035a717dfd82f91f8547a789aa82f2978569a488289be95c9ede17e97 |
| r6-cam-O1/stage | 只将 libcamfix 编译为 -O1 | d613aad43b4a41f84114918a89a0f8a4a258c61be326e376ac388b064271c21c | 同 baseline |
| r7-vcam-O1/stage | 在 R6 候选基础上，只将 libvcamcaptured 编译为 -O1 | 同 R6 | fca60af5d82f604aa5785fca03d3262ad6a529739116d687d7f032ce5a77eb94 |

源码逻辑和 deployment target 均不变。每份 stage 是完整独立副本；只有指定库摘要变化。`make -C sources/VPhoneGuestComponents -B OUT=<候选根> GUEST_C_FLAGS='-arch arm64e -miphoneos-version-min=26.0 -O1' <对应库目标>` 重建，再 `check_guest_components.py --stage <stage> --record`。两个候选均通过签名、架构、平台、部署版本、输入来源和文件摘要校验。experiment.json 保存来源与编译设置；不以候选构建成功宣称运行时行为一致。

## 执行和断言

1. R5：带 VM 窗口启动 v2；保存 capabilities 和宿主截图。经典 file_put 写唯一 `/var/mobile/Library/Caches/vphone-r5-<随机ID>.txt`，file_get 回读核对 SHA-256，保留该文件。固定定位采用 owner vphone-r5-acceptance、replace:false、persist:false，初始状态须 off；等待 generation、last_fix、last_ack，再只停止自己的 generation。仅在客户机声明 app_launch 时启动 com.apple.Preferences；不声明则记录 blocked，不用 API 启动冒充经典合约通过。触控通过客户机 tap 命令，先检查截图，再在客户机屏幕 (10, 10) 像素位置执行一次，前后截图记录；不发送宿主合成键鼠事件。这项需要用户确认触控范围。协议确认不等于 App CoreLocation 功能验收。
2. R6：停机。`run_v2_environment_acceptance.zsh offline-update` 先提权 --check，必须 offline_update、replace 仅 libcamfix、disk.unchanged true。T16 更新后核对身份摘要和已发布事务；重启，R4 复核及 already_current。旧盘保留。
3. R7/T17：运行中的 v2 对 r7-vcam-O1/stage 执行 online-update，断言唯一 replaced 为 libvcamcaptured、verified:true、load.source environment.loaded、cameracaptured 的旧映射 stale。保存 transaction。随后 online-restart，断言只重启 cameracaptured，重新读取 processes.list 与环境映射，要求新相机进程 current。不重启 SpringBoard 或 launchd。
4. R8：只对刚保存的 R7 transaction 执行 rollback，要求 libvcamcaptured 摘要恢复到 R6 候选，libcamfix 保持 R6，其他库不变；重启该 VM 后复核加载。保留 journal、候选、旧盘。在线 remount 若留下 root_read_only:false，保存结果并重启该副本恢复只读，不新增补丁以强行通过。
5. R9：`create_classic_acceptance.zsh` 完成无 guest-environment 选项的 regular 创建；停机只读报告要求 bootstrap none、无 /vh 和 API daemon。启动 classic 对照，验证经典连接与能力；不以关闭 API proxy 作为 API daemon 文件不存在的证据。结束后停机保留。

R7 使用 libvcamcaptured 差异，而非 libcamfix，原因：本地 SystemHook 在 cameracaptured 中加载 libvcamcaptured，libcamfix 主要位于 App。只重启 cameracaptured 不能验证 App 的 libcamfix 重新加载。此调整仍仅覆盖原设计已有环境库及相机进程。

脚本：`scripts/diagnostics/run_v2_environment_acceptance.zsh` 分离 offline-check/offline-update/online-update/online-restart/online-status/rollback；`create_classic_acceptance.zsh` 用于 R9。均通过 zsh -n，rollback CLI 参数已核对帮助；未执行真实写入阶段。已有诊断反馈脚本用于 R4，正式回归用保存的步骤和断言，不以一次界面观察替代。

R5 脚本：`scripts/diagnostics/check_v2_classic_contract.py contracts --output <证据目录>` 保存每次请求与响应、能力、文件回读摘要、定位回执及停止结果、App 能力和触控前截图。检查截图后单独运行 `tap --output <同一目录>`；一次性标记阻止重复点击。固定测试坐标为 WGS84 (31.2304, 121.4737)。脚本通过 `python3 -m py_compile`、`--help` 和 `git diff --check`；尚未取得真实协议结果。App 能力缺失记录 blocked；定位协议通过仍只记录 partial，保留应用读取未验证的限制。

## 批准范围

需明确批准：上述两个测试对象的启动/停止、一次客户机触控（10, 10 像素）、固定定位与测试文件写入、可用时的经典 App 启动、R6 停机替换、R7 在线替换和 cameracaptured 重启、R8 本次事务回退，以及 R9 新建 classic 对照（认证/TSS/磁盘空间）。权限和能力不足时保留 blocked/failed 结果，不改变判定标准。所有 VM、测试文件、日志及备份保留，无删除或发布。
