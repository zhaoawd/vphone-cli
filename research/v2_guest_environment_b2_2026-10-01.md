# v2 环境 B2：API 守护进程并行身份

日期：2026-10-01。依据 v2 设计第 4.2 节。

## 修改与证据

- 新增 `Configuration/vphoned-api.plist`：标签 `com.vphone.vphoned.api`，程序 `/usr/bin/vphoned-api`，日志 `/var/log/vphoned-api.log`，`VPHONED_VCAM=off`。经典 plist 未改。
- API 缓存改为 `vphoned-api`，可信标记与待定标记改为 `vphoned-api.api-v2`、`vphoned-api.api-v2.pending`。native 启动、proxy 和 agent.apply_update 均修改，一致性测试与 B1 清单交叉核对。
- API worker 在启动相机监听前调用 `vp_native_vcam_enabled`；只有 `off` 禁用，其他值保留既有行为。宿主 macOS harness 覆盖未设、off、on、空字符串。
- 候选构建与检查改用 `vphoned-api.plist`。新增 `VPhoneResources.daemonAPICandidate`，指向独立 candidate 目录。

## 失败复现

身份测试修改前因 `vphoned-api.plist` 不存在失败。候选测试修改前因检查器要求旧 `vphoned.plist` 失败。相机开关测试修改前因 `vp_native_vcam_enabled` 不存在编译失败。修改后均通过。

## 验证

- `.venv/bin/python3 -B -m unittest tests.test_daemon_api_build tests.test_daemon_proxy tests.test_cfw_env_update.ManifestConsistencyTests`：25 项通过（11.064 秒）。
- `make daemon_api_build`：退出 0，Xcode BUILD SUCCEEDED；候选检查通过。记录仍为 `activated:false`、`runtime_validated:false`，vsock 1339。
- `swift test --disable-sandbox --cache-path .build/test-cache --filter ResourcesTests`：11 项通过。
- `zsh -n scripts/build_daemon_api.sh`、`git diff --check`：通过。

候选摘要：

| 文件 | SHA-256 |
| --- | --- |
| vphoned | 78bd0015cfbb79009f79a338e8d97cd4f717b805d80a267eaa5aa0606e432efc |
| vphoned-api.plist | 3fd911765d4a65a7ae22fdf170fe1dc2f607926255eb05900057ce0b0d74e159 |
| vphoned.entitlements.plist | 0fc0734159f78e9b3085959d159dba4e238a48762fa5cf39b392f5c8a1b50bb3 |

## 验证限制

没有客户机安装、服务激活、真实 launchd 加载或两个守护进程并行运行证据。候选的身份校验使用真实源 plist；候选单元测试的平台与签名工具输出为替身，实际构建后的检查使用真实工具。
