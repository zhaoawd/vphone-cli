# T14：GPU、下载与共享缓存

日期：2026-10-01。分支基线 `18ae989`。上游参考 tag `upstream-2.0.8`、`upstream-2.2.3`。

本批分两部分。A 部分实现下载、共享缓存、稀疏扫描和容量显示。B 部分只对照并设计 GPU driver、compiler plugin 和 v2 布局，没有写产品代码。

各节分开陈述事实、推断和未验证项。标识符、命令、字段名和日志保留原文。行号基于本次提交后的工作树；上游位置写作 `upstream-2.2.3:<路径>:<行>`。

## 1. 上游来源

| 提交 | 内容 |
| --- | --- |
| `835c4db` | 远程 IPSW 改存共享目录 `~/.vphone/ipsws`（跟随 `VPHONE_ROOT`），新增 `--ipsw-cache`；按 cloudOS build 缓存 GPU driver；同一 URL 并发发布时复用先发布者；下载前放宽缓存目录权限；删除 1 小时未修改的 `.partial`；导出排除 `.ipsw-cache`、`.firmware-prepare-*`、`.pcc-restoration-*`、`.pcc-system-*` |
| `cb924c9` | 下载改为 `URLSessionDataDelegate` 按块写入缓存卷上的 `.partial`；非 200 在写入正文前返回 |
| `9a1018b` | `VPhoneAPFSSnapshot.rename` 按 64 MiB 窗口扫描 `Disk.img`，先 `SEEK_DATA` 跳过空洞；`ENXIO` 视为其后全为空洞，其他错误回退为扫描该窗口 |
| `6a8d2c7` | 创建磁盘改为 N × 10^9 字节；`vm list` 与 Launchpad 除以 10^9 |
| `3e80d03` | Launchpad 预览数据改为十进制字节数 |

检索命令：`git log upstream-2.0.8..upstream-2.2.3 --oneline | grep -iE "GB|size|sparse|download|cache|GPU|metal|compiler"`，得到上述 5 个提交及 5 个无关提交（libmisfix、shared cache 编辑、按钮尺寸、格式化）。

## 2. A 部分对照表

