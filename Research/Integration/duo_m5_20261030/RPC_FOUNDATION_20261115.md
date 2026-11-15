# RPC 基础集成，2026-11-15

本轮五项完成：方法类型与完整目录、声明驱动准入／派发、Duo 适配、目录／生产者漂移回归、完整 Bundle 与隔离副本验收。起点为 `2be9ff8d`，没有推送或发布。两份测试副本均已恢复原 daemon 和标记，经冷启动核对后正常关机；原验收副本本轮未启动，宿主准入未变。

## 来源与范围

| 来源 | 改动提交 | 本轮内容 |
| --- | --- | --- |
| #841 | `9f3974e2` | 方法枚举、共享派发、force 准入、目录 |
| #857 | `29fca910` | 结果声明和生产者漂移工具 |
| #884 | `46247e4a` | 方法／参数说明和约束元数据 |
| #892 | `3c98cd88` | 独立声明文件、实际类型、nullable 和编译生成目录 |

三方合并保留了当前 Duo 的 handler 实现。本轮没有引入 #908 的改名／单位迁移、#914 的错误码／未知参数拒绝、#915 的分页／输出暂存和 #916 的 observe。旧方法名与秒参数继续工作。

## 五项结果

| 项目 | 结果 |
| --- | --- |
| 类型与目录 | 195 个当前可路由方法由独立 `GuestAPI*Methods.swift` 声明，`methods.list` 返回 `scope:"guest", complete:true`；旧 `methods_list` 能力与新 `methods` 能力并存 |
| 准入和派发 | 同一声明负责派发、已声明参数过滤和 force；具体值仍由 handler 验证，类型／required／范围元数据不充当全局验证 |
| Duo 适配 | 保留活动点坐标、原生 AX ABI／display ID／PID／前台／几何复核、严格 Auto-Lock `never:true` 和 render-server 生命周期；原生 AX 的 PID 字段纳入类型声明与实际回复比较 |
| 回归 | 195 项名称检查、36 项目录自测、130 项提取器、正式 release 漂移、109 项 Swift HTTP fixture、runner 0 失败；现有 AX、Auto-Lock、点坐标和 session／HomePod ABI 回归通过 |
| Bundle／VM | 完整 Bundle、admission、深度严格签名通过；最终 VM 的 212 项目录／接口检查、15 个实际回复的 schema 检查、AX 15/15、锁屏拒绝和 respring 后来源恢复通过 |

目录覆盖当前实际 handler，未声明没有集成的 `location.services`、visionOS 方法或截图裁剪／缩放参数。既有 `GuestDuoMethod` 局部视图仍供回归使用；公开 RPC 目录以完整类型表为准。结果声明只覆盖顶层字段。

## Duo 生产者核对

- `display.auto_lock.set` 将 `seconds` 保持可选，并保留 `never`。新增回归先经过真实声明和准入，再进入生产 setter。原上游声明会过滤 `never` 并失败（`auto-lock-before.log`）；适配后 84 项通过。
- 生产者映射增加 `display.layout`、`display.metrics` 和 `display.capture_active`。`input.touch` 映射到实际 `RawInput.touch` 和 `edgeTouchResult` 两类返回构造函数，点坐标包装逻辑另由真实 handler 回归覆盖。
- 最初的 `ui.element_at` 映射只引用 icli，未覆盖 Duo 原生分支。实际 VM 的成功回复含 `pid`，而声明未包含该键。`native-result-before.log` 复现 `ui.element_at: undeclared result pid`，`drift-native-before.log` 记录原生生产者新增 integer 键。
- 映射现同时引用 icli 备用路径与 `vp_ax_display_hit_for_functions`；`ui.tap_element` 引用本地 `tapInterfaceElement` 返回构造路径。`pid` 声明为 optional integer，因为备用路径不保证该键。最终 15 个原生命中回复均逐键检查声明、必需性、nullable 和类型。
- 当前截图 handler 的参数与字段按实际实现声明；没有只为满足上游 catalog 而引入截图变换功能。UI 树的 `count` 可选性和 error 字段也根据实际路径调整。
- HomePod catalog 只提取为同内容的返回 helper；脚本 session 的正常回复增加 `crashed:false`，worker 原有字段继续存在。

工具固定使用 `swift-syntax 604.0.0`，位于开发测试包 `VPhoneDaemon/Tests/ResultSchema`，不进入运行时 Bundle。runner 校验 owning daemon 项目的 icli pin，测试用户目录采用专用变量，不改变系统 HOME。移植的 HTTP 测试助手已改为 Swift；当前测试源码不包含解释器调用。

## 静态与组件证据

证据根目录为 `.build/rpc-foundation-20261115/`。

| 检查 | 结果 | 日志 |
| --- | --- | --- |
| 方法目录与编译生成结果 | 195 names，0 failures | `methods-native-final.log` |
| 目录自测 | 36 个故意变更被检测 | `methods-self-test.log` |
| Swift／原生提取器和真实映射 | 130 tests，0 failures；设置 RS_ICLI 核对实际函数 | `schema-tests-native-final.log` |
| 正式 release 漂移 runner | exit 0，无漂移或未解析项 | `drift-release-native-final.log` |
| HTTP 比较脚本 fixture | Swift server，109 passed，0 failed | `live-stub-swift.log` |
| 路径／pin／CI runner | 0 failed | `schema-runner-user-directory.log` |
| 离线逻辑 | 479 checks，0 failures | `logic-final.log` |
| AX API／原生／几何 | API 240、几何 31；原生 display/context/ABI 通过 | `element-native-final.log` |
| Auto-Lock | 84 checks，0 failures | `auto-lock-first.log` |
| 活动点坐标与锁屏等待 | 通过，原断言保留 | `point-first.log` |
| 显示度量 | 通过 | `metrics-native-final.log` |
| Session | 34 checks，0 failures | `session-tests.log` |
| HomePod bridge | 29 donor ABI、参数／回复／拒绝／超时通过；Mac fixture | `homepod-debug-tests.log` |
| 完整 Bundle／admission | BUILD SUCCEEDED | `build-native-final.log` |
| 深度严格签名 | valid on disk，satisfies Designated Requirement | `signature-native-final.log` |

