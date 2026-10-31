# T52 默认 GUI 关机修复与真实验收（2026-10-22）

默认 GUI 正常关机已通过真实验收。具名 Core Bundle `2.6.2-local.af333c78ac3b` 已安装并复核收据；独立 `t52-v2` 通过实际 Launchpad 完成仅宿主重绑、默认图形启动和停止。客户机版本与五库摘要匹配；没有启用 HTTP API 监听，直接 VSOCK 请求被接受，客户机正常停止，启动命令退出 0，磁盘和目录锁释放，身份/配置与新绑定保持。临时辅助进程仅附加一次，205.739 秒后停止并独立确认不存在。原 VM 保持运行，受保护副本保持，旧 Bundle 未改写。相关 Swift 分组 108 项及日志边界 Python 4 项通过；混合运行既有 APIProxy 测试失败原因仍未查明。摄像头/定位应用行为及物理外置卷未验收，T52 整项仍为 `accepted=false`，未提交或推送。

用户随后明确批准具名安装、仅独立 VM 的宿主绑定与默认界面启停，以及 600 秒、一次附加、单 CDHash 的临时窗口。`sudo -n` 返回 `a password is required`，未执行脚本；已请求用户在自己的终端完成认证。实际 Launchpad 可读取，重绑弹窗显示 `t52-v2` 和原绑定，环境更新默认关闭；准备阶段已取消弹窗，没有发布绑定或启动 VM。批准在本任务具名范围内保持有效，无需重复请求批准。

## 问题与证据

上一轮默认 GUI 启动没有指定 `--api-listen`，客户机经典通道没有 `shell` 能力。`VPhoneAppDelegate` 仅在启用 HTTP 监听时创建 `VPhoneAPISession`，停止策略因此选择 `VZVirtualMachine.requestStop()`。实际日志显示该请求超时，随后框架强制停止。客户机已有 `system_shutdown` 能力；显式启用 API 的上轮对照正常停止，但对照同时改变了 CLI/headless 等设置，不构成严格的单变量实验。

本轮重新运行以下命令，仍因缺少正常关机标记或出现强制停止而退出 1：

```sh
.venv/bin/python research/upstream_integration_2026-10-15/tools/verify_t52_stopped.py \
  --serial .build/t52-real-20261021/post-update-stop-failure/serial.log \
  --runtime .build/t52-real-20261021/post-update-stop-failure/post-update-runtime.json \
  --output .build/t52-real-20261021/post-update-stop-failure/replay-20261022.json
```

API 关机请求的创建受 HTTP 监听选项限制，已由源码和生产停止路径回归确认。框架请求未使该客户机关机的原因仍未查明。本轮修复增加已存在的客户机关机能力的调用路径，不声称修复 Virtualization.framework 的行为。

## 修改

- `VPhoneAppDelegate` 在取得目标 VM 的 VSOCK 设备后保留连接器。停止时优先使用已就绪的 API 会话；没有会话时，尝试直接连接目标 VM 的 API VSOCK 1339。DFU 和 `--no-vphoned` 不使用此路径。
- `VPhoneAPIGuestShutdown` 先读取 `/v1/health`，验证 API 版本、摘要格式、实例标识和 `system_shutdown`/`session_identity` 能力，再通过另一个连接提交 `system.shutdown`，要求匹配的请求 ID 和 `accepted=true`。
- 客户机 `GuestHyperTextHandler.send` 返回 `Connection: close`；`closeAfterPeer` 随后丢弃该连接的后续入站字节。能力探测与关机命令各使用一个连接，共用 3 秒绝对总期限，不重试。响应头和正文分别限制为 16 KiB、64 KiB。
- 取消、超时和强制停止会关闭本次连接。已取消或超时后的迟到连接结果不复用。能力缺失或传输失败继续使用经典命令与框架回退；原有 10 秒总体等待不变。
- 不创建默认宿主 HTTP 监听，不要求 `VPHONE_API_TOKEN`，不安装或更新客户机 daemon，不改变启动解锁等功能的启用条件。

