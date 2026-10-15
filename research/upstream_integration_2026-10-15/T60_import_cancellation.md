# T60：导入取消与发布

日期：2026-10-15。本次推进真实 `vm import` 的取消清理和发布前检查。完整队列、导出取消和 Launchpad 退出状态仍不在本次验收范围。

## 复现与原因

旧 CLI 的 SIGINT/TERM 使用默认进程终止行为，未执行 `VPhoneBundleOps.importArchive` 的 staging 清理。`VPhoneArchiveExtractor` 已有逐块取消检查，但 CLI 和 BundleOps 未传递取消条件；system-tar 的两个子进程也未注册到现有取消控制器。

初始 FIFO 实验：导入创建 `.import-*` 后阻塞在打开源文件，SIGTERM 使进程以 -15 结束，残留一处 staging。该实验另揭示不可取消的特殊文件打开问题，故最终入口在创建 staging 前要求源为常规文件；`stat` 跟随指向常规文件的符号链接。该类型检查不建立源路径在其他进程恶意替换期间的不变性合同。

随后使用常规 1 GiB tar 的真实导入复现。观察到 staging 内 Disk.img 后，暂停本测试导入进程及其 tar 子进程，再向导入进程发送 SIGINT 并恢复。旧 CLI 退出 -2，残留 staging=1，目标未发布。证据为 `evidence/T60-import-cancellation/regular-file-red.txt`。测试库和输入归档均位于临时目录。

## 修改

- CLI import 使用现有 `VPhoneChildCancellation` 接收 SIGINT/TERM，通过 TaskLocal 绑定本次操作，并把取消条件传给 BundleOps。取消后等待本次已登记子进程退出，返回 `128 + signal`。
- system-tar 的 producer/consumer 均登记到同一控制器，使真实信号取消能够终止阻塞管道的子进程，随后 wait 回收。正常返回不会提前跳过子进程收尾。库单独传入取消闭包但不绑定控制器时，仅承诺块边界轮询；不承诺阻塞系统调用的有界中断。
- native extractor 接收已有逐块取消参数。
- BundleOps 在开始、抽取完成以及持有 library 锁并完成 `afterNameCheck` 后、rename 前检查取消。异常路径执行本次 staging 的 defer 清理。
- 排他的 rename 是发布提交点。最后一次取消检查之后到 rename 之间到达的请求，或发布之后到达的请求，不撤销已发布 bundle，也不把已完成的发布报告为取消。
- 源 FIFO 等特殊文件在创建 staging 前拒绝，避免信号转换为标志后仍无法中断其 open。

## 验证设置

`NativeTransferTests` 新增三组双后端测试：抽取回调触发取消、发布前触发取消、FIFO 拒绝；验证 staging 不残留、目标不发布、原件及原 VM 保持。既有正常导入与归档互操作测试继续作为正常路径对照。

真实 CLI 脚本：

```sh
.venv/bin/python research/upstream_integration_2026-10-15/evidence/T60-import-cancellation/accept_cli.py .build/debug/vphone-cli
```

脚本构造常规 1 GiB tar，在临时库逐一验证 system-tar/native × SIGINT/SIGTERM。system-tar 场景暂停本测试的 tar 子进程，制造无法继续消费数据的情况；检查取消最终退出码、子进程身份和退出、staging 清理、目标未发布、已有目录标记与源归档摘要保持。只对本测试拥有的进程注入信号，清理前再次核对进程启动时间及命令。

脚本第一次运行因沙箱禁止读取 `ps` 未能完成；后续运行使用获批的执行权限。没有启动 VM，没有更改系统配置或已安装工件。

## 结果

- 真实 CLI 取消四场景全部通过：system-tar/native × SIGINT/SIGTERM，退出码分别为 130/143，staging=0、目标未发布、tar 无存活进程，已有目录标记保持。原 1 GiB 输入归档前后 SHA-256 均为 `6685d734ca79c29749743282b9098915c5ee5f6536c3963344fafd078f8f2905`。见 `cli-green.txt`。
- 追加两个正常 CLI 导入对照均通过，退出码 0、数据逐字节相等、staging=0。见 `cli-normal-green.txt`，运行参数增加 `--normal-only`。
- CLI 二进制 SHA-256：`b13805cc2e89c9276c51190cd5671f4c0cbc84d1064ea7945b94e61dd96b81c5`，见 `cli-sha256.txt`。这是仓库构建产物的离线导入验收，不是 VM 启动验收。
- `NativeTransferTests`（含三个新增双后端测试）、`EnvironmentOperationTests` 和 `FirmwareReceiptPublicationTests` 共 29 项通过，17.396 秒。见相邻 `evidence/T30-swift-followup/focused-green.log`。其中 NativeTransferTests 用时 15.805 秒。
- 原 ProgressBar 断管/终端/tar 回归 7 项通过，见 `progress-regression.txt`。
- 集成构建期间暴露尾随闭包推断兼容问题和 `#expect` 对内嵌 throwing 表达式的宏展开错误。最终保留原公共 API 签名，以要求显式 `isCancelled` 参数的重载增加取消能力；全部调用点已检查，新测试先读取目录再执行断言。编译失败原始记录保留于 `evidence/T30-swift-followup/intermediate-build-failure.log`，没有将失败记录改写为成功。

完整标准 Swift 回归由协调者另行记录。本次不扩大为导出取消、队列退出或真实 VM 验收。
