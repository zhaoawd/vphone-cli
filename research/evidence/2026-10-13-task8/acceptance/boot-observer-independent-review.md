# 启动观察脚本独立静态审查

日期：2026-10-14。审查者：acceptance_audit。审查对象：watch-boot-v4-kernel-v8.py，SHA-256 `6cf1c9a363854b23375ef48253cbe5a82d08e9d33dfb6ecf743089048209fdd4`。仅阅读脚本及 host command/guest CLI 源码，未执行脚本、启动 VM、挂载或修改 AMFI。

结论：最终版本未发现启动 readiness 误报的阻断问题，可用于本次限定副本的只读观察。该结论是静态审查，不表示第八版实际启动已经通过。

- 命令固定为已授权第四版 CLI、task8-copy 和指定 library root；只请求 capabilities 及 uname/sysctl。
- ready 同时要求 capabilities 进程退出 0、ok=true、已验证 target、guest_connected=true、shell=true。
- target 检查 VM 名称、正 PID 和 instance ID，并要求各次 capabilities 的完整 target 一致；shell 请求携带该 target。host executor 在执行命令前检查 target，实例不符返回 target_mismatch，避免两次连接间 VM 替换导致归属错误。
- shell 通过条件要求外层退出 0、ok=true、code 类型严格为 int 且为 0、timed_out=false、truncated=false、stdout 为字符串，并含 Darwin、kern.osrelease:、hw.machine: 三项标记。stdout/code/timed_out/truncated 与 host 源码实际字段一致。
- 无连接、超时、错误 JSON、target 改变或未取得完整 shell 成功结果都不能将 passed 设为 true。最终未通过时非零退出；证据文件采用新名称且拒绝覆盖已有记录。

实际验收仍需关联本次正式 launch 的第四版可执行文件、目标 Disk/binding/receipt、PID/instance、启动日志和本脚本结果。guest shell 成功只能支持客户机已运行及运行环境查询，不能单独证明精确内核 payload、所有补丁行为或 UI 完全就绪。此前新旧 payload 相同的范围限制继续保留；提交后回退不由本脚本验收。
