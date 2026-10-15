# Task 8 第八版目标磁盘真实启动独立审查

日期：2026-10-14。审查者：acceptance_audit。只读核对原 watch、补充命令定位/绝对路径系统查询、实际第四版 VM argv、绑定、正式停止及停机清理证据。仅写本文件及对应 JSON；未执行 VM、挂载、AMFI、guest 命令、清理或生产修改。

结论：本次已核验第八版容器修复后的目标磁盘，在第四版 host/VM 下完成正常 guest 连接、只读系统查询和优雅停止；清理观察通过。满足已授权计划中启动通过后推进回退实施的前置条件。仍不证明不同 payload 更新、全部补丁行为或提交后 kernel-only 回退通过，Task 8/T34 尚未完整验收。

## 实例及启动前来源关联

boot-v8-guest-command-discovery-retry.json 的实际进程记录为第四版 `2.6.20261016-local/VPhone.bundle/Contents/MacOS/vphone-vm`，配置指向 task8-copy，带 --no-vphoned-update。PID 为 22914，instance ID 为 `D46D87C2-A877-4348-BA7F-A9410522C493`，与 watch 及补充 shell target 完全一致。

实际 argv 的 binding SHA `d270a47c62463a4adca22196b890a4dc228c7a11d2d3c1763f56078467452b25` 等于 binding-before-boot-v4-kernel-v8.json 的独立计算摘要；内容为 host 第四版、kernel 来源第八版。此前独立提交读回已证明 Disk/完整 IMG4/IM4P/receipt 来源关联，本次启动结论与该停机证据联合成立。未使用第八版 VM 可执行文件。

## 原探针失败与补充成功

原 watch 从 75.493 秒开始记录 guest_connected=true，共 19 次 capabilities 观察均为同一 target、ok=true、shell=true。19 次 shell 均由 host 正常回报，但 code=127，stderr 为 uname/sysctl not found；没有超时或截断。原 boot-watch-v4-kernel-v8.json 的 passed=false 和执行失败保留，不能覆盖，也不能将其写为 guest 未连接。

补充定位返回 shell=/var/jb/bin/sh、PATH=/usr/bin:/bin:/usr/sbin:/sbin，实际 executable 包含 /var/jb/usr/bin/uname 和 /var/jb/usr/sbin/sysctl；PATH 未列出这两个实际目录。首次 sandbox-only 定位因 socket Operation not permitted 退出 2；该证据保留，不能解释为 guest 命令失败。执行方另说明首次提权审批超时后获准重试；本审查不将审批超时记为安全审查拒绝。

boot-v8-guest-state-absolute.py/json 使用上述实际绝对路径，shell 请求携带同一完整 target。独立关联断言确认外层退出 0、ok=true、code 类型严格为 int 且为 0、timed_out=false、truncated=false，实际结果为：

```text
Darwin iPhone 25.1.0 ... RELEASE_ARM64_VRESEARCH1 iPhone17,3 arm Darwin
kern.osrelease: 25.1.0
hw.machine: iPhone17,3
```

补充 passed=true 与实际字段一致，证明本次 guest 已运行且系统查询成功。该成功响应没有以原 watch 的失败覆盖或默认回退逻辑取得。

## 正式停止及清理

vm-stop-v4-kernel-v8.json/log 对同一 PID/instance 正式执行 stop，退出 0，耗时 4.675350 秒。启动日志显示 graceful shutdown via guest power-off command over vsock、classicAccepted、Guest stopped，没有此前 graceful shutdown 超时的情形。vm-boot-v4-kernel-v8.json 在正式停止后退出 0，总运行 597.134056 秒；启动通过判据来自实际 guest 结果，而非单独使用 launch 退出码。

post-boot-v8-cleanup-v2.py/json 的保存结果通过：

- 已停机副本目录锁可取得，无当前本轮拥有 VM/driver 进程、无本轮镜像附件、无 pending transaction。
- host 第四版/kernel 来源第八版绑定保持；receipt SHA `266ba0ad4589044c4f736ed2911267db03c22658c8f756fab453bb5e6b855cfb` 与已提交第八版 publication 相同。
- 源 vm-new 六个关键文件的 device/inode/size/mtime/ctime 逐项与 clone.source_before 中同字段一致。该结论不包含源文件内容重新计算 SHA，也不包含 allocated 字段比较。
- 本轮记录 temporary_amfi_driver_started_this_run=false；没有为本次启动启动临时 AMFI driver。

首次 post-boot-v8-cleanup.json 的 passed=false 保留。它将历史 PID 89299 对应的新 SetStoreUpdateService 误计为本轮拥有进程；v2 按实际 VM argv/driver 脚本身份核对，历史 PID 仅作观察。该 PID 复用已由保存的实际命令名确认，没有据此向该系统进程发送信号。

## 范围限制

本次正常 guest 启动、shell 系统状态和优雅停止通过。未单独证明 UI 全面就绪或每条补丁的运行行为。decoded payload 仍为此前相同的 d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb；不能计为不同 payload 启动或回退验收。

description/PAYP 在第八版同时恢复；没有隔离对照建立其中任一变化与启动结果的因果关系。不能将本次成功单独归因于 PAYP，先前启动异常的确定原因仍未查明。

启动后 Disk/NVRAM/SEP 等正常状态可能改变；本次清理未重新要求整盘等于离线 receipt，也未以历史整盘恢复清理。源元数据保持和 receipt 文件保持不等于副本磁盘内容未变化。后续回退必须以此当前磁盘为候选来源并保留启动后数据，另行验证真正不同 payload、公开入口和 marker 保留。

审查者仅解析保存结果并核对脚本/字段，未独立重复 live 启动或 guest 查询。

## 审查输入摘要

| 文件 | SHA-256 |
| --- | --- |
| boot-watch-v4-kernel-v8.json | `1fad9d9e8d5885d652ccbac1007504a435785e0daddf9a86e27951b1dd9948c1` |
| boot-watch-v4-kernel-v8-observations.jsonl | `1cd988747a71f062a266afa68c4b10b0751fb950650ed68093b4d5be2513c576` |
| boot-v8-guest-command-discovery.json | `8413c94804b2c62bf4d8e6208d26f54e0f3929cfb03ae654ce9e92b7f0ae3d76` |
| boot-v8-guest-command-discovery-retry.json | `dbe4782427c7a16edbed81aa6a52cedeb503dc38e6f51559bdbeac0cc2c7620e` |
| boot-v8-guest-state-absolute.py | `a03ff655624ecb29d72d9674d024a64d657d24d956095d18c387b25123f717e0` |
| boot-v8-guest-state-absolute.json | `e206ace18a9460414661019eba0eee20d45f54d010c34a876e78418d2b98c01c` |
| vm-boot-v4-kernel-v8.log | `d294208556c4a53b5ac4bcac4152ddcba47e79c4e67b70348c0af38895e7b91a` |
| vm-stop-v4-kernel-v8.json | `6706f5d79e23bec9aaff78f0860c2cb4f9e566506c4b6e25f27f937348491e40` |
| post-boot-v8-cleanup.json | `24d9c779ace67cd34f81a7cd146b07a3d89fa411752e1f3d50687efa512bb7db` |
| post-boot-v8-cleanup-v2.py | `92ec06379e9d9a3932a839926d9eb43302e7ecc2a486112762fc383e6b02441e` |
| post-boot-v8-cleanup-v2.json | `c86189d75032b11fbd07c44f206c3b69cf534d76848fa2aaf816ac3740b8b107` |
