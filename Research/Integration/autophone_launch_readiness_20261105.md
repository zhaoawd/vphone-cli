# autophone-a 启动就绪校验修复

日期：2026-11-05。已修复本轮复现的前台状态延迟确认问题，并在最终本地提交下完成肯德基 Prod、飞书、企业微信六次启动复验。vm-2607 保留，未切换日常默认目标。

## 原因与修复

原始采集轮中，肯德基 Prod 的 `apps.launch` 返回 `ok=true`、PID 1879、`frontmost_verified=false`。autophone 的 wire adapter 将该返回判为未验证，DeviceSession 随即抛错；独立前台查询约在命令返回后 1.231 秒变为 `verified=true`，PID 仍为 1879。该次失败由启动返回时前台状态尚未确认、调用方未等待后续确认触发。飞书、企业微信的历史失败未在本次修复前的原始采集轮复现，未独立确认其历史原因。

修复位于 autophone 宿主侧，未修改 guest、VPhone.bundle 或 IPA：

- wire adapter 仅把原始 `ok=true`、正整数 PID、`frontmost_verified=false` 识别为 pending；guest 提供的同名内部标记不作为依据。
- DeviceSession 只发送一次启动命令。pending 状态下，有限查询同一目标的前台状态；Bundle ID、原 PID、`verified=true` 同时匹配才返回成功。
- 初始启动、后续查询、嵌套 StageGuard、写栅栏和 UDS 发送共用 15 秒绝对截止时间。传输在能力查询、实际 RPC、连接和发送前核对剩余预算。显式拒绝、异常返回、错误应用或 PID、租约丢失和传输失败继续拒绝通过；不重发启动命令。
- legacy 返回不进入 pending 查询流程。

本地提交：`b15fb6cfdd7e1b7282a87a887dd72f056c53ee14`。验证完成时工作区源码干净；该提交现已推送到 `fix/launchpad-process-paths`，尚未合入或发布。下述设备读数仍对应原验证阶段。

## 最终验证

设备固定为 autophone-a generation 1 / iOS 27.0.1。每个应用精确安装原已登记 Build 后，连续执行两次终止和启动；设备写入通过隔离 Control Plane、真实 Lease、StageGuard 和 ScreenLock。临时 executor factory 仅增加诊断与原始 RPC 采集，不替换生产 `launch_app` 实现。未执行登录、消息、订单、支付或隐私条款确认。

| 应用 | Build ID 前缀 | 两次启动结果 | 启动请求数 | 启动调用耗时（毫秒） |
| --- | --- | --- | --- | --- |
| 肯德基 Prod 6.35.1 (6) | bld-6a887785e564 | 2/2 通过 | 2 | 1618.741、473.252 |
| 飞书 7.65.10 (663587012) | bld-18a74eb83476 | 2/2 通过 | 2 | 598.038、473.681 |
| 企业微信 5.0.8 (218278) | bld-b5da481ef94f | 2/2 通过 | 2 | 453.062、537.608 |

最终轮肯德基 Prod 首次返回仍为 `frontmost_verified=false`，PID 2346；DeviceSession 在返回成功前取得同一 Bundle ID、PID 2346、`verified=true` 的前台回读。六次启动均只发送一次 `apps.launch`，全部后续采样的前台与 PID 一致，SpringBoard 身份未变化。飞书、企业微信本轮均直接返回前台确认成功。

新增回归测试先失败后通过，覆盖延迟确认、错误应用/PID、异常与显式拒绝、共享截止时间、外层和内层授权延迟、租约失效和传输异常。相关设备、协议、StageGuard 与 Provisioning 测试 220 项通过；直接使用 UDS 的设备 API、嵌入控制台测试 58 项通过；Ruff 与 diff 检查通过。首轮沙箱不允许临时 UNIX socket bind 的环境失败日志保留，允许该隔离操作后重跑通过。

只读代码审查发现的嵌套授权截止时间问题已补充测试并修复，复审无阻断项。未执行合入或发布门禁；上述结果不构成长期稳定性、完整商业业务或历史所有故障原因一致的结论。

## 收尾与后续

- 标准默认 Agent 已恢复；Control Plane 与 Agent 均运行上述提交，源码摘要为 `35b35da55a3b2c3af3d8c998b4cefa82e7a477ce01649d8c86ee2530903b48f8`，身份一致。Rig online、health healthy、active_rigs=0、ScreenLock 已释放。
- 已用标准 Provisioning 恢复原已验收 food_ordering_v2 Build `bld-5208625317d9caf3c6b737d188866722ef06c692b3b0630c037e676a151fb9e4` 的安装事实，未重跑 D0。69 个受保护文件与既有 accepted 提交一致。
- 旧 VM 的四个文件哈希和 Disk.img 元数据与 IPA 验证开始前一致，磁盘无打开进程；未计算整盘内容哈希，未启动或替换旧 VM。
- 后续确认需迁移的账号、登录态与数据，并验证实际使用的关键用例和所需 Frida/API 捕获、定位、摄像头流程；满足使用需求后再备份并切换默认路由。

## 证据

本机证据根：`/Users/qcz3840/.codex/worktrees/launchpad-process-paths/autophone/runs/autophone-local-20261105/launch-readiness/`。

- `registered-ipas.json`：精确 Build 和 Artifact 摘要。
- `results-trace1.json`：修复前原始采集；`results-trace-final.json`：最终提交的设备复验。中间修复轮记录另存，未覆盖原始结果。
- 应用目录中的 `trace.json`：原始 RPC 帧、单调时钟时序、前台采样、SpringBoard 身份和截图摘要。
- `tests-deadline.log`、`tests-console-transport.log`：220 项与 58 项检查结果；各 red 日志保留失败先验。
- `review.json`、`implementation-files-final.json`：审查结论和最终实现文件摘要。
- `final-verification.json`：最终任务、六次启动、延迟确认、服务恢复、旧 VM 和受保护证据核对。

七个 IPA 的原始兼容性验证记录见 `autophone_ipa_compatibility_20261105.md`；该历史记录的即时校验失败结论由本次后续验证补充。
