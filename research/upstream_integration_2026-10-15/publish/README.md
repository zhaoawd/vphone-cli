# 本地改动提交与推送核验（2026-10-15）

目标分支：`codex/upstream-2d21d21-integration`，远程：`origin`（`zhaoawd/vphone-cli`）。整理前本地 HEAD 为 `0d22721f3b70771922e5df389c6bd5c974e77b7d`；已刷新远程，远程基线为 `2c119ae60996ddd59783327b063a2a4aeeb297b1`，本地领先 39 个提交、落后 0 个提交。推送包含这 39 个提交，不改写其历史。

提交按五组组织：Capstone 依赖补丁的复现；kernel generation/update/rollback、I/O 追踪与相关 launcher 路由；IcliKit 0.8.5 与 JPEG overlay；8a75092 声明目录与迁移及本轮研究证据；历史验收证据与发布排除规则。

## 文件与证据

[证据打包清单](evidence-packaging.json)记录排除路径、压缩路径映射、原文及压缩文件 SHA-256。80 项原文共 78,185,861 字节，对应压缩文件共 8,148,345 字节；每项都验证解压后与原文逐字节一致。历史文档中的原文路径可以通过清单找到 `.gz` 文件，使用 `gzip -dc <path.gz>` 读取。原文没有删除或覆盖。

以下文件仅保留在本地，不纳入提交：

- `2026-10-13-task8/acceptance/kernel-v9-plan-b-candidate-installed-kernel.im4p`：固件输出，43,991,410 字节。
- `2026-10-14-kernel-io-factorial/compiled-sources/`：重复源码快照，包含资源归档、图标及 `signcert.p12` 副本；整个目录排除。原有构建输入和来源清单仍保留。
- 两个当前账户不可读的 JSON：`kernel-v9-rollback-a-amfi-restore-check.json`、`kernel-v9-rollback-a-marker-images-01-marker-images-diagnosis.json`。没有修改权限或根据其不可读内容新增结论。
- 构建目录、候选二进制、VM 镜像与凭据不纳入本轮新增文件。

已有 39 个待推送提交新增可达的 1,172 个 blob 共 31,345,963 字节。已检查文件大小、文件类型和凭据模式，并检查两个历史源码 `.tar.gz` 的成员；包内均为源码。Bearer 命中来自测试替身；本轮日志中的 token 命中是生命周期测试的探测 UUID。未发现真实凭据。该模式扫描不构成对任意凭据格式的穷尽证明。按仓库规则未读取根目录 `TODO.md` 内容。

Capstone 子模块的 9 行接口改动以 `dependencies/capstone-overlays/arm64-detail.patch` 和摘要清单提交。gitlink 保持公开基线 `ea98aa0a31693d7ea2930c4372f9b5858b0bc7a3`。标准构建与 Swift 测试入口会应用补丁；直接使用 SwiftPM 前执行 `make prepare_vendor`。未知源修改会被拒绝，当前子模块保留已应用补丁的预期 dirty 状态，没有依赖仅存在本地的子模块提交。

## 验证与限制

- 本轮依赖准备验证：3 项 Python 测试通过，覆盖干净源码应用、重复执行、未知源修改保留和补丁摘要拒绝；`make prepare_vendor` 与 shell 语法检查通过。见 [日志](logs/capstone-overlay.log)。
- 本轮 ProMotion 复验：3 项 Swift 测试通过，包含五模式默认关闭、显式启用拒绝、旧 ID 意图保留及冲突检查。见 [日志](logs/promotion.log)。
- 整理前最终标准 Python：779 项通过、1 项跳过；最终相关 Swift：131 项、11 suites 通过。本轮新增的依赖准备测试单独执行，没有把其结果写成重跑后的完整 Python 套件结果。
- 全量 Swift 首轮仍为 1,502 项、234 suites、20 issues；定向复验 126 项、14 suites 后剩两项失败。`postValidationRecognizesIdempotenceWithoutEmitting` 与 `failedStopDoesNotInterruptLaunchpadChild` 均在适配前源码副本复现，原因未查明。未修改这些断言或删除失败日志，未将全量结果写为通过。详细证据见 [适配报告](../T08_T09_adaptation.md)。
- 本轮提交整理没有启动 VM、安装候选或重做固件验收。历史证据只支持其记录中的实验设置和版本。
- ProMotion 继续在 regular/dev/jb/exp/less 默认关闭，声明保持 `notImplemented`。
