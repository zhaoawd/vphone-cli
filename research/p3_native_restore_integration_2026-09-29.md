# P3 原生恢复后端接线

本批在既有 `vm create` / `--resume` 检查点流程中增加显式 `--restore-backend native`。默认及历史检查点继续使用 Python；独立 `restore` 命令仍为既有路径。此项没有创建 v2 manifest，也没有安装候选客户机组件。

## 执行与身份边界

- DFU VM 启动和退出仍由原有创建编排负责。native 后端按 probe → ticket → restore 顺序启动同一 CLI 的隐藏 worker 子命令，不在创建进程中运行 C 恢复库。
- 每次 worker 检查监督父 PID、bundle 中的 ECID/UDID、目录锁持有者和 DFU instanceID；拒绝 ECID 为 0，不能选择“唯一已连接设备”作为隐式目标。设备探测还检查返回 ECID。
- `.native-restore.lock` 对 native worker 排他；拒绝符号链接及非普通文件。该锁不代替 DFU VM 持有的目录锁。
- probe、ticket、restore 分别限制为 30、300、1800 秒。监督进程处理 SIGINT/SIGTERM，将取消记录为 CancellationError；停止子进程后等待退出，必要时升级到 SIGKILL。worker 重置继承的信号忽略状态。父进程消失时，worker 的 250 ms 定时检查使其退出。
- C 恢复日志经 stderr 输出；本批不更改原有 C stdout 捕获实现。获取票据与恢复保持 erase 语义，恢复阶段仍在线获取恢复所需票据。
- DFU 所有者的 ps 查询设 5 秒上限，查询不成功时拒绝通过所有者检查。该改动不解释宿主全量 ps 查询曾不返回的原因。

## 检查点与失败处理

`restoreBackend` 为可选持久字段。Python 默认值不编码进新检查点，旧检查点解码后仍使用 Python，原 options digest 不变。变更后端影响 restore 阶段；已执行阶段不能无记录切换，必须显式 restart-from restore 并接受再次擦除。未给后端的 resume 保留原选择。

恢复 evidence 写入 backend；验证器拒绝 evidence 与有效配置不一致。中断恢复探测同时识别 Python bridge 和 native worker，避免已知 worker 尚在操作同一 ECID 时续跑。原 `retain_until`、工具变更确认、失败保留恢复树和 DFU 子进程清理规则继续适用。

## 验证范围

新增无固件测试覆盖 CLI 显式选择、历史编码/摘要、ECID/UDID 匹配、worker 失败、超时后的进程退出、取消类型、后端切换后续跑、native worker 占用识别。首次专项发现测试样例去掉了 UDID 连字符，而生产协议只规范大小写；修正样例后复跑。完整结果记录在本轮进展文档。

真实设备 probe/ticket/restore 尚未执行。配套 v2 创建、原生 prepare/CFW 和 helper 收据/安装仍未完成，不能将本批代码接线记为 P3 或整个上游整合完成。
