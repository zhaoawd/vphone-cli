# v2 客户机环境：设计与分批实施计划

日期：2026-10-01。基线提交 `6c7e7f9`。本文只含设计与计划，不含产品代码。没有运行或修改任何 VM，没有读写 `~/.vphone/VMs`、`~/vphone-b4-accept`、`/Volumes/vphone-t03-restore`，没有对 `vm-2607`、`vm-new` 执行命令，没有使用 sudo，没有联网。

上游指 `upstream-2.2.3`，源码以 `git show upstream-2.2.3:<path>` 读取。“上游安装器”指 `VPhoneExecutable/VPhoneCommand/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstaller.swift`。本地行号为 `6c7e7f9` 的位置。每条结论标注“事实”（读源码或既有记录）、“推断”（由事实推出，未运行验证）或“待验证假设”。

## 0. 需要用户决定的事项（摘要）

完整说明见第 9 节。

| # | 问题 | 本文建议 |
| --- | --- | --- |
| D1 | v2 环境的首个变体 | 只开放 `regular`；`dev` 在 regular 真实验收后再开放；jb/exp/less 拒绝 |
| D2 | 记录方式 | 新增与 variant 正交的 `guest_environment`（`classic`/`v2`），不新增 variant 值 |
| D3 | API 守护进程 | v2 VM 以离线安装方式并行运行 API 守护进程；需修改本地 daemon 的缓存路径并关闭其 1338 相机监听 |
| D4 | 相机库 | v2 profile 仍安装 5 个库（含与本地 classic 相机 ABI 不兼容的候选相机库），在验收中单列相机为“不提供” |
| D5 | 已有 VM 的迁移入口 | 推迟到 B6，并且只在命令自建的克隆上执行 |
| D6 | regular 内核补丁不足时的处理 | 先做 R4 验收；若 `/vh` 或 `DYLD_INSERT_LIBRARIES` 在 regular 上不生效，再由用户在三个方案中选择（第 9 节） |

## 1. 已确认事实

### 1.1 本地现状

- 本地 regular/dev/jb/exp 的 CFW 都不在 `/usr/lib` 放置 5 个环境库，也不建 `/vh` 与 launchd 的 `/vh` 加载命令（`research/t16_offline_update_eligibility_2026-10-01.md` 2.2 节）。真实 VM `lp-b4-accept2`（regular）判定为 `full_migration_required`、`bootstrap.kind: none`（同文第 10 节）。
- regular 不修改 `/sbin/launchd`。`cfw_install.sh` 的 7 步为 Cryptex、seputil、GPU driver、iosbinpack64、launchd_cache_loader、mobileactivationd、LaunchDaemons（`scripts/cfw_install.sh:110-421`）。dev 增加 launchd jetsam 补丁，不注入加载命令（`scripts/cfw_install_dev.sh:158-175`）。jb/exp 对 launchd 做 jetsam 补丁并注入 `/b`，以 `ldid -e` 取出原 entitlements 后用 `ldid -S<ents> -M -K signcert.p12` 重签（`scripts/cfw_install_jb.sh:165-206`；`scripts/cfw_install_exp.sh:326-369`），`/b` 为 BaseBin `launchdhook.dylib` 的副本（`cfw_install_jb.sh:347-353`）。
- `cfw.py inject-dylib` 调用 `insert_dylib --weak --inplace --all-yes`，即加入 `LC_LOAD_WEAK_DYLIB`（`scripts/patchers/cfw.py:311-329`）。
- launchd.plist：各变体在缺少时创建 `System/Library/xpc/launchd.plist.bak`，再由 `.bak` 重建并用 `cfw.py inject-daemons` 注入固定名单（`bash`、`dropbear`、`trollvnc`、`vphoned`、`rpcserver_ios`）的 plist，键为 `/System/Library/LaunchDaemons/<name>.plist`（`cfw_install.sh:410-421`；`scripts/patchers/cfw_daemons.py:47-70`）。jb 另把 `com.vphone.jb-setup` 直接注入当前 launchd.plist（`cfw_install_jb.sh:409-424`）。
- 宿主驱动 `scripts/cfw_install_host.sh`：install 模式按 variant 选择脚本（`:66-72`），在 T15 暂存副本上运行（`:380-397`），变体脚本自行挂载并在结束时卸载 `MNT1`（`cfw_install.sh:425-429`），随后翻转快照（`:409-412`）并发布（`:415`）。T15 记录与旧盘存于 `.cfw-history/<id>/`。
- guest 组件候选：`make guest_components_build` 产出 `.build/guest-components-v2/stage`，5 个环境库与 GPU compiler plugin 均以 `codesign --force --sign -` 做 ad-hoc 签名（`sources/VPhoneGuestComponents/Makefile:88-121`），`manifest.json` 记录 `activated:false`、`camera_header_bytes: 64`、`compatible_with_classic_camera: false`（`scripts/check_guest_components.py:57-63`）。源码固定在上游 2.0.8（`sources/VPhoneGuestComponents/README.md`）。
- 本地 SystemHook（2.0.8 版）：`posix_spawn`/`posix_spawnp`/`execve` 只对 bootstrap 路径、含 `.app/` 的路径和 `cameracaptured` 插入 SystemHook（`sources/VPhoneGuestComponents/SystemHook/SystemHook-vphone.c:40-46`）；构造函数在 `cameracaptured` 中加载 `/usr/lib/libvcamcaptured.dylib`，在 App 中加载 `/usr/lib/libvlocation.dylib`，已加载 AVFoundation 的 App 再加载 `/usr/lib/libcamfix.dylib`，并尝试 `<VPHONE_JB_ROOT 或 /var/jb>/usr/lib/TweakLoader.dylib`（`:140-211`）；名为 `vphoned`、`logd`、`notifyd`、`usermanagerd` 的进程跳过（`:190-192`）。
- 本地 launchdhook（2.0.8 版）：由 launchd 的弱加载命令载入；只对 xpcproxy、bootstrap 程序和 `/Applications`、`/var/containers/Bundle/Application` 下的 App 插入 SystemHook（`LaunchHook/launchdhook-vphone.c:39-88`）；插桩 `xpc_dictionary_get_value` 以加入 bootstrap 的 LaunchDaemons（`:224-256`）；在 PID 1 清除 jetsam 上限（`:258-271`）。
- 插入的库路径为 `DYLD_INSERT_LIBRARIES=/usr/lib/SystemHook-vphone.dylib[:<原值>]`（`Shared/InjectionEnvironment.h:8`、`:76-85`）。
- 补丁声明：`system-launchdaemons-boot-environment` 的 `variants` 为空、`coverage: .guestStep`（`sources/FirmwarePatcher/PatchSet/PatchDeclarationCatalogData.swift:898-910`）；`system-launchd-boot-jetsam_panic_guard_bypass` 为 dev/jb/exp（`:815-821`）；`system-extensions-boot-gpu_bundle` 为五变体（`:870-882`）。
- 内核补丁：`kernel-boot-amfi_trustcache`、`kernel-boot-post_validation_unsigned`、`kernel-boot-cred_label_update_execve`、`kernel-boot-load_dylinker`、`kernel-boot-proc_security_policy` 等 32 项（含 Frida 2 项）只属于 jb/exp；regular/dev 有 `txm-boot-trustcache_bypass`、`kernel-boot-dyld_policy`、`kernel-boot-launch_constraints`（`PatchDeclarationCatalogData.swift` 中各声明的 `variants`）。

