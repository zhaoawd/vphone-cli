# P2 第三批：原生 VM 传输接口与 IPSW 缓存

提交记录（2026-09-28）：按用户要求，将本记录对应的代码、测试及相关文档纳入本次整合提交。下文的“未提交”描述保留各阶段记录时的状态；验收范围和未验证项目不变。

日期：2026-09-28。上游固定为 `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3`。本批在现有 VPhoneBundleOps 中加入原生归档后端，并迁入 IPSW 缓存接口；代码尚未提交。

## 接入方式

`VPhoneCore` 依赖不含业务模型的 `VPhoneArchiveKit`。锁、VM manifest、缓存及发布逻辑保留在 Core，CLI 调用原有 VPhoneBundleOps API。未将上游 VPhoneBundleTransfer 整体替换本地实现，避免丢失本地占用检查和库锁。

| 对象 | 行为 |
| --- | --- |
| `vm export/import --archive-backend native` | 显式使用原生归档库；省略参数时仍为 `system-tar` |
| 导出 | 原有 VM 锁覆盖整个导出；GNU tar、zstd 3/xz 9、顶层 VM 名称及排除规则保持；原生输出拒绝已有文件 |
| 原生导出进度 | 按未压缩文件内容计数；硬链接只计一次；排除目录不继续计入其子目录 |
| 导入 | 两种后端共用随机独占 `0700` 暂存父目录、manifest/链接检查和库锁；最终用 `renamex_np(RENAME_EXCL)` 排他发布 |
| `VPhoneIPSWCache` | 提供本地检查、HTTP(S) 缓存及 iPhone/cloudOS 配对 API |
| `fw inspect INPUT [--cloudos-source PATH] [--json]` | 读取本地 BuildManifest，指定 cloudOS 时检查配对，不下载或解包 |
| `fw prepare`、CFW 安装 | 保留现有脚本路径；尚未改用原生缓存下载器 |

示例：

```sh
vphone-cli vm export sample --out /path/to/new-export.tzst --archive-backend native
vphone-cli vm import /path/to/export.tzst --name sample-copy --archive-backend native
vphone-cli fw inspect /path/to/phone.ipsw --cloudos-source /path/to/cloud.ipsw --json
```

默认后端保持不变，因为真实 VM 导入和导入后启动仍按用户要求跳过。显式原生入口提供后续验收所需的代码路径，不代表真实 VM 已验收。

## 导入检查

发布前要求只有一个真实顶层目录，config.plist 必须为普通文件且可以解析。manifest 指定的磁盘、NVRAM、SEP 和 ROM 路径必须为相对路径，不含 `.` 或 `..`；路径中已存在的父项必须为真实目录，末项必须为普通文件。尚未生成的 NVRAM 等文件可以缺失。

归档中的符号链接只能使用留在 VM 目录内的相对目标。以真实目录深度限制开头的 `..`，拒绝命名路径组件之后再出现 `..` 的歧义形式。普通文件和真实目录可以导入；FIFO、设备等特殊文件拒绝发布。目录检查深度限制为 128。

归档解包到暂存父目录内的 `contents` 子目录，避免归档中的 `.` 目录元数据改变外层 `0700` 权限。两种后端均有对应回归。

最终名称检查和排他 rename 在同一库锁内完成。包括悬空符号链接在内的已有目的路径被拒绝；发布前出现的竞争目录不会被覆盖或清理。失败时清理本次暂存目录。这些发布检查也用于系统 tar 后端。

## IPSW 缓存适配

迁入上游 VPhoneIPSWCache 和 4 项基础测试，移除递归权限放宽。新缓存目录、私有暂存目录为 `0700`，下载文件为 `0600`，不修改已有目录权限。缓存位置若已是符号链接或其他非普通文件则拒绝。

下载按 1 MiB 缓冲写入；检查 HTTP 200、已知 Content-Length 与实际长度、任务取消以及 BuildManifest。失败时保留原有无效缓存；成功后持有缓存目录锁重新检查，优先复用并发完成的有效缓存，否则用同卷 rename 替换无效普通文件。仅清理本次创建的暂存目录。

BuildManifest 成员读取上限为 32 MiB。归档读取 API 新增可选 `maximumBytes`，检查声明大小和实际读取量，硬链接目标沿用同一上限。现有 `archive cat` 仍默认读取整个成员。

配对检查要求 iPhone 的 SupportedProductTypes 包含 `iPhone17,3`，cloudOS 的 BuildIdentities 包含 `vresearch101ap`，并识别来源对调。缓存检查不验证 Apple 签名或所有归档成员，不等同于固件真实性或完整恢复兼容性验证。

## 验证

| 检查 | 结果与范围 |
| --- | --- |
| 初轮相关 Swift 专项 | 46 项、5 个 suite 通过，含原有 BundleOps/LibraryLock 和新增测试 |
| 完整 Python | make test：369 项通过 |
| 完整 Swift | 初轮 make test 为 578 项；追加解包根目录权限保护后 make test_swift：579 项、80 suites；XCTest 145 项，3 项跳过，0 失败 |
| 既有传输内存回归 | 两条 1 GiB 路径通过；最终 file/producer 峰值 RSS 为 8,732,672 / 7,782,400 字节 |
| 跨后端归档 | system-tar/native × fast/max 四种导出组合，每种由两个导入后端恢复；身份、7 类持久文件、硬/符号链接和权限检查通过 |
| 原生传输 | 占用锁拒绝、排除/包含 Restore 目录、已有输出保护、非法 manifest/链接、多顶层目录、竞争发布、进度检查通过 |
| 稀疏文件 | 256 MiB 临时磁盘逐块内容、逻辑长度、低分配量及 `0700` 暂存目录检查通过；不外推真实 VM 的空间需求 |
| IPSW | 模拟 HTTP 成功/失败、长度不符、并发发布、取消、原缓存保留、权限、符号链接拒绝、ZIP 本地检查、配对和读取上限测试通过 |
| CLI 临时目录验收 | 8 次调用符合预期；原生导出由两个后端导入，7 个持久文件 SHA-256 一致；真实进程持锁时导出拒绝，输出冲突拒绝，ZIP 配对检查通过且对调拒绝 |
| make build | 退出 0；Release 编译、宿主/guest 签名、bundle 资源和 entitlements 校验通过 |
| 来源与动态依赖 | 本轮清单 SHA-256 全部一致，许可证随 app 分发；otool -L 无 Homebrew 或外部 libarchive 动态依赖 |

初次编译因同 package 类型不允许 `@retroactive` 标记而失败，移除该标记后重新编译通过。签名 app 的实际 VM 执行准入未重新验证；本轮 CLI 验收使用 debug 可执行文件和临时夹具。

源码来源、部分迁移映射和本轮 SHA-256 见 [来源清单](p2_transfer_sources_2026-09-28.json)。前两批来源清单保留其验证时的快照，本清单记录本轮继续修改的归档读取器及接线文件。日志与 CLI 数据保存在 `research/artifacts/p2-transfer-2026-09-28/`，该目录被 Git 忽略。

## 剩余工作

P2 仍未完成。后续推进 Restore 依赖和原生解析/probe/ticket/错误映射接口，以及 daemon/guest、bundle 布局；完整原生固件准备管线也尚未迁入。P1c 真实 VM 导入、导入后启动和 P1b 真实 DSC 验收继续保持未完成。本批仅使用临时夹具，未下载真实固件、删除 VM、启动 VM 或执行恢复。
