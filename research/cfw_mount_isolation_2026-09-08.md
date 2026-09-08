# B1 CFW 挂载隔离验证记录

日期：2026-09-08。

## 范围与实现

A1 已提交为 `b7d0382`，A2 已提交为 `2ac6c51`。B1 修改主机安装驱动和四个变体的挂载路径，没有新增二进制补丁。

- 驱动在 VM 的物理路径下创建 `.cfw_mount.XXXXXXXX` 独立目录，通过导出的 `CFW_HOST_MNT` 传给安装脚本及其子进程。四个变体取消共享目录默认值。
- System、Data、Preboot 和临时 Cryptex 挂载使用本次目录。SystemOS/AppOS 缓存文件继续保存在 `.cfw_temp`，EXP 的已修改缓存仍可复用。
- 驱动在 attach 前设置退出和信号处理。attach 输出保存在本次目录的 `attach.log`，支持工具已输出设备但随后失败的清理。成功卸载设备后删除该记录，避免再次清理同一设备。
- 清理读取实际挂载表，只处理本次目录下的挂载，并输出设备和目录。Cryptex 使用 `hdiutil detach`，容器卷使用 `umount`，最后卸载本次附加的基础设备。
- 安装失败码保留；SIGINT、SIGTERM、SIGHUP 分别使用 130、143、129。正常安装后的清理失败也使流程失败，阻止离线快照修改。退出处理会再次尝试清理。
- 清理只删除已知日志和空目录，不递归删除挂载目录。失败时保留目录并报告路径。

## 验证方法

命令替身测试：[test_cfw_host_isolation.py](/Users/qcz3840/github/vphone-cli/tests/test_cfw_host_isolation.py)。运行驱动副本，仅替换提权判断；磁盘命令和挂载表使用替身，安装负载使用测试脚本。覆盖两个任务并发、第三方挂载排除、设备发现失败、attach 部分失败、清理失败阻止快照修改、安装失败码保留和 SIGINT。

原生测试：[cfw_host_mount_native.py](/Users/qcz3840/github/vphone-cli/tests/cfw_host_mount_native.py)。创建两份专用 32 MiB APFS 镜像，使用真实 `hdiutil attach` 挂载；从生产驱动提取原样的清理函数和退出处理运行。检查第一个任务卸载后第二个任务仍挂载且文件可读，并验证退出码 37。测试结束清理专用镜像。

```sh
make test
.venv/bin/python3 -m unittest discover -s tests -p test_cfw_host_isolation.py -v
.venv/bin/python3 tests/cfw_host_mount_native.py
make build
```

原生测试需要访问 macOS DiskImages 服务，因此在沙箱外执行。没有访问既有 VM 镜像，也没有运行完整 CFW 安装。

## 验证结果

- `make test` 退出码 0：Python unittest 37 项、Swift Testing 180 项、XCTest 20 项，共 237 项通过。
- 最终清理代码的 6 项主机隔离专项测试通过；原生 APFS 测试退出码 0。
- 五个安装脚本的 `zsh -n`、`git diff --check`、`make build`、应用主程序的 `codesign --verify --strict` 均通过。
- 最初的独立目录测试和部分 attach 失败测试在修复前失败，修复后通过。

本地日志位于 `research/artifacts/b1-2026-09-08/`：`test.log`、`host.log`、`native.log`、`build.log`。该目录被 Git 忽略，不随代码分发。

## 限制

- 原生测试验证真实 APFS Cryptex 挂载的清理；容器卷 `mount_apfs`、`umount`、完整固件安装和离线快照修改仅由替身覆盖或未执行。
- SIGINT 已由进程组信号测试验证；SIGTERM、SIGHUP 的处理路径已实现，未单独进行原生信号实验。shell 等待子进程时可能推迟处理仅发给父进程的信号。
- SIGKILL、断电或工具附加设备后尚未输出设备信息即被终止时，不能保证自动清理。
- 本项隔离不同安装任务的挂载目录，不提供同一磁盘的排他锁。B2/B4 仍需处理跨入口并发；同一 VM 下的缓存和其他安装临时文件也未改成跨进程事务。
- B1 与本记录一并独立提交。用户原有触控修改和诊断文件保持独立。
