# Task 8 PAYP 与 description 保留修复

已确认的封装缺陷是：原路径使用固定 description `kernelcache` 新建 IM4P，没有保留原件的 PAYP。合成生产封装回归已两次复现该行为；此前真实容器对照也确认安装后少了 315 字节 PAYP，description 缩短 18 字节。

修复从 `produced.input` 读取元数据，先核对完整文件 SHA-256 与 producer 的输入摘要，再结构化解析 IM4P。description 和 PAYP 保留原始 TLV。输出 payload 使用已验证的 producer 解码字节，因此输出不携带原 LZFSE compression-info。目标 IMG4 的 IM4M/IM4R 仍由 swap 原样保留。提交前候选及发布后读回均要求完整 IM4P 与重封装结果相等；proof 新增 `im4pSHA256`。

本次支持未压缩及已验证的 LZFSE 原件。未知、加密、重复或不一致元数据拒绝；PAYP 字段结构、名称与私有 tag、重复字段和 primitive 值类型均检查。携带 PAYP 时，producer payload 长度必须与原件解码长度一致。本次明确拒绝 LZSS。测试最初调用既有 vendor LZSS 压缩器构造输入时触发 `Range requires lowerBound <= upperBound`，发生在测试构造阶段；日志 `green-real.log` 保留，未据此认定生产解码器失败。

可信 generation 原件导出文件为 `/private/tmp/task8-pristine-kernel.im4p`，完整摘要 `b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac` 与 v7 proof 的 `inputSHA256` 一致。原件 description `KernelManagement_host-487.0.4`、PAYP 原始摘要 `92c4c621253f5ecd211e5e6f0d6d5164688575a7395988fbf29142509a8a9b93` 均与更新前基线一致。源目录由导出方报告，脚本没有读取 VM 目录。

真实纯文件回归通过：新 helper 从该原件取得元数据，将已安装的错误容器修复为与基线逐字节相同的 IMG4，完整摘要 `5b90c5a0ee87bf810c7e90795d537265f39774fbf85c430263fd2f61fc41ce7a`。这项结果同时核验目标 IM4M 原字节保留。合成测试另覆盖 IM4R 保留、payload 修改、伪 PAYP marker、LZFSE 解压后移除旧压缩信息，以及 13 个拒绝场景。

最终定向回归退出 0，Swift Testing 汇总 37 项测试、6 个 suite，通过耗时 16.272 秒；`actualCandidateRegionUsesSourceFlow` 因未设置其独立 fixture selector 跳过。实际元数据 fixture 测试已运行。最终定向套件覆盖 metadata、swap、kernel update、orchestration、effect index 和 installed origin；本轮未修改内存修复代码。

命令见 `commands.json`，原件与修复结果核验见 `repacked-verification.json`，源码和全部日志摘要见 `manifest.json`。未修改内核补丁算法，未操作 VM、挂载或 AMFI。先前启动异常原因未查明；纯文件修复不证明真实更新、启动或提交后回退已通过。
