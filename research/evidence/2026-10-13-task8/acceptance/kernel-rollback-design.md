# Task 8 提交后 kernel-only 回退设计草案

本轮仅研究接口和证据资格，不修改生产代码或测试，不操作 VM、挂载或 AMFI。实施等待根任务确认启动验收通过。本草案不判定 v8 正式提交或启动结果。

回退的操作范围是：以停止后的当前 `Disk.img` 创建候选，只替换候选 Preboot 的唯一内核，再以新事务提交新 receipt 和 kernel 来源。当前磁盘包含启动后的客户机数据。历史事务的整盘 `reverse` 只能用于其未提交阶段的中断恢复，不能用于已经提交并启动后的回退。新回退事务自身中断时，可以恢复到这次回退开始前的当前磁盘状态。

公开目标使用已提交事务 UUID。Core Bundle 版本号不能唯一确定内核，因为同一个 producer 可以执行不同计划。历史记录、备份文件和 origin 字符串提供选择与核验数据；它们不能直接构造发布资格。

| 对象 | 当前证据 | 回退目标资格 |
| --- | --- | --- |
| 更新前 baseline | 无已核验的 kernel 来源；有完整 IMG4 摘要 | 只用于字节对照，不能从备份推定旧 producer 或填写来源 |
| v7 事务 | 已提交；payload 与 baseline 相同，但 description 改变、PAYP 缺失 | 不作为符合当前 metadata 合同的目标；启动异常原因仍未查明 |
| v8 已验证的纯文件候选 | 从可信原件重封装后与 baseline IMG4 逐字节相同 | 尚不能用候选代替正式已提交记录；未来选择其正式事务时仍需重新取得 producer 资格 |
| 尚未提交或恢复失败的事务 | 可能有备份、report 或 partial output | 拒绝作为公开回退目标 |
| 同一可信 producer、不同已提交计划 | 可从相同 generation 原件重新产生两个候选 | 优先用于真正不同 payload 的回退验收；必须先实测两个摘要不同 |
| 旧 Bundle 的已提交事务 | 可记录版本、代码摘要、计划与 payload 摘要 | 需重新执行所验证旧 producer；缺少严格执行适配时明确拒绝 |

当前可复用部分为 `FirmwareKernelUpdate` 的候选克隆、唯一 Preboot 定位、kernel/DSC 校验、元数据保留、`FirmwareKernelDisk` 的本次发布游标，以及 `FirmwareTransaction` 的 receipt/origin 原子提交。`FirmwareInstalledOrigin.withTrustedStore` 要求实际执行者与所验证 Store CLI 相同；不能把该条件改为只比较旧版本字符串。Store 验证 callback 在退出后失效，URL 或 JSON 不能延长其资格。

现有 `FirmwareComponentReceipt.readCommitted` 会比较整个当前磁盘与 receipt 的离线摘要。正常启动写入会使该检查失败。历史目标读取需要独立的、严格限定的 reader：核对同一 VM 的稳定身份、generation 原件、已提交 journal、report/receipt/proof 的摘要关系及目标 kernel 的完整 IM4P/payload；不能要求当前磁盘仍等于历史整盘摘要，也不能调用历史 `kernelDisk.validate` 来验证启动后的当前磁盘。历史数据即使全部摘要自洽，仍需真实 producer 重算。

建议公开接口保持三个入口：列出目标、预览明确目标、发布该预览。CLI 拟议形式如下；这些命令尚未实现。

```text
vm rollback-kernel NAME --list
vm rollback-kernel NAME --to-transaction UUID --preview
vm rollback-kernel NAME --to-transaction UUID
```

不接受任意备份路径或单独版本号作为目标，不默认选择“最近一个”事务。列表显示目标 UUID、producer 版本与代码摘要、generation、计划摘要、完整 IM4P/payload 摘要、metadata 校验结果及拒绝原因。预览保存当前 binding、当前 desired 的 CAS 摘要、当前磁盘摘要和目标摘要，返回的数据不携带可复用授权。发布重新取得 Store → VM → worker 的完整锁作用域，重读所有输入并重新取得 producer 资格。启动入口仍使用已授权第四版 VM；回退入口和离线执行者的 sealed protocol/launcher 白名单需显式支持新命令，不借用 `--recover` 解释成已提交回退。

