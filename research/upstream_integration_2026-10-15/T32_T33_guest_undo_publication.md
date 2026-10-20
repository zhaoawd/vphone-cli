# T32/T33：DSC 撤销写入、Receipt 与来源发布（2026-10-15）

延续 [只读候选](T32_T33_guest_undo_candidates.md)，本阶段接入实际 staged DSC 写入、host 驱动、分组件效果 Receipt、guest 来源 unknown 转换及中断恢复。固定目标仍为 `8a75092013eda87a4e30ed029b72028cb9279ac4`。代码工作区基于 `fcd19e78` 和已保留的本地修改。

## 调用与范围

```sh
.build/debug/vphone-cli cfw undo NAME --generation GENERATION_SHA256 \
  --declaration dyld-cfw-camera

.build/debug/vphone-cli cfw receipts NAME --json
```

`cfw undo` 通过现有冻结计划、资源和 sudo/原生权限弹窗入口调用 `cfw_install_host.sh`。shell 新增 `--undo-declaration`（可重复）与 `--generation`，互斥于环境更新。命令要求期望 generation 和唯一 declaration；实际写入还要求当前 live plan 的规范内容等于父 journal 中产生效果的计划。desired 已改变时仍可只读预览，但此写入路径明确拒绝。

当前支持拥有完整来源证据的 DSC 操作链后缀。新事务不会执行变体安装器或翻转已生效的启动快照，也不删除输入目录或重新记录变体。IOMFB 条件实现的生产门控继续生效。任意中间操作重打、Mach-O、Preboot 及尺寸变化的 DSC 仍不接受此入口。

## 写入与效果证据

1. 持有 VM 目录锁和原磁盘描述符，沿用真实 clone/校验复制路径生成新的 v3 journal。`prepare-undo` 要求克隆完整摘要与当前父 checkpoint 相符。
2. 重新验证父 journal、期望 generation、generation 原件及全部被选操作，保存不可变请求摘要。父事务 ID、父 checkpoint 摘要、完整选择、保留行摘要和目标 mode/uid/gid 均进入请求。
3. 将保留的实际操作行及所有内容 blob 复制到新 journal；生成最终来源索引时仅保留未撤销效果。新 journal 的 `operation=guest-dsc-undo-v1` 与 request SHA-256 必须匹配。
4. 通过现有 APFS 附件/PhysicalStores/精确 System 卷检查取得可写挂载。全部目标先检查父路径无链接、单链接普通文件、完整当前摘要、长度及已提交元数据；全部候选先检查完整 CodeDirectory 代码页。预检完成前不写目标。
5. 按保留的完整签名快照流式覆盖同一文件，保留 inode 和 mode/uid/gid，fsync 后重新核对完整摘要与代码页。实际 before/after 摘要和元数据写入 `guest-undo-applied.json`。
6. 执行原最终只读 reader，卸载附件后重新只读附加并再次核验。新 `guest-undo-provenance.json` 从保留链重建。最终成员必须精确等于恢复候选，其元数据必须等于父提交。
7. `seal` 将 `guest-undo-request.json`、`guest-undo-applied.json`、`guest-component-receipts.json` 与原计划、操作行、来源索引、最终读回及完整候选磁盘摘要一起封存。

Receipt 采用 `scope=installed-component-effects`，保存实际最终 target/state/effect、当前 appliedDeclarations、本次 removedDeclarations、generation、计划和磁盘摘要。它不构造 Swift 受信 `InstalledOrigin`。`cfw receipts` 通过 Python 目录锁重新检查已提交 guest journal，并输出该 Receipt；原 `fw receipts` 的生成固件协议保持。

## 来源与共同发布

历史快照不能取得当前 Core Bundle 的生产来源资格。本次撤销仅将 `launchpad.json` 中 guestEnvironment 清为 unknown；bundle、kernel、bootChain 的值保持。原记录不存在时继续缺失，不补造来源。原文件 mode/uid/gid 保留，原始与目标字节及元数据绑定在同一个 Undo 请求中。

发布前必须仍是原来源字节。磁盘交换后，用临时文件、文件 fsync、原子 replace 和 VM 目录 fsync 完成来源转换，再写 published journal。`VPhoneMachineBinding` 在存在 `.cfw_disk.*` 时拒绝提供已提交来源，覆盖磁盘与来源两次原子操作之间的状态。普通启动与写入继续使用原有 pending CFW 锁拒绝。

恢复只接受请求中记录的来源原值或目标值。来源处于未知的第三种内容时保留两个磁盘及 staging，记录 publication-uncertain。Undo 恢复会通过 hdiutil 检查原磁盘和候选附件；仍附加时要求先正常卸载和 detach，保留候选。已交换而来源尚未更新时，恢复在核对已封存磁盘、实际效果、父事务和原磁盘后完成来源转换。来源已转换而 published 状态尚未落盘时，恢复保持幂等。

Receipt、Undo 和来源请求以同一 `.cfw-history/<id>` journal 为提交依据，不增加可自行授予来源版本的根目录 sidecar。已提交后允许 host bundle 选择变化；祖先事务不再要求当前 binding 仍等于其历史值。最新 Undo 效果仍要求 guest 来源为 unknown。

## 归档恢复修复

