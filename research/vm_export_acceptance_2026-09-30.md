# VM 导出验收（2026-09-30）

## 范围与授权

本次验证当前 `vm-2607` 的显式原生归档后端导出；不执行导入、恢复或导入后启动。用户要求暂缓特权 helper 安装，并分别授权正常关闭 VM、在导出期间临时暂停并恢复 autophone 监控。用户要求可用磁盘空间低于 10G 时暂停相关动作；本次按 10 GiB（10,737,418,240 字节）实施。

源码基线为 `ef6f408`。CLI 使用 `.build/vphone-cli.app/Contents/MacOS/vphone-cli`。本次未修改 AMFI、SIP、系统 helper 或生产 Core Bundle。

## 已完成检查

- 运行中使用 `vm export --archive-backend native` 返回 busy，指向 PID 18678 和 boot instance；没有创建输出文件。
- 对历史导出包 `research/artifacts/p1c-import-2026-09-26/resume/source.tzst` 执行完整 `tar -tf`，退出 0。SHA-256 为 `6fc5aa3ef5fc918303386e9d3fd015b7034b4b594a27f97d87dcd3cbd4086b72`，与原记录一致。该包属于历史测试副本，不能当作当前 VM 状态。
- 第一次 `vm stop --timeout 120` 正常停止 PID 18678，没有报告强制终止。autophone 随后领取恢复任务 `A-REC-572795b05283619143f49212a21b85f1`，VM 又以 PID 84531 启动。恢复任务日志最终为 `status=error`、`rig_disposition=quarantine`；本次不修改其业务状态。
- 首次当前 VM 导出再次因 boot 锁拒绝。经用户单独授权后，以 SIGSTOP 暂停对应 Rig Agent PID 3710，保留进程身份记录；第二次正常停止 PID 84531。原健康监控 PID 21068 已在自动恢复流程中退出，本次没有终止该进程。

## 执行与结果

原生导出退出 0，耗时约 165.6 秒；完整内容校验通过，耗时约 153.6 秒。导出包装脚本每秒检查磁盘空间；低于阈值时 SIGSTOP 导出进程组并保留 VM 锁。校验流式读取归档和源文件，不解包 64 GiB 磁盘到磁盘上；在持有 VM 目录锁期间逐字节比较普通文件、校验成员集合、权限、所有者、秒级 mtime 和源元数据。本次校验通过；不据此推导导入或导入后启动通过。

证据目录：`research/artifacts/vm-export-2026-09-30/`。其中 `run_export.py`、`verify_export.py` 是本次验收脚本，不是生产命令或默认后端变更。


| 检查 | 结果 |
| --- | --- |
| 输出 | `research/artifacts/vm-export-2026-09-30/vm-2607-native.tzst` |
| 归档大小 | 16,779,735,482 字节，约 15.63 GiB |
| SHA-256 | `c637871651f8da4e1daf0a7cf04c80e6f6b36a489242807bd47ed4ab7df26059` |
| 成员 | 2,953 项，包含 2,194 个普通文件 |
| 文件内容 | 共 68,822,894,043 字节，与源文件逐字节比较通过 |
| Disk.img | 完整 68,719,476,736 字节比较通过；SHA-256 `3465faeadd529b3c8523e9dd17d19e65a07e9b662c8b0b62ca82d3fef32265f2` |
| 元数据 | 成员集合、权限、uid/gid、秒级 mtime 一致；校验期间源文件元数据未变 |
| 导出对源目录的影响 | 只有 `.vphone-runtime.json` 诊断记录改变；其余成员的 inode、大小、mode、uid/gid、纳秒级 mtime 未变 |
| 空间 | 导出阶段最低 79,872,000,000 字节；校验阶段最低 79,052,800,000 字节，约 73.62 GiB；未触发 10 GiB 暂停 |
| 健康管理终态 | 核对 PID、启动时间和命令后恢复 Rig Agent 3710；日志确认重新握手及 device session channel open |
| VM 终态 | 恢复 Rig Agent 后检查 Disk.img/nvram.bin 无打开文件；没有主动重启 VM |

本次没有恢复已由自动恢复流程停止的旧 health daemon，也没有修改自动恢复任务的 quarantine 业务状态。恢复的是本次主动暂停的 Rig Agent。该状态区别于“VM 健康验收通过”。

本次未验证 xattrs/ACL 的跨归档恢复、实际导入后的稀疏分配量、导入后启动或应用行为；默认归档后端保持 `system-tar`。真实原生导出证据只覆盖本 VM 与本产物。
