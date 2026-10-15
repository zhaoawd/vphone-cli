# Task 8 提交后 kernel-only 回退设计独立审查

日期：2026-10-14。审查者：acceptance_audit。只读审查 kernel-rollback-design.md、FirmwareInstalledOrigin、FirmwareTransaction、FirmwarePipeline、receipt reader 和现有 CLI。仅写本文件及对应 JSON；未修改生产/测试，未执行 VM、挂载、AMFI 或 producer。实施仍须等待根任务确认启动验收通过。

结论：草案的最小正确范围完整，可作为实施方向。没有发现需要扩大到整盘历史恢复或放宽来源资格的理由。实施前必须确定 schema 4 双计划字段合同及统一验证路径；旧第八版的仅报告适配仍不能取得发布资格。公开功能、故障恢复和真实不同 payload 回退验收都尚未实现，本审查不把设计通过写成 Task 8/T34 完成。

## 最小可实施范围

优先限定同一新可信 producer、同一 VM/generation、同一固件版本上下文和声明 catalog。正式提交计划 A，启动通过；正式提交仅内核选择不同的计划 B，启动通过；确认实际 A/B payload SHA 不同后，以公开 UUID 目标回退到 A，再启动并验证启动后 marker 保留。相同 producer 版本号可以保持，但计划、实际 payload 和事务 UUID 必须分别关联。

force-exc-guard 等已有选项只可作为候选组合。必须用实际生产重算证明差异、完整必需声明和 DSC 兼容性，不能从选项名称推定字节不同，也不能为制造差异手工修改内核。仅修复 metadata、改变来源或重新发布相同 payload 不满足不同内核内容回退验收。

候选必须从回退开始时已停机的当前磁盘创建，保持 Disk.img 稳定身份/inode；只替换唯一 Preboot 内核。不能把历史事务的整盘 reverse 用到提交并启动后的磁盘。新回退事务自身未提交时，可恢复到该回退开始前的当前磁盘，而不是恢复到旧内核首次安装前的磁盘。

## 实施前必须固定的合同

1. **schema 4 双计划关系。** 必须用类型化字段分别表达实际 targetPlan/targetPlanSHA、历史目标选择及其 desired 摘要、当前 desired 的 CAS 摘要、当前 binding CAS、目标 UUID、generation、catalog 和 producer 代码身份。receipt 指向实际执行的目标选择；proof 同时指向目标选择与当前 desired CAS。不能将同一个 desiredSHA256 在不同调用点分别解释为目标计划和当前写入条件。
2. **统一验证路径。** FirmwareTransaction.validateReport 当前硬性要求 desired.plan == journal.plan；Session.produceBinary 还会验证 planBinding。需要 schema 4 专用且共享的 qualification 方法，同时校验 targetPlan 完整 kernel Gate 和 currentDesired CAS，供 prepare、producer、ready、每个发布点及最终提交复用。普通 schema 3 行为保持。不能用 currentCatalog=false、删失败记录或只跳过 desired 相等检查来实现回退。
3. **已提交历史 reader。** 当前 readCommitted 会对当前整盘计算 receipt 摘要，不能直接用作启动后历史目标 reader。新 reader 必须检查普通目录/文件、同一稳定 VM 身份、可信 generation 原件及 committed journal/report/receipt/proof 的完整关系，取得目标完整 IM4P/payload。可读取并验证归档 candidate 镜像或新保存的小型 IM4P 证据；不能要求当前 live Disk.img 等于历史整盘 SHA。历史自洽 JSON 仍只提供选择数据，不能构造 Session/InstalledOrigin。
4. **新事务恢复合同。** schema 4 的 --recover 仍只恢复本次未提交事务，不重新运行 producer。恢复到本次开始前 Disk/binding/receipt；全局 currentDesired 不被目标历史计划覆盖或反向恢复。对 desired CAS 变化拒绝新的执行；恢复阶段需要明确处理未被本事务修改的 desired，不能凭历史计划取得新写入权限。未知磁盘或发布元数据修改继续保留待恢复。

以上是实施前必须落实的接口/测试条件，不是要求现在扩大支持跨 generation/catalog 或旧版适配。

## producer 来源与锁

