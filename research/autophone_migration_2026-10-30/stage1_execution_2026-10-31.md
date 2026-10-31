# autophone 迁移阶段 1 执行记录

日期：2026-10-31。状态：**阶段 1 已通过**。覆盖固定纯上游构建、新 VM 的固件准备、补丁、恢复、CFW 安装，以及通过 autophone 独立入口执行的正常启动、停止、再次启动和启动锁释放。阶段 2/3 尚未实施或验收。

当前测试 VM 已停止；独立收尾确认磁盘无进程占用、CFW 挂载和安装进程均已结束。未删除旧 VM 或历史实验数据，未提交、合入或发布。

## 运行对象与用户确认

用户确认：新建独立 VM，采用 iPhone17,3 iOS `27.0.1 (24A446)` + cloudOS `26.4 beta (23E5207q)`、standard preset；允许本次精确构建加入 AMFI allowlist。阶段 3 首批流程为指定 build-id 安装与基础应用操作，具体应用和 build-id 待该阶段核对。

| 对象 | 身份与位置 |
| --- | --- |
| autophone worktree | `/Users/kolar/github/autophone/.claude/worktrees/autophone-upstream-migration` |
| autophone 分支与基线 | `feat/autophone-upstream-migration`；`3bf50e8848b15cb5fe9848aa5087c85c8bd42c15` |
| 纯上游源码 | `.build/autophone-migration-20261031/upstream`；`39324ee7fcbb1d909bfa293f6188a8ef752ba734`，最终已跟踪源码状态干净 |
| Core Bundle | `.build/autophone-migration-20261031/DerivedData/Build/Products/Debug/VPhone.bundle`；`2.14.1 (58)`；`VPhoneBuildHash=39324ee` |
| VM companion CDHash | `5b2fde525d99a1783343762ea168b24410e0a9d1` |
| 新 VM | `.build/am31/machines/baseline`；8 CPU、8192 MB、64 GB 配置 |
| UDID / ECID | `0000FE01-2119AAF5C1E70D2F` / `0x2119AAF5C1E70D2F` |
| 宿主 | macOS `27.0.1 (26A434)`；Xcode `27.1 (27A9269)` |

隔离源码最初从固定提交导出，之后建立独立 Git 元数据，避免构建脚本将外层仓库身份写入产物。上游 `vphone-cli-up` checkout 保持干净。autophone 主工作区既有 `AGENTS.md` 和 `TASKS.md` 修改未覆盖，新增代码仅位于上述 worktree。

## autophone 实现范围

新增 `autophone/rig/upstream.py`，入口为 `python -m autophone.rig.upstream`：

- `preflight` 显式指定 `--bundle`，调用对应的 `vphone-cli host preflight`。
- `launch/stop` 显式指定 `--bundle` 和 `--vm-dir`，检查三个宿主可执行文件及 `schemaVersion=2`，将 VM 名称及其父目录传给上游 `--library-root`。
- `launch` 可指定 `--headless`；`stop` 委托上游正常关机及超时处理。通过 `execv` 替换包装进程，保留上游信号处理。
- 同 VM 的非阻塞启动锁 FD 随 exec 传入上游 CLI；重复启动拒绝，stop 不等待启动锁。检查锁文件类型、所有者、链接数，拒绝符号链接。
- `--dry-run` 输出 JSON argv，无协议猜测重发或 AMFI 自动授权。保留 StageGuard 的 VM 操作门禁。

**启动锁仅覆盖经过该入口的启动。直接调用上游 CLI 不受其约束；跨入口的完整磁盘排他性尚未验证。** 原生实验表明两个进程可同时创建同一 4 MiB 临时镜像的可写 `VZDiskImageStorageDeviceAttachment`；实验未启动 VM，不能据此断定完整 VM 的并发启动结果。源码为 `probe_disk_attachment.swift`，结果为 `runtime/attachment-exclusivity.json`。

原 `scripts/start_vphone.sh` 和 `RigLifecycle` 尚未接入新入口。新入口不启动 SSH、Frida、健康守护或 Control Plane；这些仍属后续适配。

## 固件与构建结果

构建与签名检查：

```sh
xcodebuild -workspace "$PWD/.build/autophone-migration-20261031/upstream/VPhone.xcworkspace" \
  -scheme VPhone -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/.build/autophone-migration-20261031/DerivedData" build
codesign --verify --deep --strict .build/autophone-migration-20261031/DerivedData/Build/Products/Debug/VPhone.bundle
```