拟议 `FirmwareKernelRollback` Module 统一持有这些检查，Interface 为 `targets(in:)`、`prepare(in:toTransaction:)`、`publish(_:)`。生产与测试跨同一 seam。候选挂载、producer 调用和资格检查保持内部 Adapter；不向调用方暴露可自行填写的 `InstalledOrigin` 或“已验证版本”参数。实际发布资格使用不可 Codable 的作用域对象，历史 JSON 不能解码成该对象。

不同计划的回退需要区分当前 desired 与目标执行计划。当前 `validateReport(forCommit:)` 要求 `desired.plan == journal.plan`，不能直接承载此行为。建议新增 reader 会拒绝的 journal schema 4，加入类型化 `rollbackSelection`：目标事务 UUID、目标 generation/plan/desired 摘要、旧 producer 版本/代码摘要，以及本次开始时当前 desired/binding 的 CAS 摘要。普通 schema 3 更新保持原检查。

schema 4 中，目标计划经当前可信 producer 重新解析并校验；receipt 的 plan/desired 指向实际执行的目标选择，proof 同时明确记录目标选择摘要和当前 desired 的 CAS 摘要。当前全局 desired 不被历史计划覆盖，因此回退后 desired 与 installed 可以不同。每个提交点核对当前 desired 未改变，并单独验证目标计划及全部必需内核声明。初版限制为相同 generation、固件版本上下文和声明 catalog；允许内核选择不同，要求非内核选择不变。跨 catalog 或跨 generation 目标先明确拒绝。不能用通用 `currentCatalog: false` 或删除 report 中失败项来放宽写入资格。

同一 producer 的不同计划优先使用已有公开内核选项。例如只有在适用条件满足、非内核选择保持一致、实际重算摘要不同且 DSC 检查通过时，才考虑 `force-exc-guard` 等计划差异。不为制造差异而手工改内核字节。两次提交即使 kernel 来源版本相同，也由不同事务 UUID、计划和 payload 摘要区分。相同 payload 的元数据修复或来源变化单独记录，不能充当不同 payload 回退验收。

旧 v8 的公开 dry-run 适配具有可研究路径：父执行者持有旧 Bundle 的 Store 资格和正式 VM/worker 锁，在独立私有 library 中运行精确 verified 旧 CLI；子进程只取得私有目录的占用锁，不能访问正式 VM。私有目录包含经过摘要核对的 AVPBooter 和完整 Restore 原件克隆，只有一个 Restore 目录，不复制真实 desired、binding、generation 或活动事务记录。缓存通过 `VPHONE_ROOT` 放入私有目录；环境不允许 DYLD 或资源路径注入。

```text
<verified-old-cli> fw patch scratch \
  --library-root <private-library> -V <target-variant> \
  --ablate avpbooter ibss ibec llb txm devicetree filesystem manifest \
  --report-out <private-report.json> --quiet
```

该示例仅说明现有入口，未在本轮执行。禁止 `--allow-ablation-output`。源码显示 `patchAllStructured` 在非空 ablation 且不允许输出时直接运行 dry-run，不创建事务，也不调用 loader 保存；但它仍加载每个 component，不能只提供 kernel 文件。CLI 可能写私有占用记录、缓存和 report，因此“只读”指固件输入不变，不表示完全没有文件写入。必须核验输入树前后摘要、报告唯一普通文件及父目录身份、子进程退出 0，以及旧代码和资源在 callback 内始终未变。

dry-run 不自动消费目标冻结计划的 `enabledSteps`。旧 CLI 的 variant、Frida、EXC_GUARD 参数和完整 step ablation 必须精确表示目标计划；无法表示的 guest-environment-v2、experimental-v2 或其他选择明确拒绝。用旧 verified CLI 的 `fw plan --json` 重新解析并比较目标计划，同时核对实际 report gates 与输入 manifests。保留完整原 report，确认所有非内核记录为空，另构造内核投影供 `enforceKernel` 检查。目标必需内核 step 不能被 ablate；不能删掉内核失败或 ablated 结果来制造通过。

