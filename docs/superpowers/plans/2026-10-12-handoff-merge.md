# Handoff 分支合并实施计划

> **For agentic workers:** 使用 superpowers:executing-plans 在本会话执行。用户已批准本轮合并与验证，不重复请求计划批准。

**Goal:** 将 `959acfc0` 的 handoff 历史及适用实现合入以 `2c119ae6` 为起点的开发线。

**Architecture:** 保留最新 classic 控制/相机与独立现代 API 的默认组合。接入显式 regular-v2 安装、检查点及 root-remount 实验；保留冻结计划、版本输入、事务和连接生命周期约束。

**Tech Stack:** SwiftPM / Swift 6、Python 项目 .venv、zsh。

**Spec:** 本会话批准的四步合并顺序；`research/upstream_handoff_2026-10-01.md`、`research/v2_guest_environment_design_2026-10-01.md`、`research/upstream_integration_2026-10-06/evidence/B38/T08/REPORT.md`。

## Global Constraints

- 不读取或修改根目录 TODO.md；不操作用户 VM 或宿主安全设置。
- IcliKit 固定 0.7.16，保留 API_ONLY 隔离和 classic 1337/1338；现代 API 为 1339。
- root-remount 仅显式 regular-v2；默认关闭。合并不构成实验真实 VM 验收。
- 新固件路径同时保留 plan/versionInputs 事务绑定，更新补丁比较记录。
- 先在本聊天独立工作树完成合并、验证和审查，再将干净目标分支快进至合并结果；不推送远端。

## Review Focus

- 默认 classic/API 安装与显式 v2 安装的 daemon plist、相机配置和缓存标记必须一致。
- API_ONLY 不启动相机或恢复 bootstrap；显式 v2 保持相机关闭，不影响默认 classic 路径。
- 冻结 plan/versionInputs 不因新增实验选项而丢失；版本未知及组合声明约束保持。
- 旧检查点字段省略保持摘要兼容；续跑不静默改变 guest environment 或实验选择。
- stdout JSON 与失败输出隔离、克隆历史排除保留最新覆盖，不重复较弱测试。

## Task 1: 固定基线与合并

**Files:** 本次新工作树与 Git 合并状态。

- [x] 核对两端 SHA、隔离状态、.venv/依赖及基线测试；日志写入 research/artifacts/handoff-merge-2026-10-12/。
- [x] 使用 `git merge --no-ff --no-commit 959acfc0` 保留合并历史。

## Task 2: 解决冲突与组合兼容

**Files:** 12 个冲突文件、`scripts/check_guest_api.py`、API 构建/安装入口及相关 tests。

**Interfaces:** `VariantPlanResolver.resolve` 保留 cloudOSVersionKnown 并接入 guestEnvironmentV2；`FirmwareTransaction` 保留 plan/versionInputs；API cache path/marker/proxy 一致。

- [x] 保留两侧有用研究记录；源码冲突按上述接口合并，重复修复保留新分支版本。
- [x] 先运行 handoff 的原有入口/事务/安装测试及最新 API 组合测试；新增问题写回归并记录失败，再修复。
- [x] 核对 v2 daemon plist、默认组合校验与两套缓存更新标记，运行相关 Python/Swift 回归。

## Task 3: 完整验证与收尾

**Files:** `research/handoff_merge_2026-10-12.md`、`research/0_binary_patch_comparison.md`。

- [x] 运行 `make test_python`、`make test_swift`；夹具完整时运行 `make test_firmware`，否则记录缺失。
- [x] 检查签名构建所需依赖并在本工作树执行可用构建；记录环境限制，不扩大 VM 验收范围。
- [x] 独立审查合并差异，修复本次引入的问题，复跑受影响验证。
- [x] 写入决策、命令、结果、未验证行为；提交双亲合并提交。
- [x] 在目标工作树仍干净且 HEAD 未被其他操作改变时快进目标分支；保留当前主工作区未跟踪文件，不推送。
