# T60/T46 进度输出断开处理

日期：2026-10-15。基线：`2df4be8ceab956d498f2cc7d79b26f4ddbdee467`。
固定上游目标：`8a75092013eda87a4e30ed029b72028cb9279ac4`。

## 范围与现象

本次只处理 `VPhoneProgressBar` 的输出失败。T60 的队列、取消清理和最终状态仍未完成。

本地进度条在初始化时检查 stderr 是否为 TTY。普通 pipe/Launchpad 子进程原本不输出进度，因此上游“Launchpad 退出导致所有导入因进度管道失败”的条件不能直接套用。本次复现使用真实 PTY 初始化生产进度条，再将 stderr 重定向到读端已经关闭的 pipe，或关闭 PTY master。数据写入与进度回调交替执行。

初始 RED：忽略 SIGPIPE 时，旧 `FileHandle.write(_:)` 使进程以 SIGABRT（Python returncode -6）退出，数据写入未完成。仅替换为 throwing API 后，默认 SIGPIPE 条件仍以 -13 退出。`VPhoneProcessRunner.runCountingTarPipe` 只在传输期间忽略 SIGPIPE，返回时恢复原处理器；CLI 随后调用 `bar.finish()`。

## 修改

- render 和 finish 共用 best-effort 写入函数，使用 `try? FileHandle.write(contentsOf:)` 处理写入错误。
- 每次写入前重新验证 TTY。若 stderr 已重定向到 pipe，停止输出进度，保持本地仅 TTY 输出的合同。
- 不修改任何信号处理器和文件描述符标志。

实验曾尝试对 `dup(stderr)` 设置 `F_SETNOSIGPIPE`。实测原 stderr 的 `F_GETNOSIGPIPE` 同时改变，保留原标志的断言失败。因此没有采用该方案，也没有采用临时修改/恢复 stderr 标志的方案。

源码检查：`VPhoneVMImportCommand` 和 `VPhoneVMExportCommand` 在数据操作后调用 `bar.finish()`，随后仅通过 stdout 输出成功摘要；未发现这些调用点另有 stderr 写入。stdout 消费者关闭属于另一输出合同，本次没有修改。`VPhoneFWCacheCLI` 的独立非 TTY Hashing 日志也不在本次导入导出范围。

## 验证

命令：`.venv/bin/python -m unittest tests.test_progress_pipe -v`。

测试直接编译生产 ProgressBar、ProcessRunner 及其依赖，使用独立临时目录和 `-module-cache-path <temporary>/modules`，不使用 SwiftPM `.build`。TaskLocal 宏插件在受限沙箱内无法启动；同一测试经执行审批后通过。没有运行 VM、安装产物或更改宿主安全配置。

| 实验设置 | 结果 |
| --- | --- |
| 初始化为 TTY，随后重定向到关闭读端的 pipe，SIGPIPE 已忽略 | 数据 4096 字节完整，进程成功退出 |
| 同上，SIGPIPE 为默认处理器 | 数据完整，进程成功退出 |
| 关闭 PTY master | 数据完整，进程成功退出 |
| 正常 PTY | 输出标签与 100% 进度 |
| 从初始化开始即为 pipe | stderr 无进度输出 |
| 真实 `runCountingTarPipe` 提取归档，使用生产进度回调，返回后 finish | 提取内容逐字节一致，成功退出 |
| 进度初始化及断管后，在开始数据写入前发送 SIGINT、SIGTERM | 分别按信号终止；未创建目标数据文件 |

7 项测试通过；信号测试包含 SIGINT 与 SIGTERM 两个子场景。非 tar 子场景另断言 stderr 的 `F_GETNOSIGPIPE` 保持原值。证据见 `evidence/T60-progress-pipe/red.txt`、`baseline-final-tests.txt`、`green.txt`。

## 验证范围

本次真实 tar 回归覆盖 import 使用的流传输函数与进度回调，没有完整调用 VM library 的 bundle 验证、发布及清理。信号测试证明进度修复不会吞掉真正的 SIGINT/TERM；它不证明归档传输中断时 staging 清理、子进程收尾、队列退出或 UI 状态正确。仍需后续 T60 集成验收。

本地没有并发重定向 stderr 的产品合同；本次不保证 `isatty` 与 write 之间任意并发 `dup2` 的竞争行为。
