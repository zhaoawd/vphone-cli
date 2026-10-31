# 阶段 3 续验：iOS 27 Scene 生命周期与首批业务验收

2026-10-31，用户批准“生成兼容 iOS 27 的新构建并继续验收”后完成。**指定新 Build 的正式安装、独立标记回读和菜单／购物车 D04 两轮真实验收通过。** 两轮使用不同 Fixture nonce 和应用 PID，SpringBoard 身份保持一致；最终两台 VM 已停止。该结果覆盖本次选定流程，不表示 M12–M19 的全部组合通过。

原指定 Build 的 UIScene 启动崩溃与旧 procexp 内核 panic 记录保留，见 [首次阶段 3 执行记录](stage3_execution_2026-10-31.md)。原 IPA、Build Record、原产品仓库和阶段 1/2 精确 bundle 未覆盖。

## 最终身份

| 对象 | 结果 |
| --- | --- |
| App / Bundle ID | `food_ordering_v2` / `com.autophone.foodorderingdemo.v2` |
| 新 Build | `bld-e6ecfbb834f844e2dd566771c69a1d58190aa4f4babbac0debed79eaf7b44fff` |
| 标签 / 版本 | `food-coupons-ios27-scene-r9` / `1.0.0 (1)`，Version Slot `001` |
| IPA | 9,957,545 字节；SHA-256 `6279b1c468aed04b108c4e4fb9b705b4f8d76d9ddb1b6fa1377c3be7ff0d42e3` |
| Source Revision | `source_tree` / `generated`；基于 `f6a72613482ec50b639829d39884868828798e76` |
| 源码树 SHA-256 | `e679217cad747a9a2b95c694737ffee21138fd44b2197290d3ef789fd50923e4` |
| Build marker SHA-256 | `e7efa7d96be550826d4dce873bfd9da7e9c6191e6d17ad4f38a7b5d3fc9a3165` |
| 框架 / 架构 | Expo 53.0.34 模板、原依赖锁文件、JSC；`newArchEnabled=true` 保持 |
| 构建 | Xcode 27.1 / iPhoneOS 27.1 SDK，Release，clean build；未启用构建加速 |
| 最终 Rig | `migration-stage3-fresh`，generation 6；`isolation-peer`，独立 ECID/UDID |
| 目标配置 | `.build/am31/stage3-fresh/runtime/target-6.json` |
| 隔离 State | `.build/am31/stage3-fresh/state`；新 Build 在此包仓库登记 |
| VM 基线 | 复用阶段 2 新建的隔离 VM；iPhone17,3 iOS 27.0.1/24A446 + cloudOS 23E5207q，standard |
| 宿主 bundle | 复用已批准阶段 2 构建；VM CDHash `1259c91630fc141bc5a1687b5792f42694c1bc3f` 保持 |

证据：[导出来源](evidence/stage3-20261031/scene-export-r9.json)、[最终 IPA 核验](evidence/stage3-20261031/scene-ipa-verification-r9.json)、[构建原始回执](evidence/stage3-20261031/scene-build-receipt-raw-r9.json)、[正式构建回执](evidence/stage3-20261031/scene-final-release-build-receipt.json)、[登记结果](evidence/stage3-20261031/scene-package-add-r9.log)。构建使用缓存种子的摘要已记录，但 CocoaPods 解析未锁定，依赖可重放性仍为 `non-reproducible`，不宣称 IPA 字节级可重放。

## 实现

修改位于 `/Users/kolar/github/autophone/.claude/worktrees/autophone-upstream-migration`，分支 `feat/autophone-upstream-migration`，基线 `3bf50e8848b15cb5fe9848aa5087c85c8bd42c15`。

- `expo_scene_lifecycle.py` 导出 Expo 配置插件，并接入 `ui_verification_food_ordering.py` 的受控模板。插件声明单 Scene、移除 AppDelegate 中的旧窗口启动块，在 SceneDelegate 建立窗口关联后启动 React Native；转发激活、前后台、URL 和用户活动回调。未知 Swift 模板、非 Swift 模板和已有冲突 Scene manifest 拒绝自动改写。
- `export_scene_workspace` 生成独立源码树，拒绝覆盖输入或已有输出。原提交导出摘要为 `23500f23221dc16772ca48e1d695a8ec91a3000f9d1a594aef96e4c7a2a70f93`，与旧 IPA 记录一致。最终仅 `app.json` 与新增 `verification/withAutophoneSceneLifecycle.js` 不同；业务文件、原新架构开关及依赖锁文件保持。见 [最终源码对比](evidence/stage3-20261031/scene-final-source-comparison-r1.json)。
- `tools/phase1/upstream_app.py` 使用真实 ScreenLock，先执行正式 CLI 精确安装与 RigProvisioner 独立回读，再写入基线 Fixture、校验消费回执及稳定观测，最后调用现有 `run_dish_scenario(..., 'D04')`。每次 AX 读取核对前台、应用 PID 和 SpringBoard 身份；最终截图与失败观测均落盘。Control Plane 已配置时，该独立入口拒绝执行。
- Fixture 校验复用 `home_bag.receipt_matches` 和 `observed_home_baseline`：唯一 nonce、基线 mutation、epoch 0、两次相同快照及购物袋初值 2。Fixture 通过不替代独立 AX 业务断言。
- AX 适配器按 `UIAccessibilityTraitSelected` 解码选中态，捕获的标准份／大份响应保存为回归夹具。没有修改 D04 的标签、数量、价格或选择断言。

