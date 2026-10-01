# v2 环境 B5：Swift 入口与安装证据

日期：2026-10-02。依赖：B1–B4，基线 `69df867`。范围依据 `v2_guest_environment_design_2026-10-01.md` 第 7、8 节。

## 实现

- `vm create` 和 `cfw install` 接受 `--guest-environment classic|v2`。默认 classic；v2 仅允许 regular。创建检查点保存 v2，resume 未指定该参数时保留原值，`create-status` 显示环境。
- 两个入口将 v2 参数及候选目录传入 B4 驱动。候选目录允许 `VPHONE_GUEST_COMPONENTS`、`VPHONE_API_DAEMON` 覆盖；默认使用资源根下的 stage 和 candidate。
- 创建完成 CFW 后记录 `restore-info.json.guest_environment`。classic 的历史检查点编码和摘要沿用 B1 兼容规则。
- 独立 `cfw install` 要求请求环境与 restore-info 的有效环境相同；没有记录视为 classic。classic 转 v2 留给 B6；记录 v2 的 VM 无选项安装也拒绝。检查发生在缓存创建、Python 查找和提权之前。
- resume 在修改检查点之前拒绝 v2 降级为 classic，即使指定 `--restart-from cfw`。
- v2 CFW 执行必须产生唯一新增 `.cfw-history` 归档。检查点 evidence 保存事务 ID、安装报告相对路径及 SHA-256。校验器核对报告 schema、profile、variant、事务 ID、installed 结果、already_current 后置判定、published 事务状态及 restore-info 环境。报告和事务文件必须为 bundle 内的普通文件，拒绝路径中的符号链接。安装报告作为 SHA-256 artifact 保存。
- T16 的 full_migration_required 提示给出 `vm create <name> --variant regular --guest-environment v2`，不执行迁移。

## 复现与验证

先增加复现，再实现：两个入口未知选项；v2 对非 regular variant 未拒绝；恢复请求无法携带环境覆盖；缺少 v2 报告仍被 CFW 校验器接受；旧迁移提示未包含新入口。失败日志分别在 `/tmp/vphone-b5-entry-red.log`、`guard-red.log`、`guard-green.log`（新增恢复字段编译失败）、`evidence-red.log`、`migration-red.log`，均使用同一 `vphone-b5-` 前缀。

回归包括参数解析、variant 限制、独立安装环境一致性、降级时检查点字节不变、报告缺失、摘要不符、variant 不符、事务未发布、符号链接拒绝、有效报告通过以及 restore-info 环境不符。

验证结果：

- `make test_python`：581 项，146.873 秒，退出 0；日志 `/tmp/vphone-b5-python.log`。
- `make test_swift`：11 组 Swift 测试全部通过，guest components 124 checks、0 failures，退出 0；日志 `/tmp/vphone-b5-swift.log`。测试输出含宿主私有框架重复类与 contacts 服务诊断，未导致测试失败。
- 最后的成功报告/环境记录断言新增后，`swift test --disable-sandbox --cache-path .build/test-cache --filter 'GuestEnvironmentEntryTests|v2Resume|v2CFWVerifier|v2InstallationEvidence'`：6 项通过；日志 `/tmp/vphone-b5-evidence-green.log`。
- `.build/debug/vphone-cli vm create --help` 与 `cfw install --help`：两个入口显示该选项。
- `git diff --check`：通过。

固件夹具比较未执行，本批未改变固件补丁。

## 验证限制与下一步批准

未执行真实创建、System 卷安装、启动、库加载、T16/T17 成功路径；未在主仓库执行 `make build`。Swift 测试产物不足以用于 VM 执行。R1–R9 仍需用户授权；T18/T19 范围仍保留后续确认。

建议批准范围：在 `/private/tmp/vphone-v2-build-20261002` 独立 checkout 和独立 `.build` 构建签名产物；新建 `/Users/kolar/vphone-v2-accept-20261002/VMs` 测试库及 `lp-v2-accept-20261002`（regular、v2，默认 64 GB 磁盘），不覆盖已有名称；运行 R1–R4，包括 sudo/认证、TSS 联网、VM 启停及只读环境诊断。R4 失败时停止 R5 及后续，记录 D6 证据并提交用户决定。R4 通过后，R5 触控、R6/R7 修改测试 VM、R8 回退及删除、R9 classic 副本操作按第 7.2 节另列具体对象供批准。

R1 命令：`vphone-cli vm create lp-v2-accept-20261002 --library-root /Users/kolar/vphone-v2-accept-20261002/VMs --variant regular --guest-environment v2 --root-popup`。
R2 命令：`vphone-cli cfw update-environment lp-v2-accept-20261002 --library-root /Users/kolar/vphone-v2-accept-20261002/VMs --check --root-popup`。
R3/R4 使用同一测试库，API 仅绑定 `127.0.0.1:0`，每次使用随机 token；运行 `guest env status`、`guest rpc device.info`，保存进程映射与客户机日志。

不操作 `vm-2607`、`vm-new`，保留测试 VM 和事务备份。当前仓库外的 checkout、测试库与写入动作等待本次明确批准。
