# 同 daemon SIGCONT 恢复 helper 独立审查

结论：修正 TRACE 常量后的 helper 未发现阻断，可用于已有固定 V4 driver 证据限定的同 daemon 状态恢复。helper SHA 为 `527a804644b4db0873996179bbf4c255db94df750834422b713da30e336d0eae`，mock SHA 为 `7f3a919c43424bd292eaa84eefbfa05a352bd098ef2f835f8fd1617e74cddcd6`。F99 driver SHA 不变。审查未调用真实 PID API、信号、attach、VM 或挂载；独立12项纯mock全部通过（0.018秒），仅普通临时文件 metadata 使用 fgetattrlist。

本机 SDK sys/proc_info.h 明确 PROC_FLAG_TRACED=2、PROC_PIDTBSDINFO=3；ctypes proc_bsdinfo 大小136，flags/state/xstatus/PID/PPID/UID offsets 为0/4/8/12/16/20，start秒/微秒为120/128，与头文件一致。旧0x800是该接口的其他标志，不能用于TRACE。独立literal2负例存在；controlled mutant改回0x800时三个选中负例失败，真实PID/信号接口未执行。

资格限定为：root；固定F99/runtime源码摘要；固定 driverwrapper exactargv/result/log；单一READY PID；精确V4单CDHash、paths=[]、allow_all=false、无持久config；两个匹配hook return1；已有stopped状态下DeleteAllBP/DetachFalse/CLEANUP_DONE。普通证据文件有NOFOLLOW、nlink1、size上限、字节/身份/时间/birth复核，JSON拒绝重复字段及NaN。

native身份须为该READY PID、/usr/libexec/amfid、UID0、PPID1。正确时间方向为 **daemon start_ns <= 原始 driver log birth_ns**，以拒绝log创建后重用PID的新daemon；不允许反向比较。每次 native观察对 info/path/info 身份及TRACE bit2复核，全部证据再次读取后还做最后一次身份/状态检查。

SRUN2时不发信号。只有SSTOP4且xstatus=SIGSTOP17时发至多一次SIGCONT；没有Stop、debugger/attach、kill终止、新allowlist/hash或持久配置操作。最多20次读回、每轮0.05秒，要求同身份且SRUN2，否则失败，不重复信号。结果区分attempted/sent，既有输出独占拒绝在任何action前发生，失败记录passed=false并返回非0。

mock覆盖资格/文件/JSON/wrapper/scope/hook/cleanup失败、非root、TRACE、PID/path/start/state变化、消失、already-running、信号异常、读回仍停止、有界等待和输出不覆盖；nativeDLL与os.kill均替代。结果不建立真实恢复或启动成功。观察与按PID发送信号是分别的系统调用，不能宣称原子进程句柄保证。SRUN2也不表示正在消耗CPU或host preflight/VM已成功。此前DetachFalse后native停止原因未查明，F99/V9生产不变。完整输入摘要见同名JSON。
