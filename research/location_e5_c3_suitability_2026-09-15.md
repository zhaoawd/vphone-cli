# E5：C3 less 实例作为第二台 VM 的适用性检查

日期：2026-09-15。目标：`vm-c3-runtime-20260914`，less，iPhone/cloudOS 26.1（23B85）。用户授权条件为可用于双 VM 定位隔离时开始验收。

## 结果

当前实例不能直接用于 E5 双 VM 定位隔离。原客户机声明 `location`，未声明 `location_owned`；固定源、流和所有权命令均不可用。按 less 方式编译并签名的临时客户机启动后被 SIGKILL，串口同期记录 `token is untrusted: hash does not match`、`unable to verify audit token came from amfid` 和 `AMFI: code signature validation failed.`，未获得新版客户机能力回执。

本轮只完成适用性检查，没有开始双 VM 定位场景，没有启动 rig2，也没有操作正在被其他任务使用的 vm-2607。

## 检查与尝试

- 两候选实例初始没有对应宿主进程和磁盘打开记录。C3 启动前取得目录锁检查无 socket、无待恢复固件事务；生产宿主启动后持有 VM 锁。
- 使用 E5 修复版独立签名宿主，显式 `--variant less --headless`，关闭自动更新。代码也明确禁止 less 自动更新；不能沿用 EXP 的部署流程。
- C3 原客户机文件接口可用，串口 bash 可用；`/iosbinpack64/bin/launchctl` 为旧版工具，现代 `print system` 返回 `Bad request.`。
- 原 vphoned 为 PID 65、父 PID 1，程序路径 `/usr/bin/vphoned`；原服务文件存在。客户机缓存 `/var/root/Library/Caches/vphoned` 不存在。
- 使用生产 less 构建参数 `-DLESS=1` 和项目签名证书生成临时客户机，放在 `/var/tmp/e5-vphoned`。未覆盖系统程序、服务文件或原客户机缓存。
- 尝试旧版 `launchctl unload`：退出码为 0，但文本为 `Could not find specified service`。因此不能认定原服务卸载成功。临时程序 PID 533 随后显示 `Killed: 9`，其输出日志为空，原客户机仍可连接。

## 恢复与后续条件

所有本轮 `/var/tmp/e5-*` 文件已按精确路径清除，并通过客户机文件接口逐项确认不存在；原客户机缓存仍不存在。C3 已请求正常关机，原环境重启复核的最终结果见下方补充。

若继续使用该 C3 镜像，需要先解决新版 less 客户机的可执行签名/信任条件，并确认可恢复的服务切换方式，再验证 `location_owned`。本轮没有修改内核、信任缓存或重做固件恢复。另一选择是在 vm-2607 空闲且可独占后，与 rig2 执行双 VM 验收。

证据位于 `research/artifacts/e5-dual-location-2026-09-15/c3/`：`inputs.json`、`build.log`、`baseline.log`、`requests.jsonl`、`processes.txt`、`e5-unload.txt`、`e5-temporary-daemon.pid`、`guest-cleanup.json`、`verify-restore.log`。

最终复核通过：原客户机在重启后重新连接，能力与初始旧版能力一致；临时程序和客户机缓存不存在。随后客户机再次关机、宿主退出 0，socket 消失，目录锁可重新取得，配置逐字节未改变。rig2 未启动；vm-2607 原宿主 PID 33731 仍存在。见 `restored-capabilities.json`、`restored-original.log`、`final-cleanup.json`。