| 上游行为 | 本地位置 | 结论 |
| --- | --- | --- |
| 远程 IPSW 存入共享 `userDataRoot()/ipsws` | script 后端：`IPSW_DIR` 由 CLI 设为 `resources.ipswCacheDir`（`sources/VPhoneCore/VPhoneResources.swift:131`，`sources/vphone-cli/VPhoneCreateOrchestrator.swift:662`），各 VM 共用。Swift `VPhoneIPSWCache.resolve` 由调用方给目录，产品代码中没有调用方（原生 prepare 只接受本地文件，`sources/vphone-cli/VPhoneNativeFirmwarePreparer.swift:38-40`） | 已等价（script 后端）；位置未改 |
| `--ipsw-cache <dir>` | 无对应选项 | 缺失，未迁入（任务要求不改共享缓存位置） |
| 缓存条目复用条件：文件名来自 URL，BuildManifest 可读即复用 | 本次改为内容身份：完成标记记录来源、大小、SHA-256 和发布后文件的 inode/mtime（`sources/VPhoneCore/VPhoneIPSWCache.swift:201-221`，`scripts/ipsw_cache_entry.py:108-132`） | 本地有意不同（更严格） |
| 同一 URL 两个 prepare 同时完成，后者复用先发布者 | Swift：发布在缓存目录锁内，先检查可用条目（`VPhoneIPSWCache.swift:142-153`）；脚本：`publish` 同样处理（`ipsw_cache_entry.py:276-304`） | 已等价 |
| 下载前对缓存目录调用 `makeDirectoryAccessible`（放宽权限） | 新建缓存目录 `0700`，下载文件 `0600`，不改已有目录权限（`VPhoneIPSWCache.swift:113`、`:130`） | 本地有意不同（P2 已移除权限放宽） |
| 删除 1 小时未修改的 `.partial` | 按写入进程 pid 判断：pid 不存在才删除（`VPhoneIPSWCache.swift:271-283`；`scripts/fw_prepare.sh:437-450`） | 本地有意不同；不删除仍在写入的下载 |
| 按块写入 `.partial`，不经系统临时目录 | `DownloadState`/`Attempt` 按 URLSession 交付的块写入缓存目录内的 partial，并同步计算 SHA-256（`VPhoneIPSWCache.swift:303-524`） | 已等价 |
| 断点续传 | 上游没有。本地：同一次 resolve 内，传输中断后以 `Range` + `If-Range`（强 ETag 或 Last-Modified）续传；实体变化或服务器不支持范围时从 0 重来（`VPhoneIPSWCache.swift:317-322`、`:416-440`）。脚本：`curl_download` 每次以 `-C -` 续传本次 partial（`fw_prepare.sh:328-349`） | 本地扩展 |
| 按块校验 | 上游没有。本地记录整体 SHA-256，不做按块校验 | 未实现（上游无） |
| 可重试结果 | 上游没有重试。本地：网络错误、5xx/408/429、正文不足按 `DownloadPolicy` 重试；用尽后抛 `downloadFailed(…, retryable: true)` 或 `incompleteDownload`；4xx 立即抛 `unexpectedHTTP`；`Error.isRetryable` 区分（`VPhoneIPSWCache.swift:68-77`、`:324-355`） | 本地扩展 |
| 请求超时 3 小时（`timeoutInterval`） | 默认 60 秒空闲超时，由重试和续传承接中断（`VPhoneIPSWCache.swift:88`） | 本地有意不同 |
| 取消 | 取消任务即取消 URLSession 任务并删除 partial（`VPhoneIPSWCache.swift:406-413`、`:133-136`） | 已等价，测试覆盖 |
| 导出排除 `.ipsw-cache`、`.firmware-prepare-*`、`.pcc-*`；进度统计按排除规则剪枝 | `exportExcludePatterns` 不含这些模式（`sources/VPhoneCore/VPhoneBundleOps.swift:297`）；进度统计对排除项 `continue`，不剪枝子树（`:382`）。本地不在 VM 内缓存 IPSW，也没有 `.pcc-*`；原生 prepare 被强制终止时会留下 `.firmware-prepare-<uuid>`（`VPhoneNativeFirmwarePreparer.swift:60`），会被导出 | 缺失，未改（属导出范围，待决） |
| GPU driver 按 build 缓存 `~/.vphone/gpu-drivers` | 本地没有 PCC GPU 恢复路径 | 缺失，见 B 部分 |
| 稀疏扫描（`9a1018b`） | 本地等价物是 `tools/apfs_snap_rename.py`（`scripts/cfw_install_host.sh:341` 调用）。原实现 mmap 整个文件后 `find`。本次改为 64 MiB 窗口、仅读有数据的窗口（`tools/apfs_snap_rename.py:79-120`） | 已等价；空洞判断本地有意不同（见 §5） |
| 归档稀疏读取 | `VPhoneArchiveWriter` 用 libarchive 读盘并带稀疏表（`sources/VPhoneArchiveKit/Archive/VPhoneArchiveWriter.swift:107-127`） | 本次补测试：decmpfs 文件三种格式往返内容正确，未改代码 |
| 磁盘创建 N × 10^9，显示除以 10^9 | 创建仍为 N × 2^30（`VPhoneBundleOps.swift:102`）；CLI 与 Launchpad 统一除以 2^30（`VPhoneBundleOps.swift:10-28`，`sources/vphone-cli/VPhoneVMCLI.swift:64`，`sources/VPhoneLaunchpad/VPhoneLaunchpadMachinesView.swift:505-509`，`sources/VPhoneLaunchpad/VPhoneLaunchpadNewMachineView.swift:343-346`） | 本地有意不同，见 §6 |

## 3. 缓存身份规则（Swift 与 fw_prepare.sh 共用）

规则写在 `scripts/ipsw_cache_entry.py` 顶部说明中。`VPhoneIPSWCache` 实现同一格式。B4 的 partial 命名与完成标记保留，没有新建第二套规则：

1. 写入目标为 `.<名称>.partial.[<标签>.]<pid>`，最后一段是写入进程 pid（aria2c 控制文件另带 `.aria2`）。pid 不存在的 partial 在下一次运行时删除。Swift 用 `.<名称>.partial.<8 位随机>.<pid>`，以区分同一进程内的并发下载。
2. 文件条目 `X` 的完成标记是同目录 `.X.vphone-complete`；目录条目 `X`（解包缓存）的完成标记仍是 `X/.vphone-extract-complete`。标记最后写入。
3. 标记为 JSON，`format` 为 `vphone-ipsw-cache/1`。文件标记：`source`（远程为 `{"url": …}`；本地为 realpath、device、inode、size、mtime_ns）、`size`、`sha256`、`file.inode`、`file.mtime_ns`。目录标记：`parent.size`、`parent.sha256`，即来源 IPSW 条目标记中的值。
4. 条目可用的条件：标记存在且格式正确；`source` 与本次来源相同；文件当前的大小、inode、mtime 与标记一致。目录条目还要求来源 IPSW 条目可用且摘要一致。
5. 发布、丢弃和写标记都持有缓存目录本身的 `flock`，即 `VPhoneLibraryLock` 使用的锁。读者不会在标记写入前看到可用条目。目录丢弃在锁内改名为 partial，在锁外删除。
6. 不可用的条目在下载或复制前删除，避免同一卷同时容纳旧条目和新下载。

