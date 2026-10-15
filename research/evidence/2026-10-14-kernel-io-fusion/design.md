# 内核 I/O 第二、三项优化范围（2026-10-14）

本轮修改当前工作区源码及测试。冻结 V9、已有验收证据和已安装产物保持。测试使用独立普通文件；不操作 VM 或 AMFI。

## 第二项

仅合并 kernelUpdate 回调中的候选摘要比较与 kernelMount 的挂载前摘要计算。withVolumes 接收预期摘要，仍实际读取镜像并在 attach 前比较；detach 后重新计算完整摘要。事务入口 SHA、尾部 SHA、session.recheck、generation 输入、计划、report、binding 和 metadata 循环重验保持。

published 成功路径由 5 次整盘 SHA 降至 4 次，candidate 回调由 3 次降至 2 次。不实现 5→2，不跨回调或阶段缓存。operations.volumes 工厂现在先于唯一的挂载前 SHA；工厂返回的 attach/inspect/detach 均在原有校验范围内。生产默认工厂返回 nil；合成工厂只提供测试操作。新挂载前校验拒绝工厂留下的错误镜像；任意并发修改后恢复的所有时间窗口与旧实现等价，尚未证明。

## 第三项

capture 保留 live 和 candidate 的初始完整 SHA、复制及三次 sync。同步后以 1 MiB 双流扫描同时计算两份 backup 的 SHA 和 4 KiB 差异。结束后再次计算 live SHA，并核对两份已打开 backup 的类型、链接数、长度、inode、mtime、ctime 以及路径关联。每份 backup 的摘要必须与相应源文件的初始摘要一致。单次完整 SHA 计算仍为 5 次；两份 backup 不再另行读取计算 SHA。显式扫描逻辑读取由 7 倍镜像长度降至 5 倍，不含复制内部 I/O。

同步顺序保持 old→new→root，比较扫描移至同步后。失败发生于事务准备阶段，尚未发布 Disk.img 或 metadata。不得通过扫描前计算的摘要替代同步后的校验。持久块、cursor、pending、发布、反向恢复及同步实现保持。扫描内存仍为两个最多 1 MiB 缓冲和两个 SHA 状态，不保存整盘内容。

## 验证

- 挂载前预期摘要不符时不 attach；attach/body/inspect/detach 留下的镜像变更拒绝；detach 失败拒绝。
- capture 覆盖短读、EINTR、EOF、尾块、两份 backup 的字节篡改、长度、路径替换、符号链接和硬链接；修改后恢复字节仍须通过文件状态检查拒绝。
- 重跑差异、pending、发布/恢复、更新/回退及内存测试。
- 使用 opt-in trace 核对 capture 的 3 次独立 SHA 和 2 次融合 SHA、每流实际字节及 published 回调整盘 SHA 次数。不根据读取遍数推算耗时收益。

任意并发修改时序下的完全观察等价和真实 VM 行为不在合成回归的证明范围内。第二项剩余摘要合并继续需要内容稳定性与故障恢复协议设计。
