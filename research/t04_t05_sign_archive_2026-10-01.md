# T04/T05：签名命令区空间与 C locale 下 UTF-8 归档

日期：2026-10-01。本地分支 `codex/upstream-4bab3b7-integration`，基线 HEAD `8d84bbc6bf5e6f0ce0301f43afe7fb1ef3a37f3d`。本记录对应的改动未提交。

上游固定输入：

- `upstream-2.2.3` = `a969cd5d9206932dc1a2797348027fbc7d0ee347`
- `upstream-2.0.8` = `9d218dedf58d4b19db5e51c8b584c1f14a96eee3`
- 读取方式：`git show upstream-2.2.3:<path>`、`git show <sha>`、`git diff upstream-2.0.8 upstream-2.2.3 -- <path>`。未 checkout、merge 或 cherry-pick 上游。

## T05：C locale 下 UTF-8 归档

### 来源

| 项 | 值 |
| --- | --- |
| 提交 | `7f746eedfe79a3e7ec7603cde79f3b803e990489`（2026-09-30，"Read and write UTF-8 archive names in the C locale"） |
| 新增文件 | `VPhoneKit/VPhoneArchiveKit/Archive/VPhoneArchiveLocale.swift`（`withArchiveLocale`） |
| 调用点 | `VPhoneArchiveReader.withReader`、`VPhoneArchiveExtractor.extract`、`VPhoneArchiveWriter.create`；提取器拒绝 NULL 成员名 |
| 上游测试 | `VPhoneKit/VPhoneArchiveKitTests/RoundTripTests.swift`：gnutar/pax 往返、UTF-8 标志 zip |
| 之后的上游变化 | `7f746eed..upstream-2.2.3` 在 `VPhoneKit/VPhoneArchiveKit` 下只有 `a3d2382`，仅修改 `Transfer/VPhoneBundleTransfer.swift` 的导出排除项，与 locale 无关 |

### 本地修改

| 文件 | 修改 |
| --- | --- |
| `sources/VPhoneArchiveKit/Archive/VPhoneArchiveLocale.swift`（新增） | 迁入 `withArchiveLocale`：`duplocale(uselocale(nil))` 复制当前线程 locale，`newlocale(LC_CTYPE_MASK, "UTF-8", base)` 只替换 LC_CTYPE，`uselocale` 设置到当前线程，`defer` 中恢复原 locale 并释放。`newlocale` 或 `duplocale` 失败时按原 locale 执行。不调用 `setlocale` |
| `VPhoneArchiveReader.swift` | `withReader` 整个 libarchive 会话包在 `withArchiveLocale` 内。`entries`、`readMember`（含硬链接递归）、`describe` 都经过该函数 |
| `VPhoneArchiveExtractor.swift` | 公开 `extract` 改为在 `withArchiveLocale` 内调用新的私有 `unpack`，`unpack` 为原函数体。`archive_entry_pathname` 返回 NULL 时抛出 `readFailed`（原因含 "member name cannot be converted"），不再按 `""` 处理 |
| `VPhoneArchiveWriter.swift` | `create` 在 `VPhoneArchiveOutput.publish` 闭包内用 `withArchiveLocale` 包住 `createFile`。路径解析、源树/输出位置检查、`topLevel` 检查和排他发布在包装外，未改动 |

未改动：链接目标与路径越界检查、`--no-overwrite-dir`、排他发布（`VPhoneArchiveOutput`）、稀疏文件与内存约束、`decompress`（raw 格式，无成员名转换；上游同样未包装）。

与上游的差异：上游 Writer 把整个 `create` 包在 `withArchiveLocale` 内；本地 `create` 结构不同（先检查，再经 `publish` 写临时文件），包装位置放在 `createFile` 外层，libarchive 会话范围相同。Reader 的 `makeEntry` 和 `readMember` 对 NULL 名仍映射为 `""`，与上游 2.2.3 相同。

### 测试

新增 `tests/VPhoneArchiveKitTests/ArchiveLocaleTests.swift`，Suite "Archive names in the C locale"，`.serialized`。每个用例用 `uselocale` 把当前线程固定为 "C"。

