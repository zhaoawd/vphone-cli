# B35：T08 启动恢复修复与默认产物准备

## 结果

现代 daemon 的 `refreshBootstrapOnStartup` 原实现只修复 RootHide 链接和 firmware 记录，没有加载 RootHide LaunchDaemons。已有 B34 冷启动依赖显式 Irisin 激活；API_ONLY 跳过该函数。缺少自动加载是代码事实；它对完整现代 daemon 冷启动的实际影响尚未在 VM 验证。

本轮修复完成标记有效的 RootHide 启动恢复：链接修复成功后异步逐项加载常规 plist，单项失败记录后继续；以完成标记的物理根调用固定 IcliKit `LaunchdPlistPaths.prepared`，保存属主/权限并原子替换。符号链接、目录、无效及超过 1 MiB 的 plist 不加载。API_ONLY 条件保持，rootless 未新增自动加载。

启动函数回归在旧实现上产生 4 项失败，最终修复后 4 项通过；包含固定 IcliKit 路径转换源码的相关回归共 22 项通过。现代 API 候选、默认完整 app 和六个现代组件均构建通过。默认 app 仍打包 classic regular/less，现代 API 和 64 字节组件保持候选角色。因此未完成旧 CFW 自动激活和默认现代产物的运行来源一致性验收，T08 保持部分完成。

## 验证

回归入口：`.venv/bin/python research/upstream_integration_2026-10-06/evidence/B35/T08/run_regressions.py`；最终输出 `Ran 22 tests ... OK`。三个构建目标均在 `.build/research-b35/source` 执行，默认/组件构建由 `build_guard.py` 监测 5 GiB 阈值。最终现代 API 构建使用该快照的模块缓存；其日志明确 `BUILD SUCCEEDED` 和 candidate only。

| 实验设置 | 结果 | 证据 |
| --- | --- | --- |
| 实际启动函数 Swift 测试；外部服务/安装状态为替身 | 旧实现 4 项失败，最终 4 项通过；未执行 iOS launchd | `startup-red.log`、`startup-green-final.log`、`tests/test_bootstrap_startup.py` |
| 启动恢复、完成标记、API pin/build/overlay、固定 IcliKit 原始路径/归档测试 | 22 项通过；首次未限定全套模块缓存时，完成标记测试 setup 被文件系统权限拒绝，保留失败 | `related-tests-final.log`、`regression-entrypoint.log` |
| 隔离 `make daemon_api_build` | iOS arm64 Release、七个固定 checkout、overlay、签名/来源检查通过 | `api-build-final.log`、`api-candidate-manifest.json` |
| 隔离 `make build` | 最终完整 app 资源、原生依赖闭包、签名和 entitlement 检查通过；默认 guest 为 classic | `default-build-final.log`、`default-build-dependencies.json`、`default-classic-payload-manifest.json` |
| 隔离 `make guest_components_build` | 六个 arm64e 组件及源 pin/签名/manifest 检查通过；未部署 | `components-build.log`、`guest-components-manifest.json` |
| 新宿主仅 `--help` | 退出 -9；精确路径日志 AMFI -424：ad hoc signed but contains restricted entitlements | `vm-help-execution.json`、`vm-help-amfi-log.json` |
| 研究副本离线只读兼容性检查 | `sudo -n` 退出 1：需要密码；没有启动磁盘检查 | `cfw-eligibility.log` |
| 源与研究副本最终读回 | 源 PID25784、原健康 PID21157、healthy、app_list 往返成功；研究副本无磁盘句柄 | `final-readback.json` |

完整构建的前两次失败分别来自嵌套 sandbox-exec 和 dsymutil 权限；最终获准在隔离目录构建。隔离 Swift 包装器曾将缓存选项错误传给 `swift --version`，修正后完整构建通过。原构建脚本未修改，失败日志保留。缓存、SwiftPM 配置、安全配置和产物均在隔离快照中；没有覆盖源 VM 使用的 app。

## 来源与限制

分支 `codex/upstream-2d21d21-integration`，HEAD `d5d179ddd90a40e57dc739c14dbee1bed92d1bd6` 加本轮未提交启动修复。`source-snapshot.json` 保存构建源码摘要和额外输入；`signed-artifacts.json` 保存新宿主及现代 API 摘要与 CDHash。研究原宿主 SHA256 `35d53dbd…9163623`、原 API SHA256 `7f66a296…87ec454` 保持，源仍运行，本轮未暂停监测或停止 VM。构建守护记录最低余量约 269.69 GiB，未触发 5 GiB 阈值。

新宿主的临时 AMFI 作用域尚未获准。具体单 CDHash 驱动及后续步骤见 `scoped_amfi.py` 和 `vm-validation-plan.md`。旧 CFW 与现代完整组合的适用迁移步骤仍需磁盘分类核实；默认构建仍选择 classic，不能将候选静态来源检查等同于默认运行验收。没有修改系统方向策略、宿主持久 SIP/AMFI/TCC 设置或 kernel patch。
