# generation 准备入口独立审查

2026-10-13，实施与审查使用独立子代理。

首次审查未发现新增路径会替换已安装 ROM、Restore 或 Disk.img。`prepareWithSource` 从真实归档生成 Source；私有 scratch 的位置、原件摘要、磁盘身份及 desired plan 首次发布条件均核验。锁覆盖准备与元数据发布。测试通过不等于真实归档已验证。

随后真实 IPSW 场景失败，新增 `libraryDirectoryURLCanPrepareFreshArchives` 以 `VPhoneLibrary.url(forName:)` 的显式目录 URL 复现同一错误。目录父 URL 与 sourceDirectory 路径相同，末尾 `/` 导致 Foundation URL 比较不等。修复只将该处比较改为规范路径比较，保留符号链接解析和来源核验。49 项定向测试通过。

复核使用独立 Foundation URL 探测，检查 generation publish/load、KernelUpdate.prepare 以及 kernel-only 事务输入集合。未发现公开 library URL 调用路径上的其他同类阻断。新增测试覆盖准备、generation 发布和 desired plan 加载。审查者未独立重跑 Swift 测试。

回退审查：`--recover` 对未提交事务执行恢复，对 committed 事务只核验与归档。当前没有公开的 archived-transaction rollback。发布旧计划并重新生成内核不保证恢复更新前精确磁盘或来源，不能作为该结果的验收证据。
