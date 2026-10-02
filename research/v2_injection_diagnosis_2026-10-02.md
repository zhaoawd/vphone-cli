# v2 R4 注入诊断与用户态修正候选

日期：2026-10-02。对象：`/Users/kolar/vphone-v2-accept-20261002/VMs/lp-v2-accept-20261002`；基线 `4a36dcc`。用户同意先诊断原因，再评估新增补丁。未新增内核、TXM、DSC 或 MIS 补丁。

## 复现与观察范围

只读反馈脚本 `scripts/diagnostics/check_v2_injection.py` 调用 environment status 和 processes.list，断言 load.source 为 environment.loaded、扫描完整、pid 1 映射当前 launchdhook，以及运行中的所有 cameracaptured 映射当前 SystemHook。

命令：

```sh
.venv/bin/python3 scripts/diagnostics/check_v2_injection.py \
  --cli /private/tmp/vphone-v2-build-20261002/.build/vphone-cli.app/Contents/MacOS/vphone-cli \
  --library /Users/kolar/vphone-v2-accept-20261002/VMs \
  --vm lp-v2-accept-20261002 \
  --components /private/tmp/vphone-v2-build-20261002/.build/guest-components-v2/stage
```

修改前连续执行两次均退出 1，耗时约 0.1 秒。输出 passed:false；cameracaptured PID 70 不在 SystemHook_current_pids 中。两次扫描完整、uninspected 空。这是相机服务加载的反馈信号，不替代相机功能或全部 App 验收。

重新启动并等待后的诊断发现多个 App/扩展进程已映射 SystemHook、libcamfix、libvlocation。第一次报告中的 282 个进程无 SystemHook 映射，是当时的快照；不能推广为 App 持续不允许注入。后续扫描 340 个进程，SystemHook_current_pids 有 8 个，但仍不包含 PID 70。后续 launchdhook-spawn.log 存在，包含 Weather、Home、Camera 等扩展的 inserted 记录。

## 假设与证据

测试前向用户列出四项待验证假设：目标筛选遗漏；未插桩启动函数；安全模式变量；启动时序。

| 问题 | 证据 | 结论范围 |
| --- | --- | --- |
| 未插桩 posix_spawnp | launchdhook 插桩表仅有 posix_spawn；实际客户机 launchd 导入两者，otool 反汇编有三处 posix_spawnp 调用。插桩表边界测试报 launchdhook does not interpose posix_spawnp | 已确认代码遗漏与实际调用入口存在；未用运行时断点追踪 cameracaptured 的具体调用 |
| 直接相机路径未纳入目标 | 实际 com.apple.cameracaptured.plist 的 ProgramArguments 为 /usr/libexec/cameracaptured；vpSpawn 筛选仅覆盖 xpcproxy、bootstrap、特定 App 路径。真实函数调用测试报 SystemHook missing from forwarded spawn environment | 已确认该路径经 vpSpawn 也不会注入 |
| 安全模式 | 相机服务 plist 无 EnvironmentVariables；App 实际已插入。候选测试覆盖 DISABLE_TWEAKS、_SafeMode、_MSSafeMode | 没有证据支持全局安全模式导致全部注入失败；未读取进程继承环境 |
| 启动时序 | 后续 App 有映射及 inserted 记录 | 解释早期快照与后续 App 结果差异；不证明 cameracaptured 的遗漏由时序造成 |

实际 launchd SHA-256 与反汇编保存在诊断证据目录。静态调用地址：0x100027c7c、0x100048274、0x100048fcc 调用 posix_spawnp；0x100046860 调用 posix_spawn，后一处传入 /sbin/launchd。地址只作为这份二进制的证据，不进入运行时逻辑。llvm-objdump 拒绝该二进制的节布局，Apple otool 成功反汇编；未修改二进制以绕过工具校验。

## 候选修正

launchdhook 新增 posix_spawnp 插桩；两种入口共用原目标选择和环境合并逻辑，将精确 /usr/libexec/cameracaptured 路径纳入目标。保留原 App/bootstrap 范围和安全模式规则。SystemHook、环境库、API 守护进程及经典守护进程源码不改。输入清单保留 upstream_sha256，记录 launchdhook 的 local_sha256 与修改来源。

宿主 harness 编译真实 launchdhook 源码，只将 interpose 节名改为测试节以避免宿主实际插桩，并将原 spawn 被调用函数替换成观察边界。实际 vpSpawn 和插桩表不替换。修改前 4 项中 2 项失败；修改后通过。只修改 camera 筛选的隔离探针使直接 camera 用例通过，未安装到客户机。

完整定向测试 12 项通过：两种 spawn 入口、直接相机路径、App、安全模式、无关守护进程及输入清单一致性。真实调用后仍只转发一次 spawn。`make test_python` 590 项，150.074 秒，退出 0。最终源码再次执行 12 项定向测试通过。独立 `make guest_components_build` 成功，签名、架构、部署版本、输入清单校验通过。Swift 代码未改，本批未重复完整 Swift 测试。客户机原复现尚未变绿，候选仍未安装。