最终构建退出 0，bundle 构建验证阶段与签名检查通过。批准的 allowlist 执行退出 0；经 autophone 新入口运行 `host preflight` 退出 0。实际宿主修改仅包括用户批准的精确构建 AMFI 准入；没有执行其他宿主策略修改。

| 输入或操作 | 证据与结果 |
| --- | --- |
| iPhone IPSW | 12,343,857,610 字节；SHA-256 `fc87bb9da8c03d0154d87531950f4a170195f6663ee5208653fa7a26bafb9469`，与下载响应的摘要一致；BuildManifest 为 iPhone17,3 `27.0.1/24A446` |
| cloudOS IPSW | SHA-256 `c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64`；BuildManifest 为 `26.4/23E5207q`；读取既有本地缓存 |
| `fw prepare` | 退出 0；复用已核对版本的本地 GPU bundle，写入新 VM 的 restore tree |
| `fw patch --preset standard` | 退出 0；日志报告 11 个组件、252 项补丁；未修改补丁源码、声明或 preset |
| restore | 显式绑定新 UDID/ECID，退出 0；`restore-info.json` 记录已选构建；日志另报告 101 个 boot-chain receipt 条目，不与 252 项操作作等价换算 |
| DFU 停止 | autophone 新入口 `stop` 退出 0，原 DFU launch 退出 0；不计为 guest 正常关机验收 |
| CFW 安装 | 一次性 `install_stage1_cfw.zsh` 执行退出 0；固定 CLI SHA-256，检查目标磁盘所有者、符号链接、签名与停机状态；仅本轮新 VM，工作目录 `.build/am31/cfw-work`，`--keep-artifacts` 保留准备产物 |

CFW 日志报告 `vphoned is installed, no package bootstrap was staged`。guest 实际报告型号 `iPhone17,3` 和 iOS `27.0.1`；`restore-info.json` 的宿主 device 记录为 `iPhone99,11`，不能将该字段当作实际 guest 型号。guest `jailbreak.layout` 为 null；本阶段未安装包管理器、SSH、Frida 或其他用户环境。

## 真实启停验收

保存的 `accept_stage1.py` 通过 autophone 新入口执行两轮 GUI 启动与正常停止。脚本检查已恢复的构建组合、guest iOS 版本、只读 ping、`device.info`、宿主进程归属、启动锁、磁盘句柄和 boot session UUID。出现强制断电或 SIGKILL 时拒绝通过。

最终结果为 `runtime/boot-acceptance-r2/result.json`，`accepted=true`：

| 验证 | 第 1 轮 | 第 2 轮 |
| --- | --- | --- |
| ping 就绪耗时 | 10.047 秒 | 4.069 秒 |
| `device.info` 耗时 | 16.396 秒 | 0.056 秒 |
| guest 型号 / iOS | iPhone17,3 / 27.0.1 | iPhone17,3 / 27.0.1 |
| 宿主进程归属 | `target`，退出 0 | `target`，退出 0 |
| 运行中启动锁 | 已持有 | 已持有 |
| 正常关机 | 日志含 Asking the guest to shut down 和 Guest stopped | 同左 |
| stop / launch 退出码 | 0 / 0 | 0 / 0 |
| 停止后磁盘占用 | 无 | 无 |
| 停止后启动锁 | 已释放 | 已释放 |

两轮 boot session UUID 分别为 `1245F829-2847-4598-A53F-A316C488F1A2`、`7599CF04-18B2-479C-971C-1D503361AA85`，证明观察到了不同启动会话。两轮 daemon binary hash 均为 `65e94b380a952fd770ae2bd9ab5769bfa4f4472897a20291490a91b3941ba6d1`。

独立收尾再次确认：固定上游源码干净、bundle 签名有效、目标磁盘无打开进程、无该目标或 CFW 工作目录的 hdiutil 附件、无该 VM 或安装进程。见 `runtime/independent-closeout.json`。收尾时卷可用空间约 92 GiB；本轮源码、固件、VM 与证据均保留。

复跑命令（在 vphone-cli 根目录执行；`--output` 必须选择尚不存在的新目录）：

