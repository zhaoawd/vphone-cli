# D3 真实 CFW 安装验收

日期：2026-09-17。使用 iPhone/cloudOS 26.1（23B85）和四台位于 `.build/d3/` 的专用测试 VM。`vm-2607` 的运行磁盘未用于本次安装。

## 实验设置

- `vm-regular`：`make vm_new` 创建 64 GiB 稀疏磁盘；`fw_prepare` 从本地两份 IPSW 生成混合恢复目录；`fw_patch` 提交 58 条 regular 补丁记录；DFU 恢复命令返回 0。恢复后向已核对配置路径的 DFU 宿主发送 SIGINT，宿主正常退出。安装前确认磁盘无打开句柄、socket 不存在且目录锁可获取。
- `vm-dev`、`vm-jb`、`vm-exp`：各自新建 64 GiB 稀疏磁盘；恢复目录从 `vm-regular` 固件事务的 `backup` 中以 APFS 克隆复制。`fw_patch_dev`、`fw_patch_jb`、`fw_patch_exp` 分别提交 70、152、178 条补丁记录。三个 VM 各有独立磁盘与配置。
- 三台专用 VM 的首次安装前只读清单已保存到 `research/artifacts/d3-cfw-2026-09-17/{dev,jb,exp}-before.json`。System 卷均无 Cryptex OS/App 目录、`vphoned` 与其 LaunchDaemon，三个待补丁系统程序存在且均无 `.bak`；这些记录确认后续安装从未安装 CFW 的系统卷开始。
- `.build/d3/vm-baseline` 从关机的旧 `vm-new` 复制。只读 System 卷检查发现已有 Cryptex OS/App 各 3 个目录项；该副本不计为首次安装基线，也未执行 CFW 安装。
- 安装使用 `vphone-cli cfw install --variant <variant> --root-popup --keep-artifacts --project-root /Users/kolar/github/vphone-cli`，其中 VM library root 为 `.build/d3`。管理员权限由 macOS 原生认证窗口提供。

## 安装结果

| 变体 | 固件准备与恢复 | CFW 首次安装 | 重复安装与产物比较 |
| --- | --- | --- | --- |
| regular | 补丁提交、DFU 恢复返回 0、关机检查通过 | 安装命令返回 0；七阶段完成，离线 snapshot 切换成功；`restore-info.json` 记录 `regular` | 第二、三次安装均返回 0；Cryptex 识别已有内容并跳过复制；snapshot 工具报告此前已切换 |
| dev | 补丁提交、DFU 恢复返回 0、关机检查通过 | 安装命令返回 0；七阶段完成，离线 snapshot 切换成功；`restore-info.json` 记录 `dev` | 再次安装返回 0；Cryptex 识别已有内容并跳过复制；snapshot 工具报告此前已切换 |
| jb | 补丁提交、DFU 恢复返回 0、关机检查通过 | CFW 与 JB 阶段完成，安装命令返回 0；离线 snapshot 切换成功；`restore-info.json` 记录 `jb` | 再次安装返回 0；Cryptex 识别已有内容并跳过复制；snapshot 工具报告此前已切换 |
| exp | 补丁提交、DFU 恢复返回 0、关机检查通过 | CFW、JB 与 EXP 阶段完成，安装命令返回 0；离线 snapshot 切换成功；`restore-info.json` 记录 `exp` | 再次安装返回 0；Cryptex 识别已有内容并跳过复制；snapshot 工具报告此前已切换 |

regular 首次安装后的只读复查使用 [清单脚本](d3_cfw_inventory.py)，输出为 `research/artifacts/d3-cfw-2026-09-17/regular-first.json`。System 卷中 Cryptex OS/App 各有 3 个目录项，`seputil`、`launchd_cache_loader`、`mobileactivationd` 与各自 `.bak`、`usr/bin/vphoned`、`vphoned.plist` 均存在。清单保存这些文件的大小与 SHA-256。复查后已卸载镜像。

