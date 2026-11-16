# Duo M5 当前任务

更新：2026-11-16。Duo 工作留在 `duo-integration-20261030`；同步方向为上游 → `main` → Duo。`origin/main` 已刷新到 `13169405`（2.17.1）；本地 `main` 仍为 `6f57024a`。本轮改动已按范围评审并拆分为本地提交；尚未推送或发布。

## 整体接入优先

用户当前方向：优先完成剩余功能组的生产接入，细节诊断和扩展验收后置。以下为建议执行顺序，固定上游仍为 `13169405`；具体差异见 `UPSTREAM_REMAINDER_20261115.md`，历史状态由下文较新的生产记录更新。

- [x] 固定当前接入基线：75 个文件的已实现／已验证改动保存为本地提交 `119f1529`，保留测试与研究记录。
- [x] 第一组生产接入，#909＋#911：PCC OS image GPU 提取、版本匹配／AEA 回退、临时恢复 vCPU 策略和 SE 3／transport 依赖已完成；相关回归通过，旧固件运行验收后置。
- [x] 第二组生产接入，#921：SPTM 组件、语义补丁、pipeline、PatchKit／Launchpad 目录、预设和 drift 已完成，cloudOS 18 版本门槛与相关回归通过；旧固件多 vCPU 运行验收后置。
- [x] 第三组生产接入，#920：鼠标模式、偏好持久化、菜单及 iPad pointer／touch 已接入，保留 Duo 坐标转换；`vphone-vm` 编译通过，实际输入运行验收待集中执行。
- [ ] 第四组，#926：接入 QuartzCore 未旋转 framebuffer 的 planner、声明、CLI、安装／撤销及共享缓存修改归属；Duo 默认选择通过组合候选确定，不将其作为已有显示诊断的已确认修复。
- [ ] 前四组接入收尾：核对目录、预设、CLI、收据、Launchpad 与版本契约；按 upstream → main → Duo 整理同步，完成完整 Bundle／Launchpad 构建和一轮 Duo 组合验收。
- [ ] 最后一组，#900：独立接入 trusted darwinOS／persistent Cryptex 的依赖组，包括 RPC、菜单、cryptexctl 来源及恢复回退；保留支持范围与拒绝路径，不加入 Duo 27.1 默认计划。

每组保留编译、补丁选择／版本门槛、兼容／撤销等必要回归。可以集中执行实际组合验收，不要求完成所有独立设备和扩展工作流后才继续下一组生产接入。

第一组生产接入完成：CoreKit 45 项、DeviceTree／目录 65 项、transport 和实际恢复源码 CPU 策略 8 项通过。完整 Bundle 构建与后续组集中进行；旧固件运行验收后置。下一组为 SPTM。见 [整体接入记录](Research/Integration/duo_m5_20261030/OVERALL_PORT_20261116.md)。

后置清单继续保留：内屏 AX 可见性过滤、首次姿态超时、间歇启动／AMFI 拒绝、显示交接与方向细节；LLDB、CMS／真实 profile 热重载、local pairing 协议、App 直接 posix_spawn；旧固件实机矩阵、27.2、Linux FUSE／并发、物理 USB／DFU、WDA 与宿主快捷键。发布准备另列四语手册审阅、Release 产物、Developer ID 签名和 notarization。

## 2026-11-16 生产移植

固定上游 `13169405`，起点 `c07ee974`。本轮修改工作树，未推送或发布。旧评估条目保留当时状态，以本节为当前进度。

