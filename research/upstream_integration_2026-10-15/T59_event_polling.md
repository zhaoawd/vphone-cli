# T59 设备状态按订阅轮询（2026-10-15）

本轮完成 `device.state` 轮询的源码适配、可回归调度验证及独立 iOS Release 候选构建。T59 整项未验收：实际客户机 CPU、wakeups、首响应延迟、实例切换，以及相机、陀螺仪、音频和摘要缓存的其余范围仍待核对。

## 1. 来源与实施范围

固定目标仍为 `8a75092013eda87a4e30ed029b72028cb9279ac4`。来源提交为 `afc62ef0d783afd0c1dd0dca4e1cad1ad45917c0`，已读取仓库保存的 `evidence/git-audit/endpoint.diff` 中 `APIWire.swift` 与 `GuestEventPublisher.swift` 的完整差异段。本机没有历史审计仓库 `/private/tmp/vphone-8a75092-audit-repo-20261015.git`，也没有该固定目标 Git 对象；本轮没有重新获取对象，不新增完整 Git 对象核验结论。

原实现初始化后以 3 秒周期调度定时器，无订阅时虽然不查询设备状态，但定时器仍唤醒。现实现如下：

- `APIEventHub` 仅在首个订阅者加入和最后一个订阅者移除时通知，通知在锁外执行。重复加入、移除不存在的 channel 不产生额外边界通知。
- 发布器无订阅时将定时器设为 `distantFuture`。订阅恢复后立即调度，并继续使用原 3 秒周期。已排队的定时器回调仍检查当前订阅者，避免无订阅时查询设备状态。
- 每次处理通知时重新读取 Hub 当前状态，处理不同 channel 的回调乱序。
- 本地另补充快速重连处理：即使退订与重新订阅均先于队列执行，也清空旧订阅的状态摘要并立即调度。否则两次回调均读到“有订阅”，会保留旧摘要，导致新订阅者收不到内容未变的首次状态。
- 初始化时处理已存在的订阅者；发布器释放时取消定时器。`main.swift` 仍先建立 Hub 和发布器，再接受网络连接，通知闭包只在初始化时设置。

事件包络、状态字段和内容不变时不重复广播的行为保持。没有新增 kernel、DSC、Mach-O 指令补丁，没有改变相机 ABI 或 guest 端口。

## 2. 回归方法与证据

`tests/test_daemon_event_publisher.py` 直接编译生产 `APIEventHub` 与 `GuestEventPublisher`，仅替换平台查询、NIO 传输和调度器。Swift 6 编译后的可执行夹具检查调度结果、设备查询次数、广播内容与接收者，以及定时器释放；不依靠时间等待判定。该测试纳入 `make test_python` 的既有 discover 入口。

旧源码实际失败原文为 `idle publisher armed a repeating timer`。修改后覆盖无订阅、首次订阅、状态去重与变化、多订阅者、重复移除、队列中残留事件、重连、退订后立即重连、回调乱序、初始化前已有订阅以及对象释放。Hub 通知中同步读取 `hasSubscribers`，验证通知没有持有 Hub 锁。传输与调度替身不能代替实际 GCD/NIO 客户机验收。

另在临时源码副本中只去掉通知触发的摘要重置，实际失败为 `rapid reconnect reused the previous subscriber's snapshot`，验证快速重连断言能捕获该差异；生产源码未回退。

独立构建命令：

```sh
VPHONE_DAEMON_API_BUILD_DIR="$PWD/.build/daemon-api-t59-20261015" make daemon_api_build
```

构建通过；classic 与 v2 两类候选的 arm64、iOS 15.0 部署目标、动态依赖、entitlement、七项锁定 pin 和 JPEG overlay 校验通过。IcliKit 固定为 `0.8.5 / 815ef234df5461b8eb9455931d38cb1c37992fe6`。两类候选的 daemon SHA-256 均为 `6491858363777c1a2eb8a674f8e40237d788d08404ba9a46b04c715498b2d34d`；清单保留 `activated=false`、`runtime_validated=false`。