### 1.2 上游 2.2.3 的 v2 环境

- 安装顺序（上游安装器 `installMounted`，`:523-665`）：`system-vphoned-boot-install` → `installVphoned`（`:642-644`）；`system-launchdaemons-boot-environment` → `installEnvironment`（`:645-647`）；`system-launchd-boot-jetsam_panic_guard_bypass` → 对 `sbin/launchd` 执行 `patch-launchd-jetsam`、`inject-dylib /vh`，保留并合并原 entitlements 后重签（`:648-657`、`:1060-1092`）；随后无条件执行 `restoreMISFixTargets`（`:658`、`:927-940`）。`/vh` 加载命令属于 jetsam 补丁 ID，不属于 environment ID。
- `installEnvironment`（`:896-905`）：把 `VPhoneGuestEnvironment.libraries` 复制到 `/usr/lib/<name>`（0755、root:wheel）；建 `/vh` → `/usr/lib/launchdhook-vphone.dylib`，`/vh` 已被他物占用时报错（`:909-917`）；只在缺失时写 `usr/lib/libmisfix.plist`（`:947-956`）。注释说明 `/vh` 与旧 `/b` 同样占用 32 字节加载命令（`:901-902`）。
- 库清单：launchdhook、SystemHook、libvcamcaptured、libcamfix、libmisfix（`VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestEnvironment.swift:9-15`）。
- `installVphoned`（`:855-879`）：把 API 守护进程装到 `/usr/bin/vphoned`，plist 装到 `System/Library/LaunchDaemons/vphoned.plist`，缺少时建 `launchd.plist.bak`，由 `.bak` 重建 launchd.plist 并注入单个守护进程。上游没有 1337 经典守护进程。API 守护进程监听 vsock 1339（`VPhoneDaemon/Daemon/main.swift:88`）。
- 上游预设 `standard` 只排除 15 项（Frida 2 项、hv_vmm 3 项、DeviceTree/Preboot 身份 9 项、`dyld-exp-mis_trust_auth`；`patches_presets/standard.plist:100-117`），包含 `com.vphone.patchset.kernel.cfw` 的全部补丁，例如 `kernel-boot-amfi_trustcache`、`kernel-boot-proc_security_policy`（`FirmwarePatcher/PatchSets/FirmwareKernelCustomFirmwarePatchSet.swift:29-259`）。
- 上游 2.2.3 的注入（`Shared/InjectionEnvironment.h`）：`VP_MIS_FIX` 为 `/usr/lib/libmisfix.dylib`（`:15`）；`vpIsMISFixTarget` 按路径后缀匹配 installd、misagent、lockdownd、remoted、SpringBoard（`:47-55`）；`vpMISFixFor` 只在该文件可读时返回它（`:60-62`）。launchdhook 对除 `/sbin/launchd` 外的每个 spawn 插入 SystemHook，并对 MIS 目标加入 libmisfix（`LaunchHook/launchdhook-vphone.c:77-108`）。上游注释说明 SpringBoard 由 launchd 直接启动，不经 xpcproxy。
- 上游没有 `/b` 与 BaseBin 的安装代码；bootstrap 由 API 守护进程在客户机内安装（Irisin）。

### 1.3 两个守护进程

- 经典 vphoned：vsock 1337（`scripts/vphoned/vphoned.m:64`），安装路径 `/usr/bin/vphoned`，缓存 `/var/root/Library/Caches/vphoned`（`:81-82`）；启动时若从安装路径运行且缓存可执行即 exec 缓存，不校验（`:640-649`）；宿主在握手时按哈希推送新二进制（`sources/vphone-cli/VPhoneControl.swift:278-282`、`:341-380`）。
- API 守护进程候选：vsock 1339（`sources/VPhoneDaemon/Daemon/main.swift:84`）；启动时同时启动相机监听（`main.swift:16`，vsock 1338，`Native/vphoned_vcam.m:344-356`）。缓存、标记、待定标记为 `/var/root/Library/Caches/vphoned`、`vphoned.api-v2`、`vphoned.api-v2.pending`（`Native/vphoned_native.m:11-14`；`Native/vphoned_proxy.c:20`）；`agent.apply_update` 写同一缓存路径（`Daemon/GuestAPI.swift:343-359`）。launchd 标签与程序与经典相同：`com.vphone.vphoned`、`/usr/bin/vphoned`（`Configuration/vphoned.plist`）。构建产物在 `.build/daemon-api-v2/candidate`，以 ldid 签名（`scripts/build_daemon_api.sh`），任何安装流程都不使用它（`research/p2_daemon_api_integration_2026-09-28.md`）。
- 经典相机监听也在 1338（`scripts/vphoned/vphoned_vcam.h:29`）。bind 失败时该线程记录日志并结束（`Native/vphoned_vcam.m:350-356`）。推断：两个守护进程同时运行时，先启动者占用 1338。
- 经典相机共享内存在 `/var/jb/var/mobile/Library/vphone-vcam-frame.shm`（`scripts/vphoned/vphoned_vcam.h:24-27`），头部 256 字节；候选相机库使用 `/var/mobile/Media/SimulatedCamera`（`VCamCaptured/VCamFrameProtocol.h:9`），头部 64 字节。

### 1.4 2026-10-01 真实环境发现（主会话记录，本文未复核）

- regular 客户机（`lp-b4-accept2` 的克隆）的经典 vphoned 不声明 `shell`：`vphoned.m:534` 只在 `vp_shell_path()` 找到 `/bin/sh` 或 `/var/jb/bin/sh` 时声明（`scripts/vphoned/vphoned_shell.m:27-33`）。请求返回 `guest does not support capability: shell`。T17 方案 B（经典 `file_put` + `shell` 启动候选）在 regular 上不可用。
- exp 客户机（`rig-baseline` 的克隆 `rig-t17-accept`，shell 为 `/var/jb/bin/sh`）：经典 `file_put` 上传候选 `vphoned` 到 `/var/root/vphoned-api/vphoned`（客户机内 SHA-256 与宿主一致，`96aea4406824ac52…`）和改标签的 plist 后，`launchctl bootstrap system <plist>` 与 `launchctl load <plist>` 都返回 `Service cannot load in requested session`，服务未注册，候选未运行。原因未查明。
- 宿主的自动权限检查拒绝“在客户机内以 launchd 加载候选守护进程”。
- 结论（用于设计）：API 守护进程的激活必须是离线安装的一部分（系统卷 LaunchDaemons + launchd.plist 注入），不依赖运行时从 `/var/root` 热加载。已有依据：经典 vphoned 以同一方式（`cfw_install.sh:407-421`）注入后在现有 VM 中运行（`research/t17_online_update_activation_2026-10-01.md` 第 2 节）。

## 2. 问题 1：v2 环境的组成与来源

