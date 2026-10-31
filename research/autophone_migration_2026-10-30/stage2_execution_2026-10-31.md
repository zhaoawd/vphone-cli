# autophone 迁移阶段 2 执行记录

日期：2026-10-31。状态：**基础兼容验收通过**。阶段 3 尚未开始。

## 工作区与构建身份

| 对象 | 结果 |
| --- | --- |
| autophone worktree | `/Users/kolar/github/autophone/.claude/worktrees/autophone-upstream-migration`，分支 `feat/autophone-upstream-migration`，基线 `3bf50e8848b15cb5fe9848aa5087c85c8bd42c15` |
| 上游扩展 | `.build/autophone-stage2/upstream`，分支 `codex/autophone-stage2`，基线 `39324ee7fcbb1d909bfa293f6188a8ef752ba734` |
| bundle | `.build/autophone-stage2/DerivedData/Build/Products/Debug/VPhone.bundle`，完整构建 `build-r4.log` 退出 0，deep/strict 签名验证通过 |
| 已批准宿主 | `vphone-vm` CDHash `1259c91630fc141bc5a1687b5792f42694c1bc3f`，SHA-256 `0f86660fa63f85614fdb5bb81cbf76d4193d7b4fc3a3e4c82fd7b48e3eac8a88` |
| 实际 guest | SHA-256 `73df3c1625d736be80b183d0270d735ebe82c9dc00e120df43915be7a625269b`；运行身份观测与 bundle 内文件一致 |
| 主测试 VM | `.build/am31/machines/baseline`，iPhone17,3 / iOS 27.0.1，standard；预测 UDID `0000FE01-2119AAF5C1E70D2F` |
| 第二测试 VM | `.build/am31/machines/isolation-peer`，上游 `vm clone --new-identity` 创建，独立 machine identifier/MAC；预测 UDID `0000FE01-32F7B33D02134DC5`，headless |

阶段 1 的纯上游源码与构建保留，源码仍干净。autophone 主工作区未覆盖。上游扩展未改变内核补丁算法或 preset，未重新执行 CFW 安装。

上游源码补丁为 [upstream-stage2-r2.patch](upstream-stage2-r2.patch)。autophone 相对基线的阶段 1/2 累计补丁为 `autophone-stage2-r3.patch`。最终摘要为 `evidence/stage2-20261031/candidate-r4.json`、`autophone-source-r3.json`。较早的 patch、candidate 和源码清单均保留。

## 实现结果

autophone 增加显式 `legacy` / `upstream_v1` 协议与 `core_bundle` 绑定，默认保持 legacy。ContextVar 与显式协议冲突、跨 socket 使用绑定、未知协议和同代次目标配置变化均拒绝。Rig 路径和环境由冻结的目标配置生成。

统一传输层在逻辑命令完成 StageGuard/写栅栏检查后执行 wire 映射：应用使用 `apps.*`，展平 `result` 并映射 `data_path`；文件使用 push/pull，支持宿主路径、内联数据与八进制权限；截图显式 `save:false` 并校验 430×932 JPEG；单次 Shell 使用独立 `shell.exec`，保留原交互 Shell。操作前按显式协议与能力声明准入，失败不切换协议重发。

响应分帧、大小和绝对截止时间有界，校验 peer UID；已发送写操作在超时、EOF、非法 JSON 或损坏响应时保留 `operation_may_continue`。`CaseContext.launch_app` 的 upstream 路径在失败后不自动经 uiopen 或图标点击再次启动。健康探针区分 unreachable、host_only 和 guest_ready。Rig 停止使用上游 SIGINT 路径；启动异常只清理本次新建 VM，清理失败保留错误。

上游扩展提供准确能力声明、截图无默认落盘、同 UID 准入、0600 socket、单次请求并发上限 64，以及有界读写。原交互 Shell 转交 relay 后释放该并发名额，该上限不表示交互连接总数。

单次 Shell 使用 posix_spawn、独立进程组、stdin EOF、cwd、每流 64 KiB 输出上限与 1 MiB JSON 帧上限。超时、UDS 断连和 guest HTTP 断连接入取消；向进程组发信号后再回收 leader。参数校验拒绝非法 cwd/timeout；完成标识与早到取消分别保留有界记录。正常命令退出不终止显式分离且已关闭管道的后台任务。

## 管理员认证恢复

用户已明确批准该精确 CDHash 加入 AMFI allowlist。原 osascript PID 78913/session 58769 在用户报告未看到窗口后，复查已不存在，原日志为空，预检仍被 AMFI 拒绝；退出原因未查明。sudo 非交互尝试返回需要密码，未修改准入状态。

随后在可见 Terminal 中运行保存的 `allowlist-approved.command`，先核对同一 CDHash，再由同目录 vphone-escalator 执行 allow。命令退出 0，amfid 采用包含该 CDHash 的规则，后续预检退出 0。该恢复未重复索取批准。证据为 `allowlist-terminal-r3.log`、`allowlist-terminal-r3-result.json` 与 `preflight-after-allowlist-r3.log`。

## 工具环境