复用时不重新计算 SHA-256。依据是 inode、mtime、大小未变；这不能发现不改 mtime 的原地篡改。SHA-256 在写入时计算并记录，用于目录条目关联来源和事后核对。

fw_prepare.sh 改动（`scripts/fw_prepare.sh`）：

- `fetch`（`:394-420`）：先删 pid 已结束的 partial；条目可用则输出 `Cached:`；否则 `discard` 后写入本次 partial。本地来源先 `identify` 记录来源身份，`cp` 后 `publish --expect-source` 核对来源未变。远程来源由 `download_file` 写入 partial。两者都要求 ZIP 中有非空 `BuildManifest.plist`（`--require-member`）。
- 原实现直接写最终名称，并在已有文件时 `curl -C -` 续传；curl 退出码 33 视为“已完整”。新实现不再把 33 当作成功。
- `curl_download`（`:328-349`）：最多 `CURL_ATTEMPTS`（默认 5）次。退出码 6/7/18/28/35/52/55/56/92 与 HTTP 5xx/408/429 重试，下一次以 `-C -` 从 partial 长度续传。HTTP 416 或 curl 33 删除 partial 后从 0 开始。其他 4xx 不重试。curl 自带的 `--retry` 在本机实测从 0 重来，不续传，因此未使用。aria2c/wget 分支未改。
- `extract`（`:459-485`）：`check-dir`、`discard-dir`、`publish-dir` 替代原来的“标记文件存在即复用”。

`scripts/check_bundle.py` 的必需资源加入 `scripts/ipsw_cache_entry.py`（`build.sh` 以 rsync 复制整个 `scripts/`，已包含该文件）。

## 4. 下载实现（`VPhoneIPSWCache`）

- `resolve(_:in:session:policy:)` 新增 `policy: DownloadPolicy`（默认 5 次、间隔 2 秒 × 次数、60 秒空闲超时）。调用方签名兼容。
- 每次尝试一个 `URLSessionDataTask`，任务级 delegate 处理响应和数据。200 时若已有数据则截断重来，并记录长度与验证器；206 要求 `Content-Range` 起点等于已写长度、总长不变；416 或范围不符时下次从 0 开始。
- 只有已知总长且有验证器时才续传。弱 ETag 不用。无 Content-Length 时，中断后从 0 开始。
- 正文写入失败（如空间不足）不重试，直接抛出。
- 结束后 `inspect` partial 的 BuildManifest，再在锁内发布：已有可用条目则丢弃本次结果；否则删除旧条目，`renamex_np(RENAME_EXCL)` 发布，写标记。

## 5. 稀疏扫描

事实：

- 本机（macOS 27）对 decmpfs 文件（`UF_COMPRESSED`，数据在 `com.apple.decmpfs` xattr）执行 `lseek(SEEK_DATA)` 与 `lseek(SEEK_HOLE)` 均返回 `ENXIO`，`st_blocks` 为 0。夹具由 xattr + `chflags(UF_COMPRESSED)` 生成，`ditto --hfsCompression` 在本机未压缩该文件。
- 上游 `9a1018b` 的规则遇 `ENXIO` 即结束扫描。对照脚本以该规则扫描 decmpfs 映像，结果为空；新规则找到位于 20480 的记录（`snap-controls.log`）。
- T15 记录 HFS+ 上 `SEEK_DATA` 返回 `ENOTTY`（`research/t15_cfw_write_protection_2026-10-01.md:149`）。

`tools/apfs_snap_rename.py` 新规则：

