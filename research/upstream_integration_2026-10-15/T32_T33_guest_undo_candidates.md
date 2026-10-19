# T32/T33：已提交 guest DSC 撤销候选（2026-10-15）

起点为合并后的 `fcd19e78` 工作区；前一阶段见 [拉取合并记录](pull_merge_reconciliation.md)。本阶段新增持锁的只读 `preview-undo` 入口，从当前磁盘的已提交 v3 journal 读取 DSC 原件和操作链，返回可核验的撤销候选摘要。没有执行 guest 写入、改变安装来源或解除 IOMFB 生产门控。

## 来源与事务证据

1. 与 `inspect` 共用 `committed_guest_evidence`，要求唯一已归档 v3 journal、published 状态、原磁盘检查通过，以及当前磁盘 inode、大小、mtime 和完整 SHA-256 与检查点相符。存在已交换但未完成恢复的事务时拒绝。
2. 调用者必须提供期望 generation 和不重复的 declaration ID。保存计划及上下文从同一 journal 读取，核对规范编码、固定目标、VM、generation、身份和语义摘要。读取使用独立 `SavedPlan`，不构造当前写入计划。
3. 来源索引从保存的完整操作链重新构建，并与已封存索引逐字节比较。原件继续通过 generation manifest 的 content ID、顶层 original 目录树摘要和 source binding 核对。缺失或变化的原件、blob、最终证明、索引及 journal 均拒绝。
4. 结束前再次检查 generation 来源、索引和整个已提交检查点。代码页验证期间发生的来源变化不能产生成功结果。

新的 desired 选择可以与旧 journal 中的计划不同。预览仍描述旧计划产生的实际提交证据；它不取得新计划的执行资格。旧 v1/v2 历史、裸 Undo 文件、导入记录和 `.bak` 不产生此预览的来源资格。

## 撤销候选

`scripts/patchers/guest_undo.py` 只处理具有完整来源链的 DSC 成员。选中的每个 declaration 的所有实际变化都必须属于可核对的 DSC 操作；跨未认证成员或其他组件的部分结果拒绝。

对每个成员，选中操作必须形成链末尾连续的一组操作。处理按相反顺序逐项核对 afterSHA256 与当前链状态，再取得已保留的 beforeSHA256 内容。完整成员快照保留原有签名表；操作修改范围继续来自实际前后内容的差异。候选不重新拼接推测字节，不直接修改原件或当前磁盘。

只撤销末尾补丁时，候选保留前序补丁；撤销整条链时，候选必须回到已认证首次原件摘要。选中中间补丁而保留后续补丁时拒绝，原因是需要重新执行保留的 producer 并重新证明签名页，当前入口未实现该流程。

当前成员与恢复候选均通过既有 `component_signatures` 读取 DSC CodeDirectory 并重新计算全部代码页摘要。缺签名目录、零代码页、不支持的哈希、页摘要不一致均拒绝。返回字段包括 currentSHA256、restoredSHA256、restoresFirstOriginal、reversedOperations、remainingDeclarations 和 verifiedCodePages；同时固定输出 `writeAuthorized=false`、`runtimeValidated=false`。

候选内容是 journal 中已保留并按摘要复核的 blob。命令输出其摘要及反向操作证据，不创建或发布新的磁盘文件。

## 使用

```sh
.venv/bin/python3 scripts/vm_lock.py /absolute/VM cfw-record -- \
  .venv/bin/python3 scripts/cfw_disk_txn.py preview-undo \
  --generation GENERATION_SHA256 \
  --declaration dyld-cfw-camera /absolute/VM
```

多个 declaration 使用重复的 `--declaration` 参数。参数缺失、重复 ID、未知 ID、generation 不符或未继承 VM 锁均返回非零。新模块加入 app bundle 必需资源；构建脚本沿用整个 patchers 目录的复制流程。

## 验证

保存了入口尚未实现时的失败回归。新增 12 项测试从实际 source prepare/attach、guest_write、cfw producer 证据、final reader、seal、publish 和 finish 运行到预览；来源挂载、最终 APFS 查询及补丁算法使用既有隔离夹具。磁盘摘要、journal、来源核对、签名页验证与 rename 使用实际实现。

相关组合命令为：

```sh
.venv/bin/python3 -B -m unittest tests.test_guest_undo tests.test_cfw_guest_publication tests.test_undo_provenance tests.test_cfw_disk_transaction -v
```

65 项通过，44.711 秒，退出 0。覆盖多次修改逆序恢复、保留前序补丁、中间撤销拒绝、desired 改变、错误 generation、旧 schema、未完成发布、损坏原件页、缺原 blob、损坏索引、磁盘变化、验证中来源变化、实际 CLI 和锁要求。`make test_python` 最终执行 869 项，跳过 2 项，无失败，220.260 秒，退出 0。`git diff --check` 通过。命令、源码摘要及压缩日志见 [证据清单](evidence/T32-T33-guest-undo/manifest.json)。

## 剩余范围

- 将候选应用于新 staged guest 的确切目标、执行任意中间补丁的受控重打，再经快照后只读核验发布。
- 在同一可恢复事务中交付 guest 分组件 Receipt、Undo 和 Swift 安装来源。目前仅消费已有 journal，不改变来源状态。
- Mach-O、Preboot、尺寸变化的 DSC 及旧 VM 缺可信 Undo 的受控迁移。
- IOMFB 固定固件对照、真实 guest on→off→on、显示/DeviceHub 行为和实际断电恢复验收。

本阶段未运行完整 Swift 入口、真实固件比较、真实挂载、签名 App 构建或 VM 验收。现有 Swift 源码、Capstone overlay 和合并前 stash 均保留。