新增回归复现：`finish` 已把 staging rename 到历史区，但最后一次 record 写入尚未完成时，archive 可能没有原磁盘检查结果，导致已经发布的结果无法读取，且原 staging 路径不再存在。

修复为在归档 rename 前持久化 original_check、完成状态、退出码和目标 location。历史目录 rename 成为可读取的提交边界；后续中断不会丢失必要完成证据。原目录仍存在时继续由 pending CFW 边界保护。

## 磁盘身份连续性（2026-10-16）

真实 Swift 计划验证器复现：generation 绑定原 Disk.img 的 device/inode/birthtime，第一次 CFW 发布更换 inode 后，后续读取报 `generation manifest or VM identity differs`。此前替换验证器的 Python 夹具未覆盖该边界。

`FirmwareGeneration.loadVerified` 现允许通过已提交 v3 CFW journal 证明磁盘身份连续性。检查保持相同 machineIdentifier 和 Disk.img 名称，从当前磁盘沿唯一 staged inode、完整 checkpoint、保留原磁盘回溯到 generation 原物理身份。每级核对完整磁盘摘要、计划、上下文、最终读回、来源索引、全部操作行和 blob；Undo 还核对精确父 journal ID 和 checkpoint 摘要。循环、歧义、缺文件或超过 64 次发布均拒绝。该检查仅确认 generation 的机器关联，不授予组件效果或受信来源。

保存的联合回归使用实际编译的 Swift CLI 验证器，依次运行两次 CFW 发布和一次 DSC 撤销；source 索引、CodeDirectory、实际复制/写入、journal、磁盘交换与归档均执行生产代码。APFS 附件查询、签名 DSC 补丁结果和卷到 raw image 的写回由夹具提供。五种参数覆盖正常链，以及 checkpoint、当前磁盘身份、machineIdentifier、保留原磁盘变化后的拒绝。最终 1 项参数化测试（5 个用例）通过；夹具开发期间的模块路径、输入路径和复制 mock 设置失败单独保存，未修改生产断言。

## 验证

保存测试覆盖实际 source/producer/final-reader/journal、DSC 文件写入、完整 CodeDirectory 页验证、分次撤销、metadata/父目录链接/父证据/Receipt 篡改、来源竞争、缺 binding、host 来源改选、RENAME_SWAP 与两步 RENAME_EXCL 中断、来源已更新但状态未保存，以及归档 rename 后中断。

宿主驱动回归运行实际 zsh 与 Python 协议，仅替换 APFS/挂载系统调用和权限提升。临时目录表示卷，受控 unmount 把实际目标内容写入测试 raw image。该夹具不证明真实 APFS 操作或 VM 启动。

最终相关 Python 157 项通过（112.494 秒）；Swift 定向 11 项通过。首轮完整 Python 885 项中，既有 `test_interrupted_install_returns_artifacts` 超时且清理出现 killpg EPERM（共 2 个 errors、跳过 2 项），make 退出 2。同项单独复验通过（未改断言和时限），初次失败原因未查明。补充附件拒绝检查后的写入/恢复组合 17 项通过。最终 `make test_python` 执行 886 项，跳过 2 项，无失败，241.068 秒，退出 0；源码摘要与最终运行前一致。最终 `make test_swift` 退出 0：XCTest 325 项（跳过 7 项）、常规 Swift Testing 1529 项、限时分组 26 项通过；tar 管道/文件摘要内存检查和 guest 组件宿主检查通过。最终 Python 后仅更新 `guest_undo.py` 模块说明，已重建原文摘要并核对可执行 AST 一致；新增身份连续性代码和联合夹具由最终 Swift 全量覆盖。日志、首轮失败、最终命令结果及 24 个源码摘要见[证据清单](evidence/T32-T33-guest-undo-publication/manifest.json)。

首轮完整 Swift 退出 2：旧 export 用例要求在 pending CFW 中导出，与来源读取的新拒绝条件冲突。回归现先断言 pending 导出拒绝且无归档，再将临时 staging 移到同一测试根目录保留数据，继续执行全部原导出排除及内容断言。ArchiveKit 的 `host extraction matches plain system tar` 首次比较目录权限失败；未修改 ArchiveKit 源码或断言，定向和最终全量均通过，首次失败原因未查明。

## 未覆盖范围

- 用户后续指定 `vm-new`。旧 VM 缺证据拒绝和两次现有系统启动已通过；正向撤销仍缺 generation 和记录化安装。见[真实验收记录](T32_T33_vm_new_acceptance.md)。
- 真实固件完整 DSC 集合、APFS/Preboot 及 guest on→off→on、显示/DeviceHub、实际断电行为尚未验收。
- 反向恢复限操作链后缀；不执行任意中间补丁 producer 重打。写入限同一 live plan，其他 desired 变更继续拒绝。
- 连续 Undo 来源链上限为八个 Undo journal；需要保留父历史及其原磁盘。祖先先完整核验，再作不重复递归的封存内容复查，避免重复展开祖先链。
- 每次验证仍读取完整磁盘、blob 和 generation 目录树；真实大固件成本未测量。
- generation 物理身份连续性最多回溯 64 次 CFW 发布；缺少需要保留的祖先磁盘时拒绝。
- guest 来源保持 unknown，未实现新的受信 Core Bundle guest 来源推进。T32/T33 整项不提升为 accepted。
