# T32/T33：roothide VM journal 核对（2026-10-16）

用户指定 `/Users/kolar/github/vphone-cli/vm-roothide-b33-20261010` 作为替代验收对象。管理员只读检查已退出 0。当前 VM 不具备正向 DSC 撤销所需证据；没有执行启动、撤销、恢复、重新安装或清理。

## 实际记录

| 事务 | journal 版本 | 状态 | 磁盘关系 |
| --- | --- | --- | --- |
| `20261011T014923Z-B38-oipbh50q` | 1 | published | 当前磁盘 dev/inode 等于记录的 staged，历史目录保留 original |
| `20261011T014844Z-B38-i7ri6ze5` | 1 | failed，exit_code=1 | staged_retained=true，原因为 mount cleanup incomplete |
| `20261011T014729Z-B38-unjetlgv` | 1 | failed，exit_code=1 | staged_retained=true，原因为 mount cleanup incomplete |

当前磁盘 device=16777231、inode=203798527，与 published.staged 相同；当前 mtime_ns=1791684727164028225，与记录的 1791634178675626457 不同。inode 一致不能证明内容保持。本轮未计算完整磁盘摘要。

三个事务目录均仅有 `Disk.img` 和 `transaction.json`。没有 `guest-publication.json`、保存计划、guest 效果、来源索引、blob 或代码页证明。VM 根目录没有 `.firmware-generations` 和 `.firmware-desired-plan.json`。v1 的 `original_check` 是历史 `sampled:66` 观察，不能作为 DSC 首次原件或逐操作来源资格。

两份 staging 的实际状态是 failed，且已经记录 finished_at；不能把目录存在等同于交换尚未完成。当前 `VPhoneVMLock` 对 `.cfw_disk.*` 按路径拒绝普通操作，因此这两份刻意保留的副本仍需明确处置后才能使用普通启动/克隆/准备入口。本轮没有移动、删除、恢复或重写它们。

## 历史用途

已读取 `research/upstream_integration_2026-10-06/evidence/B38/T08/REPORT.md`、`deployment.json` 及 `cleanup.json`。B38 报告记录独立 API daemon、其 plist 和 launchd 字典项安装，没有记录 DSC 指令变更；两份失败副本被刻意保留。历史任务的授权不作为本轮恢复、清理或重新安装授权。

## 检查与限制

管理员 helper 固定到本 VM，只使用只读文件描述符，在目录 flock 下读取 journal 与磁盘元数据，检查 lsof 和 hdiutil。检查取得目录锁，原磁盘、三份保留磁盘没有打开句柄，VM 没有附件，检查前后磁盘元数据相同。普通权限的独立记录确认 config.plist、runtime 的摘要及 Disk.img 元数据保持。

实际 journal 的版本、状态和文件集合已经足以确认缺少撤销前提。后续补充生产 reader/原磁盘抽样命令仍在等待管理员授权，已精确取消本任务的 osascript 请求，退出 143；没有向 VM 进程发送信号。该补充命令没有结果，不计作 reader 拒绝或原磁盘抽样通过。其脚本仅作为未执行的准备资产保留。

原始管理员输出为 [inspection.json](evidence/T32-T33-roothide-journal-inspection/inspection.json)，限定范围的结论为 [qualification.json](evidence/T32-T33-roothide-journal-inspection/qualification.json)，全部源码与文件摘要见 [manifest.json](evidence/T32-T33-roothide-journal-inspection/manifest.json)。

正向 DSC 撤销仍需要独立原始固件、generation、冻结计划、逐操作签名前像及与当前状态匹配的 v3 发布证据。不能把该 v1 API 安装报告直接升级为这些证明。若继续使用这台研究 VM，需先明确授权处理保留失败副本并建立新的记录化安装基线；这些动作本轮未执行。T32/T33 整项未接受。