| 用例 | 覆盖 |
| --- | --- |
| non-ASCII names and link targets round trip in the C locale（gnutar/pax/ustar） | 中文、西里尔、emoji、带重音字符的目录名、文件名和两个符号链接目标；写 → `entries` → `readMember` → 提取；检查条目集合、`linkTarget`、内容和提取后的链接目标 |
| a UTF-8 flagged IPA-shaped zip ... | 在 UTF-8 locale 下用 libarchive 写出带 UTF-8 标志（bit 11）的 zip，布局为 `Payload/应用.app/...`，含非 ASCII 符号链接目标；在 C locale 下分别列出、读取成员、提取 |
| an entry whose name cannot be converted is refused ... | 失败路径：UTF-8 标志 zip 中成员名含非法 UTF-8 字节 0xFF；在 C 与 UTF-8 locale 下提取都必须抛出 `VPhoneArchiveError`，目标目录仍为空目录 |
| a missing non-ASCII member is reported by name ... | 失败路径：`readMember("目录/不存在.txt")` 抛出 `memberNotFound`，成员名原样返回 |
| archive calls restore the calling thread's locale, including on failure | `create`/`entries`/`readMember`/`describe`/`extract` 成功及失败（缺失归档、缺失成员、已存在输出）后，线程 locale 对象指针与 codeset 不变 |
| withArchiveLocale changes only the calling thread, and only inside the call | 包装内当前线程 codeset 为 UTF-8；同一时刻另一线程读到的 codeset 与包装外相同；`setlocale(LC_CTYPE, nil)` 不变；正常返回和抛错后均恢复 |
| archive calls do not change other threads or the global locale | 8 轮 pax 写/读期间，另一线程持续采样 codeset，只出现初始值；全局 LC_CTYPE 不变 |

### 修改前复现（事实）

在未修改的实现上运行前 6 个用例（`withArchiveLocale` 直接测试引用新符号，修改后才加入）。命令：`swift test --disable-sandbox --cache-path .build/test-cache --filter ArchiveLocaleTests`（环境变量 `CLANG_MODULE_CACHE_PATH`、`SWIFT_MODULECACHE_PATH` 指向 `.build/test-module-cache`，同 `scripts/run_tests.py`）。结果：`Test run with 6 tests in 1 suite failed ... with 10 issues`，退出码 1。

- gnutar、ustar 往返在修改前通过；pax 写入失败：`Unable to write to lien-данные (Can't translate pathname 'lien-данные' to UTF-8)`。
- UTF-8 标志 zip：`entries` 结果与期望集合不一致，符号链接目标不一致，`readMember` 报 `does not contain 'Payload/应用.app/Info.plist'`。
- 非法 UTF-8 成员名：`extract` 未抛错并返回 `1`；之后 `lstat` 显示目标路径不再是目录，`contentsOfDirectory` 失败。推断：NULL 名按 `""` 解析为目标目录本身，该条目写在目标目录的位置。
- 其余 3 个用例在 pax 建档步骤失败，错误同上。

修改后同一命令：`Test run with 7 tests in 1 suite passed`，退出码 0。

### 变异检查

临时把 `withArchiveLocale` 改为进程级 `setlocale(LC_CTYPE, "UTF-8")`，运行同一 Suite：7 个用例中 6 个失败；线程隔离用例报 `inside == "UTF-8"`、`elsewhere == CodesetObserver.sampleOnAnotherThread()` 两项期望失败。之后恢复原文件，`diff` 确认与修改后版本一致。该检查说明隔离用例能区分线程局部与进程级实现。

### T05 未覆盖

- guest 端 `scripts/vphoned/unarchive.m`（Objective-C，guest 内 IPA 解包）未修改。该路径对 NULL 名返回失败，不会写到目标目录；C locale 下 UTF-8 标志 IPA 的解包结果未验证。上游对应修复在 icli 0.7.5（提交说明 #530），属 T08 范围。
- 提取器对转换失败的硬链接目标（`archive_entry_hardlink` 返回 NULL）未单独拒绝，与上游相同。
- 未在真实 IPA、VM 导入导出或 guest 安装流程上验证。
- 测试进程中 C locale 由 `uselocale` 设置在测试线程上，未以 `LC_ALL=C` 启动独立进程验证。`grep` 核对 `sources/` 下除新文件外没有 `setlocale`/`uselocale` 调用；进程启动后 locale 为 "C" 属上游说明，本地未单独测量。

## T04：签名与 Mach-O 空间修复

### 来源与范围

