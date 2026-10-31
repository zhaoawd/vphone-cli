# T47 与 T48：克隆身份边界、APFS 快照生命周期与四层来源对账（2026-10-21）

本轮完成 T47（身份克隆与密钥继承边界）和 T48（快照、来源与整组恢复）的核心库、LaunchpadKit、CLI 入口与离线回归测试。未启动或修改真实验收 VM，未替换冻结应用，未执行提交或推送。

## 实现范围與代码结构

| 模块与路径 | 实现内容 |
| --- | --- |
| `sources/VPhoneCore/VPhoneBundleActivity.swift`、`sources/VPhoneCore/VPhoneUnixSocket.swift` | 通过 `proc_listpids`、`proc_pidinfo(PROC_PIDLISTFDS)` 与 `PROC_PIDFDVNODEPATHINFO` 检查状态文件打开句柄（含 `UInt32(bitPattern: fsid.val.0)` 高位设备号）；结合控制 socket `connect(AF_UNIX)` 探测（`ECONNREFUSED`/`ENOENT` 判为陈旧 socket，`0`/`EACCES`/`EPERM` 判为活动）和进程锁执行复制/快照前后停机核验与无漂移签名检查 |
| `sources/VPhoneCore/VPhoneBundleOps.swift` | `rename` 在 `localHostName` 等于旧名称派生默认值时同步更新，保留手工指定值；`clone` 新增 `newIdentity: Bool = false`，在复制前后验证源机停机且 `stateSignature` 未变化；启用 `newIdentity` 时清空 `machineIdentifier`、`ecid`、`udid`、`macAddress` 与冲突网络项，原样保留 `SEPStorage`、`Disk.img`、`nvram.bin`；排除 `Snapshots`、`.snapshot-revert-*`、`.template.plist`、`.cfw-history` 与根级 `.firmware-*` 本地计划及收据目录 |
| `sources/VPhoneCore/VPhoneMachineSnapshots.swift`、`sources/VPhoneCore/VPhoneVMLock.swift` | 在 `<bundle>/Snapshots/<name>/Snapshot.plist` 下管理 `Disk.img`、`SEPStorage`、`nvram.bin`（必选）及 `restore-info.json`、`.cfw-state.plist`（可选）整组 CoW 快照；`revert` 采用 `.snapshot-revert-<uuid>/SnapshotRevertJournal.plist` 事务日志，中途失败自动回滚，未清理的恢复事务阻止常规启动直至执行恢复；恢复后调用 `reconcileRevertedBundleOrigins` 重置缺失收据的已应用状态并保留 `config.plist`、ROM 与固件计划不变 |
| `sources/VPhoneCore/VPhoneMachineBinding.swift`、`sources/VPhoneLaunchpadKit/VPhoneLaunchpadMachineBinding.swift` | 维护 `launchpad.json` 四层模型（`identity`、`desired`、`applied`、`recovery`）及快照内 `launchpad.json` 副本；拒绝符号链接读写；快照恢复后将快照内 `applied`/`recovery` 与当前 `identity`/`desired` 重新对账 |
| `sources/VPhoneLaunchpadKit/VPhoneLaunchpadMachineEdit.swift`、`sources/VPhoneLaunchpadKit/VPhoneLaunchpadMachineLibrary.swift` | 新增 `VPhoneLaunchpadMachineSnapshot` 列表解码、`VPhoneLaunchpadMachinePath` 克隆与快照参数构造，以及 `VPhoneLaunchpadEditCommand.clone(_:as:newIdentity:)` |
| `sources/vphone-cli/VPhoneVMTransferCLI.swift`、`sources/vphone-cli/VPhoneVMSnapshotCLI.swift`、`sources/vphone-cli/VPhoneVMCLI.swift` | `vm clone` 增加 `--new-identity` 标志与密钥耦合说明（明确 `SEPStorage`、`Disk.img`、`nvram.bin` 共享同一次恢复生成的 SEP 根秘密与 Data 卷密钥）；注册 `vm snapshot create|list|revert|delete` 子命令 |

## 验证结果

| 测试套件 | 用例数 | 结果 | 覆盖重点 |
| --- | --- | --- | --- |
| `BundleActivityTests` | 12 | 退出 0 | 活动/陈旧控制 socket 区分、高位设备号句柄检测、短暂读者等待放行与持续读者拒绝、复制前后状态变化拒绝 |
| `BundleSnapshotsTests` | 12 | 退出 0 | 必选/可选状态文件整组克隆、恢复期间配置保持、可选收据缺失清除、中途失败回滚、`SnapshotRevertJournal.plist` 崩溃恢复与锁门控、四层 `launchpad.json` 对账、归档导出排除 `Snapshots` |
| `BundleOpsTests` | 29 | 退出 0 | 派生与自定义 mDNS 改名行为、`clone(newIdentity: true)` 身份与网络清理、读写者等待与状态漂移拒绝、导入导出稀疏文件与归档排除 |
| `BundleCloneStateTests` | 12 | 退出 0 | 保身份克隆、强制 fallback 复制、私有 staging 清理、符号链接拒绝、根级 `.cfw-history` 排除 |
| `MachineSnapshotsTests` | 4 | 退出 0 | 快照默认命名递增、JSON 解码与非法负载拒绝、克隆/快照 CLI 参数生成、四层 `launchpad.json` 对账与符号链接拒绝 |
| `FirmwareDesiredPlanStoreTests` | 18 | 退出 0 | 快照恢复后磁盘身份变化与克隆排除 `.firmware-*` 均拒绝直接沿用源机 `FirmwareDesiredPlanStore` 预检资格 |
| `VMSnapshotAndCloneCLITests` | 2 | 退出 0 | `vm clone --new-identity` 与 `vm snapshot create|list|revert|delete` 子命令解析及端到端执行 |

执行命令：

```sh
swift test --disable-sandbox --filter "BundleActivityTests|BundleSnapshotsTests|BundleOpsTests|BundleCloneStateTests|MachineSnapshotsTests|FirmwareDesiredPlanStoreTests|VMSnapshotAndCloneCLITests"
```

首次在受限沙箱内执行时，`BundleActivityTests` 中 `bind(AF_UNIX, ...)` 被沙箱拦截（退出码 1，日志归档为 `swift-tests-sandbox-eperm.log.gz`）；在授权环境中执行同一命令，7 个测试套件共 89 项测试全部通过（退出码 0，日志归档为 `swift-tests.log.gz`）。

## 验证限制

- 本轮验证均在隔离临时目录夹具上完成，未在真实 64 GiB 已恢复 VM 上执行快照恢复后启动验收或 `--new-identity` 副本并行双机启动验收。
- 冻结 `.app` 产物保持未变，尚未重新打包带新 `vm snapshot` / `vm clone --new-identity` 界面的签名候选应用。
- 证据：`research/upstream_integration_2026-10-15/evidence/T47-T48-20261021/manifest.json`。
