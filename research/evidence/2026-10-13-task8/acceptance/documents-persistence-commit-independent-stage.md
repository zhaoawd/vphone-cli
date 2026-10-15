# Documents 跨回退验收：commit 阶段独立核对

本阶段通过。完整 Documents 持久性结论尚未建立；跨 R_B 的 V4 boot、原 marker actual file_get、formal stop 和 cleanup 待根任务通知最终文件齐备后另行审查。

本次只读取 saved E8 小型文件，并调用冻结 verifier 的纯 `validate_commit` 验证 A、历史 B 和 R_B；没有运行 verifier main、freeze helper、CLI、VM、磁盘读取、大文件 SHA、Store、AMFI、进程查询或信号。所有已使用输入在结束前重新读取并复核身份和字节。阶段 JSON 保存完整输入 SHA256，日志保存校验结果；未覆盖此前审查。

R_B 正式命令记录为 frozen V9 CLI 的公开 `rollback-kernel --to-transaction 2901d975-2379-4b50-9340-8580786aacc1`，exit 0，记录耗时 4283.967677116394 秒。新 transaction 为 `0d6d197a-8b24-4944-bb38-16a60ed24fb0`，journal version 4、phase committed、cursor 49/49、pending=false，saved actual readback 的 remaining_attachments 为空。

独立核对的关联包括：trusted producer/version/executable、期望 plan/desired、live desired 与 binding 双 CAS、原始盘摘要与 operation-before、候选盘摘要与 receipt/proof/readback、journal/report/receipt/proof 原始 JSON 摘要链、120 effects 与 report records、六文件 inode 保持及其他五文件 SHA 保持。R_B 的 currentDisk 起点使用 post-reboot operation-before，未把历史 B 整盘作为回退目标。

R_B payload 与历史 B 的 `a89e2e786dc61d93b14ea129072bc762594ca4cd1f54719810ea1cbf99c0e2c0` 相同，与 A payload 不同。IM4P、IMG4、description、PAYP、IM4M 和 container envelope 均与历史 B 的 saved actual readback 相同；description/PAYP/IM4M/container envelope 同时保持 A 的对应值。历史 B 的原始 journal/report/receipt/proof 和 IM4P 摘要重新构成 targetEvidenceSHA256，结果与 R_B selection/proof 一致。

saved actual readback 的 Disk SHA256 为 `a30f80c18c00e914ebe15973d819d40a41545bb33a33e250ee3bacc43c935b1b`。本次没有重新读取或散列 Disk.img；这里只核对保存的实际读回结果及其摘要链。

旧 tmp ENOENT 记录仍为 passed=false，SHA256 保持 `af26e5130253333e99034296d5e31c055bf4e13d0d2e43a56222f447fcc05835`，并继续锚定历史 B 的 committed receipt。未更改旧失败或将其写为通过；旧 marker 消失原因未由本阶段确定。