- `holes_reliable`（`:48-58`）：文件带 `UF_COMPRESSED`，或 `lseek(0, SEEK_HOLE)` 报任何错误时，不使用空洞信息，逐窗口读取。
- 可靠时：`SEEK_DATA` 返回 `ENXIO` 表示其后无数据；其他错误读取当前窗口（`:61-69`）。
- 名称跨窗口边界时补读后续字节，与原整文件扫描结果一致（`:104-108`）。写入改为 `pwrite` 块并 `fsync`。CLI 参数与输出文本不变。

对照（同一 16 GiB 稀疏映像，记录在 12 GiB 处，`--dry-run`）：原工具 5.25 秒，新工具 0.12 秒，结果相同。

归档：`VPhoneArchiveWriter` 对 decmpfs 文件在 gnutar、pax、ustar 三种格式下读回与解包内容均正确（新测试），未改代码。原因未查明（libarchive 对该文件的稀疏表处理未逐行核对）。

范围外发现：`scripts/cfw_disk_txn.py:100-117` 的 `data_ranges` 遇 `ENXIO` 即返回，未检查 `UF_COMPRESSED`。若 `Disk.img` 为 decmpfs 文件，其完整复制回退与抽样摘要会把内容当作零。该文件属 T15/T16 范围，本次按边界要求未修改。`Disk.img` 被 decmpfs 压缩的条件未验证。

## 6. 容量显示口径

事实：

- 本地创建 `Disk.img` 为 N × 2^30 字节；`--disk-size` 与 Launchpad 步进器都标为 GB。
- 改动前：`vm list` 除以 2^30，Launchpad 列表、检查器和剩余空间除以 10^9（T26 B1/B4 引入）。同一个 64 的磁盘，CLI 显示 64 GB，Launchpad 显示 68 GB。

处理：新增 `VPhoneDiskSize`（`VPhoneBundleOps.swift:10-28`），创建与所有显示共用 2^30。创建字节数不变。显示单位文字仍为 “GB”，含义为创建时的单位。iOS 内显示的十进制值不同（64 显示约 68.7 GB）。

上游的磁盘（N × 10^9 字节）导入本地后显示为 59（`BundleOpsTests` 断言）。是否采用上游十进制创建需要用户决定：采用后新磁盘字节数改变，旧磁盘显示变为 68。

## 7. 旧缓存与空间影响

`~/.vphone/ipsws` 只读列出（未读取内容，未修改）：

| 名称 | 字节 |
| --- | --- |
| `399b664dd623358c3de118ffc114e42dcd51c9309e751d43-727c4f5e2432.ipsw` | 935,422,803 |
| `c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ad-b80d96a0b616.ipsw` | 1,199,454,323 |
| `iPhone17,3_26.1_23B85_Restore.ipsw` | 10,778,507,403 |
| `iPhone17,3_26.6.1_23G82_Restore.ipsw` | 11,254,333,223 |

四个条目共 24,167,717,752 字节，均无完成标记。按规则：

- 下一次 script prepare 用到某条目时，删除该条目并重新下载或复制。默认 26.1 组合涉及前表第 1、3 项，共 11,713,930,206 字节需重新下载。旧文件在下载前删除，峰值占用不超过原占用；下载期间该条目不可用。
- 未被使用的条目不被扫描或删除。
- 解包缓存（B4 的空标记）会被丢弃后重新解包；不需要网络。
- 中断的下载不再跨运行续传：partial 在下一次运行时删除，下载从 0 开始。同一次运行内仍续传。

推断：其他工作树或旧版本脚本仍可能按名称复用或续写同名文件。它们改写文件后 inode/mtime 与标记不符，本版本会视为不可用。

## 8. 测试与结果

新增或改写的测试：

