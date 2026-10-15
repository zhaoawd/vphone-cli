# 第九版计划 A 提交独立审查

结论：计划 A 的离线正式提交与独立只读读回证据通过。事务为 `c0a0a7a8-3677-4a44-aa36-f370bb67b5ca`，schema 3，committed，正向 14/14 块、pending=false。正式固定 V9 CLI update-kernel 命令退出 0，耗时 3240.822113 秒。16 个冻结源码/测试摘要仍一致。未建立 A 启动、不同 payload 更新或提交后回退结论。

journal/receipt/proof/report 原始摘要及事务 UUID 相互对应；实际 installed receipt 与 readback 一致。冻结 operation expectations 的对象/原始摘要匹配，EXP forceExcGuard=false、plan SHA `703f9ad46613fa819ec6460846865ba9cd3ccd389f4b03c078fbc9baae741a3c`、desired A `ea1f464ba1ffb63737082879323cdac4a1efc8b40aa30e7ee7e505606a7fac34` 与操作前快照一致。

119 条 report 有序记录与 receipt effects 完全相等。审查者另对已导出的 pristine IM4P 做纯文件解码，逐条检查当前 original 字节并应用记录，重建 payload SHA 为 `d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb`，等于 proof 与实际 Preboot 读回。按 source raw description/PAYP 重新编码的完整 IM4P SHA 为 `b1f07780484d9dc88f989d6e236049050b38e50a1ddb94030dcecaed43f962db`，也与实际读回一致。

实际完整 IMG4 SHA 为 `5b90c5a0ee87bf810c7e90795d537265f39774fbf85c430263fd2f61fc41ce7a`，等于经过摘要固定的 baseline。raw envelope SHA `32670de0eb0e52a18645867eaa681af0c130cece11fcad590f755bdd80135c88` 与 proof 相同；IM4M SHA `ec08fc625f7f8b76861b93fb9a950022103fe4031ead235f64daad1df8c4c657`、原 description `KernelManagement_host-487.0.4` 和 PAYP 保持。纯文件重算不执行 producer、挂载或测试。

Disk 从 `c8d26177b43ed535ca4db2dae178f3fe5f300f2acf5292e484fbff104b84c7d4` 变为 `3f2860e4917024ab81d39a36d25831573318eadaf8da8e3745e1aa057763d783`。后者等于 journal candidate、proof image、receipt 唯一输出和 readonly 后整盘摘要。六文件 device/inode/size 在已审查工具中核对保持，记录 inode 与 before 一致；其他五文件完整 SHA 保持。host 仍 V9，kernel 从 V8 变 V9；原 binding/receipt 摘要与 journal metadata.original 对应，current desired A 保持。独立读回 11 条外部命令均退出 0，附件为空，工具同时拒绝两个 pending 标记。

本次 A 与已独立校验的纯文件 force=false pair 的 payload/IM4P/plan 摘要一致。DSC 由本次正式生产 commit 校验建立；generic readback 不独立重跑 DSC。A payload 仍与 V8/baseline 相同，14 个磁盘块变化、新事务或来源升级不构成不同 payload 验收。envelope 保持也不建立签名或启动适用性结论。

审查仅读取冻结 E 证据、源码摘要和已导出的纯文件；未读取活跃 VM，未执行 VM、挂载、guest、AMFI、Store 写入、build 或 test。后续需要正式 host 重绑 V4、授权 V4 启动 A，再完成不同 payload B、明确 UUID 回退 A 与 marker 保持验收。完整证据摘要见同名 JSON。
