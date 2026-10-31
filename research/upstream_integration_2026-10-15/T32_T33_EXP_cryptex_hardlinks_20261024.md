# T32/T33 EXP Cryptex 硬链接拒绝（2026-10-24）

regular三项Mach-O已完成严格应用→撤销→重应用，三个阶段独立审计均为4681/4681匹配。EXP首次应用在DSC补丁执行前失败，本轮未完成T32/T33整体验收。

## 原生结果与保留核验

原计划`b98e0a56…`已按失败停止结束。EXP事务`20261024T131058Z-8sbOtt6f`没有发布，正常卸载后删除了本轮暂存磁盘，原盘身份和66处采样摘要保持；该检查不能单独表述为新的整盘完整摘要复核。regular已发布的三个事务、全部旧盘、原件、历史及备份保留。没有自动重试或回滚。

只读收尾核验通过：源备份10项完整内容及身份、571项计划输入、94项执行输入、12个无关磁盘身份和目标无附件。root私有12项写前备份依据原生最终完整读回报告，普通用户收尾没有重新读取该私有目录。归档33份文件的完整摘要再次匹配，原manifest为`0b9a83ea3334aea7300149e8cf5c38c1eba9e748ec5c583c32e513d36694722a`。源码修复在上述执行与收尾结束后进行；旧冻结包保持，旧执行计划不得用修改后的源码重跑。

## 原因与复现

`cryptex_source.attach`为EXP的可写Cryptex缓存采集`baselineTree`。`tree`对每个普通文件调用`file_sha`，经`plan_gate.snapshot`进入`component_effects.regular`。该读取器默认拒绝链接数不为1的文件。

保留的真实缓存已只读挂载并枚举。第一项被拒绝的输入为`System/Library/Accounts/DataclassOwners/Bookmarks.bundle/_CodeSignature/CodeResources`：普通文件，链接数38。总计327条硬链接路径、34组，所有组的路径计数与链接数相符，均位于该观察树内。观察时使用owners off，因此记录的宿主UID/GID不能单独作为客户机所有者证明。

同内容的两个独立文件对照通过，硬链接夹具连续两次触发原文`effect input is not an unlinked regular file`。原整树函数在真实缓存上也复现相同拒绝。真实原因是整树读取使用了补丁目标的单链接限制。文件类型变化和解除链接假设没有得到本次只读复现的支持。

## 修复及验证

整树读取先枚举并核对硬链接组的全部路径与链接数，只允许同一文件系统、完全位于观察树内的组。读取使用O_NOFOLLOW，并检查读取前后文件身份、大小、时间、链接数、模式、UID/GID及树条目。补丁目标的snapshot/capture_input仍沿用单链接限制；没有修改component_effects或放行可写文件系统的readonly_source标志。

9项定向回归通过，覆盖树内组、树外链接、读取中修改、树条目变化、符号链接、可写文件系统的只读标志拒绝及补丁目标拒绝。完整Python回归：1093项，跳过4项，314.103秒，退出0。命令为`.venv/bin/python3 -B scripts/run_tests.py python`。测试使用隔离夹具，没有启动VM。

修复后的真实缓存整树读取覆盖2931条目，与现有严格只读分支得到相同SHA-256：`8ca9292d96e176cc957bde0a5f775f8bc765f320ebe0395430b6a0a5efa4c02c`。诊断挂载已正常卸载。该结果不等于修复候选的CFW部署验收。

## 候选与待批准计划

候选`2.6.2-local.16f1cc296c84`，归档SHA-256为`36c919af81ef8b893abe7189fde414f103aa9352435364f78a021bec0efdb8b7`。以已核验a84候选为基础，仅更新Cryptex读取器、来源/构建清单及签名。CLI资源签名随之变化，非签名字节和entitlements经verify_signing核对保持；VM及全部客户机资产逐字节保持。Bundle严格签名、资源和entitlements检查通过，未安装候选。

新计划：`.build/t32-t33-completion-20261023/exp-cryptex-links-acceptance-20261024/offline-plan.json`，SHA-256为`74985b1c614eb7686564992acff1f885a75fbf955019670b1a9bfc16a3ec40e7`。只续验现有EXP副本及generation9084e09e…，不再执行regular CFW。安装和绑定前，由原生执行器完整核验并备份14项文件，包括两个现存缓存文件；13项已在准备阶段完整读回，root私有desired-plan的预期摘要来自前轮原生原件索引，实际完整读回是新执行前置条件。随后两项plist应用→撤销→精确重应用，逐阶段独立只读审计、完整原件和来源核验。允许备份后通过正式入口清理EXP可重建.cfw_temp及本轮新暂存，保留所有旧盘、失败历史、原件和其他VM。失败停止，不自动重试或回滚。

861项计划输入、94项执行输入已冻结，7项执行器回归通过。该计划尚未批准或执行。VMStarts=0、securityWindows=0；真实显示、AA.gl、应用消费和补丁运行效果仍未验收，整体accepted=false。

证据：`evidence/T32-T33-completion-20261023/exp-cryptex-hardlinks-20261024/manifest.json`。
