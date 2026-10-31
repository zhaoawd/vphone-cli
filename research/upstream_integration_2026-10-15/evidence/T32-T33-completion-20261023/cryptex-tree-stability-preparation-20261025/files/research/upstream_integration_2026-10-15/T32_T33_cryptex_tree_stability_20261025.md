# T32/T33 EXP 缓存树读取稳定性诊断（2026-10-25）

## 已结束的执行

用户批准计划`242f80d4a9b7dedd9e09fa59ad8918ad542436789bddca9b795ce3bb34714edd`后，原worker79703完成四项具名退役。删除前归档并读回255份小型记录，保存1363条完整清单；源备份10项删除前后完整读回及t33t保留检查通过。可用空间记录从56473042944增至90340343808字节（52.595→84.136GiB，增加31.541GiB），达到75GiB门槛。该记录不是独占extent测量。

同一worker完成12项写前完整备份和三类旧缓存移动保留，安装并验证`2.6.2-local.e12747163c76`，绑定及正式计划检查通过。首次on事务`20261025T043518Z-1urmPFY7`在EXP缓存SystemOS的可写挂载完成后、任何hv_vmm或camera DSC补丁前失败：`effect input changed during read`。

该次dev归档准备没有报错，但未进入基础安装和JB-2，不能据此声称实际dev部署或整个修复通过。首次CFW未发布，off/reapplied未执行。缓存源挂载和暂存磁盘正常卸载，事务未交换原Disk，暂存盘按正式失败清理移除。原Disk核验范围是dev/inode/size/mtime及66段采样，不提升为本次失败后的完整目标Disk摘要核验。

原worker79703、原认证session96536及独立收尾69948/session96444均已结束。源备份10项完整读回、581项计划输入、102项执行输入、8个保留磁盘身份及目标无挂载通过；root执行器完整复核12项写前备份及三类保留缓存。用户态独立收尾只读取相应公开证明，未独立读取root私有备份。

最终归档25文件摘要复核通过，manifest为`8192df5fce44f65ba8f42decd1e3e35cf97ca0dbe49fb38883852b6901d13d1c`，位置`evidence/T32-T33-completion-20261023/dev-overlay-outcome-20261025/manifest.json`。计划已失败结束，不重跑，不自动回滚；T32/T33整体accepted=false，未启动VM或AMFI辅助窗口。

## 复现入口与当前证据

工具：`tools/probe_t33_cryptex_tree_stability.py`。它只读取原缓存，分别制作全新APFS克隆，在克隆上执行与生产相同的`cryptex_source.tree`读取器；可写和只读两种挂载均使用`-owners off`。结束后正常卸载，并重新计算原缓存完整摘要与身份。测试克隆保留，没有删除原VM、缓存或失败记录。

执行命令示例：

```sh
.venv/bin/python -B -u research/upstream_integration_2026-10-15/tools/probe_t33_cryptex_tree_stability.py \
  --source .build/t33t-20261025/.cfw_temp/CryptexSystemOS.dmg \
  --output .build/t32-t33-completion-20261023/cryptex-tree-stability-20261025-user-r2
```

普通用户的两次重放均退出1：可写克隆报`Cryptex tree changed during read`；只读克隆的2931项读取通过。第二次记录初始2931项、末尾2933项，新增`.fseventsd`及`.fseventsd/fseventsd-uuid`，没有缺失项。只读对照成员集合保持，树摘要`8ca9292d96e176cc957bde0a5f775f8bc765f320ebe0395430b6a0a5efa4c02c`，单次树读取约4.76秒。原缓存完整SHA-256 `600c789470b94e733796f0a0158365177c275a918a34e4d0f9ee1f7cd5fcdbf6`及身份均保持。

这复现了同一读取路径的树稳定性拒绝，但错误尚未与原生`effect input changed during read`完全一致；原生发生变化的具体文件和字段尚未确定，原因未查明。未修改生产校验器或放宽变化拒绝。

## 待验证假设与下一项

1. 宿主文件事件记录在可写挂载后创建或更新成员。预测：root重放失败路径位于`.fseventsd`，只读对照保持。
2. `owners off`导致root读取时文件描述符和路径身份观察不一致。预测：失败记录主要为uid/gid等身份字段差异，且可能没有树成员增加。
3. 挂载后已有文件发生并发写入。预测：失败路径的size/mtime/ctime发生变化；若路径为DSC成员，不能将它归入仅宿主目录变化。

已请求一次同root身份诊断，PID13967/session53763当前等待macOS认证；尚无root诊断输出。该请求只在新克隆中挂载和读取，不安装、不执行CFW、不删除或启动VM。普通用户原始结果及两次工具源码/日志分别保留；没有重复请求root认证。

下一项是在同身份重放中捕获确切失败路径、before/after/named字段，保留可重复失败后再选择修复。root请求等待期间，仅完成日志和代码边界核对，不将当前假设写成已确认原因。
