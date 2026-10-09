# T46 transport 与 T24 legacy v1 准备

现有 `OutputXPCTests` 使用真实匿名 NSXPC，但两端位于同一测试进程，listener 直接接受连接，verify 注入 Data；它没有证明两进程、生产签名身份或 root Mach service。现有默认30秒测试直接调用 `VPhoneHelperOutputAcknowledgement.wait()`，没有通过 NSXPC。`fail("writer failed")` 验证失败状态不可被晚到 ACK 覆盖，不是实际 FileHandle 写入失败。

已准备 `TransportHarness.swift`，暂未编译、签名或执行。它导入生产模块并调用实际 `VPhoneHelperService.verifyBundleStreaming`、`VPhoneHelperOutputChannel`、默认30秒 `VPhoneHelperOutputAcknowledgement`、`VPhoneHelperOutputReceiver`、`VPhoneLogWriter` 和 `VPhoneHelperReply`。fixture仅提供只读verify返回值，并拒绝authorize/install。没有复制或修改生产ACK状态机。

临时app内嵌 application-scoped XPCService；两端均以Apple Development证书正常签名，使用独立的transport标识符和生产格式的 `anchor apple generic + identifier + OU=3AA3QL69MQ` 要求。listener调用生产 `callerRejection` 校验真实auditToken，并设置逐消息签名要求；client设置server签名要求。两端静态签名与peer PID须记录。身份失败必须拒绝，不允许跳过校验。

| 实验设置 | 生产链 | 预期结果 |
| --- | --- | --- |
| 正常ACK | service→channel→receiver→writer.finish→ACK→reply | 完整两行尾部；成功仅在writer异步finish后返回 |
| 无ACK | 实际receiver完成后保留真实XPC reply且不调用 | 生产默认30秒后返回未确认错误，不能返回成功 |
| XPC断线 | 实际receiver完成后invalidate同一连接，不回复ACK | 连接错误；不能返回成功 |
| 实际写失败 | 生产writer的package initializer注入只读FileHandle | 真实I/O错误传播为负ACK/操作失败；预存文件不变 |

读取稳定debug modules必须等待T40 GREEN通知。随后只用swiftc和只读已有objects/modules输出至临时目录，不运行SwiftPM，不编辑源码。编译后保全源码与objects摘要，正常同团队签名app/XPCService，记录readback。执行每行使用独立新目录、UUID及固定可比较尾部。结束后核验临时client/service均无残留。出现钥匙串提示时报告，不绕过。

该harness不经过 `VPhoneHelperClient.request` 的固定 `NSXPCConnection(machServiceName: com.vphone.cli.helper, options: .privileged)`，也不经过 `VPhoneHelperDaemon.run` 的root检查、授权项注册、真实store或系统安装。它补充真实两进程生产输出链故障证据，不能替代系统helper完整验收。匿名endpoint的SDK合同只支持通过已有连接发送endpoint，本方案不把endpoint归档到普通文件来宣称跨进程。

## 历史v1候选

原未配置adhoc实物保持不变，配置退出78；本次没有构建或注册。拟冻结历史源码 `dd3c800277605589ae1cb2466a2b33fa33e549d1`（protocol2引入前提交），相关blob见legacy-v1-source-manifest.json。不能据此断言该提交生成了原B13 adhoc实物。

现有效身份为Apple Development（不是Developer ID），证书SHA1为5620D69F097306848C7CCD69F0B796A3C588BF28，Team OU为3AA3QL69MQ，有效期至2027-02-18。历史候选保留protocolVersion/CFBundleVersion=1与原生产listener、auditToken、逐消息要求、授权逻辑；仅显式配置Team和SMAuthorizedClients并正常签名。拟定plist已保存，未用于构建。

最终53580180 CLI当前是adhoc、Team未设，不能通过生产helper caller门槛。后续需要独立副本正常同团队签名，保全原文件摘要、移除签名前后主程序一致性、完整嵌套VM与资源摘要，增加与团队一致的VPhoneHelperSigningTeam和SMPrivilegedExecutables；不重签原实物。

最终客户端的 `register()` 首先用协议2的 `fromHelperInfo` 检查内嵌helper，v1会在注册前拒绝，不能用该verb安装v1。实际v1 daemon启动还将写管理员授权项且要求root，属于必须单独审查的系统变更。只有确实需要填补生产历史listener身份与协议协商证据时才准备重建候选并取得具体SHA/CDHash；不要重复已有B24受控v1矩阵作为新验收。

后续六行仍为verify/install × 无日志/新日志/已有日志，所有身份校验开启。每行应在version=1时明确协议拒绝，不能进入authorize/install/verify或打开新日志；新日志缺失，已有文件摘要/权限不变。若进行此实验，服务/授权项/文件恢复必须按具体候选和基线核验。结果必须命名为历史源码重建签名候选，不能命名为原历史实物。