- [x] DriverKit：运行树、Preboot 修复、设备族排除及回归通过。新副本两次冷启动均有 driverkitd／HID dext 和 Virtual USB Touch Screen；两面板原生 VZ 触摸 6/6 通过。
- [x] local pairing：语义发现、安装与撤销接线、合成负例及真实 27.1 镜像签名／重复应用通过；实际协议连接和真实 iOS 18 输入未验收。
- [x] X1：完整转换／可选安装器、35 项独立 AX＋HomePop、旧选择／备份／收据兼容及只读审计。36 项真实备份共 3,168 条指令的转换、签名、重复应用和撤销通过；两次冷启动的 36/36 实际文件匹配候选，原备份不变，收据迁移通过。12 项 debug-library 实际文件无剩余 X1，严格签名 12/12，原始备份共 31,013 条待转换指令；LLDB 未验收。
- [x] TXM：native remap／profile、旧 ID 兼容、precheck 优先级及两条静态候选。8 个生产组合通过，显式 precheck 保持旧标准输出。工作树 standard 候选跟随上游 native remap；仅切换 TXM 的新副本已完成恢复和下列运行范围，不等于其他启动链开关或完整 standard 已验收。
- [x] 完整 2.16.0 Bundle、admission、深度严格签名、Launchpad 构建、15 个 suite／164 项回归和 CLI 存盘／导出往返通过；CI 已接入。
- [x] 已批准的运行验收：`a91b9e15…` AMFI 准入、宿主预检、新副本 `duo-patches-20261116` 环境更新、收据和两次冷启动均通过。显式保留旧 precheck、关闭 remap；不能计为 native remap 验收。21 项环境库、原 daemon、根只读、两面板原生输入、AX 命中 15/15 和锁屏拒绝通过。KFC 前台 PID 在 15 秒内保持，Food AI 有可点击 AX 元素。两轮均恢复合盖纵向、Auto-Lock 120 秒、锁屏／熄屏和低电量原值后正常关机，退出 0、无状态句柄；未执行恢复。
- [ ] 内屏 AX 发现限制：`patch-port-touch.mjs` 仍因默认 `ui.tree` 只返回 4/9 按钮而失败；未过滤查询返回全部 9 个。可见性过滤的具体边界原因待验证。原断言保留，独立 UIKit 坐标原生输入 6/6 不替代该项。
- [x] TXM 候选准备：新身份副本 `duo-txm-remap-20261116` 的 126 项固件比较仅 TXM 不同，payload 匹配生产静态 remap 候选；来源关闭的三个启动链项继续关闭，RestoreRamDisk 沿用来源文件。原比较失败及重新生成产物保留。
- [x] TXM 独立运行验收的已测范围：用户批准新副本 DFU／擦除恢复／停止／CFW 安装和运行验收后执行完成。默认签名、仅移除 custom-trust、再次冷启动后各 20/20 remap、80 个 alias，实际 RX、字节比较与执行通过；两种外部 dylib 均构造器=1／返回 73。ldid／Apple ad-hoc 两种 standalone 的受控 exec 注入均在两轮通过，自身路径匹配、exit=0，临时作业已卸载。原始 VM 和旧验收副本未启动。
- [x] TXM 擦除恢复：绑定新副本 ECID `0x0C5CF189506BC959` 的恢复成功，记录 iOS 27.1／cloudOS 26.4 和 102 项启动链补丁；TXM 收据含 remap、不含 precheck。随后仅停止该副本的 DFU 进程，退出 0。
- [x] TXM CFW 安装：用户完成系统管理员认证后，同一安装会话成功退出 0；日志记录完整安装成功，无 `[!]`／failed／Error。安装后 remap 为 enabled/planned/applied，precheck 三项均 false，二者 pending=false。
- [x] TXM 冷启动与清理：同一 CDHash 的宿主拒绝在有效授权内重新准入后通过；拒绝原因未查明。两次冷启动、36/36 AX 文件、21 项库、根只读和 pairing 文件核对通过。实际 Preboot TXM 的 IM4P 与 payload 均完全匹配候选。两轮恢复稳定快照的合盖纵向、Auto-Lock 300 秒、锁屏／熄屏及低电量原值后正常关机，VM exit=0、无句柄；离线只读挂载已清理，前后镜像清单相同。
- [ ] TXM 验证限制：首次姿态 RPC 超时保留，原因未查明；App 直接 posix_spawn 两种签名均 EPERM，原 aggregate 断言仍失败，独立 exec 注入通过不替代该路径。CMS／真实 profile 热重载、修改后私有代码／inline hook、LLDB 和其他 injector／系统／版本未覆盖。
- [ ] 其他设备／旧固件、SPTM、鼠标／framebuffer 项目按原差异清单独立推进；trusted darwinOS 不加入 Duo 默认计划。

来源、迁移规则、失败与修复、命令和未覆盖范围见 [生产移植记录](Research/Integration/duo_m5_20261030/PATCH_PORT_20261116.md)。静态证据为 `.build/upstream-port-20261116/saved-run.a1thV043/`；实际运行证据为同级 `cold-run.acMbD9pf/` 和 `cold-run.jM0hDUCb/`。新副本保留候选补丁及生成的 TapProbe，来源与原始副本未启动。

## 当前待办

