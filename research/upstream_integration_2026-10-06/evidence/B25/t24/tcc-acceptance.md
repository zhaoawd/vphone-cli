# T24 TCC 责任链验收设置

本地没有独立 location helper 目标。宿主 CoreLocation 调用位于 `vphone-vm` 的 `VPhoneLocationProvider`。`VPhoneLaunchpadChildProcess.spawnDetached` 对启动子进程设置 responsibility disclaim；launcher 创建子进程时不设置 disclaim；CLI 的 `boot` 入口通过 `execv` 替换为配对 VM，保留 PID。上述为源码证据，实际 responsibility 归属仍需运行观察。

`/private/tmp/vphone-b25-t24/tcc-static.json` 保存构建前现有 CLI、VM、Launchpad、launcher 的 SHA256、签名、entitlements、内嵌 Info.plist 检查及源 plist。VM 签名为 ad hoc，含 location entitlement；VM 没有内嵌 `__TEXT/__info_plist`，codesign 显示 `Info.plist=not bound`。同目录 app 的 `CFBundleExecutable` 为 `vphone-cli`，三项 location usage description 存在。不据此判定实际 VM 使用了该 app 身份或 usage description。

## 实验设置

1. 最终构建后记录实际选中 CLI/VM/app SHA256、CDHash 和 Info.plist。使用父任务管理的已保留 VM 副本，保持客户机载荷摘要，关闭自动更新。
2. 直接 CLI 路线为：`<已签名app>/Contents/MacOS/vphone-cli boot --config <副本绝对路径/config.plist> --variant <副本实际模式> --no-vphoned-update`。不添加 `--headless`、`--dfu` 或 `--no-vphoned`。如副本已有绑定，必须遵守现有绑定验证并传入实际摘要，不能绕过 Bundle store/launcher 门槛。记录启动后 PID 路径，确认 CLI 的 PID 被配对 VM 占用。
3. VM 的正常启动完成后创建 CLLocationManager。GUI 的 `Location > Sync Host Location` 在 guest location capability 可用时启用，操作调用 `requestAlwaysAuthorization`/`startUpdatingLocation`。预设和回放不调用宿主 CoreLocation 请求。VM 初始化或 guest capability 失败时，仅记录已观察边界，不能声称授权流程完成。
4. 授予新的系统定位权限属于实际 GUI 动作，应由父任务在动作发生时按 CUA 策略处理确认。静态检查和观察现有权限不需要 reset。当前没有授权修改 TCC 数据库。首次提示或拒绝矩阵如需 reset，应另行明确授权，不能从已授权状态推断首次提示行为。
5. 可用系统日志流命令（由父任务启动和有界停止）：`/usr/bin/log stream --style ndjson --level debug --predicate '(process == "locationd" OR process == "tccd")' | <Python> /private/tmp/vphone-b25-t24/tcc-attribution-filter.py`。过滤器只输出允许的身份字段、actor 名称及事件分类，不输出原消息或坐标。某些系统版本日志字段为 private；缺少身份字段时保留未确认，不从 actor 名称推断 responsibility。
6. VM stdout 可仅保留 `[location] authorization status: <整数>`、`host location forwarding ready`、`started host location tracking`、`sync toggled`，将 `got location:` 行转成固定标记 `[location] location sample received`。不要保存或显示原坐标行。
7. 同时核对 requesting/accessing/responsible 的 PID、路径、签名身份，以及授权状态回调和样本接收标记。`started host location tracking` 只证明调用发生；只有收到授权状态/样本及责任归属证据后才能评估对应路线。直接 CLI 结果不能替代 Launchpad → launcher → trusted store 路线；本轮未实际建立的路线保持未验。

本轮子任务没有启动 VM/GUI、注册服务或修改 TCC 状态。
