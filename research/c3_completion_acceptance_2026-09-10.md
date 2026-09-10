# C3 收尾验收记录

后续远程迁移合并的取舍与复验另见 [C3 远程合并记录](c3_remote_merge_2026-09-10.md)。本页保留原验收范围、产物与结果。

日期：2026-09-10。状态：已完成。本轮 24 个非 less 场景及 1 个 less 默认场景已完成下述验收；历史组合保留原证据和验证阶段。

## 工作项范围

[总清单](project_iteration_checklist_2026-09-08.md)的 C3 原始要求是结构化迁移、组级完整性、同输入同选项的迁移等价性，以及支持范围内每个变体的必要集合检查。C3 完成不表示完成恢复或启动。

| 工作项 | 验收范围 |
| --- | --- |
| C3 | 补丁状态、必要集合、完整方法声明、迁移等价性与本轮产物检查 |
| C4 | 所有文件和挂载副作用、暂存、多文件提交、中断及磁盘不足恢复 |
| F1 | 创建、恢复、首次与第二次启动、交互与适用能力 |

此前进度记录把修正后内核启动、less 恢复与启动列入 C3 未完成原因。这些运行项目仍未验证，按原清单归入 F1；此次范围澄清不产生新的运行证据。LLB `patchRootfssBypass` 必要性仍为待验证假设，保留当前 optional 定义。

## 精确输入与场景

非 less 输入由 [准备与落盘验证脚本](c3_full_pipeline_acceptance.py) 从固定 catalog 配对取得。每组 `stock/sources.json` 记录来源 URL、归档成员、长度和 SHA-256；AVPBooter 来源与哈希也单独登记。不能把相同 cloudOS 内核的结果外推为不同 iPhone 构建全链通过。

| 配对标识 | iPhone | cloudOS | 场景 | 数量 |
| --- | --- | --- | --- | ---: |
| 261 | 26.1 / 23B85 | 26.1 / 23B85 | regular、dev、jb、exp | 4 |
| 263 | 26.3 / 23D127 | 26.3 / 23D129 | regular、dev、jb、exp | 4 |
| 2661 | 26.6.1 / 23G83 | 26.4 / 23E5207q | regular、dev、jb、exp、jb-frida、exp-frida | 6 |
| 270b5 | 27.0 / 24A5408d | 26.4 / 23E5207q | regular、dev、jb、exp、jb-frida、exp-frida | 6 |
| 1862 | 18.6.2 / 22G100 | 26.1 / 23B85 | regular、dev、jb、exp | 4 |
| less-261 | 26.1 / 23B85 | 26.1 / 23B85 | less，默认安装选项 | 1 |

非 less 共 24 个场景，less 为 1 个独立场景。这 24 + 1 个场景是本轮实证范围，不表示 catalog 中 23 个配对的全部排列组合已经验收。`-frida` 表示启用 Frida；其他场景关闭。force-exc-guard 关闭，dev 和 iOS 18 的 EXC_GUARD 由生产门控启用；iOS 27 门控从原始 iPhone Manifest 读取。less 默认 `noBinpack=false`、`noVphoned=false`。

**26.3 构建号必须区分：**本轮 catalog 归档的 BuildManifest 与 SystemVersion plist 标识为 `23D129`。历史 C1 `pv-263-parity` 指向 `23D128`，不能被本轮替代、纠正或自动升级。

## 非 less 验收判据与当前证据

1. 生产 CLI 运行完整引导链，保存结构化报告；检查器核对完整方法集合、有效必要集合，并拒绝 legacy、消融及失败结果。
2. 六类二进制按完整记录独立重放，比较落盘 payload；DeviceTree 必须比较完整序列化 payload，不能按旧偏移重放长度变化的记录。
3. [完整流水线 parity 测试](../tests/FirmwarePatcherTests/FullPipelineParityTests.swift)在全新 stage 上执行生产配置，保存被截获到内存，再对同一原始输入运行 legacy 调度。逐组件比较完整 payload 与 records，并核对磁盘输入容器未变。该测试不修改 stage。
4. 方法计数、记录数、运行退出码和完整日志分别记录；记录数相等不能替代字节比较。

