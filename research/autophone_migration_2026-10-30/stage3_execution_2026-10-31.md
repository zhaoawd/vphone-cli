# 阶段 3 执行记录（2026-10-31，首次结果）

后续状态：用户批准独立新 Build 后，最终两轮安装身份／菜单购物车验收通过，见 [阶段 3 续验记录](stage3_scene_execution_2026-10-31.md)。以下保留首次执行时的失败结果与待办含义。

阶段 3 尚未通过。用户指定构建已完成正式 CLI 安装、注册验证和独立构建标记回读；应用在 iOS 27 启动时崩溃，菜单／购物车验收被阻塞。待用户选择是否适配构建流程并生成新的独立 build-id。原 IPA、Build Record 和失败证据保留。

## 范围与固定输入

| 对象 | 结果 |
| --- | --- |
| autophone worktree | `/Users/kolar/github/autophone/.claude/worktrees/autophone-upstream-migration`，`feat/autophone-upstream-migration`，基线 `3bf50e8848b15cb5fe9848aa5087c85c8bd42c15` |
| App / Build | `food_ordering_v2` / `bld-0eef57d16616da2938cf1d701b3ae6e3732f6552d8674a1dc3d6f9879fcba225`，`food-coupons-r1-clean` |
| IPA | 9,954,044 字节；SHA-256 `e0942c400684af47d5d8e67c79d996adae42e8a5f3024c36522d5b780cb0c642` |
| Source Revision | `git_commit` / `clean` / `f6a72613482ec50b639829d39884868828798e76` |
| Bundle ID / 版本 | `com.autophone.foodorderingdemo.v2` / `1.0.0 (1)` |
| Rig | `migration-stage3`，generation 4；`.build/am31/stage3/runtime/target-4.json` |
| VM / 固件 | `.build/am31/machines/baseline`；iPhone17,3 iOS 27.0.1/24A446 + cloudOS 26.4 beta/23E5207q，standard |
| 宿主 bundle | 复用阶段 2 精确批准构建；VM CDHash `1259c91630fc141bc5a1687b5792f42694c1bc3f`，未重建宿主程序 |
| 隔离状态 | `.build/am31/stage3/state`；CLI 读到该 Rig 的 Control Plane 配置为 missing，使用既有单 VM 兼容路径；未清除或绕过已配置控制面 |

输入与路由证据：[selected-build-r1.json](evidence/stage3-20261031/selected-build-r1.json)、[package-import-r1.log](evidence/stage3-20261031/package-import-r1.log)、[install-route-r1.json](evidence/stage3-20261031/install-route-r1.json)。隔离入库得到与原仓库相同的完整 build-id。

## 实现与结果

1. `upstream_wire` 增加逻辑 `ipa_install` 到原生 `apps.install` 映射。准入同时要求 host RPC、guest 连通和 guest `ipa_install` 能力；显式禁止或字段类型错误均拒绝。
2. `upstream_install.install_copy` 为调用者 IPA、证书创建唯一输入副本。原生安装器只消费副本；能力和写权限检查在暂存前执行。超时或未知完成状态不触发安装重放，不删除仍可能在使用的输入。
3. 包仓库和 `VPhoneDeviceSession` 的默认传输按显式协议选择 UDS `file_put`；legacy 保持原 SSH 路径。原生注册验证核对唯一注册项、Info.plist 内 Bundle ID，以及读前读后注册路径一致。
4. SpringBoard 残留检查保留原判据：任何 Tag 255 区域均拒绝安装。upstream 使用新的只读区域工具；要求阳性对照、完整结束标记、区域计数一致及查询前后相同 SpringBoard PID/启动时间。工具缺失或查询失败时拒绝安装。
5. `tools/phase1/upstream_app.py` 保存精确 Build 回读、前台身份、进程持续性和 D04 菜单／购物车断言。脚本使用实际 ScreenLock，Control Plane 已配置时拒绝独立执行。业务通过必须满足 UI 断言；launch acknowledgement 不作业务成功证据。

正式 CLI 安装命令通过，见 [package-install-r1.log](evidence/stage3-20261031/package-install-r1.log)：

```sh
python -m autophone.cli app package install food_ordering_v2 \
  --build-id bld-0eef57d16616da2938cf1d701b3ae6e3732f6552d8674a1dc3d6f9879fcba225
```

命令在 target-4 的环境、隔离 State 和 worktree 中运行。安装前 SpringBoard `clean`。独立 `RigProvisioner.ensure` 回读版本为 `1.0.0 (1)`，marker SHA-256 与 IPA 内预期字节相同：`13351cc72ddebe42696b2fefa6af9b6f3de7d9c3d9f1331924dc47f41e4c9a68`。它确认既有精确安装观测并未重复安装。见 [provisioning-readback-r3.json](evidence/stage3-20261031/provisioning-readback-r3.json) 和 [installed-build-marker-r3.json](evidence/stage3-20261031/installed-build-marker-r3.json)。

## 启动失败

两份原始 `.ips` 的主线程首帧均为 `___UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption_block_invoke`，异常为 `EXC_BREAKPOINT/SIGTRAP`。IPA 的 `DTSDKName=iphoneos27.1`，没有 `UIApplicationSceneManifest`。证据与 Apple 对 SDK 27 构建必须采用 Scene 生命周期的要求一致：[Apple 文档](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle)。据此，本轮应用启动失败归因于缺少 UIScene 生命周期支持。

