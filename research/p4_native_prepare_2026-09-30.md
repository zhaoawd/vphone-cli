# P4 第一批：本地 IPSW 的原生 classic prepare

## 实现范围

固定上游来源为 `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3` 的 `VPhoneFirmwarePreparer.swift`，原文件 SHA-256 为 `9fc62bde68bc056f32a27c76a291370c11c4f160cd7f6109b300ff26671ab496`。迁入本地 `VPhoneNativeFirmwarePreparer`，使用现有 `VPhoneArchiveKit`、`VPhoneIPSWCache` 和 Swift `FirmwareManifest`。

新增显式入口：

```sh
vphone-cli fw prepare NAME --prepare-backend native \
  --iphone-source /path/to/iphone.ipsw \
  --cloudos-source /path/to/cloudos.ipsw
```

省略参数仍使用 `script`。原生入口只支持本地普通文件和 classic 布局，不支持下载、版本选择器、less 或 v2 GPU/客户机布局。第一批未接入 `vm create` 检查点；第二批接入结果见下文。P4 尚未完成。

## 行为与保护

- 整个准备过程持有现有 VM 目录锁；运行中拒绝。
- 先检查已有 Restore 路径，包含普通文件和悬空链接。拒绝覆盖或自动删除，不复用旧暂存目录。
- 检查 iPhone/cloudOS 来源身份。版本和 build 只允许字母、数字与点，不能构成路径跳转。
- 归档只允许普通文件和目录，拒绝链接、特殊文件、重复成员、歧义路径及特殊权限位，限制最多 100,000 个成员。要求两份根级清单都是普通文件。
- 核算 iPhone 解包量、cloudOS 解包量及额外 cloudOS 复制量，加上 10 GiB 保留空间。声明长度溢出时拒绝。
- 在 VM 内随机创建 `0700` 暂存目录，完成提取、合并和清单生成后，用 `renamex_np(RENAME_EXCL)` 发布。抛错只清理本次暂存目录；强制终止可能留下隐藏暂存目录，不会发布为 Restore 树。
- 提取前后核对源文件设备、inode、长度、mtime 和 ctime；不改写源 IPSW。此检查不是 Apple 签名认证。
- cloudOS kernelcache、指定 Firmware 子目录及根级 im4p 覆盖对应暂存组件；同名 iPhone dmg 和 dmg.trustcache 保留。原 iPhone BuildManifest 单独保留。
- 清单生成使用既有 Swift 实现。本批没有增加或修改二进制补丁，没有进行内核指令分析。

## 验证

6 项专项测试通过：后端显式选择、合并及源归档不变、重跑拒绝、清单失败清理、取消、发布竞争、归档链接/悬空目标拒绝及 VM 锁占用拒绝。测试中的生成器注入用于检查失败和竞争；真实清单生成另以原始固件验证。

首次编译存在遗漏 `try` 和测试闭包参数标签问题，已修正。首次默认 Swift 编译受全局 module cache 沙箱权限限制，使用项目测试缓存后可编译。全量沙箱回归包含进程查询、socket 和权限位失败，以及旧超时测试失败；不得将该次运行记为通过。宿主权限下按默认调度复跑 `make test_swift` 通过：Swift Testing 744 项 / 106 suites，XCTest 178 项（3 项跳过、0 失败）；归档内存检查、RootHide loader-link 检查和相机 124 项检查通过。沙箱失败日志和成功复跑日志分别保留。

真实输入为已缓存的 iPhone/PCC 26.1 / 23B85。测试目录 `research/artifacts/native-prepare-2026-09-30/library/preparation-only` 仅复制配置文件用于 CLI 定位，没有 VM 磁盘、NVRAM、SEP、票据或设备运行状态，不可作为已创建或可启动 VM。

原生 prepare 退出 0，耗时约 36.15 秒；最低可用空间 66,764,800,000 字节，约 62.18 GiB。验收包装脚本每秒检查磁盘空间，低于 10 GiB 即暂停进程组，本次未触发。

输出 182 个文件。对 180 个非生成清单文件的 11,060,157,452 字节，按来源和覆盖规则与原始 ZIP 成员逐字节比较通过。`BuildManifest.plist` 与 `Restore.plist` 使用原始四份 plist 运行现有 Python `fw_manifest.py` 后比较，解析后的内容一致。没有将两个 plist 的序列化字节一致作为要求。

日志、命令、逐文件摘要与比较脚本位于 `research/artifacts/native-prepare-2026-09-30/`；原始缓存、既有 VM 与已验收导出包保留。

## 后续范围

仍需原生 prepare 接入 checkpoint/resume、源选择和下载、GPU 驱动及 compiler plugin、v2 bundle 与原生 CFW。完整变体映射和 less 路径单独处理。本次结果不证明固件补丁、恢复、启动、Metal 或客户机 Hook 行为。


`make build` 通过，完整 app 的资源、签名和 entitlements 校验通过。签名 CLI 的 prepare 帮助返回 0；对已有 Restore 树的重跑请求返回 1，在打开所给缺失 IPSW 前拒绝。源码、CLI/VM 摘要及新 cdhash 保存于证据目录 `artifacts.json`。最新产物未执行 VM 启动，不沿用旧产物的 AMFI 或启动结论。

