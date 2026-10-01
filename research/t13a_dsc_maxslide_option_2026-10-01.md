# T13a：DSC maxSlide 选项层对齐（2026-10-01）

范围：何时执行 `patch-dsc-maxslide` 的检查与清零，包括选项、默认值和决策逻辑。清零写入的字段、字节和写入方式不变。其他补丁未改动。

## 来源

- 上游提交 `d930e50`（"Remove --force-dsc-maxslide from every command and from Launchpad"，包含于 `upstream-2.2.3`）。
- `upstream-2.2.3:VPhoneExecutable/VPhoneCommand/FirmwarePatcher/DyldSharedCache/Patchers/DyldSharedCacheMaxSlidePatcher.swift`
- `upstream-2.2.3:VPhoneExecutable/VPhoneCommand/FirmwarePatcher/DyldSharedCache/DyldSharedCacheChunkSet.swift`
- `upstream-2.2.3:VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift`
- `upstream-2.2.3:VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareDyldSharedCacheVerbsCommand.swift`
- `upstream-2.2.3:VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/FirmwareGuestSystemPatchSet.swift`
- 本地基线 `6c7cb3f`：`scripts/patchers/cfw_patch_dsc_maxslide.py`、`scripts/patchers/cfw.py`、`scripts/cfw_install.sh`、`scripts/cfw_install_host.sh`、`sources/vphone-cli/VPhoneVMCreateCLI.swift`、`sources/vphone-cli/VPhoneRestoreCLI.swift`；映射记录 `research/t09_patch_id_mapping_2026-10-01.json`（`dyld-boot-maxslide`）；声明 `sources/FirmwarePatcher/PatchSet/PatchDeclarationCatalogData.swift:688-701`。

## 对照

上游行号指 `upstream-2.2.3`。本地行号指 `6c7cb3f`（改动前）。

### 安装侧门控

| 项目 | 上游 | 本地（改动前） |
| --- | --- | --- |
| 版本门 | `VPhoneCustomFirmwareInstaller.swift:549` `version.hasPrefix("27.")` | `scripts/cfw_install.sh:251-252` `case "$IOS_VERSION" in 27.*)` |
| 计划开关 | `:553` `on("dyld-boot-maxslide")`；声明 `FirmwareGuestSystemPatchSet.swift:43` 起，`iOSBase: .major(27)` | 无计划开关；声明层 `optIn: .none`，`versionRule: nil`（guest 步骤只登记，不门控） |
| 安装调用参数 | `:554` `patch("patch-dsc-maxslide", [dsc])`，无 `--force` | `cfw_install.sh:255` 无 `--force` |
| 非 27 基线 | 不调用 | `cfw_install.sh:264-268`：`FORCE_DSC_MAXSLIDE=1` 时调用 `--force`；默认值 `0`（`:250`） |
| 强制入口 | 已删除 `--force-dsc-maxslide`（`vm create`、`restore`、`cfw install`、Launchpad） | `VPhoneVMCreateCLI.swift:38`、`VPhoneRestoreCLI.swift:130` 的 `--force-dsc-maxslide` 设置 `FORCE_DSC_MAXSLIDE=1`（`VPhoneRestoreCLI.swift:159`、`VPhoneCreateOrchestrator.swift:910`）；`cfw_install_host.sh:189` 转发该变量 |
| 手动入口 | 独立命令 `patch-dsc-maxslide --force` 保留（`VPhoneCustomFirmwareDyldSharedCacheVerbsCommand.swift:250`） | `cfw.py patch-dsc-maxslide --force`（`cfw.py:234-241`） |

### 补丁器判断

| 项目 | 上游 `DyldSharedCacheMaxSlidePatcher.swift` | 本地 `cfw_patch_dsc_maxslide.py`（改动前） | 结论 |
| --- | --- | --- | --- |
| 区域上限 | `:84` 常量 `0x180000000`（vphone600 26.x 内核 `SHARED_REGION_SIZE_ARM64`） | `:43` 同值常量 | 等价 |
| 主分块存在 | `:207-209` | `:48-49` | 等价 |
| 头部读取 | `:354-364` 取主分块文件偏移 0 的映射地址，`:385` 经映射读取 0x100 字节 | `:52` 直接读文件偏移 0 的 0x100 字节，不检查读到的长度 | 读取内容相同；本地缺少映射检查，短文件触发 `struct.error` |
| magic | `:387-392` 前 7 字节 `dyld_v1` | `:53-54` 同 | 等价 |
| 字段存在 | `:394-402` `mappingOffset >= 0xF8` | 无 | 不等价 |
| 与映射表交叉校验 | `:410-417` `sharedRegionStart` 等于全部分块最低映射地址；`:418-425` `sharedRegionSize` 不小于映射跨度 | 无 | 不等价 |
| 求和溢出 | `:227-234` 64 位溢出时报错 | 无（Python 整数无溢出，继续判断并可能写入） | 不等价 |
| 判断式 | `:236` `size + maxSlide <= region` 为可容纳 | `:60` 同 | 等价 |
| 可容纳且无 force | `:237-252` 不写 | `:61-64` 不写 | 等价 |
| maxSlide 已为 0 | `:253-265` 不写 | `:65-67` 不写 | 等价 |
| 写入 | `:309` 经映射写入 8 字节 0；`:315-320` 回读校验 | `:77-85` 在文件偏移 0xF0 写入 8 字节 0，`fsync`，回读校验 | 写入位置与字节相同（头部映射文件偏移为 0） |
| 重新签名页 | 不做 | 不做 | 等价 |

