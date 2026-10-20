# T32/T33：已提交 Receipt 与撤销预检（2026-10-15）

起点为 `2df4be8c`，固定上游目标为 `8a75092013eda87a4e30ed029b72028cb9279ac4`。本轮修改生成固件的证据读取、字节撤销与只读检查入口，不操作实际 VM。T32/T33 整项尚未验收。

## 问题与证据

| 问题 | 已确认现象 | 验证 |
| --- | --- | --- |
| 保留补丁的当前字节未核对 | 原 `restoring` 只核对被撤销记录；同组件其他记录已经失效时仍返回恢复副本 | 修改前 `staleRetainedPatchRefusesWholeComponent` 失败 |
| 无首次原件的 no-op 记录可被撤销 | original 与 patched 相等的记录不能证明首次原始字节，原代码仍返回恢复结果 | 修改前 `noOpRecordCannotEstablishFirstOriginal` 失败 |
| 归档 producer report 未参与读取 | 原 `readCommitted` 核对 journal/Receipt 摘要及实际输出，但 report 缺失或损坏仍能返回记录 | 使用 HEAD 原文件执行 missing/corrupt 对照，两例均失败 |
| 改变 desired 后旧应用证据不可读 | 原读取路径通过当前 desired 验证旧 Receipt，选择改变后报告 qualification differs | HEAD 对照中 `changedDesiredPlanPreservesEvidenceOfActualCommittedPlan` 失败 |

失败日志见 `evidence/T32-T33-undo/red.log` 和 `receipt-baseline-control.log`。后者仅临时替换 `FirmwareComponentReceipt.swift` 为 HEAD 原文件，完成后已恢复候选；基线和当时的候选源码均保存。该对照退出 1，表示预期行为失败，不表示基线通过。

上游来源是已保存的 `evidence/git-audit/endpoint.diff`：`DyldSharedCacheUndoLog.swift` 与 `VPhoneCustomFirmwareInstaller.swift` 的差异，以及原始报告中的 DeviceHub #604。上游为 `dyld-boot-iomfb_force_kern` 识别旧 4 字节记录，撤销后重打 16 字节条件分发。本轮仅移植记录形状判定和撤销/重打的预检约束；没有移植条件分发指令，也没有声称本地 DeviceHub 已可用。

## 实现

`FirmwareComponentReceipt.readCommitted` 现在核对归档 report 的精确摘要，并将每组件 Receipt 的完整 PatchRecord 数组与 producer report 对齐，包括 originalBytes。只有当前输出、生成原件、VM 身份、已提交 journal、原计划及相关记录都通过，才返回证据。检查采用 journal 内产生输出的计划；后续 desired 选择不会改写旧应用事实。当前计划的写入资格继续由原执行门判断。

`VPhonePatchUndoLog` 核对同组件全部记录的当前字节和范围。撤销返回新副本、修改范围和剩余日志。重复应用保留首次 originalBytes；没有历史原件的新 no-op 不能产生撤销资格。添加记录核对完整输入/输出，拒绝未记录的变化、重叠和跨补丁覆盖。撤销后重打在内存副本运行 producer；producer 失败或记录不完整时不返回候选。

同 ID 的 IOMFB 实现形状分为旧形状、当前形状和未知。缺记录、混合长度及未知长度不判定为当前形状；形状本身不授予可信或 accepted 状态。重打该 ID 后仍是旧形状时拒绝结果。测试使用合成字节，未验证真实 IOMFB 指令或显示行为。

`FirmwareComponentUndo.load` 从现有已提交 Receipt/report 恢复不可直接解码构造的 Snapshot，不另设一份权威 Undo sidecar。每次生成撤销或重打副本前后，重新验证持久化证据和实际输出。当前只接受可按字节恢复的 generatedFirmware；installedComponent、Filesystem、Manifest 和 DeviceTree 拒绝使用此路径。这些对象需要各自的磁盘适配、结构化恢复及重新证明，不能通过修改 scope 绕过。

新增 `fw receipts` 展示同一证据读取结果。缺记录显示 unknown，坏记录返回错误，旧 `PatchReceipt.plist` 的 ID 不升级为 committed。`--undo-component` 配合期望 generation 和 declaration 只输出恢复副本摘要与涉及记录，不写固件。命令使用现有每 VM 锁；锁的运行记录属于诊断信息。

```sh
.build/debug/vphone-cli fw receipts NAME --json
.build/debug/vphone-cli fw receipts NAME --undo-component avpbooter \
  --generation GENERATION_SHA256 --declaration avpbooter-boot-dgst_bypass --json
```

## 验证

首批相关回归为 68 项、7 个 suite，通过。最终相关 Swift Testing 为 72 项（69 项 FirmwarePatcher、3 项 CLI），全部通过；APIProxy 的 XCTest 另补跑 1 项通过。验证包括重复应用与日志序列化保留首次原件、off→on、旧 4 字节记录向 16 字节候选迁移、未记录写入拒绝、producer 失败、归档原件伪造、证据变化拒绝，以及真实 CLI 的损坏输入拒绝。

`make test_swift` 普通宿主运行的 Swift Testing 共 1527 项，保留 `postValidationRecognizesIdempotenceWithoutEmitting` 的已记录 issue（emittedRecords 为 2，断言为 1）；XCTest 中 `testActiveConnectionLimitAndStopDuringConnect` 另失败一次，随后单独复验通过，初次失败原因未查明。运行器退出 1，外层 make 退出 2，不能表述为标准入口通过。内核补丁和该断言未修改。

标准入口失败后的限时组另补跑 9 项通过；tar 管道、文件摘要内存检查及 guest 组件检查均退出 0。首次标准 Swift 在沙箱内另有本机连接、进程检查及隔离进程权限失败，原日志保留。最终命令、退出码、源码摘要和验证范围见 `evidence/T32-T33-undo/manifest.json`。本轮没有修改 Python，不重复执行 Python 全量；没有运行实际固件比较、签名 App 构建或 VM 验收。

## 剩余范围

1. 普通 guest CFW 的 Disk.img 交换与分组件 Receipt/Undo/来源必须在同一个可恢复 journal 中发布。目前 shell 磁盘事务与 Swift 生成固件事务分别存在；本轮没有将它们合并。
2. DSC chunks、Mach-O、Preboot 的撤销需要原始来源认证、实际安装目标映射、修改页重新证明及最终磁盘读回。本轮 Snapshot 不授予这些对象写入资格。
3. 实际 IOMFB 条件分发实现与 DeviceHub/Flutter 兼容链仍属于 T53 相关工作。本地现有 Python force-kern producer 仍采用原 4 字节实现；本轮的形状判断不会改变该 producer。
4. 新候选的真实 guest on→off→on、缺 Undo 的旧 VM、断电/中断恢复和运行行为尚未验收。不能用生成固件副本的测试替代这些结果。

因此本轮推进 T32/T33 的持久证据读取、首次原件保留和迁移预检，不将整项改为 accepted，也不提高任何已安装 guest/kernel/boot-chain 的来源版本。T08 的新 daemon 客户机验收、T09/T10 的指令实现及适用性仍保持原未完成状态；此前的顺序建议不表示这三项已经完成。
