# T32 regular 历史清理（2026-10-30）

用户在本聊天明确要求“清理T32的历史内容”。已删除且仅删除 `.build/t32q-20261024/.cfw-history`，包含四份历史事务、八份历史磁盘/客户机镜像及 effect-blobs。执行退出 0，独立复核确认目录不存在。

当前 regular 的 Disk.img、固件 generation、Restore 工作目录、配置及 `.build/t32q-20261024-binding-backup` 保留；EXP 数据未纳入删除范围。未安装、重绑或启动 VM，未停止进程，未改写验收计划和历史接受状态。

## 空间结果

| 对象或读数 | 结果 |
| --- | ---: |
| 删除历史目录的分配量 | 164,031,750,144 字节，152.766 GiB |
| 删除前卷可用空间 | 93,829,349,376 字节，87.385 GiB |
| 删除后卷可用空间 | 116,008,022,016 字节，108.041 GiB |
| 即时可用空间增量 | 22,178,672,640 字节，20.655 GiB |
| 稍后独立复测 | 115,916,800,000 字节，约 107.956 GiB |

目录分配量包含 APFS 可能共享的数据块。未测量独占 extent，也未隔离同期其他写入；不能将目录分配量或卷即时差值当作独占物理回收量。清理后 regular 根目录的可读分配量约 17.330 GiB，绑定备份仍约 14.001 GiB；私有 generation、Restore 内容没有完整枚举，不能由可读分配量推定完整大小。

## 删除范围与记录归档

以下四项事务均在删除前读取为 `status=published`、`exit_code=0`：

- `20261024T004144Z-SaOxXsod`
- `20261024T044848Z-v8ovSVP3`
- `20261024T064924Z-hG5gtVTI`
- `20261024T081630Z-kbuBz8Io`

删除前保存 1563 项目录/文件元数据。47 份 JSON/JSONL 记录原始总大小 23,924,461 字节，已另存为 `research/evidence/t32-history-cleanup-20261030/retired-records.tar.gz`，压缩后 3,214,383 字节。归档包含事务、计划、发布、实际效果、来源、Undo 等记录，每份内容摘要在删除前、删除后和独立复核时均通过。

归档不包含八份完整历史镜像或 effect-blobs，不能恢复旧历史的完整二进制状态。

## 功能与计划影响

regular 原有限定范围的应用、撤销、重应用验收事实及既有研究证据保持。删除完整 `.cfw-history` 后，该 VM 的完整 Receipt、Undo、历史身份链核验与历史重放能力已退役。当前磁盘字节保留不代表后续固件更新、来源资格、启动或撤销仍可通过；这些行为未重新验收。

已核对生产读取路径：`scripts/cfw_disk_txn.py:committed_guest_evidence` 在历史目录不存在时返回无已提交证据；`FirmwareGuestDiskIdentity.matchesRegistered` 在需要历史链且历史目录不存在时拒绝。没有放宽生产校验、伪造历史记录或创建替代链。

EXP 最新冻结计划 `3d98012abcd1bd61105d38ce7f042f46eca2ee2d9159d3e26cdc1691a3d88490` 对本次删除范围的直接引用只有 `unrelatedDiskIdentities` 中：

`.build/t32q-20261024/.cfw-history/20261024T004144Z-SaOxXsod/Disk.img`

该历史磁盘现已退役，旧计划的原路径保留检查不再满足。原计划与原批准记录保持原文；不能直接重跑旧计划或宣称其保留检查仍通过。未来续验需要在新计划中明确登记这项退役。`retirement.json` 已记录上述影响和原计划摘要。

## 验证

- 执行器 `research/cleanup_t32_history_20261030.py` 无参数预检、`--apply` 和 `--verify` 均完成退出 0；使用当前用户权限完成删除，没有管理员认证或权限修改。
- 检查路径为固定真实目录、四项事务集合不变、无符号链接/特殊文件/额外硬链接、无阻止删除的文件 flags、目录可写且没有 Git 跟踪文件；执行时持有 regular VM 目录、当前 Disk.img 和历史目录的非阻塞排他 flock。
- 首轮对整个 VM 执行递归 lsof 时，因保留的私有 generation/Restore 不可枚举而拒绝，尚未删除数据。后续检查限定为 VM 顶层全部条目和实际删除历史树的完整递归；不忽略 lsof 警告。未发现其他打开句柄、该 VM 的镜像附件或相关活动 VM/验收进程。私有固件目录内部的句柄未完整枚举。
- 当前 regular 的完整 64 GiB Disk.img 在删除前后 SHA-256 均为 `8ed1bb308cef1df67c980384890b838b7ae0fdd73cb0ba8be573a04d873bb9ab`，元数据保持。没有用抽样摘要替代完整读取。
- 143 项保留记录删除前后及独立复核一致，包括其他 VM/备份的顶层元数据、选定可读小文件完整摘要、当前 regular 磁盘元数据、Python 环境链接及 EXP 原计划摘要。没有对其他 VM 的完整磁盘或不可读私有目录内容重新计算摘要。
- 独立复核确认历史目录不存在、保护状态一致、原计划未变、47 份归档逐成员内容摘要匹配，执行记录中的当前 regular 完整磁盘前后摘要相等。
- 本轮未运行产品测试、固件比较或真实 VM 验收。本次仅证明删除范围、记录归档、当前 regular 磁盘字节及所列保留对象检查通过。

证据目录：`research/evidence/t32-history-cleanup-20261030/`，包含 `plan.json`、`inventory.json.gz`、`retired-records.tar.gz`、`records-manifest.json`、挂载/句柄/进程记录、`protected-after.json`、`retirement.json`、`result.json` 和 `independent-verification.json`。执行器已有完成记录，拒绝重复删除。