实际 launchd SHA-256：`33191ad183a67a1bcbd5176cbef0a8340b86442db34b3eefb755dffd6da63d4c`。原始证据及文件摘要保存在 `research/artifacts/v2-injection-diagnosis-20261002/`（Git 忽略）。

新候选 launchdhook SHA-256：`157beaed8168fa53df58cdcf2d6181152bb4a5409a7ec1b093af21c394073027`；旧客户机 SHA-256：`aa3033827565032bc5ea39c659373b3cca95cf1223cbf038ac1f260be2c70f6a`。其余四个环境库摘要与已安装客户机相同。候选未安装、未激活。

## 真实验证限制及待批准范围

源代码缺口已由测试确认；真实失败是否由这两项完全解释，需安装候选并重启后重跑原反馈脚本。尚未建立该 VM 的修复成功结论。

建议仅批准对上述测试 VM 执行 T16 停机替换，候选目录 `/private/tmp/vphone-v2-build-20261002/.build/guest-components-v2/stage`。先 --check，要求 offline_update 且 replace 仅 launchdhook-vphone.dylib；若不符则停止。随后运行 cfw update-environment（T15 副本事务），保留旧盘；重启同一 VM，重跑反馈脚本和 R4，读取日志并停机。不删除数据，不新增内核补丁，不执行 R5–R9、B6/B7 或 T18/T19。

当前诊断测试 VM 已停止，旧库仍在客户机，等待这次写入与重启的批准。

替换命令（等待批准）：

```sh
VPHONE_ROOT=/Users/kolar/vphone-v2-accept-20261002 \
VPHONE_PYTHON=/Users/kolar/github/vphone-cli/.venv/bin/python3 \
/private/tmp/vphone-v2-build-20261002/.build/vphone-cli.app/Contents/MacOS/vphone-cli \
  cfw update-environment lp-v2-accept-20261002 \
  --library-root /Users/kolar/vphone-v2-accept-20261002/VMs \
  --project-root /private/tmp/vphone-v2-build-20261002 \
  --components /private/tmp/vphone-v2-build-20261002/.build/guest-components-v2/stage \
  --root-popup
```

先使用同一命令加 --check 确认 replace 范围，再执行写入。旧库 5 项已存在，符合 T16 的只替换策略，不重装 CFW、不修改 launchd 的加载命令。

## 获批真实验证进度

用户批准上述单库 T16 替换及重启复核。先执行 --check，报告 offline_update、replace 仅 launchdhook-vphone.dylib、disk.unchanged true；随后执行普通用户 CLI 的 --root-popup 更新入口，日志 `/tmp/vphone-v2-fix-update.log`。更新正在运行。

## 获批真实验证结果

2026-10-02，用户批准后执行同一候选的 T16 替换。事务 `20261002T064301Z-rFaRcKXJ` status published；environment-update.json result replaced、replaced 仅 launchdhook-vphone.dylib、after.classification already_current、identity_unchanged true。更新前后、重启前核对七项身份文件 SHA-256 均相同（检查点、SHSH、config.plist、nvram.bin、restore-info.json、SEPStorage、udid-prediction.txt）。旧 Disk.img 保留在该归档中。

重启后原 `check_v2_injection.py` 连续两次退出 0，passed:true；pid 1 映射当前 launchdhook，cameracaptured PID 70 映射当前 SystemHook 和 libvcamcaptured；load.source environment.loaded、complete true、uninspected 空。完整环境状态为 already_current，5 个文件均 matches_candidate true。真实 App 路径 /Applications/Setup.app/Setup、/Applications/PosterBoard.app/PosterBoard、/Applications/MomentsUIService.app/MomentsUIService 与多个扩展进程映射 SystemHook，相关 App 的 libcamfix、libvlocation 也有映射。

日志新增 `event=inserted child=70 path=/usr/libexec/xpcproxy status=0`，SystemHook 日志有 `pid=70 path=/usr/libexec/xpcproxy label=com.apple.cameracaptured root=<absent>`。这说明本次相机服务经 xpcproxy 进入 SystemHook。结合实际 launchd 的 spawnp 调用、本地插桩表遗漏、边界回归以及单个 launchdhook 替换后原失败消失，证据支持本次未加载的原因是缺少 posix_spawnp 插桩。直接 cameracaptured 路径的筛选缺口是独立确认的代码问题；本次日志未单独验证该路径。

未添加内核补丁即可在本次 regular 26.1 组合满足 R4 加载判定，不再以本次失败作为 D6 内核不足证据。结论不推广到其他固件、所有进程或定位/相机功能。`application.state: not_verified` 仍保留；没有执行 R5 合约回归或 T17 在线更新。

已执行 vm stop，返回 stopped；仅操作获批测试 VM，候选、旧盘及事务均保留。证据新增至 `research/artifacts/v2-injection-diagnosis-20261002/`，fixed-summary.json 与 evidence-sha256.json 可用于复核。
