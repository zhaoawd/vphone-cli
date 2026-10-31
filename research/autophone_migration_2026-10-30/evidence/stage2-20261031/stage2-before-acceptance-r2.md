# autophone 迁移阶段 2 执行记录

日期：2026-10-31。状态：**实施与验证中，未验收**。

## 范围与工作区

- autophone：沿用 `/Users/kolar/github/autophone/.claude/worktrees/autophone-upstream-migration`，分支 `feat/autophone-upstream-migration`，基线 `3bf50e884`。主工作区未覆盖。
- 上游扩展：`.build/autophone-stage2/upstream`，分支 `codex/autophone-stage2`，固定基线 `39324ee7fcbb1d909bfa293f6188a8ef752ba734`。阶段 1 纯上游源码、构建与证据保留。
- 新候选：`.build/autophone-stage2/DerivedData/Build/Products/Debug/VPhone.bundle`；完整构建和签名检查通过；`vphone-vm` CDHash `1259c91630fc141bc5a1687b5792f42694c1bc3f`。
- 当前候选源码差异为 [upstream-stage2-r2.patch](upstream-stage2-r2.patch)；精确构建摘要为 [candidate-r2.json](evidence/stage2-20261031/candidate-r2.json)，autophone 工作树摘要为 [autophone-source-r2.json](evidence/stage2-20261031/autophone-source-r2.json)。原 `upstream-stage2.patch` 和 `candidate.json` 保留历史含义。

## 已实现范围

autophone 新增显式 `legacy` / `upstream_v1` 协议绑定，Rig 配置记录 `protocol` 和 `core_bundle`；legacy 为默认值。ContextVar 绑定与显式参数发生冲突、跨 socket 复用绑定或未知协议时拒绝。目标配置以代次文件保存，已存在同代次的不同配置拒绝覆写。

统一传输层在逻辑命令完成 StageGuard 和写栅栏检查后才进行 wire 映射。应用命令映射至 `apps.*` RPC，展开 result 并映射 data_path；文件命令映射至 push/pull，支持内联数据和宿主路径及 octal 权限。截图请求显式禁止默认落盘。Shell 映射至独立 `shell.exec`，不使用同名交互终端。所有写操作失败均不切换协议重发。

upstream_v1 操作在执行前读取宿主能力声明；缺少正确协议或命令能力时拒绝。响应分帧、大小和绝对截止时间有界；校验 peer UID；发送后的写请求超时保留 `operation_may_continue`。健康探针区分宿主回答与 guest 就绪；宿主已回答后的 guest 超时保持 host_only。新 Rig 启停与健康守护接入显式 bundle 和目标，跳过旧 AMFI/SSH/guest 修复脚本，停止委托上游 SIGINT 路径。健康守护启动失败或发生异常时，仅停止本次新建 VM，已有 VM 不受该清理路径影响；停止失败保留在错误结果中。

调用方 `CaseContext.launch_app` 的 upstream_v1 路径在原启动失败后，不自动调用 `uiopen` 或点击 SpringBoard 图标再次启动。legacy 路径保留原行为。该修改补充了传输层之外的写操作重发限制。

上游扩展提供能力声明、截图 `save:false`、同 UID 连接准入、0600 socket、单次请求处理并发上限 64、有界分帧和绝对读写截止时间。原有交互 Shell 在转交 relay 后释放该并发名额，不以此上限声明其总连接数。单次 Shell 使用原生 posix_spawn、独立进程组、stdin EOF、每流 64 KiB 输出上限、退出码和截断标志。超时、UDS 断连及 guest HTTP 断连均接入取消；进程组信号在 leader 回收前发出，避免对复用 PID 发迟到信号。正常命令退出不将显式分离且已关闭管道的后台任务自动终止。

guest Shell 参数拒绝非字符串 cwd、布尔或非整数 timeout；完成请求及早到取消分别保留有界记录，正常请求结束后的迟到取消不再占用早到取消记录。

## 当前验证