## 回归结果

1. 提取生产停止路径的 API 请求选择后，`GuestShutdownTests.defaultGUIStopCanTryGuestAPIWithoutEnablingHTTPProxy` 先失败：默认配置的请求为 nil。修复后通过。
2. 初版模拟客户机允许连接复用，与实际关闭行为不符。将模拟服务改为每次响应后关闭连接，`testShutdownRespectsGuestConnectionCloseWithoutListenerOrToken` 在单连接实现上抛出 `transport`，退出 1；改为两连接后通过。原失败日志保留。
3. 最终新增的 10 项 socketpair 测试覆盖实际关闭行为、能力/实例缺失、请求关联与拒绝、异常 HTTP 长度/传输编码、总超时、取消、无回调及迟到回调释放。
4. 最终混合扩展运行中，未改动的 `APIProxyTests.testActiveConnectionLimitAndStopDuringConnect` 出现失败。该测试独立运行通过，完整 APIProxy 11 项单独运行也通过。混合运行失败原因未查明，未修改该测试或弱化断言。
5. 最终分组验证：APIProxy 11 项通过；其余相关 97 项通过（XCTest 45 项、Swift Testing 52 项）。两组共 108 项，分组之外未执行本轮全量 Swift/Python 测试。

最终分组命令：

```sh
swift test --skip-build --filter APIProxyTests
swift test --skip-build --skip 'FirmwareIntegrationTests|APIProxyTests' \
  --filter 'VPhoneAPIKitTests|GuestShutdownTests|APIProxyCLITests|ShutdownPolicyTests|VMWindowCloseTests|HostControlLifecycleTests|GuestWriteCoordinationTests'
```

测试未启动 VM。原始日志位于 `.build/t52-real-20261021/gui-shutdown-*.log`，小型证据另行归档。独立 release CLI 与 VM 使用 `swift build -c release --force-resolved-versions --product ...` 构建，随后执行与项目构建流程相同的权限签名、原生依赖封装、构建记录生成及 `check_bundle.py` 校验。

## 候选与批准范围

| 对象 | 结果 |
| --- | --- |
| Core Bundle 版本 | `2.6.2-local.af333c78ac3b` |
| 归档 | `.build/t52-real-20261021/gui-shutdown-fix/2.6.2-local.af333c78ac3b.tar` |
| 归档 SHA-256 | `fae9fc55a7342b80279f878f3df0e379dc6e9e787010e8b5c1d97570dc2fa912` |
| CLI SHA-256 | `e297ce7989dba9bb2f810d398ddbc2c572f58f27d0213f7a75ea96e3de3f5a54` |
| VM SHA-256 | `af333c78ac3b603a9b30871f9482b9a8471191c262d090535468d3a9ddc34dbb` |
| VM CDHash | `87b5a726726ab5b133613a8a1f26bfe3e047e271` |
| 计划安装目录 | `/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.af333c78ac3b` |
| 独立验收 VM | `.build/t51rt/lib/t52-v2` |

相对上一已安装版本，逐文件比较仅发现 CLI、VM、`build-dependencies.json`、新增源码摘要记录及签名资源表变化。全部客户机资源与 Framework 库保持字节一致。已安装的 `2.6.2-local.cd529f26a150` 保持原样。首次封装因写入源码记录后主程序资源签名失效被拒绝；改为先写记录再执行原生依赖签名后通过。摘要提取改用 `codesign --verbose=4`，已通过只读复核完成候选记录。失败副本保留。

计划仅新增具名系统版本，并将已停止的独立 VM 的宿主绑定切换到该版本；不重新进行环境替换，不修改客户机组件来源。临时放行只包含上述 VM CDHash，最长 600 秒，仅一次附加，完成即停止，不写持久允许名单。脚本 `gui-shutdown-fix/authorize-gui-shutdown.zsh` 固定归档摘要、旧安装器摘要及辅助脚本摘要，先安装并核验新版本，再启动窗口；尚未执行。

## 验收脚本与验证范围