父进程可以按新执行产生的 ordered records 从可信 pristine payload 重建候选：逐条检查原字节、范围和长度，检查全部 record 归属和必需声明，并将最终 payload 与历史目标的完整摘要比较。报告必须来自这次受控的旧 CLI，不能从归档或任意 `--report-out` 文件加载后直接获得资格。

该适配仍有明确缺口：dry-run 丢弃内存中的最终 payload，没有返回其字节或完整摘要；现有 `produceBinary` 额外检查 `reconstructed == actualPayload`，报告重建不能一般性地替代该检查。如果 patcher 在 records 之外修改 buffer，单靠报告无法观察。旧 v8 无 producer-only 输出协议。因此在证明冻结旧实现的完整 record-only 输出合同或取得真实最终 payload 之前，该适配只能提供报告重算证据，不能无条件构造等价 `ProducedBinary`。初版可明确拒绝旧 v8 回退资格，不能把备份或归档 proof 填充成旧 producer 资格。

未来新 Bundle 应声明只产生 kernel 的 sealed producer 协议，接收精确原件摘要、版本上下文和冻结计划，输出实际最终 payload、完整 report、原件/元数据摘要。父进程在 Store callback 内等待子进程结束，独立验证 ordered records 重建与实际 payload 相等，再构造本次作用域资格。当前执行者与目标 producer 相同时，可直接复用现有 `Session.produceBinary`，无需旧 CLI 报告适配。这使未来 v9 同 producer 不同计划的真实回退成为最小验收路径；以后跨 Bundle 的回退目标必须支持该协议或经过独立验证的严格旧版本 Adapter。

发布过程在当前磁盘候选上只打开唯一 Preboot kernelcache 进行写入。元数据取自可信目标 generation 原件，禁止从已经损坏的目标现状推定 PAYP/description。保留当前目标 IMG4 的 IM4M/IM4R 原字节；历史 IM4M 只能作为比较证据，不能替换当前启动链的清单。验证目标完整 IM4P、payload、所有 effect、内核共享区域与当前安装 DSC，完成卸载后再次只读验证。新事务只发布 installed kernel receipt、kernel 来源和必要 proof；host、guestEnvironment、bootChain 来源保持本次开始时的值。若当前 IM4M/DSC 不兼容目标，拒绝；保留 IM4M 字节不等于验证签名或启动通过。

| 实验设置或问题 | 必须验证的结果 |
| --- | --- |
| 已提交并启动后，当前磁盘正常变化 | 允许以此当前磁盘创建候选；不要求整盘等于旧 receipt |
| 伪造历史 UUID、跨 VM/generation、未提交事务 | 拒绝，不改变磁盘或来源 |
| 归档所有摘要被同时重写 | 仍需 producer 重算；不能从自洽 JSON 获得资格 |
| Store 版本缺失、签名/资源变化、实际执行者不符、callback 过期 | 拒绝；保留 Store → VM → worker 顺序 |
| 目标计划不同于当前 desired | 仅内核选择差异允许；当前 desired CAS 不变，目标计划单独验证 |
| 目标必需声明缺失、未知 record、non-kernel record、错误 ordered original bytes | 拒绝；不使用任意 record 回放作为 producer |
| PAYP/description 缺失、未知或不一致压缩信息 | 拒绝；保持当前保留策略及完整 IM4P 读回 |
| 当前 IM4M/DSC 与目标不兼容 | 候选提交前拒绝；不退回历史 System 或清单 |
| 预览后 binding/desired/原件/当前磁盘/目标证据改变 | CAS 或资格复核拒绝 |
| 本次 rollback 的正向写入、metadata、commit、archive 中断 | 复用事务故障矩阵；未提交时恢复到本次回退开始状态，提交后恢复只做归档 |
| 同 producer 同 payload 的目标 | 明确显示内容未变；不计不同 payload 回退通过 |
| 同 producer 不同已提交计划、不同 payload | 完成两次实际启动和回退启动；核对目标 UUID、计划、payload、metadata、kernel 来源与新事务 |
| 不支持 producer-only 的旧 v8 | 明确报告资格缺口；不回退到 v7 缺 PAYP 容器 |