### 2.1 组成清单（本地 v2 profile）

| 项 | 客户机路径 | 来源 | 签名 | 属主/权限 | 本文范围 |
| --- | --- | --- | --- | --- | --- |
| launchdhook | `/usr/lib/launchdhook-vphone.dylib` | `.build/guest-components-v2/stage/launchhook/` | 候选 ad-hoc 签名，不重签 | root:wheel 0755 | 安装 |
| SystemHook | `/usr/lib/SystemHook-vphone.dylib` | `stage/systemhook/` | 同上 | 同上 | 安装 |
| libvcamcaptured | `/usr/lib/libvcamcaptured.dylib` | `stage/vcamcaptured/` | 同上 | 同上 | 安装（见 D4） |
| libcamfix | `/usr/lib/libcamfix.dylib` | `stage/camfix/` | 同上 | 同上 | 安装（见 D4） |
| libvlocation | `/usr/lib/libvlocation.dylib` | `stage/locationfix/` | 同上 | 同上 | 安装 |
| 加载别名 | `/vh` → `/usr/lib/launchdhook-vphone.dylib` | 符号链接 | — | root:wheel | 安装 |
| launchd 加载命令 | `/sbin/launchd` 的 `LC_LOAD_WEAK_DYLIB /vh` | `cfw.py inject-dylib`（`insert_dylib --weak`） | `ldid -S<原 entitlements> -M -K signcert.p12`，与 jb 相同 | root:wheel 0755 | 安装；缺少时先建 `/sbin/launchd.bak` |
| API 守护进程 | `/usr/bin/vphoned-api` | `.build/daemon-api-v2/candidate/vphoned`（B2 修改后） | 候选 ldid 签名与 entitlements，不重签 | root:wheel 0755 | 安装 |
| API 守护进程 plist | `/System/Library/LaunchDaemons/vphoned-api.plist`，并注入 launchd.plist 键 `/System/Library/LaunchDaemons/vphoned-api.plist` | B2 新增 `Configuration/vphoned-api.plist` | — | root:wheel 0644 | 安装 |
| 经典 vphoned | `/usr/bin/vphoned`、`vphoned.plist` | 变体脚本原样安装 | 不变 | 不变 | 不改 |
| libmisfix | `/usr/lib/libmisfix.dylib` | T18 | — | — | 只预留（第 5 节） |
| libmisfix.plist | `/usr/lib/libmisfix.plist` | T18 | — | 0644，仅缺失时写入 | 只预留 |
| GPU compiler plugin | — | `stage/gpu/` | — | — | 不安装（第 6 节） |

清单来源：继续以 `scripts/guest_environment.json` 为唯一来源。新增可选段（`schema_version` 保持 1，现有读取方忽略未知键：Python `json`，Swift 宿主只检查 `schema_version == 1` 与已有字段，`sources/vphone-cli/VPhoneGuestEnvironment.swift:24-39`）：

- `profiles.v2.variants`：`["regular"]`（D1）。
- `profiles.v2.api_daemon`：`label`、`program`、`plist`、`launchd_key`、`cache`、`marker`、`pending`、`vcam`（`off`）。
- `profiles.v2.reserved`：`libmisfix.dylib`、`libmisfix.plist`，`task: T18`，`install: false`。
- `profiles.v2.launchd`：`backup: sbin/launchd.bak`，`load_command: /vh`，`sign: ldid-preserve-entitlements`。

库字节：安装器写入的字节就是 stage 中经 `manifest.json` 核对的字节，与 T16 判定和 T17 在线更新使用的候选相同。因此新建后的 T16 判定应为 `already_current`（推断，B3 测试覆盖，真实验收 R6 复核）。

### 2.2 与五变体的关系

| 变体 | v2 | 依据 |
| --- | --- | --- |
| regular | 显式 opt-in（D1 首个开放） | 默认变体；`lp-b4-accept2` 为 regular；launchd 未被其他加载命令占用 |
| dev | 暂不开放；regular 验收后再开放 | 内核补丁集合与 regular 相同；launchd 已有 jetsam 补丁，加 `/vh` 需与 `cfw_install_dev.sh:158-175` 的重签方式合并 |
| jb、exp | 拒绝 | launchd 已注入 `/b`。T16 规则把 `/b` 与 `/vh` 同时存在判为 `unknown`（`scripts/cfw_env_update.py:339-353`）。两个 launchdhook 都插桩 `posix_spawn`，SystemHook 与 BaseBin 的 TweakLoader 加载链会重叠（推断）。用户决定不无条件替换 `/b`；共存方案归 P6/T21 |
| less | 拒绝 | 无 CFW 阶段（`VPhoneCreateCheckpoint.swift:23-32`），T16 判为 `not_applicable` |

opt-in 形式（D2）：新增与 variant 正交的选项 `--guest-environment classic|v2`，默认 `classic`。不新增 variant 值，原因：

1. variant 值进入补丁声明、固件流水线、`device(forVariant:)` 与 6 处校验列表（`VPhoneCreateCheckpoint.swift:410`、`VPhoneCLI.swift:149-154`、`VPhoneRestoreCLI.swift:139-140`、`cfw_install_host.sh:66-72`、`PatchDeclarationCatalogData.swift`、`FirmwarePipeline.Variant`）。新值需要逐处定义补丁与设备语义。
2. v2 环境只改变 CFW 阶段写入的客户机文件，不改变固件补丁、恢复与设备身份。

记录位置：

- `restore-info.json` 增加可选字段 `guest_environment`（缺省表示 `classic`）。由 CFW 阶段成功后与 variant 一起写入（`VPhoneCreateOrchestrator.swift:1029-1043` 的 `recordCFWVariant` 扩展）。
- 检查点 `effective_options` 增加可选字段 `guest_environment`，值为 `classic` 时不编码，保持历史检查点的 `inputs_digest` 不变（与 `restoreBackend` 的做法相同，`VPhoneCreateCheckpoint.swift:110-115`、`:131-132`）。`changes(to:)`（`:140`）把它映射到最早受影响的阶段 `cfw`。

T16 判定规则的配套修改（B1）：

- 事实：`variant_records` 从检查点顶层读 `variant`（`cfw_env_update.py:223-231`），而检查点把 variant 存在 `effective_options` 下（`VPhoneCreateCheckpoint.swift:100-101`）。推断：检查点来源当前总是 `None`。B1 改为读 `effective_options.variant` 与 `effective_options.guest_environment`。
- `bootstrap.kind == v2` 且记录的 `guest_environment == v2`：不再产生“classic variant”原因（现规则 `:366-370`）。
- 记录为 `v2` 但磁盘为 `none` 或 `classic`：`full_migration_required`，原因写明记录与磁盘不一致。
- `/b` 与 `/vh` 同时存在仍为 `unknown`。
- 新增 `daemon` 段（API 守护进程的路径、摘要、launchd.plist 键是否存在），只进入 `notes`，不改变分类。停机更新仍只替换 5 个库（T16 设计决定 3）。

### 2.3 与 `/b` 的关系

