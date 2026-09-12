# E3：headless 宿主控制与 socket 生命周期

日期：2026-09-12。实现基线：`d05e0c5`。E3 的代码、完整本地回归及实际 VM 接口验收已完成；远端 CI 待本次提交后核对。本项不应用固件补丁，不复制磁盘；C4 继续暂停。

## 问题、修改与原因

E2 将命令和画面能力分开，但实际 VM 仍只在 GUI 分支启动控制 socket。E3 将命令执行对象及 socket 的创建移到公共启动路径；GUI 分支仅提供可选画面适配器。普通 headless VM 因此可以使用已经连接的客户机、定位和相机接口。

| 启动方式 | socket 与能力 | 结果 |
| --- | --- | --- |
| 普通 GUI | `boot_mode:normal`；按客户机声明及画面状态计算能力 | 保留 GUI 命令及截图策略 |
| 普通 headless | `boot_mode:normal`、`screen_available:false` | 客户机查询、shell、文件、应用及定位入口可用；screenshot 返回 `no active VM view` |
| DFU | `boot_mode:dfu`；不提供客户机、画面、定位或相机实现 | 只允许 capabilities；其余命令返回 `capability_unavailable` |

DFU 的命令执行器即使被误传入已连接的依赖，也不将其作为可用能力。capabilities 表示查询时入口是否具备能力，不保证后续操作成功。E2 的参数约束、默认截图策略及 180 秒命令期限保持不变。

socket 路径仍为配置目录的 `vphone.sock`，权限为 0600。监听改为非阻塞 `DispatchSourceRead`：取消监听后由 cancel handler 关闭监听描述符，避免阻塞 accept 的退出依赖。已接收连接由带锁的登记表管理；stop 在锁内 shutdown，工作线程负责 close，避免退出清理错误关闭已复用的描述符。

start 现在抛出错误。AppDelegate 将启动失败交给 AppKit 终止流程，执行统一清理并保留非零退出码。活动 socket、普通文件及其他用户的 socket 均不被替换；仅当同用户 socket 的连接探测返回 ECONNREFUSED 且 inode 未变时移除旧路径。停止时只删除本实例记录的 device/inode 对应路径。停止后的实例不能再次启动；新启动需创建新实例。

## 实现期间的故障定位

首次真实监听测试触发 signal 5。最小复现为 `testListeningSocketWorksWithoutViewAndCleansUp`；崩溃线程为 `vphone.hostcontrol.accept`，调用栈包含 `_dispatch_assert_queue_fail`、`_swift_task_checkIsolatedSwift` 和 `VPhoneHostControl.start()` 内闭包。原因是 DispatchSource handler 在 MainActor 方法内创建并继承隔离，而实际在监听队列执行。显式标记两个 handler 为 `@Sendable` 后，最小复现、专项及完整回归均通过。未修改客户机代码或宿主安全设置。

## 自动化验证

新增 7 个生命周期测试，使用真实 Unix socket 和客户机/画面替身，覆盖无视图命令、GUI/DFU 能力、断线状态变化、活动 socket 冲突、陈旧 socket、普通文件保护、路径替换、目录权限、路径长度、慢连接停止及两个 endpoint 的停止隔离。E1 的真实监听测试同时改为检查抛错启动。

`make test` 通过：81 个 Python 测试；114 个 XCTest（3 个跳过，0 个失败）；331 个 Swift Testing 测试、53 个 suite。`make build BUNDLE=.build/vphone-e3.app` 完成 release 编译、私有 entitlements 签名及独立 app bundle。

## 实际 VM 验证

使用现有且初始空闲的 `vm-2607-rig2`：iOS/cloudOS 26.1（23B85），exp，8 CPU、8 GiB RAM。磁盘、NVRAM、SEP 存储及机器标识与 `vm-2607` 独立。测试使用独立 app bundle，通过不存在的显式 vphoned 路径关闭本轮客户机自动更新。脚本只停止自身启动的子进程。

| 实验设置 | 证据与结果 |
| --- | --- |
| headless 正常引导 | 能力查询成功且无画面；shell 返回 `e3-ok`；18 字节含 NUL/0xff 的文件往返一致；应用列表返回 236 项；定位查询、设置及停止成功；截图被明确拒绝 |
| headless 守护进程故障 | 先确认 shell 的父进程为 `/usr/bin/vphoned`，再用 shell 内建 kill 终止该父进程；观察到 guest_connected=false、shell 未连接错误、自动重连及后续 shell 成功 |
| GUI 正常引导 | shell、文件、应用列表、定位均通过；screen_available=true，截图返回可解码的 5606 字节 JPEG；图像内容为黑屏，原因未查明，不据此声称客户机界面显示正常 |
| DFU | 能力表仅 capabilities 为 true；shell、screenshot、location_source_status 均返回 capability_unavailable |
| 正常退出 | 四次测试进程均以 0 退出，退出后 rig2 的 socket 不存在 |

首次 headless 故障注入使用后台 `sleep`/`killall` 命令，90 秒内没有观察到断线，该次脚本返回失败。随后诊断中 `command -v killall` 和 `command -v sleep` 没有输出，只有父进程查询成功。第一次注入未确认守护进程终止，不能将其解释为重连失败；修正注入后单独通过。原失败记录保留在 headless 目录，成功故障注入记录在 reconnect 目录。

客户机声明 legacy `location`，未声明 `location_owned`，所以实际定位测试覆盖兼容入口。本轮没有验证定位所有权、持久化重启或流隔离；这些仍归 E5。E3 重连实验也不替代 E4 的消息边界、ID、迟到响应、旧写队列和取消测试。

正式签名 CLI 的帮助命令和上述 VM 引导在当前环境可执行，9 月 11 日记录的执行限制本次未复现；变化原因未查明。该结果不等于 C4 正式固件恢复流程通过。

终态核对中，原 `vm-2607` 应用二进制的 inode、mtime 与大小未变，测试进程均已退出。原 VM 当前以 PID 57388 运行，初始 PID 为 27809；本次脚本未向原 VM 发送信号，PID 变化原因未查明。本轮不作为 F2 双 VM 连续运行或完整停止隔离验收。

## 证据与后续

日志、验收脚本、各模式 results.json、截图、终态核对及 SHA-256 清单位于 `research/artifacts/e3-headless-2026-09-12/`（本地产物目录）。新增自动化测试随代码提交。

下一项为 E4：建立客户机传输故障与取消测试，明确旧连接结果、迟到响应和已经提交操作的处理。E5/E6 仍需真实入口验收；C4 按用户决定继续暂停。