- autophone 相关隔离回归：445 passed，13.89 秒，1 项 websockets 弃用警告；Ruff 通过。包含 legacy、StageGuard、应用/文件映射、协议绑定、分片 UTF-8、半包、超限、写超时不重放、健康三态、Rig 启停、目标配置代次和应用动作。执行命令及日志见下节。
- 将实际 guest C 源码编译为宿主动态库运行：10 项通过，覆盖 stdout/stderr、退出码、cwd、父进程、超时和取消的进程组清理、早到取消、持续输出、并发和最坏 JSON 转义后小于 1 MiB。该结果不替代 guest 内验证。
- 实际 Swift Shell 控制器与 C 模块组合：11 项通过，包括参数校验、请求标识复用拒绝、完成请求迟到取消与早到取消隔离。
- 实际宿主 I/O 模块的 socketpair 回归：6 项通过，覆盖 UTF-8 分片、半包拒绝、请求及响应超限、读超时和慢读者的写截止时间。
- 启动失败清理回归先复现 4 项失败，修复后相关 19 项通过；应用启动重发回归先复现 3 项失败，修复后应用动作相关 26 项通过。原失败日志保留。
- 完整 Xcode 构建 `build-r4.log` 退出 0，包含宿主、iOS/tvOS guest 与 bundle 验证；`codesign --verify --deep --strict` 通过。r4 的宿主二进制 SHA-256 与原候选相同，CDHash 保持 `1259c91630fc141bc5a1687b5792f42694c1bc3f`。
- 新候选先前 `host preflight` 退出 1：`AMFI blocked vphone-vm`。用户随后明确批准上述精确构建加入 allowlist，批准记录为 `allowlist-authorization.json`；原生管理员认证请求 session `58769`、osascript PID `78913` 已发起，当前仍待系统认证，日志尚无执行结果。未重复发起，未将阶段 1 的批准用于本构建。

## 回归入口与证据

在 autophone worktree 执行以下命令；Python 使用 `/Users/kolar/github/autophone/.venv/bin/python`。

```sh
python -m pytest -q tests/test_upstream_wire.py tests/test_upstream_rig_lifecycle.py tests/test_rig_lifecycle.py tests/test_start_vphone_script.py tests/test_device_execution.py tests/test_lock_state_helper.py tests/test_vphone_target.py tests/test_device_session_channel.py tests/test_vphone_capabilities.py tests/test_device_runtime_observation.py tests/test_stage_guard.py tests/test_upstream_vphone_lifecycle.py tests/test_transfer_atomicity.py tests/test_vsock_health_client.py tests/test_actions_launch_app.py tests/test_platform_launch_blocker.py tests/test_actions_press_key.py -m 'not live_device and not live_frida'
```

结果为 [autophone-regression-r2.log](evidence/stage2-20261031/autophone-regression-r2.log)。原生与 Swift 验证日志为 `native-shell-tests-r2.log`、`swift-shell-controller-tests.log` 和 `host-io-tests-r2.log`；构建日志为 `build-r4.log`。这些检查未启动真实设备，不证明 guest 实际执行行为。

真实验收脚本已保存为 autophone worktree 的 `tools/phase1/upstream_compat.py`，须显式提供 `--target` 与独立 `--output`。本轮目标配置为 `/Users/kolar/github/vphone-cli/.build/am31/stage2/runtime/target-2.json`，脚本尚未执行。当前 VM 已停止，尚未部署阶段 2 guest。工具环境就绪后仍需验证实际粘贴输入、断连重连和运行身份漂移，不能仅凭已保存脚本判定覆盖完整。

## 工具环境与运行限制

阶段 1 新 VM 的只读调查确认 `/bin` 没有 sh，`/var/jb` 和 `/var/jb/tmp` 不存在。原 guest 的 agent.health 只作为 HTTP 路由实现，不支持同名 RPC；新候选补充该 RPC。新 shell 能力仅在可执行 POSIX shell 存在时声明，不能将交互 shell/JavaScript 能力当作单次 POSIX Shell。

已取得上游安装器指定的 rootless Irisin `5.1.4` 发布包并校验 SHA-256 `0914c598a039a18e09677a280d25243965ee7aa274faef8339c25513a8d4e009`。包内容已列出；它提供 Irisin 应用和安装服务，未发现 POSIX shell 本体。尚未安装该包或执行其 bootstrap 安装流程；工具来源和安装步骤仍在核对，不能声称 `/var/jb/tmp`、sha256sum 或 guest Shell 已可用。

## 待完成

1. 完成现有 macOS 管理员认证，核对 allowlist 命令结果后执行预检与新 guest 部署。精确构建已获批准，无需重复征求批准。
2. 完成工具环境准备，验证 guest 内 Shell 的五项边界、辅助程序目录及 755 执行。
3. 在测试 VM 上运行保存的基础兼容验收：身份、健康、截图/几何、输入/剪贴板、应用查询启停、文件与失败路径，以及停止收尾。
4. 完成跨入口磁盘排他性、断连重连和运行身份漂移的剩余验证。未通过前不标记阶段 2 完成。

没有修改内核补丁算法或 preset，尚未对阶段 1 VM 应用新 CFW。未合入、发布或删除历史数据。
