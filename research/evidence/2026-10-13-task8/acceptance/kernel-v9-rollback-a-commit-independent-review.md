# 第九版公开回退 A 提交与实际读回独立审查

结论：公开明确 UUID 的提交后 kernel-only 回退及实际只读读回通过。第三次 V4 启动和 B marker 保持仍待验收。正式固定 V9 rollback-kernel 命令以 --to-transaction `c0a0a7a8-3677-4a44-aa36-f370bb67b5ca` 选择 A，退出0，4370.195726秒；新事务 `58597f0a-e94c-4f69-86af-b0fdfa9fd3f3` 为schema4/kernelOnly/committed、forward49/49、pending=false。实际 generic readback 退出0/115.825306秒，11条外部命令均0，工具SHA6ec114…保持，无task8附件/两个pending。

目标A历史证据另由审查者按生产公式对冻结 journal+report+publication+proof+IM4P摘要串联求SHA，得 `53c4ad6c5fb7d4221f482e13b4602ef101eeea9f69497b54616155e84ac185fc`，等于selection/proof.targetEvidenceSHA。完整targetDesired等于A原desired；journal.plan/options/receipt/targetDesiredSHA指向A ea1f…/plan703f…；liveDesiredSHA和当前before则保持B3ad404…。binding CAS43ac…与实际before关联，两种desired语义没有混用。

actual Preboot payload `d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb`、完整IM4P `b1f07780484d9dc88f989d6e236049050b38e50a1ddb94030dcecaed43f962db`、完整IMG4 `5b90c5a0ee87bf810c7e90795d537265f39774fbf85c430263fd2f61fc41ce7a` 均等于已审查A，并与B实际产物不同。R的119条有序records与A完全相同，report原SHA同为94dc7a…；generic actual readback从原件完整重建等于实际payload。source仍为同V9/e1c6ca… producer，target qualification依赖fresh可信生产路径，历史JSON不提供发布权限。rawdescription/PAYP/IM4M/envelope保持，envelope32670d…与proof相同。

| 磁盘边界 | 完整SHA |
| --- | --- |
| B启动和marker后，本次回退开始snapshot | `e8763d11ecba26d4e8c04a03bd45f69a4836b88c6551fa28e8994d74d5199575` |
| 本次回退实际结果 | `fd8c34e130d99ef75af90ee44fee6d0dcd2822048a53eb74c1cdb46ca8f23741` |
| 历史A首次提交的整盘 | `3f2860e4917024ab81d39a36d25831573318eadaf8da8e3745e1aa057763d783` |

R originalSHA等于本次post-B snapshot，且不同B首次提交Disk；结果等于candidate/proof/receipt/readonly后整盘摘要，并不同历史A整盘。该证据支持从本次当前磁盘回退内核，不能写成整盘历史恢复。其他五宿主文件完整SHA、六文件device/inode/size保持；语义binding前后均V9 host/kernel，非内核来源保持，journal.metadata原binding/receipt摘要对应本次before。currentdesiredB在读回前后CAS中保持，installed receipt指A。

原非root observer阶段报告无权威，权限误判已由root纠正；本结论使用committed archive和root实际读回。DSC由正式生产commit建立，generic readback不独立重跑DSC。字节envelope保持不等于签名/启动适用性验证；不同历史整盘SHA也不单独证明全部guest文件不变。

本审查仅E冻结文件和既有代码只读，未访问VM/Disk/实时进程或执行AMFI/VM/mount/guest/build/test。B marker已在本次snapshot之前创建并即时读回，但回退后保持必须由第三实例实际file_get建立。后续按host4/ownerfix→授权V4启动→同marker读取→正式stop/cleanup→V2最终join完成。全部输入摘要见同名JSON。