`FORCE_DSC_MAXSLIDE` 覆盖的情形是“非 27 基线且缓存可容纳时仍清零”。上游没有替代的安装路径：声明固定为 `iOSBase: .major(27)`，安装器不传 `--force`，非 27 基线保留原 slide。上游只保留手动执行 `patch-dsc-maxslide --force`。

上游 `d930e50` 提交说明记录：24A435 缓存头 `size 0x17D504000 + maxSlide 0x20000000 = 0x19D504000`，超过 `0x180000000`，自身判断即会清零，无需 force。

## 决定与依据

1. 删除强制选项。依据：上游 `d930e50` 删除全部强制入口；本地 27 路径从未使用 `--force`。
2. 保留 `27.*` 安装门，不改为在所有基线上运行跨度检查。依据：上游安装器 `:549` 与声明 `iOSBase: .major(27)` 均保留 27 门；在非 27 基线运行检查会与上游行为不同。
3. 补丁器头部校验改为与上游等价：补齐头部长度、`mappingOffset`、文件偏移 0 映射、`sharedRegionStart`、`sharedRegionSize` 与映射跨度、64 位求和六项检查。任一失败抛出 `RuntimeError`，不写入；`cfw.py` 以非零状态退出，`cfw_install.sh`（`set -e`）随之停止。映射表复用 `cfw_dsc_chunks.DSCChunks.mappings()`，该模块未修改。
4. 旧环境变量：`cfw_install_host.sh` 在取得锁之后检查 `FORCE_DSC_MAXSLIDE`。非空时向 stderr 打印已移除提示（含原值），然后 `unset`，不再转发给任何变体安装脚本。该脚本是 regular/dev/jb/exp 四个变体的共同入口，提示对四个变体一致。less 变体没有 CFW 安装步骤（`t09` 记录：`CryptexFilesystemPatcher.swift:141` 不含该补丁），不涉及该变量。
5. 旧 CLI 选项：从 `vm create` 与 `cfw install` 删除 `--force-dsc-maxslide`。传入时 ArgumentParser 报未知选项并退出。`VPhoneCreateOrchestrator`、`VPhoneCreateRunner`、`VPhoneCreateCheckpoint` 中的 `forceDscMaxSlide` 字段未改（范围外文件）；CLI 不再设置它，默认值为 `false`/`nil`。已有检查点若记录为 `true`，恢复时仍会设置环境变量，由第 4 条的提示处理。
6. 声明表无需修改：`PatchDeclarationCatalogData.swift:694` 与 `research/t10_patch_declarations_2026-10-01.json` 中该项 `optIn` 已是 `none`，没有 force 类 opt-in。

## 改动

| 文件 | 改动 |
| --- | --- |
| `scripts/patchers/cfw_patch_dsc_maxslide.py` | 新增 `_read_header`（`:68-107`）执行六项校验；溢出检查（`:119`）；判断与写入代码保持原样；文档字符串去掉非 27 opt-in 描述；`_self_test` 改用带映射表的合成头部 |
| `scripts/patchers/cfw.py` | `patch-dsc-maxslide` 帮助：`--force` 仅供手动执行，安装脚本不传；说明校验失败不写入 |
| `scripts/cfw_install.sh` | 删除 `FORCE_DSC_MAXSLIDE` 默认值与非 27 `--force` 分支；`27.*` 分支调用不变（`:253-256`）；更新注释 |
| `scripts/cfw_install_host.sh` | 删除变量转发；新增已移除提示与 `unset`（`:66-73`） |
| `sources/vphone-cli/VPhoneVMCreateCLI.swift`、`sources/vphone-cli/VPhoneRestoreCLI.swift` | 删除 `--force-dsc-maxslide` 及其传递 |
| `tests/test_dsc_maxslide.py` | 新增：13 项 |
| `tests/test_cfw_host_isolation.py` | 安装脚本替身记录收到的 `FORCE_DSC_MAXSLIDE`；`start()` 增加 `variant` 参数；新增 1 项 |
| `tests/VPhoneCLITests/DyldMaxSlideOptionTests.swift` | 新增：3 项 |
| `research/0_binary_patch_comparison.md` | 新增 2026-10-01 T13a 段落；第 10 行、iOS 27 校验表与安装流程矩阵中的 opt-in 描述改为已删除 |

## 测试覆盖

