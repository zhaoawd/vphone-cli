# 未提交改动评审与模板重启验收，2026-11-14

本轮按用户确认的顺序，整理和评审现有修改，再完成 #899 的隔离 VM 重启验收。起点为 `a0b5899e`，分支为 `duo-integration-20261030`。未推送、合并或发布。评审针对本地改动及已有证据，没有把本地条目编号解释为已完成全部上游同步。

## 评审结果

发现并修复两项问题。模板重启时序问题：原实现先调用 `exitedCleanly()`，再调用 `failure()`。子进程在两次读取之间正常退出时，后一次读取返回状态 0，流程仍按故障结束。新确定性回归在原实现失败，错误为 `Setup boot failed at step reboot (f. reboot): vphone-vm exited with status 0`。

修复先取得 failure 结果，再处理正常退出；允许补启动一次，之后才使用取得的故障结果。不能再次启动、异常退出、panic 和截止时间的原有断言保留。CoreKit 的 47 项模板测试全部通过，包含新时序用例。日志为 `.build/review-20261114/template-race-before.log` 和 `template-race-after.log`。

第二项是历史诊断入口的清理条件：仅在 CLI 父进程存活时发送关机请求，父进程先退出会遗漏仍在运行的 VM。新增测试提取实际 cleanup 函数，以已退出父进程及仍打开的状态文件复现失败；修复改为始终尝试正常关机，并根据实际文件句柄等待。关机失败或句柄仍在时仍判失败，不强制终止 VM。两个 fixture 场景通过，接入 CI；日志为 `runtime-cleanup-before.log` 和 `runtime-cleanup-after.log`。该回归未启动 VM。

共享文件按内容拆分：GuestAPI 的设置值与方法目录、GuestAPI+Input 的目录与 AX、GuestAPI+Device 的目录与 AOD、GuestHyperTextHandler／main 的传输与显示代次、VPhoneGuestControl 的健康重试与方向保持，分别进入对应提交。部分暂存只改变 Git 索引，工作树保留了原有完整修改。新增研究文件统一使用索引中的 `Research/` 路径，避免本机大小写不敏感文件系统产生两个目录名称。

## 源码提交

| 提交 | 内容 |
| --- | --- |
| `82947d82` | Reject invalid settings values without crashing the guest worker |
| `e9d591e3` | Describe the supported Duo display RPC methods |
| `bd4b714a` | Bound guest process output and retain pipe ownership |
| `c874fc84` | Bound health probes and report guest connections closed without a reply |
| `b1017c9e` | Start the shell completion status on its own line |
| `7f60b5c9` | Preserve orientation across short guest disconnects |
| `70ab6d48` | Record capture timestamps and retain native handoff analysis |
| `978a95ee` | Allow standalone machine creation to select its setup boot |
| `82bd1825` | Resume a template reboot after the VM exits cleanly |
| `3b4ac980` | Clear failed recovery clients before returning to callers |
| `b0516b90` | Hit-test the active Duo display and verify the foreground process |
| `69c46de6` | Preserve AOD and native panel content through Duo handoffs |
| `61e7125e` | Recreate the guest API worker when the render server changes |

CI 与共享验收脚本提交为 `4fcc5b3d`，当前记录另行提交。CI 增加 owning CoreKit 方案中的 TemplateSetupBootTests 和 APIRequestGateTests；需要实际 VM 的回归保持手动运行。所有提交均留在本地分支。

## #899 实际 VM 验收

源副本 `duo-rpc-accept-205443` 保持关机。使用项目已有 APFS clone 命令创建新身份副本 `duo-template-reboot-20261114`，没有恢复或擦除流程。测试静态链接实际 CoreKit，编译生产 `VPhoneTemplateSetupVirtualMachine` 和 `VPhoneHostAutomationProbe`，仅为观测增加只读扩展及计数包装。`restartGuest` 改为 internal，允许通过该入口测试重启，避免执行完整 setup 的快照与应用删除步骤。

