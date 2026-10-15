# Task 8：真实已安装 DSC 的 atlas 校验修复

日期：2026-10-13。

## 问题与复现

`FirmwareKernelDSC.validate(system:region:)` 按主缓存文件名前缀枚举文件，仅排除 `.symbols`、`.map`。实际安装目录包含 `dyld_shared_cache_arm64e.atlas`，其前 4 字节为 `AA01`，不含 dyld mapping header。

使用已授权备份 `/private/tmp/vphone-task8-acceptance-vms/task8-before-binding/Disk.img`，通过 `hdiutil attach -readonly -nomount` 和 `mount_apfs -o rdonly` 挂载 System。`diskutil info` 确认 `WritableVolume=false`、`WritableMedia=false`。

`dsc-atlas-real-red-normalized.log` 记录生产校验抛出 `Unknown DSC header`。`dsc-atlas-minimal-red.log` 记录最小复现：同一合法主缓存先通过，添加 `.atlas` 后失败。最初 `dsc-atlas-real-red.log` 因测试 URL 尚未标准化而提前拒绝，该记录不能证明 atlas 问题；测试随后采用 `standardizedFileURL`。

## 原因与来源证据

检查时列出三个待验证假设：atlas 被当成 subcache；正常 subcache 损坏；主缓存引用表格式识别错误。实际 79 条 subcache 引用不含 `.atlas`，仅 atlas 没有 `dyld_v1` header。精确排除该 sidecar 后，全部引用、UUID、VM offset、mapping 范围和重叠检查通过。

Apple 官方 dyld 源码 revision `fd8d0c4d52320ebf64db34f3cb280310d905c5ae` 的 [mrm_shared_cache_builder.cpp](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/cache_builder/mrm_shared_cache_builder.cpp#L746) 为主缓存名称附加 `.atlas`，并在第 2911 行附近将 atlas 单独写为 FileResult。atlas 与 cacheBuffers 分别保存。源码 SHA-256 与行号见 `dyld-atlas-source.json`。此源码用于确认 sidecar 分类；未声称它与安装 DSC 的 dyld 构建版本完全一致。

## 修改与验证

只排除准确名称 `dyld_shared_cache_arm64e.atlas`。不排除 `.01.atlas` 或 `.atlas.extra`。若主缓存引用表出现 `.atlas`，明确拒绝。引用表、UUID、VM offset、mapping 和容量检查保持原条件。

`dsc-atlas-exp-final.json` 退出码 0，5 tests / 2 suites 通过。参数化回归包含 atlas 精确名称、相似名称拒绝、被引用 atlas 拒绝、缺少 subcache、UUID 不同、未引用文件、VM offset 不同以及 7 GiB DSC 对 6 GiB 内核的拒绝。

实际链路使用 `prepared-desired-plan.json` 的 EXP 计划和真实 raw kernel 输入，经 `reproduceInstalledComponentReport`、`PatchDeclarationGate.enforceKernel`、`FirmwareKernelRegion.inspect`，最后调用生产 DSC 校验。候选 payload SHA-256 为 `d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb`。完整三组件报告见 `dsc-exp-candidate-report.json`，结果见 `dsc-exp-candidate-result.json`。

| 对象 | 数值 |
| --- | --- |
| 候选 kernel region base | `0x180000000` |
| 候选 kernel region size | `0x180000000`（6 GiB） |
| DSC 主 header region size | `0x12fafc000` |
| DSC maxSlide | `0x20000000` |
| DSC size + maxSlide | `0x14fafc000`，小于 6 GiB |
| 全部 mapping 范围 | `[0x180000000, 0x2afaf8000)` |
| subcache / mapping 数量 | 79 / 102 |

逐条 mapping、实际 header 和 atlas 哈希见 `dsc-actual-headers.json`。验证期间没有修改 DSC 或 maxSlide，也未修改 task8-copy 和 vm-new。只读备份已卸载，`dsc-detach.json` 记录退出码 0。

此验证证明候选的声明检查与当前安装 DSC 的静态兼容检查通过，不证明内核更新发布或 VM 启动通过。增加真实安装目录测试可在合成测试之外覆盖 sidecar 文件分类差异。
