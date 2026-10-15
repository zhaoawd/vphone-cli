# 冻结 V9 内核发布性能只读分析

后续独立优化已完成分项计时、1 MiB 读取回归与三版本隔离基准。512 MiB+3 字节、暖缓存、三次计入测量中，完整 capture 中位数由未计时基线 1.908 秒降至 1.661 秒（减少 12.9%），validate 由 1.369 秒降至 0.722 秒（减少 47.3%）。结果仅适用于合成 helper，不能外推为完整发布加速。详见[独立验证结果](/Users/qcz3840/github/vphone-cli/research/evidence/2026-10-14-kernel-io-performance/performance-results.md)。冻结 V9 和 Task 8 验收保持，原数据标记失败与 amfid 停止原因均未查明。

以下保留原冻结 V9 只读分析的范围和证据。

分析对象：`2.6.20261021-local`，build `2026101404`，Task 8 测试副本的普通 schema3 `vm update-kernel`。性能分析读取冻结源码与已保存证据，并补充两次各 1 秒的回退进程采样，保存本说明及同名 JSON；未为分析修改生产源码或冻结工件，未运行磁盘哈希基准。Task 8 已授权的回退验收在独立流程中继续。已阅读 diagnosing-bugs 技能、CONTEXT.md、当前五任务设计和 kernel rollback 设计/独立审查。未找到该范围单独命名的 ADR。

现有证据确认了反复执行全量验证的具体位置和次数。它支持“整盘重复读取和哈希是明确的耗时工作来源”，尚不能把全部 3240.822 秒分摊给某一函数。没有建立快速端到端 RED/GREEN，本轮不实施优化，也不声称性能问题已解决。诊断技能的复现、插桩和修复阶段未在本次只读分析范围内执行。

| 确认事实 | 证据与限制 |
| --- | --- |
| A 正式发布退出 0，耗时 3240.822113 秒；独立读回耗时 105.036608 秒 | `kernel-v9-plan-a.json`、`readback-kernel-v9-plan-a.json`。读回是另一次命令，不计入发布耗时 |
| B desired preview 为 52.413274 秒，apply 为 101.968363 秒；发布前 snapshot 为 51.520018 秒 | 对应 `kernel-v9-plan-b-desired-preview-restored.json`、`kernel-v9-plan-b-desired-apply.json`、`snapshot-kernel-v9-plan-b.json`。snapshot 包括六文件读取、状态检查等，不能当作隔离的 Disk SHA 基准 |
| B 的 1 秒 sample 中，主线程 562 个样本均位于整盘 SHA 调用链 | PID32495，启动 13:16:45.322，采样时间 13:49:46.190；调用链为 Transaction636 → verifyOrigin167 → KernelUpdate170 → KernelMount30 → readFile/SHA。370 个主线程样本进入 SHA 压缩，192 个进入 FileHandle 读取分支。仅适用于这次短采样，不是全程时间或 CPU 占比 |
| 当时的工作是只读挂载卸载后的镜像 SHA | `FirmwareKernelMount.swift:30`。该采样没有显示锁等待或补丁扫描；不能据此排除其他阶段的等待 |
| A 磁盘 journal 有 14 个变更块；B candidate journal 有 49 个 | 块大小 4096，分别为 56 KiB 和 196 KiB 的 image block 写入量。该数值不是内核指令修改量，也不是 APFS 内部物理写入量 |
| cursor 完成后仍有较长发布期 | A 首次观察到 14/14、pending=false 为 observer elapsed 1312.4 秒，之后仍在 publishing 至 3175.8 秒；wrapper finished 首次见于 3210.9 秒。observer 起点与 wrapper 计时起点不同，不能混用 |
| 写入完成的观测窗口较短 | A 最后一次 0/14、pending=false 至首次 14/14、pending=false 为 35.0 秒；B 相应 0/49→49/49 窗口为 60.1 秒。这只是轮询包围的窗口，未隔离每次 pwrite/fsync 的耗时。cursor 只记录 Disk 写入，不记录后续哈希、DSC、Store 或 metadata 校验进度 |

一次 `verifyOrigin(.published)` 的计数如下。前提是 kernelOnly=true、唯一 installed output 为 64 GiB 的 Disk.img、所有校验成功，执行完整回调。

| 位置 | 整盘 SHA 次数 | 验证对象 |
| --- | ---: | --- |
| Transaction142，output guard | 1 | 当前 live Disk |
| KernelUpdate169，origin callback | 1 | 当前 live Disk |
| KernelMount12，只读挂载前 | 1 | 当前 live Disk |
| KernelMount30，卸载后 | 1 | 当前 live Disk，与挂载前摘要比较 |
| Transaction187，尾部 output guard | 1 | 当前 live Disk，在 plan/desired/binding 校验后再次核对 |
| 合计 | **5** | **320 GiB 逻辑内容读取** |