本设计不在 jb/exp 上安装 v2 环境，不读写、不删除、不替换 `/b`。安装器在检测到 `/b` 加载命令或 `/b` 别名时拒绝（退出 3），不做部分安装。jb/exp 的 v2 共存方案需要先确认：两个 launchdhook 的 `posix_spawn` 插桩顺序、`xpc_dictionary_get_value` 插桩重复加入 bootstrap LaunchDaemons、TweakLoader 是否被加载两次。这些属于 P6/T21。

## 3. 问题 2：安装入口

### 3.1 新建 VM：CFW 阶段内的新步骤

位置：`cfw_install_host.sh` install 模式中，变体脚本子 shell（`:390-396`）结束之后、`cleanup`（`:399`）之前。不新增检查点阶段，原因：

1. 检查点校验要求阶段列表与 `VPhoneCreateStage.allCases` 完全相等（`VPhoneCreateCheckpoint.swift:415`）。新增阶段会使全部历史检查点校验失败，需要升级 `schema_version` 与阶段合同版本。
2. 同一 T15 事务中执行，变体安装与 v2 安装要么一起发布，要么都不发布；失败时原盘不变（T15）。
3. 快照翻转（`:409-412`）在两者之后执行一次。

流程：

1. Swift 传入 `--guest-environment v2`。驱动在提权前检查：只接受 install 模式；variant 必须在 `profiles.v2.variants` 中；否则退出 1，不调用任何工具。
2. 变体脚本按原样运行。
3. 新脚本 `scripts/cfw_env_install.py install --device /dev/$SYS --mount $CFW_HOST_MNT/mnt1 --components <stage> --daemon <candidate> --report $CFW_DISK_WORK/guest-environment-install.json <VM>`：
   1. 校验候选：stage `manifest.json` 摘要、普通文件、`LC_CODE_SIGNATURE`（复用 `cfw_env_update.candidates`）；API 守护进程候选 `manifest.json` 摘要与 plist 内容。
   2. 读写挂载 System 卷，先判定（复用 `assess`）：必须为 `full_migration_required` 且 `bootstrap.kind == none`，且 5 个库全部缺失、`/vh` 不存在。其他状态退出 3，不写入。
   3. 写入 5 个库（同目录临时文件 + rename，root:wheel 0755）。
   4. 建 `/vh`。
   5. launchd：缺少 `/sbin/launchd.bak` 时复制；以当前 `/sbin/launchd` 为输入（regular 未修改过它）；`ldid -e` 取 entitlements；`inject-dylib /vh`；`ldid -S<ents> -M -K <vm>/cfw_input/signcert.p12` 重签；写回。重签后核对：加载命令含 `/vh`，entitlements 与原值相同。
   6. API 守护进程：写 `/usr/bin/vphoned-api` 与 plist；用新增的单项注入命令把 plist 注入当前 `System/Library/xpc/launchd.plist`（键按 2.1 节，已存在同键时覆盖）。`launchd.plist.bak` 不变。
   7. 再判定：必须为 `already_current`；API 守护进程的文件摘要与 launchd.plist 键必须存在。否则退出 1。
   8. 卸载。报告随 T15 记录归档到 `.cfw-history/<id>/guest-environment-install.json`。
4. 后续快照翻转、发布与 T15 相同。

`/sbin/launchd` 的重签方式取 jb 的现有方式（`cfw_install_jb.sh:176-201`），不引入上游的进程内 `VPhoneSigner`。原因：本地 CFW 全部使用 ldid，签名证书来自 `cfw_input/signcert.p12`；引入新签名器属于另一项迁移（T04 范围）。

报告 `guest-environment-install.json`（schema `vphone.guest-environment-install/1`）字段：`profile`、`variant`、`manifest_sha256`、`components_manifest_sha256`、`daemon_manifest_sha256`、每个写入文件的 `path`/`before`/`after_sha256`/`mode`/`owner`、`launchd`（`before_sha256`、`after_sha256`、`load_commands_before/after`、`entitlements_sha256_before/after`）、`launchd_plist`（`key`、`before_sha256`、`after_sha256`）、`assessment_before`、`assessment_after`、`reserved`（libmisfix 两项，`state: reserved_absent`）、`result`。

检查点 evidence（`VPhoneCreateLiveStages.swift:127` 执行端、`:269-278` 校验端）增加：`guest_environment`、`guest_environment_report`（`.cfw-history` 内相对路径）、`guest_environment_report_sha256`、`guest_environment_assessment`（应为 `already_current`）、`cfw_transaction_id`。校验端在 `guest_environment == v2` 时另外检查：报告存在且摘要相符；报告 `result == installed`；`restore-info.json` 的 `guest_environment == v2`；报告中的事务 id 与 `.cfw-history/<id>/transaction.json` 的已发布事务一致。

重跑与续跑：

- `--restart-from cfw`：变体脚本从 `.bak` 重建 launchd.plist 与（dev/jb/exp）launchd。v2 步骤的前置判定在重跑时会看到 5 个库已存在。处理：前置判定接受“`/vh` 与 5 个库都等于候选且记录为 v2”的已安装状态，此时只重做 launchd 注入与 launchd.plist 注入，再做后置判定。regular 的变体脚本不改 `/sbin/launchd`，重跑时它已含 `/vh`；安装器在加载命令已存在时不再注入、不再重签，并在报告中记为 `unchanged`。
- `guest_environment` 选项在 `cfw` 已完成后改变：按 `changes(to:)` 规则要求 `--restart-from cfw` 或更早阶段。从 `v2` 改回 `classic` 时，变体脚本不删除 `/usr/lib` 中的库与 `/vh`。处理：拒绝该改变，提示新建 VM。

### 3.2 独立 `cfw install` 与保护

- `vphone-cli cfw install` 增加 `--guest-environment v2`。只在 `restore-info.json` 已记录 `guest_environment: v2` 时接受（重装同一 v2 VM）。对没有该记录的 VM 拒绝，原因：用户决定旧 bundle 不原地升级。
- 记录为 `v2` 的 VM 执行不带该选项的 `cfw install`：驱动拒绝（退出 1）。原因：变体脚本会由 `.bak` 重建 launchd.plist，去掉 API 守护进程条目，dev 还会去掉 `/vh` 加载命令，结果是 T16 的 `full_migration_required`。

### 3.3 已有 classic VM 的完整迁移（T16 `full_migration_required` 的去向）

本设计提供入口，但排在 B6，并需 D5 决定。规则：

- 命令：`vphone-cli cfw migrate-environment <source> <new-name> [--library-root R] [--root-popup]`。
- 源 VM 只读：以 T16 提权只读检查判定，必须为 `full_migration_required`、`bootstrap.kind == none`、记录 variant 在 `profiles.v2.variants` 中、`guest_environment` 未记录。
- 命令自行调用 `VPhoneBundleOps.clone`（`vm clone` 的实现，`sources/vphone-cli/VPhoneVMTransferCLI.swift:7-26`）生成新 bundle，在新 bundle 中写 `.guest-environment-migration.json`（源名称、源 `Disk.img` 身份、源判定报告摘要）。
- 在新 bundle 上以驱动新模式 `--install-environment v2` 运行 T15 事务：只执行 3.1 节第 3 步，不运行变体脚本，不翻转快照（与 T16 `--update-environment` 相同，`cfw_install_host.sh:409-412`）。
- 成功后在新 bundle 的 `restore-info.json` 写 `guest_environment: v2` 与 `migrated_from`。源 bundle 不写任何文件。
- 不接受用户自行指定的已有 bundle 作为迁移目标。这样“旧 bundle 不原地升级”只由命令自建的克隆满足。
- 克隆保留源 VM 的设备身份（`VPhoneVMTransferCLI.swift:11-14`）。两者同时运行的影响与现有 `vm clone` 相同，本设计不改变。