上一批实现与验收截至 `f168cb8b`；三个本地提交为 `cc3f1d85`（网页摄像头及复现资产）、`06bcf315`（构建配置与 notice 门禁）、`f168cb8b`（GUI／摄像头验收和回滚记录）。其后 3–5 的范围评估和离线回归保存为 `316fa62c`、`98426587`、`a22078e7`；本轮运行记录另行保存，未推送或发布。上游同步目标仍为已固定的 `13169405`，本次未刷新远端。

前两项评估完成，后续按以下顺序推进；生产移植与评估分别记录：

前两项结果：固定 `origin/main=13169405`，#924 的 35 项路径与 Duo 聚合 AX 目录重叠；直接新增／删除声明的旧选择兼容问题已复现。#919／#923 缺少 #831 native remap 和 profile 修正依赖，直接重命名也拒绝旧选择。65 项 X1／撤销／目录／预检测试和参考 TXM 的 8 个上游内存策略组合通过；显式 precheck 输出与当前标准策略逐字节相同。本轮仅新增测试与研究资产，未启动 VM、移植生产补丁或改变预设。证据目录 `.build/x1-txm-preflight-20261115/saved-run.NrAzph31/`；见 [差异、方案和验证限制](Research/Integration/duo_m5_20261030/X1_TXM_PREFLIGHT_20261115.md)。

1. [x] #924 评估：独立 AX 插件清单、聚合目录重叠、旧选择负例、可选安装器依赖和迁移方案已保存。实际独立声明／审计移植及 35 项真实镜像验收未完成。
2. [x] #919／#923 评估：依赖、版本／默认选择、优先级和参考 TXM 的 8 个组合已验证；旧选择改名负例已保存。native remap 生产移植和实际启动／注入／remap 验收未完成。
3. [x] 其余上游差异评估：#867／#877 DriverKit、#900 Cryptex、#909／#911 旧固件与 PCC GPU、#910 pairing、#920／#926 鼠标与 framebuffer、#921 SPTM 的最终差异、依赖、适用范围和验收目标已保存。实际生产移植另列。见 [差异清单](Research/Integration/duo_m5_20261030/UPSTREAM_REMAINDER_20261115.md)。
4. [ ] 显示与启动诊断继续：全尺寸 RGBA 分析和两轮新 MOV 已完成。连续原生采样轮 6/6 交接确认，但第 3 次合盖采到 5 个近黑样本；取消连续原生采样的对照 6/6 确认、无近黑样本，最长相同缩略亮度区间约 700 ms。两轮均有方向变化，单轮对照不证明原因。候选矩阵早期出现 Safari 方向／恢复失败；补充前台稳定与截图可用性检查后，最终 6 项支持姿态及 2 项明确拒绝、来源和恢复 8/8 通过，最小循环 3 次未复现原失败。产品原因未确定，内容方向像素验证仍未完成。间歇冷启动失败仍缺少 guest 失败时状态。见 [诊断记录](Research/Integration/duo_m5_20261030/DISPLAY_BOOT_DIAGNOSIS_20261115.md)。
5. [ ] 验证缺口：新身份 CFW 副本的完整安装、environment update、System 工作镜像卸载、收据和实际冷启动已完成；保存版摄像头脚本已在 VM 通过原生 14/14、WKWebView 10/10、Safari 10/10 变化摘要。foundation 已恢复原 daemon／标记、21 项原库，冷启动核对根只读与 Auto-Lock 120 秒后正常关机，无状态句柄。Linux FUSE／并发、物理 USB／DFU 与恢复空间峰值、27.2 独立候选仍未验收。见 [验证结果与环境限制](Research/Integration/duo_m5_20261030/VALIDATION_GAPS_20261115.md)。

本轮 3–5 状态：第 3 项评估完成；第 4 项保存了新的失败、对照和方向复现，完整原因未查明；第 5 项的 CFW／卸载与保存版摄像头实际验收完成，独立环境项目保留。证据目录为 `.build/followup-3-5-20261115/` 与 `.build/host-webcam-distribution-20261115/`。用户已批准并完成当前 `974031b5…` 宿主准入与新副本全量安装，不再等待同范围批准。原副本 `duo-rpc-accept-205443` 未启动，新 CFW 副本保留候选安装和恢复树；回归完成后恢复原设置并正常关机。没有推送或发布。

