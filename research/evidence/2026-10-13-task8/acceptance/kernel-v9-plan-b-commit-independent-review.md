# 第九版计划 B 正式提交与实际读回独立审查

结论：B 的正式不同 payload 离线更新与实际只读读回通过。事务 `2901d975-2379-4b50-9340-8580786aacc1`，schema3/kernelOnly/committed，forward49/49、pending=false。固定 V9 update-kernel 命令退出0，3389.396429 秒；实际 generic readback 退出0，110.513448 秒。B 启动、marker 和提交后回退仍待验收。

committed journal/receipt/proof/report 原始摘要与事务关系一致，report/receipt/proof 与此前候选逐字节相同。此次实际读回另核对当前 Disk/Preboot，actual proof/receipt 与 committed 副本一致；不以 candidate 或 receipt.state 字段替代正式提交。读回工具仍为已审 SHA6ec114…576af6，11 条外部命令均0，passed=true，无 task8 附件与两个 pending。

| 对象 | A | B |
| --- | --- | --- |
| payload SHA | `d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb` | `a89e2e786dc61d93b14ea129072bc762594ca4cd1f54719810ea1cbf99c0e2c0` |
| 完整 IM4P SHA | `b1f07780484d9dc88f989d6e236049050b38e50a1ddb94030dcecaed43f962db` | `ecbea551116fbb2d10b0196d72ecd7f52f8f145b5ecd7632159c0025fb78bf98` |
| 完整 IMG4 SHA | `5b90c5a0ee87bf810c7e90795d537265f39774fbf85c430263fd2f61fc41ce7a` | `744be24ed1b2d636a7746f3ed6b2d4bb062c1f5b363d0b7acf1cec3c45e8a315` |

实际 B IM4P 等于冻结 candidate artifact SHA，actual payload 等于 proof 及此前独立 pristine+120 条有序记录的完整重建结果。A/B 使用同 V9 executable SHA `e1c6ca75c19966ec8bcada05ca235c1e5019c572570b64e8ebed041f0d14da76`、同输入 b7fa45…和 generation；payload/完整 IM4P/IMG4 均不同。raw description、PAYP、IM4M 和 envelope 与 A 保持，envelope 为 `32670de0eb0e52a18645867eaa681af0c130cece11fcad590f755bdd80135c88`，与 proof 相等。

当前 Disk 从 A 启动后的 snapshot `d5e5d1163260d7d774da5069f1b3ea697a309e44e609011b667a092d13351355` 变为 `df1f5f4f8dc909d62b5c1585f2a369c415b3243d54cffa62054d7a26593f5bd1`。后者等于 journal candidate/proof image/receipt 唯一输出及 readonly 后整盘 SHA。六文件 offline identity 保持，其他五文件完整 SHA 保持；current desired B3ad404…、planbb37…及120 effects 与 frozen expectations/report/known true pair 一致。

host/kernel 版本在 B 更新前后均为 V9；不同内容由实际 payload、proof 和 receipt 建立，不能只看版本字符串。journal 的原 binding/receipt SHA 与 before 相符，非内核来源保持。DSC 由本次生产 commit callback 建立；generic readback 不独立重跑 DSC，先前 true-plan/current-System DSC 证据按精确摘要关联。envelope 保持不等于签名或启动适用性验证。

本审查只读取 E 冻结文件，未读取当前 VM/Disk，未操作 VM、挂载、guest、AMFI 或进程，未改生产或执行 build/test。下一步仍需正式 host4、授权 V4 B 启动和 marker 写入，之后公开明确 UUID 回退 A、实际读回及新实例 marker 保持。完整输入摘要见同名 JSON。
