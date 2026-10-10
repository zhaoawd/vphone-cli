# B34：RootHide 研究副本与 T08 180° 请求诊断

## 结果与范围

本轮已查明受控应用在放宽方向集合后，180° 请求无错误但实际未旋转的原因。应用内 UIKit 的方向集合变为 30，SpringBoard 的独立场景参与者策略仍将倒置纵向判为不允许；它将场景支持集合 30 清理为 26，排除倒置纵向位 4。180° 请求确实到达 SpringBoard，但请求接收没有导致界面方向变更。

限定受控场景的反事实实验确认了该条件的作用：原条件返回 0 时，系统支持集合 26、实际方向 1；仅将该场景的允许条件临时返回 1 后，系统集合 30、实际方向 2；恢复条件后，系统集合重新为 26，实际方向最终为 1。实验没有修改产品源码或持久系统方向策略。诊断仅覆盖本机冻结研究工件、当前 iOS 26.1 客户机及受控应用，不直接证明全部系统应用的行为。

已在本机构造 `vm-roothide-b33-20261010`，安装 Irisin 4.5.26 和 89 个固定软件包，冷启动检查通过。研究副本已正常关机并释放磁盘。源 `vm-new` 按原命令恢复，原健康监测 PID 21157 已 SIGCONT，新采样 healthy。T08 整项仍未接受：旧 CFW 自动激活、默认产物完整构建及构建/运行来源一致性与整体验收未完成。

## 实验设置

- 分支：`codex/upstream-2d21d21-integration`。
- 用户批准仅在研究副本内转换 bootstrap、安装和清理；正常停止源 VM；暂停精确匹配源 socket 的健康监测，结束后恢复。若源自动重启则暂停。B34 运行没有检测到源自动重启。
- 源停止前 PID 20668、instanceID `9ADAB589-C178-49ED-ABDC-3A43416F071D`。健康监测 PID 21157 的命令、开始时间和 socket 精确核对后发送 SIGSTOP。源仅正常停止一次，连续 10 秒确认磁盘释放。
- 宿主签名工件 SHA256 `35d53dbd71371180d599f684a1584fdf27fe1b48fb480a5d5bd6390419163623`；研究 API SHA256 `7f66a29680e0b527e31fa204c2306f750ffccc5a915728ac775ec1cd787ec454`，IcliKit 0.7.16。现有宿主没有 `--no-vphoned-update`，显式使用副本原 `.vphoned.signed`；现代 API 独立 API_ONLY 启动。这不构成默认产品来源一致性验收。
- Frida 17.17.0 临时服务，认证输入仅在私密构建目录和客户机临时目录中；没有导出令牌。
- 受控应用 bundle ID `research.vphone.b31.rotation`，PID 479；场景 `39275F10-EB53-4363-BA29-A5FBF7BE533D`；SpringBoard PID 34。完整矩阵和因果实验均保持同一应用 PID/场景。
- 原应用可执行文件保持。新增 `UILaunchScreen={}` 这一项元数据以退出兼容窗口模式：窗口由 320×480 变为 430×932，原生应用内 Home 键条件由 1 变为 0，基线集合 26 与 B32 一致。该变化明确保留于 `fixture-modern-build.json`，未静默沿用不等价样本。
- 应用侧只临时改变 B32 已定位的 Home 键调用结果，集合 26→30→26。SpringBoard 请求边界探针只读；后续反事实探针只匹配受控 bundle 的 `SBTraitsSceneParticipantDelegate`，仅改变 `_isAllowedToHavePortraitUpsideDown`，finally 撤销并卸载。

## 原始现象与原因证据

