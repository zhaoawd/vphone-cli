# kernel 操作快照与提交后读回工具独立审查

结论：两项阻断均已修正。当前脚本可用于限定范围验收取证；已核对最终冻结生产 schema 3/4 与 proof 字段。审查仅读取源码、现有 JSON 和做 AST 解析，未执行工具，未操作 VM、挂载、guest 或 AMFI。

两工具均已固定六文件集合。snapshot/readback 开始和结束检查两个 pending 标记及 task8 根目录下全部附件。snapshot 结束重检 binding、desired、receipt 摘要；readback 通过前重检 binding、receipt 和 archive 四份 JSON 摘要，finally 再检查附件与 pending，异常将 passed 置为 false。

固定集合为 `Disk.img`、`nvram.bin`、`SEPStorage`、`config.plist`、`AVPBooter.vresearch1.bin`、`AVPSEPBooter.vresearch1.bin`。

当前字段与生产实现对应。update 使用 schema 3，rollback 使用 schema 4；两者 proof 的 producer 均为 `current-bundle-kernel-update`，rollback 额外有 `operation=kernel-rollback`。目标 plan/desired 与当前 desired CAS 分别比较；当前 desired 保持操作前摘要。rollback 的目标 UUID、payload 和完整 IM4P 与冻结期望关联。

现有读回链覆盖新事务 archive、live receipt、proof、report、Disk 全摘要和实际 Preboot。实际 IM4P 必须同时等于 archive artifact 和 proof 摘要；实际解码 payload 必须等于 proof，并等于从 pristine 原件按 report 有序记录完整重建的字节。每条记录检查 offset、等长非空内容、边界与当前 original 字节。基线 IMG4 尾部原始元素、source description/PAYP 逐字节比较；IM4R 保持也包括固定基线中 IM4R 缺失状态保持。

只读导出检查 image/device、APFS physical store、VolumeUUID、挂载目录身份、唯一普通 kernel 文件和遍历错误。导出进入 try 后，detach 失败或残留 Disk 附件会阻止通过；device 尚未赋值时有附件发现兜底。DER helper 的 main 有入口保护，导入不执行其写证据流程。VM 目录 flock 与生产 VPhoneVMLock 使用相同目录 inode，贯穿 hash 和只读导出。

最终版已增加 publication/receipt/proof/before desired schemaVersion 为 1、canonical UUID 和 metadata 名称不重复断言。前置输入解析/open/flock 失败会非零退出并可能留下已独占的空输出文件；该路径没有 passed 结果。root 保留此行为，实际执行使用完整冻结期望，失败后使用新 label。readback 记录 before.json 摘要并核对 label 可加强后续汇总关联。

证据范围：DSC 和 declaration rule 语义仍由正式生产校验建立。该工具未独立验证 Bundle 签名或重现 producer session。目标历史资格校验仍由生产 reader 建立，脚本只关联 selection/proof 中目标 evidence 摘要及冻结 UUID/payload/IM4P。不同 payload A/B、三次独立启动实例和 marker 保持须由最终联合证据证明；本工具不建立正常启动或全部 guest 文件系统保持结论。

审查脚本摘要：

- `snapshot-kernel-operation.py`：`b7841badaa65976ba874c04ae5e8dc47e45d07005d42b98ced328d17e32a9f04`。
- `readback-kernel-operation.py`：`6ec11470f4a6285e33d2d812d485f96f447f71108afc7e0c7025618f13576af6`。
- `container-format/compare-containers.py`：`32979bde3287e7732a054bcbeb73a9a94c550f197d85ddc85adb8c179c73f5ae`。

## 最终 envelope 字段与 host 重绑定补充审查

最终 readback 的 DER envelope 按 raw IMG4 magic TLV 加全部 IM4P 后 trailing TLV 拼接，等于生产 `container.leading + container.trailing`；两侧均不包含外层 sequence 长度。实际 envelope SHA 必须等于 proof.containerEnvelopeSHA256，并保存到结果。AST 解析通过，脚本 SHA 已同步上方最终值。

`rebind-acceptance-host.py` 固定正式 V9 CLI，只允许 V4/V9 目标，调用正式 bind-core-bundle；不自行写 binding，不启动 VM。产物独占创建，前后拒绝两个 pending 标记和 task8 全部附件。实际 `kernel-v9-plan-a-source9-host-rebind-check.json` 退出 0、passed=true：host 从 V4 变 V9，kernel 保持 V8；receipt/desired/proof/journal SHA 与六宿主文件 dev/inode/size/mtime/ctime 均保持。另独立解析已保存 binding artifact，JSON 与 after 一致且 SHA 等于 after.binding_sha256。

该 helper 的前后观测不自行持有 VM 目录锁，正式 binder 在变更期间取得锁；digest 使用普通 read_bytes。当前证据适用于 root 串行调度，不建立通用并发快照保证。六文件比较是 metadata，不是完整内容摘要。后续复用需保持串行，并核对保存 binding artifact 摘要与 after 结果。当前受限使用未发现阻断项。
