# Task 8 guest marker v2 独立工具审查

日期：2026-10-14。审查者：signed_v6。结论：冻结工具及纯模拟测试未发现阻断问题，可由根任务用于已授权的唯一 Documents 标记创建和新实例读回。

本审查只读旧工具、旧创建及失败读回、guest 路径诊断、Task 8 约束、v2 工具和纯模拟脚本，独立运行纯模拟。未构建或修改生产源码，未操作 Store、真实进程、VM、挂载或 AMFI，未发送真实 guest 请求。

## 已核对的行为

- 固定第四版 CLI、唯一 task8-copy 和完整 target。host 在命令执行前校验 target；前后 capabilities 要求精确 target、正常启动、guest 连接及 shell/file_get 能力。
- boot-label 选择已通过的 boot watch，label 用于新证据。标签不能包含路径。输出和 intent 独占创建，intent flush/fsync 后才首次写 guest；已有输出拒绝覆盖且不发送请求。
- create 只使用随机 canonical UUIDv4 的 /private/var/mobile/Documents/task8-kernel-rollback-UUID。没有任意路径、目录创建或删除入口。set -C 与固定格式 printf、shlex.quote 限定写入命令；已有同路径文件拒绝覆盖。
- 写入前仅探测固定 /bin/sync 或 /var/jb/usr/bin/sync。写入后实际发送独立 exec sync 请求，要求 CLI 和 shell 退出 0、无超时或截断。随后同实例 file_get 实际解码并比较完整字节、SHA-256 和严格整数尺寸。sync 缺失或失败不能产生合格 create。
- 每个请求前及最终均重读 boot 证据和当前 binding、receipt、desired、config。原始摘要、committed kernel receipt 事务及 generation、机器标识和固定目录保持，firmware/desired pending 拒绝。不对运行中 Disk.img 计算摘要。
- read 仅接受合法 v2 create 标签，逐项核对原 boot 摘要、实例、规范路径、内容重建、六条 create 请求及原始响应、实际 sync 和 file_get。旧工具、旧 tmp 路径、失败或不完整 create 拒绝。
- read 要求同一 VM 身份、不同实例 UUID 和更晚启动时间。当前 receipt 可以指向新目标，live desired 单独核验。read 只发送 capabilities/file_get，不写 guest 或运行 sync。

## 独立纯模拟结果

运行前已确认主要用例注入纯 Operations；Native CLI adapter 的 subprocess.run 完全 mock；main 的 NativeOperations 在临时文件用例中也替换。真实读写仅限自动清理的临时普通文件。

独立运行退出 0，11 个测试函数通过，unittest 耗时 0.048 秒。覆盖两个 sync 路径、sync 缺失/错误/超时/截断、禁止覆盖、内容/尺寸/base64、实例与能力失配、输入及 pending、desired 竞态、旧或被篡改的 create 关联、同实例/不同机器、标签/重复 JSON、独占输出和 CLI 适配。证据为 guest-rollback-marker-v2-independent-mock.log/json。本审查未重新运行实施者的临时 mutant。

| 对象 | SHA-256 |
| --- | --- |
| guest-rollback-marker-v2.py | d9d7a5c37dede5acc212a85581686601fd92b0513e527caf212bd0472a83013b |
| guest-rollback-marker-v2-mock.py | d963ef54774c435caee48a066f118e60fad0937a5f14667ef7eaf2e67b81ddaa |

## 证据范围

旧 B 标记由原实例实际返回 742 字节，R_A 新实例 file_get 返回 ENOENT。路径诊断确认 /private/var 挂载在 disk2s2，/private/var/mobile 挂载在 disk2s7，Documents 目录存在。旧标记缺失的原因未查明，不能由本次路径选择或 sync 补充推定。

本结论确认工具流程和纯模拟结果，尚不证明 v2 标记真实创建、跨不同 payload 回退后保持或掉电持久性。最终须关联 create 的实例/事务/实测 payload、公开回退提交及读回、新实例和实际标记字节。成功标记只证明该文件保持，不能提升为全部 guest 文件系统保持。旧 tmp 失败继续保留。