| 实验 | 现象 | 证据 |
| --- | --- | --- |
| 完整 A/B/A 矩阵 | A 的 180° 返回 UISceneErrorDomain 101；B 的 90°/0° 实际为 3/1；B 的 180° 超过 10 秒无错误、方向保持 1；恢复 A 再次拒绝 | `rotation-a96515c5673f/rotation-probe.json` |
| 最小单请求 | B 的集合 30、前台、未锁定；180° 无错误且未观察到方向 2；实际入口退出 1 | `rotation-b869a8869c94/rotation-probe.json` |
| 请求边界对照 | SpringBoard 请求助手分别收到 8/2/4，错误输出均 nil；180° 未出现应用方向选择/更新路径 | `request-boundary-5dc943fe6c6f/request-boundary.json` |
| 原条件 180° | 允许条件 0，清理输入 30→26；连续 11.252 秒，方向 1，无错误 | `scene-gate-1a6e985e17da/scene-gate.json` |
| 临时允许 180° | 同一场景允许条件 0→1；清理输入 30→30；连续 11.749 秒，实际方向稳定为 2 | 同上 |
| 恢复条件 180° | 条件恢复 0，清理输入 30→26；11.503 秒观测的首样本仍为 2，约 0.25 秒后为 1；判定 `target_seen_but_not_stable` | 同上；`causal-verification.json` |
| 撤销全部 SpringBoard 探针后 | 独立最小请求再次得到 `no_error_without_rotation`，退出 1，未观察到方向 2 | `rotation-7a6b72017d0e/rotation-probe.json` |

`scene-policy-code.json` 与 `gate-code.json` 保留实际运行方法反汇编：

1. `_supportedOrientations` 读取场景客户端集合，并调用 `_sanitizedMask:forApplication:`。
2. `_allLegalOrientations` 根据 `_isAllowedToHavePortraitUpsideDown` 返回 30 或 26。
3. `_sanitizedMask:forApplication:` 对普通集合与合法集合求交；对单独的倒置集合 4，在不允许时返回纵向集合 2。后者是代码证据，本次运行时清理输入观测为 30，未将代码分支结果写成运行观测。
4. 请求助手 `_startSceneOrientationRequestWithDesiredOrientations:error:` 保存非零请求集合并通知仲裁更新。实际 180° 输入为 4、错误输出 nil；这一接收步骤没有证明方向已完成。

`gate-callees.json` 按实际 adrp/add/br 跳转桩解析，条件调用 `__sb__runningInSpringBoard`、`SBFEffectiveDeviceClass`、`SBFEffectiveHomeButtonType` 和 `UIDevice.userInterfaceIdiom`。本次没有取得这些 SBF 函数的实际返回值，因此不为枚举值补充未经验证的设备类型名称。已确认的直接原因是当前场景允许条件为 0 及其方向清理结果。应用内放宽 Home 键条件没有改变这一独立的 SpringBoard 条件。

探针中 `native` 字段表示该次调用在当前实验条件下的原方法结果。临时允许阶段的 `_allLegalOrientations` 和清理方法结果已受内部允许条件覆盖影响，不能将其中的 30 称为未注入基线结果。

请求传递丢失与本轮记录不符：SpringBoard 收到正确集合 4。原始现象在超过 10 秒和调用前两秒稳定集合的条件下仍出现，且改变系统条件后实际旋转，支持上述原因。恢复阶段首样本的方向 2 不能用来证明原始未注入请求曾短暂旋转；独立最小复现中没有方向 2。不能从本轮采样推断所有时序或更短于采样间隔的事件。

## RootHide 构造和冷启动

95 个准备输入的摘要再次核对。源原 rootless 仅在研究副本内卸载。Irisin 安装返回成功，RootHide 根为 `/private/var/containers/Bundle/Application/.jbroot-000114514191980C`，实际 inspect 仅一个根。事务 dry-run 退出 0 且 status 摘要保持；实际 89 包事务退出 0，最终含 firmware 虚拟包的 90 条记录均为 `install ok installed`，`dpkg --audit` 无输出。

基础链接、账户数据库和 SSH 密钥在研究副本内准备。冷启动前后 dpkg status、pwd.db、spwd.db、ed25519 私钥的客户机内摘要一致；只导出摘要，没有导出私钥或 master.passwd。现代 API 布局、健康和固定摘要通过。Irisin helper 与 RootHide SSH 服务显式激活退出 0。这不是旧 CFW 默认自动激活验收。