- [第一次原始崩溃](evidence/stage3-20261031/FoodAIVerification-2026-10-31-125544.ips)
- [第二次原始崩溃](evidence/stage3-20261031/FoodAIVerification-2026-10-31-125623.ips)
- [IPA 字段与崩溃帧汇总](evidence/stage3-20261031/app-launch-analysis-r1.json)
- [现场进程、前台身份与日志目录](evidence/stage3-20261031/app-diagnosis-r1.json)

已保存入口的真实执行结果见 [app-live-r1/result.json](evidence/stage3-20261031/app-live-r1/result.json)：构建回读通过、启动请求返回成功；首页 `home.recommendation.title` 在截止时间内未出现，`accepted=false`，ScreenLock 已释放。D04 的菜品规格、金额与购物车断言未执行，不计为业务通过。源应用仓库 `/Users/kolar/github/food_ordering` 未修改，原构建未替换。

探索脚本 `app-probe-r1/r2` 曾因装配未注入 installer、环境在模块导入后设置而失败；这些记录保留。r3 在导入前设置隔离 State 后完成正式回读；r4 的有界 AX 等待仍失败，后续取回原始崩溃报告。环境错误未通过手工填写观测或安装回执处理。

## 区域工具兼容性

旧工具在新 VM 缺失，随后从已存在的 iosbinpack64 归档提取并暂存到 guest 数据目录。该旧 `procexp` 查询 SpringBoard 时触发 kernel panic，panicked task 为 `procexp`；日志含 `VM entry ... lock is invalid (0)` / `vm_entry_lock.c:168`。**内核原因未查明**，不重跑该组合，不声称修复了内核问题。

原始来源和失败记录：[procexp-source-r1.json](evidence/stage3-20261031/procexp-source-r1.json)、[procexp-failure-r1.json](evidence/stage3-20261031/procexp-failure-r1.json)、[vphone-panic-r1.log](evidence/stage3-20261031/vphone-panic-r1.log)。随后正常停止并重启同一 VM，未更换固件或宿主构建。

新 `tools/guest/proc_regions.c` 使用 `proc_pidinfo(PROC_PIDREGIONINFO)`，不获取目标 task port、不 attach。SDK ABI 固定为 96 字节，工具输出沿用原区域解析器和 Tag 255 判据。实际 guest 返回过 size=0、下一段 address 的间隙记录；继续查询精确下一起点后得到完整结果。捕获样例已写入 C 级回归，不能把间隙记录当作区域或干净结果。

最终工具 SHA-256 为 `c7dc2775f3fdc7dd4c492fbc3a6eb922f593e3a2fae17a531fe154ad6313a92a`，部署到 `/var/jb/usr/local/bin/autophone-proc-regions`。自身实际分配 Tag 255 的阳性对照被生产解析器检出；SpringBoard 查询完整且判为 clean。见 [libproc-validation-r5.json](evidence/stage3-20261031/libproc-validation-r5.json)、[阳性原始区域输出](evidence/stage3-20261031/libproc-positive-regions-r5.txt)。构建入口为 `zsh tools/guest/build_proc_regions.sh /absolute/output-binary`，本身不部署或修改 AMFI。

## 回归与收尾

最终相关 pytest：**333 passed，1 个既有 websockets DeprecationWarning**；Ruff 通过。选择范围为包安装、设备会话、Provisioning、Build marker、StageGuard、upstream wire、Rig lifecycle、SpringBoard 残留与真实 Darwin C 工具测试；排除 `live_device/live_frida`。命令与完整结果见 [regression-r2.log](evidence/stage3-20261031/regression-r2.log)、[ruff-r1.log](evidence/stage3-20261031/ruff-r1.log)。其中新增安装／工具相关小组最终 49 项通过。

```sh
python -m pytest -q tests/test_platform_packages.py tests/test_package_install_application.py \
  tests/test_device_session_channel.py tests/test_provisioning_observation.py \
  tests/test_build_marker_identity.py tests/test_stage_guard.py tests/test_upstream_wire.py \
  tests/test_upstream_install.py tests/test_proc_regions.py tests/test_springboard_residue_check.py \
  tests/test_upstream_rig_lifecycle.py tests/test_upstream_vphone_lifecycle.py \
  -m 'not live_device and not live_frida'
```

baseline 已正常停止，peer 保持停止。独立收尾确认两台 VM 均 `stopped`、磁盘无占用、启动锁和 ScreenLock 释放、socket 不可达。批准 host bundle 的签名和 VM SHA-256、原始 IPA 摘要保持。见 [stop-r1.log](evidence/stage3-20261031/stop-r1.log)、[independent-closeout-r1.json](evidence/stage3-20261031/independent-closeout-r1.json)。两台 VM 和已安装 App 保留；未合入、未发布。

源码累计补丁与摘要见 [autophone-stage3-r1.patch](evidence/stage3-20261031/autophone-stage3-r1.patch)、[autophone-source-r1.json](evidence/stage3-20261031/autophone-source-r1.json)。本轮 54 份证据的大小和 SHA-256 已逐项读回核对，清单见 [candidate-r1.json](evidence/stage3-20261031/candidate-r1.json)，其中整体 `accepted=false`。

## 待办与验证限制

- 待用户选择是否生成兼容 iOS 27 的新构建。变更必须得到新的 Source Revision、IPA SHA-256 和 build-id；不覆盖本轮指定输入。
- 菜单／购物车 D04 仍未通过。已保存断言保持原值；新构建就绪后重新执行，不以安装通过替代业务消费证据。
- 本轮没有验证 Frida、定位、相机、QR 消费、证书签名安装、System 注册、旧 VM 升级或完整 M12–M19 组合；证书和注册参数映射只有隔离回归证据。