合成缓存：主分块 `dyld_shared_cache_arm64e`，头部 0x100 字节，`mappingOffset 0x198`，一条映射（地址 `0x180000000`，跨度为 `size - 0x4000`，文件偏移 0）。断言返回值、完整文件字节和输出行。

| 情形 | 用例 | 断言 |
| --- | --- | --- |
| 需要清零 | 24A435 头部值；dry-run；CLI 退出码 | 只有 `0xF0..0xF8` 变为 0；dry-run 不写；输出 `overflow: span+maxSlide 0x19D504000 > region 0x180000000` |
| 不需要 | `0x140904000 + 0x20000000`；恰好等于区域；手动 `force=True` | 不写；`force` 仍清零（手动入口保留） |
| 已为 0 | 清零后重跑；`force` 且为 0；超出区域但为 0 | 返回 0，字节不变 |
| 头部损坏 | magic、0x80 字节头部、`mappingOffset 0xF0`、无文件偏移 0 映射、起始地址不符、size 小于跨度、64 位溢出、主分块缺失；CLI 退出码 | 抛出错误，文件字节不变；CLI 非零退出 |
| 旧环境变量 | 四个变体 × 值 `1`/`0`；未设置；安装脚本静态检查 | 提示出现一次；安装脚本收到 `<unset>`；未设置时无提示；安装脚本代码行不读取该变量，`patch-dsc-maxslide` 只在 `27.*` 分支调用且无 `--force` |

## 命令与结果

日志位于 `research/artifacts/t13a-dsc-maxslide-2026-10-01/`（Git 忽略）。环境：`.venv` 为主仓库 `.venv` 的符号链接；`vendor/*` 子模块递归初始化；按 Makefile 格式生成被忽略的 `sources/vphone-cli/VPhoneBuildInfo.swift`。

| 命令 | 结果 |
| --- | --- |
| 改动前：`HEAD` 的 `scripts/`、`tests/` 导出到 scratchpad，放入新测试后运行 `python -B -m unittest tests.test_dsc_maxslide tests.test_cfw_host_isolation` | 32 项，`failures=16, errors=1`。错误：0x80 字节头部触发 `struct.error`。失败：5 个头部损坏子用例未抛错并写入；CLI 对起始地址不符返回 0；`cfw_install.sh` 有 2 处调用（第 255、267 行）；`cfw_install.sh` 读取变量；四变体 × 两值共 8 个子用例无提示 |
| 改动前 Swift：临时恢复两份 CLI 文件，`swift test --skip-build --filter DyldMaxSlideOptionTests` | 3 项中 2 项失败，5 个 issue：带 `--force-dsc-maxslide` 的三次解析未报错；两份帮助文本含该选项 |
| 改动后：同一 unittest 命令 | 32 项通过 |
| `python3 scripts/patchers/cfw_patch_dsc_maxslide.py`（自检） | `self-test OK` |
| `swift build --build-tests` | 完成 |
| `swift test --skip-build --filter DyldMaxSlideOptionTests` | 3 项通过 |
| `make test_python` | 417 项通过，1 项跳过（`test_daemon_api_icli`：IcliKit checkout 缺失，与本项无关） |
| `make test_swift` | 退出 0；Swift Testing 10 次运行共 804 项通过；XCTest 执行 183 项，3 项跳过，0 失败；tar pipe 两条 1 GiB 路径峰值 RSS 8,929,280 / 8,060,928 字节；`test_guest_components` 124 项检查 0 失败 |

## 事实、推断与未验证

事实：

- 本地 27 路径的判断式、写入位置和写入字节与上游相同；改动未改变这部分代码。
- 改动前，本地补丁器对上游会拒绝的 5 类头部继续写入，对短头部以 `struct.error` 失败。改动后这些情形均报错且不写入。
- 改动后没有安装路径会传 `--force`；`FORCE_DSC_MAXSLIDE` 在四个变体入口均被报告并不再转发。

推断（待验证假设）：

- 真实 iOS 27 缓存满足新增校验。依据是上游 `readHeader` 注释记录 24A435 arm64e 缓存 `start 0x180000000`、`size 0x17D504000`、映射跨度 `0x17D500000`。本地 `DSCChunks` 分块枚举规则与上游 `enumerateChunks` 基本一致（均排除 `.symbols`、`.map`），未在真实缓存上比对映射集合。

未验证：

- 真实 iOS 27 DSC 上的 `patch-dsc-maxslide` 运行（本机无已解出的 DSC）；新增校验对 24A5380h、24A5408d、24A435 缓存的结果。
- CFW 安装后 iOS 27 客户机启动（`launchd`、`libSystem` 映射）。未操作 VM。
- `--root-popup`（osascript）路径下提示的显示；测试只覆盖 `cfw_install_host.sh` 的直接执行。
- 记录 `force_dsc_max_slide: true` 的已有 create 检查点在恢复时的端到端行为。
- `research/t09_patch_id_mapping_2026-10-01.json` 中 `FORCE_DSC_MAXSLIDE` 相关条目是 T09 当日快照，未修改。
