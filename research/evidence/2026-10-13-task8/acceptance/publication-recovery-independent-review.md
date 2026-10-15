# Task 8 第七版磁盘发布后中断恢复独立审查

日期：2026-10-14。审查者：acceptance_audit。范围：只读审核保存的中断、物理块读回、正式恢复、归档 journal、元数据、六文件读回及附件观察。仅写本文件和对应 JSON；未操作 VM、挂载、AMFI 或运行中的进程。审查时另一次无注入正式更新已开始，本结论描述恢复完成时的保存观察，不表示当前 VM 没有新事务。

结论：本次证据支持实际 Disk.img 发布后中断，以及同一未提交事务正式恢复成功。未发现关联矛盾或阻断问题。该结果不证明正式完整更新、真实启动或已提交且启动后的 kernel-only 回退。

## 实际发布后中断

操作工件为已安装第七版 `2.6.20261019-local` CLI，目标限定 `/private/tmp/vphone-task8-acceptance-vms/task8-copy`。记录使用项目 `.venv/bin/python3`，设置 PYTHONDONTWRITEBYTECODE=1。

kernel-interruption-v7.json 记录 injected=true、SIGTERM、子进程退出 -15，用时 1,337.990064 秒。观察 journal、退出后 journal 和独立保存的 kernel-interruption-v7-journal.json 完全一致：

- transaction ID：`057edee1-adee-4535-b13f-0a2778470dc4`
- phase=publishing，kernelOnly=true，direction=forward，cursor=5，pending=false
- 总差异块 10,159；磁盘大小 68,719,476,736 字节，Disk.img inode 为 589096904
- 原盘 SHA-256：`391c05e119055a10b477d8ba73bb69188c4856f80ac6e69a09856a3e24baa7f0`
- 候选 SHA-256：`e1144d09d35cc5db6667f399320a39676e150bf72a155ae13c74e2fd21e4b246`

kernel-interruption-v7-physical-readback.json 的 5 个偏移正好对应 journal.offsets 的前 5 项：20,480、230,084,608、230,088,704、230,092,800、230,096,896。各块 actual 摘要等于 candidate 摘要且不同于 original 摘要，报告的两个字节比较条件均为 true。binding_unchanged=true。

该证据证明至少 5 个完整差异块已实际发布，而非仅创建候选或进入 publishing 阶段。cursor 小于差异块总数，事务尚未 committed。不能将这些块称为已经完成的完整内核安装，也不能称为短写、断电或固定指令位置的注入验收。

## 正式恢复及完整读回

kernel-interruption-v7-recover.json 的正式 `vm update-kernel ... --recover` 命令退出 0，用时 482.231996 秒。日志归档路径包含上述同一 transaction ID；日志中的 `/tmp` 与指定 `/private/tmp` 是本机已确认的系统路径别名。

归档 journal 为 rollingBack、direction=reverse、cursor=0、pending=false。恢复前后 identity、originalSHA256、candidateSHA256、size 和 offsets 完全一致。rollingBack 是当前实现恢复后归档保留的阶段名称；不能将其解释为 committed。

kernel-interruption-v7-recovery-readback.json 的文件集合与 baseline-digests.json 中副本基线严格一致，共六项：Disk.img、nvram.bin、SEPStorage、config.plist、AVPBooter.vresearch1.bin、AVPSEPBooter.vresearch1.bin。审查者对保存证据执行关联断言：六个 SHA-256 均逐一等于基线，same_content 和 inode_unchanged 均为 true；Disk.img 完整摘要恢复为上述原盘 SHA，binding_unchanged=true，pending_transaction=false。

recovery-metadata.json 中 launchpad.json 的实际 SHA 等于 journal.metadata.original，且等于 binding-before-update-v7.json 的独立计算 SHA `0b4bcfceb1b19169e7f10ffa3853578606fc6d9699a741ce88745d65c87d49c0`。原 `.firmware-component-receipts.json` 缺失状态恢复，expected/actual 均为 null。两项 restored 均为 true。

保存的 recovery-attachments.plist 不包含 task8 副本、备份或事务候选镜像；无本轮附件与无 pending 的观察一致。该 plist 中的其他既有系统镜像不属于本次清理范围。

## 证据限制

- 审查者重新解析并核对保存证据，未重新读取 64 GiB 实际磁盘或运行恢复。完整摘要和 inode 取自实施者在恢复后保存的读回结果。
- 本次为未提交事务逆向恢复原盘及元数据。提交后 guest 启动可能改变磁盘内容，不能由本结果推导已提交且启动后的 kernel-only 回退通过。该公开回退入口尚未实现。
- 无注入正式提交、提交后 payload/IM4M/receipt/source 读回、正式 host 重新绑定第四版、真实启动和清理仍需各自证据。Task 8/T34 保持未完整验收。
- 此次 SIGTERM 是主动注入，不解释此前 SIGKILL；此前 SIGKILL 的原因未查明。

## 审查输入摘要

| 文件 | SHA-256 |
| --- | --- |
| kernel-interruption-v7.json | `c3a8259d3faffc39e2cf654c05f3d52b0b3a94f5f14707878567c3c4969149c8` |
| kernel-interruption-v7-journal.json | `a17a4c77df0dac14f5bd9c203a916001927153ba66d277fd935b8f4297ab7fe1` |
| kernel-interruption-v7-physical-readback.json | `3b2a0948afdb1e0e655db1680054f1d94bd9372ce1bb8589d648bb46dada7560` |
| kernel-interruption-v7-recover.json | `f5829235673155ba59517d0b50a801698538691846b6c4bdca536b5dbaf999b4` |
| kernel-interruption-v7-recover.log | `23bf01057ae0724539fa10564cb45db6d86f3a73acc716e1e3678106d046c244` |
| kernel-interruption-v7-recovered-journal.json | `3706f59fccb26d7d2a2080a1cff21734e06f513149f5d15f629d2ec262923dfa` |
| kernel-interruption-v7-recovery-metadata.json | `7c8589cac1cb604d352af26a82b2eaf205daff91c3c6e5549ce06871300e1b05` |
| kernel-interruption-v7-recovery-readback.json | `22ab43eb72dc6b7402425c1eff3e3596edeb08525b6a6c642327d54ffa63e55e` |
| kernel-interruption-v7-recovery-attachments.plist | `0b053dcbc0b1999bbae1470cd73d1463bf6e16de55f80cc87f2a0822ffd75deb` |
