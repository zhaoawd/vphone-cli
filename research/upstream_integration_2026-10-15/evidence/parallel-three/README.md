# 三项并行实施与集成验证

日期：2026-10-15。基线 `2df4be8ceab956d498f2cc7d79b26f4ddbdee467`；固定上游 `8a75092013eda87a4e30ed029b72028cb9279ac4`。

## 实施与独立审查

| 范围 | 定向验证 | 审查结果 |
| --- | --- | --- |
| 内核幂等记录测试 | 21 项通过；原失败及移除观察的反证均保留 | 独立审查核对原失败发生于第二次调用，测试区分字节修改与验证观察；未发现阻断问题 |
| IOMFB 实现资格拒绝 | 最终 50 项通过 | 首次发现按 ID 无条件拒绝会影响 iOS 26/18；修正冻结版本条件并添加真实写入对照，复审未发现新增问题 |
| 进度输出断开 | 7 项通过；四种原实现失败保留 | 独立审查核对 TTY/pipe、真实 tar 回调、信号及数据断言；未发现新增问题 |

研究记录分别为 [T30](../../T30_kernel_idempotence.md)、[T32/T33](../../T32_T33_implementation_migration.md)、[T60/T46](../../T60_progress_pipe.md)。各独立证据目录的 archive-manifest.json 保存原日志与 gzip 摘要。

## 标准 Swift

两次 `make test_swift` 均未全通过，原幂等失败在两次中均未出现。

- 首次常规 Swift Testing：1511 项、236 suites、8 issues，159.322 秒。worker 故障注入的等待/恢复文件检查，以及 VMRuntimeEntry 的进程结果失败。日志 `swift.log`。
- 首次失败定向复核：`startedWorkerIOFailureWaitsAndDrainsBeforeUnlock|VMRuntimeEntryTests`，3 项、2 suites，通过，3.208 秒；没有调整生产代码、断言或超时。日志 `swift-failures-focused.log`。
- 第二次常规 Swift Testing：1511 项、236 suites、46 issues，196.420 秒。包括 worker 等待、环境写入协调、XPC、HTTP/WebSocket、退出时限及创建状态问题。日志 `swift-final.log`。
- 第二次 XCTest：321 项、7 跳过、0 失败。常规 Swift Testing 失败后，标准入口未继续限时组、内存和 guest 组件检查。

两次失败集合不同，原因未查明。定向通过不替代标准入口通过；没有将问题归因于本批改动或环境，也没有修改分组或放宽断言。

## 完成边界

内核生产指令补丁未改；IOMFB 本批只完成生产拒绝，条件算法、可信 Undo 持久化和迁移发布仍未完成。进度输出子项不证明完整 VM 导入发布、传输中断清理或队列退出。没有操作真实 VM、Store、AMFI/TCC 或安装工件。Capstone 既有生成 overlay 保留。

## Python 与后续检查

`make test_python` 退出码 0：798 项，跳过 3 项，507.973 秒。日志 `python-final.log`，命令退出码见 `results.json`。

标准入口停止后的检查按原命令分别补跑，退出码与命令见 `followup-results.json`。限时组 9 项、8 suites 通过，8.482 秒。单独补跑不改变上述标准 Swift 入口未通过的结果。

tar 传输内存检查通过：file/producer 两种输入均超过 1 GiB，计数单调，峰值 RSS 分别为 8,716,288 / 8,896,512 字节，均低于 128 MiB 上限。文件摘要检查通过：512 MiB 输入的摘要一致，峰值 RSS 为 8,388,608 字节，低于 64 MiB 上限。`make test_guest_components` 的宿主 loader-link、camera 和 audio 算法检查通过；这些检查不证明 guest 运行效果。

## 剩余 TODO

- T30/T31：诊断标准 Swift 的当前失败，完成剩余内核结构化与语义定位范围的验收。本次只修正幂等记录测试契约。
- T32/T33：实现 IOMFB 条件分派、可信原始字节和 Undo 持久化、同 ID 实现替换及事务发布；完成迁移回归后才能解除拒绝。
- T46/T60：验证真实传输中断清理、导入发布、队列取消与退出状态，以及剩余输出退出矩阵。

`source-manifest.json` 记录本批变更源码的 SHA-256；`archive-manifest.json` 记录日志原文件及 gzip 文件的 SHA-256。