## 第二批：创建检查点与续跑（2026-09-30）

新增创建入口：

```sh
vphone-cli vm create NAME --prepare-backend native \
  --iphone-source /absolute/path/to/iphone.ipsw \
  --cloudos-source /absolute/path/to/cloudos.ipsw
vphone-cli vm create --resume NAME
vphone-cli vm create --resume NAME --restart-from prepare
```

`prepare_backend` 写入 `effective_options`，并参与 `inputs_digest`。默认 `script` 不编码；旧检查点的编码与摘要保持兼容。未给该参数的续跑沿用原值；prepare 已完成后切换后端，runner 在归档及写入前拒绝，要求从 prepare 重跑。恢复后端仍由独立的 `restore_backend` 控制。七阶段、变体适用规则与 `stage_contract_version = 1` 保持不变，产物布局未改变。

原生创建入口不调用固件下载选择器。两份来源按同一基目录转成绝对路径，再记录到检查点；从其他工作目录续跑时使用已记录路径。原生 prepare 仍只支持本地普通文件和 classic 布局，拒绝 URL、缺少来源及 less。重跑 prepare 时仍要求源文件可读；跳过 prepare 时不重新打开 IPSW。

执行器直接调用现有原生 preparer，整个提取、合并及发布过程持 VM 目录锁。prepare evidence 新增 `prepare_backend`。只读验证器检查 evidence 与有效选项一致；历史 evidence 缺少字段时按 `script` 处理。backend 不一致时拒绝，包括当前 Restore 树已按默认规则清理的情况。

独立 `fw prepare` 保持已有 Restore 路径拒绝规则。检查点 prepare 存在重跑历史时，可处理唯一的普通 `iPhone*_Restore` 目录：先保留原树并生成新树；清单生成完成后复核旧树目录身份，将旧树移动到 VM 内随机的 `0700` `.firmware-prepare-backup-*` 目录，再用 `RENAME_EXCL` 发布新树。多个 Restore 路径、普通文件、符号链接和悬空链接均拒绝。发布失败时尝试排他回滚；回滚被占用时保留备份并报告路径。备份不参与自动清理，由操作员显式处理，重复重跑会增加空间占用。

旧树移动与新树发布为两次 rename；本批不宣称该替换具有整体原子性。强制终止可能留下隐藏暂存目录或备份；续跑不复用暂存目录，可从原始 IPSW 重新准备。新树发布后、成功检查点提交前中断时，磁盘上的 prepare 为 `running`；续跑探测空闲后重跑，并保留已发布旧树。

当前 Restore 树继续使用原 `retain_until`，在 patch、restore、cfw、first_boot、verification 完成前保留；`--keep-artifacts` 继续生效。备份不属于该自动删除范围。新版二进制续跑旧创建时，现有工具摘要检查仍生效，需要按实际提示使用 `--accept-tool-change`。

第二批专项 90 项 / 4 suites 通过，包括历史选项摘要、后端切换拒绝后检查点不变、失败和取消续跑、旧树保留、发布失败回滚、拒绝链接/歧义路径，以及产物保留和默认清理。一个合成输入集成测试通过实际原生 prepare 分发与 Swift 清单生成，再用实际只读验证器验收；注入成功检查点 rename 失败后续跑通过，第二次续跑跳过 prepare 并复核清单与产物指纹。该测试使用合成 ROM，在 patch 执行前主动失败，不执行二进制补丁或 VM 操作。

首次专项存在 URL 的尾部斜杠比较差异，改为比较路径；首次全量回归发现新增相对路径测试在并行测试修改进程 cwd 时读取了不同基目录，已固定测试基目录，并让两个来源使用同一基目录解析。失败日志保留；复跑 `make test_swift` 通过：Swift Testing 753 项 / 107 suites；XCTest 178 项（3 项跳过、0 失败）；归档内存、RootHide loader-link 和相机 124 项检查通过。

本批起始可用空间约 27.7 GiB。没有重新复制或解包 26.1 真实固件，没有安装 helper、恢复或启动 VM；第一批的真实组件对照结果不作为本批完整创建流程的实机证据。本批未增加二进制补丁。GPU/compiler plugin、v2、下载及原生 CFW 仍待完成，P4 保持未完成。

日志与后续构建摘要保存在 `research/artifacts/native-prepare-checkpoint-2026-09-30/`。

第二批 `make build` 通过；`check_bundle.py --execute` 确认完整资源、签名、VM entitlements，以及从外部 cwd 和符号链接执行的签名 CLI 资源定位。签名 CLI 的 create/prepare 帮助均包含 `--prepare-backend`；缺少来源、native + less、已有 Restore 路径三项拒绝检查均返回 1。拒绝创建后未生成目标库目录；已有 Restore 的标记内容不变，未生成准备暂存或备份目录。最终可用空间为 29,614,080,000 字节，约 27.58 GiB。源码 SHA-256、最终 CLI/VM SHA-256 与 cdhash、命令和退出状态保存在本批 `artifacts.json`。未执行本批 VM 产物，不沿用旧 VM 执行准入或启动结论。