发布准备另行跟踪：四语手册 Argon 审阅、Release 产物及 Developer ID 签名／notarization 未完成；当前 Debug 构建和本地验收不替代发布验收。

前两项的生产移植与剩余验收：

- [x] X1：完整转换／可选安装器、旧选择／备份／收据迁移、35 项独立声明＋HomePop、只读审计及实际安装验收完成。Duo 共享缓存撤销归属保持。内屏 AX 过滤限制与 LLDB 未验收另列。
- [x] TXM：#831、profile、旧 ID／收据迁移及 #919／#923 生产实现与 8 个静态组合完成；新副本已按独立批准恢复并完成原始代码 remap／简单注入及两次冷启动，实际 Preboot 字节匹配。CMS／真实 profile、修改后代码和 App 直接 posix_spawn 等限制见本节当前记录；guest 更新仍不替换 TXM。

上一批完成：真实新宿主 GUI × 旧 daemon 的五类面板刷新／筛选通过；#906 原生／WKWebView／Safari 变化帧通过；#861／#869／#870／#888 构建环境、固定依赖、许可证和分发门禁已集成。完整 Bundle 构建、严格签名、Launchpad Debug 构建和相关正反回归通过，版本保持 2.15.2。当次新宿主实际预检通过，未新增 AMFI allowlist；本轮准入前重新预检被拒绝，用户批准后当前宿主已准入。测试 App 已注销归档并保留数据；隔离副本已恢复原 daemon／标记、21 项库，冷启动核对根只读和 Auto-Lock 原值 120 秒后正常关机，无状态句柄。证据目录 `.build/host-webcam-distribution-20261115/`；见 [验收记录](Research/Integration/duo_m5_20261030/HOST_WEBCAM_DISTRIBUTION_20261115.md)。未推送、发布或执行 Developer ID 签名。

本轮完成：五项 RPC 契约修改与候选验收通过（名称／单位兼容、错误码／未知参数、列表分页、进程输出暂存、输入观察）；197 方法、38 项兼容回归、1148 项逻辑、132 项 schema、109 项 fixture 和 687 项 CoreKit 测试通过。候选实际冷启动的 91 次回复 schema、Trust 拒绝、AX 15/15 和来源恢复通过。已恢复原 daemon／标记和 21 项库。一次原组件冷启动未连接 RPC；按用户批准对该副本发出 SIGINT 后重试冷启动，原组件、原标记、21 项库、根只读和原 Auto-Lock 120 秒均核对通过，随后正常关机，无状态句柄。该次启动异常原因未查明。证据目录 `.build/rpc-contract-next-20261115/`；见 [本轮记录](Research/Integration/duo_m5_20261030/RPC_CONTRACT_NEXT_20261115.md)。

本轮五项 RPC 基础集成完成：方法类型与完整目录、声明驱动准入／派发、Duo 适配、目录／生产者漂移回归、完整 Bundle 与隔离副本验收。#841／#857／#884／#892 已移植；195 项目录、36 项目录自测、130 项提取器、正式 release 漂移、Swift HTTP fixture 109 项和相关组件回归通过。原生 AX PID 漏声明已由真实回复复现并修复。最终 c1d320… 候选的 VM 212 项目录／接口检查、15 项实际回复 schema、AX 15/15、锁屏拒绝、worker 119→491 后原生来源恢复通过。两份拷贝均已恢复原 daemon／标记、冷启动核对 21 项库和根只读后正常关机，无状态句柄；原副本未启动，宿主准入未变。详见 [本轮验收](Research/Integration/duo_m5_20261030/RPC_FOUNDATION_20261115.md)。

恢复来源与 RPC 预检完成：恢复重试来源确认为 #854，当前实现与上游对应文件相同；扩展 IOKit 回归后 libusb 7/7、IOKit 8/8 通过，旧源码分别复现 6、7 项失败。RPC 同步预检编译生成 203 项上游与 12 项 Duo 局部声明，记录 8 项差异；直接复现上游准入拒绝 Duo `never:true`。24 项预检、固定上游 1262 项离线逻辑通过。详见 [来源与预检](Research/Integration/duo_m5_20261030/RPC_SYNC_PREFLIGHT_20261115.md)。该记录为历史预检；后续基础生产移植及五项契约迁移已完成，以前述实际验收记录为准。

