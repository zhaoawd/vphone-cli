# 回退首次事务创建前校验成本独立审查

结论：冻结源码存在可精确展开的重复完整校验。单次成功公开回退，在首次 .firmware-transaction mkdir/saveJournal 前执行39轮loadVerified原件集合校验，另对transaction entries完整原件集合取摘要一次、完整Disk SHA两次、Store verifiedReceipt三次。没有发现该段外层重试或sleep循环。已有635样本属于事务内部第二次recheck，不属于首次mkdir前。

计数假设：单次成功 vm rollback-kernel --to-transaction；ready desired；目标A为正常schema3、planBinding schema2；同generation/catalog；无错误/重试。先前独立list/preview命令不计入。

| 调用单元 | loadVerified轮数 | 展开 |
| --- | ---: | --- |
| desired.validate 或 ready read | 2 | 直接loadVerified1 + originalURLs1 |
| history.read | 5 | planBinding1 + direct generation1 + desired2 + originalURLs1 |
| selection.validate | 9 | targetDesired2 + liveDesired2 + history5 |

| 首次mkdir前阶段 | loadVerified | 完整Disk SHA |
| --- | ---: | ---: |
| rollback prepare222–241 | 17 | 1 |
| publish首recheck78 | 10 | 1 |
| publish originalURLs79 | 1 | 0 |
| transaction init223–268 | 11 | 0 |
| 合计 | 39 | 2 |

constructor另对allowedInputs各自执行Self.digest（241行），覆盖完整原件集合一次，不包括在39轮中。所有loadVerified经verifyOriginals遍历每个原件、递归目录并读取文件字节，没有资格缓存。四次history.read还各执行一次kernel原件fileSHA。对于64GiB Disk，两次显式SHA对应128GiB逻辑内容；不是实际SSD读取量或耗时。

Store verifiedReceipt三次来自初始withVerifiedExecutable、withVerifiedSource初始session.recheck、publish首recheck。Session初始CLI SHA与两次recheck CLI SHA合计三次。每次verifiedReceipt显式验证Bundle和两可执行文件，共九次签名有效性API调用；OS内部nested/resource工作不能据此计时。两个checkMounts调用分别位于prepare和首recheck，执行同步hdiutil info。

首次mkdir为Transaction270，随后syncDirectory271/saveJournal272。VM lifetime lock此前可能写.vphone-runtime.json，所以“事务mkdir前”不表示所有文件系统均无写入。constructor返回后才进入worker锁和KernelUpdate86的第二次recheck。该处另增加10轮loadVerified和第三次Disk SHA，不计入上表。

## 样本阶段纠正

保存样本PID71137，启动15:09:37.868，采样15:17:26.907（+0800）。635个主线程样本全部位于 worker closure86→recheck204→Disk完整SHA；456进入SHA压缩、179进入FileHandle读取分支。冻结源码86明确位于transaction.withWorkerLock内，在constructor mkdir/saveJournal之后。

root已确认原observer77544漏sudo，Python Path.exists把root0700目录访问失败报告为不存在，原beforetransaction状态无阶段权威。root另读实际journal为TX58597f0a-e94c-4f69-86af-b0fdfa9fd3f3/schema4/building，birth1791962158.1689463（07:15:58UTC），早于07:17:26样本；已换成assertroot、仅FileNotFound正常的observer。本审查没有读取活跃journal。原sample文件名pretransaction保留，分类纠正为事务内部第二次recheck。

## 循环、等待与证据范围

源码有目录/原件/effect有限遍历和EOF流读取；没有公开prepare/publish的重试或sleep。Store/VM/worker flock均LOCK_NB，busy抛错。同步文件I/O、签名API以及hdiutil pipe读取/waitUntilExit可耗时，hdiutil路径这里没有显式timeout；该1秒样本未显示等待，不能排除其他阶段等待。

静态次数不代表每轮耗时，短样本不能分摊整段15分钟、推定主导占比或给出ETA。稀疏文件/页缓存/APFS/OS内部行为使逻辑内容与物理I/O不同。当前V9和所有资格/CAS/锁检查保持，不实施优化。仅只读冻结源码及已有样本，16冻结源摘要仍匹配；未读/挂载活VM、未新采样进程、未测试/基准或改源，未改root维护的performance-analysis。完整源码/证据摘要与展开式见同名JSON。
