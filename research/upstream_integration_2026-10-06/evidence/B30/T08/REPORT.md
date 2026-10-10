# B30：T08 RootHide 服务状态 144 与旋转诊断

日期：2026-10-10（Asia/Shanghai）。样本为 `vm-roothide-20261010`，源 `vm-new` 保持停机。没有新增整项 accepted；T08 继续部分完成。

## 服务错误与修复

临时诊断库在原 API_ONLY 进程内插入 `_xpc_pipe_interface_routine` 记录，原样传递参数、flags 和返回值；不更改 domain 顺序、fallback 或错误码。确认 parent/worker 均实际加载，worker UID/EUID 均为 0。Irisin 和独立服务 fixture 的 start 均观察到 routine 813、domain 2、handle 501、transport 0、reply.error 144；原文为 `Requestor lacks required entitlement`。没有 system 回退调用。该证据确定本次失败在 user domain 的 launchd reply 层。

固定 RootHide launchctl 软件包的签名包含 `com.apple.private.xpc.service-configure`，原候选不含。仅增加该键后重签，API start/stop 返回 0，实际服务 PID 存在，Irisin 也成功启动。恢复原签名再次返回 144；关闭 XPC 诊断库后，修正候选 start/stop/unload 继续通过，label 最终缺失。该对照支持本次 RootHide 测试环境中的 entitlement 缺失判断；未独立复验历史 rootless 样本是否同因。

原候选 SHA256：`83075a0c9de2ff5bbfd01b211ce204f59bd18cdf9eb0efb7bd0891a62f00bc07`。修正候选 SHA256：`177e8d9a7c103d9be206800bde2b118852bd9a64115ac6127f762035c122b59e`。51 个 Mach-O section 载荷摘要相同；签名 entitlements 仅差此键。没有执行 Xcode 全量重编译，采用已固定编译载荷重新签名；签名结构和文件摘要发生变化，不能称为整个文件字节相同。

自动审批最初拒绝将权限持久加入产品，理由是“继续 T08”未明确覆盖产品 launchd 配置权限扩大。准备两行补丁后，用户明确授权该单键修改及候选校验，随后完成 `sources/VPhoneDaemon/Configuration/VPhoneDaemon.entitlements` 两行增量。未新增其他权限，未修改服务 fallback、classic daemon、宿主 AMFI/TCC 或系统 helper。

候选位于 `.build/acceptance/B30/candidate`。源 policy 与实际签名一致；`scripts/check_daemon_api.py --candidate ... --record` 通过。相关 `test_daemon_api_build.py` 6 项与 `test_guest_payloads.py` 6 项通过。独立只读审查无 Critical/Important。manifest 的 activated=false/runtime_validated=false 是静态准备记录，实际运行范围以本批证据为准；没有运行完整 Swift 或固件测试。

## 实际 RootHide 服务验收

在当前物理 RootHide 的 Library/LaunchDaemons 中新建独立 plist，初始 ProgramArguments 为 `/usr/bin/sleep`, `30`。实际 services.load 重写为当前 RootHide 物理路径并设置 __Patched；保存重写前后 plist。重复 load 的 patched 数组为空；start/status、signal TERM、restart、stop、remove、unload 全部通过，实际运行 PID 可见，最终 label 缺失。没有测试 enable/disable、生产服务破坏性操作或 root 目录重命名。

首轮脚本把 `/private/var` 与 `/var` 的标准化结果按字符串直接比较而失败；实际 load 返回 200 且已重写，finally unload 通过。保留原失败后，用 API 返回的标准 `/var` 路径重跑通过。该失败不属于产品路径重写失败。测试 plist 已删除，标准输出文件未创建。

## 旋转结果

| 前台应用 | 0° | 90° | 270° | 180° |
| --- | --- | --- | --- | --- |
| Settings | 通过 | 未应用，保持 0° | 未应用，保持 0° | 未应用，保持 0° |
| Safari | 通过 | 通过 | 通过 | 未应用，保持 270° |

临时 AX 诊断库保留原 setter 的参数和调用，记录 activeInterfaceOrientation 原始值，并在 setter 前后额外调用 getter；这会改变调用次数与时序，不能描述为对运行完全无影响。失败项原始 AX 角度保持原值；API 在 setter 响应后 0、0.25、0.5、1、2 秒的采样也未达到请求值。关闭所有诊断注入后完整重跑，矩阵一致；前台应用通过 runningboard 验证，方向锁关闭。最终恢复基线角度和锁状态，并发送 Home 键。首次错误使用未知 `home` 命令的返回保留，修正为 `key/name=home` 后成功，Home Screen 读回 source=unavailable/verified=false，不宣称该读回本身完成强身份验证。

客户机 Info.plist：Settings 的 UISupportedInterfaceOrientations~iphone 仅 portrait；Safari 默认 iPhone 声明 portrait/landscapeLeft/landscapeRight，未声明 upside-down；两者 iPad 声明包含更多方向。本样本为 iPhone。声明与现象一致，运行时 scene 支持集合和实际策略拒绝仍未取得，不能把相关性写为完整因果结论。失败原因尚未完整查明；没有绕过应用方向策略或让 API 错误伪报成功。

最终未注入诊断库的 8 张截图与记录 SHA256 全部一致。已视觉检查 Settings 竖屏及 Safari 横屏，分别为 1290×2796、2796×1290。首次诊断矩阵的截图随后被重跑的同名文件覆盖，原像素未保全；首次矩阵中的摘要保留为当时记录，不提供对应原图字节。归档的同名 JPEG 仅对应最终 clean 矩阵。原始 AX 日志与两个矩阵 JSON 均保全。

## 清理与剩余工作

客户机已恢复 B29 原 API_ONLY 候选，未把修正候选装入默认启动链。临时库、客户机重签副本及夹具已移除。系统 classic 与缓存 SHA256 均为 `306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001`。因此下次使用旧 B29 研究脚本仍启动原 API，不能将本轮候选验收描述为默认启动产物已更新。

VM 正常停机，退出 0，日志含 ApplePSCI system off 和 Guest stopped；独立 lsof 确认源与样本 Disk.img 无打开句柄。既有 vm-2607 PID35668 保持运行。源 config、classic 载荷、restore-info、NVRAM 摘要及磁盘容量/mtime 保持，未计算 64GiB 全盘摘要。

独立线程每 0.5 秒检查 5 GiB 阈值，低于阈值只发一次停止信号。本轮最低记录 36,160,536,576 字节，最终独立读回 36,167,680,000 字节（约 33.68 GiB），未触发阈值。没有宿主 AMFI/TCC 修改。

T08 剩余：运行时场景方向策略与完整旋转验收、旧 CFW 自动激活 RootHide/默认产物整体验收，以及其他原合同未覆盖项。当前记录不能升级为整项 accepted。
