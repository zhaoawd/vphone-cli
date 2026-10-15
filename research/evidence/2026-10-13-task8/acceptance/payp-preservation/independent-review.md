# PAYP 保留修复及第八版读回脚本独立审查

日期：2026-10-14。审查者：acceptance_audit。仅检查源码、合成和真实导出文件回归日志、冻结 manifest 及第八版快照/读回脚本；未执行测试、挂载、VM、attach 或 AMFI 操作。

结论：本次冻结源码未发现阻断问题，可用于构建签名工件。真实导出文件回归支持 description/PAYP 保留修复；第八版快照及提交读回脚本未发现新增阻断。此结论不证明真实更新、启动或提交后回退完成，先前启动异常原因仍未查明。

## 生产修改

FirmwareKernelUpdate 从实际 producer.input 读取原始 IM4P，再核对完整文件摘要与 produced.inputSHA256。元数据源为可信 generation 原件，不从已经缺失 PAYP 的安装目标复制。原件的 description 和 PAYP 原始 TLV 保留；producer 提供已经解码并验证的 payload。

repackKernelPayload 要求单一 DER sequence、IM4P/krnl 类型、ASCII description 和非空 payload octet。额外字段仅接受规定的 compression-info 和单一 PAYP；未知、加密、重复、顺序不符合规则和结构不符的字段拒绝。PAYP 检查名称/私有 tag 对应关系、重复名称及 primitive 值类型；PAYP 内字符串 marker 不代替结构识别。长 tag 读取有界，长度累加检查溢出，截断或容器外字段拒绝。未发现本次解析差异导致的越界访问。

当前支持 NONE 和 LZFSE 原件。LZFSE 标记与 compression-info 必须同时存在，声明解压长度必须等于实际解码长度。输出为 raw producer payload，因此不保留旧 compression-info。LZSS 在调用 vendor 解码前显式拒绝。携带 PAYP 时要求原件解码长度与 producer payload 长度相同，避免保留与新长度不一致的元数据。本次没有修改 vendor 压缩/解码代码或内核补丁算法。

swap 继续保留目标 IMG4 的原始 IM4M/IM4R。提交候选及发布后读回新增完整 im4p.data == replacement 比较，原有 payload/effects/DSC 和来源资格检查保持；proof 新增 im4pSHA256。没有以 payload 相等代替完整 IM4P 元数据检查。

## 回归证据及限制

red.log/red-repeat.log 两次运行旧封装行为，固定 description、replacement 与 pristine 不同、修复后的目标与期望 IMG4 不同三项断言均失败。不是编译失败。green-real-supported.log 中 metadata/swap 汇总 9 个测试、2 个 suite，无失败，包含 13 项参数化拒绝场景与实际导出文件重建。

实际导出原件 SHA `b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac` 匹配第七版 proof.inputSHA256；原件为 LZFSE，解码长度 43,991,040 字节。该原件的 description/PAYP 与基线一致。实际 helper 将 producer payload 放回原件元数据并替换错误目标后，结果与基线 IMG4 逐字节相同，SHA 为 `5b90c5a0ee87bf810c7e90795d537265f39774fbf85c430263fd2f61fc41ce7a`。这是纯导出文件证据，不是本轮重新读取 VM 原件。

最终 task8-targeted-green.log 汇总 37 个测试、6 个 suite、无失败；actualCandidateRegionUsesSourceFlow 因独立 selector 未设置而跳过，不能写为 37 项均实际执行。actualPristineMetadataRestoresBaselineContainerExactly 已实际执行并记录精确重建。测试覆盖变更 payload、幂等、opaque manifest/restore bytes、伪 marker、LZFSE 旧压缩信息移除及拒绝路径。

green-real.log 的早期 trap 发生在 vendor LZSS 压缩器构造测试输入的阶段，不是 repack 执行失败。原日志保留；当前实现明确拒绝 LZSS，不宣称已支持该格式。

## 第八版快照和读回脚本

pre-update-v8-snapshot.py 在限定副本目录锁下要求无 pending、无当前磁盘附件；对六文件计算完整摘要并比较读前/读后 device/inode/size/mtime/ctime，要求 inode 保持。Disk SHA 必须等于第七版提交结果；同时保存当前 binding 和 receipt 摘要。该脚本只有成功后输出 passed=true；本次审查未执行它。

committed-readback-v8.py 保留先前审查的锁、归档关联、receipt/report/effect、producer manifest、唯一只读 Preboot、UUID/目录身份、异常卸载及最终残留失败判定。非 Disk 文件内容改与 pre-update-v8-snapshot.files 比较，能够区分前次启动造成的已知状态变化与本次离线更新效果；不再错误要求 NVRAM 恢复早期基线。

实际安装后的 raw IM4P 摘要必须等于 proof.im4pSHA256；完整 IMG4 摘要必须等于已核验首次绑定备份的基线摘要。在本次 payload 仍相同的设置下，这一强断言能证明 description/PAYP 及完整容器恢复为基线字节。它不能证明不同 payload 更新或正常启动。DSC 仍由正式 commit 的生产验证提供，不由该脚本独立重跑。

## 冻结输入

| 文件 | 独立计算 SHA-256 |
| --- | --- |
| VPhoneKernelcacheSwap.swift | `03aafe9cdf1719a06c2eb531ba118188d21771c01f80744b099a862fe5f97b3f` |
| FirmwareKernelUpdate.swift | `2a8455d23b7601774caa833e24623b608053687a15aed515143bd61a7b18933b` |
| KernelcacheMetadataTests.swift | `f5df99ca4c9e879a119ec71e7a879f6b99301a4b5342f227cd21b2bc120cc3da` |

三项与冻结 manifest 一致。后续真实更新须使用包含这些字节的新冻结工件；旧工件及失败日志保持。提交后 kernel-only 回退入口尚未实现，不能将未提交恢复作为其验收。
