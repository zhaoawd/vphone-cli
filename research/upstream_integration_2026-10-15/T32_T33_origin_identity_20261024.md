# T32/T33 来源证明与磁盘身份读取兼容性

## 问题与证据

合成跨语言回归复现：Python 正式事务发布来源证明后，后续 `plan_gate.from_environment()` 调用正式 Swift 读取器，返回 `Firmware desired plan VM/generation/disk identity mismatch`。直接调用 `FirmwareGuestDiskIdentity.verify` 返回 `CFW disk identity has no matching complete checkpoint`。

复现已单独核对 runtime identity、密封 postimage identity、postimage 完整摘要和 generation/plan identity；这些断言通过。相同夹具未启用来源证明时，完整文件应用与撤销通过。启用后，checkpoint 增加 `guest-origin-source.json`、`guest-origin-transition.json` 和 `guest-origin-attestation.json`，而 Swift 原有精确文件集合未包含这些文件。

原因：Python checkpoint 写入器已接入来源证明，Swift 磁盘身份读取器未接入对应 journal 字段及文件集合。普通安装使 Guest 来源失效时增加的 `guest-origin-invalidation.json` 也需要同样的关联校验。

## 修改与验证

Swift 读取器增加四个可选 journal 摘要字段。三项来源证明必须完整、互相一致，并且不得与来源失效记录共存。上述记录仅允许出现在普通 v5 安装中；每个摘要必须有效且与 checkpoint 一致，随后仍执行原有完整文件摘要核验和精确文件集合核验。该读取器只确认磁盘身份连续性，不授予来源资格；Store 生产者验证保持原职责。

回归使用正式 Python 发布、文件撤销和 Swift 计划读取代码。Store 生产者资格校验和 APFS 查询使用夹具，不使用真实 VM、Store 安装或辅助窗口。

执行命令：

```sh
CLANG_MODULE_CACHE_PATH=/Users/kolar/github/vphone-cli/.build/module-cache swift test --disable-sandbox --skip-update --cache-path .build/swift-cache --filter 'CFWOriginIdentityBridgeTests|CFWFrozenPlanTests|FirmwareGuestDiskIdentityReplayTests'
.venv/bin/python3 -m unittest tests.test_guest_origin_publication tests.test_cfw_guest_publication tests.test_cfw_guest_undo_driver
```

结果：Swift 的来源证明/来源失效两种夹具、16 种既有 v4/v5 身份场景、3 种完整文件撤销场景、5 种正式写入配置及 less 子操作通过；环境选择的历史回放未启用。测试还拒绝缺失或错误的来源摘要、冲突记录、不适用版本或操作及证明文件篡改。Python 30 项通过。Python 首次沙箱执行有一项因进程持有者检查返回 EPERM 失败；同一合成套件在沙箱外通过。

证据位于 `.build/t32-t33-completion-20261023/`：`origin-identity-bridge-red-final.log`、`origin-identity-bridge-green.log`、`origin-identity-related-swift.log`、`origin-identity-related-python.log` 和 `origin-identity-related-python-unsandboxed.log`。

## 验证限制

已安装候选 `2.6.2-local.4f9d10893183` 保持不变。上述修复尚未用于真实磁盘续验，不能据此认定 T32/T33 完成。计划 `d5cc7bf5…` 已按一次执行和失败即停止要求结束；更换候选及再次执行需要新的具名批准。

## 本轮真实结果

计划 `d5cc7bf5…` 已结束，结果为失败。regular 首次应用事务 `20261024T004144Z-SaOxXsod` 成功发布；独立只读审计的 4,681 项目标和 5 项代码页记录全部通过，来源收据及 `guestEnvironment` 绑定均为 `2.6.2-local.4f9d10893183`，`runtimeValidated=false`。三项 Mach-O 撤销在原生身份预检阶段返回 `Firmware desired plan VM/generation/disk identity mismatch`；未执行撤销写盘、重应用或 EXP。

根执行器最终确认源备份 10 项完整内容和身份保持，目标附件为空。独立补充核验确认 92 项执行输入未变，三个保留磁盘的身份和元数据保持；后者不是新的完整内容校验。旧盘、失败记录和首次应用通过报告均保留，未自动重试或回滚，VM 启动和辅助窗口均为 0。

修复候选为 `2.6.2-local.a84f5889b159`，归档 SHA-256 为 `c7a6e66a6848dc92eb7e8f3680ec374c9cf01e9482e5c1ea55660a7db2c88105`。与已安装候选完整比较，仅 CLI、构建依赖记录、来源记录和 Bundle 签名资源变化；VM 程序及客户机载荷保持。该候选签名、资源、权限和 12 个宿主 Mach-O 的依赖闭包检查通过，尚未安装。

续验仍需新的具名批准及容量条件。方案复用现有 regular generation，先备份 10 项启动文件及绑定/desired 记录，再以新候选建立首次应用状态，执行三项完整文件撤销及精确重应用；EXP 在尚未创建的 `t33q-20261024` 完成两个 plist 的同类验收。同一新候选的首次应用与重应用必须满足完整字节和 mode/uid/gid 相等；既有完整字节失败记录保持。真实显示、AA.gl 和应用消费仍未验收。