保留的失败：Irisin 首次输入未满足 UUID 缓存路径约束；改用固定协议路径。API 原 TMPDIR 创建了空 `/var/jb/tmp`，与布局检查冲突；核对为空后仅移动该目录，冷启动时指定并创建研究 API 独立 TMPDIR。首次 fixture 安装因该 TMPDIR 不存在失败，创建后重试通过。基础 helper 曾因恢复环境无 env 退出 127；postcheck 曾因 RootHide readlink 返回虚拟根而退出 1，改用恢复 shell 的物理路径检查，未删减路径一致断言。原兼容模式夹具不满足 26 基线，保留为无效实验。

## 验证、失败与恢复

- `.venv/bin/python -m unittest discover -s tests -p 'test_t08_rotation_probe.py' -v`：8 项通过，覆盖窗口、请求 ID、错误、实际方向、短暂方向、锁定、后台、PID 和采样连续性。
- `verify-scene-gate.py`：回放实际因果实验，核对各阶段允许值、清理集合、PID、连续样本、恢复以及最后的独立原始复现。初版将恢复阶段误预期为全程方向 1，断言实际失败；逐样本发现首样本为 2 后，明确改为短暂方向判定，保留失败说明，未修改原始样本或方向判定器。
- 补充只读设备条件查询等待 SpringBoard 主队列回调，未取得数值；中断后临时 Frida 服务被结束。SIGTERM 后该进程仍在，核对 PID 441 及专属路径后 SIGKILL，最终 API 列表 count 0。
- 撤销探针后的最小复核第一次因 classic `guest not connected` 退出 2。通道自行重连后原命令重跑退出 1，得到原始现象。两个结果分别保留。
- 测试应用及两个容器卸载，apps.search 为空。仅删除研究副本的 `/var/root/vphone-b34-frida`、`/var/root/vphone-b34-packages`、`/var/root/vphone-b33-control`。保留 RootHide 和 `/var/root/vphone-b33-api` 基线以供后续研究启动；宿主复现输入保留。
- 构造后的首次 classic 关机找不到 shell，宿主超时后停止；`construction-run-exit.json` 明确 `normal_guest_shutdown=false`。第二次通过现代 `system.shutdown(force:true)` 正常关机，日志含 launchd 卸载卷、`ApplePSCI - system off`、`[vphone] Guest stopped`；宿主退出 0，lsof 独立确认研究磁盘无句柄。
- 源原 argv 恢复后 PID 25784、instanceID `45E94888-1543-476D-818F-D59B02AD208B`。连续三次 app_list 客户机往返通过，原健康监测 21157 身份再次核对后 SIGCONT，状态 Ss，新 probe_count 3747 且 UDS/vsock/总体 healthy。最终复核 count 3881 仍 healthy，目标限定客户机往返通过；源磁盘由 launchd 启动的 Virtualization XPC worker PID25787 持有，不要求该 worker 的 PPID 为源宿主。初版最终核对曾误用宿主 PID 和直接父子关系断言，实际失败记录保留于 final-verification.json。仅源运行被停止和恢复，不宣称源磁盘内容或运行元数据保持不变。
- 全程保守阈值 5 GiB。构造运行最低 291,766,648,832 字节；诊断运行最低 290,173,501,440 字节（约 270.24 GiB）。恢复核对余量 293,159,870,464 字节（约 273.03 GiB），最终复核余量约 271.59 GiB。阈值未触发。

## 后续范围

本次诊断已完成。系统条件覆盖仅作为研究反事实，不进入产品。后续 T08 工作仍为旧 CFW 自动激活、默认完整产物与来源一致性验收。新研究副本与源拥有同一设备身份，后续使用仍须避免并行启动；启动脚本保留源磁盘/监测状态及余量检查。重新复现实验需重新安装已保留的夹具与临时 Frida，并按授权的源维护顺序执行。