VM 程序和 guest 资源使用保留的基线 Bundle，VM CDHash 沿用已准入版本；未修改宿主 AMFI。本轮实际覆盖的是最终 CoreKit 重启逻辑与生产启动适配器，完整构建新链接的 VM 程序尚未单独准入或运行验收。

| 实验设置 | 结果 | 证据 |
| --- | --- | --- |
| 实际 `system.reboot` | VM 内完成重启，宿主总启动次数 1，未补启动；launchd start_time 从 1794657475.028147 变为 1794657493.0227301 | `.build/review-20261114/template-native.uCxly7Wc/` |
| 真实关机对照 | 包装层明确将一次 reboot 请求转为真实 `system.shutdown`；VM 正常退出后，生产重启流程恰好补启动一次，总启动次数 2；launchd start_time 从 1794657528.0125861 变为 1794657542.0218611 | `.build/review-20261114/template-poweroff.EgOWMV5U/` |

两组均核对重启前后环境库摘要一致、根只读；只发出一次重启请求，没有进入其他 setup 操作。随后通过 RPC 正常关机，状态文件无打开句柄。提交收尾时再次只读核对原验收副本和新模板副本的六个状态文件，均无打开句柄，结果为 `.build/review-20261114/final-open-handles.txt`。关机对照用于验证实际子进程退出／重建，不计为本 guest 的原生 reboot 行为。完整模板初始化流程未在本轮实测。

回归命令：

```zsh
zsh Research/Integration/duo_m5_20261030/Regression/template-reboot-runtime.zsh native
zsh Research/Integration/duo_m5_20261030/Regression/template-reboot-runtime.zsh poweroff
```

脚本固定使用本轮隔离副本、已构建的 CoreKit 测试产物和基线 Bundle；运行前需具备这三项准备。源文件摘要、生产适配器片段和具体驱动副本保存在每轮证据中。

## 验证结果

- 完整 `VPhone` Bundle 构建、构建内 admission 和深度严格签名通过：`bundle-build.log`、`bundle-signature.log`。
- CoreKit：模板状态机 47/47；APIRequestGate 15/15。
- 宿主：健康重试 6/6、HTTP 读取 4/4、方向保持 10/10、RPC relay 8/8、shell 状态行 6 项通过。
- 录制：生成 MOV 保留实际 320 ms 采集间隔，15 项时钟、来源、报告和部署判定均通过，本轮没有跳过可选 Swift/Node 时钟检查。
- daemon：健康检查、进程管道归属和输出字节上限回归通过；逻辑测试 449 项通过；显示指标／目录契约通过。
- Launchpad 参数、创建计划及模板测试通过；恢复客户端的伪 USB 后端 7/7，通过范围不包含实际 USB/DFU 恢复。
- 共享 host-request 的 6 项临时 socket 契约通过；28 个研究 JavaScript 和原有 33 个 zsh 脚本语法检查通过；新增 cleanup 测试与修改后的入口也通过语法检查。

录制编码器与共享 socket 测试在受限 sandbox 中分别遇到编码器不可用和后台调度限制；以宿主权限重跑通过。RPC relay 首次使用默认 derived data 时缺少本地模块映射，传入实际 Bundle 的 derived data 后 8/8 通过。没有修改或弱化这些断言。

上述新日志位于 `.build/review-20261114/`。原三项修复的实际 AX、AOD、交接和回滚证据仍以 [FIXES_20261114.md](FIXES_20261114.md) 为准，本轮没有重复启动原验收副本。

## 保留的待办

- 原生 Snapshot 下最长约 432 ms 的重复亮度区间完整原因未查明；过渡中的方向变化和右横屏覆盖仍未完成。
- 新完整 Bundle 的宿主程序独立运行验收未完成。
- 四语手册的 Argon 发布前审阅未完成；本轮提交不构成发布验收。
- 上游 DSC 映射生命周期、缓存 worker、RPC 契约和其他独立候选仍按 TASKS.md 继续。