先前仅列前四处得到的 256 GiB 是下界；尾部 Transaction187 还需计入。sample 正好落在第四处。一次 candidate 校验跳过 Transaction142/187 的 live output SHA，callback 仍对 candidate 做直接 SHA 和挂载前后 SHA，共 **3 次**。

同一次成功 published 校验还包含：

- **3 次 `FirmwareGeneration.loadVerified`**：planBinding.validate 一次；validateReport → DesiredPlanStore.read → validate 内一次；该 validate 再调用 originalURLs，而 originalURLs 内又 loadVerified 一次。每次均重新 treeDigest 整套 generation originals，实际包括 AVPBooter 和完整 Restore，非只读两个 manifests。
- **2 次 Session.recheck**：callback 的起止各一次。每次执行 Store verifiedReceipt 和实际 CLI 文件 SHA。每次 verifiedReceipt 做一轮 secureTree、receipt/layout 检查，再显式调用 3 次签名有效性 API（Bundle 一次、CLI 一次、VM 一次）；CLI/VM 的 cdhash 方法先 verify，再读取 CodeDirectory。故每次 published 校验共 6 次显式签名有效性 API、2 次 CLI SHA。Bundle 的 nested-code 检查还可能与单独 executable 检查涉及相同代码，系统内部缓存和实际资源读取量未测量。
- prepared=true 时，readPublication 重读并哈希 publication 和 report；validateReport 再重读、哈希、解码 report 并执行完整 kernel Gate。proof 文件在 callback 前后分别哈希。这里确有 report/evidence 重读。
- **0 次通用 `FirmwareComponentReceipt.verify`**：kernel-only publication.records 为空，verifyPublication 的 generated-record 循环不执行；installed receipt 的结构/关联和 callback 中的 payload/effects/DSC 则重复核验。不能把两者统称为重复调用 receipt.validate。

成功 commit 的调用次数可以按 metadata 数量 m 表达：

| 调用点 | candidate | published |
| --- | ---: | ---: |
| commit(origin)，Transaction95，prepared=false | 1 | 0 |
| commit(qualifiedOrigin)，Transaction568 | 1 | 0 |
| Disk.publish 后，Transaction601 | 0 | 1 |
| 每条 metadata 备份前，Transaction636 | 0 | m |
| 每条 metadata 备份后，Transaction648 | 0 | m |
| beforeCommitted 后，Transaction656 | 0 | 1 |
| 合计 | **2** | **2+2m** |

本次 A/B journal 都有 receipt 和 launchpad 两条 metadata，m=2，因此是 **2 candidate + 6 published = 8 次**。metadata.original 是否存在只决定是否 move 到 backup，不改变这两处回调的调用次数；绑定内容未变化也不会自动移除该 metadata 项。异常、校验拒绝或中断可提前退出，因此这些是成功路径的条件性精确计数，不是已对运行过程插桩计数。非 kernelOnly 的 root publication 分支不适用本次计数。

| 成功 commit(origin) 范围，m=2 | 静态结果 |
| --- | ---: |
| verifyOrigin 内镜像完整 SHA | 2×3 + 6×5 = **36 次 / 2304 GiB / 2.25 TiB** |
| Disk.publish 的 validate 与最后 disk.validate | 各哈希 old/new backup 一遍，共 **4 次**；每次另顺序比较 old/new/live 三个完整镜像，共 **6 个整镜像读流** |
| Disk.publish 结束的 live Disk SHA | **1 次** |
| commit 内全部显式 64 GiB SHA | **41 次 / 2624 GiB / 2.5625 TiB** |
| 加上上述比较读流 | 至少 **3008 GiB / 2.9375 TiB 逻辑内容读取**，不含文件复制、hdiutil 内部读取、generation、签名和小证据文件 |
| validateReport(forCommit:true) | **13 次**，每次 schema3 desired.validate 含 2 次 generation 验证 |
| planBinding.validate(currentCatalog:true) | **13 次**，每次含 1 次 generation 验证 |
| generation 整套原件验证 | **39 轮**，即 13×2 + 13×1 |
| Store verifiedReceipt / 显式签名有效性 API / CLI SHA | **16 / 48 / 16 次** |
| readPublication / report 内容读取 | **10 / 23 次**；report 23=10 次关联检查+13 次 validateReport |
| 通用 FirmwareComponentReceipt.verify | **0 次**；installed callback 的 payload/effects/DSC 为 **8 轮** |

