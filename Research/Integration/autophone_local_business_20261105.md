# autophone-a 本机业务验证

日期：2026-11-05。精确业务安装、三次校准和菜品默认态正式 D0 已通过。归档续验后，Requirement `REQ-20261105-001` 已通过 13/13 出口条件并进入 `accepted`；初轮 12/13 的失败记录保留。

## 实验设置

- autophone：`fix/launchpad-process-paths`，提交 `75ac65bb3d4701ed535ef0a8302a9f4c9ceb22d1`。默认 Agent、Control Plane 源码摘要一致。
- VM：`autophone-a`，generation 1，iPhone17,3 / iOS 27.0.1，Bundle `2.15.0-local.ec12bbac`。
- 产品源码：从现有远端分支取得固定提交 `eba2cc658ac8d7528be1ef4c56ea07bf25eb317b`，通过 Git archive 导出。产品代码未修改。
- 新 Build：`bld-5208625317d9caf3c6b737d188866722ef06c692b3b0630c037e676a151fb9e4`，slot 001。
- IPA：9,949,208 字节，SHA-256 `1e45df01c1f7aa9ff5fca83b5823b0e7f5a06cd95614892851c6b75ed2c82845`。
- 工具链：Xcode 26.4 / SDK 26.4，Node 26.7.0、npm 11.19.0、CocoaPods 1.17.0。clean Release，`clean_acceptance_eligible=true`；未使用封存依赖种子，回执标记 `replayable=false`。本次不声明离线重放或字节级可重复构建。
- 所有业务设备执行通过本机隔离 Control Plane，目标固定为 autophone-a。其他 Rig、日常数据库和原工作区修改未作为操作对象。

## 结果

| 对象 | 结果 | 证据 |
| --- | --- | --- |
| 精确安装 | passed，注册和 Build marker 独立回读通过 | `install-result.json`；Assignment `A-994fe83a54c3430eb3c9c0f4ed113bf2` |
| Region 辅助程序 | 正向控制通过，SpringBoard 698 个区域、Tag 255 为 0 | `regions-A-994fe83a54c3430eb3c9c0f4ed113bf2/receipt.json` |
| 三次正式校准 | passed，两两变化像素 0 | `calibration-verified.json`；Assignment `A-99ee9ae5260b475a9fe3ae3509958511` |
| D0 现采 | passed，默认 Agent，经真实 Lease、fencing、StageGuard 和 ScreenLock | `d0-collected.json`；Assignment `A-8cfe0de7205b417a8c395259474c7266` |
| D0 比较与轮次 | passed，0 Finding，变化像素 0 / 2,638,237，19/19 覆盖 | `d0-result.json`、`exit-gate.json` |
| 设计范围 | 与既有菜品默认态 v4 范围和阈值相同 | `design-scope-verification.json` |
| 收尾 | Rig online、health healthy、ScreenLock 已释放、无活动 Rig 任务 | `verification-result.json` |

## 初轮未通过的出口条件（续验已解决）

唯一失败项为 `comparison_evidence_complete`：

```text
before_snapshot_not_replayable:runs/calibration/CAL-4556cb7ab5624cd188ddbced2f468c5f/CAL-4556cb7ab5624cd188ddbced2f468c5f.capture-01/actual/actual-full.png
```

Before Snapshot 原图存在、摘要和注册采集关系可复算，但本任务状态根位于 vphone 的独立 `.build/.../services/state`，不在 Git 索引内。现行 `evidence_status.repository_replayable` 只接受同一 Git 索引中可还原且字节一致的文件或证据归档映射，因此出口闸拒绝。未调用 accept，未改写冻结的 Before Snapshot，也未修改出口条件。

该项已通过下述本机独立归档解决。第二台 VM、本机并发容量、其他页面、定位和真实第三方 QR 仍未验证。

## 保留的失败与部署过程

