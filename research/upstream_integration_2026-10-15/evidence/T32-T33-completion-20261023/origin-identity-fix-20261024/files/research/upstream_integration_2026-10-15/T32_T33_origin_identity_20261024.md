# T32/T33 来源证明与磁盘身份读取兼容性

## 问题与证据

合成跨语言回归复现：Python 正式事务发布来源证明后，后续 `plan_gate.from_environment()` 调用正式 Swift 读取器，返回 `Firmware desired plan VM/generation/disk identity mismatch`。直接调用 `FirmwareGuestDiskIdentity.verify` 返回 `CFW disk identity has no matching complete checkpoint`。

复现已单独核对 runtime identity、密封 postimage identity、postimage 完整摘要和 generation/plan identity；这些断言通过。相同夹具未启用来源证明时，完整文件应用与撤销通过。启用后，checkpoint 增加 `guest-origin-source.json`、`guest-origin-transition.json` 和 `guest-origin-attestation.json`，而 Swift 原有精确文件集合未包含这些文件。

原因：Python checkpoint 写入器已接入来源证明，Swift 磁盘身份读取器未接入对应 journal 字段及文件集合。普通安装使 Guest 来源失效时增加的 `guest-origin-invalidation.json` 也需要同样的关联校验。

## 修改与验证

Swift 读取器增加四个可选 journal 摘要字段。三项来源证明必须完整、互相一致，并且不得与来源失效记录共存。上述记录仅允许出现在普通 v5 安装中；每个摘要必须有效且与 checkpoint 一致，随后仍执行原有完整文件摘要核验和精确文件集合核验。该读取器只确认磁盘身份连续性，不授予来源资格；Store 生产者验证保持原职责。

回归使用正式 Python 发布、文件撤销和 Swift 计划读取代码。Store 查询和合成 APFS 查询使用夹具，不使用真实 VM、Store 安装或辅助窗口。

执行命令：

```sh
CLANG_MODULE_CACHE_PATH=/Users/kolar/github/vphone-cli/.build/module-cache swift test --disable-sandbox --skip-update --cache-path .build/swift-cache --filter 'CFWOriginIdentityBridgeTests|CFWFrozenPlanTests|FirmwareGuestDiskIdentityReplayTests'
.venv/bin/python3 -m unittest tests.test_guest_origin_publication tests.test_cfw_guest_publication tests.test_cfw_guest_undo_driver
```

结果：Swift 的来源证明/来源失效两种夹具、16 种既有 v4/v5 身份场景、3 种完整文件撤销场景、5 种正式写入配置及 less 子操作通过；环境选择的历史回放未启用。测试还拒绝缺失或错误的来源摘要、冲突记录、不适用版本或操作及证明文件篡改。Python 30 项通过。Python 首次沙箱执行有一项因进程持有者检查返回 EPERM 失败；同一合成套件在沙箱外通过。

证据位于 `.build/t32-t33-completion-20261023/`：`origin-identity-bridge-red-final.log`、`origin-identity-bridge-green.log`、`origin-identity-related-swift.log`、`origin-identity-related-python.log` 和 `origin-identity-related-python-unsandboxed.log`。

## 验证限制

已安装候选 `2.6.2-local.4f9d10893183` 保持不变。上述修复尚未用于真实磁盘续验，不能据此认定 T32/T33 完成。正在执行的计划 `d5cc7bf5…` 保持一次执行和失败即停止要求，不能在本轮中自动替换候选或重试。
