# 2026-10-18：CFW 只读 Cryptex 来源硬链接

## 问题与证据

用户完成管理员验证后，r2 的第二次 CFW 通过只读字段检查，随后在 `guest file changed during snapshot` 失败。归档为 `20261018T140729Z-nJUroQrY`。原磁盘没有交换；dev/inode/size/mtime 和 66 段采样摘要保持，该结果不包含整盘内容比较。

对同一缓存作独立只读挂载后，单独快照 `System/Library/Accounts/DataclassOwners/Bookmarks.bundle/_CodeSignature/CodeResources` 即复现原错误。文件长 2467 字节，`st_nlink=38`。读取前、读取后、路径指向的设备号、inode、长度、链接数、mtime 和 ctime 全部相同；单链接副本的快照通过，摘要与原文件一致。内核 `fstatvfs` 的 `f_flag=3` 包含 `ST_RDONLY=1`。

实际失败发生在复制前的来源树读取。原判断将 `st_nlink != 1` 与读取期间变化共用拒绝条件，因此稳定的只读原件被拒绝。没有观察到该文件读取期间变化。

## 修复范围

正式 guest 入口先核对 invocation-local Cryptex 挂载、generation、镜像摘要和 source binding，再为该来源的树摘要与 source effect capture 显式传入 `readonly_source=True`。多链接普通文件只有在文件描述符所属文件系统明确只读时才能读取；读取后再检查只读标志，并核对 inode、大小、时间、链接数和权限/属主保持。

普通读者保持默认单链接限制。guest 写入目标、镜像原件和内容寻址 blob 未启用该例外。`cp -R` 在本机将来源硬链接复制为独立单链接文件；复制后仍使用默认严格读者核验。未增加 CLI 绕过参数，未改变证据 schema、补丁声明、DSC 指令或来源信任状态。

## 验证

正式 producer → final reader → Undo provenance 回归先重现相同错误，修复后通过。回归同时覆盖可写来源拒绝、默认读者拒绝、读取期间别名写入/链接数变化/路径替换、变为可写和 blob 硬链接拒绝。

```sh
PYTHONDONTWRITEBYTECODE=1 .venv/bin/python3 -m unittest \
  tests.test_readonly_source_hardlinks \
  tests.test_undo_provenance.UndoProvenanceTests.test_readonly_cryptex_hardlinks_are_copied_as_independent_files \
  tests.test_undo_provenance.UndoProvenanceTests.test_writable_cryptex_hardlinks_refuse_before_copy

VPHONE_DAEMON_API_BUILD_DIR="$PWD/.build/daemon-api-t59-20261015" make test_python
```

最终相关回归 147 项及硬链接回归 8 项通过；完整 Python 900 项（跳过 2 项）无失败，退出 0。同一真实只读来源的 2933 个条目、2093 个文件通过完整树读取与 effect snapshot；原诊断挂载已正常卸载。完整签名构建通过，第三次 CFW 冻结资源中的四个修改模块与源码摘要相同。

现有 Cryptex 复制夹具未覆盖这类只读来源硬链接；新增回归保留了实际调用路径和来源/目标的不同限制。

## 当前真实验收状态

既有 amfidont 已按用户此前批准的 `cad3fa35fa16672ad522b31564352ffd4276b469` 重启。本次进程不加载或修改持久允许列表，不使用路径或 allow-all 规则。本次操作未修改 SIP 或启动参数。新构建及第三次新冻结 VM 程序执行检查均退出 0。

第三次 CFW attempt 为 `1aac6854-0b8f-4206-9197-d40c599b8495`，本次管理员验证已生效，staged CFW 事务 `.cfw_disk.rDDZL4Bx` 正在安装。实际发布、撤销和正常启动尚未完成。此前完整 Swift 的 APIProxy 失败仍保留，单独重跑通过，原因未查明；本次修改没有 Swift 源码变更。

证据见 `evidence/T32-T33-new-vm-20261018/snapshot-hardlinks/manifest.json`。T32/T33 接受计数保持。
