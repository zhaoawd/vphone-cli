# T60：真实归档分配量观察（2026-10-21）

原因未查明。真实 system-tar 导入后的内容核验通过，但源盘与目标盘的物理分配量不同。native 真实导入两次在保留空间不足时取消，尚未完成完整往返；不能将小夹具通过提升为64GiB真实盘通过。

## 已确认事实

源为停机 `vm-new` 的 APFS 克隆，Disk.img 逻辑大小68,719,476,736字节，源分配24,966,512,640字节。导出为15,564,157,664字节的native `.tzst`，归档SHA256 `8a3cdc9ce63a5350ce05f6f4658e1434b5ca48d8a1d218fb8c01051b1b82bd9d`。归档的Disk.img为GNU tar普通文件头，type=0，无sparse map。源盘flags=0，无UF_COMPRESSED。

当前r3签名CLI的system-tar导入完成。Disk.img完整SHA256与源相等，另外七个持久文件也逐一相等；源盘和归档保持，无import staging，未启动VM。目标Disk.img分配66,582,839,296字节，明显高于源盘。只读抽查0、16、32、48和60GiB偏移的1MiB均匹配；32、48、60GiB的抽查区间均为零。该抽查只是诊断辅助，最终内容结论来自完整摘要。

native第二次实际导入每秒采样86次，观察到最大分配66,591,965,184字节。进程在4GiB保留下限触发后退出130，staging清理，未发布。1秒采样最小空闲4,341,760,000字节；该采样间隔不能确定触发瞬间的最低值。保留量检查每0.2秒执行；实际持续时间低于1800秒上限，导入场景没有归档大小上限条件，因此本次中断由空闲空间条件触发。

## 诊断实验

使用 [diagnosing-bugs](</Users/kolar/.agents/skills/diagnosing-bugs/SKILL.md>) 的反馈循环。尚未建立能快速复现真实源/目标差异的最小回归，因此没有据猜测修改归档实现。

| 实验设置 | 结果 |
| --- | --- |
| 256MiB连续零区间/间隔零区间 | 两个场景通过内容和低分配检查 |
| 4KiB数据、16/64/256KiB步长 | 源/目标分配量分别相等；完整内容一致 |
| 12GiB逻辑文件，0、8GiB及尾部各4KiB数据 | 源/目标均49,152字节分配，完整内容一致，10.652秒 |
| 256MiB逻辑文件，1/64/128MiB非零前缀 | 三个场景源/目标分配量相等；内容一致 |
| 上一项增加尾部4KiB非零数据 | 三个场景源/目标分配量相等；内容一致 |
| r3实际签名CLI、1GiB稀疏盘及两条硬链接 | 源/目标盘均16KiB分配、完整摘要相等，硬链接共享inode |
| 旧具名签名CLI、同一正式稀疏盘/硬链接回归 | 通过 |

第一次16KiB步长实验错误要求目标小于逻辑大小的一半；当时源本身已占满256MiB，不能代表真实源/目标分配差异。后续实验改为直接比较源/目标分配量，未声称这些实验复现或修复了真实问题。探索源码保存在明确的诊断文件`sparse-diagnostic-probes.swift.txt`，未加入常规ArchiveSafetyTests。实际CLI稀疏盘/硬链接合同保存为正式`RealCLISparseTests`，纳入正式CLI测试入口。

已读取生产`VPhoneArchiveWriter`、`VPhoneArchiveExtractor.copyData`和`VPhoneArchiveExtractOptions.extractFlags`：当前选项含ARCHIVE_EXTRACT_SPARSE。核对的[固定libarchive源代码](https://raw.githubusercontent.com/libarchive/libarchive/27cbc7827172698143e440801fc0ba39ccb4f1f5/libarchive/archive_write_disk_posix.c)在该选项下跳过前导零字节，并按文件系统块边界写入。这项代码检查不解释当前实际分配差异，也不证明环境行为相同。

## 恢复条件

此前按源物理分配量估计容量不足以覆盖本次真实行为。验收脚本已改为未排除payload的逻辑大小上界，加4GiB保留；当前保守预检为73,766,043,199字节。运行时空间监测仍保留。

当前system-tar测试副本保留在`.build/t60-remaining-20261021/real-vm-r3/import-system-tar/restored`，完整结果在同目录上层的`result-system-tar.json`。已请求用户批准删除这一具名测试副本以释放约62GiB；未获批准前不删除。原VM、归档、源克隆和验证结果均保留。native失败的空目标目录已分别改名保留，新的`import-native`路径可供后续正式复验。

证据见`evidence/T60-resume-20261021/manifest.json`及其中的原始采样、结果、诊断源码和日志。当前没有分配量问题的已验证修复；T60继续保留native真实大盘、实际create/restore退出和更广历史组合的未验证范围。

## 用户批准清理后的最终复验

用户明确批准删除本次`import-system-tar/restored`测试副本。只删除该具名副本，原VM、归档和验证结果保留；空闲空间从10,813,440,000字节恢复至77,824,000,000字节，超过保守预检要求。

同一r3签名CLI、同一归档的native导入随后通过。64GiB Disk.img及另外七个持久文件完整SHA256逐一相等，原VM和归档保持，目标发布且无import staging，未启动VM。目标盘最终分配29,551,001,600字节（约27.5GiB）；本次每秒采样中的最低空闲47,923,200,000字节，最后一条CLI运行采样为56.186秒，之后脚本继续执行完整摘要核验。

本次没有修改生产归档实现，不能把充分空间下通过写成分配量差异已修复。前两次中断及system-tar目标高分配量与本次结果的差异原因仍未查明。资源要求以保守逻辑大小预检和持续4GiB保留量监测为准。最终证据见`evidence/T60-final-20261021/manifest.json`。