现有 withTrustedStore → withVerifiedSource 确认实际运行 CLI 与已验证 Store executable 相同；callback 结束 Session.active=false。不能把历史 origin/version 字符串或 JSON 转成可 Codable 的发布资格，也不能只比较版本号替代签名、资源闭包和实际执行者检查。

初版同 producer 可直接复用进程内 produceBinary，仍要求 ordered records 从 pristine 重建与实际最终 payload 完全相等。Store → 正式 VM → worker 锁须覆盖全部重核验、producer、候选构建、读回和 origin 提交。Prepared 仅携带数据，publish 重新获得作用域，不允许保存 callback/URL 后复用资格。

未来跨 Bundle sealed producer 协议应明确由已验证、支持该协议的实际旧 executable 执行；父执行者在其 Store callback 内等待结束并重核验。仅从子 JSON 自报版本/代码 SHA 不取得来源资格。协议需要绑定输入摘要、版本上下文、完整冻结计划、实际最终 payload、完整 report、metadata 摘要、输出身份和执行结果；父进程独立验证重建 == 实际 payload == 目标预期摘要。子进程只使用私有工作目录，不访问正式 VM，不重复取得父进程已持有的正式 VM/worker 锁，不引入 Store 锁反向获取。环境和资源路径注入必须明确限制，协议能力也须由受验证 Bundle 支持，不能根据字符串猜测。

## 旧第八版入口核查

PatchComponentCLI 只有 txm、kernel-base、kernel-jb；kernel-jb 明确属于诊断入口，缺少 EXP 层且默认 gates 与完整 pipeline 不同。串联 base/JB 不能当作完整旧 EXP producer。

草案中的旧 `fw patch --ablate ...` dry-run 会在 executeStructured 的内存中产生 currentData，但不保存；公开 report 不包含最终 payload 字节/完整摘要。报告重建无法排除未记录 buffer 修改，不能等价替代 produceBinary 的 reconstructed == actualPayload 检查。旧 v8 没有所拟 sealed producer-only 协议，初版应明确拒绝该资格，不使用历史备份/proof 补充权限。

只读检查另发现现有完整 `fw patch`/`patch-firmware` 的非 ablation 事务会通过 loader.save 保存真实完整 EXP kernel 输出，并生成完整 report。它需要有效的私有 generation/desired、全部组件和事务上下文；可作为以后旧版本完整输出 Adapter 的研究入口，但目前未建立严格隔离、精确目标计划可表示性及实际执行资格的验证。不能把“有保存代码路径”写为已验证可靠 Adapter，也不应因此延迟最小同 producer 实现或解除旧 v8 拒绝。

特别是 fw plan --json 的 gates 来自模型参数，而非自动读取固件；其相等只能作为辅助检查，必须与实际 manifests/version context、真正运行 report gates 和完整目标选择一起核对。

## 启动后数据保留与验收边界

草案 marker 方法正确：在 B 正常启动后经 guest shell 写唯一文本，记录内容摘要、PID/instance、当时来源和目标选择；停止后回退，再启动新实例核对同文件和摘要。marker 只证明该项客户机写入保留，不证明全部文件系统不变。

非内核来源与 ROM/config/SEP 等宿主文件应在离线回退前后比较；再次启动后 NVRAM/SEP 等可能由 VM 正常更新，不能把启动引起的变化算成离线回退写入。需分别保存离线边界与启动后观察。当前 IMG4 的 IM4M/IM4R 原字节保留，metadata 来自可信目标 generation；当前 DSC/IM4M 不适用时拒绝，不通过恢复历史 System/清单绕过。

故障矩阵还需覆盖 schema 4 双摘要混淆/篡改、旧 reader 拒绝、target/current desired CAS 变化、不同 VM/generation、目标完整 IM4P 与 payload 不符、必需记录缺失、producer callback 过期、子进程来源不符、回退自身发布/metadata/commit/archive 中断，以及 marker 和不同 payload 的真实启动链。草案已列出这些主要类别，具体字段编码和测试命名在实施前补定。

审查输入 kernel-rollback-design.md SHA-256：`dbb5ef823d3e4912e38125a1338c09e4424c5a2053ac5ba180f97e514f1ad8d1`。
