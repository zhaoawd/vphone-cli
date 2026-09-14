# 前三项离线交付记录

日期：2026-09-14。基线提交：`70159917c200ad089205b6013ea442b18be60911`，验证对象包含工作区未提交修改。未提交或发布修改。

## 修改分组

| 范围 | 评审入口 | 状态 |
| --- | --- | --- |
| D1/D2 构建与依赖 | `scripts/build.sh`、资源解析及 bundle 检查、依赖锁；见 `d1_d2_build_dependencies_2026-09-14.md` | 保留已有修改，在隔离副本复验；远端工作流未运行 |
| D3 共用安装步骤 | `scripts/lib/cfw_common.sh`、四个 CFW 安装脚本、缓存测试；见 `d3_shared_cfw_2026-09-14.md` | 离线验证通过；真实安装待验收 |
| E6 相机回执 | 宿主相机命令、相机服务、帧生产者，vphoned/消费端及对应测试 | 增加呈现标识和停止策略；见 `camera_receipt_e6_2026-09-14.md` |
| C5/D4/F4 准备 | `c5_d4_fields_and_tests_2026-09-14.md`、根目录 `CONTEXT.md`、项目进度清单 | 字段与测试方案已准备；未实现 C5/D4 生产功能 |

## 验证结果

- Python：113 项通过。
- Swift Testing：333 项、53 个 suite 通过。XCTest：138 项、3 项跳过、0 失败。
- 隔离副本 `make build` 通过；签名、entitlements、完整资源检查通过。
- 签名应用的 `resources` 命令在仓库外和符号链接入口执行均通过。
- 新版消费端单独交叉编译通过；保留 packed atomic alignment 编译警告，未部署。
- `git diff --check` 通过。

隔离副本及应用：`.build/offline-next/source/` 和其下 `.build/vphone-cli.app`。该应用用于本轮离线验证；新版消费端另存其下 `.build/libvcamcaptured.dylib`。仓库预编译消费端未更新，因此不能把现有预编译文件视为支持 v3 回执。

日志位于 `.build/offline-next/`：`python-tests.log`、`swift-tests.log`、`build.log`、`consumer-build.log`。`snapshot.json` 记录构建输入与受保护文件哈希，`protected-check.json` 记录复核结果。

共享默认应用可执行文件、`.build/vphoned.signed`、`scripts/vphoned/vphoned`、`VPhoneBuildInfo.swift` 和仓库预编译消费端的哈希均未改变。源码修改对共享工作区可见，但本轮未启动、停止、查询控制 socket、安装或挂载现有 VM。

## 后续前置条件

C5/D4 可以继续离线实现记录模型、阶段执行器和故障测试。完整验收仍等待 C4，D4 还依赖 D3 完成。D3 真实安装、E5 定位和 E6 实际相机验收需协调 VM 时段；E6 还需部署配套宿主、vphoned 和消费端，并分别记录共享内存复制、应用显示和 QR 识别结果。