构建使用独立目录，没有覆盖 `.build/daemon-api-v2` 或历史冻结 V9。没有安装候选、启动 VM、修改系统 Store、AMFI 或 TCC。源码摘要、候选原始清单、命令和压缩日志见 [证据清单](evidence/T59-event-polling/manifest.json)。

## 3. 分支恢复与既有回归

当前仓库从干净的 `codex/handoff-20261001` 切换到用户指定分支。保留本地 `dd863325` 与已有远端引用 `76318ed1` 的两侧进展，以合并提交 `a9d07d70` 保存；未推送。两处冲突只涉及文档与测试尾部追加内容，两侧均保留。当前新上游计划来自远端已有提交，本轮未刷新远端引用。

合并定向测试 `CoreBundleStoreTests|LocalBundleLayoutTests|LauncherPolicyTests|LaunchRouteTests|ExpectedBindingCLITests|VMLaunchDiagnosticsTests` 在普通宿主权限下共 59 项通过。沙箱对照中 `setuid` 归档用例报签名拒绝，未命中预期的权限拒绝；普通宿主权限下通过。该差异仅说明两次执行结果不同，未确定沙箱如何影响权限位。

已有 `failedStopDoesNotInterruptLaunchpadChild` 在启动前失败，错误为 `Cannot inspect VM directory for committed origins`。代码核对确认夹具未创建 `sample` 目录，新增来源读取要求目录存在。只补齐夹具目录；原停止冲突、子进程存活、无 SIGINT、成功退出及输出排空断言不变。修正后相关 13 项通过，标准 Swift 中该用例也通过。

`make test_swift` 的常规 Swift Testing 共 1510 项，剩 1 issue：`postValidationRecognizesIdempotenceWithoutEmitting` 第一次调用实际产生 2 条记录，断言要求 1。此前 [T08/T09 适配记录](T08_T09_adaptation.md)已在适配前完整源码副本复现。本轮没有修改该内核补丁或断言；原因未查明。`run_tests.py` 因此退出 1，外层 `make` 退出 2；其后限时组、内存与 guest 组件检查另外执行，结果见证据清单；不能表述为标准 Swift 全通过。

限时组在普通宿主权限下 9 项通过；tar 管道和文件摘要内存检查、guest 组件检查通过。首次内存检查受默认模块缓存权限阻止；仓库内缓存重试时 tar 检查又被沙箱阻止宏插件启动，普通宿主权限下通过。一次未重定向的限时组沙箱补跑中，Core/API 两个目标失败，完整输出仅在会话工具结果中保留、未归档，原因未查明；未将它记为通过。

Python 首轮 785 项，1 项失败、2 项跳过。失败来自运行器新加的 `prepare_vendor.py` 步骤未同步到旧 5 步断言。对齐六个步骤后，新增的环境检查继续复现准备步骤未接收清理后的环境；将准备步骤移到环境构造后执行并显式传入同一环境，6 项运行器测试通过。没有删除或放宽原固件选择器隔离、限时组分离和失败退出码断言。两项跳过因默认目录仍含旧 IcliKit checkout，显式指定本轮 0.8.5 checkout 后两项通过；完整重跑结果见证据清单。

最终使用本轮 checkout 执行 `VPHONE_DAEMON_SOURCE_PACKAGES="$PWD/.build/daemon-api-t59-20261015/Xcode/SourcePackages" make test_python`：785 项全部通过，无跳过，199.101 秒。首轮失败和跳过日志保留。

## 4. 后续

T59 当前仅完成设备状态轮询部分，任务台账保持未验收。后续回到 U2 的 T15/T24/T37/T40/T52 共同边界与 T32/T33 的实现代际/可信 Undo；实际新 daemon 运行验收须绑定本轮候选，旧 B38 或冻结 V9 运行结果不证明本轮候选已通过。
