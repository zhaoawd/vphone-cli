# F2 双 VM 验收自动化准备

日期：2026-09-16。本记录描述 F2 的离线自动化准备，不构成双 VM 实机验收。

## 已实现范围

新增 `scripts/f2_dual_vm_acceptance.py`。工具通过每个 VM 目录中的宿主控制 Unix socket 工作，不新增宿主协议命令，也不负责启动或停止 VM。

`file-isolation` 场景执行以下检查：

1. 将两个输入路径解析到实际 Unix socket，检查所有者，并按设备号和 inode 拒绝同一端点及路径别名。
2. 分别查询两个端点的 `capabilities`，要求客户机已连接并提供 `file_put`、`file_get` 和 `shell`。
3. 在两个客户机的同一路径写入不同标记，再分别读回。返回内容必须与目标实例的标记一致。
4. 无论归属检查通过或失败，都尝试删除已经写入的标记。清理失败会使场景失败。

`survivor` 场景用于调用方已经停止一个 VM 后的检查：

1. 停止实例必须没有 `vphone.sock` 和 `.firmware-transaction`，且 VM 目录的非阻塞排他 flock 必须可取得。
2. `.vphone-runtime.json` 是诊断记录，不作为占用证据。文件存在时在摘要中记录 `stale_runtime_record_present: true`。
3. 仍运行实例必须完成能力查询、标记写入、读回和清理。

两个场景都要求新的输出目录，并生成 `requests.jsonl` 和 `summary.json`。工具拒绝覆盖既有证据目录。默认客户机临时路径带 `vphone-f2-` 前缀；自定义路径也必须使用该前缀。

调用示例：

```sh
scripts/f2_dual_vm_acceptance.py file-isolation \
  --left-name vm-a --left-socket /path/to/vm-a/vphone.sock \
  --right-name vm-b --right-socket /path/to/vm-b/vphone.sock \
  --output /path/to/new-evidence-directory

scripts/f2_dual_vm_acceptance.py survivor \
  --stopped-name vm-a --stopped-vm-dir /path/to/vm-a \
  --running-name vm-b --running-socket /path/to/vm-b/vphone.sock \
  --output /path/to/new-survivor-evidence-directory
```

## 自动化验证

新增 5 个通过公共命令行接口运行的集成测试。测试使用两个实际本地 Unix socket 服务器作为系统边界，覆盖：

- 相同客户机路径的双端点文件归属和证据记录；
- 一个实例停止后的目录清理与另一实例继续工作；
- socket 路径别名在请求发送前被拒绝；
- 归属判定失败后两个端点均执行标记清理；
- 目录锁已释放时允许保留陈旧诊断运行记录。

`make test_python` 通过，共 118 项。脚本语法检查和 `git diff --check` 通过。

## 当前实机条件与剩余范围

仓库中只有 `vm-2607` 和 `vm-2607-rig2` 两个 VM 配置。检查时主 VM 宿主 PID 为 21605；本轮没有连接其控制 socket，也没有启动、停止、更新或修改主 VM。rig2 的诊断运行记录包含 PID 30944，但该 PID 不存在；本轮没有删除该诊断记录。

在“主 VM 不操作”的既定约束下，没有第二个可用于本轮实机验收的实例。因此本轮没有执行双 VM 控制请求，F2 保持未完成。剩余验收包括：

- 两个实例同时启动后的应用、文件、定位和相机归属；
- 停止及重启一个实例，使用 `survivor` 和重启后的 `file-isolation` 检查另一实例及恢复后的归属；
- 端口配置、后台任务取消和失败后进程清理；
- 两个实例运行时的重建、导出和安装占用保护，以及 socket、锁和挂载清理。

E5 的双 VM 定位记录可以作为 F2 的定位证据之一，但不能替代同一 F2 流程中的应用、文件、相机和生命周期结果。当前工具只证明其离线契约，不证明真实 VM 已通过。
