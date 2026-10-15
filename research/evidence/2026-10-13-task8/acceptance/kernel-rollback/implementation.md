# Task 8 提交后内核回退实现

范围：同一稳定 VM 身份、generation、当前声明 catalog、固件版本上下文和可信 producer executable。公开入口为 `vm rollback-kernel NAME --list`、`--to-transaction UUID --preview`、`--to-transaction UUID`。list/preview 只检查历史选择数据；publish 重新取得 Store → VM → worker 资格。旧 v8 缺少本次证据合同，跨 Bundle producer 尚未支持；历史备份或 origin 字符串不取得发布权限。

`FirmwareKernelRollbackSelection` 是 schema4 的类型化字段：目标 UUID、目标历史证据摘要、完整 `targetDesired`、目标 payload/IM4P 摘要、producer 版本/代码摘要、`liveDesiredSHA256` 和 `bindingSHA256`。journal 的 plan 和 options.desiredSHA256 指向实际执行的历史目标；live desired 单独作 CAS 条件。receipt 指向实际目标计划，proof 同时记录目标、live desired 和 binding CAS。`verifyOrigin` 把 binding CAS 与实际 Store/VM callback 的 expected snapshot 关联。普通 schema3 保持原 desired 相等校验。

统一 selection 校验用于 prepare、shared publisher 的预检查、实际 produceBinary 和事务的各执行/提交校验点。它验证当前 catalog、generation 原件、版本 gate、非内核选中/排除集合以及 live desired CAS，并重读目标 journal/report/publication/proof/IM4P 的完整关系。该过程重复计算 generation 原件摘要；正式回退耗时尚未测量，本实现没有缓存资格或省略校验。

历史 reader 不要求当前 Disk.img 等于历史整盘摘要。它只接受普通目录和无额外硬链接的普通证据文件、已提交的 kernel journal、完整 report、相匹配的 receipt/proof 和小型 `installed-kernel.im4p`。新正常更新和回退均保存完整 IM4P。历史数据本身不构造 Session 或 InstalledOrigin。发布仍重新调用当前可信 producer，从 pristine 原件按 ordered records 独立重建，并要求重建等于实际最终 payload，完整 kernel Gate 通过，最终 payload 和源元数据重封装的完整 IM4P 均等于历史预期摘要。

回退复用正常更新的 publisher：克隆回退开始时的当前磁盘，只改唯一 Preboot 内核；元数据取自目标可信 generation 原件，保留原 description/PAYP，保留当前 IMG4 的 IM4M/IM4R 原字节。candidate/published callback 核对当前 envelope 原字节、完整 IM4P、payload、全部 effect 和当前 DSC，卸载后继续校验。envelope 保留检查不建立 IM4M 签名有效性或启动适用性结论。

新事务使用现有逐块 Disk 发布和 durable cursor，保持 Disk.img 身份。回退自身未提交时，恢复到本次回退开始前 Disk/binding/receipt；已提交事务恢复仅校验并归档。恢复不重跑 producer，也不把历史 desired 写回当前 desired。未知外部磁盘改动继续拒绝恢复并保留 pending。

launcher 仅在已验证 Bundle 声明 `VPhoneKernelRollbackProtocol=vphone.kernel-rollback.v1` 时将该路由交给实际 Store CLI。该 marker 是公开路由能力声明，本轮没有实现跨 Bundle 子进程 producer 协议。

测试使用同一 publisher 和 Session/transaction 逻辑。内部 Operations 仅替代合成 patch 算法、shared-region 揭示及挂载系统适配；真实输入重建、声明、容器处理、DSC 读取、Disk 逐块发布、origin、receipt 和恢复继续走生产代码。真实 EXP 两计划测试单独调用实际 producer，对已导出且摘要匹配的 pristine 输入证明实际 payload 差异。根任务独立只读挂载测试副本 System 后，用同一纯文件测试核验两产物 DSC；该证据不建立真实回退或启动通过。
