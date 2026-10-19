# T32/T33：guest 发布检查点（2026-10-15）

延续上一轮未提交的 Receipt/Undo 预检实现。Git HEAD 为 `2df4be8c`，固定上游目标仍为 `8a75092013eda87a4e30ed029b72028cb9279ac4`。本轮完成普通完整 CFW 的效果证据与实际发布磁盘绑定，不提升 guest 来源版本，不执行逐补丁撤销，也不将 T32/T33 整项标记为 accepted。

## 问题和范围

原宿主驱动在快照修改前运行 `verify-final`，然后执行清理、快照修改和磁盘交换。磁盘 journal 没有要求保存最终核验结果，也没有将最终报告、操作记录、输入/输出 blob 和交换的磁盘摘要绑定。修改前的回归证明：设置需要 guest 证据的调用后，原 `publish` 仍会交换没有最终证据的磁盘。失败记录见 `evidence/T32-T33-guest-publication/red.log`。

拉取 `fcd19e78` 后，journal v2 保留远端 Undo 来源证明语义；完整 `regular/dev/jb/exp` 安装采用 v3，同时要求 `provenanceMode=required` 和 `guestEvidenceRequired=true`。环境库替换使用远端 v2 路径并执行最终效果与来源核验。`less` 的 Swift 文件系统事务保持独立。v1/v2 历史不自动获得 v3 磁盘检查点证据。

## 发布流程

1. 驱动持有既有每 VM 锁及原 `Disk.img` 的只读描述符，生成私有副本；journal 记录 v3 及 `guestEvidenceRequired=true`。
2. 安装器完成写入后，保留原有首次效果检查和正常卸载，再对副本修改启动快照。
3. 驱动以 `hdiutil attach -readonly -nomount` 重新附加副本。最终 reader 只读挂载所需卷，重新读取操作记录及实际目标。附件记录同时包含物理设备和合成容器时，按分区表 `content-hint` 选择物理设备，再核对 APFS PhysicalStores。
4. 最终报告采用临时文件、文件 fsync、原子替换与目录 fsync 持久化。所有只读附件释放后，`seal` 再次核对活跃 frozen plan 和 VM/磁盘身份。
5. `guest-publication.json` 记录事务 ID、VM、generation、原计划及 desired 摘要、最终磁盘完整 SHA-256、最终报告/Undo 来源索引/操作记录/冻结计划/上下文摘要、全部 blob 的内容摘要与大小。直接文件操作引用的输入/输出 blob 缺失、链接、损坏或增加未知 blob 均拒绝。
6. `publish` 先重建核对远端 Undo 来源证明，再核对检查点、磁盘和当前 frozen plan，然后交换磁盘。`finish` 复核实际发布磁盘和原磁盘检查结果，再把原磁盘及证据作为同一事务归档至 `.cfw-history/<id>/`。事务记录写入及相关目录 rename 均补齐目录 fsync。

检查点文件均属于原 CFW journal，不新增一份根目录安装权威记录。封存数据中的原始内容表示 **observed-prior-state**，不能证明它从未被修补。尤其旧 `.bak`、目录复制中的既有文件和旧 guest 状态不能由本轮记录自动成为可信首次原件。

## 失败与恢复

| 情况 | 处理 |
| --- | --- |
| 最终报告缺失、属于其他事务/磁盘或操作摘要不符 | 交换前拒绝；原磁盘保持 |
| 检查点后计划、磁盘或证据发生变化 | 交换前拒绝；保留失败记录 |
| 快照后的只读核验或附件释放失败 | 不发布；按原清理规则保留需要人工检查的 staging |
| 交换完成而 published 记录尚未写入 | 根据实际 inode 判断，重新验证已封存磁盘与证据后完成归档 |
| 发布磁盘、检查点或原磁盘出现未知变化 | 标记 publication-uncertain，保留两份磁盘及 journal，不归档为成功 |
| finish 失败 | 驱动返回非零，不打印安装完成，不清理输入目录 |
| 存在未处理的 `.cfw_disk.*` | Swift/Python 的新启动和写入入口拒绝获取操作资格；cfw-record/fw-receipts 保留检查和恢复入口 |

`recover` 可在原进程结束后，从当前/保留路径中重新打开唯一匹配的原磁盘描述符。缺失、歧义或已知变化均保留数据并拒绝。旧原磁盘的完整性检查继续采用原策略：不超过 64 MiB 时完整哈希，超过该大小时分布采样；本轮没有把采样结果提升为大磁盘逐字节证明。候选/已发布磁盘使用完整 SHA-256。

以下命令必须由拥有该 VM 的锁的操作执行。示例使用现有 `cfw-record` 操作；真实 CFW 的挂载、管理员权限和所有权约束继续有效。

```sh
.venv/bin/python3 scripts/vm_lock.py /absolute/VM cfw-record -- \
  .venv/bin/python3 scripts/cfw_disk_txn.py inspect /absolute/VM

.venv/bin/python3 scripts/vm_lock.py /absolute/VM cfw-record -- \
  .venv/bin/python3 scripts/cfw_disk_txn.py recover /absolute/VM /absolute/VM/.cfw_disk.ID
```

`inspect` 只接受已完成归档、与当前磁盘 inode 和完整摘要匹配的 v3 journal。缺失和 v1/v2 记录返回 unknown；未归档、坏检查点及不明确状态拒绝。返回 `committed-effects` 时仍明确输出 `originQualified=false`、`runtimeValidated=false`，不产生新的执行权限。

## 验证和限制

以下 195 项及 manifest 属于拉取前的本地实现。合并后的验证记录见 [拉取合并记录](pull_merge_reconciliation.md)。

回归使用临时原始文件、真实 journal/检查点和 rename，并替换宿主磁盘命令、Swift plan verifier 与 APFS reader；替换边界写在 `tests/cfw_guest_publication_fixture.py`。普通宿主权限下，四个完整 CFW 变体的成功路径通过；195 项相关回归通过。首轮沙箱执行出现 EPERM 和子进程超时，普通宿主权限复验通过；未确定具体受限系统调用。中间的所有权和附件数量断言仍按旧协议，已按新增证据集合和一次写附件/一次只读附件更新；保留原有不递归修改 VM 根目录、互斥和原数据完整性断言。

另保存了最终附件 reader 的失败复现：在包含物理设备与合成 APFS 容器的构造附件中，旧代码报告无法找到唯一 base device。修正后仅接受唯一物理设备及其实际 PhysicalStores 关系。该夹具不构成真实 APFS 挂载结果。

最终全量与补充结果、命令、退出码和源码摘要见 `evidence/T32-T33-guest-publication/manifest.json`。没有执行实际 VM、真实 APFS/Preboot 操作、SIP/AMFI/TCC 改动、完整签名 App 构建或真实固件比较。

## 后续范围

- guest 分组件 Receipt 与 Swift 已安装来源、generation/磁盘身份交接仍未合入同一发布协议。本轮保存可核验的历史效果，不更新来源。
- DSC、Mach-O、Preboot 的逐补丁原件认证、on→off→on、修改代码页重新证明和 Undo 发布仍待实现。
- 拉取前本地分支未移植 IOMFB 新条件分派。远端 `fcd19e78` 已包含隔离算法及测试，生产迁移门控仍保留；完整迁移和 DeviceHub/Flutter 兼容链未验收。
- 本轮对磁盘和全部 blob 增加完整摘要检查；大容量实际 VM 的 I/O 时间尚未测量。
- 异常测试覆盖受控中断和故障，不证明实际断电、真实恢复和 guest 运行行为已经通过。