缓存生命周期集成完成：#853／#897／#865 的最终改动已集成。29 项固件测试和 15 项 C 检查、完整 Bundle 构建及严格签名通过；旧实现失败证据已保存。真实缓存两份副本的规划输出及 82 项归一化结果完全相同，其他补丁 22 条记录保留。新隔离副本禁用宿主自动更新后，候选更新和冷启动持久化通过；恢复原 daemon／标记后的再次冷启动、21 项库、根只读和正常关机均核对通过。未修改宿主准入。实际 CFW 安装／System 卸载和 Linux FUSE/并发尚未验收。详见 [集成验收](Research/Integration/duo_m5_20261030/CACHE_LIFECYCLE_20261115.md)。

后续整理完成：现有源码按依赖拆成 13 项本地提交，CI、共享回归和记录分别整理。评审复现并修复 #899 重启等待的两次状态读取竞态，47 项状态机测试通过；新隔离副本的原生重启与真实关机对照均通过，后者恰好补启动一次。历史诊断入口遗漏孤立 VM 关机的问题也由失败回归复现并修复，CI 增加该项检查。完整 Bundle 构建、admission 和严格签名通过。当前未推送或发布；详见 CHANGE_REVIEW_20261114.md。

三项修复验收完成（2026-11-14）：最终候选 T2 的完整 Bundle 构建、严格签名、Bundle admission 和相关回归通过。实际 VM 的 15 点 AX／锁屏拒绝、四次 AOD 开合与 240 个采样点、两个真正熄屏唤醒对照、重启后的原生来源自动恢复均通过。Home 六次 10 秒原生 Live 和冷启动 Safari 六次原生 Snapshot 交接均确认，观察窗口无近黑样本。用户选择保留 Snapshot；最长约 432 ms 的重复亮度样本仍存在，其全部原因未查明。过渡中采到方向变化，不计为全程固定纵向。隔离副本已恢复原 daemon 和 FoldDisplay，第二次冷启动核对 21 项库、根只读、trace=0、低电量和旋转锁原值后正常关机，无状态文件句柄。源码与最终候选留存供审阅，详见 FIXES_20261114.md。

- [x] 内屏 `ui.element_at`：修复实际 display ID 命中及普通 App PID 解析；最终 15/15 目标命中，锁屏拒绝通过。见 [修复验收](Research/Integration/duo_m5_20261030/FIXES_20261114.md)。
- [x] 常亮锁屏：修复 daemon 主动唤醒、原生 unlock 选项与独立背光请求；四次开合和无姿态对照的 240 个样本保持 AOD，真正熄屏开合仍唤醒锁屏。
- [x] 动态交接与来源恢复：代次变化自动重建 API worker；最终原生 Live／Snapshot 各六次交接均确认，观察窗口无近黑样本。保留用户选择的原生 Snapshot；约 432 ms 的重复亮度区间仍存在，完整原因未查明。最终原组件、21 项库、根只读和正常关机已核对。

## 上游同步

- [x] #853、#897 DSC 映射生命周期；#865 缓存 worker。最终上游版本已集成，Duo X1 撤销归属保持，真实缓存比较和隔离 VM 冷启动／恢复通过。未覆盖范围见集成验收。
- [x] 恢复连接重试的上游提交定位：#854 `f20bf92a`，当前已由 `3b4ac980` 集成；补充 IOKit 分支回归。实际 USB/DFU 验收仍单独跟踪。#849 是 Remote Pairing 预设改动。
- [x] #899 模板重启的实际 VM 验收：新身份隔离副本验证原生重启总启动 1 次；真实关机对照验证状态 0 退出后恰好补启动一次。47 项状态机回归、库摘要、根只读和正常关机核对通过。见 [评审与验收](Research/Integration/duo_m5_20261030/CHANGE_REVIEW_20261114.md)。
- [x] RPC 目录、类型和契约的同步评估（#841、#857、#884、#892、#908、#914–#916）：依赖、最终兼容提交、8 项 Duo 声明差异及可执行预检已保存。
- [x] RPC 目录与类型基础生产移植／验收（#841、#857、#884、#892）：195 方法、原生生产者／实际回复校验、完整 Bundle、CI 入口接入、旧准入宿主＋新 daemon 的 VM 验收及回滚完成。
- [x] RPC 契约五项实现与候选验收（#908、#914–#916）：名称／单位兼容、错误码／未知参数、分页、输出暂存和 observe；保留 Duo AX、Auto-Lock `never` 与生命周期。
- [x] 本轮隔离副本最终清理：用户批准异常停止后重试，原组件／标记、21 项库、根只读和 Auto-Lock 原值均通过；最终正常关机，无状态句柄。一次原组件启动未连接的原因未查明。
- [x] 新宿主 GUI × 旧 daemon 实测；#906 网页摄像头路径；#861/#869/#870/#888 构建分发。Bundle／Launchpad 版本仍为 2.15.2，最低 Bundle 2.15.0；Bundle 严格签名、实际 notice 门禁、Launchpad 构建和兼容策略回归通过。未执行 Developer ID 发布签名或 notarization。
- [x] #924 X1、#919／#923 TXM 与其余 9 组 DriverKit、Cryptex、旧固件、启动链和设备改动的范围评估完成，方案与预检已保存。生产移植及独立设备实测仍待完成；文档站发布另行处理。

