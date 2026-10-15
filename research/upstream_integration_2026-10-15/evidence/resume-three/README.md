# 从 handoff 恢复后的三项实施

日期：2026-10-15。HEAD 为 `2df4be8ceab956d498f2cc7d79b26f4ddbdee467`，固定上游 `8a75092013eda87a4e30ed029b72028cb9279ac4`。此前两批未提交改动和 Capstone overlay 保留。

## 验证顺序

先核对 handoff 的 16 个源码摘要，全部匹配。原 IcliKit 缓存目录已不存在，使用 `.build/daemon-api-8a75092/Xcode/SourcePackages` 并核对其 revision 与锁定版本一致。恢复前基线 `make test_python` 818 项通过，跳过 1 项，425.507 秒，退出 0，见 `python-result.json`。

随后并行实施三项，SwiftPM 由一个代理统一构建。最终 `make test_swift` 全入口退出 0：XCTest 321 项（跳过 7 项）无失败；Swift Testing 常规组 1507 项和时限组 26 项通过；两项内存检查及 guest 组件宿主检查通过。原时限保持，时限测试按精确名称移入现有阶段，组内并行保留。详见 [Swift 证据](../resume-swift/README.md)。

实施后 `make test_python`：835 项，跳过 1 项，420.289 秒，退出 2；唯一失败为旧静态边界断言要求 Launchpad 删除取消导出的最终文件。该断言与已验证的数据保留修复冲突，随后改为禁止删除最终路径；受影响的 Launchpad 模块 23 项全部通过，生产源码未再变更。未再次运行完整入口，不称全入口通过。原失败日志及修复定向日志保留，见 `python-final-result.json`。

## 实施、审查和范围

- [Swift](../../T30_swift_validation_followup.md)：修复 HTTP/WebSocket 夹具遗漏按时完成状态、子进程使用观察者时刻造成的误判，具备截止后负对照。XPC/escaped pipe 在分组后通过，生产层原始原因未查明，不称为生产修复。
- [原件索引](../../T32_T33_implementation_migration.md)：generation 原件、只读 DSC 基线、复制/逐操作前后 blob 与源码摘要持久关联；final_guest 生成、journal 绑定、发布前重建消费。schema 2 要求完整证明，环境更新同样最终读取。独立审查发现并修复长步骤后复核、跨 VM 绑定及删除证据降级问题。旧事务可恢复/清理，不能继续发布。
- [导出取消](../../T60_export_cancellation.md)：私有临时文件、排他发布、真实 SIGINT/TERM 取消与子进程回收；修复已有归档被覆盖及 Launchpad 取消盲删。真实 CLI 四项取消、两项正常往返通过，已有目标保持。标准发现新增回调导致进度回退，删除该回调后 41 项受影响回归及最终标准通过。

原件索引仅证明来源和已观察的操作链；verify-final 后仍有 APFS snapshot 变换，尚未证明变换后最终语义。逆向 Undo、旧实现迁移及 payload/Undo/Receipt 共同发布尚待完成，IOMFB 门控保持。导入队列、完整退出状态和真实 VM 验收也未完成。

本批没有启动 VM 或修改系统安全配置。提交与推送状态见 Git 历史。源码摘要见 `source-manifest.json`，日志归档摘要见 `archive-manifest.json`。