第二次 regular 安装后相同目录项与 `.bak` 摘要保持不变，`usr/bin/vphoned`、`seputil`、`launchd_cache_loader`、`mobileactivationd` 摘要变化。第二、三次安装后的文件分别保存在 `research/artifacts/d3-cfw-2026-09-17/regular-{second,third}-files/`。逐字节比较显示四个文件的长度、`LC_CODE_SIGNATURE` 的偏移和长度相同；签名区域外的字节完全相同，差异仅位于签名区域。本实验未分析签名内容变化的具体机制，不以完整文件 SHA-256 相等作为重复安装的结论。

四台 VM 完成安装后均已关机，磁盘没有 `lsof` 打开句柄、残留镜像挂载、socket 或活动固件事务。使用 [清单脚本](d3_cfw_inventory.py) 对每个 System 卷只读挂载、读取并卸载。`research/artifacts/d3-cfw-2026-09-17/{regular,dev,jb,exp}-final.json` 保存最终文件摘要和目录项；dev、JB、EXP 的安装前清单均无 Cryptex OS/App、`vphoned` 及三个 `.bak`。安装后四个变体均有 Cryptex OS/App 各 3 个目录项、`vphoned`、`vphoned.plist`、三个系统程序及其 `.bak`。JB、EXP 另有 `/cores/launchdhook.dylib`、`libellekit.dylib`、`systemhook.dylib`、`vphone_jb_setup.sh`、`vphone_sshd.sh`；regular、dev 的 `/cores` 为空。

首次与重复安装日志分别在 `.build/d3/{dev,jb,exp}-{first,repeat}.log`；regular 重复安装日志在 `.build/d3/regular-{repeat,third}.log`。首次安装日志包含 snapshot 重命名完成记录；重复安装日志报告 `no com.apple.os.update-* root snapshot found (already flipped?)`。这条输出支持本次磁盘状态已切换，不单独证明客户机正常启动。

首次安装的成功退出与上述文件清单只证明本次磁盘安装和选定产物存在。正常启动、客户机行为及其他固件版本未在此列结论。

## 环境与后续验证

- 锁定 Python 环境已通过 `check_python_runtime.py --locked`；`make build` 及包签名检查通过。
- `make test_python` 在普通沙箱中因本地 Unix socket 绑定受限出现 8 个环境错误；在允许本地 socket 的环境重跑，121 项通过。
- 本轮四变体离线安装与重复安装验收已完成。上述专用 VM 未由迁移前脚本安装；迁移前后同输入产物对照在下文配对磁盘中完成；已有 [公共步骤记录](d3_shared_cfw_2026-09-14.md) 保存阶段语句比较及故障清理回归。正常启动、客户机服务、JB 首启脚本实际执行和 EXP 客户机功能仍需后续端到端任务验证。

## 同输入迁移对照准备

从公共步骤提取前的 `bc7f075^` 读取四份原安装脚本，SHA-256 清单保存在 `.build/d3/parity/legacy-source/` 对应文件。运行副本暂存于 `scripts/.d3-parity-legacy-*.sh`；仅将 JB/EXP 对基础脚本的调用指向该副本。旧版与当前版共用未修改的 `cfw_install_host.sh` 挂载和清理逻辑，运行副本中的 host driver 只改变变体到脚本文件名的映射。对照结束后，这些运行副本已从 `scripts/` 移至受 Git 忽略的 `.build/d3/parity/legacy-runtime/`；移动后的副本不再可直接运行。

新建 `.build/d3/parity/base`，用 26.1 / 23B85 的 regular Restore 输入完成 DFU 恢复；停止专用 DFU 宿主后确认磁盘无打开句柄、socket 和活动事务。只读清单 `research/artifacts/d3-cfw-2026-09-17/parity-base-before.json` 显示无 Cryptex OS/App、`vphoned` 或 `seputil.bak`。四个变体分别从这份恢复后、未安装 CFW 的磁盘克隆出 legacy/current 配对磁盘，再从相应 D3 变体复制相同的固件 Restore 输入。每对配置和两份 Manifest 的大小、SHA-256 相同，清单在 `.build/d3/parity/paired-inputs.json`。

