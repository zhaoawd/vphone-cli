# 旧 DSC VM 完整清理（2026-10-30）

用户在已知旧 VM 剩余内容及原始 ROM 引用的当前聊天中明确要求“完全清理c”。已删除 `/Users/kolar/github/vphone-cli/vm-t32-t33-dsc-20261018` 的整个剩余目录，包括固件 generation、固件历史、CFW 输入、配置和运行记录。此前已删除的 Disk.img 和 Restore 工作目录不重复计入。执行退出 0，独立复核确认整个目录不存在。

## 空间结果

| 对象或读数 | 结果 |
| --- | ---: |
| 本次剩余目录分配量 | 22,459,658,240 字节，20.917 GiB |
| 执行前卷可用空间 | 56,707,006,464 字节，52.813 GiB |
| 执行后卷可用空间 | 79,167,287,296 字节，73.730 GiB |
| 即时可用空间增量 | 22,460,280,832 字节，20.918 GiB |
| 稍后独立复测 | 79,052,800,000 字节 |

这些是不同时间的卷读数。未隔离同期其他写入或测量独占 extent，不将即时差值作为独占物理块计量。

## 必要输入归档与引用退役

最新计划 `3d98012abcd1bd61105d38ce7f042f46eca2ee2d9159d3e26cdc1691a3d88490` 对旧目录的直接引用仍为两项：已删除磁盘的保留身份，以及 generation 内一份原始 `AVPBooter.vresearch1.bin` 的冻结输入。

删除整个目录前，将该原始 ROM 的 335,688 字节另存为：

`research/evidence/storage-cleanup-c-full-20261030/retained-inputs/AVPBooter.vresearch1.bin`

归档副本在删除前、删除后及独立复查的 SHA-256 均为 `301bc973b56e86a9906bb6002d008015a57c9e07b5f191260717b97a62589072`，与旧计划记录一致。归档只保留这份输入的字节，不保留原路径、inode 或旧 generation 的完整状态，也不把新副本登记为原来源身份。

原验收计划及历史批准记录保持原文；旧磁盘和 ROM 的原路径均已不可用。`retirement.json` 明确记录完整目录退役及归档输入位置。未来续验需要以新计划明确使用归档输入并核对其来源及身份，不能直接重跑或宣称旧冻结输入检查仍通过。本次未安装、绑定或启动其他 VM，未改写任何验收计划。

## 验证

- 执行器：`research/storage_cleanup_c_full_20261030.py`。无参数预检及 `--apply` 均退出 0；使用当前用户权限，未发起管理员认证。
- 删除前保存 470 项完整元数据，检查真实路径、目录写权限、非阻塞目录锁、Git 跟踪、打开句柄、镜像附件和相关进程。未发现 Git 跟踪文件、外部打开句柄或挂载。
- 删除前归档并逐成员核验 124 份小型记录。归档不包含完整固件大镜像，不能恢复旧 VM 或 generation。
- 删除后整个旧 VM 目录不存在。99 项目录外保护记录删除前后及独立复查保持一致，包括其他 VM/备份的选定磁盘元数据和可读启动文件摘要、保留候选 tar、诊断与失败记录、Python 环境链接、原计划摘要及归档 ROM。未重新计算其他完整 VM 磁盘摘要。
- 独立复查再次确认目录不存在、保护记录相等、原计划未改写、ROM 归档摘要匹配，并逐成员核验 124 份归档记录。
- 本次未运行产品测试、固件比较或真实 VM 验收。没有删除其他 VM 或研究证据，没有停止或重启进程。

证据目录：`research/evidence/storage-cleanup-c-full-20261030/`，包括 `plan.json`、`inventory.json.gz`、`retired-small-records.tar.gz`、`small-records-manifest.json`、`retained-input.json`、占用与挂载记录、`protected-after.json`、`retirement.json`、`result.json` 和 `independent-verification.json`。执行器已有完成记录，拒绝重复执行。
