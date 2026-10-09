# B26 T46 transport 结果

四行均使用临时app内嵌XPCService和真实不同PID，直接链接冻结的生产Service/Output/Writer/Reply；没有重写ACK状态机。双方正常Apple Development签名与严格要求通过，listener保留真实auditToken检查及逐消息要求，client保留server要求。

| 实验设置 | 结果 | 操作耗时 | 日志 |
| --- | --- | --- | --- |
| 正常ACK | receiver完成后返回成功 | 0.001303秒 | 两行75字节，0600，尾部精确一致 |
| 无ACK | 实际receiver持久化成功；生产默认30秒后返回明确未确认错误 | 30.012642秒 | 75字节/0600，文件完整不使操作成功 |
| XPC断线 | receiver完成后connection invalidated；返回Transport invalidated | 0.001547秒 | 75字节/0600；没有等待40秒客户端超时 |
| 只读FD写失败 | receiver负ACK；生产writer存储NSError为Cocoa512/底层POSIX9(EBADF)；操作明确未确认 | 0.006223秒 | 原10字节/0600文件与摘要保持 |

前3行日志SHA256为1749b7f2d93fdf4347756908497e12f37eb6605fc6abadea5386af8cfe1e4c89；写失败原文件SHA256为7ee0e7f63b9b65e302add82986c18196ecb8da0121575e4733219572eeac2712。每行harness退出0，故障行操作结果均为failure；判定还检查具体事件、错误与时间边界，未以exit0或任意failure替代故障验收。

本轮不经过生产Client.request的固定privileged Mach入口、root daemon注册或真实store。verify结果为只读fixture，authorize/install明确拒绝。独立拒绝身份运行行尚未执行。历史未配置v1实物未修改；重建方案仅prepared_not_executed。

首次framework签名失败、-R参数失败与两次harness断线SIGTRAP均保留。最终仅对临时Foundation proxy error回调显式@Sendable，没有关闭actor检查或修改生产实现。最终client/service移除签名后字节完全一致；与swiftc原输出的差异仅为__LINKEDIT.vmsize字段，其余字节一致。原始摘要及字段值已保全。

精确核验本轮20个client/service PID，均无残留，没有发送终止信号。完整结果见summary.json，冻结对象/框架输入见stable-input-manifest-final.json。
