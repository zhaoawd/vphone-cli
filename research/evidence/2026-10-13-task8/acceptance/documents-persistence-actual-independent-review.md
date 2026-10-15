# Documents 跨内核回退真实证据独立复核

结论：本场景通过。原始 Documents marker 在同 A 停机重启、随后公开回退到不同 payload 的历史 B 并启动 V4 后，actual file_get 的完整 1254 字节保持相同。R_B committed/readback、目标及双 CAS、V4 实例、正式 stop 和 cleanup 的保存证据关联通过。本结论限定这个 marker 和已核对的合同，不证明全盘用户数据相同；旧 tmp marker 消失原因仍未查明。

审查只读取保存的 E8 小型证据并计算其 SHA256。没有运行 verifier main、freeze helper、CLI、VM、磁盘散列、Store、AMFI、进程查询或信号操作。独立调用冻结 verifier 的纯证据校验，得到的结果与根任务实际执行保存的 `task8-final-documents-persistence.json` 完全相同；实际 verifier wrapper 为 exit 0，记录用时 0.12469816207885742 秒。结束前重新读取全部已用输入并核对身份与字节。结构化结果和输入摘要见同名 JSON，执行记录为 `documents-persistence-actual-independent-check.log`。

## Marker 内容与实例

路径为 `/private/var/mobile/Documents/task8-kernel-rollback-8f77ba93-3ef0-462a-985c-96f3facb748c`。原 create、同 A reboot read、跨 B read 的 actual file_get 原始响应 base64 均解码为相同完整字节，与 create 的 canonical 内容也完全相同。大小均为 1254，SHA256 均为 `a8faa4e5b805fd5a0ee0f8330296d168bb85f33c674748595d176df3714e418e`。

| 阶段 | PID | instance_id |
| --- | ---: | --- |
| 原 A create | 79393 | F8D80EFD-9D81-43E3-8103-E8B1D0910C34 |
| 同 A reboot read | 92399 | 3EF0B0A0-DB1C-4FBB-8E4E-CD8E3E15B888 |
| 回退历史 B 后 read | 94550 | CC37ACEC-BBFC-4797-800F-C2A791D86A05 |

三个实例 UUID 不同，process_started_at 严格递增。后两次读取只包含 capabilities/file_get/capabilities，目标与各自已接受 boot 相同；均引用原 create 的记录摘要、intent、VM 身份和固定 marker 内容。原 create 的 no-clobber 写入、显式 sync 和同实例 actual file_get 证据也重新校验。

## 公开回退、读回与启动

R_B transaction 为 `0d6d197a-8b24-4944-bb38-16a60ed24fb0`，正式命令使用 frozen V9 offline CLI，公开目标为历史 B `2901d975-2379-4b50-9340-8580786aacc1`。journal version 4、phase committed、cursor 49/49、pending=false，receipt 的 120 effects 与 report records 对应。producer/version/executable、原始 JSON 摘要链、live desired 与 binding 双 CAS、post-reboot operation-before 和候选盘读回关系均通过。保存的实际读回确认六文件身份及其他五文件 SHA 保持，Disk SHA256 为 `a30f80c18c00e914ebe15973d819d40a41545bb33a33e250ee3bacc43c935b1b`；此次独立复核没有重新读取 Disk.img。

R_B payload `a89e2e786dc61d93b14ea129072bc762594ca4cd1f54719810ea1cbf99c0e2c0` 与历史 B 相同，与 A 的 `d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb` 不同。IM4P、IMG4、description、PAYP、IM4M、container envelope 与历史 B 的保存实际读回一致；description/PAYP/IM4M/container envelope 同时保持 A 的对应值。targetEvidenceSHA256 由历史 B 原始证据字节重新构造并匹配。

正式 host4 rebind/owner 合同、receipt/desired/journal/proof 不变关系及 expectations 摘要通过。实际 VM command 指向 `2.6.20261016-local` 的 `vphone-vm`，使用目标 config、冻结 binding SHA 和 `--no-vphoned-update`。保存的 capabilities 与 guest-state 实际命令绑定 PID 94550/上述 instance；guest state 包含 Darwin 25.1.0 和 iPhone17,3。V9 在本场景承担离线 producer；没有将 V9 VM 写成已启动。

保存的正式 stop 对应相同实例 UUID/PID，launch 日志记录 graceful guest stop。cleanup 记录 passed=true、无 Task8 processes/attachments、transaction 和 desired pending 均为 false；源六文件 metadata、测试六文件身份、静态 config/ROM 摘要及 binding/receipt 保持合同通过。

## 保留的失败和归档边界

旧 `/private/var/tmp` ENOENT 记录仍为 passed=false，原始 SHA256 `af26e5130253333e99034296d5e31c055bf4e13d0d2e43a56222f447fcc05835` 保持，历史 V2 join 未被重写或宣称通过。新 Documents 场景的成功不解释旧 marker 消失原因。

首次 boot observer wrapper 为 exit 1，保存 traceback 明确在读取 root 所有、0600 的 research expectations 文件时发生 PermissionError。owner 修正证据记录内容、inode、size、mtime 和 mode 不变，SHA256 仍为 `172f2be852029e809715e3ed1d2ef9d1eb7e7297c66bcbe20c19719ca238d238`。第二次 observer 为 exit 0；其输出、boot-watch、marker 和 stop 均绑定同一个记录的 V4 实例。首次失败尚未加载 expectations，没有保存其 target witness，本审查没有补造该字段，也没有把首次失败写为通过。

stop wrapper 实际使用短标签 `R_B-vm-stop`。原始 JSON/log 均保留，canonical 两文件与原文件逐字节相同，分别为 SHA256 `8cb76cc4295f5a82cf8db7d60725a0c9e0e138128ae7192b7fef42c2bccd454d` 和 `b8d943871c9cab41473a73a35d30f785c73c4ac4e17018ffb3cbbb346de32264`。`documents-stop-evidence-archive.json` 与两侧实际字节匹配；没有因此重跑或改写正式 stop 命令。

## 冻结与范围

tools manifest-v2 的 8 项文件 SHA 全部独立匹配。该 manifest 的 stage/main_executed 是工具冻结时的历史状态，后续真实执行由 final wrapper/result 证明；未改写冻结清单。最终 boundary 保存记录的 28 项全部为 true，集合精确对应冻结 source16、V9 CLI、V4 CLI/VM、工具 8 项和旧失败；记录 SHA256 为 `0168392aa99a4b46d7b485b7525b59324cd0d292ba16fff585880870d5386ac2`。本审查读取并核对该保存记录，没有新增 installed binary/source 或磁盘散列。

真实成功范围是上述单个 Documents marker 的字节持久性、不同 payload 的内核回退和指定 V4 启停合同。它不等同于全盘用户数据一致性、旧 tmp 问题已解决、任意并发修改保证或其他版本 VM 验收。性能优化工件和生产代码未由本审查修改。