| 文件 | 内容 |
| --- | --- |
| `tests/VPhoneCoreTests/LocalIPSWServer.swift`（新） | 127.0.0.1 HTTP/1.1 替身：Range、If-Range（强 ETag）、断开、状态码、慢速正文、断开后替换实体 |
| `tests/VPhoneCoreTests/IPSWCacheTests.swift`（改写，17 项） | 按块下载与标记字段；无标记、他源、发布后被改、T14 前空标记 4 种情况重新下载；与 Python 辅助脚本互认标记；断开后 Range+If-Range 续传；实体变化与无范围支持从 0 重来；5xx 重试后可重试错误；404 不重试；连接拒绝与短正文；非 IPSW 内容不发布；取消删除 partial；同进程并发发布一个条目；pid 已结束的 partial 删除、存活的保留；原有本地来源、符号链接、配对测试 |
| `tests/VPhoneArchiveKitTests/ArchiveSafetyTests.swift`（+1 项，3 例） | decmpfs 文件在 gnutar/pax/ustar 下内容正确；断言夹具确实触发 `SEEK_DATA` `ENXIO` |
| `tests/VPhoneCoreTests/BundleOpsTests.swift`（+2 断言） | 64 的磁盘显示 64；10^9 字节磁盘显示 59 |
| `tests/test_fw_prepare_partials.py`（5 → 16 项） | 原 5 项按新规则调整；新增：T14 前空标记、他源同名解包、他源同名 IPSW、来源或缓存文件改变、非 IPSW 复制、无标记旧 IPSW；本地 HTTP 替身：断开后续传、404 不重试、无范围支持 5 次后失败、下载中 SIGINT 不留最终名称 |
| `tests/test_apfs_snap_rename.py`（新，5 项） | 128 GB 稀疏映像只读 ≤ 2 个窗口并完成改名；ENOTTY 回退读全部窗口；decmpfs 映像被读取并改名；跨窗口名称；CLI 输出不变 |

命令与结果（swift 命令环境同 `scripts/run_tests.py`：`--disable-sandbox --cache-path .build/test-cache`，module cache 在 `.build/test-module-cache`，清除 `VPHONE_TEST_*`）。日志在 `research/artifacts/t14-2026-10-01/`（Git 忽略）：

| 命令 | 结果 |
| --- | --- |
| 改动前 `swift test --filter "IPSWCacheTests\|ArchiveSafetyTests"` | 退出 0；9 项 / 1 suite，9 项 / 1 suite |
| 改动后 `swift test --filter IPSWCacheTests` | 退出 0；17 项 / 1 suite |
| 对照：临时关闭续传与来源比较后同一命令 | 退出 1；`other-source`、续传、重来 3 项共 5 处失败；源码随后恢复（`cmp` 一致） |
| `swift test --filter "IPSWCacheTests\|ArchiveSafetyTests\|BundleOpsTests\|NativeFirmwarePrepareTests\|FWInspect\|NativeTransferTests"` | 退出 0；49 项 / 3 suites，13 项 / 1 suite，10 项 / 1 suite |
| `.venv/bin/python3 -B -m unittest tests.test_apfs_snap_rename -v` | 5 项通过 |
| `FW_PREPARE_SCRIPT=<改动前脚本> … tests.test_fw_prepare_partials` | 16 项，13 失败 |
| `.venv/bin/python3 -B -m unittest tests.test_fw_prepare_partials -v` | 16 项通过 |
| `bash -n scripts/fw_prepare.sh`；`scripts/check_scripts.py` 3 个文件 | 通过 |
| `swift build --product vphone-cli`、`--product vphone-launchpad` | 退出 0 |
| `make test_python` | `Ran 498 tests`，`OK (skipped=1)`；跳过项为 `test_daemon_api_icli`（IcliKit checkout 缺失）。B4 记录为 482，本次新增 16 |
| `make test_swift` 第 1 次 | 退出 2。`ExtractPermissionsTests` 的 “host extraction matches plain system tar” 失败：`The file “vphone-arc-src-…” doesn’t exist`，该路径是 `NoOverwriteDirTests` 的暂存目录。其余通过 |
| `swift test --filter VPhoneArchiveKitTests` 重复 6 次 | 6 次均退出 0，38 项 / 5 suites |
| `make test_swift` 第 2 次 | 退出 0。Swift Testing 11 次运行：37/5、75/7、152/34、14/2、9/2、354/40、100/22、18/1、38/5、28/4、176/31（测试/suite），共 1001 项、153 suites，全部通过；XCTest 4 个包 93、95、24、5 项，3 项跳过，0 失败；`check_tar_pipe_memory` 两条 1 GiB 路径峰值 RSS 10,027,008 / 10,289,152 字节；`test_guest_components` `124 checks, 0 failures` |

第 1 次失败的待验证假设：`VPhoneArchiveWriter` 的 libarchive 树遍历会 `chdir` 进被读目录（`VPhoneArchiveWriter.swift:114-119` 的注释），工作目录是进程级状态。`NoOverwriteDirTests` 删除其暂存目录时，并行的 `ExtractPermissionsTests` 用 `Process` 启动 `/usr/bin/tar`，继承了已删除的工作目录。失败测试与本次改动的文件无关；本次新增的 decmpfs 测试也调用该写入器，可能增加这一竞态的出现机会。未修复。

