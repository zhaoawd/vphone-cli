# B26 T24 只读诊断结果

B25最终VM的执行失败已取得精确AMFI证据。2026-10-09 18:04:44.836770原VM和18:04:44.854027资源副本VM均被amfid记录 `AppleMobileFileIntegrityError -424: The file is adhoc signed but contains restricted entitlements`。原VM、Launchpad内嵌VM和B25最终snapshot的SHA256均为 `0dfa9ca618e10ce81fdbed8bbf428c78af1fc9457cb281bf361f2dc5a71d0034`，CDHash为 `77b509d8ce341c832d54c827f0a48b724791342e`。严格静态签名检查退出0。

该证据确认AMFI拒绝了ad hoc签名与restricted entitlements的组合。没有逐项删除entitlement进行实验，具体哪项触发拒绝的原因未查明。B25只记录数值9，未记录terminationReason，不能只由数值9判定SIGKILL。debug VM只有get-task-allow，不能用debug的--help通过替代最终VM验收。同期CLI -423日志伴随resources退出0，不能表述为CLI无法执行。

历史v1 helper摘要保持 `bbc0917c2d5551de48b2eff7db8396c1c1d9a7d62f48eecdacf66a82da48b3c4`；Team为空、ad hoc、配置检查退出78。系统job查询113且安装路径不存在。该实物当前不能注册，真实XPC六行拒绝矩阵仍未验收。B24受控protocol-v1服务结果不能替代历史实物。

最小下一步是由父任务处理当前CDHash的受控运行前提，再仅复验最终VM --help并保全terminationReason及精确日志。真实TCC两条路线还需要VM正常启动、GUI解锁、可信绑定及实际权限动作授权。继续使用不记录坐标的既有验收步骤；已有允许状态不能证明首次提示或拒绝行为。

本子任务只写 `/private/tmp/vphone-b26-t24/`。没有启动VM、使用UI、运行SwiftPM、注册服务、重签app或修改AMFI/TCC。完整矩阵和证据索引见summary.json。