1. 历史 Build `bld-d0bf9b08…` 对应 IPA 在本机未找到。本机重建登记了新 Build，没有复用历史产物身份。
2. AX dump、app_uninstall 首次编译因 Clang 默认模块缓存目录不可写失败；改用本任务缓存目录后构建通过。lock_state 同样在本机编译。
3. npm 安装 48.45 秒、Expo 模板 0.51 秒、原生工程生成 3.69 秒、CocoaPods 187.06 秒、Xcode 505.63 秒。编译期间健康读数超时；当时 VM PID 95231 仍存活，不能记为 VM 崩溃。恢复记录 `REC-50001064914c7eb03a52af982723645d` 的 Assignment 返回 passed，PID 未变化。随后暂停健康守护，在无活动任务时停止 Agent/VM，再完成构建；构建结束后通过 Launchpad 启动并恢复端点。
4. 首轮精确安装在 region tag 正向控制处拒绝。新 VM 尚未部署该辅助程序。第一次受控部署中，正向控制通过，但 `/var/jb/tmp` 缺失使 SpringBoard 区域输出失败；第二次补齐目录后部署和安装通过。
5. 上述辅助程序部署通过一次性执行器接线调用现有 `deploy_regions`，运行在真实 provisioning Assignment 的 fencing、StageGuard 和 ScreenLock 中。部署后已停止该执行器，三次校准和 D0 均使用默认 Agent。临时接线文件、二进制摘要和两次回执保留在本目录；未改产品门禁。
6. 校准的原始观测缺少部分按钮字色，直接构造墨迹参照被拒。使用既有 `PixelStyleObservationAdapter` v3 对三份原图派生新样式包，原始校准证据未改；另存 `ink-derivation.json` 绑定来源和派生摘要。随后墨迹参照构造通过。文字墨迹只证明与本 Build 的 iOS 渲染一致。
7. 首次建单因原始需求文件位于状态根外被拒；将本轮任务说明写入状态根后重新建单通过。历史需求、设计和证据未修改。

## 本机位置

本记录及原始执行日志位于 `/Users/qcz3840/.codex/worktrees/launchpad-process-paths/autophone/runs/autophone-local-20261105/business`。包仓库、Requirement、校准及正式 D0 原件位于 `/Users/qcz3840/github/vphone-cli/.build/autophone-local-20261105/services/state`。会话入口仍为该 services 目录的 `runtime/session.env`。工作树正在被默认 Agent、Control Plane 和健康守护使用，修复提交尚未合入主线。

## 归档与验收续验

用户要求继续完成归档和验收后，在既有 state 目录建立独立的本机证据仓库，分支为 `evidence/autophone-a-validation`。该仓库不属于 autophone 源码仓库，未配置远端、未发布；原始 Manifest 的 `local_only`、AI 和外发规则未修改，证据只用于同一 Rig 的历史结论复核。数据库、服务日志、SSH 私钥和密码未进入提交。

- 验收前快照：`1d42f8e4232b892e10812f821224a99a2e3fed36`，143 个文件。最初冻结的 69 个文件摘要均未变化。
- 用现有 `plan_requirement_evidence` 校验 D0 与三个墨迹来源归档计划。墨迹来源从既有派生包逐字节复制到现有归档器约定的位置，冻结引用和哈希保持不变。
- 原 state、独立新检出，以及去掉数据库与控制面配置的新检出，均以未修改的验证代码通过 13/13 出口条件；冻结输入身份一致。
- 正式 `workflow accept` 于 2026-11-05 15:40:57 +08:00 完成。该入口先复制标准 D0 和墨迹来源归档，再写入唯一 `requirement_accepted` 事件。
- 验收后快照：`ec27d174ee8aea53026503f48c56183de73f9a00`。另一个独立新检出复算为 `accepted`、13/13。归档工作区干净，未配置远端。
- 验收仅修改预期的 Requirement 当前态和追加式账本；其余 67 个冻结文件摘要不变。autophone 产品验证代码、设计、比较阈值、原图和 Manifest 未修改。
- 最终即时回读：Rig online、源码身份一致、health healthy、ScreenLock 已释放、活动 Rig 任务为 0。

本轮新增证据位于同一任务目录的 `../archive/`：`archive-plan.json`、`gate-before-accept.json`、`gate-fresh-checkout.json`、`gate-offline-checkout.json`、`accept-result.json`、`gate-accepted-checkout.json`、`gate-final.json`、`final-result.json`。初轮 `business/exit-gate.json` 和 `verification-result.json` 保持原字节，代表当时未验收的状态。
