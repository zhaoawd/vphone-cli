# T32/T33 当前执行清单

固定上游目标：`8a75092013eda87a4e30ed029b72028cb9279ac4`。
起点：`2df4be8c`。保留已有 Capstone overlay，不操作真实 VM。

- [x] 核对新台账、现有 Receipt/Undo、guest 写入链与上游同 ID 迁移实现。
- [x] 建立撤销当前字节、保留补丁及首次原件的失败回归。
- [x] 实现同 ID 实现形状判定与整组撤销/重打预检，不以 ID 或形状授予应用状态。
- [x] 从现有已提交生成固件 Receipt/report 恢复撤销证据，核对 generation 和原事务。
- [x] 新增 `fw receipts` 检查与撤销预览入口，记录缺失保持 unknown、损坏拒绝和 generation 约束。
- [x] 最终相关 Swift 72 项及 APIProxy 1 项通过；标准 Swift Testing 1527 项保留既有内核幂等 issue，APIProxy 标准运行失败后单独复验通过。
- [x] 标准入口后续限时组 9 项、tar/文件摘要内存与 guest 组件检查通过。
- [x] 更新 T32/T33 研究记录和台账，保留未完成范围和历史接受状态。
- [ ] guest DSC/Mach-O/Preboot 撤销、代码页重新证明及磁盘/Receipt/Undo/来源的同 journal 发布。
- [ ] 真实 guest on→off→on、旧 VM 缺 Undo 和中断恢复验收。

已确认限制：现有通用 Undo 仅为内存处理；guest 的普通 CFW 磁盘交换尚未接入 Swift 分组件 Receipt 的同 journal 来源发布。不能把生成固件证据提升为已安装 guest 证据，也不能自动信任旧 `.bak` 或导入 Receipt。

## 当前下一项：guest 发布检查点

- [ ] 保存缺最终证据仍能交换磁盘的失败回归。
- [ ] 在快照修改后重新只读核验，封存原计划、操作记录、效果报告和 blob 索引，与最终磁盘摘要绑定。
- [ ] 将检查点要求写入磁盘 journal；交换与中断恢复均核对，证据不一致时保留数据并拒绝确认。
- [ ] 增加历史读取与错误/中断回归，执行 Python 相关与全量测试。
- [ ] 更新研究记录与台账，保留实际 guest 撤销和来源发布的未完成状态。