新 VM 初始没有 POSIX shell，能力声明真实返回 shell=false；新 guest 自动部署后摘要与候选一致。原生 setup.skip 完成后，再安装已校验的 [Irisin v5.1.4](https://github.com/Lakr233/Irisin/releases/tag/v5.1.4) rootless 包，SHA-256 `0914c598a039a18e09677a280d25243965ee7aa274faef8339c25513a8d4e009`。

[官方 rootless 仓库](https://apt.procurs.us/dists/iphoneos-arm64-rootless/1800/)的 Release 和 Packages 索引按 SHA-256 核对，工具包逐一按索引摘要验证。最终工具集为 29 个包，含 dash、coreutils、system-cmds、dpkg、grep 及其依赖；完整版本、路径和摘要见 `rootless-tools-artifacts-r6.json` 与 `rootless-tools-artifacts-grep-r7.json`。旧 iphoneos-arm 索引仅用于调查，未安装其软件包。

Irisin CLI 的 [Pipeline.run](https://github.com/Lakr233/Irisin/blob/v5.1.4/IrisinCLI/Transaction/Pipeline.swift) 未设置 bootstrapInstall。普通安装顺序先后在缺少 shell 和 dpkg-divert 时停止，失败记录保留。按官方包内容仅预置缺失的 dash、cp、dpkg-divert，上传后逐字节读回摘要一致；动态库通过官方安装器安装。随后新的 27 包事务退出 0；日志中 add-shell 的 grep 缺失提示通过另一次两包事务补齐。未使用占位程序或忽略脚本失败选项。`/var/jb/tmp` 已创建，实际 Shell 与 755 文件执行均通过；这些结果跨重启复核。

## 验证结果

| 范围 | 结果 | 证据 |
| --- | --- | --- |
| autophone 相关隔离回归 | 451 passed，1 项 websockets 弃用警告，15.37 秒；Ruff 通过 | `autophone-regression-r3.log`、`ruff-r3.log` |
| 实际 guest C 源码的宿主测试 | 10 项通过：输出、退出码、cwd、父进程、进程组超时/取消、早到取消、持续输出、并发、帧预算 | `native-shell-tests-r2.log` |
| 实际 Swift Shell 控制器+C 模块 | 11 项通过：参数、完成标识、早到/迟到取消隔离等 | `swift-shell-controller-tests.log` |
| 实际宿主 I/O socketpair | 6 项通过：UTF-8 分片、半包、请求/响应超限、读截止时间、慢读者 | `host-io-tests-r2.log` |
| 真实基础兼容 | **25/25 通过** | [live-r3/result.json](evidence/stage2-20261031/live-r3/result.json) |
| 真实双 VM | **13/13 通过** | [isolation-r3/result.json](evidence/stage2-20261031/isolation-r3/result.json) |
| 独立停止收尾 | 两 VM stopped；磁盘无持有者，锁释放，socket unreachable | [independent-closeout-r3.json](evidence/stage2-20261031/independent-closeout-r3.json) |

基础真实回归覆盖彩色 JPEG、430×932 几何、无 path 返回、剪贴板读回、424 字符 Unicode 实际粘贴且输入框值一致、tap/swipe、home/volup/voldown/power、应用查询/启停、2 MiB 文件往返摘要、755 执行、cwd/stdin EOF、stdout/stderr/非零退出、每流输出上限、超时、断连后的父子进程回收与并发查询。系统 sips 另行确认截图为 RGB JPEG 430×932。

双 VM 回归覆盖独立宿主 PID 与 guest boot ID、Per-Rig 启动锁、跨 socket 写拒绝、剪贴板隔离、headless 截图、运行中 clone 拒绝、在途 Shell 请求停止、另一 Rig 仍 guest_ready、目标磁盘释放及重连后的新 PID/boot ID。停止中的在途请求收到 guest 未连接错误；脚本未重发该写操作。

首轮 isolation-r1 的“在途停止”检查中，sleep 因 PATH 缺失提前退出，不能作为该项证据，已保存单独的 validation note。isolation-r2 在确认请求未完成后收到预期断连错误，但测试辅助函数未接纳该错误，故该轮失败。修正脚本后 isolation-r3 全部通过；原结果未覆盖。启动清理、应用自动重发和写结果解析问题均先保存失败复现，再修复并通过回归。

## 重复执行

以下命令在 autophone worktree 执行，使用 `/Users/kolar/github/autophone/.venv/bin/python`。真实脚本要求显式目标和新的输出目录；双 VM 脚本要求 peer 事先通过独立入口以 headless 启动。

```sh
python -m tools.phase1.upstream_compat --target /Users/kolar/github/vphone-cli/.build/am31/stage2/runtime/target-2.json --output /absolute/new-output
python -m tools.phase1.upstream_isolation --target /Users/kolar/github/vphone-cli/.build/am31/stage2/runtime/target-2.json --peer /Users/kolar/github/vphone-cli/.build/am31/stage2-peer/runtime/target-3.json --output /absolute/another-new-output
```

隔离 pytest 的精确参数保存于 `regression-commands-r4.json`，显式排除 live_device/live_frida。真实脚本为 `tools/phase1/upstream_compat.py` 与 `tools/phase1/upstream_isolation.py`。源码补丁和摘要随本次结果保存。

## 验证范围与后续

本结论覆盖上述基础兼容矩阵。未逐项进行跨 UID 实际连接、DFU、旋转、文件传输中途取消、低空间及所有系统应用重装组合的真实测试；分帧/超限/超时与身份漂移的隔离测试不冒充这些真实场景。文件原子发布沿用上游 GuestFileUpload 的临时文件与 rename 实现。本轮没有替换该实现。

两个测试 VM 均保留并已停止。未合入、未发布、未删除历史数据。阶段 3 按用户已选的“指定 build-id 安装 + 基础应用操作”继续，尚未执行该业务验收。