worktree 环境：`.venv` 链接主仓库；初始化 `vendor/*` 子模块；生成被忽略的 `VPhoneBuildInfo.swift`。首次 `swift test` 从 GitHub 下载二进制依赖，其中 5 个返回 504，构建失败；随后从主仓库 `.build/artifacts` 复制已有产物并登记到本 worktree 的 `workspace-state.json`，此后构建未再访问网络。测试本身只连接 127.0.0.1。

## 9. 事实、推断与未验证（A 部分）

事实：

- Swift 下载和脚本下载在测试中都只连接本地替身服务器；续传请求带 `Range`，Swift 另带 `If-Range`。
- 改动前脚本把中断的下载留在最终名称下，并按名称复用；替身测试中改动前脚本 16 项失败 13 项。
- 无完成标记、标记来源不同、文件在标记后被改动的条目都不会被复用。

推断：

- curl 的 `-C -` 续传不带 `If-Range`。远程实体在同一次运行的两次尝试之间变化时，partial 可能拼接两个实体；发布前只检查 ZIP 中央目录与 `BuildManifest.plist`，不一定能发现。Apple CDN 上同一 URL 的内容变化未观察到。

未验证：

- 真实 Apple CDN（大文件、重定向、HTTP/2、代理）上的 Swift 下载与续传；脚本的 aria2c 与 wget 分支。
- 真实 `fw_prepare.sh` 全流程（真实 IPSW 下载、解包、合并）及其后 restore/boot。
- decmpfs 压缩的真实 `Disk.img` 上的快照改名；HFS+ 卷上的真实运行（只用 mock 覆盖 `ENOTTY`）。
- Launchpad 界面显示（只编译，未运行 UI）。

## 10. B 部分：GPU driver、compiler plugin 与 v2 布局（设计，未实现）

本节事实来自上游 tag 源码，部分由只读子代理整理；以下几处已逐行复核：`VPhonePCCGPUDriver.swift` 全文、`VPhoneFirmwarePreparer.swift:95-145`、`VPhoneGuestComponents/Makefile:45-52`、`:158-166`、`VPhoneCustomFirmwareInstaller.swift:823-853`、`VPhoneVirtualMachineManifest.swift:68-76`。其余行号未逐一复核。

### 10.1 上游 GPU driver

- 来源：`AppleParavirtGPUMetalIOGPUFamily.bundle` 不随 app 分发（`upstream-2.2.3:VPhoneKit/VPhoneCoreKit/Firmware/VPhonePCCGPUDriver.swift:3-6`）。`fw prepare` 按以下顺序取得：
  1. `--gpu-driver-bundle <path>`：直接校验并暂存。
  2. 缓存 `userDataRoot()/gpu-drivers/<cloudOS version>_<build>/`：`try?` 校验，失败则落到第 3 步（`VPhoneFirmwarePreparer.swift:103-116`）。
  3. `VPhonePCCGPURecovery.stage`：在 `<staging>/.pcc-restoration-<UUID>` 建临时 VM（8 CPU、8192 MB、64 GB 磁盘），把解包的 cloudOS 树移入为 `iPhonePCC_Restore`，DFU 启动后用原生 restore（`ticketPath: nil`，联网取 TSS）恢复 cloudOS；以 `hdiutil attach -readonly -nomount` 与 `mount_apfs -o rdonly` 挂载 System 卷到 `.pcc-system-<UUID>`，复制 `System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle`；随后卸载、分离、删除临时库。卸载或分离失败时保留目录并告警。成功后写入第 2 步的缓存，写缓存失败只告警。
- 放置：暂存到 `<restore tree>/.pcc-gpu/AppleParavirtGPUMetalIOGPUFamily.bundle`（`VPhonePCCGPUDriver.swift:22-24`）。CFW 安装时 `installGPUBundle` 删除 System 卷原 bundle，复制该目录，设置权限，并要求 plugin 存在（`VPhoneCustomFirmwareInstaller.swift:823-853`）。该步骤由补丁 `system-extensions-boot-gpu_bundle` 控制。
- 校验：目录内须有 `AppleParavirtGPUMetalIOGPUFamily`、`Info.plist`、`_CodeSignature/CodeResources`；`CFBundleIdentifier` 为 `com.apple.driver.AppleParavirtGPUMetalIOGPUFamily`；`DTPlatformVersion` 等于 cloudOS BuildManifest 的 `ProductVersion`（`VPhonePCCGPUDriver.swift:45-74`）。
- 版本对应：临时恢复与缓存键按 cloudOS build 区分。显式 bundle 只比较版本号，不比较 build、`CFBundleVersion` 或摘要；同版本不同 build 的 driver 会被接受。driver 不与 iPhone IPSW 校验。
- 缓存写入：复制到 `.<UUID>.partial` 后改名；已有损坏目录先删除；并发时保留先发布者（`VPhoneFirmwarePreparer.swift:161-185`）。缓存内容是插入 plugin 前的 bundle。

