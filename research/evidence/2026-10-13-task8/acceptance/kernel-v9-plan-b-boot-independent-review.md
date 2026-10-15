# 第九版计划 B / 第四版 VM 启动独立审查

结论：B 的实际 V4 guest 正常状态、唯一 marker 创建/即时读回、正式停止和清理证据通过。首次超时保留；提交后回退及 marker 保持仍待验收。operation label 为 kernel-v9-plan-b，成功补充 boot/marker/cleanup label 为 kernel-v9-plan-b-resumed。

首次 kernel-v9-plan-b-boot-watch.json 为 passed=false，361.804 秒、24 次观察、无 target。实际 V4 CLI9333 仍等待 host preflight 子进程9357→9455；sample 栈为 launch→runCapturing→NSConcreteTask.waitUntilExit。该时段没有 B guest 执行证据，不把它写为内核启动失败。原正式 launch 最终退出0、1751.059353 秒，包含 preflight 等待与后续运行，不是启动延迟。resumed watch 的0.355秒只是 guest 已可用后的补充观察耗时，也不是启动延迟。

固定 F99 once driver 退出0/24.989307秒，两个单一43c00…CDHash hook return1，DeleteAllBreakpoints、Detach(False)和 CLEANUP_DONE 日志成功。随后原生 BSDinfo 实际记录同 amfid95240 为 state4/xstatus17；root报告无TRACE，原始 flags0xa0404030 保留。该事实表明 Detach 成功日志本身不足以证明 daemon 已恢复运行。精确恢复记录仅有 SIGCONT95240；UID0/PPID1、/usr/libexec/amfid、PID与 start 时间前后完全一致，start 早于 driver log birth，state4→2。root报告该精确恢复经自动审批通过；本审查未执行信号或查询实时进程。未增加 Stop、attach、hash/allowlist 或持久配置。为何 Detach(False)后仍观测到该 native state，原因未查明；不由此推定较早 --help exit-9 的原因。

resumed expectation raw 与原文件逐字节相同，receipt518a878…、事务2901…、实际 payload a89e2e78…、desired3ad404…与 B commit/readback 关联。实际固定 V4 argv 为 task8-copy config、--no-vphoned-update、binding dc087…和 headless。PID35061、instance `CC65D525-3CE7-41F4-83A8-937095907BD7` 与 A 不同。严格 capabilities normal/guest_connected/shell 与绝对 uname/sysctl 均成功，outerexit0、ok=true、code0、无超时截断，输出 Darwin25.1.0 / iPhone17,3。

B 成功实例创建 `/private/var/tmp/task8-kernel-rollback-682d8cbe-429b-4c4a-95fb-e6dfa945aa35`，742字节。intent、实际 file_get 解码字节与记录 content 完全相同，SHA 为 `2f30a9afeae97959ee833db90f12cdd0b4c22c932257e1d8f689ce5b5958162f`。目前仅证明创建和即时读回，未证明回退后保持。

正式 V4 stop 退出0/5.777116秒，日志同实例/PID；launch 日志有 guest power-off、classicAccepted 和 Guest stopped。resumed cleanup passed=true，源六metadata/副本六身份及config/两ROM基线摘要符合，无task8 VM/driver路径进程、附件及两个pending，binding/receipt/desiredB保持。source范围仅metadata，没有新完整内容摘要，启动后Disk/NVRAM/SEP内容不作保持结论。

最终汇总需显式关联operationB与bootB-resumed，并保留旧watch失败和同daemon恢复证据。后续仍需公开UUID回退A、实际读回、第三实例启动、同marker读回与清理。审查只读E冻结文件，未读VM或实时进程、未操作AMFI/VM/guest/mount，未改生产或build/test。所有证据摘要与范围见同名JSON。
