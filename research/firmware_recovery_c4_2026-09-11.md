# C4 固件中断恢复：初步写入审计

日期：2026-09-11。基线：`da678a3`。状态：已开始源码审计，尚未实现暂存或恢复，不计为 C4 完成。

## 已确认的写入边界

| 对象 | 当前行为 | 对恢复设计的要求 |
| --- | --- | --- |
| `FirmwarePipeline.patchAllStructured` | 每个组件通过后立即调用 loader.save；后续必要项失败只停止后续执行 | 必须区分已验证暂存结果与正式产物，保留跨组件提交进度 |
| `ContainerFirmwareLoader` / `IM4PHandler.save` | 从原文件读取容器属性，再直接写入目标路径 | 暂存区需要保留原容器；单文件写入完成不代表多文件提交完成 |
| `CryptexFilesystemPatcher.apply` | 生成文件系统、trustcache、mtree、digest、metadata、root hash 后返回新的 Manifest | Filesystem 的外部副作用早于流水线 loader.save，不能仅替换 loader 来实现完整暂存 |
| `createTrustcache` / `setUpdatedComponentsInManifest` | 删除已有输出并移动新文件到 restore/Firmware；更新 Manifest 引用 | 应将这些输出路径全部限制到暂存 restore，提交时包含新建、替换和引用变更 |
| 镜像挂载与临时目录 | 使用 hdiutil/diskutil；部分 defer 清理使用 try? | 必须记录本任务实际挂载设备，显式保留清理失败；中断恢复不能依赖对象 deinit |
| `ManifestHashPatcher` | 从 restore 读取最终组件，计算 SHA-384 后生成 Manifest | Manifest 校验必须读取同一次暂存事务中的产物，不能混合原文件与部分新输出 |
| less 消融 | 当前在未消融整个 Filesystem 时拒绝不落盘运行 | 在 Filesystem 全部副作用被隔离前继续保留该限制 |

来源：[流水线](../sources/FirmwarePatcher/Pipeline/FirmwarePipeline.swift)、[容器写入](../sources/FirmwarePatcher/Binary/IM4PHandler.swift)、[Filesystem](../sources/FirmwarePatcher/Filesystem/CryptexFilesystemPatcher.swift)、[Manifest](../sources/FirmwarePatcher/Manifest/ManifestHashPatcher.swift)。本次审计未运行固件流程或挂载镜像。

## 下一步实现与验收

1. 补齐路径清单：记录全部输入、输出、外部工具与挂载副作用，包括 less 输出和 VM 根目录组件；确定路径别名与符号链接策略。
2. 定义事务记录：输入和选项摘要、每个文件的原始/暂存哈希、阶段、提交进度及挂载归属。记录格式和恢复策略在实现前确定，不把多文件替换描述为原子操作。
3. 将生产流程置于独立暂存输入集；注入暂存 restore 路径，保证 Filesystem 和 Manifest 操作访问同一组文件。仍使用既有 bundle 锁保护检查、构建与提交窗口。
4. 校验必要集合、实际产物与 Manifest 一致性后再提交；保留可识别的原文件和提交记录，按记录恢复中断状态。
5. 用临时样本验证每个写入和提交阶段的错误、磁盘不足、进程退出及重复恢复，再执行既有非 less/less 产物比较。真实镜像验收与替身测试分别记录。

此处是初步审计和后续实现范围，不构成已经实现的事务接口。仅为七个二进制增加临时文件不能满足 C4，因为 less 还会写入镜像及多个 Manifest 引用的文件。