主控已复核下列 CLI 必要集合及六类二进制落盘重放结果。DeviceTree 的落盘完整序列化比较与 legacy/structured parity 分别记录，不能由二进制重放结果代替。

| 配对 | regular | dev | jb | exp | jb-frida | exp-frida | 完整 legacy/structured parity |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 261 | 58 | 70 | 152 | 178 | 不在本轮场景 | 不在本轮场景 | 四场景 `parity-02` 全部通过 |
| 263 / cloudOS 23D129 | 58 | 70 | 152 | 178 | 不在本轮场景 | 不在本轮场景 | 四场景 `parity-02` 全部通过 |
| 2661 | 59 | 71 | 153 | 179 | 157 | 183 | 六场景 `parity-02` 全部通过 |
| 270b5 | 59 | 71 | 165 | 191 | 169 | 195 | 六场景 `parity-02` 全部通过 |
| 1862 | 59 | 70 | 153 | 179 | 不在本轮场景 | 不在本轮场景 | 四场景 `parity-02` 全部通过 |

表中数值为记录数。24 个场景的 CLI 必要集合和六类二进制重放均通过；五组输入的 DeviceTree 落盘完整序列化检查已覆盖全部 24 个场景并通过。完整 legacy/structured parity 的 24/24 个场景全部通过，各组 parity-summary 已齐全，总运行退出码为 0。

产物根目录：`research/artifacts/c3-full-pipeline-2026-09-10/`；除 261 外分别追加 `-263`、`-2661`、`-270b5`、`-1862`。生产报告位于 `runs/acceptance-01/`，完整 parity 使用独立 `runs/parity-*/`（261 本次有效结果为 `parity-02`）。最终状态须以每场景退出码、报告及 parity 结果为准。

## less 输入、包装等价性与产物检查

[less 准备脚本](c3_less_pipeline_acceptance.py)拒绝已存在目标和符号链接路径。大型来源镜像按原 ZIP 成员长度和 CRC32 校验后进行 APFS 克隆，再比较本地 SHA-256；SHA-256 不是服务端提供的签名或摘要。生产 `fw_manifest.py` 从原始 plist 生成混合 Manifest。准备脚本不挂载镜像、不执行补丁。

[less 完整流水线测试](../tests/FirmwarePatcherTests/LessFilesystemAcceptanceTests.swift)只允许固定隔离目录，执行完整生产 less 流程，并验证 Filesystem 输入 Manifest、Filesystem 输出与 Manifest 输入、最终 Manifest 落盘之间的完整字节链。本轮流水线通过，耗时 1320.393 秒，15 个声明方法、26 条记录，Filesystem 字节链检查通过。

### Filesystem 状态迁移的等价性证明

对比 `01847be^` 与迁移提交 `01847be`：`CryptexFilesystemPatcher.apply()`、初始化参数及全部产物辅助方法未修改。旧路径 `findAll()` 返回常量占位记录，无外部副作用，随后调用一次 `apply()` 并读取 `patchedData`。结构化路径声明一个 required 步骤，非消融执行时同样调用一次 `apply()`，从同一 `rebuiltData` 生成报告记录，`commit()` 为空，随后读取 `patchedData`。

因此，对全新实例，在同输入、同选项、相同外部状态与外部操作返回序列、正常完成且不消融的条件下，状态包装执行相同产物计算并返回相同字节。包装不再次合并、加密或序列化。旧记录为空字节占位，新记录为真实 Manifest 替换；记录语义有意改变，不要求两者 records 相等。

失败从抛异常转为 required failed；未执行时 `patchedData` 从强制解包改为原输入回退。这些是状态表达变化。外部部分写入仍可能存在，不能由失败报告推断已回滚。

迁移后的临时文件清理是独立改动：删除转换后的解密源、删除转换后的中间 raw image、在 SystemOS 成功卸载后清理解密临时文件。前两处删除可能抛错，其验证必须与纯包装证明分别记录。

该结构证明不能表述为已执行两次完整 APFS/AEA 镜像逐字节比较。代码使用 UUID 临时目录，并读取操作后 mtree 的修改时间生成 remap；外部 AEA 工具未由代码指定确定性随机源。独立重建不具备相同外部返回序列。若观察到差异，仍须定位具体字段，不能未经验证统称随机差异。

