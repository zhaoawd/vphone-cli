# 计划核验的重复完整读取优化

日期：2026-10-20。范围限于同一次 `FirmwareDesiredPlanStore.read` 内的重复完整核验。独立 DSC 真实验收继续使用冻结应用；本次没有改变其执行中的程序、计划或磁盘。

## 问题和基线

`plan_gate.py` 的每次 write/sign 都先运行 Swift `cfw verify-plan`。`FirmwareDesiredPlanStore.validate` 先调用 `FirmwareGeneration.loadVerified`，随后调用 `originalURLs`，后者再次调用 `loadVerified`。已执行 CFW 磁盘交换的 VM 还会沿历史发布证据核验完整 postimage 和 effect blob 摘要。

使用现有 `VPHONE_KERNEL_IO_TRACE`，在正式 Store.read 外建立 `regression.desired-plan.read` 测量区间，排除夹具准备。两次独立请求各执行两次 loadVerified 和 verifyOriginals；`check_desired_plan_cost.py` 要求每次一次，因此优化前失败。失败日志保留。该脚本同时拒绝缺失、不完整或丢事件的 trace。

## 修改

validate 从本次刚完成完整校验的 manifest 解析原件路径，随后继续读取实际版本清单并检查 catalog、计划和版本条件。每次新的 read 都重新完整验证一次；没有跨请求或跨进程缓存。公开 originalURLs 的完整校验行为保持。

该修改减少单次计划读取内的重复核验。每个写入操作仍独立启动 verifier；历史发布链中相同内容的跨节点重复读取仍未优化。原件、发布副本和 blob 的完整摘要核验及读取稳定性检查保持。

## 回归

新增正式 Store.read 回归：连续两次新请求均成功，随后修改已保存原件且恢复原 mtime，新请求必须拒绝。I/O trace 复验确认每次仅一次完整 loadVerified/verifyOriginals。

相关 Swift 47 项、5 suites 通过：FirmwareDesiredPlanStoreTests、FirmwareGenerationTests、FirmwareGenerationPreparationTests、CFWFrozenPlanTests、FWDesiredPlanCLITests。包含实际 Swift CLI 驱动 Python/Zsh、两次 CFW 发布和 Undo、8 类身份或证据变化拒绝。参数化用例保留，未修改既有拒绝断言。另新增可选的独立性能夹具准备测试，1 项通过，使用 64MiB 磁盘和真实发布/Undo元数据；不启动 VM。

单个微型夹具的时间受并发测试负载影响，不将校验次数减半换算为实际安装耗时减半。独立 Release CLI 的相同输入对照结果将在产出后追加。

## 复验入口

- `FirmwareDesiredPlanStoreTests.measuredReadRevalidatesOriginalsForEveryRequest` 配合新的绝对 `VPHONE_KERNEL_IO_TRACE` 前缀。
- `tools/check_desired_plan_cost.py TRACE_PREFIX`：每次读取要求一次完整校验。
- 设置 `VPHONE_PLAN_COST_FIXTURE` 为一个不存在的目录后运行 `CFWFrozenPlanTests.prepareIsolatedPlanCostFixture`，保存独立64MiB、两次CFW发布及Undo的夹具。
- 经 `scripts/vm_lock.py VM fw-receipts --` 运行 `tools/benchmark_desired_plan.py`，交替执行前后两个实际CLI，各预热一次、测量三次；检查输出完全一致、trace完整、校验次数2→1、所有夹具文件和两个程序的完整摘要保持。

当前未执行新实现的真实64GiB VM安装、撤销或启动验收；现有冻结验收的结果须独立记录。

## Release 对照结果

同一独立夹具含两个64MiB历史发布副本；现有Python Undo夹具会将最终合成镜像改写为4422字节，因此测量对象明确为该历史证据链，不是实际64GiB运行磁盘。首轮基准脚本要求当前磁盘仍为64MiB而拒绝，未运行对照；核实夹具后改为同时要求当前镜像不超过64MiB、两个历史postimage各为64MiB。这个限制没有改变验证器或证据内容。

