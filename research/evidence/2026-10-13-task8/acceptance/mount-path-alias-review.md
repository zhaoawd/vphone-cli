# Task 8：真实混合挂载路径关联修复

日期：2026-10-13。

## 复现与原因

v4 真实更新返回 `Installed volume is not the exact readonly mount`。本轮使用授权备份的独立 clone，不写配置中的 Disk.img 或事务归档。

首先按生产顺序 hardware(ro) → preboot(rw) → system(ro) 进行 rw attach 与逐卷挂载。全部挂载后，diskutil 的 WritableVolume 分别为 false/true/false，statfs 的 MNT_RDONLY 位分别为 1/0/1。使用 `/private/tmp` 挂载根时，生产 validate 回放通过。因此观察不支持“WritableVolume 表示可写介质能力而非挂载状态”的解释。

同一实验改用 `/tmp` 挂载根后，diskutil MountPoint 返回 `/private/tmp`。完整 `FirmwareKernelMount.withVolumes` / `liveOperations` 实验也复现相同拒绝：Foundation transaction 路径是 `/var/folders/...`，diskutil 返回 `/private/var/folders/...`。三卷设备及读写状态均符合预期，仅路径字符串存在系统别名差异。

- `mixedmount-replay-baseline.json`：原检查在无路径别名差异时退出码 0。
- `mixedmount-live-red.json`：真实 liveOperations 退出码 1，18.953 秒，进入测试 body 前返回原错误。
- `live-mount-red/rw-1-*`：首次真实 attachment、hdiutil、APFS 列表、单卷 info、statfs flags。
- `mixedmount-alias/`：同一 clone 通过 `/tmp` 挂载时的真实观察。

## 修改

`sameHostPath` 仅将 macOS `/tmp`、`/var` 的完整路径前缀映射到 `/private/tmp`、`/private/var`。它不折叠 `..`，不调用 resolvingSymlinksInPath 或 realpath，不接受任意 symlink 的目标等价关系。

该比较应用于 hdiutil image-path 和 APFS/info MountPoint。设备、唯一容器成员、UUID、读写状态及 mount root 的 lstat 身份检查保持不变。原有相对路径检查仍要求 transaction work 内的路径层级为普通目录。

`mixedmount-alias-green.json` 记录真实 `/tmp` 观察回放、两个系统别名、任意 symlink 拒绝、dot-component 拒绝以及原有身份/读写状态场景通过。完整集成测试在该命令中未启用，不将跳过记录计为 live 验收。

## 完整集成测试范围

`FirmwareKernelLiveMountTests.liveCandidateSwapAndReadonlyReadback` 在独立临时候选上调用生产 liveOperations 和 withVolumes，复现真实 EXP producer 及 declaration gate，校验候选 region 和当前 DSC，调用真实 kernelcache swap 编码，写入唯一 Preboot 内核并即时读回。随后卸载，按 readonly 模式重新挂载并核对内核字节及 DSC；withVolumes 同时验证只读挂载前后磁盘 SHA-256 不变。

每次 inspect 保存三卷 info、APFS 列表、hdiutil images、attachment 和 statfs flags。实际结果与卸载状态以最终补充记录为准。此测试不执行 VM 启动，也不代表配置磁盘上的正式发布事务已验收。

最终完整 live 验证：`mixedmount-live-green.json` 退出码 0，`liveCandidateSwapAndReadonlyReadback` 通过，耗时 170.131 秒。日志记录候选内核 replacement 与 DSC 校验成功，以及卸载后 readonly 内核/DSC 读回成功。withVolumes 最终磁盘 SHA-256 不变检查通过。`live-mount-flags-summary.json` 记录四次 inspect、合计 12 次卷状态的 MNT_RDONLY 与 WritableVolume 全部符合要求。

`live-mount-final-attachments.json` 在测试结束后重新查询 hdiutil，确认 RED 和 GREEN 的候选镜像均未残留挂载。`live-mount-observation-sha256.json` 固定原始观察证据摘要。生产源已冻结。

清理：手工混合挂载实验创建的独立 `/private/tmp/vphone-task8-mixedmount-candidate.img` 已删除；删除前核对它与授权备份的 inode 不同。保留原始观察、测试与脚本，未删除备份或事务归档。
