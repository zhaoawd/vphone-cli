# 构建产物清理记录

日期：2026-09-19。

## 结果

清理前 `.build` 的表观占用约 252 GiB。检查发现一个运行中的 `vphone-cli` 进程使用
`.build/vphone-cli.app/Contents/MacOS/vphone-cli`，因此未执行 `make clean`，未删除该
应用包。

本轮只删除可由 SwiftPM 重新生成的编译缓存和元数据：主构建目录、索引构建目录、
测试与 SwiftPM module cache、插件、依赖 checkout/repository 缓存、构建数据库、
构建 YAML、锁文件及两个零字节的临时保存项。清理后文件系统可用空间由约 194 GiB
增加到约 196 GiB。具体释放量受 APFS 克隆和共享块影响，不能由 `du` 差值直接推算。

用户随后明确批准删除大型验收数据。本轮删除：`.build/d3/vm-regular`、
`.build/d3/vm-exp`、`.build/d4acc/lib`、`.build/d4acc/src` 中可由当前用户删除的内容、
`.build/c5/lib`、`.build/c5/prep` 和 `.build/c5/ipsws`。删除后文件系统可用空间约为
329 GiB，相对大型数据删除前的约 196 GiB 增加约 133 GiB。APFS 克隆和共享块使该值
小于清理前 `du` 显示的约 248 GiB。

`.build/d4acc/src` 仍有约 224 KiB root 所有的 Python 字节码。普通删除因权限不足；
本轮尝试 `sudo rm` 时当前会话无法提供 sudo 密码，因此保留该残留。其余上述目标均已
删除。

## 保留范围

- `.build/vphone-cli.app` 与 `.build/vphoned.signed`：前者正在运行。
- `.build/d3`、`.build/d4acc`、`.build/c5` 中的日志、JSON、脚本和对照结果；大型
  VM、固件输入与事务历史已删除。
- `.build/f1`、`.build/f3`、`.build/f3diag`：保留验收日志、运行记录和源码快照。
- 根目录 `vm*`、`vm.backups`、`ipsws`、`research/artifacts`：不属于本轮编译缓存
  清理范围，未修改。

上述大型验收目录可以重建，但重建需要重新准备固件、构建源码或重跑验收。删除后
本地原始实验数据不可直接恢复；研究文档和已提交摘要不能替代原始文件。
