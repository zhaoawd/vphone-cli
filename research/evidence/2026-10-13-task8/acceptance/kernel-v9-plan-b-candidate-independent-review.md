# 第九版计划 B 候选文件独立审查

结论：冻结候选文件内部关系和实际 IM4P 产物检查通过。该结论仅为 candidate 文件一致性；不建立已安装、正式提交或启动结论。快照为逐文件稳定读取，非原子 journal 快照。

冻结 journal 为 schema3/kernelOnly、事务 `2901d975-2379-4b50-9340-8580786aacc1`、publishing、forward49/49、pending=false。五份文件的实际 size/SHA 均与 snapshot-check 相同；report/receipt/proof 原始摘要、事务 UUID、B generation/desired/plan、V9代码版本和固定 executableSHA 相互对应。

实际 artifact SHA 为 `ecbea551116fbb2d10b0196d72ecd7f52f8f145b5ecd7632159c0025fb78bf98`；raw payload SHA 为 `a89e2e786dc61d93b14ea129072bc762594ca4cd1f54719810ea1cbf99c0e2c0`，43991040 字节。DER 恰含 IM4P/krnl/description/raw payload/PAYP 五项。raw description `KernelManagement_host-487.0.4`、magic/fourcc 和 raw PAYP 与 pristine 原件一致，PAYP SHA 为 `92c4c621253f5ecd211e5e6f0d6d5164688575a7395988fbf29142509a8a9b93`。payload 无已识别 LZFSE/LZSS 编码头。

审查者对 full SHA `b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac` 的 pristine 原件做纯文件解码，按 report 顺序应用 120 条记录。每条检查整数 offset、非空等长内容、边界和当前 original 字节；完整重建字节等于实际 candidate artifact payload，全部 final effect 均在最终字节中。receipt effects 与完整有序记录相等，唯一输出为 Disk.img。

B actual payload/IM4P/plan/input 与此前 true 计划的实际 producer + 当前 System DSC 证据一致，并与已验收 A 的 payload/IM4P 不同。proof envelope32670d…与 A 相同，但本快照无完整 candidate IMG4，未独立读取其 envelope 原字节。candidate imageSHA 也仅完成 journal/receipt/proof 关联，未实际读取当前 Disk。

49/49 与 receipt.state=committed 不代替 journal.phase=committed；artifact 名称 installed-kernel.im4p 和 receipt.scope=installedComponent 也不建立当前 Preboot 已安装结论。后续仍需正式更新退出0、committed archive、实际只读 Preboot/整盘读回及 V4 B 启动。审查只读取 E 与指定 pristine 文件，未读取活跃 VM，未操作 VM、挂载、guest、AMFI 或进程，未 build/test。完整输入摘要见同名 JSON。