Scene 生命周期要求依据 [Apple 迁移文档](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle)；窗口与事件转发设计参考 [Expo Scene 实现](https://github.com/expo/expo/blob/sdk-57/packages/expo/ios/AppDelegates/ExpoAppSceneDelegate.swift)。本轮针对冻结的 Expo 53 模板实现适配，没有升级为 SDK 57。

## 真实验收

| 检查 | 第一轮 | 第二轮 |
| --- | --- | --- |
| 正式 CLI 安装精确 Build | 通过 | 复用同一已安装 Build，未重复安装 |
| RigProvisioner 版本及 marker 独立回读 | 通过 | 通过 |
| Fixture nonce | `8a9be403a9366c9a83fb9008981200d9` | `a974c18b99c948d55f551f4bb05037da` |
| 应用 PID | 915 | 953 |
| 前台身份与首页 | 通过 | 通过 |
| D04 菜品规格、加蛋、数量及购物车 | 通过 | 通过 |
| 商品小计 / 数量 | `¥82` / 2 | `¥82` / 2 |
| SpringBoard | PID 36，启动时间保持 | 与第一轮相同 |
| 最终结果 / ScreenLock | `accepted=true` / 释放 | `accepted=true` / 释放 |

D04 保留现有步骤：核对两份默认购物车，经 UI 清空；进入菜品规格，核对默认价格 `¥32`、数量 `1`、标准份选中和减号禁用；选择大份、加蛋、加到两份，核对 `¥82`；加入后核对首页购物袋，再进入购物车独立读取规格“大份 · 加蛋”、数量“2 份”和商品小计 `¥82`。本次没有提交订单或付款。

证据：[两轮汇总](evidence/stage3-20261031/scene-final-acceptance-r1.json)、[第一轮完整结果](evidence/stage3-20261031/scene-final-app-live-r1/result.json)、[第二轮完整结果](evidence/stage3-20261031/scene-final-app-live-r2/result.json)、[最终购物车截图](evidence/stage3-20261031/scene-final-app-live-r2/screen.jpg)。每轮目录还保存选择请求、应用生成的选择回执、产品观测、设备 marker 与逐步 AX 树。

再次执行时显式选择同一目标、State 与 Build：

```sh
cd /Users/kolar/github/autophone/.claude/worktrees/autophone-upstream-migration
/Users/kolar/github/autophone/.venv/bin/python -m tools.phase1.upstream_app \
  --target /Users/kolar/github/vphone-cli/.build/am31/stage3-fresh/runtime/target-6.json \
  --state-dir /Users/kolar/github/vphone-cli/.build/am31/stage3-fresh/state \
  --build-id bld-e6ecfbb834f844e2dd566771c69a1d58190aa4f4babbac0debed79eaf7b44fff \
  --output /absolute/new-evidence-directory
```

VM 当前已停止，需先经 RigLifecycle 正常启动。需要重装时显式加 `--install`；不指定时只核对当前精确安装并冷启动，不回退安装其他 Build。

## 失败记录与结论修正

1. 原指定 Build 使用 iOS 27.1 SDK，却未采用 UIScene 生命周期。两份原始崩溃报告指向 UIKit 的 `NoSceneLifecycleAdoption` 检查。该启动问题由新 Scene 构建解决，原 Build 保留。
2. 早期 Scene 候选出现空白页面。验收入口遗漏了该演示应用的基线选择文档；源码 `useEvalFixture` 在缺少文档时失败，首页直接返回 `null`。设备实际读取返回 `File could not be opened`。补齐原 Fixture 协议后，同一 r6 Build 可进入首页和菜品页。见 [缺失文档证据](evidence/stage3-20261031/scene-selection-before-r6.json)、[补齐前置后的运行](evidence/stage3-20261031/scene-fixture-app-live-r1/result.json)。此问题属于本轮验收入口遗漏，不能据早期结果认定 Scene 回调、架构、缓存或业务初始化失败。
3. 早期仅凭统一日志缺少记录推测 Scene 未连接，证据不足。应用自身阶段记录随后确认 AppDelegate、Scene 连接和 React Native 根视图创建均已执行；字体、认证和验证开关也均正常。相关诊断版本和读回保留：[阶段记录](evidence/stage3-20261031/scene-trace-readback-r5.txt)、[JS 状态](evidence/stage3-20261031/scene-js-state-r5.json)。最终版本已移除这些临时诊断代码。
4. 新架构／传统架构对照均曾因上述 Fixture 遗漏而失败。最终保留 `newArchEnabled=true` 的版本通过两轮 D04；没有证据支持必须关闭新架构。对照输入见 [源码单变量对比](evidence/stage3-20261031/scene-architecture-source-comparison-r1.json)。
5. 补齐 Fixture 后，实际选中的标准份曾被验收适配器误判为未选中，原因是使用了 image 位而非 selected 位。保存实际 AX 响应后修正解码，原业务断言不变；后续 r6 与最终 r9 的 D04 通过。
6. 对照 VM 一次显示 `Trust This Computer?`。根据实际截图选择 `Don't Trust` 关闭遮挡，未授予主机配对权限。见 [截图](evidence/stage3-20261031/scene-app-live-r4/screen.jpg)、[动作记录](evidence/stage3-20261031/dismiss-trust-fresh-r1.json)。该弹窗不能解释全部早期空白记录。
7. 首次对照目标 generation 5 被手工重新序列化，违反目标文件的逐字节不变约束，启动被拒绝。保留拒绝记录，后续由正式序列化创建 generation 6，未修改门禁。见 [拒绝复现](evidence/stage3-20261031/scene-fresh-target-rejection-r1.json)、[新目标启动记录](evidence/stage3-20261031/scene-fresh-start-r2.log)。

r1–r6 的构建与诊断运行均保留；r7 已构建但未安装，r8 只导出源码未构建；最终采用 r9。各次输入均有独立目录和源码摘要，未覆盖旧 Build Record。窗口顺序、事件转发等兼容实现由最终运行验证；不把早期空白页错误归因于这些未证实原因。

## 回归与收尾

最终相关回归：**844 passed，1 skipped，1 个既有 websockets 弃用警告，17.75 秒**；Ruff 通过。跳过项需要靶 A 的本地 `node_modules` 提供 tsc，本轮该测试路径不存在。测试覆盖安装、设备会话、标记身份、权限门禁、Scene 模板、构建管线、原生依赖投影、Fixture nonce／稳定快照及捕获的 AX 状态。完整日志：[final-regression-r1.log](evidence/stage3-20261031/final-regression-r1.log)、[final-ruff-r1.log](evidence/stage3-20261031/final-ruff-r1.log)。

```sh
python -m pytest -q tests/test_platform_packages.py tests/test_package_install_application.py \
  tests/test_device_session_channel.py tests/test_provisioning_observation.py tests/test_build_marker_identity.py \
  tests/test_stage_guard.py tests/test_upstream_wire.py tests/test_upstream_install.py tests/test_proc_regions.py \
  tests/test_springboard_residue_check.py tests/test_upstream_rig_lifecycle.py tests/test_upstream_vphone_lifecycle.py \
  tests/test_expo_scene_lifecycle.py tests/test_ui_verification_food_ordering.py \
  tests/test_ui_verification_eval_target_live.py tests/test_rn_native_projection.py tests/test_rn_ios_references.py \
  tests/test_rn_local_native_sources.py tests/test_upstream_app_acceptance.py \
  -m 'not live_device and not live_frida'
```

两轮结束后区域检查 `clean`，见 [最终残留检查](evidence/stage3-20261031/scene-final-residue-r1.json)。baseline 与 isolation-peer 均 `stopped`，磁盘无占用、启动锁和各自 State 下的 ScreenLock 释放、socket 不可达。原 IPA SHA-256、已批准 host bundle 的 VM 摘要及签名保持。见 [正常停止](evidence/stage3-20261031/scene-final-stop-r1.log)、[独立收尾](evidence/stage3-20261031/scene-independent-closeout-r1.json)。历史候选、诊断文件和 VM 保留。

源码累计补丁见 [autophone-stage3-scene-final-r1.patch](evidence/stage3-20261031/autophone-stage3-scene-final-r1.patch)，38 份变更文件的摘要见 [autophone-source-scene-final-r1.json](evidence/stage3-20261031/autophone-source-scene-final-r1.json)。在原基线文件及权限上执行 `git apply --check` 无警告通过，见 [补丁检查](evidence/stage3-20261031/patch-check-final-r2.json)。正式兼容观测的独立副本见 [已安装 Build 观测](evidence/stage3-20261031/scene-final-observed-state-r1.json)，不是手工构造的安装事实。

最终候选摘要与证据文件哈希见 [scene-candidate-final-r1.json](evidence/stage3-20261031/scene-candidate-final-r1.json)。

## 验证限制

- 通过范围为明确选择的新 Build 安装、身份和菜单／购物车 D04；没有执行正式需求交付出口闸或全部业务用例。
- Frida、定位、相机、QR 消费、旧 VM 升级、证书安装和 System 注册未在本轮真实验证。该流程通过 native AX 和 UDS 实现，不要求 Frida。
- Scene URL／用户活动转发已生成、回归检查并编译；没有执行真实深链、Handoff 或多 Scene 验收。
- 旧 procexp 引发的内核 panic 原因仍未查明。替代区域工具通过实际阳性对照和完整计数，不表示已修复内核。
- 修改保留在独立 autophone worktree；未合入、未发布，也未修改原产品仓库。
