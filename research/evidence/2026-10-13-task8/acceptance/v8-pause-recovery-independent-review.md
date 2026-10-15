# Task 8 第八版暂停事务恢复独立审查

日期：2026-10-14。审查者：acceptance_audit。只读复核暂停请求/状态、原 journal、正式恢复命令、归档 journal、更新前快照、读回脚本及实际结果；仅写本文件及对应 JSON。未执行 VM、挂载、恢复、AMFI 或进程操作，未修改生产代码。

结论：第八版同一未提交暂停事务已正式恢复，六文件内容和身份、更新前绑定及原 receipt 保持，恢复观察时无本轮附件或 pending。原暂停 journal 的 cursor=0、pending=false，没有已发布块证据；本次不能新增计为第八版磁盘写入后中断恢复。此前第七版五个实际发布块恢复的独立结论不变。

## 暂停及正式恢复关联

pause-v8-request.json 记录用户请求暂停，限定第八版 CLI 对 task8-copy 的更新进程收到 SIGTERM。pause-v8-state.json 和 pause-v8-journal.json 的 transaction ID 均为 `76e115c5-70ff-4484-8358-a357e59ce1e5`，phase=publishing、direction=forward、cursor=0、pending=false，总差异块 10,094。phase=publishing 本身不证明已有磁盘块发布；本次没有对应实际新字节读回证据。

kernel-update-v8-pause-recover.json 记录已安装 `2.6.20261020-local` CLI 正式执行 `vm update-kernel task8-copy ... --recover`，退出 0，耗时 507.385636 秒。命令保留项目 .venv 与 PYTHONDONTWRITEBYTECODE=1。日志归档路径指向同一 transaction ID；`/tmp` 与 `/private/tmp` 为本机已确认的系统路径别名。

kernel-update-v8-pause-recovered-journal.json 为 version=3、kernelOnly=true、phase=rollingBack、direction=reverse、cursor=0、pending=false。恢复前后 identity、originalSHA256、candidateSHA256、size 和 offsets 一致。该 rollingBack 归档表示当前实现的恢复记录，不能写成 committed 或提交后回退。

## 正确时点的基线及实际读回

读回使用 pre-update-v8-snapshot.json，要求 passed=true、VM 路径精确一致及六文件集合完整。该快照是第八版更新前状态，不能用更早初始基线替代。NVRAM 本次基线 SHA 为 `cd1be2e27adc339d08016adc61f82b9fd086cabf3242f49f7bdd57c6250fbfcc`，与最初基线不同；本次恢复保持的是更新前值。

pause-recovery-readback-v8.py 在副本排他目录锁下，对每个普通文件通过 O_NOFOLLOW fd 计算完整 SHA，检查 fstat/lstat 的 device/inode/size/mtime/ctime 在读前、读后及具名路径间稳定。内容、inode/device/size 与快照比较；并不要求恢复写入后的 mtime/ctime 回到旧时间值。最终附件查询失败、存在本轮附件或 pending 均令 passed=false 且非零退出。

kernel-update-v8-pause-recovery-readback.json 的 passed=true。审查者对保存结果重新执行关联断言，验证以下事实：

- 文件集合与快照严格一致，共 Disk.img、nvram.bin、SEPStorage、config.plist、AVPBooter.vresearch1.bin、AVPSEPBooter.vresearch1.bin 六项。
- 六个实际 SHA 均逐一等于快照，六个 inode 数值也与快照一致；每项 same_content/inode_unchanged/device_unchanged/size_unchanged 均为 true。
- Disk.img 完整 SHA 为 `9918d2bdd8f4cb9b653ebe0a5d552cd3f61bb4986421652f08c4049adfb82531`，等于快照及恢复关系 originalSHA256；inode 为 589096904。
- binding_unchanged=true，比较对象是 binding-before-update-v8.json（host 第八版、kernel 来源第七版），而非快照中更早的第四版 host 绑定。该文件独立摘要等于事务 launchpad.json 的 original 摘要。
- receipt_unchanged=true，快照 receipt SHA `003953ec6c64a099981f999bfa81b7d5f29efcf3c395a65029529e164dc92c8c` 等于事务 receipt 元数据的 original 摘要，保持此前已提交第七版 receipt。
- 归档 id/phase/direction/cursor/pending 与恢复命令和保存 journal 一致；task8_attachments=[]、pending_transaction=false，未记录 error 或 cleanup_observation_error。

## 范围限制

独立审查重新解析保存证据，未再次读取真实磁盘或运行读回；device/size 保持及读取期间稳定性来自已审脚本的执行断言与保存结果。无附件/pending 的结论属于恢复完成时观察，不排除随后以新名称开始的新正式更新。

本次只证明暂停的未提交事务恢复。第八版完整更新、已安装 description/PAYP 精确恢复、正常 guest 启动仍需后续证据；先前启动异常原因未查明。已提交且启动后的 kernel-only 回退入口尚未实现，不要求在本轮恢复审查中补实现。Task 8/T34 保持未完整验收。

## 审查输入摘要

| 文件 | SHA-256 |
| --- | --- |
| pre-update-v8-snapshot.json | `a589712c5d010fa6e575ec10bfe1e07e0250e5258e3a2ea432a066a14044aa53` |
| binding-before-update-v8.json | `299cced2aefc75f18256084283b2da25f44e907af763ffe51cee166c167504e8` |
| pause-v8-journal.json | `46873eccf758880f1b29c2937ea78f1723af940ce777faa973d4d2ab0d8a4dec` |
| pause-recovery-readback-v8.py | `d5e983e9210611903b5f6e20c61a491f6b6a213ddb50a59170b52364f6e16354` |
| kernel-update-v8-pause-recover.json | `abad008835c419e37af814add469d20c1294d028df478b45fbe0f3e7493235f8` |
| kernel-update-v8-pause-recover.log | `75b7825d5585617baf8a1564b1c7c5b16827b9affe33023a646079fcffde4e13` |
| kernel-update-v8-pause-recovered-journal.json | `3395bd69e6a95e409d6498fe07d5506e2dbc4651d49103da8baa0ee23ca90d2e` |
| kernel-update-v8-pause-recovery-readback.json | `4b1a8809d16f8bf84c3d23e2c2391adfc778b29998f077a727d013fc178ae7c8` |
