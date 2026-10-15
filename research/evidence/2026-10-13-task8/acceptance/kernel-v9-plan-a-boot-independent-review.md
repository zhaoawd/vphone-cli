# 第九版计划 A / 第四版 VM 启动独立审查

结论：计划 A 的实际 V4 正常 guest 启动、绝对路径状态命令、正式停止和清理证据通过。A payload 仍为 d2b901…，本结论不包含不同 payload B 或提交后回退验收。审查仅解析 E 中冻结文件与工具源码，未读取 VM/进程实时状态，未操作 VM、挂载、guest、AMFI，未改生产或执行 build/test。

实际 V4 VM PID 为 14713，instance 为 `BF494884-1005-4FDB-8504-C14DA034354D`，目标 task8-copy。argv 为固定 V4 binary、精确 config、--no-vphoned-update、binding SHA `dc0875196f34361bec07f278cded496c32d14f2cb60419044aafc5dfc5fb555d` 与 headless。冻结 receipt SHA `e59819c579c3f958227a76c5d7fa5397134e01fb95937ea17a330c23bbc47169` 与实际 A publication 相同，事务 UUID、payload、desired A 与 A readback 一致。

capabilities 在 60.517 秒返回 normal / guest_connected / shell；同实例的绝对路径 uname/sysctl 返回 outer exit0、ok=true、code=0，无超时或截断，输出 Darwin 25.1.0 / iPhone17,3。watch 65.504 秒完成并通过。正式 launch 和 stop wrapper 的固定 V4 argv 及退出 0 均核对；stop 7.015676 秒，launch 至停止 122.389389 秒。日志记录同 PID/instance、guest power-off、classicAccepted 和 Guest stopped。

post-boot cleanup passed=true：无目标 VM/固定 driver 路径进程、无 task8 附件和两个 pending；binding/receipt/desired A 保持。源六文件 dev/inode/size/mtime/ctime 与 clone 基线一致；测试副本六文件 dev/inode/size 保持，config/两 ROM 的实际 SHA 与初始 baseline 一致。该记录没有重新计算源完整内容 SHA，也不要求启动后的 Disk/NVRAM/SEP 内容保持不变。

## 绑定 owner、列表与临时 driver

owner 修复工具限定固定副本，要求 passed 的正式 rebind 记录、目录排他锁、无 VM/附件/pending、固定 VM/config owner。binding 经 O_NOFOLLOW 打开，必须普通文件、nlink1、root:wheel0600 和精确 raw SHA；仅通过该 fd fchown。实际 UID 从 0 变 2035870432，GID0、0600、inode589376505 与内容摘要保持。源码检查 descriptor 与 named dev/inode/size/mtime/mode/nlink 一致。此前读取冻结期望遇到 PermissionError 的背景与该精确修复分别记录；不将其解释为 preflight -9 的原因。

公开 V9 rollback-kernel --list --json 退出 0，共 12 个目标。A 的 UUID、producer 代码/版本、plan、payload 和完整 IM4P 与已审查 commit 相符，eligible 范围明确为 historical-selection-only。V8 返回缺少支持的 rollback evidence protocol；该列表不提供发布权限，也不是回退完成证据。

本次 once driver 源码 SHA 仍为此前审查的 f99f3c…c219，实际退出 0，24.986775 秒。allowlist 仅含 V4 CDHash `43c00d51b4c7f07a5feba006f3c244edbac39cea`，paths=[]、allow_all=false、无 persistent_config。日志显示两条该 CDHash 的 validate/isApple hook 各自 return1；另一个 eba1… CDHash 的两条观察无 override 记录，日志明确 not patched。两匹配 hook 完成后在已有 stopped state5 删除断点成功，Detach(False) 成功，Destroy 后 CLEANUP_DONE；源码未增加 Stop 或外部 pause。实际目标 VM 由 root 调度的 launch argv 关联，AMFI hook 本身只匹配 binary CDHash。

V4 --help preflight 的 exit -9、0.005263 秒失败仍保留，原因未查明。owner 修复、临时 driver 和随后启动成功不能单独确定该失败原因。后续仍需不同 payload B 的正式提交/启动、明确 UUID 回退 A、回退新实例及 marker 保持证据。全部输入摘要与范围见同名 JSON。