`git log upstream-2.0.8..upstream-2.2.3 -- VPhoneExecutable/VPhoneCommand/VPhoneSign VPhoneExecutable/VPhoneCommand/VPhoneSignTests` 只有两个提交：

| 提交 | 内容 |
| --- | --- |
| `ee8b70ca8a6a7410f04c5064cdde409d5f6030b8` | `VPhoneMachOImage.signed()`：命令区放不下新的 LC_CODE_SIGNATURE 时移除 LC_SOURCE_VERSION 并重新计算。提交说明记录 iOS 18.6.2 (22G100) launchd 在 inject-dylib 后报 `content starts at 3208, 3224 bytes of commands`，移除后 cfw install 完成 |
| `cd45b8fab2c1fb6f542953335fdd3889492bdb91` | 同一位置：仍放不下且存在 LC_UUID 时移除 LC_UUID。提交说明只有标题 "Fix iOS 26.3 launchd signature space"，无验证记录 |

`git diff --stat`：只有 `VPhoneSign/MachO/VPhoneMachOImage.swift` 变化（+24/−2）；`VPhoneSignTests` 在该区间无变化。

### 逐项对照

对照方式：`git archive upstream-2.2.3` 导出两目录，与 `sources/VPhoneSign/`、`tests/VPhoneSignTests/` 逐文件 `diff`。

| 项 | 上游 2.2.3 | 本地（修改前） | 结论 |
| --- | --- | --- | --- |
| LC_SOURCE_VERSION 移除（ee8b70ca） | 有 | 无；同类输入报 `noRoom` | 缺失 → 已迁入 |
| LC_UUID 移除（cd45b8fa） | 有 | 无 | 本地有意不同：不采用。依据：宿主 dyld 拒绝缺少 LC_UUID 的主程序（见“宿主证据与决定”）；客户机 dyld 行为未验证。用户 2026-10-01 决定不保留 |
| `carried`/`rebuilt` 改为 `var` | 有 | `let` | 属 ee8b70ca，已迁入 |
| `VPhoneMachOImage.swift` 其余内容 | — | 与上游相同 | 已等价存在 |
| `VPhoneSigner.swift` | 2.0.8 与 2.2.3 相同 | 要求普通文件、拒绝符号链接；随机名 `0700` staging 目录，不删除固定 `.文件名.vphonesign` | 本地有意不同（P2 第一批记录），非 2.0.8→2.2.3 变化，保持不变 |
| 其余 8 个源文件 | — | 逐字节相同 | 已等价存在 |
| 上游 5 个测试文件 | — | 逐字节相同 | 已等价存在 |
| `VPhoneSignIntegrationTests.swift` | 无 | 本地新增（P2 第一批） | 本地有意不同 |

迁入后本地 `VPhoneMachOImage.swift` 与上游 2.2.3 的差异为：不含 cd45b8fa 的 LC_UUID 移除块，改为注释说明不采用的原因；其余只差注释文字。有空余空间的文件不进入移除分支，ldid 字节一致性用例（`VPhoneSign is byte-identical to ldid`）仍通过。

### 测试

新增 `tests/VPhoneSignTests/VPhoneSignCommandSpaceTests.swift`，Suite "Load command space and damaged load commands"。输入由测试内独立解析器从 `hello-arm64`（`__text` 偏移 1544，命令区 1464 字节）构造：删除 LC_CODE_SIGNATURE，按需删除 LC_SOURCE_VERSION/LC_UUID，追加 `/vh` 的 LC_LOAD_WEAK_DYLIB，使命令区距第一个 section 恰好剩余指定字节数。