完整 Bundle 为 `.build/duo-sync-20261113/XcodeBundle/Build/Products/Debug/VPhone.bundle`。最终 daemon 冻结到 `.build/rpc-foundation-20261115/candidate-final/vphoned`，SHA-256 为 `c1d3207755de0164b400761394f26cf254f21eda962832877df08ddef82bb7e9`。

CI 新增目录、目录自测、Swift HTTP fixture、runner、带 RS_ICLI 的提取器测试和正式漂移入口；不依赖研究预检中的上游 Git 对象。本轮完成本地调用验证，未触发远端工作流。

## 实际 VM 与回滚

实际运行使用既有已准入的基线 `vphone-vm`，宿主 daemon 自动更新禁用，guest 库保持原版本。新构建的宿主 VM 程序没有另行准入运行。

最终验收使用 `duo-rpc-foundation-identity-20261115`，从已停机的 `duo-rpc-accept-205443` 保留身份克隆。源副本保持停机；保留身份拷贝不得与源副本同时运行。本轮未选择 Trust，最终验收沿用既有身份且没有出现配对提示。

| 阶段 | 证据目录后缀 | launchd start_time | 结果 |
| --- | --- | --- | --- |
| 最终候选安装 | `identity-worker-install.XTYrWPKl` | `1794703749.054779` | 固定 c1d320… 候选更新并确认，无 pending |
| 冷启动与回归 | `identity-worker-cold.gzvgVOl9` | `1794703929.01515` | 195 方法、212 目录／接口检查、15 个回复 schema、AX 15/15、锁屏拒绝；respring 响应保留，worker 119→491，原生捕获恢复 |
| 最终回滚 | `identity-worker-rollback.Cwj3KXyU` | `1794704074.014462` | 原 daemon 与原标记恢复 |
| 回滚后冷启动 | `identity-worker-restored.1KsrVCiN` | `1794704217.054765` | 原 daemon、标记、21 项库和根只读核对通过 |

四阶段均核对 21 项库不变、根只读、正常关机及无状态文件句柄。原 daemon SHA-256 为 `446925b66b983e6395bc2c6715885f1eae1d1836cee014a3df136f468540419b`。Auto-Lock 实测从 120 秒切到 Never、1800 秒，再恢复 120 秒；pose readback 的 hinge、orientation、device_orientation、tabletop 与回归前相同。

新身份诊断副本 `duo-rpc-foundation-20261115` 也已恢复原 daemon／标记；`worker-restored.4RVnKg06` 的第二次冷启动核对通过，正常关机。最终 `lsof` 同时检查原副本和两份拷贝的 Disk.img、nvram.bin、SEPStorage，输出 `final-open-handles.txt` 为空。

## 中间失败与验证限制

- `worker-cold.lg3qOTnp` 的测试误将原本无 force 门的 files.remove 当作 force 方法。对照原实现和当前声明后改用实际 always-force 的 apps.uninstall，并保留拒绝断言。
- `worker-cold.l7Gnp6sH`、`worker-cold.eknuunSm` 未进入 AX 命中测量；后者 20 次准备采样始终是新身份的 Trust This Computer 对话框，只有两枚可点击按钮。加入准备状态记录和有界就绪等待，15 点命中与锁屏拒绝断言未放宽。
- `worker-cold.XSoXdHK4` 精确匹配系统 ID 后选择 Don't Trust，返回 `tapped:true`，提示仍存在，原因未查明。当前点击方法体未因目录迁移改变；该提示的点击效果没有通过验收，单独跟踪。诊断副本已回滚并关闭。
- 中间候选 `2e894686…` 曾完成命中／来源恢复，但其声明缺少原生 PID；不作为最终 schema 验收。最终 c1d320… 候选重新执行全部回归并逐条比较真实回复。
- 195 项方法的静态声明和生产者均检查通过，不表示所有写操作都在 VM 执行。未验收其他设备、WDA、USB/DFU 恢复或新宿主可执行文件；也未包含下一组契约迁移。

## 保存入口

```zsh
zsh VPhoneDaemon/Tests/run-methods-tests.sh
zsh VPhoneDaemon/Tests/run-methods-tests.sh --self-test
RS_ICLI="$PWD/.build/XcodeDaemon/SourcePackages/checkouts/icli" \
  zsh VPhoneDaemon/Tests/run-result-schema-tests.sh --jobs 4
zsh VPhoneDaemon/Tests/run-result-schema-check.sh \
  --icli "$PWD/.build/XcodeDaemon/SourcePackages/checkouts/icli"
```

研究目录 `Regression/rpc-foundation-identity-runtime.zsh` 接受 install、cold、rollback、restored，固定最终候选和保留身份拷贝；每轮正常关机。`rpc-foundation-runtime.zsh` 保留新身份诊断副本及中间候选的固定范围，用于其恢复与证据核对。两组原标记快照独立保存，重复安装不覆盖初始快照。`rpc-foundation-live.mjs` 调用现有 AX／生命周期资产并检查实际返回 schema。大体积候选和证据只保存在 `.build`。

本地源码／既有回归适配提交为 `49612b23`，目录与漂移工具提交为 `a75a260a`；工作流、运行入口和本记录另行保存。未推送或发布。