### 本轮实际产物的必要检查

- 完整结构化方法集合及必要集合通过。
- Filesystem 输出与后续 Manifest 输入完整字节相等，最终落盘等于 Manifest 记录输出。
- 四组件的实际摘要与 Manifest 相等，路径限制在隔离目录。
- 最终 AEA 独立解密成功，所需内容存在；canonical metadata 和原始输出 root hash 通过独立验证。
- 原始镜像输入哈希未变，卸载状态与临时清理结果有记录。

`LessOutputParityTests` 已对本次真实 Manifest 及 iBEC、LLB、DeviceTree 三个引导组件完成 legacy/structured 比较及实际输出 payload 比较，全部通过，耗时 64.249 秒。该结果来自本次产物，不以非 less 的版本名称或工厂相同替代。

本轮独立验证已通过全部 21 个 Manifest 组件的 SHA-384、来源输入不变检查及 Filesystem 字节链检查。最终 AEA 独立解密与内容检查成功。独立 root hash 校验退出码为 0，使用原始输出 root hash，未导入 digest.db；验证副本已卸载并删除，交付产物未变。结果见 `research/artifacts/c3-less-pipeline-2026-09-10/content-verification/result.json`。AEA SHA-256 为 `3319c2a527539606db27b0e441a5abf84a778cba7c56eeec1709a23729775b05`，root hash 容器 SHA-256 为 `04f31da4e2ba3e1a5be65e30b16178ec1312f7e1cf7b1b504b932375cdc75ade`。旧 [less 验收](c3_less_acceptance_2026-09-09.md)的根哈希通过结果只覆盖旧产物，不自动覆盖本轮新产物。

初次独立校验器假设“没有补丁工厂的组件容器字节不变”，因此在 TXM 容器变化时报告失败。生产流水线仍会对这些组件执行 loader 保存，产生重封装。后续直接比较确认 iBSS、TXM、kernelcache 的完整 payload 逐字节相等，fourcc 与 description 一致；观察到压缩表示从 LZFSE 变为 none。该差异属于容器重封装，不能以容器哈希不同推断补丁 payload 改变，也不能宣称这些容器文件字节未变。来源输入不变检查与隔离产物容器变化分别记录。

## C1 登记与保留限制

已新增七条 `patch_verified`：263、2661、270b5、1862 默认非 less 组合，2661 与 270b5 Frida 组合，以及 less-261 默认组合；261 既有条目追加完整 parity 证据。记录仅包含本次实际通过变体。

历史 `23D128`、26.5 合成组件结果、其他 iOS 27 与 26.6.1 capability 条目保留原日期和证据，不以本轮结果替换。已有 23 条 `code_selectable` 仍只表示代码可选择。新记录须明确限定为本次补丁/产物验收、固定 AVPBooter 来源，不包含恢复、启动、GUI、Frida 客户端 instrumentation 或 C4 中断恢复。less 非默认安装选项不随本轮获得验证。

## 证据归档

主控逐组核对五份 parity-summary 的场景集合与生产 verification、DeviceTree 结果一致，共 24 场景；各项 `expected_test_passed` 为真且退出码为 0。less 完整日志归档于 `research/artifacts/c3-less-pipeline-2026-09-10/`，包括 `pipeline.log`、`output-parity.log`、`verification.log`、`content-verification.log` 和 `content-verification/result.json`。上述本地大型产物目录由 Git 忽略；本页、验收脚本及测试随提交保存。

## 最终汇总

本轮默认回归：Python 73 项通过；XCTest 共 21 项，其中完整流水线 parity 因未设置样本环境跳过 1 项，实际执行 20 项、0 失败；Swift Testing 300 项通过。`make build` 构建与签名通过。原始固件环境门控测试与默认回归分开记录。

全部 24 个非 less 场景及 less 默认场景验收已完成，C3 标记完成，总清单为 9/28。Filesystem 的等价性证据按前述结构证明、真实字节链及独立产物校验限定，不宣称两次完整镜像字节实测。恢复/启动、跨文件中断恢复及范围之外组合仍未由此获得验证。