## 需要独立环境或权限

| 项目 | 现状及继续条件 |
| --- | --- |
| 当前宿主与完整 CFW | 用户已批准 `974031b5…` 准入及新身份副本完整安装；预检、两条安装命令、System 工作镜像卸载、收据及两次实际冷启动已通过。foundation 临时库已回滚；原副本未启动。 |
| Linux FUSE／并发 | macOS 上的 Docker CLI 存在，当前 daemon socket 不存在，且没有 sshfs；需要可用 Linux 验收环境。离线映射测试不替代该项。 |
| USB/DFU 恢复重试、恢复空间峰值 | 客户端 libusb 7/7、IOKit 8/8、原生恢复 72/72 通过。实际验收需要独立目标；涉及擦除的恢复须先获明确批准。 |
| 27.2 铰链与音频、GLES、独立 RPC 候选 | 三个候选预检仍被 AMFI 拒绝。当前 27.1 的局部 RPC 验收已完成；不替代独立候选。见 [候选和运行条件](Research/Integration/duo_m5_20261030/ACCEPTANCE.md#后续独立候选)。 |
| WDA HTTP、宿主快捷键 | 分别需要运行中的 WebDriverAgentRunner 和已获辅助功能权限的宿主环境。 |
| KFC 登录会员点击、应用辅助功能启用来源 | 历史观察，尚无定位证据。见 [F6 记录](Research/Integration/duo_m5_20261030/F6.md)。 |
| 新身份副本的 Trust 提示 | 本轮基础 daemon 与最终候选上提示均已消失；最终候选两次实际提示各验证 20 次后续消失采样。未稳定复现历史失败，原因未查明；未改写点击实现。见 [本轮记录](Research/Integration/duo_m5_20261030/RPC_CONTRACT_NEXT_20261115.md)。 |

## 已完成证据

- [Duo 运行验收](Research/Integration/duo_m5_20261030/ACCEPTANCE.md)：连接稳定性、异常响应、慢响应、断连方向、显示与输入、窗口采样。内屏左横屏边缘手势使用旋转后的面板坐标，复测 3/3。
- [AX 与 Auto-Lock](Research/Integration/duo_m5_20261030/ELEMENT_TAP.md)：30 秒、Never、冷启动，以及同次启动中按 launchd 标签重启 `profiled` 后观察到有效设置更新，测试后恢复原值。
- #917 shell JSON 状态行修复：旧实现复现失败，修复后 6 项通过并接入 CI；完整 Bundle 构建和严格签名通过。
- #907 Launchpad CLI：允许 `--no-template --slim on|off`，其他模板专用开关仍拒绝；旧实现复现失败，模板参数和计划回归、Launchpad Debug 构建均通过。同步四语手册。
- #899 模板重启：guest 在请求重启后正常退出时，宿主只补启动一次。CoreKit 模板设置回归 46/46、完整 Debug Bundle 构建和严格签名均通过。#907、#899 日志位于 `.build/launchpad-907.FUmycAhy/`。
- [截至 2026-11-13 的执行记录](Research/Integration/duo_m5_20261030/WORK_LOG_20261113.md)：保留原清单的提交、命令、日志、历史验收范围和授权来源。旧状态以当前清单为准。

当前任务的验证使用隔离副本。删除数据、变更宿主安全设置、修改其他仓库或原始 VM、发布和推送前，须核对当前任务的明确授权。构建和大体积证据留在 `.build`。四语手册发布前按仓库约定完成 Argon 审阅。
