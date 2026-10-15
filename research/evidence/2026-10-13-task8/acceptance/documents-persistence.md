# Task 8 Documents 标记持久性验收

本轮新 Documents 标记的停机重启和跨回退保留检查均通过，完整保存证据校验通过。仅使用冻结 V9 的公开内核回退入口及已授权第四版 VM；独立 I/O 优化不合入。源 VM 不启动或挂载。旧 tmp 标记失败证据保留，原因未查明。

## 停机重启结果

原 Documents 标记由回退 A 实例 `F8D80EFD-9D81-43E3-8103-E8B1D0910C34` 创建，已执行 `/var/jb/usr/bin/sync` 并实际 file_get 读回。路径为 `/private/var/mobile/Documents/task8-kernel-rollback-8f77ba93-3ef0-462a-985c-96f3facb748c`，1254 字节，SHA-256 为 `a8faa4e5b805fd5a0ee0f8330296d168bb85f33c674748595d176df3714e418e`。

正式停机后，本轮第四版 VM 新实例 `3EF0B0A0-DB1C-4FBB-8E4E-CD8E3E15B888` 正常 guest 查询通过。只读 file_get 取得同一标记，实际内容、大小和摘要与原创建记录一致；没有重新创建标记。正式 stop、launch 退出及清理均通过。

证据：`kernel-v9-documents-reboot-a-{boot-watch,marker-v2-read,vm-stop,vm-launch,post-boot-cleanup}.json`。本次第四版 preflight 退出 0，未运行临时 AMFI 驱动，未发送 amfid 信号。

## 跨回退验证

目标为已有 B 事务 `2901d975-2379-4b50-9340-8580786aacc1`，payload `a89e2e786dc61d93b14ea129072bc762594ca4cd1f54719810ea1cbf99c0e2c0`。回退前为 A 内核，payload `d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb`。本轮通过正式 `vm rollback-kernel --to-transaction` 切换到历史 B，保持当前 desired B。

停机基线冻结已通过，Disk.img 摘要为 `428bb8459b1b96d96f907b89f01d71faf74b30168888857ca44f08d2e2f4ac41`。正式回退退出 0，耗时 4283.968 秒，新事务 `0d6d197a-8b24-4944-bb38-16a60ed24fb0` 为 schema 4、committed、49/49 块、pending=false。独立实际 Preboot 读回退出 0，耗时 108.183 秒；完整 Disk.img 摘要 `a30f80c18c00e914ebe15973d819d40a41545bb33a33e250ee3bacc43c935b1b` 与提交证据一致。实际 IMG4/IM4P/payload 和 120 条 ordered records 重建匹配历史 B；description `KernelManagement_host-487.0.4`、PAYP、IM4M 和 container envelope 保持。离线发布前后六文件身份保持，其他五文件内容保持。

正式重绑为第四版 host、第九版 kernel 后，第四版 guest 实例 `CC37ACEC-BBFC-4797-800F-C2A791D86A05` 正常查询返回 Darwin 25.1.0 / iPhone17,3。只读取得原 Documents 标记的全部 1254 字节，SHA-256 与原创建及同 A 重启一致。没有重新创建标记。随后正式 stop 退出 0，launch 退出 0，日志记录 guest 优雅关机；清理验证无专用 VM、临时驱动、挂载或 pending。源 VM 六文件元数据保持；未重新计算源 VM 全盘内容摘要。

操作证据使用独立标签 `kernel-v9-documents-rollback-b`，不覆盖原 A/B/回退 A 记录。主要记录为该标签下的 `.json`、`-readback.json`、`-boot-watch.json`、`-marker-v2-read.json` 和 `-post-boot-cleanup.json`。

## 证据校验及范围

[task8-final-documents-persistence.json](task8-final-documents-persistence.json) 实际校验通过：原创建、同 A 重启、不同 payload 的 schema 4 回退 B、实际读回、三个不同启动实例、只读标记读取、正式停机及清理关联一致。校验器及启动预期工具的 26 个不同测试通过；启动预期工具的 8 项另在 Python `-O` 模式通过。冻结工具 manifest-v2 的 8 文件摘要保持；最终 [documents-persistence-final-boundary.json](documents-persistence-final-boundary.json) 的 28 项检查通过，包括冻结 V9 的 16 源文件及实际 CLI、第四版 CLI/VM 和旧失败文件。

[独立实际证据复核](documents-persistence-actual-independent-review.json) 通过：独立纯文件校验得到相同结果，并核对原创建及两次读取的实际全部字节、历史 B 目标、提交/读回/启动/停机/清理、旧失败及权限失败证据。复核没有启动 VM、访问磁盘内容或操作 AMFI。

第一次 B 启动观察因 root、0600 的启动预期证据文件无法由普通用户读取而失败。原失败记录保留，仅修正该证据文件的所有者，内容、inode 和模式保持，再观察同一已运行实例通过。补充观察的 0.248 秒不是完整启动耗时。见 `kernel-v9-documents-rollback-b-boot-observation.json` 和 `kernel-v9-documents-rollback-b-boot-evidence-owner-check.json`。

停机包装器使用了短标签 `R_B-vm-stop`。原始 JSON/log 保留，并按校验器固定文件名逐字节归档；没有重跑停机或改写命令、退出码和时间。来源及双方摘要见 [documents-stop-evidence-archive.json](documents-stop-evidence-archive.json)。

结论范围为这个 Documents 标记的两项持久性检查和相应内核回退/启动证据，不证明全部用户文件内容一致，不证明每个内核补丁的运行行为。旧 tmp 检查及其旧汇总工具没有改写或提升为通过。生产代码和优化工件没有变更，未提交 Git。

## 旧失败及独立问题

原 `kernel-v9-rollback-a-marker-read.json` 的 passed=false 保留，SHA-256 `af26e5130253333e99034296d5e31c055bf4e13d0d2e43a56222f447fcc05835`。新 Documents 重启通过不改变旧 tmp 标记失败结果，也不能说明其原因。

amfid 停止问题见 [amfid-stop-tracking.md](amfid-stop-tracking.md)，原因未查明，与内核发布耗时及标记问题分别跟踪。