`validateReport` 的 13 次来自 verifyOrigin 内 8 次，以及 Transaction561/632/657 三处、metadata 内637两次；planBinding 同样来自 verifyOrigin 内8次，以及576/630/658三处、metadata内638两次。一般公式为 validateReport=planBinding=7+3m，schema3 generation 验证为21+9m。prepared=true 的 verifyOrigin 为7次，连同 commit 的其他三次 readPublication，共10次。

扩大到一次正常 `vm update-kernel` 的 prepare+publish 成功路径，显式镜像 SHA 还包括 prepare 1次、三个 recheck 3次、candidate clone 核对1次、capture 5次、保存 receipt 前 imageSHA1次，合计 **52 次 / 3.25 TiB**。capture 另比较两个完整镜像；连同 commit 的6个比较读流，显式逻辑读取下界为 **3.75 TiB**。这不是 SSD 实际读取字节：页缓存、稀疏文件、APFS clone、压缩和系统内部读取会使物理 I/O 不同，也不能由此推算精确 wall time。

另外，64 GiB / 4096 = 16,777,216。capture 的循环执行这一数量级的4 KiB比较；每次 disk.validate 又执行同样数量级的三文件比较。正常 commit 调用 disk.validate 两次。读取粒度导致大量 FileHandle 读取调用，独立于 SHA 的完整读流。实际发布每个变更块仍有一次 Disk fsync、两次 durable journal 保存；每次 journal 保存包含文件同步和目录同步。A14块对应28次 journal 保存，B49块对应98次；同步耗时尚未分项测量。A/B 写入完成后长时间 publishing 的证据说明不能把整个执行时间都归于这些变更块写入。

desired-plan 的慢路径也存在可数的重复。对于本次 ready desired、无 legacy、CLI 显式 classic guestEnvironment 的成功流程，preview 有 **8 轮 loadVerified**；apply 在同一准备流程上增加三个 check()和最终readCurrent，额外8轮，总计 **16 轮**。这与52.413/101.968秒接近两倍的观测相容，但尚未分项证明每轮占用时间。schema4回退会更重：selection.validate 内9轮 generation验证（targetDesired2 + liveDesired2 + history5），加外层planBinding1，单次 verifyOrigin 为10轮；相同m=2成功commit合计 **130轮**。这是成功 commit 范围的静态成本，不是动态计数。实际完整回退 A 命令退出 0，用时 4370.195726 秒（约 72.8 分钟）；独立读回另用 115.825306 秒。

| 待验证假设 | 可证伪的后续验证 |
| --- | --- |
| 重复64 GiB SHA是发布耗时的主要部分 | 在后续独立优化工件中按调用点记录hash次数/逻辑字节/开始结束单调时间；若累计时间占比较低，该假设不成立 |
| generation嵌套遍历明显增加desired保存和回退耗时 | 记录loadVerified调用者及累计原件字节/耗时，区分source文件读取与manifest解析；不根据8/16/39/130的静态计数直接推算时间 |
| Store严格签名/资源重核验有额外可见成本 | 分别记录secureTree、Bundle verify、CLI/VM verify及CLI SHA耗时，保留callback有效期和真实executable门 |
| 4 KiB读循环及逐块同步构成另一个耗时阶段 | 分别计capture/validate循环、读取调用、Disk fsync、journal文件/目录sync；用同内容非竞争测试区比较，不能在当前验收I/O中跑基准 |

B 已完成正式更新，退出 0、3389.396429 秒；独立实际读回为 110.513448 秒。这两项是分开的命令。随后首次 guest 观察在 361.804 秒超时，没有 VM target/socket。CLI 采样定位在宿主 preflight 等待，尚未执行 VM。固定临时驱动虽然记录 Detach(False)/CLEANUP_DONE，但原 amfid95240 的实际状态仍为 SSTOP4/xstatus17、非 traced。严格核对同一 PID、路径、UID、PPID 和开始时间后仅发送 SIGCONT，状态恢复为运行，原 preflight 与正式 launch 随后继续，V4 guest 系统查询通过。detach 后仍停止的原因未查明。

原 B launch wrapper 总计 1751.059353 秒，其中包含该宿主等待；补充 guest 观察为 0.355 秒，发生时 VM 已就绪。这两个时长均不能当作正常 VM 完整启动延迟。该停顿与内核发布阶段的重复整盘校验分别记录，不能合并归因。未来临时驱动退出后应核验实际 daemon 状态，严格同身份且确有残留停止时才恢复；驱动日志和退出码不能替代外部状态检查。

