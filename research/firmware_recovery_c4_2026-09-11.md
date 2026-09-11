# C4 固件暂存与中断恢复

日期：2026-09-11。实现基线：`cf4f1ba`。状态：已实现暂存、提交记录和显式恢复；非 less 实际产物与故障恢复已验证，完整 less 成功路径仍待验收，暂不计为 C4 完成。

## 实现前的写入审计（`da678a3`）

| 对象 | 当前行为 | 对恢复设计的要求 |
| --- | --- | --- |
| `FirmwarePipeline.patchAllStructured` | 每个组件通过后立即调用 loader.save；后续必要项失败只停止后续执行 | 必须区分已验证暂存结果与正式产物，保留跨组件提交进度 |
| `ContainerFirmwareLoader` / `IM4PHandler.save` | 从原文件读取容器属性，再直接写入目标路径 | 暂存区需要保留原容器；单文件写入完成不代表多文件提交完成 |
| `CryptexFilesystemPatcher.apply` | 生成文件系统、trustcache、mtree、digest、metadata、root hash 后返回新的 Manifest | Filesystem 的外部副作用早于流水线 loader.save，不能仅替换 loader 来实现完整暂存 |
| `createTrustcache` / `setUpdatedComponentsInManifest` | 删除已有输出并移动新文件到 restore/Firmware；更新 Manifest 引用 | 应将这些输出路径全部限制到暂存 restore，提交时包含新建、替换和引用变更 |
| 镜像挂载与临时目录 | 使用 hdiutil/diskutil；部分 defer 清理使用 try? | 必须记录本任务实际挂载设备，显式保留清理失败；中断恢复不能依赖对象 deinit |
| `ManifestHashPatcher` | 从 restore 读取最终组件，计算 SHA-384 后生成 Manifest | Manifest 校验必须读取同一次暂存事务中的产物，不能混合原文件与部分新输出 |
| less 消融 | 当前在未消融整个 Filesystem 时拒绝不落盘运行 | 在 Filesystem 全部副作用被隔离前继续保留该限制 |

来源：[流水线](../sources/FirmwarePatcher/Pipeline/FirmwarePipeline.swift)、[容器写入](../sources/FirmwarePatcher/Binary/IM4PHandler.swift)、[Filesystem](../sources/FirmwarePatcher/Filesystem/CryptexFilesystemPatcher.swift)、[Manifest](../sources/FirmwarePatcher/Manifest/ManifestHashPatcher.swift)。此段记录初步源码审计；后续真实运行见下文。

## 初始实现与验收计划

1. 补齐路径清单：记录全部输入、输出、外部工具与挂载副作用，包括 less 输出和 VM 根目录组件；确定路径别名与符号链接策略。
2. 定义事务记录：输入和选项摘要、每个文件的原始/暂存哈希、阶段、提交进度及挂载归属。记录格式和恢复策略在实现前确定，不把多文件替换描述为原子操作。
3. 将生产流程置于独立暂存输入集；注入暂存 restore 路径，保证 Filesystem 和 Manifest 操作访问同一组文件。仍使用既有 bundle 锁保护检查、构建与提交窗口。
4. 校验必要集合、实际产物与 Manifest 一致性后再提交；保留可识别的原文件和提交记录，按记录恢复中断状态。
5. 用临时样本验证每个写入和提交阶段的错误、磁盘不足、进程退出及重复恢复，再执行既有非 less/less 产物比较。真实镜像验收与替身测试分别记录。

以上为实现前确定的范围；当前实现约定与验收结果如下。仅为七个二进制增加临时文件不能满足 C4，因为 less 还会写入镜像及多个 Manifest 引用的文件。

## 实现约定（2026-09-11）

- 单个活动目录为 VM 内 `.firmware-transaction`，内含 `journal.json`、`stage/`、`backup/`、`work/`；工具占用锁使用活动目录 inode；成功或显式恢复后整体归档到 `.firmware-history/<id>`，保留原文件及失败产物供审计。
- 输入范围为选中的 Restore 目录及实际根目录引导组件，不复制 Disk.img、NVRAM 或其他 VM 状态。复制优先使用 APFS clonefile，拒绝符号链接与特殊文件。输入/输出摘要按文件内容和目录条目生成，包含空目录。
- 阶段为 building、ready、publishing、rollingBack、committed。提交前记录全部原始和暂存摘要；每次 rename 后同步目录。恢复结合文件位置和摘要判断已完成的 rename，不只依赖阶段计数。
- 原文件在提交前保持不变。publishing/rollingBack 恢复到原始输入；committed 恢复只检查正式产物并归档，不回滚已完成结果。未知摘要或路径冲突时停止，保留证据。
- less 临时镜像置于 work。外部工具通过持锁 worker 执行，主进程退出后 worker 仍等待子进程；恢复期间同锁阻止新工具开始。仅按 hdiutil 报告的镜像路径识别本事务挂载，不按猜测的设备编号卸载。
- CLI 的 `patch-firmware --recover` 和 `fw patch <name> --recover` 仅恢复/归档，不继续执行补丁。调用方沿用已有 bundle 锁。
- 初版保留 less dry-run 的既有限制。该工作不修改补丁匹配、指令编码或必要集合定义。成功与失败归档都会占用磁盘；清理归档不在本轮自动执行。
- 验收区分进程中断恢复与断电耐久性；本轮不宣称已通过物理断电实验。

