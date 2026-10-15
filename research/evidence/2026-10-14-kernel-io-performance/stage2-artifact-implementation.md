# KernelDisk 1 MiB 读取实现

本实现仅位于隔离优化副本。计时阶段通过后才修改 capture/validate 和最小 reader seam；原工作区、已签 V9、VM、Store、AMFI 均未操作。本文不是性能验收结果。

capture 仍对 live/candidate 各做一次 SHA256、复制两份快照、按原顺序同步 old/new/root，再做原有三次 SHA256。validate 的 identity、cursor、offsets、pending、old/new 摘要和 interrupted 摘要门保持。isWritePrefix、publish、reverse、readBlock、writeBlock、fsync 和 journal 语义保持源码原样。

新 reader 在原 FileHandle.fileDescriptor 上 pread，不拥有或关闭 fd，也不改变 descriptor 的当前 offset。FileHandle 的打开和 defer 关闭保持。读取参数检查 count<=1MiB、off_t 可表示范围和整数溢出；固定 Data 内原位填充。EINTR 重试同一位置，正数短读继续填充；提前 EOF 拒绝，其他负数保留 POSIXError。每次 reader 调用先增加 attempts，成功正数字节立即增加 bytes，因此后续 EOF/error 不会丢失此前已读字节。native adapter 紧接 pread 保存 errno。

扫描开始对已打开的普通文件 fstat 取长度：capture 两备份等长；validate old/new/live 均须等于 journal size。按 min(1MiB,remaining) 填满一批，再逐 4096 字节判断变化和 cursor/pending/interrupted。所有切片以各自 Data.startIndex 推导。offsets、持久写入、恢复 cursor 的单位仍为 4096；最后不足块使用实际剩余长度。主扫描缓冲逻辑容量 capture<=2MiB、validate<=3MiB，不缓存整盘。offsets 数组、原有 SHA256/复制实现的工作内存不属于这项缓冲容量，保持原有行为。

pending 仅在当前 4096 子块处理三个零基副本。from 先在内层 pool 构造并清理 interrupted 文件读取的临时对象，随后构造 to/current，三副本容量合计<=12KiB。现有 isWritePrefix 按同一 index 索引三份 Data，因此不能直接把非零起始 slice 和零基 interrupted Data 混用。非 pending 仍比较完整子块，未列入 offsets 的区域也不能跳过。

每批和每个逻辑块都有 autoreleasepool。EOF 必须以 pread 在显式 offset=size 探测，因为 pread 不推进 FileHandle 当前位置。独立审查发现，仅 probe live 会遗漏 old/new 在预哈希和 length 检查后、最后不足 4KiB 尾块读取前增长的拒绝边界。根任务运行实际 validate seam 测试，RED02 一个 XCTest 出现两处未抛错失败，确认缺口；RED01 是编译失败，不计为功能 RED。现已补 old→new→live 三个 EOF probe，按照 guard 短路，未执行的 probe 不补计数；0 返回增加 attempts、不增加 bytes。当前修复只有 frontend parse 通过，完整 GREEN 由根任务继续执行。

compare span 的 read_calls 在新实现表示 native pread attempts，包括 EINTR/EOF/errors；bytes 表示正数 pread 返回量，失败前的部分读取也保留。labels 明确 native_pread，与基线 FileHandle API 调用计数区分。baseline FileHandle 调用次数不能写成真实 syscall 次数。logical_bytes/blocks 只累计已完成校验的逻辑块，不能替代失败前实际读取量。注入 reader 时 attempts 是 seam 调用次数；正式默认 adapter 每次恰好对应一次 pread。测试中的 expected 诊断行不代替实际 trace 字段核验。

新增 FirmwareKernelIOReaderTests 当前包含 10 个方法：小块短读和 fd offset 保持；实际 capture/validate 的 1/4095/4096/4097 上限短读；首轮与中途 EINTR；部分正数后 EIO/提前 EOF 的实际统计；生产 seam 错误拒绝且 live 不改；合法 EOF/零长度请求；非法范围、offset/count 溢出、无效 reader 结果、计数溢出和 EBADF；已知长度不符与 live 尾部增长；非零 batch slice 和 interrupted reverse pending；old/new 最后不足块的晚到增长拒绝。文件为独立合成普通文件，未使用真实 VM 输入。

新长度预检和精确填充是更严格、明确的拒绝条件。等价目标是相同稳定普通文件的 4KiB 逻辑判定，不是逐次模仿旧 FileHandle 可能短返回的观察序列。旧算法假设每次 FileHandle 读取得到完整 4KiB 或最终尾块，不能据此宣称任意短读完全等价。扩大批次会改变多流读取的时间窗口；这些检查不能提供对任意并发修改时序的绝对快照保证。原有目录锁、摘要、identity 和写前校验仍承担原本的边界，不新增缓存 authority。

本轮只执行 frontend parse；完整构建、回归、实际 trace 和交替多轮基准均由根任务统一安排。没有整条 CLI 的性能 RED/GREEN，也未推算收益。