`cfw update-environment` 对 `full_migration_required` 的输出（`cfw_env_update.py:382-388` 的 `migration` 文本）在 B5 后改为：新建 `--guest-environment v2` 的 VM；B6 后增加迁移命令。

### 3.4 写盘

所有写盘只经 T15 事务：暂存副本、四点复核、排他发布、旧盘保留在 `.cfw-history/<id>/Disk.img`。安装器只在暂存副本的挂载点上写入，路径必须在 VM 目录内（与 `cfw_env_update.apply` 相同的检查，`:694-701`）。

## 4. 问题 3：守护进程

### 4.1 关系：v2 VM 中并行

| 方案 | 结果 | 结论 |
| --- | --- | --- |
| 替代（API 守护进程装为 `/usr/bin/vphoned`） | 1337 消失。宿主默认路由全部走 1337（下表），触控、`location_owned`、相机回执、shell、经典文件传输、宿主暂停均失效 | 不采用，待 P5 补齐合约后再评估 |
| 只保留经典 | T17 在线更新与 `environment.loaded` 不可用；`guest rpc` 遗留验收无法完成 | 不采用 |
| 按变体选择 | 每个变体只有一个守护进程，同样丢失其中一方的功能 | 不采用 |
| 并行（建议） | 经典 1337 保留本地合约；API 1339 提供 `environment.*` 与 `rpc` | 采用，仅限 v2 profile |

classic VM 不安装 API 守护进程，行为不变。

### 4.2 冲突与解决

| 冲突项 | 现状（事实） | 解决（B2） |
| --- | --- | --- |
| launchd 标签 | 都是 `com.vphone.vphoned` | API 改为 `com.vphone.vphoned.api` |
| 程序路径 | 都是 `/usr/bin/vphoned` | API 改为 `/usr/bin/vphoned-api` |
| plist 与 launchd.plist 键 | 都是 `vphoned.plist` | API 用 `vphoned-api.plist` 与对应键 |
| 缓存二进制 | 同一 `/var/root/Library/Caches/vphoned`。经典启动时 exec 该路径且不校验 | API 改为 `/var/root/Library/Caches/vphoned-api`、`vphoned-api.api-v2`、`vphoned-api.api-v2.pending`（`vphoned_native.m:11-14`、`vphoned_proxy.c:20`、`GuestAPI.swift:345`、`:355`）。宿主继续阻止 `agent.apply_update`（`VPhoneHostRPC.swift:75-82`） |
| vsock 1338 相机监听 | 两者启动时都绑定 | API 在 v2 profile 中不启动相机监听：plist `EnvironmentVariables` 设 `VPHONED_VCAM=off`，`main.swift:16` 前判断。不使用命令行参数，原因：`vp_native_process_mode` 依据参数区分 proxy 与 worker（`main.swift:8-13`），新增参数的影响未核对 |
| 进程名 | SystemHook 只跳过名为 `vphoned` 的进程（`SystemHook-vphone.c:190`） | `/usr/bin/vphoned-api` 不是 App、bootstrap 或 `cameracaptured` 路径，SystemHook 不在其中加载库（`:193-198`）。推断：不需要加入跳过名单 |
| 日志 | 都写 `/var/log/vphoned.log`（API plist） | API 改为 `/var/log/vphoned-api.log` |

API 守护进程的 `GuestIrisinInstaller.refreshBootstrapOnStartup()`（`main.swift:17`）只在存在已完成的 Irisin bootstrap 记录时动作（`GuestIrisinInstaller.swift:409-423`）。regular 没有该记录（推断）。

### 4.3 本地控制合约在 API 守护进程上的对应

宿主路由（事实）：`VPhoneHostCommandExecutor` 默认把所有命令发往 1337 或宿主 VZ；`transport:"api"` 只覆盖 `app_list`、`app_foreground`、`app_launch`、`app_terminate`、`file_get`、`file_put`（`sources/vphone-cli/VPhoneHostAPICommands.swift:18`）；`rpc` 与 `environment_*` 只走 1339；两者之间没有自动回退。唯一的隐式转发是非硬件名称的 `key` 在有 API 会话时转为 `input.key`。

| 本地合约 | 经典 1337 | API 1339 | 缺口 |
| --- | --- | --- | --- |
| 握手、版本、自更新 | hello + caps（`vphoned.m:466-563`）；`update`（`:571-587`） | `/v1/health`；`agent.apply_update`（宿主阻止） | API 自更新不接入宿主（保持） |
| 触控 | `touch`，整数阶段、`edge`（`vphoned.m:255-261`），caps `touch`、`touch_edge` | `input.touch`（字符串阶段，无 edge，宿主 rpc 阻止）；`input.tap/swipe/touch_sequence` | 无 edge 标志；整次手势路由与 1337 的串行关系未验证（T23） |
| 硬件键 | `hid`（`:243`） | `input.hid`、`input.button`、`input.key` | 宿主禁止 rpc `down` |
| `location_owned` | `location_source_begin`、带 `generation` 与 `delivery_sequence` 的 `location`、`location_stop`（`:300-362`） | 无；`location.set/clear` 无 owner/generation/sequence（`GuestLocationSimulation.swift:29-54`），宿主 rpc 阻止 | 缺失（T20） |
| 相机回执 | `vcam_status`、`vcam_receipt_v3`，256 字节头（`vphoned_vcam.h:46-66`） | 无；64 字节头，无 generation/presentation_id | 缺失（T22） |
| shell | `shell`（仅在客户机有 shell 时声明，regular 不声明） | 无 | 缺失；宿主暂停依赖经典 shell（`VPhoneControl.swift:800-820`） |
| 文件 | `file_*`（`vphoned_files.m`） | `/v1/files/content`、`files.*` | 已有 |
| App | `app_*`（`vphoned_apps.m`） | `apps.*`，含 `frontmost_verified` | 已有（显式 `transport:"api"`） |
| IPA 安装 | `ipa_install`（自定义安装器） | `apps.install`（IcliKit） | 实现不同；宿主保持经典 |
| 剪贴板、设置、钥匙串、开发者模式 | 有 | 有（超集） | — |
| 环境库 | 无 | `environment.status/install/restore/loaded` | API 独有（T17） |
| 进程、respring、服务、日志 | 无（经 shell） | `processes.*`、`system.respring`、`services.*`、`logs.*` | API 独有 |

结论：API 守护进程缺少 `location_owned`、相机回执 v3、shell、触控 edge。v2 VM 中这些仍由经典 1337 提供。regular 上 shell 两边都没有。