## 本轮验证与原因

| 实验设置 | 结果 | 证据与限制 |
| --- | --- | --- |
| 真实 non-less：26.1 / 23B85，regular、dev、jb、exp | 四个生产流程均成功提交；每个场景的 9 个完整组件 payload 与 C3 基线一致；原始 Restore 与归档 backup 摘要一致 | `research/artifacts/c4-nonless-2026-09-11/{regular,dev,jb,exp}.log`；本轮四个场景不替代 C3 的 24 场景矩阵 |
| 事务故障注入 | 复制/提交准备 ENOSPC、读取 EIO、部分保存 ENOSPC、五个 rename 窗口、回滚再中断、提交后归档失败均验证恢复；未知外部修改和损坏记录拒绝覆盖 | `FirmwareTransactionTests.swift`；注入 ENOSPC 不等于已执行物理磁盘耗尽实验 |
| 真实进程退出 | 发布第一个组件后 `_exit(73)`，无析构清理；新进程恢复旧输入，通过 | `FirmwareTransactionCrashTests` |
| 外部工具互斥 | 父进程被杀后 worker 保持事务锁，工具退出后释放；归档后旧 worker 不能开始；待恢复目录阻止其他 VM 操作 | `tests/test_firmware_worker.py` 与 `FirmwareRecoveryLockTests.swift` |
| less 第一次运行 | 退出码 137，事务停在 building；显式恢复通过 | `pipeline-initial-137.log`、`recovery.log`；操作系统终止原因未直接确认 |
| 大文件哈希最小复现 | 两次 128 MiB 摘要导致峰值 RSS 增长 269,828,096 字节；每次读取使用 autoreleasepool 后，小于 64 MiB 的回归约束通过 | 哈希算法及输入不变；同样修正最终 Manifest 的分块读取。复跑已进入镜像处理，未再在原位置退出 |
| less 普通用户运行 | 合并 AppOS 时删除镜像内 `System/Cryptexes/App` 遇到权限错误；未提交正式固件；恢复和原始摘要校验通过 | `pipeline-retry.log`、`recovery-permission.log` |
| less 管理员运行 | 镜像处理中可用空间降至约 2.7 GiB，主动终止验收；没有将本轮标记为成功 | `pipeline-admin.log`；此前已确认免交互管理员授权可用，当前成功路径待验收原因是磁盘空间 |

日志路径在 `research/artifacts/c4-less-2026-09-11/` 下，除表中明确给出的其他目录。大型样本和日志被 Git 忽略；复现入口为 [样本准备脚本](c4_transaction_acceptance.py) 和 [真实验收测试](../tests/FirmwarePatcherTests/FirmwareTransactionAcceptanceTests.swift)。测试显式校验 C4 隔离路径，不针对现有 VM 运行。

真实中断恢复还发现裸 APFS 镜像会同时报告底层磁盘和合成容器。原逻辑仅接受一个 `/dev/diskN`，因此报设备歧义。回归使用实际 `hdiutil` 结构先复现失败；修复后的真实恢复通过（7.311 秒），对应 `recovery-admin-fixed.log`。修复通过 `diskutil info` 的 `APFSPhysicalStores` 解析底层磁盘，且结果必须仍属于该镜像的原始候选集合。集合外设备继续拒绝卸载。

为继续验收，在恢复成功后清理本轮权限失败和管理员主动中断事务的 `work`；清理前保存路径、大小、SHA-256 清单到该归档的 `removed-work-inventory.json`。原始输入、暂存固件、事务记录和日志保留；管理员创建的隔离归档已恢复当前用户所有权。清理后可用空间约 21 GiB，无活动事务和本轮残留挂载。此操作是隔离验收的空间整理，不改变生产事务默认保留归档的行为。

## 剩余工作

1. 在磁盘空间充足时完成管理员权限下的 less 完整成功路径，核验全部 Manifest 引用摘要、交付产物和备份。已有 C3 less 成功记录不能替代新增事务封装的验收。
2. 补齐完整 less 成功路径后再评估 C4 勾选。完整创建续跑、启动和客户机能力分别属于 D4、F1、E 系列，不因本轮事务实现自动完成。
3. C5 继续统一工具版本、输入、选项和失败阶段的实验记录；当前事务 journal/report 已提供部分数据，但尚未完成统一实验记录协议。

## 使用方式

```sh
vphone-cli patch-firmware --vm-directory /path/to/vm --recover
vphone-cli fw patch VM_NAME --recover
```

出现 `.firmware-transaction` 后，先执行恢复命令；恢复成功后再重新执行补丁。恢复不会自动续跑补丁。若提示工具仍运行，等待该工具退出后重试；若提示摘要或设备归属不一致，保留目录和日志检查，不能直接删除活动事务目录以绕过保护。

## 回归与构建

- `make test`：77 项 Python 测试通过；XCTest 80 项（3 项按环境条件跳过）无失败；Swift Testing 331 项通过。
- `make build`：release 编译、签名与 app 打包通过。恢复提示透传修正后，共享操作保护定向回归 12 项通过；交付前再次执行 `make build`。
- CLI 错误传播测试曾确认：待恢复错误被共享保护包装为普通 VM 占用提示。现已保留恢复错误类型和 `--recover` 提示；其他占用判断保持原路径。
- 本轮未执行 VM 恢复刷写、启动和客户机功能验收，未更改二进制补丁匹配或指令内容。
