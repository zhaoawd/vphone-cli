# P2 第二批：原生归档库与 CLI

提交记录（2026-09-28）：按用户要求，将本记录对应的代码、测试及相关文档纳入本次整合提交。下文的“未提交”描述保留各阶段记录时的状态；验收范围和未验证项目不变。

日期：2026-09-28。上游固定为 `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3`。本批接入 `VPhoneArchiveKit` 的 Archive 目录及显式 `archive` CLI。代码尚未提交。

## 范围和来源

迁入 7 个归档库文件、3 个上游测试文件和 1 个 CLI 文件。逐文件上游 blob、本地 SHA-256 与适配状态见 [来源清单](p2_archive_sources_2026-09-28.json)。本地新增输出发布辅助类、归档安全测试及 CLI 测试。

| 对象 | 本地状态 |
| --- | --- |
| ArchiveReader / Extractor / Writer | 支持读取条目、读取单个成员、解包、打包和单层解压缩 |
| TreeFingerprint | 支持生成目录元数据与内容摘要，比较目录差异 |
| CLI | `archive extract/create/decompress/list/cat/fingerprint`，默认子命令为 extract |
| SwiftPM | 独立 VPhoneArchiveKit target 和测试 target，CLI 增加依赖 |
| VM 导入导出、IPSW cache、CFW 安装 | 保留现有入口；上游 Transfer 目录未迁入 |

`create` 支持 GNU tar、pax、ustar，CLI 支持 zstd/xz；库另支持 gzip。解包自动识别格式和压缩算法。`cat` 通过库读取整个成员后输出，当前不提供流式 stdout API。

## 依赖与分发

ArchiveKit 的包地址为 `https://github.com/Lakr233/libarchive.xcframework.git`，采用上游 1.0.0 对应的精确 revision `82687c75e530917b7fbeb15cd5f9369524637155`。Package.resolved 中原有依赖 revision 保持不变。

二进制来自固定包清单声明的 `upstream.27cbc7827172.2/libarchive.xcframework.zip`，SHA-256 为 `573fa72ca53f0e623e1f26e3993a22a075b5dba91733ea8aaaa370b52d93537c`；SwiftPM 下载并校验。libarchive、liblzma、libzstd、liblz4 静态链接；zlib、bzip2、iconv、libxml2 使用 Apple SDK 动态库。没有在本轮从 C 源码重建该二进制。

固定依赖的完整许可证复制到 `scripts/licenses/libarchive.txt`，包含包装层 MIT 和所带库的许可证。文件位于主仓库，构建脚本复制到 app 的 `Contents/Resources/scripts/licenses/`；`check_bundle.py` 要求文件存在且非空。

## 本地适配

1. 移除上游 CLI 的递归权限放宽调用。默认解包使用当前用户和 umask，不恢复 setuid/setgid/sticky；`-p` 显式恢复权限和数字所有者。`--no-overwrite-dir` 跳过已存在目录的元数据修改。
2. 在规范化前拒绝绝对成员路径及含 `..` 的成员或硬链接目标；写入路径必须在目标目录中。保留 libarchive 的 SECURE_SYMLINKS 和 SECURE_NODOTDOT 检查。
3. `create` 和 `decompress` 拒绝已有输出路径，包括悬空符号链接。输出先写入本次独占创建的 `0700` 暂存目录，再通过同卷 `link` 排他发布；失败或取消只清理本次暂存目录，并保留竞争者输出。
4. `create` 拒绝位于源目录树内的输出，避免将自己的产物纳入遍历；拒绝不安全的顶层路径。
5. 打包逐块释放 Foundation 自动释放对象，处理 `archive_write_data` 短写并逐块检查取消。打包和解包检查最终 `archive_write_close` 的返回值。
6. CLI 验收发现硬链接成员读取为空；读取接口现跟随归档内硬链接，并拒绝循环或超过 64 层的链接。成员大小预分配上限设为 1 MiB，避免仅凭未验证的头部大小进行大额预分配；实际内容仍完整读入内存。
7. 解包设置 `ARCHIVE_EXTRACT_SPARSE`。本机 16 MiB 夹具内容往返一致，但目标仍完整分配，原因未查明。256 MiB 夹具通过内容、逻辑长度和低分配量检查。该结果不能外推真实 VM 磁盘的空间需求。

解包可以替换已有普通文件，不提供整批回滚。后续成员失败时，前面的成员可能已经写入；错误信息和 README 已明确这一行为。VM 导入的 staging、manifest、库锁和权限策略继续由现有实现负责，未用本批通用解包命令替代。

## 验证

归档相关共 32 项、5 个 suite 通过：21 项上游测试、9 项本地库测试及 2 项 CLI 测试；参数化测试覆盖多个输入。新测试覆盖已有输出/悬空符号链接、源目录内输出、顶层路径、发布竞争、文件内部取消、解压失败清理、成员/硬链接越界、符号链接越界、256 MiB 稀疏往返、硬链接读取及循环拒绝，以及 CLI 注册/参数验证。

首次新增测试编译遇到 throwing 闭包推断问题，显式标注后修复。16 MiB 稀疏分配断言未通过；按既有 P1c 实验规模改为 256 MiB，并保留上述限制记录。

| 检查 | 结果与范围 |
| --- | --- |
| 完整 Python 套件 | make test：369 项，0 失败 |
| 完整 Swift 套件 | 首轮 560 项通过；硬链接修复后 make test_swift：Swift Testing 561 项、77 suites，XCTest 145 项（3 项跳过、0 失败） |
| 既有传输内存回归 | file/producer 两条 1 GiB 路径通过；最终峰值 RSS 为 7,651,328 / 7,831,552 字节 |
| CLI 临时目录验收 | 9 次命令调用符合预期：zstd 打包、列表、二进制成员读取、解包、解压缩、指纹、输出冲突和损坏输入；硬/符号链接保留，目录 0700、文件 0600 保留 |
| 原生打包内存观察 | 单个 128 MiB 文件打包成功，峰值 RSS 17,940,480 字节；这是一次观察，不代表所有压缩配置的内存上限 |
| make build | 退出 0；Release 编译、宿主/guest 签名、bundle 资源和 entitlements 校验通过 |
| 分发与来源核对 | app 内许可证与源码逐字节相同；otool -L 无 Homebrew 或外部 libarchive 动态库；来源清单全部 SHA-256 复核通过 |

CLI 验收首次发现硬链接成员返回空内容，修复后通过。`/usr/bin/time -l` 首次因沙箱限制 `kern.clockrate` 查询而失败；允许该只读查询后完成上述测量。

日志保存到 `research/artifacts/p2-archive-2026-09-28/`（Git 忽略，不随源码提交分发）。

## 后续

P2 保持部分完成。后续先适配原生库与 VM 传输/IPSW 的接口，保留占用检查、manifest 验证、暂存和排他发布；再推进 Restore、daemon/guest 和 bundle 布局。P1c 真实导入及导入后启动继续按用户要求跳过，真实 DSC、恢复和完整 VM 验收仍未完成。本批未删除 VM、未启动 VM、未运行固件恢复。
