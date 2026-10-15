# VM 备份清理记录

日期：2026-10-08。用户授权清理部分 `vm.backups`。

## 结果

删除 5 份旧 VM 副本、1 个恢复测试 sparsebundle 和空的 `t03-restore-mount-20261007` 目录。
保留 3 份 VM 备份。未修改 `vm-new`、`vm-2607`、旧导出包、构建产物或固件夹具。

清理期间，文件系统可用空间从 17,735,680,000 字节（约 16.52 GiB）
增加到 42,188,800,000 字节（约 39.29 GiB），
观测增量约 22.77 GiB。
其他任务同时运行；该数值为清理前后观测差值。APFS 克隆存在共享块，目录占用差值不能直接作为实际释放量。

## 保留范围

- `vm.backups/t03-vm-new-20261007-recovery-point`
- `vm.backups/b17-vm-new-stopped-20261008`
- `vm.backups/b18-vm-new-first-binding-retry-20261008`

T03 保留原始恢复点；B17 的复制记录为 `verified`；B18 保留正在进行的绑定验收之前的状态。
上述用途不证明所有备份均已完成恢复、启动或应用验收。

## 删除范围

- `vm.backups/b09-vm-new-stopped-20261007-second`
- `vm.backups/b09-vm-new-stopped-20261007.staging`
- `vm.backups/b10-vm-new-stopped-20261007`
- `vm.backups/b14-vm-new-stopped-20261008`
- `vm.backups/b16-vm-new-stopped-20261008`
- `vm.backups/t03-vm-new-20261007-restored.sparsebundle`

删除副本的全部普通文件已归档，但不包含各副本的根目录 `Disk.img` 和 sparsebundle 的 `bands/` 数据。
归档包含小文件、NVRAM、SEP 存储、配置、固件历史和日志，大小 172,702,643 字节。
该归档不能恢复完整 VM。

证据：`research/artifacts/backup-cleanup-2026-10-08/cleanup.json`；
归档：`research/artifacts/backup-cleanup-2026-10-08/removed-backups-small-files.tar.gz`。
两者位于 Git 忽略的实验产物目录。

## 验证

- 删除前 `lsof +D vm.backups` 未列出打开文件；`hdiutil info` 未列出目标测试镜像。
- 清理期间持有备份根目录及所列备份目录的非阻塞排他 flock；未发现待恢复固件事务。
- T03/B17 与原复制清单逐项核对文件大小，并核对除 `Disk.img` 外所有普通文件的 SHA-256。
- B18 核对必要文件存在及磁盘文件大小；本次未重新对任何保留磁盘执行完整摘要。
- 删除前逐项读取并校验小文件归档中的文件大小和 SHA-256。
- 删除后核对所有目标路径不存在，3 份保留备份的普通文件集合、大小、mtime、inode 和分配块数未变。
- 本次未启动或恢复 VM，也未执行应用验收。