当前公开回退 A 也完成了 1 秒采样：PID71137、启动 15:09:37.868，采样 15:17:26.907，主线程 635 个样本均在 `FirmwareKernelUpdate.recheck`（204 行）→ Disk.img 完整 SHA 读取；456 个进入 SHA 压缩，179 个进入 FileHandle 读取分支。上层调用点为事务 worker 内第二次 recheck（86 行），在 transaction 创建之后。最初用户态 observer 对 root:0700 目录使用 Path.exists，误报不存在，导致本说明曾错误归类为事务创建前；独立审查及 root 只读实际 journal 已纠正。journal 创建于 15:15:58，早于采样；新 root observer 记录 schema4/building，原受限观察日志及带 pretransaction 的采样文件名保留，不作为阶段证据。该窗口没有显示锁等待，也不能排除其他阶段等待。回退已正式提交；此短采样仍不能确定各项耗时的全程占比。原非 root sample 权限失败单独保留，root sample 成功，未改冻结工件。

独立源码审查还核算了 schema4 回退首次创建事务目录前的成功路径：prepare 17 轮 generation loadVerified、publish 首 recheck 10 轮、inputs.originalURLs 1 轮、transaction 初始化 11 轮，合计 39 轮；另有一次 entries 原件集合完整摘要遍历、两次 64 GiB Disk.img SHA、3 次 Store verifiedReceipt/CLI SHA、2 次 hdiutil info。worker 内第二次 recheck 再增加 10 轮 generation 验证和第三次 Disk SHA，当前采样属于该处。计数条件为完整成功路径，不能直接作为各阶段耗时。详细独立审查文件另存为 `performance-prepare-independent-review.md/json`。

回退发布后的第二个 1 秒采样（2026-10-14 15:54:06.516 +0800，PID71137）定位为 Transaction637 → validateReport353 → rollbackSelection.validate32 → liveDesired.validate176 → loadVerified194 → verifyOriginals259 → treeDigest275/286。545 个主线程样本均在原件文件读取或 SHA 更新，424 个进入哈希更新分支（其中423个进入SHA压缩），121个进入读取分支。该窗口发生在metadata备份前，直接补充了重复 generation 内容验证的运行证据；仍不能计算其全程占比。另一个worker线程545个等待样本不计入主线程工作占比。

用户已明确指定执行顺序（2026-10-14）：

1. 独立优化工件中先增加分项计时。记录完整 SHA 的调用点、次数、实际逻辑字节和累计耗时；分别测量 generation 原件验证、Store/签名、比较循环及 fsync/journal。嵌套计时标记包含关系，不能直接相加。
2. 第一项算法变更仅将 capture/validate 的底层读取增至约 1 MiB，内存仍按 4 KiB 比较。先验证块偏移、末尾不足块、pending 前缀、外部修改拒绝、恢复行为及内存上界，再用隔离基准测量收益。若使用 pread，处理短读及 EINTR。
3. 单次 verifyOrigin 内合并 SHA、capture 摘要与比较融合、跳过 metadata 循环磁盘重验均后置。须另行明确验证作用域、内容稳定性证据及故障恢复矩阵，不能预先认定低风险或语义等价。跨阶段缓存、generation/Store 复用和减少 fsync 也不在首项优化范围。

独立源码副本为 `/private/tmp/vphone-kernel-io-optimization-20261014`，初始文件摘要保存于 `research/evidence/2026-10-14-kernel-io-performance/baseline-source-copy.json`。冻结 V9、Task 8 工件及现有 AMFI 范围保持，不热替换运行产物。基准使用独立合成数据，不与 Task 8 镜像检查或发布竞争。amfid 停止原因未查明，单独跟踪，不与内核发布耗时合并归因。

分项计时第一阶段已完成：独立工件中 9 项计时器 XCTest 与相关 Swift Testing 均退出 0；Swift Testing 汇总 38 项，其中 2 项真实固件 fixture 入口跳过。实际合成 capture/validate 探针动态核对 helper 内 5/2 次完整 SHA、比较字节和 EOF 计数；部分读取后 consumer 抛错保留原错误并记录 1 MiB/1 次调用。另以实际生产 helper 的小型 fixtures 记录 generation、Store/签名、journal/fsync，共 13962 条事件，完整性检查和独立审查通过。包含关系明确，不将这些计数或时间外推为完整 CLI 的分项占比。

仅计时源码与二进制已保存为 `/private/tmp/vphone-kernel-io-timed-20261014`。1 MiB 读取实现已在独立副本完成 10 项读取、7 项差异/恢复和 4 个内存子操作验证；尾部增长检测先实际 RED，补齐三流 EOF 检查后 GREEN。18 项更新/回退定向 Swift Testing 实际通过，2 项 fixture 跳过；24 次隔离基准全部通过，6 次预热排除。完整 helper 和比较阶段分别报告，不将 FileHandle API 调用与 native pread 尝试计数视为相同系统调用指标。阶段证据见 `research/evidence/2026-10-14-kernel-io-performance/stage1-production-probe-check.json`、`stage2-independent-review.md` 和 `isolated-512m-results.json`。后置优化范围保持。