| 用例 | 覆盖 |
| --- | --- |
| the constructed inputs have exactly the room they claim | 构造输入的命令区恰好到达第一个 section |
| with room left, LC_SOURCE_VERSION and LC_UUID are kept | 剩余 16 字节时不移除任何命令 |
| with no room, LC_SOURCE_VERSION is dropped and LC_UUID is kept | iOS 18.6.2 形状：只移除 LC_SOURCE_VERSION；其余命令顺序不变；命令数、命令区大小一致；`__text` 字节不变 |
| with no room and no LC_SOURCE_VERSION, LC_UUID is kept and signing fails | iOS 26.3 形状（cd45b8fa）：输入含 LC_UUID、无 LC_SOURCE_VERSION；抛出 `noRoom`，文件字节不变，目录无残留 |
| with no room and nothing to drop, signing fails and the file is unchanged | 两者都缺失时抛出 `noRoom`；文件字节不变，目录无残留 |
| after a drop the signature verifies and carries the entitlements | ldid 样式带 entitlements：`VPhoneSigner.entitlements` 读回与输入解析后相同，存在 CodeDirectory 与 entitlements blob，再次签名输出不变；Apple ad-hoc 样式：`codesign --verify --strict -vvv` 退出 0，`codesign -d --entitlements - --xml` 读回相同；无 entitlements 的 Apple ad-hoc 输出保留 LC_UUID，在宿主执行退出 0 且有输出 |
| a damaged load command is refused and the file is unchanged（9 例） | cmdsize 为 0、非 8 倍数、越过命令区；ncmds 多于实际；sizeofcmds 越过文件；签名数据越过文件；LC_CODE_SIGNATURE 小于 16 字节；段声明 1000 个 section；字符串表越过签名。均抛出 `malformed`，文件不变；除字符串表一项外 `entitlements(ofFileAt:)` 也抛出 `malformed` |

修改前复现：命令 `swift test ... --filter VPhoneSignCommandSpaceTests`。该次运行时 “after a drop” 用例使用 `sampleEntitlements`，且没有宿主执行段落；两处在签名步骤之后，修改前失败发生在签名步骤。结果：`Test run with 7 tests in 1 suite failed ... with 4 issues`，退出码 1。当时的 3 个移除用例（LC_SOURCE_VERSION 移除、LC_UUID 移除、参数化 2 例的 “after a drop”）报 `no room for the signature load command: content starts at 1544, 1560 bytes of commands`，与 ee8b70ca 提交说明中的报错形式一致。空间充足、无可移除命令和 9 个损坏输入用例在修改前已通过，说明本地原有损坏输入检查与上游一致，本次只补测试。

修改后（首版，含 LC_UUID 移除）：`Test run with 37 tests in 5 suites passed`（VPhoneSign 全部 5 个 Suite，退出码 0）。

回退 LC_UUID 移除后（最终版）：LC_UUID 用例改为断言 `noRoom`，“after a drop” 去掉只为 LC_UUID 服务的参数化分支。`swift test --filter VPhoneSignCommandSpaceTests`：`Test run with 7 tests in 1 suite passed`，退出 0；5 个 Sign Suite：`Test run with 37 tests in 5 suites passed`，退出 0。

### 宿主证据与决定

手动探针（`vphone-cli sign --apple-adhoc --identifier launchd`，构造输入同上，macOS 27.0 / 26A428）：

| 输入 | codesign --verify --strict | 宿主执行 |
| --- | --- | --- |
| 剩余 16 字节，未移除 | 通过 | 输出 `1 p`，退出 0 |
| 移除 LC_SOURCE_VERSION | 通过 | 输出 `1 p`，退出 0 |
| 移除 LC_UUID（首版实现，已回退） | 通过 | `dyld: missing LC_UUID load command`，退出 134 |

- 事实：宿主 dyld 拒绝缺少 LC_UUID 的主程序。
- 待验证假设：iOS 26.3 的 dyld 是否对 launchd 执行同样检查未查明。cd45b8fa 提交说明写 "LC_UUID is not required for loading"，未给出验证记录。若 iOS dyld 同样检查，移除 LC_UUID 后的 launchd 无法加载，失败会在启动阶段出现，而不是签名阶段的 `noRoom`。
- 已决定（用户，2026-10-01）：不采用 cd45b8fa。`VPhoneMachOImage.signed()` 只移除 LC_SOURCE_VERSION；仍放不下时报 `noRoom`，不移除 LC_UUID。代码注释写明不采用的原因。iOS 26.3 launchd 若出现该形状，本地签名会在签名阶段失败。

其他观察：`VPhoneSignParityTests.sampleEntitlements` 用 Apple ad-hoc 样式签在未修改的 `hello-arm64` 上时，`codesign` 报 `binary contains an invalid entitlements blob` 且不满足 designated requirement。该现象与本次改动无关，因此 Apple ad-hoc 验证用例改用只含布尔和字符串数组的 entitlements。带 `platform-application` 的 ad-hoc 程序在宿主执行时被 SIGKILL（状态 9），宿主执行用例使用无 entitlements 的副本。

### T04 未覆盖

