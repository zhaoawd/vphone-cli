# VM Restore 输入与 C3 运行实例清理

日期：2026-09-16。用户授权按既定顺序清理两个保留实例的 Restore 输入，并删除 `vm-c3-runtime-20260914`。本次不修改 VM 磁盘内容、固件补丁或客户机文件。

## 范围与后续输入策略

删除范围：

- `vm-2607/iPhone17,3_26.1_23B85_Restore`
- `vm-2607-rig2/iPhone17,3_26.1_23B85_Restore`
- `vm-c3-runtime-20260914` 整个实例；其 Restore 输入包含在该目录内

D3、D4 和 F1 后续使用重新生成的专用输入与专用测试 VM。C3 less 尚未执行的 GUI、应用、DDI、定位和相机检查需要重新创建 26.1 / 23B85 less VM。本次删除不将 D3、D4、F1 或 C4 标记为完成。

历史 C3 less 验收脚本不再只依赖固定的 `vm-2607` 路径。`research/c3_less_pipeline_acceptance.py` 增加 `--source`，重新准备输入后可显式指定新的 `iPhone*_Restore` 目录；未指定时仍保留历史默认值。

## 删除前证据与安全检查

`research/artifacts/vm-cleanup-2026-09-16/pre-cleanup.json` 保存三个 Restore 的逐文件大小和 SHA-256，以及 C3 身份文件摘要、C3 稀疏磁盘逻辑/分配大小和删除前空间。清单覆盖：

- `vm-2607` Restore：182 个文件
- `vm-2607-rig2` Restore：182 个文件
- C3 Restore：27 个文件

三实例均无待恢复固件事务或相关挂载。删除时无进程打开目标目录。`rig2` 和 C3 无 socket；`vm-2607` 原宿主 PID 33731 仍在运行，因此先暂停健康监控 PID 39330 与 rig agent PID 81563，再向已核对配置路径的宿主发送 SIGINT。宿主在 50 秒期限内正常退出。

删除前 `vm-2607` 没有独立的 `restore-info.json`。从两份 Manifest 核对 iOS 和 cloudOS 均为 26.1 / 23B85 后，在 VM 目录锁内写入 `variant=exp`、`device=iPhone17,3` 的版本记录。`rig2` 原有版本记录保持不变。

## 删除与结果

两个 Restore 目录分别在对应 VM 目录 inode 排他锁内删除。C3 实例确认无 socket、事务、挂载和打开文件后，在实例目录锁内删除。三个目标路径均已确认不存在。

删除前证据记录可用空间为 16.34 GiB。删除后执行构建、签名、VM 启动和日志写入后，`post-cleanup.json` 记录可用空间为 48.30 GiB，净增加 31.96 GiB。该数值是同一文件系统的前后净变化；APFS 克隆共享和期间新增构建产物使其不等于目录名义占用之和。

保留实例当前占用：

- `vm-2607`：约 26.99 GiB
- `vm-2607-rig2`：约 18.08 GiB

证据目录还保存 `vm-2607-restore-info.json`、清单生成脚本和 `post-cleanup.json`。这些文件位于 Git 忽略的 `research/artifacts`，其他 checkout 不保证存在。

## `vm-2607` 恢复检查

低风险清理已移除原宿主程序的磁盘路径，但原进程当时仍在运行。停机前重新执行 `make build`，签名应用、资源和 entitlements 验证通过。编译保留现有 warning，没有新增处理。

新应用首次执行受宿主签名策略拒绝，退出码为 137。随后使用项目标准脚本启动 amfidont 路径/CDHash 放行，新应用帮助入口执行通过。使用原 `config.plist` 和 `Disk.img` 启动 `vm-2607`，新宿主 PID 为 21605。客户机连接后 UDS shell 返回 `AUTOPHONE_UDS_READY`；健康监控恢复后报告 UDS 与 vsock 均为 `healthy`。健康监控和 rig agent 已从暂停状态恢复。

rig agent 恢复时 `127.0.0.1:8100` 没有控制面监听，既有 `control-plane.pid` 指向的进程不存在；日志中的最后一次控制面连接早于本次清理。agent 保持重连。本次没有启动或修改 autophone 控制面，因此该状态不作为 Restore 清理失败。

`rig2` 未在生产 `vm-2607` 恢复后并发启动。其 `config.plist`、`restore-info.json` 均通过格式检查，socket、事务和挂载均不存在。本次不新增 rig2 启动通过结论。

## 后续影响

- 两个保留 VM 的普通启动使用各自 `Disk.img`，不依赖已删除的 Restore 目录。
- 再次执行 DFU restore、固件补丁或依赖 SystemOS/AppOS 输入的 CFW 安装前，必须重新准备对应固件树。
- C3 历史恢复、首次和第二次启动结果仍按原日期保留；已删除实例不能用于继续取得运行证据。
- C4 完整 less 成功路径仍未执行。恢复 C4 前应重新核对当前空间、输入和事务状态。
