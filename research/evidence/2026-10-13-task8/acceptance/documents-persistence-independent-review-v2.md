# Documents 持久性证据工具独立复审 v2

结论：本轮窄修复已解除前次 freeze helper 的两项阻断，当前工具审查范围内未发现新增阻断。此结论允许工具进入根任务安排的后续流程，不表示真实跨 R_B 的 commit、actual readback、V4 boot、marker、stop 或 cleanup 已通过。审查没有执行 helper/main、verifier main 或业务请求。

前次 `documents-persistence-independent-review.md/json` 和失败结论保留。`verify-documents-persistence.py` 与原 18 测试文件摘要均未变；该部分沿用前次静态审查和独立纯测试证据。本轮只复核修正 helper 与新增 8 个纯测试。

## 已解决的问题

helper 已拆为 guarded `main` 与纯 `build_expectations(evidence, live)`。模块导入只定义和载入验证代码，不会读取 live VM 元数据或写 expectations。纯函数直接复用 verifier 的 `validate_commit` 和 `validate_rebind`，要求正式 schema4 committed/public rollback/target B/readback 合同、完整 host4 command/target_version、before→after 的 binding 变化范围，以及 receipt/desired/journal/proof/六文件 metadata 不变合同；owner 的 label、after uid、双侧 gid/mode 和 inode 关系也由同一验证器检查。

helper 另要求 host4.before binding SHA 与 committed journal 中 launchpad metadata output 相同，live binding 字节摘要与 host4.after 相同，live receipt 与 committed artifact 逐字节相同，live desired B 摘要与 after 和 operation-before 相同。`FrozenInputs` 在返回或抛错前重新读取全部已使用输入；输入身份变化会拒绝。上述校验均为显式 `require`，AST 检查没有可被 Python 优化移除的 assert。

main 的静态路径要求无参数、输出不存在，以 `O_NOFOLLOW` 打开 VM 目录并取得非阻塞独占 flock，再拒绝 transaction/desired pending。它使用既有 marker 工具的 strict_read 读取三个有限大小、普通单链接的小型 live 元数据文件；构造 expectations 后再核对相同字节，最后通过 verifier 的 `O_EXCL` 输出并 flush/fsync。关闭目录 fd 释放锁。此次没有实际执行这条路径，目录锁、当前 pending/live 状态和输出持久化效果只作源码检查，未写成实测通过。

## 纯测试与限制

独立运行新增 8 个测试，普通模式全部通过，用时 0.545 秒；`-O` 模式同 8 个全部通过，用时 0.549 秒。两次均在导入前屏蔽真实 subprocess、process/signal、`os.open` 和 `fcntl.flock`，测试期间还将 helper.main 设为拒绝入口。因此，这些测试只执行内存 evidence/live seam 和读取既有小型 fixture；没有打开 VM 目录、读取 live 元数据、发送信号或写 boot expectations。

新增测试覆盖正式 rebind command/target/exit 错误、kernel/receipt/desired/journal/proof/files 变化、owner label/uid/gid/mode/inode 错误、live 字节与摘要变化、preview 与未 committed phase、源输入身份变化及无 assert。根任务保存的普通和优化模式测试也均为 8 项通过；它们与本次独立执行日志分别保留。

helper SHA256 为 `4b4da22297aa7dc636e8ab668090b29f0c0d97db2396e5edecb20979876acca2`，新增测试 SHA256 为 `6a556ab007b359d55bc69971e96d76b7839cc149b3fc7a7be6be0bf6abdba96d`。完整摘要和独立测试日志引用保存在同名 JSON。真实完整持久性结论仍须由根任务在全部 saved evidence 齐备后统一运行 verifier；missing/pending 和旧 tmp failure 的拒绝及保留要求保持。