### 4.4 宿主侧

- v2 VM 需要以 `--api-listen` 与 `VPHONE_API_TOKEN` 启动才有 1339 会话（`sources/vphone-cli/VPhoneAPIProxyOptions.swift:12-33`、`VPhoneAppDelegate.swift:143-155`）。本设计不改变默认启动参数。
- 经典自更新继续推送 `/var/root/Library/Caches/vphoned`，不影响 API 守护进程（B2 后路径不同）。
- API 守护进程的升级：本设计不提供在线或停机替换。重新安装经 3.2 节的 `cfw install --guest-environment v2`。是否把它纳入停机更新属于后续决定（T16 第 8 节已列“是否替换 vphoned”）。

## 5. 问题 4：与 T18 的接口

本设计为 T18 预留，不实现内容：

1. 清单：`profiles.v2.reserved` 列 `libmisfix.dylib`（`/usr/lib`，0755）与 `libmisfix.plist`（`/usr/lib`，0644，`preserve_existing: true`）。安装器在报告中输出 `state: reserved_absent`，不写入。T18 把 libmisfix 从 `upstream_only` 移入 `libraries` 后，T16 判定、T17 更新与本安装器读同一清单，不需要另一份列表。
2. 配置文件规则：安装器保留“配置文件段”，规则与上游 `installMISFixDefaults` 相同：只在缺失时写入，已有文件不覆盖（上游安装器 `:947-956`）。停机与在线更新都不写配置文件（T19“环境更新不覆盖每机 UDID”）。
3. 注入点：上游 2.2.3 由 launchdhook 与 SystemHook 共同决定 MIS 目标并插入 libmisfix（`InjectionEnvironment.h:47-62`；`launchdhook-vphone.c:77-108`）。本地两个 hook 固定在 2.0.8，launchdhook 不对 SpringBoard 插入 SystemHook（本地 `launchdhook-vphone.c:39-47`、`:74-80`；SpringBoard 路径在 `/System/Library/CoreServices`）。推断：T18 需要把 launchdhook、SystemHook、`InjectionEnvironment.h` 升级到 2.2.3 的插入规则，这会改变两个库的字节。v2 VM 获得新字节的途径为 T16 停机更新或 T17 在线更新；替换 launchdhook 需要重启客户机（T17 激活规则）。
4. 条件：libmisfix 只在 v2 profile 中安装；只在 `vpMISFixFor` 判断文件可读时插入，缺文件时不插入（上游规则）。
5. 不做：`restoreMISFixTargets`（上游用于删除旧版对 installd/misagent/SpringBoard 的加载命令；本地从未写过这些加载命令）；`dyld-exp-mis_trust_auth`；MIS 守护进程重启（T17 白名单仍只有 `cameracaptured`）。
6. T18 验收依赖本设计的 R4：v2 VM 中 SystemHook 是否进入 App、`cameracaptured`、SpringBoard，以及 regular 内核是否允许插入（D6）。

## 6. 问题 5：与 T14 B 部分的取舍

| 项 | 本设计 | 理由 |
| --- | --- | --- |
| 清单 `schemaVersion = 2` | 不引入 | 本地加载器拒绝含 `schemaVersion` 的 `config.plist`（`sources/VPhoneCore/VPhoneVirtualMachineManifest.swift:182-188`）。上游 v2 清单还要求应用版本为 2.x（上游 `VPhoneVirtualMachineManifest.swift:261-266`）。引入需要扫描、启动、克隆、导入导出、Launchpad 同时支持两种格式（实施计划 P4 第 1 步）。v2 客户机环境只需要 2.2 节的 `guest_environment` 记录 |
| `machines` 库目录 | 不引入 | 改变默认库根、锁、Launchpad 与全部 CLI 的路径解析；与客户机环境无依赖 |
| GPU driver 来源（`.pcc-gpu`、临时 PCC 恢复） | 不引入 | v2 VM 继续使用 `cfw_input` 中的 GPU driver（`cfw_install.sh:315-335`），与 classic 相同。T14 §10.6 第 1–4 项未决定 |
| GPU compiler plugin | 不安装 | 上游 README 记录的缺失只涉及 cloudOS 26.4 `23E5207q` 的 bundle（T14 §10.2）；本地现有 GPU tar 的 VM 未记录黑屏。插件为未封装的 ad-hoc dylib，加载条件未验证。与环境库无依赖 |
| 补丁声明 `system-launchdaemons-boot-environment` | B1 填入 `variants: ["regular"]`，增加 `OptIn` 值 `guestEnvironmentV2`（`PatchDeclaration.swift:32-37`），`coverage` 仍为 `.guestStep` | 使 `fw plan` 显示该步骤只在 opt-in 时生效；T09 的 `uncertain` 改为“本地等价，库清单差异见 T20/T18” |
| `/vh` 与 jetsam 补丁 | 不把 jetsam 补丁加到 regular | 上游把 `/vh` 绑定在 jetsam 补丁 ID 上；本地 launchdhook 构造函数已清除 PID 1 的 jetsam 上限（`launchdhook-vphone.c:265-271`）。regular 补丁集合保持不变。代价：本地无法用一个补丁 ID 表示 `/vh`，B1 在声明中以说明字段记录 |

继续推迟的项在 T14 B 部分恢复时一并决定。本设计的 `guest_environment` 字段与上游清单字段不冲突，后续引入 `schemaVersion = 2` 时可映射。

## 7. 问题 6：验收方案

### 7.1 无 VM 测试

| 层 | 内容 | 断言 |
| --- | --- | --- |
| Python：安装器（合成目录树） | 沿用 T16 合成 Mach-O 与目录树；`ldid` 与 `insert_dylib` 用记录参数的替身，另有一项在 `.tools/bin/insert_dylib` 存在时用真实工具对 macOS 构建的测试二进制注入（不存在则跳过并说明） | 成功：只有清单文件、`/vh`、`/sbin/launchd(.bak)`、API 守护进程文件与 launchd.plist 变化；库字节等于候选；属主与权限；launchd.plist 键存在且 `.bak` 不变；后置判定 `already_current`；libmisfix 未写入。拒绝：`/b` 存在、未知加载命令、`/vh` 指向他处、库已存在但不等于候选、候选摘要不符、候选无签名、API 守护进程候选不符 → 退出 3，树不变。失败：第二个库写入报 `EIO` → 非 0，报告 `failed` |
| Python：判定规则 | 新规则 | 记录 v2 + 磁盘 v2 → 无 classic 原因；记录 v2 + 磁盘 none → `full_migration_required`；检查点 `effective_options` 中的 variant 被读出；`/b`+`/vh` 仍为 `unknown`；`daemon` 段只进 `notes` |
| Python：驱动（`HostDriverFixture`，tar 映像） | `--guest-environment v2` | 成功：发布的映像相对原映像只多出预期文件；报告归档到 `.cfw-history/<id>/`；快照翻转被调用一次。安装器失败：原盘 inode、SHA-256、mtime 不变，未发布。jb/exp/dev/less + v2：退出 1，无工具调用。记录为 v2 的 VM 不带选项：退出 1。不带选项的 regular：调用序列与修改前一致（回归） |
| Python：一致性 | `ManifestConsistencyTests` 扩展 | API 守护进程 plist 的标签、程序、日志与清单一致；daemon 源码中的缓存路径与清单一致；`InjectionEnvironment.h` 的 SystemHook 路径与清单一致 |
| 原生合成磁盘（手动脚本） | T16 原生检查的扩展：`hdiutil` 建 raw APFS 映像，普通用户读写挂载 | 安装、判定 `already_current`、再次安装被前置判定处理 |
| Swift | 检查点与 CLI | 历史检查点（无 `guest_environment`）的 `inputs_digest` 不变；`v2` 只与 regular 组合；`changes(to:)` 映射到 `cfw`；`cfwInvocation` 参数；校验端在报告缺失、摘要不符、记录不符时拒绝；`cfw install` 的保护规则；`create-status` 显示 |
| daemon | B2 | `make daemon_api_build` 成功；候选检查断言新 plist 字段；`VPHONED_VCAM=off` 的判断在 macOS harness 中覆盖（若可抽到 C 函数） |

