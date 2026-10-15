# 离线标记镜像工具独立复审 v2

结论：审查范围内未发现剩余阻断。最终工具 SHA256 `454f10947bfd1c0d07102448b3dbd07be2525c2f79b8505a55ed44e4b0ef33c9`。独立 AST 检查通过，独立纯 mock 测试退出 0，24 项通过。未运行 main、真实进程检查、客户机、VM、hdiutil 或挂载；此结论不代表真实镜像诊断已经通过。

首轮 blocked 审查、23 项测试和 XML/binary plist 拒绝复现均保留。作者本次抽出 `load_frozen(path, frozen, digests, raw=False)`。该函数先通过原 observe_file 读取并登记完整 SHA256、文件身份和字节；只有 config.plist 调用明确使用 raw=True。其他 JSON 输入继续严格拒绝重复字段和非有限数值。config.plist 后续由 plistlib.loads 解码并核对 machineIdentifier SHA256。main 末尾仍遍历全部 frozen 输入，重新读取并逐项比较身份和原始字节，config.plist 无例外。

新增测试对有效 binary 和 XML plist 各自验证：raw 模式返回原字节、plist 正确解码、digest 登记正确、observe_file 与 frozen 完全相同；默认 JSON 模式继续拒绝 plist。独立复跑全部 24 项通过。该测试直接覆盖修复后的生产读取 seam；完整 main 的真实平台链仍由根任务实际执行。

其余静态范围与首轮审查一致：固定归档与来源证据摘要链；唯一 GUID backing device 与精确单 PhysicalStore；唯一 Data/UserData 卷；只读 attach/mount；前后设备、UUID、物理存储、MountPoint、WritableVolume 验证；固定 UUID 标记路径及 O_NOFOLLOW 单硬链接普通文件；错误 PhysicalStore、加密/可写、权限和清理失败拒绝；只 detach 本轮精确关联附件，不使用 force；detach 失败不删除挂载目录内容；每镜像完整 SHA256 和身份前后重验；最终 pending/附件和全部冻结输入重验。

许可范围仅为根任务在已正式停机、目录锁及无 pending/已有附件条件下运行该固定只读诊断。工具不更改 V9、F99、AMFI 或客户机文件。当前 Disk 仅要求与本次观测前一致，允许正常启动后的全盘内容变化。归档旧 tmp 标记缺失可作为观察；当前 Documents 标记必须存在且完整字节相同。旧 tmp 标记缺失原因未查明，诊断观察不能单独确认内核回退与缺失之间的因果关系。
