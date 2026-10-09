# T28：在线环境更新接口与证据范围

日期：2026-10-07。上游目标固定为 `2d21d21fbdd4f51f013616273ceda9b35a3e0789`。本地代码依据本轮工作树源码；本文不代表正在运行的 vm-new 已使用这些代码。

## 白名单与来源

本地 host 从 `scripts/guest_environment.json` 加载库清单。API daemon 在 `sources/VPhoneDaemon/Daemon/GuestAPI+Environment.swift` 声明相同的 5 个名称和顺序。宿主更新前核对客户机清单；缺库或 `/vh` 指向不符时返回 `full_migration_required`，在线更新只替换已有库。

<!-- local-libraries -->
| 名称 | 加载对象或条件 |
| --- | --- |
| `launchdhook-vphone.dylib` | launchd 在客户机启动时通过 `/vh` 加载 |
| `SystemHook-vphone.dylib` | launchdhook-vphone 为 launchd 启动的进程插入 |
| `libvcamcaptured.dylib` | cameracaptured 启动时由 SystemHook 加载 |
| `libcamfix.dylib` | 相机客户端进程启动时由 SystemHook 加载 |
| `libvlocation.dylib` | 本地清单指定的定位客户端加载路径；实际进程加载仍需验收 |
<!-- /local-libraries -->

固定上游 host/guest 源码均列 7 个库。两端共有前 4 个；本地增加 `libvlocation.dylib`，上游增加 `libmisfix.dylib`、`libhapticsfix.dylib`、`libbatteryhealthfix.dylib`。固定上游 `Research/vphoned_http_api.md` 的环境更新段仍列前 4 个，并写“only those four names”。该段不能作为目标版本的完整白名单。本轮未扩大本地在线更新范围。

## 方法、参数与能力

| 方法 | 参数 | 结果或能力 |
| --- | --- | --- |
| `environment.status` | 无 | 库摘要、暂存摘要、root 只读状态、`/vh` 目标、近期事务；`environment_update` |
| `environment.install` | `libraries: [{name, sha256}]` | 备份和日志、逐库状态、`installed`、`complete`、`reboot_required`、`root_read_only`；宿主要求 `environment_update`、`environment_transaction`、`files`、`file_upload_identity` |
| `environment.restore` | `transaction` | 按记录恢复已替换库；宿主要求 `environment_update`、`environment_transaction` |
| `environment.loaded` | 可选 `processes` 精确名称数组 | 当前或旧文件映射、未检查进程；`environment_activation` |

CLI 提供 `guest env status/update/rollback`，默认候选目录为 `.build/guest-components-v2/stage`。`update --restart` 当前只允许 `cameracaptured`，并要求 `processes` 能力。没有 `environment_transaction` 的旧 API daemon 被拒绝在线批次更新；不能只凭 `environment_update` 推定其具备本地事务契约。

客户机暂存目录固定为 `/var/root/Library/Caches/vphone-environment`。宿主按清单上传，使用权限文本 `644`；候选必须为普通文件，摘要与候选 manifest 一致，并含 `LC_CODE_SIGNATURE`。这不等于客户机运行签名验收。daemon 安装使用 root 写盘及临时可写挂载；在线接口不增加任意库名称或安装缺失库。

通用 API client 默认请求期限为 30 秒；文件上传默认期限为 120 秒，单文件上限为 64 MiB。安装超时、断线或回复不完整不能证明操作未执行；宿主不在同一调用中自动重试安装。API session 的 generation 检查不替代客户机安装事务的操作标识和并发控制。

## 文件安装、激活和业务验收

本轮宿主安装回复检查必需字段、请求顺序与名称、候选摘要、重复项、逐库状态、`installed` 集合和 `complete/state` 一致性。安装后对被替换库再次读取客户机摘要。不一致返回 `api_protocol`，包含 `outcome: unknown` 和 `operation_may_continue: true`，保留事务位置，不继续查询激活或重启进程。

`complete` 是客户机文件批次状态。`reboot_required=false` 不证明进程加载新库。`environment.loaded` 依据文件 dev/inode 区分当前和旧映射；未检查进程仍为未知。客户端输出单独列 `files`、`load`、`activation`，业务字段 `application.state` 保留 `not_verified`。本轮 daemon 的 install 不自动重启进程；显式重启请求只在完整安装后执行，重启后的业务行为仍需验收。

客户机 `EnvironmentTransaction.apply/applyRestore` 当前忽略部分日志保存错误，尚需修复后才能满足持久恢复契约。rollback 回复的严格校验、每 VM 写操作协调、T16 模式允许集合绑定、回复丢失后的确定恢复以及混合版本 VM 验收仍未完成。

## 固件事务证据

T15 的提交窗口检查覆盖 VM 根固件文件和 Restore 树。它不覆盖离线 CFW 写盘的磁盘交换、配置和 Guest receipt。现有 `cfw_install_host.sh` 与 `cfw_disk_txn.py` 在隔离副本上安装：优先 APFS clone，失败后使用 SHA-256 验证的完整稀疏副本，两者不可用则拒绝。完成卸载后交换磁盘，旧盘保存在 `.cfw-history`。clone 路径使用抽样摘要，大文件不能据此声称完整摘要验证。磁盘、配置和分组件 receipt 的共同恢复记录、owner/hardlink 复核及真实 VM 恢复验收仍未完成。

T32 复用已有 journal，保存可选 `reportSHA256`，核对同一事务下 `report.json` 的精确字节。发布前及记录 committed 前核对报告，并复用必需失败和 frozen-plan declaration 检查；恢复时核对报告完整性。缺少该字段的历史或手工事务保留未知报告证据。报告摘要是完整性关联，不能作为加密认证，也不能证明每个补丁在客户机生效。

本轮没有创建 `PatchReceipt.plist`，没有将 `plan.enabled` 复制为 applied 集合，没有抬升 Guest、内核或启动链版本。生成、宿主发布、客户机安装、进程激活及业务验收仍须分别记录。

## 可复算检查

执行 `audit_environment_contract.py --upstream-git-dir <上游 bare 仓库> --document <本文路径>`，核对本地清单与 daemon 白名单、固定上游 host/guest 白名单和本文本地表格，并输出源码摘要。该检查读取源码，不调用客户机 API。声明形态改变时脚本报错并要求人工审查。

本轮原始日志、源码快照和范围结论保存在 `evidence/B04-*`。全任务验收仍依赖尚未完成的 GPU、离线磁盘事务、分组件 receipt、在线事务协调与真实 VM 证据。