### 7.2 真实验收（需用户授权）

前提：用户授权；独立库根；VM 名不为 `vm-2607`、`vm-new`；构建 `make build`、`make guest_components_build`、`make daemon_api_build`，记录各产物 SHA-256。

| 步骤 | 操作 | 证据 | 授权项 |
| --- | --- | --- | --- |
| R1 | `vm create <lp-v2-accept> --variant regular --guest-environment v2` | `create-status`；`.cfw-history/<id>/guest-environment-install.json`；检查点 evidence | 磁盘空间、sudo/认证对话框、TSS 联网 |
| R2 | 停机只读判定 `cfw update-environment --check --root-popup` | `already_current`；`bootstrap.kind: v2`；`disk.unchanged: true` | 认证 |
| R3 | 启动：`VPHONE_API_TOKEN=<随机值> vm launch <vm> --api-listen 127.0.0.1:0` | 完成 first_boot 与 verification；经典 caps 不变（无 shell）；`api_session.state: ready`；`guest rpc device.info` 成功（T17 遗留） | VM 运行 |
| R4 | 环境加载 | `guest env status`：`load.source: environment.loaded`；pid 1 映射 launchdhook 为 `current`；App 与 `cameracaptured` 映射 SystemHook；经典 `file_get` 读 `/var/mobile/Library/Caches/vphone-launchdhook-injection.log` 与 `vphone-systemhook.log` | 同上 |
| R5 | 经典合约回归 | 触控、`location_owned`、`file_get/put`、`app_launch`、宿主截图 | 同上；不发送合成键鼠事件，触控以客户机路径执行并经用户确认 |
| R6 | T16 停机更新成功路径 | 停机；用只改 libcamfix 的候选判定为 `offline_update`；替换后 `already_current`；身份文件摘要不变；启动后 R4 复核 | sudo/认证、VM 运行 |
| R7 | T17 在线更新成功路径 | 不同候选 `guest env update`：差异库 `replaced`、`verified: true`；`load` 中运行进程为 `stale`；`--restart cameracaptured` 后为 `current` | 客户机写入 |
| R8 | 回退 | `guest env rollback <vm> <事务>` 后摘要恢复；整机回退：删除测试 VM，或手动以 `.cfw-history/<id>/Disk.img` 替换（本地无现成命令） | 删除数据 |
| R9 | classic 回归 | 不带选项新建 regular VM 或启动既有 classic 副本：无 `/vh`、无 API 守护进程 | 磁盘、VM 运行 |
| R10（B6 后） | 迁移 | 对停机 classic 源执行 `cfw migrate-environment`：源 bundle 文件列表与摘要不变；克隆判定 `already_current`；启动后 R4 | 磁盘、sudo |

R4 判定：pid 1 未映射 launchdhook，或 App 未映射 SystemHook，判为 D6 情形。此时停止 R5 之后的步骤，记录 `vphone-launchdhook-injection.log` 是否存在与 `environment.loaded` 的 `uninspected` 列表。

T17 第一段验收前提调整：原方案 B（经典 `file_put` + `shell` 热加载）在 regular 上缺 shell，在 exp 上 `launchctl` 拒绝加载，且宿主权限检查拒绝该操作（1.4 节）。T17 两段验收合并为 R3、R4、R7，前提改为“按本设计新建的 v2 VM”。

## 8. 问题 7：分批实施计划

每批一个提交，可独立构建与测试。

| 批 | 文件范围 | 依赖 | 测试 | 验收条件 | 不验证 |
| --- | --- | --- | --- | --- | --- |
| B1 记录与判定 | `scripts/guest_environment.json`（`profiles.v2`）；`scripts/cfw_env_update.py`（`variant_records`、v2 规则、`daemon` 段）；`sources/VPhoneCore/VPhoneRestoreInfo.swift`（`guestEnvironment`）；`VPhoneCreateCheckpoint.swift`（选项、校验、`changes`）；`PatchDeclaration.swift`、`PatchDeclarationCatalogData.swift`（OptIn 与 environment 声明）；`tests/test_cfw_env_update.py`；Swift 检查点与声明测试 | 无 | 7.1 判定规则与 Swift 检查点项；修改前运行新用例记录失败 | `make test_python`、`make test_swift` 通过；历史检查点摘要不变；`fw plan` 输出 environment 声明 | 无客户机写入；不提供 CLI 选项 |
| B2 API 守护进程并行身份 | `sources/VPhoneDaemon/Native/vphoned_native.m`、`vphoned_proxy.c`、`Daemon/GuestAPI.swift`、`Daemon/main.swift`；新增 `Configuration/vphoned-api.plist`；`scripts/build_daemon_api.sh` 与候选检查；`VPhoneResources`（`daemonAPICandidate`）；一致性测试 | B1（清单字段） | `make daemon_api_build`；一致性测试；native harness | 候选产物含新 plist；缓存路径常量与清单一致；1338 开关测试 | 客户机运行；iOS 上的 launchd 加载 |
| B3 离线安装器 | 新增 `scripts/cfw_env_install.py`；`scripts/patchers/cfw.py`、`cfw_daemons.py`（单项 `inject-daemon`）；`tests/test_cfw_env_install.py`；`tests/cfw_env_update_harness.py` 扩展；`scripts/check_bundle.py` | B1、B2 | 7.1 安装器项；原生合成磁盘脚本 | 合成树上成功、拒绝、失败三类断言通过；后置判定 `already_current` | 真实 iOS 系统卷；真实 launchd 重签后的启动 |
| B4 驱动接入 | `scripts/cfw_install_host.sh`（`--guest-environment`、`--install-environment` 预留给 B6）；`tests/test_cfw_disk_transaction.py`、`tests/test_cfw_host_isolation.py` | B3 | 7.1 驱动项 | 成功发布、失败保护原盘、拒绝组合无工具调用、无选项回归 | 真实 sudo/认证 |
| B5 Swift 入口 | `VPhoneVMCreateCLI.swift`、`VPhoneCreateOrchestrator.swift`（参数、记录）、`VPhoneCreateLiveStages.swift`（evidence 与校验）、`VPhoneRestoreCLI.swift`（`cfw install` 选项与保护）、`VPhoneCFWEnvironmentCLI.swift`（迁移提示文本）；`create-status` 输出；Swift 测试 | B4 | 7.1 Swift 项 | `make test` 通过；`vm create --help` 显示选项 | 真实创建 |
| R 真实验收 | 研究记录 | B5 与用户授权 | 7.2 R1–R9 | 见 7.2 | — |
| B6 迁移命令（D5） | 新 CLI `cfw migrate-environment`；驱动 `--install-environment v2`；测试 | B5、R4 通过 | 驱动与 CLI 测试；R10 | 源 bundle 不变；克隆 `already_current` | — |
| B7 dev 开放（D1） | 清单 `profiles.v2.variants` 加 `dev`；安装器处理已有 jetsam 补丁的 launchd | R 通过 | 合成树 dev 用例 | 同 R1–R4 在 dev 上 | — |