八次安装与 [卷清单脚本](d3_cfw_parity.py) 已编排在 `.build/d3/parity/install-batch.zsh`，逐一检查关机、磁盘占用和至少 80 GiB 可用空间，随后比较 System、xART、Preboot 卷。管理员认证后批次已启动；2026-09-17 15:23 的日志显示 regular 两次安装及 dev 迁移前安装完成，dev 当前版安装已启动。全量只读扫描在普通用户环境遇到 System 卷受保护文件 `.file` 的权限拒绝，并已卸载镜像；批次中的扫描随后在管理员环境执行。

## 同输入迁移对照结果

批次日志显示八次安装全部结束于 `[+] host-mode CFW install complete`，首次安装均包含 snapshot 重命名记录。随后在管理员环境对八个磁盘执行只读 System、xART、Preboot 全量扫描，并生成四份 legacy/current 比较结果。完成后复核：配对目录下无残留挂载，`hdiutil info` 无配对磁盘，`lsof` 无打开句柄。

四个变体的三卷目录项数量在 legacy 与 current 之间一致：

| 变体 | System | Preboot | xART | 差异条目 |
| --- | ---: | ---: | ---: | ---: |
| regular | 447168 | 67 | 4 | 10 |
| dev | 447318 | 67 | 4 | 143 |
| jb | 447326 | 6604 | 4 | 22 |
| exp | 447328 | 6610 | 4 | 159 |

没有仅存在于一侧的安装文件。全部差异分为以下类别，分类结果在 `research/artifacts/d3-cfw-2026-09-17/parity/classification.json`，四份比较结果和配对输入清单保存在同一目录。`research/artifacts/` 与 `.build/` 均受 Git 忽略，这些文件只保存在原主机；约 100 MiB 的逐卷清单保留在 `.build/d3/parity/*.inventory.json`，其 SHA-256 记录在分类文件中。

| 类别 | 涉及变体 | 证据 |
| --- | --- | --- |
| `.fseventsd` 日志文件（6–15 条） | 全部 | macOS 文件系统事件日志及 `fseventsd-uuid`，在读写挂载期间生成；安装脚本不直接放置这些文件 |
| thin Mach-O 仅签名区域不同（4–8 条） | 全部 | `usr/bin/vphoned`、`seputil`、`launchd_cache_loader`、`mobileactivationd`；dev/JB/EXP 另有 `sbin/launchd`、`debugserver`；EXP 另有 Preboot 中 `libcamfix.dylib`、`libvcamcaptured.dylib`。比较工具确认长度、模式、签名区域位置相同，签名区域外字节 SHA-256 相同 |
| iosbinpack64 AppleDouble 文件（131 条） | dev、EXP | 两侧 `cfw_input/jb/iosbinpack64.tar` 均在安装时由 dev overlay 重新打包，620 个成员名称、模式、大小一致。131 个 `._*` 成员的内容差异全部位于 `com.apple.quarantine` 值 `0281;<8 位十六进制时间>;` 的时间字段；另有同名 pax 扩展属性和 1 个 mtime 不同。四个磁盘上 310 个 `._*` 文件的 SHA-256 均与各自 tar 成员一致 |
| fat Mach-O 仅签名区域不同（4 条） | JB、EXP | `/b`、`cores/launchdhook.dylib`、`libellekit.dylib`、`systemhook.dylib`。只读挂载提取后逐字节比较：两个 arm64 slice 的 `LC_CODE_SIGNATURE` 位置相同，全部差异字节位于签名区域 |
| `TweakLoader.dylib`（1 条） | JB、EXP | 签名区域外仅 `LC_ID_DYLIB`（35 字节）和 `LC_UUID`（16 字节）不同。install name 分别为 `.build/d3/parity/vm-<variant>-legacy/.cfw_temp/TweakLoader.dylib` 和 `vm-<variant>-current/...`；迁移前后 `build_tweakloader` 的编译命令相同，`TEMP_DIR` 均为 `$VM_DIR/.cfw_temp`。差异来源于配对目录名 |