优化前后Release CLI交替顺序，各预热一次并测量三次。中位耗时143.313ms→85.219ms，耗时减少40.5%，速度比1.682。每次完整fileSHA256消费字节268509688→134254844，完整generation核验次数2→1。输出字节完全相同，夹具全部文件和两个程序SHA256保持。Release构建68.45秒退出0，实际Release验证器的3个测试函数通过，含5种写入设置和8类身份/篡改变更；可选夹具准备1项按配置跳过。

证据：`evidence/T32-T33-plan-verification-cost-20261020/manifest.json`。优化后的CLI位于 `.build/plan-verification-cost-20261020/vphone-cli-optimized`，仅用于隔离验证。当前真实DSC冻结验收已完成安装发布及installed证明，事务20261020T070734Z-tjhO0rSZ、6885代码页通过，现处于undo-preboot；没有替换其冻结应用。上述性能数据不表示真实安装耗时减少40.5%。本轮没有提交或推送。


## 2026-10-21：离线收尾与4GiB证据链对照

评审核对：新的路径解析使用本次loadVerified返回的manifest；generation ID、原件名称集合和目录布局已由该调用验证，与originalURLs原路径映射一致。公开originalURLs继续完整校验。desired的规范编码、catalog/plan摘要、版本条件、实际身份/历史发布/原件完整摘要和读取稳定性检查保持。本次未增加跨请求、跨进程或持久摘要缓存。

新增实际Store.read回归：两个CFW发布及Undo之后正常读取仍绑定原generation；checkpoint、当前磁盘替换、机器身份、保留磁盘、postimage内容/替换及运行镜像尺寸变化均必须通过计划读取入口报identityMismatch。相关回归框架报告48项/5 suites，其中可选成本夹具1项按配置跳过；执行的47个测试函数通过。将拒绝断言限定为identityMismatch后，实际Release verifier再次运行3个函数通过（报告4项，其中成本夹具1项跳过），8类身份/证据设置和5类写入设置保持。

扩展成本夹具为显式64/256/1024/4096MiB选项。仅全新路径可准备；基准要求仓库.build内路径、合成来源device、标记中generation/大小、两个指定大小postimage和一个合成Undo镜像相符。该夹具使用正式Swift/Python发布及撤销链，但APFS查询和DSC内容仍为夹具；两个历史postimage各4GiB，当前Undo镜像4422字节，不是实际4GiB或64GiB运行磁盘。准备1项102.640秒通过。

最终Release对照在相关回归进程结束后执行，各预热一次、交替顺序测量三次：

| 实验设置 | 优化前 | 优化后 |
| --- | --- | --- |
| 单次计划核验中位耗时 | 7.155970秒 | 3.657979秒 |
| 完整generation核验次数 | 2 | 1 |
| fileSHA256读取字节 | 17179943362 | 8589971681 |

该夹具耗时减少48.9%，速度比1.956。输出字节完全一致，全部夹具文件和两个CLI的完整摘要保持，trace完整且无丢事件/未关闭span/I/O错误。首轮对照部分与回归并行，结果单独保留，不作为最终时间数据。真实VM验收及其他宿主活动没有为基准停止；这些数据不建立空闲宿主预算，也不能换算为真实安装总耗时。

每个write/sign仍启动独立verifier；历史发布链中重复内容仍按节点读取。此轮完成单次请求内去重的离线收尾，不将跨操作缓存或历史链去重登记为已实现。优化候选未执行新的真实VM安装/Undo/启动；当前真实验收冻结CLI/VM SHA256前后保持。没有提交或推送。

证据：`evidence/T32-T33-plan-verification-closeout-20261021/manifest.json`；复验命令见同目录commands.txt。基准重跑须使用新的out目录，夹具重建须使用新路径。