每批按项目规则更新对应研究记录；B3 若引入新的 launchd 修改方式，同步 `research/0_binary_patch_comparison.md`（`/vh` 加载命令对 regular 是新增的 launchd 改动）。

## 9. 问题 8：风险与需要用户决定的问题

### 9.1 风险

1. regular 内核补丁不足（待验证假设）。上游 `standard` 包含本地只给 jb/exp 的 32 项内核补丁中除 Frida 2 项以外的 30 项（1.1、1.2 节）。regular 能否让 launchd 加载 ad-hoc 签名的 `/vh`、能否对 App 执行 `DYLD_INSERT_LIBRARIES`，没有任何记录。regular 已有 `kernel-boot-dyld_policy`、`txm-boot-trustcache_bypass`，并已运行 ldid 重签的 seputil 等二进制（事实），这只说明重签的可执行文件可运行。R4 是第一项判定。
2. regular 的 launchd 首次被重签（事实：regular 现不改 launchd）。若重签后的 launchd 不能启动，客户机不能启动。T15 保留旧盘；R1 的失败恢复为删除测试 VM。
3. 候选相机库 ABI 与本地 classic 相机不兼容（事实）。regular 的经典相机共享内存在 `/var/jb` 下，regular 没有 `/var/jb`（推断：regular 现无相机功能）。候选 `libvcamcaptured` 在 `cameracaptured` 中加载后的行为未验证，可能影响系统相机进程。
4. API 守护进程首次在客户机运行（事实：尚无运行记录）。签名、AMFI、Swift 运行库、proxy/worker 在 iOS launchd 下的行为未验证。KeepAlive 与 `ThrottleInterval 1` 下的反复崩溃会占用资源，但不影响经典 1337（推断）。
5. exp 上 `launchctl` 拒绝加载的原因未查明。系统卷 LaunchDaemons + launchd.plist 注入的方式已由经典 vphoned 证明可用；对 API 守护进程是否同样可用，由 R3 判定。
6. 本地 launchdhook 不对 SpringBoard 插入 SystemHook（推断，依据本地源码与上游注释）。T17 激活规则把 SpringBoard 列为 respring 对象（`research/t17_online_update_activation_2026-10-01.md` 3.3 节）；在本地 2.0.8 hook 下 SpringBoard 可能不加载 libvlocation。R4 记录实际映射。
7. 应用安装后由宿主推送的经典 vphoned 与 API 守护进程同时运行时的资源与 Jetsam 影响未知。
8. guest 组件与 API 守护进程候选只在 `.build/` 中，不在签名 app 的资源里。签名 app 运行 `vm create --guest-environment v2` 需要源码树或 `VPHONE_GUEST_COMPONENTS` 等环境变量。打包属于 P8/T28。

### 9.2 需要用户决定的问题

- D1：v2 首个变体是否为 regular。备选是 dev（内核补丁相同，launchd 已改过）。jb/exp 需要 `/b` 共存方案，本设计不覆盖。
- D2：是否采用正交的 `guest_environment` 记录，而不新增 variant 值。
- D3：是否接受 v2 VM 中并行运行持久的 API 守护进程，以及为此修改本地 daemon 的缓存路径、标签、程序路径并关闭其相机监听（与上游不同）。
- D4：v2 profile 是否安装两个候选相机库。安装：清单与 T16/T17 一致，相机按“不提供”记录，存在风险 3。不安装：需要在清单中把相机库标为该 profile 可选，T16/T17 判定规则随之修改。
- D5：是否提供已有 classic VM 的迁移命令（B6），以及“只在命令自建的克隆上执行”这一限制。
- D6：若 R4 显示 regular 不加载 `/vh` 或不插入 SystemHook，三个方案：(a) 为 v2 profile 增加一组 opt-in 内核补丁（改变 regular 固件输出，需要补丁比较记录与逐项验收）；(b) v2 改为只在 jb 上提供，并在 jb 上以 `/vh` 替代 `/b`（与“不无条件替换 `/b`”冲突，需另行决定）；(c) 暂停 v2，T17/T18 真实验收继续等待。

## 10. 本文未覆盖

- 没有运行任何构建、测试或 VM；第 1 节以外的结论都是设计。
- 子代理整理的上游与本地事实已逐项抽查以下位置：上游安装器 `:523-665`、`:855-960`、`:1056-1092`；上游 `InjectionEnvironment.h:1-70` 与 `launchdhook-vphone.c:77-110`；`standard.plist:100-117`；本地 `SystemHook-vphone.c`、`launchdhook-vphone.c` 全文；`cfw_env_update.py:215-390`；`cfw_install_host.sh:60-75`、`:380-415`；`VPhoneCreateCheckpoint.swift:8-32`、`:98-135`、`:405-418`；`VPhoneCreateLiveStages.swift:265-278`；`VPhoneVirtualMachineManifest.swift:178-188`；`vphoned.m:505-540`、`:636-650`；`vphoned_native.m:11-14`、`:55-110`；`GuestAPI.swift:343-360`；`VPhoneHostAPICommands.swift:16-20`；`VPhoneHostRPC.swift:75-83`；`vphoned_vcam.h:24-29`；API `vphoned_vcam.m:340-375`；`main.swift:1-30`。其余行号来自子代理报告，未逐一复核。
- 1.4 节的真实环境发现来自主会话，本文未复核。

## 12. 用户决定（2026-10-01）

- D1：首批只开放 `regular`；`dev` 在 regular 真实验收通过后开放；jb、exp、less 拒绝。
- D2：新增与 variant 正交的 `--guest-environment classic|v2`，默认 `classic`；不新增 variant 值。
- D3：v2 VM 中 API 守护进程与经典守护进程并行、持久运行；修改本地 daemon 的标签、程序路径与缓存路径，关闭其 1338 相机监听（与上游不同）。
- D4：仍安装两个候选相机库，验收时相机记为“不提供”；T16/T17 判定规则不变。
- D5：已有 classic VM 的迁移命令推迟到 B6，只在命令自建的克隆上执行。
- D6：待 R4 真实验收结果后再定。
- 实施顺序：B1–B5 依次实施，随后执行 R1–R9 真实验收（需用户授权的步骤届时单独确认）。
