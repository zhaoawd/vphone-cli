# autophone-a IPA 兼容性验证

日期：2026-11-05。本记录保存启动修复前的 IPA 验证阶段；后续进展见 [启动就绪校验修复](autophone_launch_readiness_20261105.md)。七个选定 IPA 均已通过安装、LaunchServices 注册和独立身份回读。五款应用最近一轮两次冷启动的即时校验通过；肯德基 Prod 和飞书仍存在安装后第一次启动即时校验失败的问题。当前保留 vm-2607，尚未切换日常默认目标。

## 实验设置

- 设备：autophone-a，generation 1，iPhone17,3 / iOS 27.0.1，Bundle `2.15.0-local.ec12bbac`。8 vCPU、8 GiB RAM、64 GiB 虚拟磁盘，预览 430×932。
- autophone：`75ac65bb3d4701ed535ef0a8302a9f4c9ceb22d1`，源码工作区保持干净。未修改产品代码或上游安装器。
- IPA 来源：本机原仓库 `/Users/qcz3840/github/autophone/packages`。逐个核对原登记的 SHA-256、字节数和 Bundle ID，再登记到本次隔离包仓库。商业应用来源保持 `unknown`；靶 A 保留原 Build 的 Source Revision。原包仓库未作为写入目标。
- 每次安装指定完整 `--build-id`、`--rig-id autophone-a` 和 `--device autophone-a`。设备操作通过隔离 Control Plane 派单，使用真实租约、StageGuard 和 ScreenLock。
- 使用临时 executor factory 在安装任务内执行启动检查；安装任务的 `passed` 只表示 Provisioning 通过。启动结果另存 `smoke.json`。这批检查不构成正式业务回归或 Requirement 验收。
- 每轮终止被测应用，回读 PID=0，再启动两次；每次在启动命令返回约 2 秒和 14 秒后采样 PID、前台身份和截图。另核对 SpringBoard PID 与启动时间。
- 未登录、下单、支付、发送消息或同意应用隐私条款。通知权限弹窗未确认，骑手端和飞书部分截图存在该弹窗遮挡。

## 结果

“即时校验”指 `app_launch` 返回的 PID/前台校验；“末次采样”指约 14 秒后的独立前台查询。

| 应用 | IPA 版本（构建号） | 安装及身份回读 | 即时校验：初轮 → 复测 | 界面与结果 |
| --- | --- | --- | --- | --- |
| 肯德基 UAT | 6.34.1 (3) | 通过 | 2/2 → 未追加 | 显示隐私政策页 |
| 肯德基 Prod | 6.35.1 (6) | 通过 | 1/2 → 1/2 | 显示隐私政策页；两轮第一次即时校验均失败，末次采样均确认前台 |
| 必胜客 | 6.53.1 (1) | 通过 | 2/2 → 未追加 | 显示隐私政策页 |
| 肯德基骑手端 | 9.1.1 (4) | 通过 | 2/2 → 未追加 | 显示账号密码登录页及通知权限弹窗 |
| 飞书 | 7.65.10 (663587012) | 通过 | 1/2 → 1/2 | 显示信息保护指引；两轮第一次即时校验均失败，末次采样均确认前台 |
| 企业微信 | 5.0.8 (218278) | 通过 | 1/2 → 2/2 | 显示隐私政策页；首轮异常保留，复测未复现 |
| UI Eval Target A | 1.0.0 (1) | 通过 | 2/2 → 2/2 | 初轮显示 selection 文件不可读；补入既有 baseline selection 后显示首页，mutation 与 nonce 回读一致 |

初轮七款与追加四款共 22 次冷启动：即时校验通过 17 次、失败 5 次；22 次末次采样均返回 `verified=true` 且 Bundle ID 正确，22 次 PID 在两次采样间一致。飞书两轮第一次的早期采样为 `verified=false`，末次为 `true`。所有轮次 SpringBoard 身份均未变化。该结果不声明长时间运行稳定性。

即时校验失败日志为 `app_launch failed: application launch/foreground was not verified`。该阶段原因未查明。后续采样成功不能替代该即时校验，原始五次失败记录保留；后续独立诊断与修复复验见启动修复记录。

首批准备阶段还遇到锁屏及熄屏，已保留 a1/a2 记录。原生通知读数确认第一次 Home 仅点亮屏幕，按现有最多两次 Home 的流程解锁后开展上述 a3/a4 检查；锁屏受阻不计入上述 22 次。

靶 A 使用既有 `mutation_id=baseline`、`nonce` 协议写入本机新 VM 的应用 Documents，回执为 `ui-eval-selection-receipt/v1`。本次只确认选择回执与页面显示，未追加像素差异、AX、API 捕获、定位或摄像头业务回归。

## 收尾核对

- 已恢复标准 Agent（默认 executor factory），Rig online、health healthy、active_rigs=0、ScreenLock 已释放。
- 已通过标准 Provisioning 恢复原已验收的 food_ordering_v2 Build `bld-5208625317d9caf3c6b737d188866722ef06c692b3b0630c037e676a151fb9e4` 的安装事实。未重跑其 D0；与本地 accepted 提交比较的 69 个受保护证据文件均未变化。
- vm-2607 位于 `/Users/qcz3840/github/vphone-cli/vm-2607`，本轮未启动或替换。config.plist、nvram.bin、SEPStorage、.vphone-runtime.json 四个文件的哈希及元数据与本轮开始时一致；Disk.img 的 inode、大小、修改时间一致，未计算磁盘内容哈希；结束时无打开该磁盘的进程。
- 本轮保留原 VM、应用数据、历史 Build 和验收记录。所有本次安装仅写入 autophone-a 与隔离状态目录。

## vm-2607 替换条件

以下是该阶段的评估条件。启动校验项的后续处理见 [启动修复记录](autophone_launch_readiness_20261105.md)；账号、数据、关键业务验证与备份切换仍需完成。

1. 查明并处理肯德基 Prod、飞书首次启动即时校验问题，保留企业微信首轮异常记录并补充该路径验证。
2. 确认旧 VM 仍需保留的账号、登录态和应用数据，完成必要迁移；运行实际使用的关键用例。未准备的账号验证、API 捕获、定位、摄像头及长时间运行不能按本次启动检查判定通过。
3. 本轮只覆盖各应用选定版本，其他历史 IPA 未全部验证。amap 本机包仓库没有可用 IPA；本机旧 VM 的实时应用清单和数据未探测，历史安装回执只作为历史证据。
4. 验证满足使用需求后，对已关闭的旧 VM 做可恢复备份并校验，再将日常默认路由切换到 autophone-a。保留两个 VM 原有标识、历史证据和回滚路径。

## 证据

本机证据根：`/Users/qcz3840/.codex/worktrees/launchpad-process-paths/autophone/runs/autophone-local-20261105/ipa-compatibility/`。

- `registered-ipas.json`：IPA 全量摘要、原 Build ID 与隔离 Build ID 对照。
- `results-a3.json`、`results-a4.json`：安装任务与启动检查索引；每个应用子目录内含原始 `smoke.json` 和 JPEG 截图。
- `target-a-selection/`：selection 请求、准备记录及设备回执。
- `final-verification.json`：上述数量、当前控制面状态和旧 VM 核对结果。
- `accepted-evidence-verification.json`：与 accepted 提交 `ec27d174ee8aea53026503f48c56183de73f9a00` 比较的 69 个文件结果。
- `agent-restored.json`、`food-restore-assignment.json`：标准 Agent 恢复记录与原业务 Build 的安装回读。

此前 food_ordering_v2 的正式验收见 `autophone_local_business_20261105.md`。本记录未扩大其验收范围。
