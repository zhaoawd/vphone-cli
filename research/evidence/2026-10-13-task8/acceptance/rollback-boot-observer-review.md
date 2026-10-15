# 回退验收公共启动观察工具独立审查

日期：2026-10-14。审查者：acceptance_audit。只读审查 watch-boot-v4-rollback-acceptance.py；未执行脚本、VM、guest 查询、挂载或 AMFI 操作。

最新结论：独占创建修正已完成，最终版本未发现阻断问题，可用于本次限定 A/B/rollback 的单次启动观察。此工具只证明单次目标实例的启动查询，不单独证明不同 payload 或回退目标已运行。

## 已核对的正确范围

- label 仅允许小写字母/数字/连字符，期待文件位于固定证据目录；CLI、VM binary、task8-copy 和 library root 均固定为授权第四版路径。
- 开始和成功结束均检查完整 binding 值/原字节 SHA、receipt SHA、无 pending 和期待文件原字节未变。
- capabilities 必须外层退出 0、ok=true、boot_mode=normal、guest_connected=true、shell=true。PID 为严格正 int，VM 名称精确匹配，instance 存在且同轮保持完整 target 一致。
- 每轮核对实际 ps argv 的第四版 VM 路径、固定 config、同 binding SHA、--no-vphoned-update，拒绝 --no-vphoned；成功前再核对进程。
- shell 使用已证实的 /var/jb 绝对路径，携带完整 target。host executor 在执行前拒绝 target_mismatch。外层退出 0、ok=true、code 严格 int 0、无超时/截断及三项系统输出标记才通过。
- 错误、超时、实例改变和输入改变不取得 passed；观察记录逐次保存。

## 执行前最小修正

初版 out 先 exists 检查、最后 write_text，不是独占发布。同 label 并发时，第二进程 observations.open('x') 失败后仍进入 finally 写 out，可能与第一进程覆盖最终证据。应以独占方式创建最终 out，且没有取得 observations 创建权的进程不发布该轮结果。一般已有证据拒绝覆盖的意图正确，需要避免这一异常分支。

三次 A/B/rollback 启动还应在联合验收中检查实例 ID 分别属于对应正式 launch，且实际重新启动；该工具只检查一轮内部 target 稳定。不同 receipt/事务、离线 installed IM4P/payload 读回和三次 launch 日志由外层验收关联。不得仅凭此脚本通过就计为不同 payload 回退。运行期间不重算整盘历史 receipt SHA，避免将正常 guest 写入误判为提交失败。

首版审查 SHA：`1e234a61543762f952657bf5cc0ec540824e8a1cfc6888f28a3e469b068e9d04`。根任务负责修正；本审查不修改脚本。

## 最终版本复核

最终脚本只有在 observations.open('x') 成功后才以 out.open('x') 预留最终结果文件，finally 仅写本进程已取得的 handle。未取得观察文件或结果文件创建权的进程不能覆盖已有结果。原先同 label 并发的覆盖分支已消除；失败证据需用新 label 保留，不能覆盖原记录。

最终 SHA：`5036b2e20ba2f5a0f5928c6decdc3746a23ca72738d58f7ec6872e4acb2a2a0f`，与根任务冻结值一致。未执行脚本。kernel-rollback-acceptance-plan.md 明确将三次实例、对应事务/计划、实测不同 payload 和 marker 作为联合验收，不将单次 observer passed 代替全部回退结果；该范围与本工具职责一致。