`tools/verify_t52_default_shutdown.py prepare|running|stopped` 只观察，不启动或停止 VM。实际 Launchpad 完成宿主绑定和默认启动/停止，脚本核对新 VM 字节、冻结绑定、未启用 API 监听、客户机版本、五库摘要、直接 VSOCK 关机请求、`Guest stopped`、无强制停止、磁盘/目录锁释放及配置保持。GUI 运行/停止断言与截图通过保存的 `accept_t52_default_shutdown_ui.cua.mjs` 执行，宿主重绑提交使用 `apply_t52_host_rebind_ui.cua.mjs`，环境更新始终关闭。

首次停止证据读取误用了旧日志偏移，退出 1。原始失败日志 `default-shutdown-stopped.log` 保留。源码确认 Launchpad 为每次启动创建新日志文件；本次日志 inode 为 248798552，创建时间 08:21:22.412，晚于准备基线 08:21:13.267，早于已观察的运行实例。旧文件偏移 116694 大于新文件长度 86404，导致首次读取为空。修正后的 `t52_serial_evidence.py` 按文件身份及创建时间选择新日志从零读取；追加模式仍验证旧前缀摘要，运行观察后创建的替换文件被拒绝。4 项 Python 回归覆盖新文件、旧文件、追加与前缀改写、晚到替换。修正只涉及验收日志选择，全部正常关机、无强制停止、退出 0、磁盘/目录锁及配置保持断言保留，重放同一实际启动结果后通过；未重复启动 VM 或放行窗口。

## 真实执行结果

以下时间为 Asia/Shanghai，日期均为 2026-10-22。

| 对象 | 结果 | 证据 |
| --- | --- | --- |
| 新 Bundle | 08:19:09 安装，非特权及最终收据核验通过，归档摘要及两个 CDHash 匹配 | root-install-receipt.json、new-bundle-final-verified.json |
| 宿主重绑 | 仅 `t52-v2` 绑定切换；新绑定 SHA-256 为 `6af5c034a1837f05b3f4246203c0ff42240913f532c6e73bf026d9891510fabc`；环境更新关闭 | ui/rebind-prepared-asserted.ax.txt、ui/rebind-submitted.json、default-shutdown-prepare.json |
| 默认界面启动 | 08:21:23 提交启动；VM PID 64720，实例 `969AF5BD-896B-4636-B7E4-260EC4AEE33A`；无 `--headless`、无 `--api-listen`，经典通道 `rpc=false` | default-shutdown-running.json、ui/default-gui-running.json |
| 客户机读回 | iOS 26.1/23B85；五库目标摘要均匹配；未请求 daemon 更新 | default-shutdown-running.json、default-shutdown-requests.jsonl |
| 默认界面停止 | 08:22:04 提交停止；日志有 direct API VSOCK、apiAccepted、Guest stopped 及退出 0；无超时或框架强制停止 | default-shutdown-serial.log、default-shutdown-result.json、ui/default-gui-stopped.json |
| 发布后保持 | 配置、新绑定、restore-info、UDID 文件摘要保持；磁盘无占用，目录锁可获取 | default-shutdown-result.json |
| 临时放行清理 | 08:19:10.382 开始，08:22:36.121 停止，205.739 秒；一次附加，早于 600 秒截止，PID 63302 独立确认不存在 | boot-window/cleanup.json、final-cleanup.json |
| 受保护对象 | 原 VM PID 33355 保持运行；base/target/t52-environment 的既有文件元数据及选定摘要保持，原本缺失的绑定仍缺失；目标无挂载遗留，两版系统 Bundle 收据通过 | protected-vms-final.json、final-cleanup.json |

本轮验证了默认图形启动下的修复路径。Virtualization.framework 原请求未完成的原因仍未查明；没有将先前旧二进制的失败结果改为通过。摄像头/定位应用行为未验证，物理外置卷按用户指示暂缓。`candidate.json` 是安装前冻结的构建记录；当前完成状态见 `final-runtime-summary.json` 和 `status.json`。
