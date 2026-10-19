# T32/T33：vm-new 真实验收（2026-10-16）

用户指定 `vm-new` 用于撤销写入和启动验证。实际目录为 `/Users/kolar/github/vphone-cli/vm-new`，不是默认 library 下的同名目录。磁盘为 68,719,476,736 字节（64 GiB）。本轮不修改生产源码，不重新安装 CFW，不构造缺失的历史证据。

## 前置条件与结果

初始 lsof 未发现 Disk.img 占用，hdiutil 未发现该磁盘附件。原 `.vphone-runtime.json` 是 2026-10-11 的诊断记录，不能据此认定 VM 正在运行。目录没有 `.firmware-generations`、`.firmware-desired-plan.json`、`.cfw-history` 或 pending CFW 事务。

因此本轮可以验证旧 VM 缺证据时的拒绝及现有系统启动。正向 DSC 撤销需要独立原始固件、generation、冻结计划和完整的已提交安装 journal；当前安装文件、`.bak` 和现有 Restore 目录不能补造这些资格。用户后续选择改用已有完整 journal 的 VM，因此不重新安装 vm-new；目标核对见本文末节。

## 旧 VM 拒绝验收

保存脚本：`tools/verify_legacy_guest_undo.py`。执行：

```sh
.venv/bin/python3 -B research/upstream_integration_2026-10-15/tools/verify_legacy_guest_undo.py \
  --vm vm-new --cli .build/debug/vphone-cli \
  --out research/upstream_integration_2026-10-15/evidence/T32-T33-vm-new-acceptance/offline-final
```

脚本使用实际 CLI、Python 预览入口和目录锁。全零 generation 仅表示明确不存在的期望值，不作为该 VM 的 generation。

| 检查 | 结果 |
| --- | --- |
| `cfw receipts vm-new --json` | 退出 0，返回 `schemaVersion=1, state=unknown` |
| `cfw_disk_txn.py preview-undo` | 退出 1，`no committed guest checkpoint; Undo is unavailable` |
| `cfw undo vm-new` | 退出 64，`CFW requires a current bound desired plan; missing/legacy selection cannot authorize installation` |
| Disk.img 完整 SHA-256 | 前后均为 `2ba5633b755289909086d3762237c37411ba39c6ba1e942c1bcce5662b7fe95a` |
| 磁盘、配置、NVRAM、SEPStorage | 摘要及记录的身份、大小、权限、owner、mtime/ctime 前后一致 |
| generation、历史 journal、staging | 未创建 |

最终脚本退出 0，用时 67.774 秒。首轮脚本误期望另一接口的错误文本 `Missing desired plan`，实际入口已安全拒绝；根据入口源码修正精确错误断言，保留首轮日志。最终同时断言非零退出码、准确拒绝原因和文件保持，没有降低拒绝要求。目录锁会更新诊断 runtime 文件，该文件不属于磁盘内容保持断言。

## 构建与宿主检查

`make build` 首次在 daemon overlay 检查处退出 2：默认 `.build/daemon-api-v2` 缓存的 IcliKit revision 为 `702990b59ca412ad975f9f0ea5dafe95c30fac21`，与锁定的 0.8.5 / `815ef234df5461b8eb9455931d38cb1c37992fe6` 不同。未改锁文件或覆盖该旧缓存。

随后核对仓库内 `.build/daemon-api-t59-20261015` 的全部锁定依赖，用 `VPHONE_DAEMON_API_BUILD_DIR` 选择该构建目录重建候选；显式将校验后的 candidate 交给 `check_guest_api.py --stage-api --record`；使用文档支持的 `zsh scripts/build.sh --no-vphoned` 复用刚构建的资源，完成完整应用的签名、资源、依赖闭包和 entitlement 校验，退出 0。候选没有安装到 VM。

`boot_host_preflight.sh --assert-bootable` 对当前签名 release VM 可执行文件退出 0，`release_help` 退出 0；临时签名 debug 对照退出 137。该结果证明当前 release 路径可执行，不证明任意路径的私有 entitlement 都已放行。本轮未更改 SIP、AMFI、allow-research-guests 或系统 Store。

## 两次真实启动

保存脚本：`tools/verify_legacy_vm_boot.py`。执行：

```sh
.venv/bin/python3 -B research/upstream_integration_2026-10-15/tools/verify_legacy_vm_boot.py \
  --vm vm-new --vm-executable .build/release/vphone-vm \
  --cli .build/vphone-cli.app/Contents/MacOS/vphone-cli \
  --out research/upstream_integration_2026-10-15/evidence/T32-T33-vm-new-acceptance/runtime
```

实际 VM 参数为 `--config .../vm-new/config.plist --headless --no-vphoned-update`。该入口持有 VM 锁，连接现有 classic daemon，禁用二进制更新。请求仅查询 capabilities、`kern.boottime` 和 SystemVersion.plist；没有执行客户机文件写入。正常启动和关机会改变客户机磁盘、NVRAM 等运行状态，因此离线拒绝阶段的磁盘不变结论不延伸到启动阶段。

| 检查 | 第一次 | 第二次 |
| --- | --- | --- |
| host runtime instanceID | `4E7B3E81-E2B5-45C4-9A28-CA0991A7D55E` | `3140CF01-76C1-4AC4-B6D1-EBCA6D68E609` |
| `kern.boottime` 秒值 | 1792081447 | 1792081476 |
| 客户机连接 | vphoned v1，连接成功 | vphoned v1，连接成功 |
| SystemVersion | iOS 26.1 / 23B85 | iOS 26.1 / 23B85 |
| `vm stop` / VM 退出码 | 0 / 0 | 0 / 0 |
| 正常停止 | 日志含 `Guest stopped` | 日志含 `Guest stopped` |
| 强制停止 | 未触发 | 未触发 |
| 磁盘与目录锁 | 已释放 | 已释放 |

两次 instanceID 和客户机启动时间均不同。配置和已有 `.vphoned.signed` 的摘要保持。最终 lsof、hdiutil 和目录 flock 核对：VM 已停止，磁盘无占用、无附件，无 pending CFW 事务，generation 和 CFW 历史仍缺失。

## 证据与范围

[证据清单](evidence/T32-T33-vm-new-acceptance/manifest.json)保存初始文件元数据、离线完整摘要、实际命令与返回值、构建失败与成功日志、宿主预检、两次串口日志、读回结果和最终状态。

本轮通过“旧 VM 缺 Undo 时拒绝”和“两次现有系统启动及正常停止”验收。尚未完成真实 DSC 撤销、撤销前后功能比较、撤销后的再安装、中断恢复或真实完整 DSC/Preboot 集合验证。两次启动不提升为 guest Undo on→off→on 验收；T32/T33 整项继续未接受。

## 后续选择：改用已有 journal 的 VM

用户选择改用已有完整 journal 的 VM，没有授权重新安装 vm-new。本轮只读检查仓库、默认 library、既有 v2 验收 library、已知备份及注册工作树根目录，共发现 7 台 VM。classic/v2 两台验收 VM 的 4 份可读已发布日志均为 v1，没有 generation、冻结 desired plan 或 `guest-publication.json`。roothide VM 的 1 份历史因 root 权限不可读，且另有 2 个未完成 CFW 事务，未恢复或改动。其余已知 VM 没有符合要求的历史。

这次检查只覆盖已知目录和日志头，尚未找到可进行完整校验的正向撤销候选。已请求用户提供另一台 VM 的名称或路径。VM 文件保持；未启动其他 VM，未更新 runtime 记录。目录清单、读取错误和范围见 [inventory.json](evidence/T32-T33-existing-journal-search/inventory.json)。