真实数据保留验收在首次启动通过后进行，不能现在执行。先由正式 guest shell 写入唯一 `/private/var/tmp/task8-kernel-rollback-<uuid>` 小文本，记录内容 SHA-256、当前 VM PID/instance_id、guest shell 返回和当时 kernel/计划/来源。正式停止 VM，记录回退前当前磁盘状态，再执行公开回退。回退后使用已授权第四版 VM 重新启动，取得新的 VM 实例信息，读取同一路径并核对文本 SHA-256，同时读取 guest 信息、目标内核和四层来源。实例应匹配本次重新启动的控制目标，不能把第一次启动的缓存回执当作证据。marker 保留证明这项启动后写入未丢失；它不单独证明整个 guest 文件系统均未变化。

验收结论分开记录：目标资格、离线事务提交、启动、不同 payload 回退、marker 保留。需要额外保存回退前后关键 guest 文件与非内核来源、ROM/config/SEP 等宿主文件的比较。正式候选只修改 Preboot 内核，但 APFS 元数据会相应变化，不能用“整盘只出现内核字节差异”替代文件级范围证明。内核 payload 相同或仅 origin 变化不满足不同内核内容回退的验收条件。

风险与待确认事项为：旧 v8 报告适配的实际输出缺口；跨计划 receipt/desired 双摘要的 schema 4 精确编码；当前 IM4M 在另一 payload 下的实际启动适用性；有效且安全的不同 payload 计划组合；历史小型 kernel 产物的持久化格式。未来事务宜另存完整已验证 kernel IM4P 并由 proof 引用摘要，以免为读取旧目标反复挂载整盘归档；该文件仍是证据，不能代替可信 producer。跨 catalog/generation 的回退与旧版本兼容扩展后续单独设计。

本草案依据：`FirmwareInstalledOrigin.swift` 的 Store/实际执行者检查和完整重构检查；`FirmwarePipeline.swift:299–319, 464–557, 701–718` 的 dry-run 与 producer 路径；`StructuredPatcher.swift:48–137` 的 step/record 执行；`VPhoneFWCLI.swift:119–226` 的公开 patch 参数；`FirmwareTransaction.swift:114–185, 338–374` 的提交资格与 desired 检查；`FirmwareComponentReceipt.swift` 的已提交 reader；`container-format/`、`payp-preservation/` 与 v7 提交证据。未把恢复成功或纯文件修复写成真实回退已验收。

## 2026-10-14 首版实现合同

首版公开入口和 schema4 双计划合同已实现，详见 `kernel-rollback/implementation.md`。同 producer 指实际 Session executable SHA-256 与历史 proof 一致；非内核选择、generation、catalog 和版本上下文必须保持。`--list` 的 eligible 只表示历史选择检查通过，输出 `eligibilityScope=historical-selection-only; publication requires fresh verified producer`，不是发布权限。

新正常更新保存完整 `installed-kernel.im4p`、实际 producer 代码/输入/payload/IM4P 摘要和当前 IMG4 envelope 摘要。回退必须 fresh produce，并匹配目标完整 IM4P；旧 v8 缺少此证据合同仍拒绝。当前 envelope 在 candidate/published readback 均重验，不替换历史清单；签名及实际启动适用性继续按真实验收边界陈述。

已验证的公开不同计划候选为 EXP `forceExcGuard=false/true`。同一 pristine 输入 `b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac` 的实际产物分别为 `d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb` 与 `a89e2e786dc61d93b14ea129072bc762594ca4cd1f54719810ea1cbf99c0e2c0`；完整必需声明、ordered records 重建与实际输出相等，两者当前 DSC 校验通过。两产物尚未完成 V9 正式 A/B 更新、启动和公开回退验收。真实 marker 验收要求保持，不能用同 payload metadata 修复代替不同 payload 回退。