### 10.2 上游 compiler plugin

- 源码：`VPhoneGuestComponents/GraphicLoader/main.mm`，重新实现 `libAppleParavirtCompilerPluginIOGPUFamily.dylib`。上游 README 记录：cloudOS 26.4 `23E5207q` 的 bundle 缺少该 plugin，缺少时 `MTLCompilerService` 反复中止，VM 窗口为黑屏。
- 构建：`xcrun --sdk iphoneos clang++ -arch arm64e -miphoneos-version-min=26.1 -std=c++17 -O2 -dynamiclib`，`-Wl,-not_for_dyld_shared_cache`，install name 为 bundle 内路径，LLVM/MTLGPUCompiler 符号以 `-Wl,-U` 留待运行时解析，`codesign --force --sign -`（`VPhoneGuestComponents/Makefile:49`、`:158-166`）。
- 分发：`StageBundle.sh` 复制到 `VPhone.bundle/Contents/Resources/guest-resources/`；`ValidateBundle.sh` 检查存在、签名与 iOS 平台。`fw prepare` 把它复制进 `.pcc-gpu/<bundle>/` 并设为 0755，不改 Apple bundle 的 `_CodeSignature`（`VPhoneFirmwarePreparer.swift:132-141`）。
- 推断：guest 接受 bundle 内未封装的 ad-hoc dylib，可能依赖补丁后的内核/AMFI 状态。源码与文档没有说明。

### 10.3 v2 布局差异

| 项目 | 上游 2.2.3 | 本地 |
| --- | --- | --- |
| VM 清单 | `schemaVersion = 2`，其他值拒绝加载（`VPhoneVirtualMachineManifest.swift:71`） | 无 `schemaVersion` 字段 |
| 默认库目录 | `userDataRoot()/machines` | `~/.vphone/VMs` |
| Restore 树 | `iPhone17,3_<ver>_<build>_Restore`，含 `iPhone-BuildManifest.plist` 与 `.pcc-gpu/` | classic 布局，无 `.pcc-gpu` |
| GPU 来源 | `.pcc-gpu`（PCC 恢复或显式 bundle）+ app 内 plugin | `cfw_input.tar.zst` 中预制 `custom/AppleParavirtGPUMetalIOGPUFamily.tar`（`scripts/cfw_install.sh:315-335`；`sources/FirmwarePatcher/Filesystem/CryptexFilesystemPatcher.swift:283-310`） |
| plugin | `guest-resources/` 内，`VPhoneResources.gpuCompilerPlugin` | 候选构建在 `.build/guest-components-v2/stage/gpu/`，未打包、未安装（`sources/VPhoneGuestComponents/README.md`）；`VPhoneResources` 无对应访问器 |
| IPSW 缓存 | 共享 `userDataRoot()/ipsws` | 同（script 后端） |
| Metal 验证 | 无专门测试；验收为锁屏与 vphoned ping | 无；`scripts/f1_runtime_acceptance.py` 中 Metal compute probe 标为未实现 |

相关上游提交（2.0.8..2.2.3）：`835c4db`（GPU 缓存）、`107cbd0`（macOS 27 磁盘选择）、`090df08`（错误文本）、`30c8512`/`ae5e453`（补丁声明与 ID）、`2debf87`（`cfw update-environment` 不做 GPU 工作）。机制本身在 2.0.8 之前已引入（`9fc1b46`、`8758b41`、`bc79586`、`b06496e`、`f9e7abb`、`961f18c`）。

### 10.4 本地引入时的改动位置（设计）

