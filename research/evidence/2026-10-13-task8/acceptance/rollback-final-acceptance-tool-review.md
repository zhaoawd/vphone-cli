# 回退最终验收与启动清理工具独立审查

结论：F1 及两项关联建议已修正，两工具当前未发现阻断项，可用于限定范围的最终验收取证。两工具尚未执行。本审查仅解析源码、AST 与已有证据字段，不读取正在变化的 VM，不操作 VM、guest、挂载、AMFI 或进程。

最终汇总使用 command_matches 逐项比较完整 argv：离线 prefix 固定 sudo/-n/env 及两个项目环境项，唯一固定 Store V9 CLI；A/B 为 update-kernel，R 为 rollback-kernel 且 --to-transaction 等于实际 A UUID，精确 library-root，无额外 list/preview/recover。V4 launch/headless 与 stop 亦要求完整 argv 相等。marker create/read expected 分别等于 B/R boot.expected；R boot-expectations 必填 desired_sha256==B receipt.desiredSHA256，cleanup 会据此核对当前实际 desired 保持。

已有汇总关系合理：receipt 原始文件 SHA 将 boot expectation 与实际 publication 关联；installed receipt 与 readback 一致；三事务与三实例不同；A/B 实际 payload 不同，R payload/完整 IM4P/IMG4 等于 A；envelope 相同；实际结果与两计划 DSC 证据的 known A/B payload、IM4P、plan 相符。schema4 目标 UUID、目标 receipt A 与 live desired B 分别关联，B 启动后当前 Disk 摘要必须变化。marker 字节摘要与 B/R 启动目标、新实例关系检查存在。

cleanup 对 VM/source 取得目录排他锁，固定六文件集合。source 比较 dev/inode/size/mtime/ctime；target 比较 dev/inode/size，并计算 config/两 ROM 的实际 SHA。进程检查按 task8 VM 命令和固定 scoped-amfi-v4 脚本路径识别，不使用旧裸 PID。两个 pending 与全部 task8 附件须为空，binding/receipt/可选 desired 保持。输出独占创建；异常不会生成 passed=true。

证据范围：source 仅 metadata，无新全量内容摘要；target Disk/NVRAM/SEP 允许正常启动变化。固定 driver 路径进程缺失不代表所有可能 debugger/系统进程均缺失。最终汇总依赖已审查的子工具和 root 冻结证据，不替代真实发布、物理读回或 guest 执行。marker 保持只证明该项数据保持。

审查摘要：

- `cleanup-kernel-boot.py`：`4bc39effe61cb6fa5fa10158f9efb1ec0e881b40cbac5ed2d76f73e42b4b1b61`。
- `verify-rollback-acceptance.py`：`cdcbac696c9d44ed5bc9590c7e2048dec51b3a8cdd4d48e70f767207b3e55034`。

## V2：保留 B 首次失败并关联补充观察

静态终审无阻断，未执行最终 join，R 尚未实际执行。V1 SHA `cdcbac696c9d44ed5bc9590c7e2048dec51b3a8cdd4d48e70f767207b3e55034` 保持；V2 SHA `93d1c1a6f7231724a4b1bc6f93cdcf2321437cab0f403c2c33e53f0f8ecbf179`，AST 通过。

V2 保持 operation/readback/committed/launch/stop 使用 A/B/R 原 label，仅 B boot/expectations/cleanup/marker-create 映射到 B-resumed，并将映射写入结果。原 B watch 必须 passed=false，expected 对象与成功补充观察相同；original/resumed expectation 的原始 SHA 及原失败 watch 的记录 SHA 必须相等。既有精确命令、receipt原SHA、三TX/instance、实际 payload/IM4P/IMG4/envelope、schema4/dual desired、marker 内容/目标关联断言保持。

恢复断言限定本次冻结 B 记录：仅SIGCONT95240；UID0/PPID1/path/start 精确相同，native state4/xstatus17→state2，flags trace bit2 为0。该硬编码不是通用恢复协议，不验证任何未来 R 的实时状态。B 初次失败、host wait、恢复范围依据已经独立审查的冻结证据；V2不重新查询daemon，也不确定detach后native state异常的原因。未来R若需要恢复须单独记录与审核。

V2 使用新的独占输出文件，不覆盖 V1 或原 B 失败。当前 R 提交/读回/启动/marker 保持仍待实际执行，不能从本次工具审查建立最终验收完成结论。