- 未使用真实 iOS 18.6.2 或 iOS 26.3 launchd 验证；未执行 `cfw_install*`、VM 启动或 guest 加载。签名成功不等于执行准入或应用启动成功。
- 本地 CFW 流程当前不经过 `VPhoneSign` 重签 launchd：`scripts/cfw_install_jb.sh` 用 `cfw.py inject-dylib` 注入 `/b` 后以 `ldid -S... -M -K...` 重签；`scripts/cfw_install_dev.sh:170`、`scripts/cfw_install_exp.sh:362-364` 也用 ldid。`VPhoneSigner` 的调用方为 `sources/vphone-cli/VPhoneSignCLI.swift`（`vphone-cli sign`）和 `sources/VPhoneDaemon/Daemon/GuestSigner.swift`。因此本次修改不改变本地 CFW 安装结果；本地 `cfw.py inject-dylib` 的空间处理未核对。
- 未更新 `research/0_binary_patch_comparison.md`：本次改动不是固件补丁。

## 执行的命令与结果

测试命令统一加 `--disable-sandbox --cache-path .build/test-cache`，并设置 `CLANG_MODULE_CACHE_PATH`、`SWIFT_MODULECACHE_PATH` 为 `.build/test-module-cache`。

| 命令 | 结果 |
| --- | --- |
| `swift test --filter ArchiveLocaleTests`（修改前） | 6 tests，10 issues，失败，退出 1 |
| `swift test --filter ArchiveLocaleTests`（修改后） | 7 tests passed，退出 0 |
| `swift test --filter ArchiveLocaleTests`（进程级 setlocale 变异） | 7 tests，6 失败，10 issues，退出 1；已恢复 |
| `swift test --filter "VPhoneArchiveKitTests\|VPhoneBundleStoreTests"` | 37 tests / 5 suites passed；CoreBundleStoreTests 12 tests passed；退出 0 |
| `swift test --filter VPhoneSignCommandSpaceTests`（修改前） | 7 tests，4 issues，失败，退出 1 |
| `swift test --filter VPhoneSignCommandSpaceTests`（修改后） | 7 tests passed |
| `swift test --filter "VPhoneSign..."`（5 个 Sign Suite，首版） | 37 tests / 5 suites passed，退出 0 |
| `swift test --filter VPhoneSignCommandSpaceTests`（回退 LC_UUID 后） | 7 tests passed，退出 0 |
| `swift test --filter "VPhoneSign..."`（5 个 Sign Suite，回退 LC_UUID 后） | 37 tests / 5 suites passed，退出 0 |
| `make test_swift`（修改后，全量） | 退出 0。Swift Testing 10 次运行共 752 tests 全部通过（37/75/11/9/324/66/12/37/28/153）；XCTest：VPhoneCoreTests 79、VPhoneCLITests 71、VPhoneAPIKitTests 23、FirmwarePatcherTests 5（3 skipped），0 failures；`check_tar_pipe_memory.py` file/producer 两条 1 GiB 路径峰值 RSS 7,864,320 / 8,044,544 字节；`test_guest_components` 输出 `RootHide loader link tests passed` |

全量通过，未建立 HEAD 基线 worktree 对照。

全量运行后，为消除一条 unused-result 编译警告，IPA 用例增加一项断言（`extract` 返回 3）。之后 `swift test --filter VPhoneArchiveKitTests`：37 tests / 5 suites passed，退出 0，该文件无警告。全量未在此之后重跑；回退 LC_UUID 后也未重跑全量（主工作区另有代理在跑全量，按协调要求只跑 Sign 专项）。

## 改动文件

- `sources/VPhoneArchiveKit/Archive/VPhoneArchiveLocale.swift`（新增）
- `sources/VPhoneArchiveKit/Archive/VPhoneArchiveReader.swift`
- `sources/VPhoneArchiveKit/Archive/VPhoneArchiveExtractor.swift`
- `sources/VPhoneArchiveKit/Archive/VPhoneArchiveWriter.swift`
- `sources/VPhoneSign/MachO/VPhoneMachOImage.swift`
- `tests/VPhoneArchiveKitTests/ArchiveLocaleTests.swift`（新增）
- `tests/VPhoneSignTests/VPhoneSignCommandSpaceTests.swift`（新增）
- `research/t04_t05_sign_archive_2026-10-01.md`（本记录）