1. 资源：`scripts/build.sh` 把 plugin 候选复制到 `Contents/Resources/guest-resources/`；`VPhoneResources` 增加 `gpuCompilerPlugin`；`scripts/check_bundle.py` 增加存在、签名、`vtool` 平台检查。
2. 准备：在 `VPhoneNativeFirmwarePreparer` 清单生成之后增加 GPU 步骤。先只支持显式 `--gpu-driver-bundle`。临时 PCC 恢复复用本地原生 restore 与 DFU owner、VM 锁、检查点。暂存目录名需与本地 `.firmware-prepare-*` 清理和导出排除一起定义。
3. driver 缓存：沿用 §3 的规则，作为目录条目：标记记录 cloudOS version、build、cloudOS IPSW 的 SHA-256 和 bundle 内各文件 SHA-256。位置需用户决定（不隐式新建共享路径）。
4. CFW：v2 路径从 `<restore>/.pcc-gpu` 安装；classic 路径保留 `cfw_input` tar。补丁 `system-extensions-boot-gpu_bundle` 的本地映射已存在（`sources/FirmwarePatcher/PatchSet/PatchDeclarationCatalogData.swift:871-883`），需要确认两种来源的选择条件。
5. 检查点与导出：prepare evidence 记录 driver 来源、cloudOS build、driver 与 plugin 摘要；导出排除 `.pcc-*` 暂存目录。

### 10.5 测试与 Metal 实测方案（设计）

无固件测试：

- driver 校验：缺文件、错误标识符、版本不符、build 不符（若采用更严格规则）、符号链接与硬链接来源。
- plugin 合并：权限 0755、覆盖已有文件、缺失时报错。
- 缓存：与 §3 相同的标记、并发发布、损坏条目重新获取。
- 临时恢复：以替身替换 DFU 启动、restore、`hdiutil`、`mount_apfs`，注入每一步失败，断言卸载、分离、目录保留或删除的条件与上游一致，且不留可复用的缓存条目。

真实实测（需要用户批准写盘、联网 TSS 与 VM 运行）：

1. 记录 cloudOS 与 iPhone IPSW 的 build 与 SHA-256、driver bundle 各文件 SHA-256、plugin SHA-256 与 cdhash。
2. 显式 bundle 与临时 PCC 恢复两条路径各创建一个 v2 VM；记录空间峰值、取消与中断后的挂载和目录残留。
3. 启动后检查：主机帧非全黑；guest 中无 `MTLCompilerService` 崩溃日志；`backboardd` 日志无 `XPC_ERROR_CONNECTION_INTERRUPTED`。
4. guest 内 Metal compute 探针：`MTLCreateSystemDefaultDevice`、运行时编译一个 compute kernel（经过 compiler plugin）、执行并比对结果。该探针在本地与上游均不存在，需新增。
5. 重启后重复第 3、4 步。

### 10.6 需要用户决定的问题

1. 是否引入临时 PCC 恢复路径。它需要联网 TSS、一次额外的 DFU 恢复和约 64 GB 逻辑大小的临时磁盘；或只支持显式 `--gpu-driver-bundle`。
2. GPU driver 缓存位置。上游为 `userDataRoot()/gpu-drivers`，本地尚无该共享路径。
3. driver 与固件的绑定强度。上游只比较 `DTPlatformVersion`；是否要求 build 一致并记录摘要。
4. plugin 适用的变体（regular/dev/jb/exp/less），以及未封装 dylib 在各变体上的加载条件。
5. 是否采用 v2 清单（`schemaVersion = 2`）与 `machines` 库目录，或保持 classic 并只引入 GPU 来源。

A 部分遗留的决定：

6. 是否恢复跨运行续传。需要把 partial 与来源绑定（例如按来源摘要命名并加锁），属于第二种 partial 规则。
7. 旧缓存是否提供显式“认领”入口：用研究记录中的 SHA-256（例如 `upstream_remaining_progress_2026-09-29.md:69-70`）核对后写入标记，避免重新下载约 11.7 GB。
8. PCC URL 路径中的 64 位十六进制是否作为 Apple 提供的摘要强制核对。依据只有一个样本（`399b664d…`），未确认 URL 规则。
9. 是否采用上游十进制磁盘创建（§6）。
10. 导出是否排除 `.firmware-prepare-*` 与 `.firmware-prepare-backup-*`（§2）。

## 11. 未覆盖范围

- 没有真实下载、真实 IPSW、真实 restore、VM 启动或 Metal 验证。
- less 变体的 `apfs_sealvolume` 缓存（`download_apfs_sealvolume`）仍按文件名复用，未纳入本规则。
- `cfw_disk_txn.py` 的 decmpfs 问题未修改（§5）。
- `ExtractPermissionsTests` 的并行竞态未修复（§8）。
- 未修改执行清单与实施计划。
