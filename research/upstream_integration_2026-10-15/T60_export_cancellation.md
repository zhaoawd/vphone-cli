# T60：导出取消、归档发布与 Launchpad 保留规则

日期：2026-10-15。继导入取消之后，本次接通导出 CLI 的 SIGINT/TERM、两种后端的取消检查及目标归档发布。实验只使用临时库和合成文件，未启动 VM，未修改已安装工件或系统配置。

## 原问题与 RED

真实旧 CLI 的 system-tar 后端直接向最终路径执行 `tar -cf`。目标已有内容为 `keep existing archive` 时，命令退出 0，目标内容被改写。复现脚本与输出：`evidence/T60-export-cancellation/reproduce_existing_output.py`、`existing-output-red.txt`。

消费者检查发现 Launchpad 在任务取消后，根据“导出开始前该路径不存在”删除最终路径的普通文件。该条件不能证明文件由本次导出创建，也不能证明文件未完成。新增 library→stand-in CLI 回归分别先发布完整输出、由另一写入者创建目标，然后触发 UI 取消。旧实现两种情况均删除文件，测试因目标不存在而失败。记录：`evidence/resume-swift/launchpad-export-red.log`。

## 修改与路径规则

- `VPhoneBundleOps.export` 保留原公共签名，新增显式 `isCancelled` 重载。CLI 使用现有取消控制器接收 SIGINT/TERM，并绑定生产端、消费端 tar 的已有取消管理。
- 两后端写入目标父目录下 `.vphone-export-<UUID>/output`，临时目录权限 0700。native writer 自身的内部临时文件仍在该私有目录内。
- 后端完成且最后一次取消检查通过后，使用 `renamex_np(..., RENAME_EXCL)` 发布。并发创建的目标不会被替换；未发布的本次 staging 在异常、取消或成功返回时清理。
- rename 是提交点。提交前取消不发布；提交后到达的取消不删除已完成归档。
- 已存在的最终文件、符号链接和悬空符号链接均拒绝。既有目录仍按 `<VM name>.<compression extension>` 自动命名，自动名称冲突同样拒绝。
- 父目录必须已经存在；父目录符号链接解析为真实路径。既有目录的符号链接也可作为输出目录。源 bundle 树内的目标拒绝，避免临时归档被包含进源归档。
- 此次不增加针对其他进程恶意替换父目录的目录文件描述符绑定，也不宣称掉电持久性保证。

Launchpad 不再在取消后删除最终路径，相关删除辅助函数已移除。CLI 负责其私有 staging；已提交输出、并发目标及旧 CLI 留下但无法确认归属的部分文件均保守保留。现有目标即使旧调用传入 `replacing: true` 也拒绝，防止保存面板的覆盖确认使旧 Bundle CLI 直接覆盖归档。UI 中英文说明同步为选择不存在的新目标、取消请求和保留已完成归档。

## 验证

真实 CLI 命令：

```sh
.venv/bin/python research/upstream_integration_2026-10-15/evidence/T60-export-cancellation/accept_cli.py .build/debug/vphone-cli
.venv/bin/python research/upstream_integration_2026-10-15/evidence/T60-export-cancellation/reproduce_existing_output.py .build/debug/vphone-cli
```

脚本生成一份 256 MiB 常规源文件，四个取消场景依次复用。仅向本测试创建并核对身份的 CLI/tar 进程发送信号；测试清理前再次核对启动时间与命令。

| 实验设置 | 结果 |
| --- | --- |
| system-tar 消费端暂停，CLI 收到 SIGINT | 退出 130；生产端与消费端均回收；staging=0；最终目标不存在 |
| system-tar 生产端暂停，CLI 收到 SIGTERM | 退出 143；生产端与消费端均回收；staging=0；最终目标不存在 |
| native 写出中 SIGINT、SIGTERM | 分别退出 130、143；staging=0；最终目标不存在 |
| 两后端正常导出，再由相同后端导入 | 均退出 0；导入 Disk.img 内容逐字节相等；无导出 staging |
| 两后端已有目标文件 | 均退出 1；目标字节保持 |

四次取消后，源 Disk.img SHA-256 为 `51757b6a6998f158920c6826b4ac4603a3cb00b57bcc32f2d9e5e019743986f5`，源 config.plist SHA-256 为 `29e7a5cabfdc692c1c4af07175def6f5d93e778492916ef66b4ca583623f1a04`，均与测试前一致。相邻已有归档标记也保持。随机合成内容每次运行的摘要可不同。

证据：`cli-green.txt`、`existing-output-green.txt`、`cli-sha256.txt`，均位于 `evidence/T60-export-cancellation/`。

库级 `NativeTransferTests` 新增参数化回归覆盖：常规文件与符号链接目标、缺失父目录、源树内目标、目录自动命名冲突、父目录别名、临时目录权限、取消后原件保持、进度回调取消、进度回调创建竞争目标。native 回调注入检查内部 writer 已完成 staging/output，system-tar 在传输进度回调注入，不将后者描述为后端完成后的回调。该套 15 项已通过；首次组合命令整体失败来自同时运行的另一项预期 RED，不应把整条命令记录为成功。

最终合并定向验证包含 `NativeTransferTests`、`EditLibraryTests`、`ExportOutputTests` 及并行任务的时限回归，共 8 个 suite、54 项测试通过，耗时 21.266 秒。Launchpad 回归覆盖已提交输出、并发目标、旧 CLI 未确认归属的输出，以及 `replacing: true` 仍拒绝既有文件。日志：`evidence/resume-swift/final-focused.log`。最终源码稳定后由协调者启动标准 Swift 全量，本记录不预先声明全量结果。

首次标准 Swift 验证的 1507 项中，`BundleOpsTests.exportAndImportReportProgress` 报告 1 项失败：system-tar 的传输计数包括归档头和对齐字节，本轮新增的结束回调却使用成员逻辑大小，使末次计数从 1074278400 回退到 1074267272。已移除 system-tar 新增的结束回调，保留原始传输字节计数；CLI 仍由 `bar.finish` 完成显示。原回归断言保持，两后端、两压缩格式的互通测试增加非空与单调性断言。受影响的 `BundleOpsTests`、`NativeTransferTests` 共 41 项通过，耗时 26.411 秒。RED 日志：`evidence/resume-swift/standard-final.log`；GREEN 日志：`evidence/resume-swift/export-progress-green.log`。

## 仍未验收

本次没有完成全体 T60 的导入队列、应用整体退出等待、所有混合 Bundle 版本或真实 VM 迁移矩阵。旧 CLI 的部分输出由 Launchpad 保留，不能据此宣称旧 CLI 获得事务导出能力。标准 Swift 全量由协调者统一运行并记录。