结论：同一恢复后磁盘、同一配置和 Manifest 输入下，迁移前后四个安装入口放置的文件集合一致；内容差异均可归因于签名、事件日志、安装时 quarantine 时间和 VM 目录路径，未发现迁移引入或遗漏的补丁、文件或阶段。此结论不覆盖客户机启动、首启脚本执行和客户机功能；fat Mach-O 与 `TweakLoader.dylib` 的逐字节分析由一次性脚本完成，未保存为回归测试。签名内容每次变化的具体机制未分析。

`d3_cfw_parity.py preflight` 原先要求 `<variant>-<side>` 目录名，与本批次实际使用的 `vm-<variant>-<side>` 不一致；已改为 `vm-<variant>-<side>` 并同步测试。在安装后的配对目录上执行该检查通过（可用空间 228 GiB）；该次运行在安装之后，不作为安装前置证据。

## 续跑环境检查

2026-09-17 在 `/Users/qcz3840/github/vphone-cli` 续跑时，上一主机位于 `.build/d3/parity` 的配对磁盘、运行副本和日志不存在；当前主机没有 D3 批次进程。当前主机保留两份 26.1 / 23B85 IPSW 缓存，但三个现有 VM 均无 Restore 输入，其中 `vm-2607` 正在运行。数据卷可用空间为 38 GiB，低于上一批次采用的 80 GiB 前置阈值。本轮未创建磁盘副本、未重新恢复、未执行 CFW 安装，也未修改三个现有 VM。配对磁盘完整产物比较仍无结论。

[卷清单脚本](d3_cfw_parity.py) 新增 `preflight` 子命令。该检查要求 regular、dev、JB、EXP 各有 `legacy`/`current` 配对目录，核对配置和两份 Manifest 的大小与 SHA-256，拒绝符号链接磁盘、活动固件事务、socket、打开的磁盘、根目录下的残留挂载和低于阈值的可用空间。检查结果写入新的 JSON 文件，拒绝覆盖已有证据。准备好配对目录后先执行：

```sh
python3 research/d3_cfw_parity.py preflight /path/to/parity \
  --minimum-free-gib 80 --output /path/to/preflight.json
```

该检查不替代管理员环境中的八次安装和三卷只读扫描；它只固化续跑前置条件。

上述续跑检查记录的是另一主机的状态。原主机 `/Users/kolar/github/vphone-cli` 上的批次已完成，结果见“同输入迁移对照结果”。

## 清理

2026-09-17 D3 关闭后，删除前复核 `.build/d3` 下无挂载、无 `hdiutil` 附加镜像、磁盘无打开句柄、无活动固件事务和 socket。已删除：8 个配对 VM、`parity/base`、8 份 `*.inventory.json`、`vm-baseline`、`vm-dev`、`vm-jb`，以及 `vm-regular`、`vm-exp` 的 `.firmware-history`。数据卷可用空间从 228 GiB 增至 314 GiB（增加 85 GiB）；`du` 统计值较大，差值来自 APFS 克隆共享块。

保留：`parity/` 下的安装日志、比较结果、配对输入清单、`legacy-source` 与 `legacy-runtime`，以及 `vm-regular`、`vm-exp`（已安装 CFW 的磁盘与 Restore 输入，供 F1/D4 复用；两者未启动验证，也不再有固件事务回滚备份）。分类文件中记录的清单 SHA-256 已无对应本地文件，需要时可从新的配对安装重新生成。