```sh
.venv/bin/python research/autophone_migration_2026-10-30/accept_stage1.py \
  --bundle "$PWD/.build/autophone-migration-20261031/DerivedData/Build/Products/Debug/VPhone.bundle" \
  --vm-dir "$PWD/.build/am31/machines/baseline" \
  --autophone /Users/kolar/github/autophone/.claude/worktrees/autophone-upstream-migration \
  --python /Users/kolar/github/autophone/.venv/bin/python \
  --output /absolute/path/to/new-evidence-directory
```

## 回归命令与结果

在 autophone worktree 根目录运行：

```sh
/Users/kolar/github/autophone/.venv/bin/python -m pytest -q \
  tests/test_upstream_vphone_lifecycle.py tests/test_start_vphone_script.py \
  tests/test_rig_lifecycle.py tests/test_vphone_target.py tests/test_m6_same_host_multi_rig.py \
  -m 'not live_device and not live_frida'
/Users/kolar/github/autophone/.venv/bin/ruff check \
  autophone/rig/upstream.py tests/test_upstream_vphone_lifecycle.py
```

最终 **156 passed, 8 skipped，8.91 秒**；Ruff 通过。8 项因缺少 `AUTOPHONE_TEST_POSTGRES_DSN` 跳过；不表示 PostgreSQL 多 Rig 集成已验证。

在 vphone-cli 根目录运行验收工具的隔离回归：

```sh
.venv/bin/python -m unittest discover -s research/autophone_migration_2026-10-30 -p test_accept_stage1.py -v
/Users/kolar/github/autophone/.venv/bin/ruff check \
  research/autophone_migration_2026-10-30/accept_stage1.py \
  research/autophone_migration_2026-10-30/test_accept_stage1.py
zsh -n research/autophone_migration_2026-10-30/install_stage1_cfw.zsh
```

最终 6 项隔离测试、Ruff 和 shell 语法检查通过。覆盖错误构建拒绝、强制停止拒绝、写探针拒绝、分片与截断响应，以及分片流不得延长总截止时间。真实 VM 验收由保存的同一脚本执行，未以单次 UI 交互替代。

## 失败记录与验证限制

- 首轮沙箱构建退出 66，原生构建成功。首次导出源码构建的版本戳误读取外层仓库；核对发现后建立独立 Git 元数据并重建。最终戳为 `39324ee`，不含 dirty；错误版本戳不作为来源证据。
- 首次测试选择包含不存在的文件，退出 4、未执行测试；修正后完成上述回归。Ruff 曾发现未使用导入及验收脚本风格问题，修正后检查通过。
- 批准前宿主预检被 AMFI 拒绝；原始结果保留在 `host-preflight-final.log`，批准后结果在 `host-preflight-allowed.log`。
- 首次真实验收中 ping 约 5.018 秒就绪，`device.info` 在客户端 3 秒预算内未返回，整轮 `accepted=false`。脚本随后正常关闭 guest，stop/launch 均退出 0。原记录保留在 `runtime/boot-acceptance/`。
- 固定上游 `VPhoneHTTPLimits.rpc` 的截止时间为 180 秒。验收脚本将 `device.info` 客户端预算设为 185 秒，并记录实际延迟；其他成功断言保持不变。复测两轮实际查询耗时为 16.396 秒和 0.056 秒。该结果不建立阶段 2 的低延迟健康准入保证。
- 10 月 30 日原调查快照与首轮 `execution.json` 保留历史含义；后续源码与 TASKS.md 变化使用新快照记录，不覆盖历史证据。

尚未覆盖：原全栈 Rig 接入、显式 Per-Rig 协议绑定、UDS 失败路径和权限边界、Shell 执行契约、文件/应用语义、跨入口磁盘排他性、真实 PostgreSQL 多 Rig、指定 build-id IPA 安装、SSH/Frida、定位/相机消费。阶段 1 的通过仅适用于上表固定构建、固件组合与独立入口。

## 后续阶段

阶段 2 按清单推进基础兼容与失败路径回归；先处理 Per-Rig 协议显式绑定、健康状态与传输适配，保留 StageGuard 的逻辑命令分类，不自动切换协议重发写操作。阶段 3 按用户选择实施指定 build-id 安装及基础应用操作，先核对仓库包记录再选定具体应用与 build-id。旧 VM 原地升级、按需扩展和历史清理未纳入本轮运行。
