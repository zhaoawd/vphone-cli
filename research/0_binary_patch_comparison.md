# Patch Comparison: Regular / Development / Jailbreak / Experimental

## 2026-10-15 DSC 原件及操作前像的生产关联（恢复批次）

固定上游仍为 `8a75092013eda87a4e30ed029b72028cb9279ac4`。本批未新增指令替换，接入 generation 原件、只读 DSC 基线、实际复制/变更记录、逐操作前后 blob 和生产者源码摘要的持久索引；final_guest 生成索引，journal 绑定摘要，发布前重新构建并校验。新磁盘事务 schema 2 统一要求证明，环境更新也记录实际复制效果并执行最终读取；旧 schema 1 保留恢复/清理，拒绝继续发布。相关 157 项组合中的旧输入路径断言已修正，最终 36 项补跑全部通过。具体范围见 [T32/T33 记录](upstream_integration_2026-10-15/T32_T33_implementation_migration.md)。

索引仅证明来源和已观察操作链。verify-final 后仍有 APFS snapshot 变换，尚未证明变换后的最终语义；逆向 Undo、旧实现迁移和 payload/Undo/Receipt 共同发布仍未完成。IOMFB 生产迁移门控保持，未执行真实固件写入或 VM 验收。

## 2026-10-15 IOMFB 条件分派算法（第二批）

固定目标仍为 `8a75092013eda87a4e30ed029b72028cb9279ac4`。Python IOMFB writer 已从单条无条件分支改为四指令条件分派：保留原空连接失败目标，读取连接的 IOConnect 端口，有端口时跳到 kern 路径，否则跳到 virt 路径。端口布局 `0x14` 的来源证据仅覆盖上游 24A446；本批临时 DSC fixture 验证不扩大真实固件适用范围。符号和 Capstone 语义识别原始、当前、旧实现及未知状态；旧实现或未知完整三符号入口拒绝，SwapSignal 按固定上游明确例外保持原路径。预检全部改写范围和 CodeDirectory 槽，覆盖 16 字节跨页重签及最终读回。35 项算法、既有语义和约束检查通过，旧 writer 四项反证失败，另三项入口对照通过。

当前算法可在隔离副本和 dry-run 验证；生产写入仍受准入拒绝约束。可信 Undo、旧实现撤销重打和 payload/Undo/Receipt 事务发布尚未实现。未执行真实固件写入、VZ 显示或 DeviceHub 运行验收。详见 [T32/T33 第二批记录](upstream_integration_2026-10-15/T32_T33_implementation_migration.md)。下节保留第一批实施时的状态。

## 2026-10-15 同 ID 实现资格拒绝与幂等证据回归

固定目标为 `8a75092013eda87a4e30ed029b72028cb9279ac4`。本地 `dyld-boot-iomfb_force_kern` 仍写入旧无条件分派，尚无当前条件分派及可信 Undo 消费/事务发布链。本批不增加指令替换；Python 冻结计划准入在 iOS 27 启用该声明时拒绝安装，在显式调用旧 writer 时拒绝执行，均在写入和证据创建前发生。缺少可信原件时不从已补丁字节推定原件。iOS 26/18 的其他授权写入保持可用，dry-run 明确标为旧算法诊断。50 项门控回归通过；未建立当前目标的 IOMFB 输出等价或迁移验收。详见 [T32/T33 记录](upstream_integration_2026-10-15/T32_T33_implementation_migration.md)。

JB post-validation 生产算法保持。原幂等测试失败实际发生于第二次调用：新增同位置、前后字节相等的已应用验证记录。测试现分别核验实际修改、观察记录和结构化声明摘要，21 项相关回归通过；移除观察的反证使两个增强测试失败。仅合成 fixture，未运行真实 kernel/VM。详见 [T30 记录](upstream_integration_2026-10-15/T30_kernel_idempotence.md)。

## 2026-10-14 kernel-only IM4P 字段保留修复（Task 8）

第七版实际容器对照确认，固定 description 重建 IM4P 删除了原始 PAYP，并将 `KernelManagement_host-487.0.4` 改为 `kernelcache`。更新前后解码 payload 相同，IM4M 原字节相同；该差异与 guest 未就绪的因果关系尚未验证。新增回归已在现有生产封装路径两次复现字段丢失。修复从摘要匹配的可信 generation 原始 IM4P 保留 description/PAYP 原始 TLV；未压缩输出移除原 LZFSE 压缩元数据，未知或不一致结构拒绝，LZSS 原件明确拒绝。候选和发布后均核验完整 IM4P，proof 增加其摘要。37 项定向测试汇总退出 0，含 1 个独立 region fixture 入口跳过；实际元数据回归执行并将错误容器恢复为与基线逐字节一致。独立审查未发现阻断问题，见 [修复证据](evidence/2026-10-13-task8/acceptance/payp-preservation/diagnosis.md)。内核补丁算法未改变。第八版及第九版计划 A 的实际更新、读回和已授权第四版 guest 启动通过；description/PAYP 同时恢复，不能单独确定此前启动异常的原因。提交后回退实现与回归已通过独立审查，不同 payload 的 B 更新、读回及第四版 guest 启动已通过，公开回退 A 的实际验收继续执行，见 [验收进度](evidence/2026-10-13-task8/acceptance/acceptance-progress.md)。

## 2026-10-13 kernel-only 停机更新（Task 8 / T34）

新增从可信 generation 原件执行冻结内核计划的停机更新路径、候选 Preboot 载荷替换、内核共享区域与已安装 DSC 容量检查，以及 schema 3 磁盘/receipt/kernel 来源共同恢复。复用现有内核补丁与 IMG4 payload swap；未新增内核补丁算法，未修改 DSC maxSlide 或其他组件。kernel-only 报告保留完整计划摘要，只检查内核操作范围的必需声明并拒绝其他组件记录；普通事务继续检查完整计划。验证结果及真实 VM 未验证范围见 [Task 8 实施记录](evidence/2026-10-13-task8/implementation.md)。

## 2026-10-12 稳定身份与可信 generation（T11/T12）

新增严格 machineIdentifier 与磁盘文件身份、新 schema 的改名恢复、由已验证 prepare 产生的完整原件 generation，以及 create prepare/patch 接入。generation 内容身份不包含计划摘要；计划关联单独记录为 prepared。native 和真实 script/less 小型档案来源验证通过，430 项相关 Swift 回归与 20 项 prepare Python 回归通过。未改变补丁算法、写入字节或五模式声明成员；真实固件及 VM 行为未验证。来源边界、旧 schema、完整首批测试的环境失败及后续生命周期要求见 [generation 记录](upstream_integration_2026-10-06/T11_T12_firmware_generation_2026-10-12.md)。

## 2026-10-12 逐声明执行证据门（T10）

发布门新增冻结声明的显式记录归属、完整必需声明检查及 alreadyApplied 当前载荷读回证据。缺单项或缺整个组件均拒绝提交，全组件 ablation 保留只读报告。未改变补丁算法或字节。独立 scratch 的 FirmwarePatcherTests 与完整历史固件对照共 313 个测试通过；五模式完整证据及缺单项不改变原固件的故障测试通过。证据、接口边界和未验证行为见 [执行证据记录](upstream_integration_2026-10-06/T10_execution_evidence_2026-10-12.md)。这些结果不建立固定上游字节等价或 VM 验收。

## 2026-10-12 固定上游声明目录（T09）

声明目录现对应固定上游 `2d21d21fbdd4f51f013616273ceda9b35a3e0789` 的全部 141 个 ID，并保留 2 个本地 less ID。原有 119 个声明的执行步骤、模式成员、版本规则和显式选项保持原值；24 个新增目标 ID 均标记 `notImplemented`，各自记录原因，显式选择时拒绝。决定及五模式版本矩阵见 [T09_target_applicability.json](upstream_integration_2026-10-06/T09_target_applicability.json)。本轮未新增二进制补丁或修改匹配及写入逻辑。声明身份和步骤成员关系不建立上游字节等价；真实固件、恢复和 VM 启动行为未验证。

## 2026-10-02 regular-v2 MAC mount 实验候选

用户批准独立对照实验。显式 `vm create --guest-environment v2 --experimental-v2-root-remount` 仅为 regular 追加现有 `kernel-boot-mac_mount`，不采用其他 JB 步骤。23B85 原始 vphone600 的内存输出比较通过：默认 regular 的 28 项内核记录逐项相同，实验候选额外两项 4 字节写入，完整输出与预期一致。匹配沿用当前映像语义锚点与 ARM64Encoder，不使用固定地址。默认 regular/classic 选择保持原范围；真实重挂、在线更新及回退尚未验证。详见 [实验记录](t17_mount_rejection_diagnosis_2026-10-02.md)。

## 2026-10-01 DSC maxSlide 选项层对齐（T13a）

`FORCE_DSC_MAXSLIDE=1` 与 `vm create`、`cfw install` 的 `--force-dsc-maxslide` 已删除，与上游 `d930e50` 一致。`cfw_install.sh` 只在 `27.*` 基线调用 `patch-dsc-maxslide`，且不传 `--force`；是否清零由补丁器按缓存头判断（`sharedRegionSize + maxSlide > 0x180000000` 时清零，已为 0 或可容纳时不写）。补丁器增加与上游 `DyldSharedCacheMaxSlidePatcher.swift` 等价的缓存头校验（0x100 字节头部、`mappingOffset` 覆盖 `maxSlide`、主分块存在文件偏移 0 的映射、`sharedRegionStart` 等于最低映射地址、`sharedRegionSize` 覆盖映射跨度、64 位求和不溢出），校验失败时报错且不写入。`cfw_install_host.sh` 对所有变体识别到旧环境变量时打印已移除提示，并且不再转发。清零写入的字段、字节和写入方式不变；独立命令 `cfw.py patch-dsc-maxslide --force` 保留供手动使用。记录见 `research/t13a_dsc_maxslide_option_2026-10-01.md`。本轮未新增二进制补丁，本文既有计数不变；真实 iOS 27 缓存与启动未验证。

## 2026-10-01 声明层与变体计划（T10/T11）

Swift 补丁步骤的声明层映射、五变体计划解析与严格写入门见 `research/t10_t11_variant_plan_strict_gate_2026-10-01.md`；声明数据 `sources/FirmwarePatcher/PatchSet/PatchDeclarationCatalogData.swift`（可读副本 `research/t10_patch_declarations_2026-10-01.json`），只读入口 `vphone-cli fw plan`。本轮未新增或改动二进制补丁，本文既有计数不变。

## 2026-09-29 VM runtime split, schema boundary and API app actions

Added a paired VM executable with separate signing, boot exec handoff, legacy/new process identity matching and combined CLI/VM checkpoint fingerprints. Versioned manifests are refused by the legacy backend without rewriting them. Explicit API launch/terminate preserves foreground verification and reports post-submission uncertainty. No firmware/kernel/DSC patch bytes or default guest payloads changed. The new VM executable is rejected by AMFI for restricted entitlements; real VM acceptance remains incomplete. See [runtime details](p3_vm_process_integration_2026-09-29.md) and [remaining stage status](upstream_remaining_progress_2026-09-29.md).

## 2026-09-29 P2 isolated guest components

Added fixed-source LaunchHook, SystemHook, location/camera libraries and GPU compiler plugin candidates with separate build metadata, source hashes and host C checks. Their 64-byte camera header is incompatible with the local 256-byte publish header; candidates are not installed or activated. Existing firmware/kernel/DSC patches and variant defaults remain in place. See the [component record](p2_guest_components_integration_2026-09-29.md).

## 2026-09-29 P2 API file uploads

Added explicit API file_put with bounded private source snapshots, request identity and length validation, guest staging/backpressure/atomic replacement, and cancellation uncertainty reporting. Candidate daemon only; no guest installation or firmware/kernel/DSC patch changes. See the [upload record](p2_api_upload_integration_2026-09-29.md).

## 2026-09-29 P2 bounded API file downloads

Added explicit API file_get routing with 1 MiB inline/64 MiB streamed-save limits, private staging and exclusive publication. Managed downloads validate HTTP daemon identity and connection generation, have deadlines and cancellation, and refuse redirects. The inactive candidate adds identity response headers and nonblocking regular-file checks. Firmware/kernel/DSC patch logic and default installation choices are unchanged. Real VM acceptance remains skipped. See the [eleventh-batch report](p2_api_files_integration_2026-09-29.md).

## 2026-09-29 P2 read-only host app commands

Added explicit API routing for Unix-socket app_list and app_foreground, with capability discovery, field/error mapping and cancellation/generation checks. Classic routing remains the default. Tests cover contract failures and a real Unix-socket-to-loopback-WebSocket path. No daemon, firmware/kernel/DSC patch or installation changes in this batch; real VM acceptance remains skipped. See the [tenth-batch report](p2_api_commands_integration_2026-09-29.md).

## 2026-09-28 P2 managed API session

Added VM-runtime-scoped API sessions with HTTP/WebSocket identity agreement, SHA/capability checks, heartbeat, reconnect and additive Unix-socket discovery. The inactive candidate daemon now declares a process UUID, session capability and read-only health RPC. These are local API v1 extensions to fixed upstream 2.0.8. Firmware/kernel/DSC patch logic and installed classic payload selection are unchanged. Real VM acceptance remains skipped. See the [ninth-batch report](p2_api_session_integration_2026-09-28.md).

## 2026-09-28 P2 opt-in API proxy

Added an explicit loopback TCP-to-VSOCK 1339 proxy to boot/vm launch. The proxy adapts the fixed upstream request gate, checks one token and local Host/no Origin before connecting, strips credentials, and bounds admission, connection attempts, relay buffers and writes. Host-only tests exercise HTTP/WebSocket forwarding and socket lifecycle. No daemon installation, firmware patch, kernel/DSC logic, or default 1337 control behavior changes. Real VM acceptance remains skipped. See the [eighth-batch report](p2_api_proxy_integration_2026-09-28.md).


## 2026-09-28 P2 host HTTP/WebSocket foundation

Added the independent `VPhoneAPIKit` SwiftPM library, adapting the fixed upstream API v1 value types and client contract. Health/capability/hash checks, bounded HTTP RPC, WebSocket response correlation, deadlines, cancellation and connection generation have host-only tests, including a real loopback HTTP/WebSocket fixture. No firmware, kernel/DSC patch, daemon payload, installation target or default VM control path changes in this batch. VSOCK/proxy and business command integration remain pending. See the [seventh-batch report](p2_host_api_integration_2026-09-28.md).


## 2026-09-28 P2 isolated upstream API daemon build

Imported fixed upstream VPhoneDaemon/native proxy and its camera protocol header into an isolated iOS build. `make daemon_api_build` pins the daemon's dependency graph and produces a signed, inactive candidate. The shared signer is cross-compiled from the existing local implementation; request decoding and proxy lifecycle have firmware-free tests. Default host/guest transport, installed daemon payloads and kernel/DSC patch logic remain unchanged by this batch. See the [sixth-batch report](p2_daemon_api_integration_2026-09-28.md) for validation and unverified guest behavior.


## 2026-09-28 P2 pre-signed guest payload layout

Regular/dev/JB/EXP installation and host auto-update now share the pre-signed local vphoned under `guest-resources`; the less pipeline uses a separately compiled `LESS=1` payload. Build-time checks cover arm64/IOS/minos 15.0, forbidden Swift imports, entitlement equality and artifact hashes. Installers no longer compile or re-sign these daemon payloads. Kernel/DSC patch logic and variant selection are unchanged; daemon build metadata and resulting payload bytes change. The upstream SwiftNIO daemon/proxy and remaining guest components have not been substituted. See the [fifth-batch report](p2_guest_layout_integration_2026-09-28.md) for fixture validation and unverified VM behavior.


## 2026-09-28 P2 native Restore foundations

Imported MobileRecoveryCore, MobileRestoreCore and VPhoneRestore from fixed upstream `2.0.8 / 9d218de`, with pinned AppleMobileDeviceLibrary and OpenSSL dependencies. Added read-only `restore-inspect` for directory selection and bounded plist/gzip ticket inspection. Local changes reject ambiguous ticket selection, unknown probe modes and oversized/trailing ticket data. Existing Python restore execution and DFU ownership checks remain in use. Firmware patch bytes and variant defaults are unchanged. Validation and limitations are recorded in the [fourth-batch report](p2_restore_integration_2026-09-28.md); no USB/TSS/restore or real VM acceptance was performed.


## 2026-09-28 P2 native transfer and IPSW interfaces

Added opt-in native VM export/import behind the existing bundle and library locks; the default remains system-tar. Both import backends validate manifest paths and links before exclusive publication from private staging. IPSW cache and local `fw inspect` interfaces now read bounded BuildManifest data and validate source pairing. Firmware patch bytes, variant defaults, firmware preparation and CFW installation backends are unchanged. Fixture interoperability, cache tests and CLI evidence are recorded in the [third-batch report](p2_transfer_integration_2026-09-28.md); real VM import/boot acceptance remains skipped.

## 2026-09-28 P2 native archive entrypoints

Imported the Archive portion of VPhoneArchiveKit and explicit `archive` commands from fixed upstream `2.0.8 / 9d218de`, using pinned ArchiveKit `82687c7`. Local adaptations preserve permission policy, reject path traversal, publish new outputs exclusively, resolve hardlink member reads and enable sparse extraction. Firmware patch bytes, variant defaults, VM transfer and CFW archive backends remain unchanged. Small-fixture validation and the 16 MiB sparse-allocation limitation are recorded in the [P2 archive report](p2_archive_integration_2026-09-28.md). This does not establish real VM import or boot acceptance.

## 2026-09-28 P2 native signing entrypoints

Imported VPhoneSign and its fixed upstream corpus from `2.0.8 / 9d218de` as a separate SwiftPM target with explicit `sign` and `dump-entitlements` CLI commands. Existing firmware patch bytes, variants, CFW signing scripts and guest installation paths are unchanged. File signing uses private staging and refuses symlinks; the native signer has not replaced ldid in the installation pipeline. Frozen signing parity, local CMS verification and ordinary host execution are recorded in the [P2 integration report](p2_sign_integration_2026-09-28.md); these do not establish guest/VM acceptance.

## 2026-09-28 P1a catalog and P1b camera DSC preflight

The catalog adds iOS 26.6.2/23G90 and 27.0 RC/24A435 from upstream `9c23c8adcd4b362120988ab9d228b959bcc23ae3`, both paired with cloudOS 26.4. All five variants remain only `code_selectable` for these additions; upstream Tested Environments rows are not local acceptance evidence.

The EXP Python camera patcher now plans all six sites before writes, recognises its exact existing output, and fills mixed original/patched inputs. Invalid sites fail before any write unless the explicit prologue override is used; short or overlapping inputs and incomplete signature slots still fail. It checks written bytes and SHA-256 page slots, includes existing sites when re-attesting after interruption, and covers both pages of a boundary-spanning patch. Replacement instructions and the six-site scope are unchanged. AVF-only and dry-run remain available. Write/hash failures propagate without rollback; the EXP installer still logs camera failures and continues.

The full `make test` passes: 369 Python tests (including 17 new synthetic DSC tests), 497 Swift Testing tests, and 145 XCTest cases (3 skipped, no failures), plus both archive relay memory checks. CLI JSON reports all 25 catalog pairings and both new menu selections pass. Real DSC and EXP runtime validation remain outstanding. P1c real import and post-import boot acceptance are skipped at the user's request, retaining their unverified status. See the [P1a/P1b record](p1ab_integration_2026-09-28.md) for source mapping, regression results, and limits.

## 2026-09-26 P1c host state integration

Applied the first-batch host NVRAM and stopped-VM clone changes. Existing NVRAM is opened without recreation; clones retain persistent boot identity while omitting root host runtime state and the default control socket. Firmware patch logic, variant defaults, patch counts and previous firmware acceptance results are unchanged. Real VM repeat boot and stopped-clone boot passed on isolated copies after a temporary, single-CDHash AMFI allowance. Export/import acceptance is not complete. macOS unit/integration results and the remaining VM acceptance are recorded in [the P1c integration report](p1c_batch1_2026-09-26.md).

The follow-up import change uses `bsdtar -S` to recreate holes from zero blocks. A 256 MiB regression fixture verifies byte equality, logical size, and reduced allocation through the real export/import entrypoints. The resumed Swift suite passes 496 tests plus 145 XCTest cases (3 skipped). Real-VM results and the limits of this allocation behavior are tracked in [the import acceptance record](p1c_import_acceptance_2026-09-26.md); this remains a host-only change. The archive relay now drains Foundation autoreleased buffers per chunk. Isolated 1 GiB tests of both real relay input paths fail above 1 GiB RSS before the change and pass below 9 MiB afterward; the check is included in `make test_swift`.

The final real import attempt exhausted the configured free-space margin and did not publish a VM. The host subsequently panicked at 2026-09-26 19:01:26 +08:00 after a logd watchdog timeout, with LOW swap space recorded. Import-related storage pressure is the leading suspected contributor; the logd blocking mechanism is unconfirmed. The temporary guard waited only for the CLI parent and did not establish that tar and disk writes had stopped. Real import/boot acceptance remains incomplete; see the [incident analysis](p1c_host_panic_2026-09-26.md).

> **EXP is a JB superset.** Everything in the baseline tables below that is `Y`
> for JB is also `Y` for EXP. The columns are kept at three variants to avoid
> noise — the only place EXP and JB diverge is the **Experimental additions**
> below, all of which are EXP-only (JB and the other variants are deliberately
> unaffected). The EXP-only items, taken together:
>
> - **Kernel** — `KernelEXPPatcher` runs the `hv_vmm_present` sysctl OID rename
>   plus kernel-internal caller cstring/sandbox-profile-token mangle (formerly
>   wired into JB Group B as JB-26 — moved out).
> - **DeviceTree at fw_patch time** — 8 identity-rewrite property patches
>   (Tier 1b + 1c) flipping userland-visible identity surfaces toward
>   D47AP / iPhone17,3.
> - **DSC user-mode** — byte-5 cstring mangle of `kern.hv_vmm_present` with a
>   sign-in blacklist + per-page slot re-attestation (`cfw_patch_hv_vmm_dsc.py`),
>   companion to the kernel rename.
> - **watchdogd (EXP-JB-3.5)** — surgical 2-instruction patch + slot re-attest;
>   forces the cached "am I a VM?" byte to `1` so watchdogd's clean-exit branch
>   runs.
> - **Post-restore DT rewrite (EXP-JB-6)** — host-side rewrite of `devicetree.img4`
>   on the ramdisk's mounted rootfs for the three restore-fatal identity
>   properties (root `model`, `target-type`, `compatible[0]`) that broke
>   restore when applied at fw_patch time.
> - **SystemVersion.plist `ProductBuildVersion` (EXP-JB-7, opt-in)** — gated on
>   `SPOOF_BUILD=<id>`. Rewrites the build identifier in the rootfs and
>   cryptex copies of `SystemVersion.plist`.
> - **Camera.app accessibility** — at fw_patch time: the `/product/camera`
>   node, two `/product` cam-offset rewrites (Tier B), three new
>   `/product` child nodes `facetime` / `audio` / `iopm` (Tier C), and
>   five minimal `/arm-io` stubs `isp` / `ispRtb` /
>   `smc/iop-smc-nub/smc-ext-charger` carrying camera-front, camera-rear
>   and camera-driver (Tier F). At install time: the 5
>   `+[_NUStyleTransfer*Processor processWithInputs:...]` DSC
>   short-circuits in NeutrinoCore plus a 1-instruction
>   `+[AVCaptureDevice authorizationStatusForMediaType:]` rewrite in
>   AVFCapture that returns `Authorized` for any media type
>   (Stage 0 of the vcam stack — auth gate only; downstream
>   cameracaptured/vcamd plumbing for actual frame delivery is open
>   work). Together these make Camera.app's icon show on the home
>   screen and in Spotlight, the viewfinder render, and arbitrary apps
>   stop bailing on the camera permission check. The NeutrinoCore patch
>   stops the viewfinder's CIImageProcessorKernel chain from asserting
>   on a nil descriptor when ANE detection comes back NO on the VM.

## Boot Chain Patches

### AVPBooter

| #   | Patch        | Purpose                          | Regular | Dev | JB  |
| --- | ------------ | -------------------------------- | :-----: | :-: | :-: |
| 1   | `mov x0, #0` | DGST signature validation bypass |    Y    |  Y  |  Y  |

### iBSS

| #   | Patch                               | Purpose                                                                                                            | Regular | Dev | JB  |
| --- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Serial labels (2x)                  | "Loaded iBSS" in serial log                                                                                        |    Y    |  Y  |  Y  |
| 2   | `image4_validate_property_callback` | Signature bypass (`b.ne` -> NOP, `mov x0,x22` -> `mov x0,#0`)                                                      |    Y    |  Y  |  Y  |
| 3   | Skip `generate_nonce`               | Keep apnonce stable for SHSH (`tbz` -> unconditional `b`)                                                          |    -    |  -  |  Y  |

### iBEC

| #   | Patch                               | Purpose                                                                                                            | Regular | Dev | JB  |
| --- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Serial labels (2x)                  | "Loaded iBEC" in serial log                                                                                        |    Y    |  Y  |  Y  |
| 2   | `image4_validate_property_callback` | Signature bypass                                                                                                   |    Y    |  Y  |  Y  |
| 3   | Boot-args redirect                  | ADRP+ADD -> `serial=3 -v debug=0x2014e %s`; iOS 18 base adds `if_attach_nx=0x3` (skywalk BSD_ONLY: disables fsw netagents so Network.framework uses BSD sockets, fixes mDNSResponder skywalk-channel crash-loop / DNS) |    Y    |  Y  |  Y  |
| 4   | Modern bootx-handoff panic bypass   | `IBootPatcher.patchBootxPrecondition` NOPs gate TBZ via structural anchor (no hash/line tied); no-op pre-26.4      |    Y    |  Y  |  Y  |
| 5   | Ramdisk boot-args overwrite         | `ramdisk_build.py:patch_ibec_bootargs` rewrites string to `... rd=md0 ... wdt=-1 ...` (ramdisk-send iBEC only)     |    Y    |  Y  |  Y  |

### LLB

| #   | Patch                               | Purpose                                                                                                            | Regular | Dev | JB  |
| --- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Serial labels (2x)                  | "Loaded LLB" in serial log                                                                                         |    Y    |  Y  |  Y  |
| 2   | `image4_validate_property_callback` | Signature bypass                                                                                                   |    Y    |  Y  |  Y  |
| 3   | Boot-args redirect                  | ADRP+ADD -> `serial=3 -v debug=0x2014e %s`; iOS 18 base adds `if_attach_nx=0x3` (skywalk BSD_ONLY: disables fsw netagents so Network.framework uses BSD sockets, fixes mDNSResponder skywalk-channel crash-loop / DNS) |    Y    |  Y  |  Y  |
| 4   | Rootfs bypass (5 patches)           | Allow edited rootfs loading                                                                                        |    Y    |  Y  |  Y  |
| 5   | Panic bypass                        | NOP `cbnz` after `mov w8,#0x328` check                                                                             |    Y    |  Y  |  Y  |

### TXM

| #   | Patch                                             | Purpose                                   | Regular | Dev | JB  |
| --- | ------------------------------------------------- | ----------------------------------------- | :-----: | :-: | :-: |
| 1   | Trustcache binary-search bypass                   | `bl hash_cmp` -> `mov x0, #0`             |    Y    |  Y  |  Y  |
| 2   | Selector24 bypass: `mov w0, #0xa1`                | Return PASS (byte 1 = 0) after prologue   |    -    |  Y  |  Y  |
| 3   | Selector24 bypass: `b <epilogue>`                 | Skip validation, jump to register restore |    -    |  Y  |  Y  |
| 4   | get-task-allow (selector 41\|29)                  | `bl` -> `mov x0, #1`                      |    -    |  Y  |  Y  |
| 5   | Selector42\|29 shellcode: branch to cave          | Redirect dispatch stub to shellcode       |    -    |  Y  |  Y  |
| 6   | Selector42\|29 shellcode: NOP pad                 | UDF -> NOP in code cave                   |    -    |  Y  |  Y  |
| 7   | Selector42\|29 shellcode: `mov x0, #1`            | Set return value to true                  |    -    |  Y  |  Y  |
| 8   | Selector42\|29 shellcode: `strb w0, [x20, #0x30]` | Set manifest flag                         |    -    |  Y  |  Y  |
| 9   | Selector42\|29 shellcode: `mov x0, x20`           | Restore context pointer                   |    -    |  Y  |  Y  |
| 10  | Selector42\|29 shellcode: branch back             | Return from shellcode to stub+4           |    -    |  Y  |  Y  |
| 11  | Debugger entitlement (selector 42\|37)            | `bl` -> `mov w0, #1`                      |    -    |  Y  |  Y  |
| 12  | Developer mode bypass                             | NOP conditional guard before deny path    |    -    |  Y  |  Y  |

## Kernelcache

### Base Patches (All Variants)

| #     | Patch                      | Function                         | Purpose                                            | Regular | Dev | JB  |
| ----- | -------------------------- | -------------------------------- | -------------------------------------------------- | :-----: | :-: | :-: |
| 1     | NOP `tbnz w8,#5`           | `_apfs_vfsop_mount`              | Skip root snapshot sealed-volume check             |    Y    |  Y  |  Y  |
| 2     | NOP conditional            | `_authapfs_seal_is_broken`       | Skip root volume seal panic                        |    Y    |  Y  |  Y  |
| 3     | NOP conditional            | `_bsd_init`                      | Skip rootvp not-authenticated panic                |    Y    |  Y  |  Y  |
| 4-5   | `mov w0,#0; ret`           | `_proc_check_launch_constraints` | Bypass launch constraints                          |    Y    |  Y  |  Y  |
| 6-7   | `mov x0,#1` (2x)           | `PE_i_can_has_debugger`          | Enable kernel debugger                             |    Y    |  Y  |  Y  |
| 8     | NOP                        | `_postValidation`                | Skip AMFI post-validation                          |    Y    |  Y  |  Y  |
| 9     | `cmp w0,w0`                | `_postValidation`                | Force comparison true                              |    Y    |  Y  |  Y  |
| 10-11 | `mov w0,#1` (2x)           | `_check_dyld_policy_internal`    | Allow dyld loading                                 |    Y    |  Y  |  Y  |
| 12    | `mov w0,#0`                | `_apfs_graft`                    | Allow APFS graft                                   |    Y    |  Y  |  Y  |
| 13    | `cmp x0,x0`                | `_apfs_vfsop_mount`              | Skip mount check                                   |    Y    |  Y  |  Y  |
| 14    | `mov w0,#0`                | `_apfs_mount_upgrade_checks`     | Allow mount upgrade                                |    Y    |  Y  |  Y  |
| 15    | `mov w0,#0`                | `_handle_fsioc_graft`            | Allow fsioc graft                                  |    Y    |  Y  |  Y  |
| 16    | NOP (3x)                   | `handle_get_dev_by_role`         | Bypass APFS role-lookup deny gates for boot mounts |    Y    |  Y  |  Y  |
| 17-26 | `mov x0,#0; ret` (5 hooks) | Sandbox MACF ops table           | Stub 5 sandbox hooks                               |    Y    |  Y  |  Y  |
| 27    | `PACIBSP→RET`              | `_thread_guard_violation`        | Disable fatal EXC_GUARD (Mach port guard) delivery. Dev variant + iOS 18 bases always; regular/jb/exp otherwise opt-in via `--force-exc-guard` (see note below). | Y* | Y | Y* |

† Always required on iOS 18 bases (18.6.2's runningboardd/SpringBoard trip `GUARD_TYPE_MACH_PORT` "flavor 10", crash-looping the UI — the VM won't boot without it there). On other bases this is opt-in, not always-on: some third-party apps shipping crash-reporting/RASP SDKs (Bugly, Crashlytics, KSCrash, ...) call `task_swap_exception_ports()`, which the research kernel can enforce as a fatal `GUARD_TYPE_MACH_PORT`/`KOBJECT_REPLY_PORT_SEMANTICS` violation (see [upstream issue #291](https://github.com/Lakr233/vphone-cli/issues/291), reproduced and confirmed via crash logs against a `kernelcache.research.vphone600 (26.1/23B85)` build) — but it's not required for the VM itself to boot on 26.x, so it stays opt-in rather than always-on for regular/jb/exp. `applyExcGuard` in `FirmwarePipeline`/`KernelPatcher` is `iosBaseIs18 || forceExcGuard`; pass `--force-exc-guard` to `patch-firmware` (or `FORCE_EXC_GUARD=1` to the relevant `make fw_patch*` target) to enable it on a base that needs it. `iosBaseIs18` (from `iPhone-BuildManifest.plist`'s `ProductVersion`) also still gates the unrelated 18.x skywalk-netagent boot-arg workaround.

### JB-Only Kernel Methods (Reference List)

> **⚠ iOS-27 hard-gate (2026-07-20).** Every patch below whose Purpose cites "iOS 27" / "27.0 on the 26.4 kernel" is **hard-gated to a 27.x base** via `KernelJBPatcher.applyIOS27` — set by `FirmwarePipeline` from the iPhone base `ProductVersion` (mirroring the `applyExcGuard`/iOS-18 mechanism at patch 27 above; standalone `patch-component` defaults it true, override with `--target-os`). Gated set: **JB-02b, JB-02d, JB-09 (the `ops[124]` add, plus on 27 the `ops[267]` removal — handed to JB-29; the other 201..316 hooks stay), JB-10b, JB-26, JB-27, JB-28, JB-29**. On an 18.x/26.x base **none** of them run. This supersedes the per-row "No-op-in-effect for version-matched userlands" notes: those describe the effect *if applied*, but **JB-27 is NOT a no-op on 26.x** — its `cmp 0x588→0x6e0` retarget makes the 26.x userclient reject its own native 0x588 SwapEnd → dead display (the 26.5 regression that motivated the hard-gate). **Verified 2026-07-20 (JB-29 addendum 2026-07-23):** a 26.5 base produces a **byte-identical** kernelcache to pre-branch `main` (`patch-component --component kernel-jb --target-os 26.5` vs main's output — `cmp` clean, 83 records each; re-confirmed unchanged after JB-29 by `sha256`, since `ops[267]` stays blanket-neutered on 26.5), and a 27.0 base emits **95** records on the `c0ecdb4b` deployment kernel: the 11 gated records above **plus JB-29's 2** (`jb.fpfs_scoped_open.{ops_retarget,cave}`), with `sandbox_ext_267` suppressed (JB-29 owns `ops[267]` on 27 → the FileProvider-scoped trampoline instead of the blanket allow-stub).

> **Frida Stalker support is opt-in (`--frida`).** JB-23b and JB-25c run only when firmware patching is invoked with `--frida` (`vphone-cli vm create … --frida`, `vphone-cli fw patch <vm> -V jb --frida`, `patch-firmware … --frida`, `patch-component --component kernel-jb --frida`, or `make fw_patch_jb FRIDA=1`), gated by `KernelJBPatcher.applyFrida` (set by `FirmwarePipeline` from `enableFrida`). Baseline JB/EXP output is **byte-identical** when off (26.4 emits 83 records without `--frida`, 87 with — the 4 being JB-23b's 2 thread_set_state setters and JB-25c's 2 vm_map_delete gates). Frida itself is installed through the existing extra-debs mechanism: on a `--frida` create the orchestrator sets `VPHONE_FRIDA=1`, `fetch_debs.sh` resolves the latest `frida_<ver>_iphoneos-arm64.deb` (== `re.frida.server`: no `Depends`, rootless `/var/jb` layout) from the Frida GitHub releases into the debs cache, `cfw_install_{jb,exp}.sh` stage it, and the first-boot "5b/8 INSTALL EXTRA DEBS" step `dpkg -i`'s it — no APT source, marker, or dependency resolution.

| #     | Group | Method                                | Function                                                                                             | Purpose                                                                                                                                                                              | JB Enabled |
| ----- | ----- | ------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | :--------: |
| JB-01 | A     | `patch_amfi_cdhash_in_trustcache`     | `AMFIIsCDHashInTrustCache`                                                                           | Always return true + store hash                                                                                                                                                      |     Y      |
| JB-02 | A     | `patch_amfi_execve_kill_path`         | AMFI execve kill return site                                                                         | Convert shared kill return from deny to allow (superseded by C21; standalone only)                                                                                                   |     N      |
| JB-02b| C     | `patch_exec_security_policy_kill`     | XNU exec `imgp->ip_mac_return` gate (kern_exec, `os_reason_create(OS_REASON_EXEC, EXEC_EXIT_REASON_SECURITY_POLICY)` site) | Flip `cbz wN, <skip>` → unconditional `b <skip>` so the exec-time MAC-verdict `SECURITY_POLICY` kill is unreachable. **Needed to run a userland NEWER than the kernel (iOS 27.0 on the 26.4 kernel):** AMFI's exec hooks reject the newer binaries' code-sign validation category, setting `ip_mac_return != 0` → core daemons (backboardd/cfprefsd/containermanagerd/…) die at exec (`namespace 9 / code 0x8`) → boot deadlock. Validated on 27.0/26.4: 0 SECURITY_POLICY kills, daemons launch, networking + SSH come up. No-op-in-effect for version-matched userlands (ip_mac_return == 0 there, so the original cbz already skips). |     Y      |
| JB-02d| C     | `patch_container_manager_upcall`      | sandbox `_hook_cred_label_update_execve` container-manager upcall guard: the `cbz w0,<success>` after `bl <container_manager_get_process_containers>`, on the `"failed to upcall to containermanagerd for a platform app"` fall-through | Flip `cbz w0,<success>` → unconditional `b <success>` so a FAILED exec-time container-manager upcall takes the success path instead of autobox/kill. **Needed to run iOS 27.0 on the 26.4 kernel:** iOS 27 DELETED the kernel-side containermanagerd upcall — the stock 27 kernel has no `HOST_CONTAINERD_PORT` / `CM_KERN_*` protocol (container resolution moved out of the kernel), so 27's containermanagerd no longer implements the reply server. On the 26.4 kernel the exec upcall therefore fails (`MACH_SEND_INVALID_DEST`) for every 27 platform app → they are autoboxed into the restrictive `temporary-sandbox` profile, which denies e.g. `mach-lookup com.apple.backboard.display.services` → Campo (the wallpaper renderer) crash-loops (no wallpaper) + intelligencetasksd/feedbackd. Re-registering the container-manager host special port is NOT viable: the 26.4 kernel then SENDS the synchronous `CM_KERN` MIG request and BLOCKS for a reply 27 cannot produce → early-boot deadlock (verified: boot hangs, never reaches SpringBoard). Anchor is structural (string xref to `"failed to upcall to containermanagerd"` → the `cbz w0` immediately preceding the string-load `adrp`, itself immediately preceded by the upcall `bl`; backward branch to the success continuation; unique). Replacement `b` from the Keystone-backed `ARM64Encoder`. **VALIDATED on-device (2026-07-15, `17,3_27.0_24A5380h` + cloudOS 26.4 `c0ecdb4b…`, JB): iOS 27 wallpaper renders, Campo/SpringBoard/backboardd stable, boot clean (no freeze, no panic).** No-op-in-effect for version-matched userlands (there the upcall succeeds → the original cbz already branches to `<success>`). |     Y      |
| JB-03 | C     | `patch_cred_label_update_execve`      | `_cred_label_update_execve`                                                                          | Reworked C21-v3: C21-v1 already boots; v3 keeps split late exits and additionally ORs success-only helper bits `0xC` after clearing `0x3F00`; still disabled pending boot validation |     N      |
| JB-04 | C     | `patch_hook_cred_label_update_execve` | sandbox `mpo_cred_label_update_execve` wrapper (`ops[18]` -> `sub_FFFFFE00093BDB64`)                 | Faithful upstream C23 trampoline: copy `VSUID`/`VSGID` owner state into pending cred, set `P_SUGID`, then branch back to wrapper                                                     |     Y      |
| JB-05 | C     | `patch_kcall10`                       | `sysent[439]` (`SYS_kas_info` replacement)                                                           | Rebuilt ABI-correct kcall cave: `target + 7 args -> uint64 x0`; re-enabled after focused dry-run validation                                                                          |     Y      |
| JB-06 | B     | `patch_post_validation_additional`    | `_postValidation` (additional)                                                                       | Disable SHA256-only hash-type reject                                                                                                                                                 |     Y      |
| JB-07 | C     | `patch_syscallmask_apply_to_proc`     | syscallmask apply wrapper (`_proc_apply_syscall_masks` path)                                         | Faithful upstream C22: mutate installed Unix/Mach/KOBJ masks to all-ones via structural cave, then continue into setter; distinct from `NULL`-mask alternative                       |     Y      |
| JB-08 | A     | `patch_task_conversion_eval_internal` | `_task_conversion_eval_internal`                                                                     | Allow task conversion                                                                                                                                                                |     Y      |
| JB-09 | A     | `patch_sandbox_hooks_extended`        | Sandbox MACF ops (extended)                                                                          | Stub remaining 30+ sandbox hooks (incl. IOKit 201..210) + `mpo_proc_check_syscall_unix` (`ops[124]`) → allow. **The ops[124] hook is the iOS-27 DDI-mount syscall fix:** MobileStorageMounter's `mount_apfs` needs the `mount(2)` syscall (unix 167) to mount the personalized DDI at `/System/Developer`; on the 26.4-kernel / 27-userland hybrid the kernel Sandbox otherwise denies it (`Protobox: mount_apfs deny(1) syscall-unix 167`). Index calibrated against the reference-XNU `mac_policy_ops` struct order (co-verified: mpo_vnode_check_open=267, mpo_vnode_check_fsgetpath=316). Validated live on `c0ecdb4b` 26.4 (DDI auto-mounts). |     Y      |
| JB-10 | A     | `patch_iouc_failed_macf`              | IOUC MACF shared gate                                                                                | A5-v2: patch only the post-`mac_iokit_check_open` deny gate (`CBZ W0, allow` -> `B allow`) and keep the rest of the IOUserClient open path intact                                    |     Y      |
| JB-10b| A     | `patch_iouc_failed_sandbox`           | IOUC *sandbox* shared gate (string `"IOUC %s failed sandbox in process %s"`)                          | **THE iOS-27 display fix (CONFIRMED 2026-07-15).** Sibling to JB-10: the IOUserClient open path has a SEPARATE Sandbox gate beyond the MACF one. On 27 userland / 26.4 kernel it spuriously DENIES the render server (backboardd) its IOMobileFramebuffer/IOSurface/HID userclient opens (27-specific: ABSENT on native 26.4; backboardd absent from every `IOUserClientCreator`) → no present (no Apple logo) + `mainDisplay=nil` → SpringBoard FBSDisplayMonitor crash-loop. Gate shape (same fn as JB-10): `blraa` sandbox check (PAC-indirect) → `cmp w0,#0xe00002c7` (kIOReturnNotPermitted) `b.eq <ALLOW>`; `ldr w8,[sp,#x]; cbnz w8,<DENY>` (other error → deny block w/ fail-log ADRP → returns error); w0==0 path → `b <ALLOW>`. Patch rewrites `<DENY>`'s first insn → `b <ALLOW>` (deny → allow-proceed), leaving the w0==0 path intact. Anchor is structural (fail-log string xref → the CBNZ whose target encloses it → the preceding `b.eq` allow target). Verified: backboardd then holds an IOMFB userclient, `[CADisplay mainDisplay]` resolves to `LCD/primary`, SpringBoard runs with 0 crashes. |     Y      |
| JB-11 | B     | `patch_proc_security_policy`          | `_proc_security_policy`                                                                              | Bypass security policy                                                                                                                                                               |     Y      |
| JB-12 | B     | `patch_proc_pidinfo`                  | `_proc_pidinfo`                                                                                      | Allow pid 0 info                                                                                                                                                                     |     Y      |
| JB-13 | B     | `patch_convert_port_to_map`           | `_convert_port_to_map_with_flavor`                                                                   | Skip kernel map panic                                                                                                                                                                |     Y      |
| JB-14 | B     | `patch_bsd_init_auth`                 | `_bsd_init` rootauth-failure branch                                                                  | Ignore `FSIOC_KERNEL_ROOTAUTH` failure in `bsd_init`; same gate as base patch #3 when layered                                                                                        |     Y      |
| JB-15 | B     | `patch_dounmount`                     | `_dounmount`                                                                                         | Allow unmount via upstream coveredvp cleanup-call NOP                                                                                                                                |     Y      |
| JB-16 | B     | `patch_io_secure_bsd_root`            | `AppleARMPE::callPlatformFunction` (`"SecureRootName"` return select), called from `IOSecureBSDRoot` | Force `"SecureRootName"` policy return to success without altering callback flow; implementation retargeted 2026-03-06                                                               |     Y      |
| JB-17 | B     | `patch_load_dylinker`                 | `_load_dylinker`                                                                                     | Skip strict `LC_LOAD_DYLINKER == "/usr/lib/dyld"` gate                                                                                                                               |     Y      |
| JB-18 | B     | `patch_mac_mount`                     | `___mac_mount`                                                                                       | Upstream mount-role wrapper bypass (`tbnz` NOP + role-byte zeroing)                                                                                                                  |     Y      |
| JB-19 | B     | `patch_nvram_verify_permission`       | `_verifyPermission` (NVRAM)                                                                          | Allow NVRAM writes                                                                                                                                                                   |     Y      |
| JB-20 | B     | `patch_shared_region_map`             | `_shared_region_map_and_slide_setup`                                                                 | Force root-vs-process-root mount compare to succeed before Cryptex fallback                                                                                                          |     Y      |
| JB-21 | B     | `patch_spawn_validate_persona`        | `_spawn_validate_persona`                                                                            | Upstream dual-`cbz` persona helper bypass                                                                                                                                            |     Y      |
| JB-22 | B     | `patch_task_for_pid`                  | `_task_for_pid`                                                                                      | Allow task_for_pid via upstream early `pid == 0` gate NOP                                                                                                                            |     Y      |
| JB-23 | B     | `patch_thid_should_crash`             | `_thid_should_crash`                                                                                 | Prevent GUARD_TYPE_MACH_PORT crash                                                                                                                                                   |     Y      |
| JB-23b| B     | `patchThreadSetStateEntitlementFlag`  | `thread_set_state_from_user` / inlined `act_set_state_from_user` flags materialization               | **Frida Stalker existing-thread support (opt-in `--frida`).** Stalker updates an existing thread's core registers via `thread_set_state_from_user`, which passes `flags = TSSF_TRANSLATE_TO_USER \| TSSF_CHECK_ENTITLEMENT` (0x201) into `thread_set_state_internal`; the inlined `thread_set_state_allowed()` then demands `com.apple.private.thread-set-state` (which the target lacks) → `GUARD_TYPE_MACH_PORT / THREAD_SET_STATE`. Rather than NOP the entitlement check, clear TSSF_CHECK_ENTITLEMENT (bit 9) in the flags the user setters pass: rewrite `mov w6, #0x201` → `mov w6, #0x1`. This preserves TSSF_TRANSLATE_TO_USER (user-pointer translation) and leaves the independent `TH_IN_MACH_EXCEPTION` guard enforced — it only stops user-initiated `thread_set_state` from being entitlement-gated. Anchor: entitlement-string xref cluster → the single containing function (thread_set_state_internal); then its direct `b`/`bl` callers that set `w6` (the 7th-arg = flags, a calling-convention anchor, not an allocation guess) to 0x201. Both setters (`thread_set_state_from_user` + inlined `act_set_state_from_user`) are patched. No offsets/VAs/registers/bytes hardcoded; replacement from the Keystone-backed `ARM64Encoder.encodeMovzW`, Capstone-verified. Kernels without the shape are skipped (fail-open no-op). Verified on the `c0ecdb4b` 26.4 kernel (UUID `BCD06230-CCBE-8E48-50FF-D9C166D83CD5`): exactly two records at file-off `0x1D95720`/`0x1D9594C`. | `--frida` |
| JB-24 | B     | `patch_vm_fault_enter_prepare`        | `_vm_fault_enter_prepare`                                                                            | Force `cs_bypass` fast path in runtime fault validation                                                                                                                              |     Y      |
| JB-25 | B     | `patch_vm_map_protect`                | `_vm_map_protect`                                                                                    | Skip upstream write-downgrade gate. Shape A (26.1–26.4) active; **Shape B (26.5) disabled 2026-07-05** — widened the `~VM_PROT_WRITE` COW strip (vm_map.c:6202) instead of the RWX gate (vm_map.c:5997), breaking COW and crashing the debugger (SPTM `VIOLATION_ILLEGAL_MAP`). Retired on 26.5+: SPTM code-mod (debugger + Substrate tweaks) uses write-then-flip via `vm_protect(VM_PROT_COPY)` → `XNU_USER_DEBUG`, so no RWX patch is needed. |    Y/N     |
| JB-25c| B     | `patchVmMapDeleteImmutableCode`       | `_vm_map_delete` permanent-entry immutable-code exception (vm_map.c:8855)                            | **Frida Stalker repeated-`VM_PROT_COPY` fix (opt-in `--frida`).** Stalker's write-then-flip leaves a CSM-associated permanent entry at current `RW` / max `RWX`; XNU's "debugger may undo executable mappings" exception tests `entry->protection & VM_PROT_EXECUTE` (current, bit 9), which is clear, so the entry stays permanent and the next fixed overwrite returns `KERN_PROTECTION_FAILURE`. Retarget the execute test to the packed `max_protection` bit (bit 9 → bit 13; `protection:3`@7..9, `max_protection:4`@11..14 in the `[entry,#0x38]` flags word). Semantic matcher: packed-flags load + `vme_permanent` (bit 19) + the inlined `developer_mode_state()` byte-bit-0 read + the current-X test bound to the immutable-code cluster (Shape A: shares the remove-flags fallback target; Shape B: branches to the permanent-continuation target). The remove-flags bit is matched structurally (a test of a non-entry register), not by source constant (VM_MAP_REMOVE_* bit numbers drift across XNU versions). The later CSM current-X `#9` test in the same window is deliberately excluded (different branch target). Exactly two gates or fail closed; branch bytes from the Keystone-backed `ARM64Encoder.encodeTestBitBranch`, Capstone round-trip verified (sense/bit/target). Verified on the `c0ecdb4b` 26.4 kernel: two records at file-off `0x1DBE14C` (`tbz w8,#9→#0xd`) and `0x1DBE828` (`tbnz w8,#9→#0xd`). | `--frida` |
| JB-26 | B     | `patch_iomfb_swapend_variable_size`   | IOMFB userclient method-5 (SwapEnd) `__DATA_CONST` dispatch entry (`checkStructureInputSize`)        | **iOS-27 VZ-view fix, kernel half — paired with DSC force-kern (DSC-patch item 11).** The 26.4 userclient's method-5 dispatch entry hard-checks `checkStructureInputSize == 0x588`; forced-kern iOS 27 sends its native `0x6e0`. Rewrite the size field to `kIOUCVariableStructureSize (0xFFFFFFFF)` so `IOUserClient::externalMethod` accepts 27's struct and reaches the handler. Anchor (structural): the sole `__DATA_CONST` entry `{ptr(ptrauth, top-byte≥0x80), scalarIn=0, structIn=0x588, scalarOut=0, structOut=0}` (verified unique; decompressed file-off 0x9c7228). No-op-in-effect for version-matched 26.x (sends 0x588). Re-enabled 2026-07-15 (was disabled when 27 present-path was still unknown). |     Y      |
| JB-27 | B     | `patch_iomfb_swapend_handler_size`    | method-5 handler internal size gate (`cmp w2,#0x588 ; b.ne <err>`)                                   | Companion to JB-26: beyond the dispatch-table check the handler re-checks the struct size (`cmp w2,#0x588 ; b.ne <kIOReturnBadArgument>`; verified unique at decompressed file-off 0x16ae22c; success path forwards the raw struct ptr to a `vtable+0x590` paravirt swap method). Retarget the `cmp` immediate to `0x6e0` so forced-kern iOS 27's native SwapEnd reaches real swap processing (27's IOMFBSwapRec prefix matches 26.x → handler reads valid fields). Semantic anchor (`cmp w2,#imm` word + following `b.ne` decode). Enabled together with JB-26 + DSC force-kern for iOS 27. |     Y      |
| JB-28 | A     | `patch_disk_images2_client_abi`       | `com.apple.driver.AppleDiskImages2` kext: `DIDeviceCreatorUserClient::CreateDevice` + `DIDeviceIOUserClient::Connect` ABI-version gates, and the `AllocPortsArray`/`RegisterNotificationPort` notif-port sizing | **iOS-27 DDI (`/System/Developer`) auto-mount — attach layer.** `pymobiledevice3 mounter auto-mount` on the 26.4-kernel / 27-userland hybrid fails at attach: the kernel DiskImages2 driver is ABI v9, the 27 userland's DiskImages2 controller/daemon is ABI v11 (`DIDeviceCreatorUserClient::CreateDevice: Incompatible client: expected ABI version 9 actual 11`). Three layers: **GATE1** NOPs the CreateDevice controller-ABI `cmp #9 ; b.ne` reject; **GATE2b** NOPs the Connect daemon-ABI `cmp #9 ; b.ne` reject (both anchored on the C++ signature cstring → unique `cmp #9`/`b.ne`; version-robust; no-op-in-effect on version-matched userlands where ABI 9==9). **GATE2** (array + 2 bound checks) fixes a RegisterNotificationPort off-by-one (userland registers at index==maxPorts, one past the array) by widening the AllocPortsArray allocation (`lsl x1,xN,#3` → `mov x1,#0x4000`) AND both bound-check field loads (`ldrh [.,#0xd8]`/`ldr [.,#0xe8]` → `mov wD,#0x800`); applied **all-or-nothing** (widening the bound checks without the backing array would let RegisterNotificationPort write past it → corruption) and skipped/logged on builds whose notif-port codegen differs (the off-by-one is 26.4-hybrid-specific). Pairs with the sandbox ops[124] allow (JB-09) and the diskimagesiod userland patch (CFW binary-patch #13). Anchors structural (Capstone decode of the pinned function's instructions); replacement bytes from the Keystone-backed `ARM64Encoder`. **GATE2a anchor note:** the AllocPortsArray size-shift is matched on `lsl` mnemonic + destination `x1` (the unique size-writing lsl in the function) — NOT a 3-operand `lsl xd,xn,#imm` shape, because Capstone on this toolchain decodes the lsl-immediate (a UBFM alias) as **2 operands**; requiring 3 operands makes GATE2 silently skip (the all-or-nothing returns a harmless no-op). Verified on the `c0ecdb4b` 26.4 deployment kernel via `patch-component --component kernel-jb --records-out`: all five di2 records emit (`di2_createdevice_abi`, `di2_connect_abi`, `di2_allocports_size`, `di2_notif_boundcheck_d8`, `di2_notif_boundcheck_e8`) — always verify the di2 records EMIT, not merely that the JB suite reports "no failures". No-op-in-effect for version-matched userlands. |     Y      |
| JB-29 | C     | `patch_fpfs_scoped_vnode_open`        | Sandbox MACF `mpo_vnode_check_open` (`ops[267]`) → per-process trampoline code cave                  | **iOS-27 random-respring fix (fpfs balloon).** JB-09 blanket-neuters `mpo_vnode_check_open` (`ops[267]` → allow) so processes can read `/var/jb`. But FileProvider's fpfs parent-walk (`fpfs_pkg_fd_lookup` → `openbyid` climbing via `getattrlistat(ATTR_CMN_PAROBJID)`) uses the stock check's EACCES at the domain-container boundary as its terminus; neutered, the walk climbs unbounded → `ResolverService` (FileProviderResolver) balloons to ~12 GB → `vm-compressor-space-shortage` jetsam → backboardd killed → **respring** (seen on 27b4/24A5390f). Fix keeps the global bypass and enforces the real check for the FileProvider daemons only: on 27, `ops[267]` is left un-neutered (removed from JB-09's blanket list — conditional `if !applyIOS27` in `patchSandboxHooksExtended`), then retargeted to a 20-insn code-cave trampoline that inlines `current_proc` (`mrs tpidr_el1` → `ldr [+0x3F0]` uthread → `ldr [+0x18]` proc), loads `p_comm` (`+0x56C`), compares the first 8 bytes to `"Resolver"`/`"fileprov"`, and on match `b`s to the real `vnode_check_open` (restores the terminus) else returns allow (`mov x0,#0 ; ret` → `/var/jb` reads + Sileo/TrollStore icons unaffected). Register-only (x8–x10), no frame/call (~18 insns/open). Struct offsets recovered via the VZ gdb stub on vphone600; cave bytes from the Keystone-backed `ARM64Encoder`, verified by Capstone round-trip; the `ops[267]` retarget preserves the auth-rebase high bits (same encoder family as JB-09). **VALIDATED on-device (2026-07-23, `17,3_27.0_24A5390f` + cloudOS 26.4, JB, `setup_machine` deploy): resprings stop; Sileo/TrollStoreLite icons render.** Backward-compat: a 26.5 base is unaffected (`ops[267]` still blanket-neutered there) — verified byte-identical kernelcache pre-vs-post (`cmp` clean, `sha256` unchanged). See `KernelJBPatchFpfsScopedOpen.swift`. |     Y      |

### EXP-Only Kernel Methods (Reference List)

Runs in `KernelEXPPatcher.findAll()` (chained after `KernelPatcher` +
`KernelJBPatcher` for the `.exp` variant only — JB and other variants
do NOT execute these).

| #      | Group | Method                | Function                                                              | Purpose                                                                                                                                                                                                                                                                                                                                                                       | EXP Enabled |
| ------ | ----- | --------------------- | --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :---------: |
| EXP-01 | B     | `patch_hv_vmm_rename` | sysctl OID name cstring `"hv_vmm_present"` → `"Xv_vmm_present"` (Part A) + every kernel-internal occurrence of `kern.hv_vmm_present` cstring/sandbox-profile token mangled at byte 5 (Part B) | Rename the `kern.hv_vmm_present` OID's name in place (`'h' → 'X'` at offset 0 of the 14-byte cstring). After this: `sysctlbyname("kern.hv_vmm_present")` returns ENOENT; `sysctlbyname("kern.Xv_vmm_present")` returns the original int value (1). Part B mangles every kernel-internal caller — AMFI, IOCryptoAcceleratorFamily, sandbox-profile token, apfs — so they keep hitting the renamed OID. Companion to the user-mode blacklist-flip mangle in `cfw_patch_hv_vmm_dsc.py`. |      Y      |

## CFW Installation Patches

### Binary Patches Applied Over SSH Ramdisk

| #   | Patch                     | Binary                 | Purpose                                                       | Regular | Dev | JB  |
| --- | ------------------------- | ---------------------- | ------------------------------------------------------------- | :-----: | :-: | :-: |
| 1   | `/%s.gl` -> `/AA.gl`      | `seputil`              | Gigalocker UUID fix                                           |    Y    |  Y  |  Y  |
| 2   | NOP cache validation      | `launchd_cache_loader` | Allow modified `launchd.plist`                                |    Y    |  Y  |  Y  |
| 3   | `mov x0,#1; ret`          | `mobileactivationd`    | Activation bypass                                             |    Y    |  Y  |  Y  |
| 4   | Plist injection           | `launchd.plist`        | bash/dropbear/trollvnc/vphoned daemons                        |    Y    |  Y  |  Y  |
| 5   | `b` (skip jetsam guard)   | `launchd`              | Prevent jetsam panic on boot                                  |    -    |  Y  |  Y  |
| 6   | Weak dylib load injection | `launchd`              | Load short alias `/b` (copy of `launchdhook.dylib`) at launch. On by default; set `DISABLE_LAUNCHD_HOOK=1` to skip because this pid-1 hook path is boot-critical and has produced boot-analysis failures |    -    |  Y  |  Y  |
| 7   | cstring byte 5 mangle `'h' → 'X'` (`"kern.hv_vmm_present"` → `"kern.Xv_vmm_present"`) + per-page slot-hash re-attestation, BLACKLIST semantics — **EXP only** | DSC dylibs        | Companion to EXP kernel rename (`KernelEXPPatcher.patchHvVmmRename`). The mangle is applied to every DSC dylib EXCEPT those in `DONT_PATCH_INSTALL_NAMES` (sign-in / device-likeness consumers, ~15 entries). Patched dylibs query `kern.Xv_vmm_present` and get the truthful 1 (graphics / accel passthrough). Blacklisted dylibs keep the original cstring, hit ENOENT on the renamed kernel, cache 0, lie about VM presence. On `codeSigningMonitor == 2` hardware the byte-mangle alone causes `CODESIGNING/Invalid Page` SIGKILL because TXM enforces per-page hashes; the re-attestation pass recomputes the SHA-256 slot in the chunk's `CS_CodeDirectory` for every modified 16 KiB page. See `scripts/patchers/cfw_dsc_codesign.py` and `cfw_patch_hv_vmm_dsc.py`. |    -    |  -  |  -  |
| 8   | (removed — was: standalone-binary mangle in 6 rootfs Mach-Os via SSH) | n/a               | Removed in the blacklist-flip redesign. With the EXP kernel rename in place, the 6 rootfs binaries (MobileActivationMigrator, CheckerBoard, StoreKitUISceneService, storekitd, appstored, CorePrescriptionService) get the desired "cache 0 / not in a VM" behavior for free: they keep their original cstring, hit ENOENT on the renamed kernel sysctl, defensive `cbnz w0, skip` leaves the cached byte at BSS-zero. No SSH-time standalone patch needed. |    -    |  -  |  -  |
| 9   | `mov w3,#<size>` -> `mov w3,#<base-size>` in `_kern_SwapEnd` — **26.0/26.0.1 and 18.x** | DSC `IOMobileFramebuffer` | Fixes host VZ GUI black-screen with the available PCC vphone600 userclient: the userclient does an exact `checkStructureInputSize` check on external-method-5 (SwapEnd) input, so a userland whose `_kern_SwapEnd` sends a different-sized state gets `kIOReturnBadArgument` and the host display stays black (guest still renders — the Apple logo is visible over VNC, just not in the vphone-cli view). **The accepted size is a property of the base kernel, not the userland**: 26.1 base -> **0x560**, 26.4 base (xnu-12377) -> **0x588**. The 0x588 value is confirmed two ways: the sole dispatch-shaped entry in `kernelcache.*.vphone600` with `checkStructureInputSize==0x588` (scalarIn=0, scalarOut=0, structOut=0, preceded by a ptrauth code ptr, at decompressed file offset 0x9c7228), and empirically — native 26.5 userland sends 0x588 and displays correctly on this stack. Source (userland-sent) sizes observed: 18.6.2 = 0x514, 26.0/26.0.1 = 0x548, 27.0 (24A5380h) = 0x6e0. The patcher is semantic (anchors on `mov w1,#5` -> `mov w3,#imm` -> `mov x4,#0`/`mov x5,#0` -> `bl` inside `_kern_SwapEnd`) and idempotent — rewrites the size to `--target-size` regardless of source and re-attests the modified DSC page. Install gate: `26.0*` / `18.*` -> 0x560 (26.1 base). Validated after host install on `17,3_26.0_23A341`, `17,3_26.0.1_23A355`, and `17,3_18.6.2_22G100` (Apple logo renders) against the 26.1 base. **CORRECTION (2026-07-15): iOS 27.0 is NO LONGER handled here.** 27 presents the paravirt display via IOMFB's `_virt_*` callback path — external method 5 is NEVER called — so no SwapEnd *size* change can help 27 (confirmed by kernel trace + live AppleParavirtGPU idle scheduler). iOS 27 now uses **force-kern (item 11)** to route present back onto method 5; this row applies to 26.0/26.0.1/18.x only. |    Y    |  Y  |  Y  |
| 10  | Zero `maxSlide` in `dyld_cache_header` (`@0xF0`) — **iOS 27.0 / any userland whose cache overflows the 6 GiB region** | DSC `dyld_shared_cache_arm64e` header | Fixes pid-1 `launchd` panic at boot on the vphone600 26.x kernel. The kernel reserves `SHARED_REGION_SIZE_ARM64 = 0x180000000` (6 GiB) and, at map time, needs room for the cache's mapped span **plus** the header `maxSlide` (ASLR range). iOS 27.0's cache (span `0x17c830000` ≈ 5.95 GiB) + `maxSlide 0x20000000` = `0x19c830000` > 6 GiB, so `_shared_region_map_and_slide` returns `ENOMEM`, dyld cannot map `libSystem.B.dylib`, and `launchd` panics (`initproc failed to start`). Zeroing `maxSlide` (LE u64) in the main chunk maps the cache at slide 0 (fits with ~58 MiB spare). Install gate: **`27.*`** (hard-gated in `cfw_install.sh` as of 2026-07-20 — an 18.x/26.x base skips it entirely). The patcher additionally self-gates (`patch-dsc-maxslide`): no-op unless span + maxSlide > `0x180000000`, kept as defense-in-depth so 26.x / 18.x are untouched even if the install gate were removed. **Opt-in for non-27 bases** (added 2026-07-23, **removed 2026-10-01, T13a**, matching upstream `d930e50`): `FORCE_DSC_MAXSLIDE=1` used to run `patch-dsc-maxslide --force` on 18.x/26.x. It and `--force-dsc-maxslide` on `vm create` / `cfw install` no longer exist; `cfw_install_host.sh` reports the variable as removed and does not forward it. Non-27 bases keep their native slide. `patch-dsc-maxslide --force` remains for running the verb by hand; `cfw_install.sh` never passes it. Since T13a the patcher also refuses, without writing, a header that fails the upstream checks (short header, `mappingOffset` before `maxSlide`, no file-offset-0 mapping of the main chunk, `sharedRegionStart` not the lowest mapped address, `sharedRegionSize` below the mapped span, 64-bit overflow). **No** page re-attestation (header metadata, not a `cs_validate`'d code page — confirmed empirically). Validated on `17,3_27.0_24A5380h` + cloudOS 26.4 (`c0ecdb4b…`): `dyld cache mapped system-wide`, launchd reaches first unlock, vphoned connects as iOS 27.0.0, 0 panics. See `scripts/patchers/cfw_patch_dsc_maxslide.py`. |    Y    |  Y  |  Y  |
| 11  | Retarget public `_IOMobileFramebufferSwap*` trampolines -> `b _kern_Swap*` (force-kern) — **iOS 27.0** | DSC `IOMobileFramebuffer` | **iOS-27 VZ-view (host paravirt-GPU scanout) fix, userland half.** The host `VZVirtualMachineView` is fed by the guest `AppleParavirtGPU` scanout, which the 26.4 kernel drives ONLY from the IOMFB userclient SwapEnd (external method 5) — the `_kern_Swap*` path. iOS 27 defaults the paravirt display's present to IOMFB's parallel `_virt_Swap*` path (`_virt_SwapEnd` does no userclient call — it invokes an in-process callback `blraaz [conn+0xe68]` and hands the IOSurface to a virtual-display consumer), so the paravirt GPU never scans out → host VZ window black (guest still composites; GUI visible over in-guest TrollVNC; AppleParavirtGPU `SchedulerState` idle). The public `_IOMobileFramebufferSwap*` entrypoints are thin trampolines (`cbz x0; ldr xN,[x0,#slot]; cbz xN; braaz xN`) that tail-call the per-connection swap fp (kern or virt impl). This patch rewrites each trampoline's first insn to `b _kern_Swap<Name>`, forcing present onto method 5 regardless of how 27 classified the display (tail-call, args intact → behaviourally identical to selecting the kern fp). Fully dynamic: public + `_kern_` addrs resolved by name via `ipsw dyld symaddr`, trampoline shape verified by Capstone, branch bytes from Keystone `asm_at()`, modified DSC code pages re-attested. Requires ≥{SwapBegin,SwapEnd,SwapSetLayer} or raises (dry-run retargets 31 entrypoints on 24A5380h, skips 4 non-trampolines). **Pairs with the JB kernel patches (`patchIomfbSwapEndVariableSize` + `patchIomfbSwapEndHandlerSize`)** which relax the 26.4 userclient's two exact `0x588` size gates to accept 27's native `0x6e0` IOMFBSwapRec (prefix matches 26.x, so the paravirt swap handler reads valid fields). Install gate: `27.*`. See `scripts/patchers/cfw_patch_iomfb_force_kern.py`. **VALIDATED on-device (2026-07-15, `17,3_27.0_24A5380h` + cloudOS 26.4 `c0ecdb4b…`, JB): iOS 27 userland renders AND is interactive in the native VZ view (not just TrollVNC); clean boot — no `kIOReturnBadArgument`/SwapEnd rejection/panic.** Runtime confirmed 31 entrypoints retargeted (4 non-trampoline setters left on virt). |    Y    |  Y  |  Y  |
| 12  | NOP `-[_LSDModifyClient clientIsEntitledForEmbeddedRegistrationOperations]` entitlement gate + per-page re-attest — **iOS 27.0** | DSC `CoreServices` (LaunchServices) | **iOS-27 app-registration fix.** lsd gates `-[_LSDModifyClient performPostInstallationRegistration:operationUUID:reply:]` (and the containerized/rebuild registration paths) behind `clientIsEntitledForEmbeddedRegistrationOperations`, which does `xpc_connection_copy_entitlement_value` on the XPC peer for any of `com.apple.private.coreservices.lsaw` / `com.apple.private.installcoordinationd.daemon` / `com.apple.private.coreservices.can-register-install-results`. A client without one gets `NSOSStatusErrorDomain -54` (permErr, `LSDModifyService.mm:1639`), so `registerApplicationDictionary:` / `registerContainerizedApplicationWithInfoDictionaries:` fail and no app can (re)register — blocking vphoned's installer, TrollStore, and uicache/Sileo alike. The entitlement route is a dead end even for a launchd platform daemon (vphoned) whose validated csblob (`csops CS_OPS_ENTITLEMENTS_BLOB`) contains all three: LS registration is proxied, so the XPC peer lsd inspects is not the registering process. Fix: NOP the final `cbz w0, <not_entitled>` (the conditional branch whose fall-through sets the `mov w<reg>,#1` result) so the method always returns YES. Fully dynamic: method resolved via the DSC's own `.symbols` in-image local-symbol table (ipsw `symaddr -a`/`a2s` time out on this cache), gate located by control-flow shape in Capstone, NOP from Keystone `asm("nop")`, modified 16 KiB page re-attested (`cfw_dsc_codesign.py`; TXM enforces per-page). The resulting CDHash change is accepted by the JB always-true AMFI cdhash-trust patch. Install gate: **`27.*`** (hard-gated in `cfw_install.sh` as of 2026-07-20 — an 18.x/26.x base does not apply it). The patcher additionally self-gates (`patch-lsd-embedded-reg`): no-op on pre-iOS-27 userlands where the method is absent. **Pairs with vphoned's `vp_register_path` containerized-registration fallback** (`registerContainerizedApplicationWithInfoDictionaries:...:registrationError:`, treating a nil `registrationError` as success since it returns NO even when it registers). Also paired with **`/cores/vpregister`** (built + deployed by `cfw_install_jb.sh` / `cfw_install_exp.sh`, invoked by `vphone_jb_setup.sh` at first boot — 27-gated by DEPLOYMENT: `cfw_install_jb.sh`/`cfw_install_exp.sh` copy `/cores/vpregister` only when the mounted rootfs `SystemVersion.plist` is `27.*`, and the setup script's `[ -x /cores/vpregister ]` presence check is the runtime gate. Do NOT gate the invocation on a guest `sw_vers` check — the hybrid guest does not reliably report the 27 userland version at first boot, which silently skipped registration): it registers JB app bundles (Sileo) via the same containerized API, because `uicache -a`'s `registerApplicationDictionary:` is a deprecated no-op on iOS 27 (lsd logs *"you cannot use ... to register applications anymore. These interfaces have been deprecated for years."*). **VALIDATED (2026-07-17, `17,3_27.0_24A5380h` + cloudOS 26.4, JB): -54 gone; Sileo registers (`uicache -l` 0→1) via `vpregister`; vphoned installs+registers a test IPA (`com.vphone.vptest`) to `/var/containers/Bundle/Application/` end-to-end. Clean boot (re-attest correct; no CoreServices page rejection).** See `scripts/patchers/cfw_patch_lsd_embedded_reg.py` and `scripts/vphoned/vpregister.m`. **FIX (2026-08-10):** `_find_gate` only matched the live `cbz`/`cbnz` branch shape, so re-running `cfw install` (host-mount flow, `myphone` VM, `17,3_27.0_24A5390f`) against a cache where this gate was already NOP'd from a prior pass raised `ValueError: ... entitled-result gate ... not found` instead of recognizing the idempotent state (unlike the Cryptex/IOMFB steps, which log `already ... idempotent` and skip cleanly). Confirmed live via host-mount disassembly: the third check's `bl <check3>` is followed by a bare `nop` at the gate site (exact match against `asm("nop")` bytes) immediately before `mov w20, #1` — i.e. already patched. `_find_gate` now also matches `nop` immediately preceding `mov w<reg>,#1` as an already-patched gate, so a re-run just re-attests the page instead of erroring. |    Y    |  Y  |  Y  |
| 13  | `mov x0,#1; ret` on `-[DIDiskArb isMountCompleteWithExpectedCount:diskTracker:]` — **iOS 27.0** | `diskimagesiod` | **iOS-27 DDI (`/System/Developer`) auto-mount — mount-gate.** After the personalized DDI attaches (kernel side: JB-28 + JB-09), MobileStorageMounter waits on diskimagesiod's `-[DIDiskArb waitForDAMountWithExpectedCount:diskTracker:]` before it does the real (nobrowse) mount at `/System/Developer`. That wait loops until `isMountComplete` (= `callbackReached \|\| (appearedDiskCount>=expectedCount && mountedDiskCount>=mountableDiskCount)`) is YES; on the 26.4-kernel / 27-userland hybrid it never becomes true (not all of the DMG's IOMedia "appear" to diskimagesiod's DiskArbitration session, and diskarbitrationd never auto-mounts the volume), so the wait hangs and pmd3 times out. diskimagesiod itself does NOT mount the DDI (its `-[DIDiskArb mountWithDeviceName:...]` is dead code) — it only gates MobileStorageMounter. Forcing `isMountComplete` → YES lets the wait return so MobileStorageMounter proceeds. IMP resolved via LC_SYMTAB or ObjC metadata (selector → `__objc_selrefs` → `__TEXT,__objc_methlist` relative method list → IMP); prologue overwritten `mov x0,#1 ; ret` (safe — the method returns to the caller's unsigned LR without pushing a frame). **Gated to 27.\*** in `cfw_install.sh` (same `$IOS_VERSION` as the DSC patches): on a version-matched userland the native wait completes correctly and forcing it early could race the real mount, so it is NOT applied there. Embedded sandbox profile + private DA/apfs entitlements preserved on re-sign (`ldid_sign_ent`). **Validated on `c0ecdb4b` 26.4 + 27.0 userland: `pmd3 mounter auto-mount` → rc=0, DDI at `/System/Developer`, idempotent across fresh boots.** See `scripts/patchers/cfw_patch_diskimagesiod.py`. |    Y    |  Y  |  Y  |
| 14  | Merge backboard/frontboard launch mach-services into `com.apple.security.exception.mach-lookup.global-name` + `ldid_sign_ent` re-sign — **iOS 27.0** | `/Applications/Campo.app/Campo` | **iOS-27 Campo (wallpaper renderer) crash-loop fix — sandbox half.** Campo declares `com.apple.private.sandbox.profile:embedded = temporary-sandbox` + `no-container`, so it runs under the `temporary-sandbox` profile. On the 26.4 vphone600 kernel that builtin profile predates iOS 27 and DENIES the `mach-lookup` of the backboard/frontboard launch services, so `BKSDisplayServicesStart` (looks up `com.apple.backboard.display.services`) and then `+[BKSHIDEventDeliveryManager sharedInstance]` (HID) fail, log *"backboardd isn't running -- or we couldn't talk to it"*, and `brk #0` ~34 ms after launch → continuous crash-loop, no wallpaper (launchd eventually throttles it off). **JB-02d is NOT sufficient here:** it stops the exec-time container-manager-upcall autobox *KILL*, but Campo is still placed in `temporary-sandbox` (its own declared profile — confirmed the JB-02d `b`-flip is present in the running kernel yet Campo still traps), and that profile still denies the lookups. Fix: append the needed services to Campo's OWN `com.apple.security.exception.mach-lookup.global-name` array — the Apple-sanctioned escape hatch, which `temporary-sandbox` honors (Campo already ships ~20 such exceptions; these launch services simply aren't among them because 27's profile allows them directly). Services added (backboard names exact, from `com.apple.backboardd.plist` MachServices): `com.apple.backboard.display.services`, `com.apple.iohideventsystem`, `com.apple.CARenderServer`, `com.apple.backboard.hid.services`, `com.apple.backboard.hid-services.xpc`, `com.apple.backboard.TouchDeliveryPolicyServer`, `com.apple.backboard.system-app-server`, `com.apple.backboard.watchdog`, `com.apple.backboard.oswatchdog`, `com.apple.backboard.altsysapp`, `com.apple.AttentionAwareness`, `PurpleSystemEventPort`, `PurpleWorkspacePort`, `com.apple.frontboard.systemappservices`, `com.apple.frontboard.workspace`, `com.apple.frontboardservices.systemappmanager`, `com.apple.frontboard.watchdog`. Merge is done by the external helper `scripts/patchers/campo_mach_lookup_exceptions.py` (Python `plistlib`, not `plutil` — the entitlement key contains dots that `plutil` keypaths would mis-split; idempotent, preserves the existing array); re-signed with the JB `signcert.p12` via `ldid_sign_ent` (AMFI enforcement is relaxed on the research VM, so the re-signed cdhash loads and the entitlements are honored). Applied at host-mount build time in `cfw_install_jb.sh` / `cfw_install_exp.sh` step **[JB-3b]**, **hard-gated to `27.*`** via the mounted rootfs `SystemVersion.plist` `ProductVersion` (same gate as the vpregister/DSC patches) — skipped entirely on 26.x/18.x, which don't need it and where `Campo.app` also exists. **VALIDATED on-device (2026-07-21, `17,3_27.0_24A5390f` + cloudOS 26.4, JB): Campo launches and stays up (stable pid, no BKSDisplayServicesStart/BKSHIDEventDeliveryManager trap, no crash-loop); first-cut display-only exception advanced the trap from display→HID, confirming the mechanism, then the full service set cleared it.** See `scripts/cfw_install_jb.sh` / `scripts/cfw_install_exp.sh` step JB-3b and the merge helper `scripts/patchers/campo_mach_lookup_exceptions.py`. |    -    |  -  |  Y  |
| 15  | Derive `matched` from `error_code` + drop the `brk #1` in libxpc `_xpc_token_satisfies_lwcr` (`cset w8,ne; eor w8,w0,w8; tbz w8,#0` → `cset w0,eq; nop; nop`) + per-page re-attest — **iOS 27.0** | DSC `libxpc.dylib` | **iOS-27 daemon crash-loop fix (Lightweight Code Requirement).** iOS 27 lets an XPC server pin a "lightweight code requirement" (LWCR) on its listener — `xpc_connection_set_peer_lightweight_code_requirement`, or the Swift `XPCPeerRequirement.hasEntitlement(_:)` wrapper (→ `xpc_peer_requirement_create_entitlement_exists` → `_xpc_peer_requirement_create_lwcr_entitlement_requirement` → `xpc_peer_requirement_create_lwcr`). Creating the requirement runs a self-check, `_xpc_token_satisfies_lwcr`, which calls an internal matcher returning a `matched` bool (w0) plus a `match_result.error_code` (`AICMR_MATCH == 0`), then hard-asserts they agree (`matched == (error_code == 0)`) via `_os_crash_msg` → `brk #1`. On stock iOS the two always agree; under our JB code-signing environment the matcher's query writes `error_code = MATCH(0)` yet returns a failure status, so the matcher yields the forbidden `(matched=0, error_code=0)` pair and libxpc aborts. Because EVERY daemon that pins an entitlement peer-requirement at startup hits it, `intelligencetasksd` / `searchpartyd` / `transparencyd` / `bluetoothd` (and others) crash-loop continuously from boot (launchd re-spawn + ReportCrash churn). Fix: recompute `matched` from `error_code` and make the abort unreachable — `cset w8,ne; eor w8,w0,w8; tbz w8,#0,<abort>` → `cset w0,eq; nop; nop`; the function now returns `(error_code == 0)`, which reproduces stock's verdict when the two agree and resolves the contradiction toward "satisfied" when error_code says MATCH (real allow/deny for genuinely (un)satisfied peers is unchanged, since those set `error_code` != 0). Fully dynamic: resolved via the DSC's own `.symbols` in-image local-symbol table as `__xpc_token_satisfies_lwcr` (the double-underscore mangled name; a single-underscore lookup silently skipped every iOS-27 build until fixed 2026-08-11), the check located by control-flow shape in Capstone (`cset wC,ne; eor wE,w0,wC; tbz wE,#0`), replacements from Keystone, modified 16 KiB page re-attested (`cfw_dsc_codesign.py`; TXM enforces per-page; CDHash change accepted by the JB always-true AMFI cdhash-trust patch). Install gate: **`27.*`** (in `cfw_install.sh`, same block as maxSlide/lsd). Patcher additionally self-gates (`patch-xpc-lwcr`): no-op on pre-iOS-27 userlands where the symbol is absent. **VALIDATED on-device (2026-07-22, `17,3_27.0_24A5390f` + cloudOS 26.4, JB, host-mount deploy): patched bytes live (`e0179f1a 1f2003d5 1f2003d5`); the four LWCR crash-loopers disappear from the crash census after boot; launchd itself (which links libxpc) boots clean past first unlock — patch does not brick boot. NOTE: does NOT stop the resprings — those are a separate `FileProviderResolver` ResolverService memory-balloon → jetsam → backboardd kill (see investigation notes).** See `scripts/patchers/cfw_patch_xpc_lwcr.py`. |    Y    |  Y  |  Y  |
| 16  | NOP the sysctl-error `b.eq <os_crash>` in libSystem `___os_lockdown_mode_enabled_block_invoke` (`cmn w0,#1; b.eq <crash>` → `nop`) + per-page re-attest — **iOS 27.0** | DSC `libSystem` (`lockdown_mode.c`) | **iOS-27 launchd (pid 1) boot-panic fix.** iOS 27's `os_lockdown_mode_enabled()` resolves Lockdown Mode once via `sysctlbyname("security.mac.lockdown_mode_state_public", &out, &len, 0, 0)`; on a -1 return it `os_crash`es (`lockdown_mode.c:os_lockdown_mode_enabled_block_invoke:47`). The vphone base kernel (cloudOS 26.x) does not implement that MAC sysctl, so the call returns -1/ENOENT and the first process to query Lockdown Mode after "Continuing system boot" aborts — that process is launchd (pid 1), so the kernel panics `initproc exited -- exit reason namespace 2 subcode 0x6 description: none`. b4 (24A5390f) boots on the same kernel; the sysctl query is new in b5 (24A5408d). The block pre-zeroes its output buffer (`stp x8, xzr, [sp]`), so NOPping the error branch falls through to the normal path, reads 0, records "Lockdown Mode disabled", and returns cleanly; on a kernel that implements the sysctl the branch is never taken (w0==0), so the patch is behavior-neutral. Dynamic: `___os_lockdown_mode_enabled_block_invoke` resolved via the DSC's own `.symbols` local-symbol table; the `cmn wR,#1; b.eq` sysctl-error idiom located by control-flow shape in Capstone; NOP from Keystone; modified 16 KiB page re-attested (`cfw_dsc_codesign.py`). Install gate: **`27.*`** (same block as maxSlide/lsd/lwcr). Self-gates: no-op where the symbol is absent (pre-iOS-27 userlands). **Root-caused + verified on-device 2026-08-11** (`17,3_27.0_24A5408d` + cloudOS 26.4, JB): abort message read live via the kernel GDB stub (patched `_abort`→`b .` to freeze launchd's spinning vCPU, then read its registers + the libSystem crash-info global) = `lockdown_mode.c:os_lockdown_mode_enabled_block_invoke:47: No such file or directory`; with the NOP applied the panic is gone and boot continues past "Got first unlock" into normal daemon startup. See `scripts/patchers/cfw_patch_lockdown_mode.py`. |    Y    |  Y  |  Y  |

### Upstream iOS 27 integration validation (2026-08-17)

The `codex/upstream-c9ad3c7-integration` branch preserves upstream history through
`f92d82c`. The incoming iOS 27 patch IDs, `applyIOS27` gating, CFW phase gating,
and intended control-flow targets remain unchanged. The integration replaces
rendered-operand parsing and inline replacement instructions in the reviewed
patchers with typed Capstone operands and computed or assembler-backed encoders.

| Patch | Anchor and validation | Replacement | Gate | Local evidence |
| --- | --- | --- | --- | --- | --- |
| `exec_security_policy_kill` | Typed `mov/movz w0,#9; mov/movz w1,#8`, same-register `ldr wN; cbz wN,<forward>` | `ARM64Encoder.encodeB` to the decoded CBZ target | `applyIOS27` | Swift compile, encoder round-trip tests, static guardrail test |
| `iouc_sandbox_gate` | Failure-string xref; typed `cbnz wN,<deny>` enclosing the xref; typed in-function `b.eq <allow>` | `ARM64Encoder.encodeB` from deny entry to decoded allow target | `applyIOS27` | Swift compile and static guardrail test |
| `iomfb_swapend_handler_size` | Typed `cmp w2,#0x588; b.ne` with unique-hit requirement | `ARM64Encoder.encodeCmpImmediateW(rn:2,imm12:0x6e0)` | `applyIOS27` | Capstone round-trip encoder test and static guardrail test |
| `iomfb_swapend_variable_size` | Unique `IOExternalMethodDispatch` table shape in `__DATA_CONST` | Data-field update to `kIOUCVariableStructureSize` | `applyIOS27` | Emitted in the live cloudOS 26.4 / iOS 27.0 24A5408d JB+Frida firmware patch run |
| `container_manager_upcall_force_success` | Failure-string xref; typed adjacent `bl; cbz w0,<backward executable target>` | `ARM64Encoder.encodeB` to the decoded success target | `applyIOS27` | Swift compile and static guardrail test |
| `di2_*` | C++/AssertMacros string anchors and typed operands; allocation and both bound checks remain all-or-nothing | Central `ARM64.nop` and computed MOVZ encoders | `applyIOS27` | Live cloudOS 26.4 run emitted all five required records: both ABI gates, allocation widening, and both notification bound checks |
| `jb.fpfs_scoped_open.*` | Sandbox ops table plus a 20-instruction cave validated through typed Capstone operands and branch targets before either emit | Named `ARM64Encoder` calls and central `ARM64.ret` | `applyIOS27` | 80-byte cave round-trip test verifies both daemon branches, allow return, and real-hook branch |
| IOMFB DSC force-kern | Named public/`_kern_` symbols and typed `cbz x0; ldr xN,[x0]; cbz xN; br* xN` shape | Keystone `asm_at()` branch | iOS 27 CFW phase | Python positive/negative semantic tests and static guardrail test |
| diskimagesiod mount gate | Symbol/ObjC metadata IMP lookup; typed prologue classifier accepts the original immediate `x29/x30` frame and the 24A5408d ARM64e callee-saved-first frame only when stack allocation, bounded spills, frame record, and frame-pointer offsets are consistent; detects an existing patch and rejects unknown input | Central Keystone-backed `MOV_X0_1` and `RET` | iOS 27 CFW phase | Real 24A5408d prefix (`pacibsp; stp x22,x21,[sp,#-0x30]!; ...`) regression fixture plus negative tests for out-of-frame records, non-spill instructions, missing writeback, unrelated, and truncated prefixes; live CFW applied at foff `0x320B4`, then CoreDevice `ddiServices --auto-mount-ddis` returned `contentIsCompatible: true` and `isUsable: true` |
| libxpc LWCR | Function-local original consistency idiom or strict already-patched flow (`bl`; same-register `ldr`/`cmp #0`; `cset w0,eq`; `nop`; `nop`) | Keystone `cset w0,eq` plus two NOPs | iOS 27 CFW phase | Original/already-patched/wrong-data-flow tests; live re-run recognized edits at `0x1805DD630`, `0x1805DD634`, and `0x1805DD638` without rewriting |
| lockdown-mode sysctl gate | In-image symbol plus `bl`-preceded `cmn wR,#1`; accepts either the original `b.eq` or an already-patched `nop` | Keystone NOP | iOS 27 CFW phase | Original/already-patched/missing-call tests; live re-run recognized NOP at `0x237D0C2C0` and continued |
| DSC maxSlide | Dyld cache header span/maxSlide check, after the header is corroborated against the mapping table (T13a); the `FORCE_DSC_MAXSLIDE=1` opt-in was removed 2026-10-01 | Header data update; no instruction replacement | iOS 27 | Live 24A5408d DSC: span `0x17CE04000`, maxSlide `0x20000000` overflowed the `0x180000000` region and was set to zero; CFW re-run reported the zero-slide cache fits |
| EXC_GUARD | Existing semantic `_thread_guard_violation` discovery | Central return instruction | iOS 18 automatic; otherwise `--force-exc-guard` | Integrated from upstream; no compatible local firmware fixture was available |
| Frida thread-set-state | Entitlement string xrefs recover one containing function; typed direct branch targets and typed `mov/movz w6,#0x201` caller anchors | `ARM64Encoder.encodeMovzW` retains `TSSF_TRANSLATE_TO_USER` and clears `TSSF_CHECK_ENTITLEMENT` | Explicit `--frida`, cloudOS 26.4+ in the pipeline | Live cloudOS 26.4 run changed both callers at foff `0x1D95720` and `0x1D9594C` from `w6=#0x201` to `w6=#1` |
| Frida vm-map-delete | Typed `ldr wF,[xE,#0x38]`, permanent-bit, developer-mode, current-X and shared-target control-flow anchors; exactly two gates or fail closed | `ARM64Encoder.encodeTestBitBranch` changes bit 9 to bit 13 while retaining register, sense and target | Explicit `--frida`, cloudOS 26.4+ in the pipeline | Live cloudOS 26.4 run retargeted both gates: `tbz` at foff `0x1DBE14C` and `tbnz` at foff `0x1DBE828`, bit 9 to bit 13 |

Validation limits:

- The compatible iOS 27.0 `24A5408d` and cloudOS 26.4 `23E5207q` images were
  prepared locally. The JB+Frida firmware pipeline completed with 9 components,
  168 patch records, both Frida matcher pairs, and all five DiskImages2 records.
- The patched image completed restore, CFW+JB installation, APFS live-snapshot
  selection, first boot, and a second boot. vphoned reported iOS 27.0.0 on both
  boots; no launchd panic occurred.
- CoreDevice DDI auto-mount completed with exit code 0 and reported compatible,
  usable DDI services. Guest serial output recorded the `Xcode_iOS_DDI` APFS
  volume mount requested by MobileStorageMounter.
- First-boot setup installed Sileo 2.5.1 and Frida Server 17.17.0. `vpregister`
  registered Sileo and TrollStore Lite with zero failures; `uicache -l` returned
  `org.coolstar.SileoStore`. On the second boot, Frida Server was running and its
  guest-local TCP port 27042 accepted a connection.
- A host Frida client instrumentation session was not run. Frida validation in
  this run covers firmware records, package installation, daemon launch, reported
  version, and protocol-port availability.
- The VM was launched headless. Native `VZVirtualMachineView` display output and
  interactive input were not visually verified in this run.
- `research/reference/xnu`, repo-exported symbol JSON files, and
  `ipsws/patch_refactor_input` comparison fixtures remain absent. The final Swift
  run passed 179 of 193 tests; 13 failures require those missing fixtures and one
  compares the macOS `/private/var` and `/var` aliases as distinct paths.

### Installed Components

| #   | Component                  | Description                                                                                                        | Regular | Dev | JB  |
| --- | -------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Cryptex SystemOS + AppOS   | Decrypt AEA + mount + copy to device                                                                               |    Y    |  Y  |  Y  |
| 2   | GPU driver                 | AppleParavirtGPUMetalIOGPUFamily bundle                                                                            |    Y    |  Y  |  Y  |
| 3   | `iosbinpack64`             | Jailbreak tools (base set)                                                                                         |    Y    |  Y  |  Y  |
| 4   | `iosbinpack64` dev overlay | Replace `rpcserver_ios` with dev build                                                                             |    -    |  Y  |  -  |
| 5   | `vphoned`                  | vsock HID/control daemon (built + signed)                                                                          |    Y    |  Y  |  Y  |
| 6   | LaunchDaemons              | bash/dropbear/trollvnc/rpcserver_ios/vphoned plists                                                                |    Y    |  Y  |  Y  |
| 7   | Procursus bootstrap        | Bootstrap filesystem + optional Sileo deb                                                                          |    -    |  -  |  Y  |
| 8   | BaseBin hooks              | `systemhook.dylib` / `launchdhook.dylib` / `libellekit.dylib` -> `/cores/` plus `/b` alias for `launchdhook.dylib` |    -    |  -  |  Y  |
| 9   | `TweakLoader.dylib`        | Lean user-tweak loader built from source and installed to `/var/jb/usr/lib/TweakLoader.dylib`                      |    -    |  -  |  Y  |

### `kern.hv_vmm_present` user-mode patcher (EXP only)

Companion to the EXP kernel patcher (`KernelEXPPatcher.patchHvVmmRename`).
Mangles byte 5 of every `kern.hv_vmm_present` cstring inside DSC dylibs
EXCEPT those in `DONT_PATCH_INSTALL_NAMES` (sign-in / device-likeness
consumers, ~15 entries). Patched dylibs query the renamed OID and get the
truthful 1 (graphics + accel passthrough); blacklisted dylibs keep the
original cstring, hit ENOENT on the renamed kernel, and defensively cache 0
("not running on a VM") for sign-in / device-attestation surfaces.
Source-of-truth research: `research/hv_vmm_present_usermode_xrefs.md`.

JB and other variants are NOT affected by this patcher.

**Patch shape (every site)** — cstring mangle:

```
Before (cstring section bytes, 20 bytes total):
    "kern.hv_vmm_present\0"
    6B 65 72 6E 2E 68 76 5F 76 6D 6D 5F 70 72 65 73 65 6E 74 00

After (1 byte change at offset 0):
    "Xern.hv_vmm_present\0"
    58 65 72 6E 2E 68 76 5F 76 6D 6D 5F 70 72 65 73 65 6E 74 00
    ^^
```

The kernel's name-to-MIB translation fails with `ENOENT` when the
caller asks for `"Xern.hv_vmm_present"`, so `sysctlbyname` returns
-1. The canonical post-call check (`cbnz w0, skip` or
`cmp w0,#0 ; b.ne skip`) then takes the skip-cache path; the cached
"is_vmm" byte stays at its initial value (BSS-zero = 0).

We don't modify executable code at all — only one byte of read-only
string data. The kernel call still happens (with the wrong name), so
any sysctl-tracing infrastructure can still see activity.

Idempotent: a re-scan for the literal `"kern.hv_vmm_present\0"` finds
no occurrences in already-mangled dylibs, so the patcher does no work
on a re-run.

**DSC-side patches** — driven by an explicit whitelist
(`PATCH_INSTALL_NAMES` in `scripts/patchers/cfw_patch_hv_vmm_dsc.py`)
applied to chunks under
`SystemOS/System/Library/Caches/com.apple.dyld/`. Comment a line in
the whitelist to skip that dylib on the next install — useful for
bisecting which consumer is responsible for an observable change.

| Dylib                                                     | Component role (paraphrased)                                  |
| --------------------------------------------------------- | ------------------------------------------------------------- |
| `usr/lib/libMobileGestalt.dylib`                          | Backs `MGCopyAnswer("hv-vmm-present")` — highest fan-in       |
| `PrivateFrameworks/AAAFoundation.framework/AAAFoundation` | Apple ID anti-abuse plumbing                                  |
| `PrivateFrameworks/AuthKit.framework/AuthKit`             | Sign-in-with-Apple-ID / iCloud auth                           |
| `PrivateFrameworks/IDSFoundation.framework/IDSFoundation` | Apple Identity Service core (iMessage / FaceTime backbone)    |
| `PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity` | Device-binding / device class identity                     |
| `PrivateFrameworks/DeviceCheckInternal.framework/...`     | DeviceCheck attestation                                       |
| `PrivateFrameworks/MobileActivation.framework/...`        | Activation flow                                               |
| `PrivateFrameworks/ApplePushService.framework/...`        | APNS client (claims device characteristics on connect)        |
| `PrivateFrameworks/AppStoreUtilities.framework/...`       | Store / IAP support                                           |
| `PrivateFrameworks/CorePrescription.framework/...`        | Health prescription store sync gate                           |
| `PrivateFrameworks/CoreCDP.framework/CoreCDP`             | CDP (cloud key-vault / iCloud Drive plumbing)                 |
| `PrivateFrameworks/EmailFoundation.framework/...`         | Mail account heuristics                                       |
| `PrivateFrameworks/PhotoFoundation.framework/...`         | Photos asset visibility heuristics                            |
| `PrivateFrameworks/FindMyBase.framework/FindMyBase`       | Find My anti-spoof                                            |
| `PrivateFrameworks/AirPlaySupport.framework/...`          | AirPlay receiver gate                                         |
| `PrivateFrameworks/TrialServer.framework/TrialServer`     | A/B / trial-rollout exclude-VM gate                           |
| `PrivateFrameworks/VisionKitCore.framework/VisionKitCore` | VisionKit                                                     |
| `PrivateFrameworks/DVTInstrumentsUtilities.framework/...` | Xcode Instruments support                                     |
| `PrivateFrameworks/WatchdogServiceManagement.framework/...` | Watchdog manager                                            |
| `Frameworks/CoreVideo.framework/CoreVideo`                | CoreVideo pipeline                                            |

**Standalone-binary patches (6 files, applied to the device rootfs
over SSH)**

| Path                                                                                              | Role                                                          |
| ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `/System/Library/DataClassMigrators/MobileActivationMigrator.migrator/MobileActivationMigrator`   | Activation migration helper                                   |
| `/Applications/CheckerBoard.app/CheckerBoard`                                                     | Apple internal accessibility test app                         |
| `/Applications/StoreKitUISceneService.app/StoreKitUISceneService`                                 | StoreKit UI host                                              |
| `/System/Library/Frameworks/StoreKit.framework/Support/storekitd`                                 | StoreKit / IAP daemon                                         |
| `/System/Library/PrivateFrameworks/AppStoreDaemon.framework/Support/appstored`                    | App Store daemon                                              |
| `/System/Library/PrivateFrameworks/CorePrescription.framework/XPCServices/CorePrescriptionService.xpc/CorePrescriptionService` | CorePrescription XPC service       |

**Explicitly NOT patched (compute / accel — patching here turns off
VM fast-paths that exist so the lib doesn't try to touch real silicon
ANE / AGX / hardware codecs):**

```
System/Library/Frameworks/CoreML.framework/CoreML
System/Library/PrivateFrameworks/Espresso.framework/Espresso
System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine
System/Library/PrivateFrameworks/CoreRE.framework/CoreRE
System/Library/PrivateFrameworks/RenderBox.framework/RenderBox
System/Library/PrivateFrameworks/WebGPU.framework/WebGPU
System/Library/PrivateFrameworks/caulk.framework/caulk
System/Library/PrivateFrameworks/IOSurfaceAccelerator.framework/IOSurfaceAccelerator
System/Library/ExtensionKit/Extensions/HostInferenceProviderService.appex/HostInferenceProviderService
```

**Wiring**

* `scripts/patchers/cfw_patch_hv_vmm.py` — standalone cstring patcher
  (used for the on-device files): finds the `"kern.hv_vmm_present\0"`
  cstring in the Mach-O's __cstring section and rewrites its first
  byte (`'k'` → `'X'`).
* `scripts/patchers/cfw_dsc_chunks.py` — chunked-DSC byte-level helper
  (`DSCChunks(chunks_dir)`): vmaddr↔chunk-fileoff mapping, cstring
  scan over executable mappings, byte read/write at a vmaddr, and
  Mach-O header walk-back to resolve a vmaddr to the dylib install
  name (LC_ID_DYLIB).
* `scripts/patchers/cfw_patch_hv_vmm_dsc.py` — DSC-native orchestrator.
  No external `ipsw` dependency. For every `"kern.hv_vmm_present\0"`
  occurrence in any executable mapping, walks back to the containing
  dylib's Mach-O header, reads `LC_ID_DYLIB`, and — if the install
  name is in the explicit `PATCH_INSTALL_NAMES` whitelist — rewrites
  the first byte of the cstring through `DSCChunks.write_at_vma`.
  Pure Python. Whitelist-based by design so an operator can comment
  out individual entries to bisect.
* `scripts/patchers/cfw.py patch-hv-vmm <binary>` —
  standalone-Mach-O subcommand (used for the 6 on-device files).
* `scripts/patchers/cfw.py patch-hv-vmm-dsc <chunks_dir>` —
  DSC subcommand (used while the SystemOS Cryptex DMG is still
  mounted on the host, before the device copy).
* `scripts/patch_hv_vmm_userland.sh` — thin wrapper used by the
  install scripts.
* `scripts/cfw_install_exp.sh` — EXP install script. Pre-step before
  invoking `cfw_install.sh`: decrypts the SysOS Cryptex into the cache
  location `cfw_install.sh` already uses, mounts it, applies the
  DSC patch, unmounts. The unmodified `cfw_install.sh` then sees the
  cached (already-patched) DMG. Standalone watchdogd is patched later
  via SSH at step `[EXP-JB-3.5]`.
* `scripts/cfw_install_jb.sh` and `scripts/cfw_install_dev.sh` —
  unchanged from pre-experimental baseline. Neither runs the DSC
  patcher.

### `kern.hv_vmm_present` kernel patcher — Part A + Part B (EXP only)

The `KernelEXPPatchHvVmmRename` Swift patcher (in `KernelEXPPatcher.findAll()`,
chained after `KernelPatcher` and `KernelJBPatcher` for the `.exp` variant only)
renames the sysctl OID and rewrites every kernel-internal occurrence of the
old name so kexts continue to find it under the new name. Two parts. JB and
other variants do NOT run this patcher.

**Part A — OID name rename.** Finds the OID's `oid_name` cstring as
the NUL-delimited bytes `\0hv_vmm_present\0` (exactly one match
required in the kernelcache; on iPhone17,3 / iOS 26.1 this lives at
file offset `0x964e0` inside `com.apple.kernel`). Flips byte 0 of the
cstring `'h'` (0x68) → `'X'` (0x58). After the patch, the kernel's
`sysctl_register_oid` keeps the OID's MIB and value (1) intact but
the name resolver returns `ENOENT` for `kern.hv_vmm_present` and
returns 1 for `kern.Xv_vmm_present`.

**Part B — kernel-internal caller mangle.** After Part A, any
kernel-side `sysctlbyname("kern.hv_vmm_present", …)` call gets
ENOENT and falls into the caller's "not in a VM" branch — which on
the bring-up build caused AMFI to panic with `AMFI: No PMGR?
(ConfigurationSettings.cpp:388)` during ramdisk boot. Part B mangles
every kernel-internal occurrence of the `kern.hv_vmm_present` name
so callers continue to find the renamed OID. The mangle flips byte
5 of the inner cstring (`'h'` after `kern.`) → `'X'`, producing
`kern.Xv_vmm_present`.

Two byte-aligned forms are searched, both anchored at the
`kern.hv_vmm_present` substring:

| Form | Needle | Where it lives | Mangle delta within needle |
|------|--------|----------------|----------------------------|
| (i) NUL-delimited cstring | `\0kern.hv_vmm_present\0` | `__TEXT,__cstring` of any kext that calls sysctlbyname by full name | +6 (skip leading NUL + 5) |
| (ii) Sandbox-profile name token | `kern.hv_vmm_present\x0f` | Inside a compiled sandbox-profile blob within `com.apple.security.sandbox`. The `\x0f` byte is the sandbox-profile end-of-name marker; the token has no leading NUL. | +5 |

On iPhone17,3 / iOS 26.1 / 23B85 the universe is 5 occurrences
(verified by raw substring scan over the kernelcache buffer):

| File offset | Fileset entry | Form |
|-------------|---------------|------|
| `0x541d56` | `com.apple.driver.AppleMobileFileIntegrity` | (i) cstring |
| `0x81bdc3` | `com.apple.iokit.IOCryptoAcceleratorFamily` | (i) cstring |
| `0xa6618b` | `com.apple.security.sandbox` | (ii) sandbox-profile name token |
| `0xbb0d55` | `com.apple.security.sandbox` | (i) cstring |
| `0xbce1f9` | `com.apple.filesystems.apfs` | (i) cstring |

Part B emits one patch record per match (5 total, plus Part A's 1)
under patch IDs `kernelcache_exp.hv_vmm_internal_caller_mangle` and
`kernelcache_exp.hv_vmm_oid_rename`. Idempotent: a re-run detects
already-mangled bytes (`kern.Xv_vmm_present` instead of
`kern.hv_vmm_present`) and reports the patch as already applied.

**Note on the sandbox-profile occurrence.** This was missed by the
original Part B because its needle required NUL on both sides. The
sandbox-profile blob stores OID names as TLV-framed tokens where the
trailing byte is `\x0f` (sandbox EOT) rather than a NUL. Without the
second needle, sandboxed callers that interpret the profile's
`kern.hv_vmm_present`-matching rule would still match against the
OLD name, while the OID itself has been renamed — so the rule's
ALLOW/DENY/audit action would never fire. With the second needle,
the rule's name token is rewritten to `kern.Xv_vmm_present` and
sandboxed callers that hit the renamed OID match the (rewritten)
rule as intended. Covered occurrence verified on
iPhone17,3 / iOS 26.1 / 23B85 at file offset `0xa6618b`.

### `watchdogd` surgical hv_vmm_present cache patch (EXP only)

**Why a dedicated patch.** After the EXP kernel-side OID rename
(`KernelEXPPatchHvVmmRename`), `sysctlbyname("kern.hv_vmm_present", ...)`
returns `ENOENT` on this image. `/usr/libexec/watchdogd` caches that
answer at startup. On `ENOENT` the cached byte stays at its BSS-zero
default (`0`) and the downstream `cbz w0, ...` at the IOWatchdog-lookup
site (`+0x58e0`) takes a branch into a `_os_crash` wrapper that does
`brk #1`. launchd's `_PanicOnCrash → PanicOnConsecutiveCrash = true`
flag in `com.apple.watchdogd.plist` escalates the SIGTRAP to a kernel
panic. The cstring-mangle approach used elsewhere doesn't apply here
because we want this binary to behave as if the sysctl returned `1`,
not as if it returned `ENOENT`.

**Patch shape.** Two-instruction surgical edit at every site in
watchdogd that has the canonical caching shape:

```
adrp x0, <page>
add  x0, x0, #<off>          ; "kern.hv_vmm_present"
...arg setup...
bl   _sysctlbyname
cbnz w0, <skip>              ; <-- patched: NOP
ldur w8, [x29, #-4]
cmp  w8, #0
cset wN, ne                  ; <-- patched: mov wN, #1
adrp xM, <page>
strb wN, [xM, #<imm>]        ; cached "am I a VM?" byte
```

Net effect: the cached byte is forced to `1` regardless of the sysctl
result, and watchdogd's pre-existing "detected virtual machine
environment, exiting..." clean-exit branch runs instead of the trap
path. Two functions in watchdogd match this shape on
`iPhone17,3 / iOS 26.1`; both are patched.

**Code signing.** The byte edit invalidates the SHA-256 slot hashes
for the 4 KiB pages containing the modifications in watchdogd's own
`CS_CodeDirectory`. The patcher recomputes those slot hashes in place
via `cfw_macho_codesign.reattest_modified_offsets` (4 KiB page size
read from the CD, correct tail-slot length, all present CDs). The
resulting CD mutation also changes the cdHash, but the existing JB
kernel patch `patch_amfi_cdhash_in_trustcache` accepts any cdHash, so
AMFI's trust-cache check still passes at execve. The patcher does NOT
re-sign with `ldid` — preserving the original Apple-issued code-signing
identifier (`com.apple.watchdogd`) is required for launchd's boot-task
identity validation; an earlier attempt to re-sign other rootfs
binaries with `ldid_sign` tripped this check on `mobile_obliterator`.

**Wiring.**

* `scripts/patchers/cfw_macho_codesign.py` — standalone-Mach-O
  page-hash re-attestation (parallel to `cfw_dsc_codesign.py` but
  parses `LC_CODE_SIGNATURE` directly, uses page size from the CD
  header, handles short tail slot, updates every present CD).
* `scripts/patchers/cfw_patch_watchdogd.py` — capstone-anchored
  pattern matcher + Keystone-assembled 2-insn patch + slot reattest.
  Idempotent.
* `scripts/patchers/cfw.py patch-watchdogd <binary>` — CLI subcommand.
* `scripts/patch_hv_vmm_userland.sh watchdogd <binary>` — thin shim
  used by the install script.
* `scripts/cfw_install_exp.sh` — invokes the patcher at step `[EXP-JB-3.5]`
  on the live `/mnt1/usr/libexec/watchdogd` (scp-down, patch, scp-up,
  chmod 0755). JB and DEV install scripts do NOT run this step.

### DeviceTree `/product/camera` node addition at fw_patch time (EXP only)

`DeviceTreePatcher` carries an `experimentalNodeAdditions` list with one
entry — a `/device-tree/product/camera` child node. Applied only when
`includeIdentityPatches` is true (i.e. variant `.exp`); other variants
leave the product subtree unchanged.

| Property                            | Type          | Value | Purpose                                                 |
|-------------------------------------|---------------|-------|---------------------------------------------------------|
| `name`                              | cstring       | `camera` | DT node name (auto-added from `nodeName`).           |
| `aggregate-camera`                  | uint32        | `1`   | Backs MG `aggregateCameraCapability` getter.            |
| `auto-focus`                        | uint32        | `1`   | Backs MG `autoFocusCameraCapability` getter.            |
| `flash`                             | uint32        | `1`   | Backs MG `cameraFlashCapability` getter.                |
| `pearl-camera`                      | uint32        | `1`   | Backs MG `pearlCameraCapability` getter.                |
| `panorama`                          | uint32        | `1`   | Backs MG `panoramaCameraCapability` getter.             |
| `pipelined-stillimage-capability`   | uint32        | `1`   | Backs MG `pipelinedStillImageCaptureCapability`.        |
| `rear-burst`, `front-burst`         | uint32        | `1`   | Backs MG burst-capability getters.                      |
| `video-cap`                         | uint32        | `2`   | Video capture level (real D47AP value).                 |
| `camera-hdr-version`                | uint32        | `3`   | HDR version (real D47AP value).                         |
| `camera-ui-version`                 | uint32        | `2`   | UI version selector (real D47AP value).                 |

Why this is necessary: `libMobileGestalt.dylib` resolves
`MGGetBoolAnswer("still-camera")` (cstring at vmaddr `0x1b1c5fedd`) via a
chain that reads `IODeviceTree:/product/camera` (cstring at vmaddr
`0x1b1c5832a`, **65 ADRP+ADD xrefs in the same dylib's `__text`**). The
canonical iPhone17,3 D47AP DT carries this node with 64 capability
properties; the vphone600AP DT ships **zero** `camera`, `audio`,
`facetime`, or `back-camera` references under `/product`. Without
the node, SpringBoard's `SBAppTags = ["still-camera"]` filter hides
Camera.app's icon and refuses to launch the bundle.

The node alone is not enough: the SBAppTags resolver also chains
through `/product` direct properties (`assistant`, `dictation`,
`compatible-device-fallback`, `chrome-identifier`, …), most of which
ship as 12-byte `'syscfg/XXXX'` cstring placeholders on vphone600 and
read back as NO. Tier 1d (below) rewrites those.

Idempotent: re-running against an already-patched DT detects the
existing child and skips.

### Camera DSC patch (EXP only)

`apply_all_camera_patches` in `scripts/patchers/cfw_patch_camera_dsc.py`
runs two patch families. Symbols are resolved per-build via
`ipsw dyld symaddr` against the cryptex's `dyld_shared_cache_arm64e`
header.

| # | Target | Framework | Effect |
|---|---|---|---|
| 1 | `+[_NUStyleTransfer{,Apply,Thumbnail,Learn,Interpolate}Processor processWithInputs:arguments:output:error:]` (5 entry points) | NeutrinoCore | Each replaced with `mov w0, #0; ret`. Camera's CIImageProcessorKernel chain that drives the style preview thumbnails short-circuits before reaching `+[_NUStyleEngine usingSharedStyleEngineForUsage:...]` → `_NUStyleEngineMemoryResource initWithDevice:descriptor:` which would otherwise assert on a nil descriptor (root cause is an upstream ANE-detection gate in `CMIStyleEngineCommonSettings`; we workaround at the consumer instead of unblocking it). |
| 2 | `+[AVCaptureDevice authorizationStatusForMediaType:]` | AVFCapture | Replaced with `mov w0, #3; ret` (AVAuthorizationStatusAuthorized = 3). Any process probing camera/audio/etc. media-type authorization gets "Authorized" without going through TCC. Stage 0 of the vcam stack — makes apps stop bailing on the auth check. Audio still doesn't work on the VM, so the broader scope is harmless (audio consumers would have failed downstream regardless). Downstream pipeline (cameracaptured rewrite, vcamd daemon) still owed for actual frame delivery. |

Wired into `cfw_install_exp.sh` immediately after the hv_vmm DSC step,
inside the same `hdiutil attach` block (one mount/unmount per install).
Page-hash re-attestation keeps the cryptex's CodeDirectory slots
consistent with the modified pages so `amfid` / TXM accepts the DSC at
next boot.

### Virtual-camera QR metadata output (EXP userspace)

The synthetic `cameracaptured` device supplies preview frames but has no
hardware metadata analyzer. Consequently `AVCaptureMetadataOutput` reports an
empty `availableMetadataObjectTypes` list and throws when scanner clients set
`AVMetadataObjectTypeQRCode`, even after the vcam input itself is accepted.

`scripts/camfix/libcamfix.m`, restricted by its TweakLoader plist to the
`Camera` and `KFCKnight` executables, completes this client-side vcam contract
for outputs bound to `vphone:vcam:0`:

- advertise and retain the requested QR metadata type without changing real
  camera outputs;
- decode the same shared-memory BGRA frames used by the preview pump with
  CoreImage's QR detector;
- deliver a machine-readable object through the standard
  `captureOutput:didOutputMetadataObjects:fromConnection:` delegate and its
  configured queue;
- treat each delegate/type configuration as one consumption window and deliver
  at most one QR callback, so a static frame repeated at camera FPS cannot
  submit the same duty transition multiple times.

This is a camera-pipeline compatibility shim, not an application hook: it does
not reference scanner view controllers, private business selectors, or QR
payload formats. The negative baseline was a KFCKnight crash at
`-[AVCaptureMetadataOutput setMetadataObjectTypes:]`; the acceptance probe is
an observation-only delegate hook matching a unique rendered nonce.

### Virtual-camera generation receipt (userspace control plane)

The camera wire carries a generation and frame index for each publication.
`vphoned` publishes them with the pixels in a packed v2 shared-memory header;
the declared header region is 256 bytes and pixels begin at offset 256.
`libvcamcaptured` stages pixels privately, rechecks the publish sequence, and
only then exposes the stable frame and writes a separate packed observe
receipt. The 1337 `vcam_status` handler reports six fields: publish/observe
frame indices, publish/observe monotonic timestamps, observed count, and the
published generation. Host `camera_present` accepts a transport receipt only
when both frame indices are nonzero and the returned generation matches the
request.

`libcamfix` reads the same `vphone-vcam-frame.shm` to synthesize capture
samples and decode QR for scanner apps, so it is a third consumer of this
header. Its packed mirror preserves the authoritative vphoned field offsets,
contains no role or in-header protocol-version fields, pads the structure to
the full 256-byte header region, and carries a `_Static_assert` so pixel-offset
drift fails at compile time.

Live validation on vm-2607 (2026-07-14) observed matching publish/observe frame
indices and `observed_at_ns >= published_at_ns`; an old-generation status query
returned no receipt, a wrong-owner stop was rejected, and a receipt-backed
neutral generation was stopped back to `source=off`.

Follow-up validation on `vm-2607-rig2` (2026-09-16) extended the same host
command to an explicit `source=video` path while preserving the v3 receipt
contract. A 2-second red/blue file obtained a matching copy receipt, guest
shared-memory samples changed color, and Camera.app with the current-source
`libcamfix` displayed red/blue changes for 4.84 seconds. A subsequent neutral
presentation used a new generation and presentation ID, obtained its own
receipt, and displayed white. The installed older consumer and older
`libcamfix` were retained as negative controls: the first could not issue a
v3 copy receipt, and the second displayed only the first video frame. Current
CFW installation builds both dylibs from the repository sources. Full evidence
and restore hashes are recorded in
`research/camera_e6_video_acceptance_2026-09-16.md`.

### Detector luma bbox-fill geometry (userspace camera daemon)

`scripts/vcamcaptured/libvcamcaptured.m` keeps the live-qualified QR geometry
in rebuildable source rather than only in a deployed dylib. In the exact
`BWMetadataDetectorGatingNode` render seam (upstream of `BWMRCNode`), the hook
reads the latest protocol-v2 BGRA frame and locates its dark-pixel bounding
box, expands it by a four-module-equivalent quiet zone (one eighth of the dark
side per edge), and nearest-neighbor maps that square onto the destination's
short edge. A 720x1280 detector input therefore carries a centered 720x720
crop whose dark QR bbox occupies approximately 80% (the live-observed 575px
target), while the rest of luma is white and chroma is neutral.

The same path handles the QR-free neutral generation: absence of dark pixels
still overwrites the full destination with white/neutral planes, so an older
QR cannot survive in detector luma during cleanup. Screenshot/OCR geometry is
not inferred from the preview path; the transformation is local to each
actual planar sample buffer. The arm64e iPhoneOS dylib rebuild succeeds with
only the pre-existing deprecated Objective-C pointer-introspection warning.
The source was recovered by a zero-conflict three-way merge of the original
metadata/detector implementation (`a4cef80`) with the current receipt work,
then rebuilt and ad-hoc signed by `scripts/vcamcaptured/Makefile`. The deployed
vm-2607 dylib hash is `163ea693...`; a post-restart scanner+neutral smoke kept
cameracaptured PID 75 stable, returned a matching publish/observe receipt, and
finished at `streaming=false/source=off`. The native detector branch remains
dormant in this scanner session, consistent with the established 0/0 result;
formal QR consumption uses the standard metadata delegate compatibility path.

### DeviceTree identity properties at fw_patch time (EXP only)

`DeviceTreePatcher` carries two property-patch lists: `basePropertyPatches`
(4 entries — `serial-number`, `home-button-type`, `artwork-device-subtype`,
`island-notch-location`) applied for every variant, and
`identityPropertyPatches` (8 entries) applied **only when `includeIdentityPatches`
is true**, which `FirmwarePipeline` sets exactly when `variant == .exp`.

The 8 EXP-only identity properties (no restore-fatal ones — those go through
EXP-JB-6 post-restore):

| # | Node path                                          | Property              | Old → New                     | Risk    |
|---|----------------------------------------------------|-----------------------|-------------------------------|---------|
| 1 | `device-tree`                                      | `target-sub-type`     | `VPHONE600AP` → `D47AP`       | HIGHER  |
| 2 | `device-tree`                                      | `compatible[1]`       | `iPhone99,11` → `iPhone17,3` (slot-preserving) | LOW |
| 3 | `device-tree/product`                              | `fdr-product-type`    | `iPhone99,11` → `iPhone17,3`  | HIGHER  |
| 4 | `device-tree/product`                              | `sub-product-type`    | `iPhone99,11` → `iPhone17,3`  | LOW     |
| 5 | `device-tree/product`                              | `unique-model`        | `VPHONE600AP` → `D47AP`       | LOW     |
| 6 | `device-tree/arm-io`                               | `device_type`         | `vresearch1-io` → `t8140-io`  | MEDIUM  |
| 7 | `device-tree/arm-io`                               | `soc-generation`      | `VResearch1` → `H17`          | MEDIUM-LOW |
| 8 | `device-tree/product/vphone600-gestalt-variants`   | `name` (node rename)  | `vphone600-gestalt-variants` → `d47-gestalt-variants` | LOW-MEDIUM |

Root `model` and root `target-type` are deliberately NOT in this list —
both have been empirically shown to break restore. Those edits run
post-restore as EXP-JB-6.

Bulk `/product` direct-property completion (rewriting the ~30
`'syscfg/XXXX'` placeholders to D47AP integer/string values) was
attempted to make `MGGetBoolAnswer("still-camera")` answer YES via the
DT path alone. It broke screen rendering on the VM (the display
pipeline / framebuffer pulls one or more `/product` capability props
during init and chooses a render path the VM can't service). Reverted.
A narrower set targeted at the Camera-icon resolver chain (Tier B + C
+ F, below) does work without breaking display.

### DeviceTree Camera-icon completion (Tier B + C + F, EXP only)

Two `PropertyPatch` entries in `identityPropertyPatches`, three
`AddChildNodePatch` entries appended to `experimentalNodeAdditions`
for `/product/*` children, and five more for `/arm-io/*` stubs.
Empirically: this is the set that makes Camera.app's icon visible on
the home screen and in Spotlight without breaking screen rendering.

**Tier B — `/product` cam-offset rewrites.** vphone600 ships these
as 12-byte `'syscfg/{fcof,rcof}'` cstring placeholders. d47ap carries
20-byte little-endian geometry blobs. Consumed by Camera.app / ARKit
/ FaceTime for image-centering math.

| Property | Old length | New length | New value (hex) |
|----------|:----------:|:----------:|------------------|
| `/product::front-cam-offset-from-center` | 12 | 20 | `61000100921c0000d8130000e803000000000000` |
| `/product::rear-cam-offset-from-center`  | 12 | 20 | `eda50000b256000059080000e803000000000000` |

**Tier C — new `/product/*` child nodes.** d47ap carries three
sibling nodes to `/product/camera`. vphone600 has none of them.

| Node | Props | Camera relevance |
|------|:-----:|------------------|
| `/product/facetime` | 9 (excl. AAPL,phandle) | Front-camera video-call config — bitrates, codec encoding/decoding, tnr-mode-back/front. |
| `/product/audio` | 31 (excl. AAPL,phandle) | Carries `supports-spatial-audio-capture=1` + `supports-spatial-facetime=1` (camera-joint). Rest is audio config. |
| `/product/iopm` | 2 (excl. AAPL,phandle) | `aot-mode=13` + `aot-linger-time-ms=0`. Always-On Technology mode. |

All property values copied byte-for-byte from
`ipsws/iPhone17,3_26.5_23F77_Restore_extracted/Firmware/all_flash/DeviceTree.d47ap.im4p`.

**Tier F — `/arm-io/*` minimal camera-flag stubs.** d47ap carries
`/arm-io/isp` (65 props), `/arm-io/ispRtb` (53 props), and a deep
`/arm-io/smc/iop-smc-nub/smc-ext-charger` chain (3 levels of node).
vphone600 has none of these paths. We add minimal stub nodes carrying
ONLY the camera-* properties and the mandatory auto-`name`,
deliberately omitting `compatible`/`device_type`/`reg`/`interrupts`,
so no IOKit kext finds a matching `compatible=` and tries to probe
non-existent ISP / SMC hardware.

| Path | Property | Value |
|------|----------|-------|
| `/arm-io/smc` | (stub — parent for chain) | — |
| `/arm-io/smc/iop-smc-nub` | (stub — parent for charger) | — |
| `/arm-io/smc/iop-smc-nub/smc-ext-charger` | `camera-driver` | str `'AppleH16CamIn'` |
| `/arm-io/isp` | `camera-front`, `camera-rear` | int32:1, int32:1 |
| `/arm-io/ispRtb` | `camera-front`, `camera-rear` | int32:1, int32:1 |

Dependency order: the patcher walks `experimentalNodeAdditions` in
array order against the in-memory tree, so each entry that resolves
to a parent added by an earlier entry resolves correctly.

Idempotent: re-running the patcher against an already-modified DT
detects the existing child by name and skips. The DT IM4P that ships
on subsequent boots is signed by Apple but the existing iBSS/iBEC/LLB
`image4_validate_property_callback` bypass accepts arbitrary payloads.

### Post-restore DT identity rewrite (EXP-JB-6, EXP only)

After the restore daemon's BuildManifest identity check has passed,
`cfw_install_exp.sh` step `[EXP-JB-6]` scp's `devicetree.img4` down from the
mounted rootfs (`/mnt5/<boot-hash>/usr/standalone/firmware/`), runs
`scripts/patchers/cfw_patch_post_restore_dt.py`, and scp's the rewritten
img4 back. The Python patcher unwraps the IM4P via `pyimg4`, parses the
DT flat-binary, rewrites three restore-fatal root properties, and repacks
preserving the IMG4's original IM4M ticket. The iBSS/iBEC/LLB
`image4_validate_property_callback` bypass (existing JB patch) accepts
the modified payload at next boot.

| # | Property         | Old → New                                                              |
|---|------------------|------------------------------------------------------------------------|
| 1 | root `model`       | `iPhone99,11` → `iPhone17,3`                                          |
| 2 | root `target-type` | `VPHONE600` → `D47`                                                   |
| 3 | root `compatible`  | reorder `["VPHONE600AP", "iPhone99,11", "AVP-ARM"]` → `["D47AP", "VPHONE600AP", "AVP-ARM"]` (keeps `VPHONE600AP` in second slot so IOKit's `AppleVMApple1IO` kext binding still resolves; userland reads only the first entry for `hw.model`) |

Idempotent. Skipped if already-rewritten DT is detected.

### SystemVersion.plist `ProductBuildVersion` rewrite (EXP-JB-7, EXP only, opt-in)

Gated on the `SPOOF_BUILD` env var. When `cfw_install_exp.sh` is invoked
with e.g. `SPOOF_BUILD=23F77`, step `[EXP-JB-7]` runs
`scripts/patchers/cfw_patch_build_version.py` (plistlib-based,
format-preserving) on both the rootfs and cryptex copies of
`SystemVersion.plist` to rewrite the `ProductBuildVersion` key to the
specified id. Without `SPOOF_BUILD`, the step is skipped and the build
version stays at the original IPSW value.

| File                                                                              | Touched if `SPOOF_BUILD=<id>` |
|-----------------------------------------------------------------------------------|:------------------------------:|
| `/mnt1/System/Library/CoreServices/SystemVersion.plist` (rootfs)                  | Y                              |
| `/mnt5/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist` (cryptex)    | Y                              |

`kern.osversion` is unaffected — that comes from a kernel global
initialized from boot args, not from this plist. Userland MG cache
picks up the new build identifier on first boot after the gestalt
cache rebuild.

### CFW Installer Flow Matrix (Script-Level)

| Flow Item                                     | Regular (`cfw_install.sh`)      | Dev (`cfw_install_dev.sh`) | JB (`cfw_install_jb.sh`)                      | EXP (`cfw_install_exp.sh`)                            |
| --------------------------------------------- | ------------------------------- | -------------------------- | --------------------------------------------- | ----------------------------------------------------- |
| Base CFW phases (1/7 -> 7/7)                  | Runs directly                   | Runs directly              | Runs via `CFW_SKIP_HALT=1 zsh cfw_install.sh` | Runs via `CFW_SKIP_HALT=1 zsh cfw_install.sh`         |
| Dev overlay (`rpcserver_ios` replacement)     | -                               | Y (`apply_dev_overlay`)    | -                                             | -                                                     |
| SSH readiness wait before install             | Y (`wait_for_device_ssh_ready`) | -                          | Y (inherited from base run)                   | Y (inherited from base run)                           |
| launchd jetsam patch (`patch-launchd-jetsam`) | -                               | Y (base-flow injection)    | Y (JB-1)                                      | Y (JB-1)                                              |
| launchd dylib injection (`inject-dylib /b`)   | -                               | -                          | Y (JB-1, opt-out via `DISABLE_LAUNCHD_HOOK=1`) | Y (JB-1, opt-out via `DISABLE_LAUNCHD_HOOK=1`)        |
| Procursus bootstrap deployment                | -                               | -                          | Y (JB-2)                                      | Y (JB-2)                                              |
| BaseBin hook deployment (`*.dylib` -> `/mnt1/cores`) | -                        | -                          | Y (JB-3)                                      | Y (JB-3)                                              |
| First-boot JB finalization (`vphone_jb_setup.sh`) | -                           | -                          | Y (post-boot)                                 | Y (post-boot)                                         |
| IOMobileFramebuffer SwapEnd payload-size patch (install-gated `26.0*`/`18.*` -> 0x560 / 26.1 base; **27.0 does NOT use this — it uses force-kern, next section**) | Y              | Y                          | Y (inherited from base run)                   | Y (inherited from base run)                           |
| dyld cache `maxSlide` zero (`patch-dsc-maxslide`; **install-gated `27.*`** as of 2026-07-20 — iOS 27's cache overflows the 6 GiB region; 18.x/26.x skip it; the `FORCE_DSC_MAXSLIDE=1` → `--force` opt-in was removed 2026-10-01, T13a) | Y | Y                     | Y (inherited from base run)                   | Y (inherited from base run)                           |
| DSC pre-patch (`kern.hv_vmm_present` byte-5 mangle + slot reattest) | -         | -                          | -                                             | Y (pre-step, before base CFW)                         |
| DSC camera patches (12 patches across CMCapture / CoreMediaIO / AVFCapture / libMobileGestalt) | - | -                  | -                                             | Y (pre-step, same cryptex mount as hv_vmm)            |
| `watchdogd` surgical 2-insn patch + slot reattest | -                           | -                          | -                                             | Y (EXP-JB-3.5)                                        |
| Post-restore DT identity rewrite (`devicetree.img4`)| -                         | -                          | -                                             | Y (EXP-JB-6)                                          |
| `SystemVersion.plist` `ProductBuildVersion` rewrite | -                         | -                          | -                                             | Y (EXP-JB-7, opt-in via `SPOOF_BUILD`)                |
| Additional input resources                    | `cfw_input`                     | `cfw_input` + `resources/cfw_dev/rpcserver_ios` | `cfw_input` + `cfw_jb_input` | `cfw_input` + `cfw_jb_input`        |
| Extra tool requirement beyond base            | -                               | -                          | `zstd`                                        | `zstd`                                                |
| Halt behavior                                 | Halts unless `CFW_SKIP_HALT=1`  | Halts unless `CFW_SKIP_HALT=1` | Always halts after JB phases              | Always halts after EXP phases                         |

## Summary

C3 structured-result migration (2026-09-10): the current Swift `KernelJBPatcher.findAll()` declares 33 orchestration methods. The historical “Kernel (JB methods) = 59” below is not the structured step count. This migration changes result reporting and ablation, with no new binary patch targets; see [C3 JB migration](patch_results_c3_kernel_jb_2026-09-10.md).

| Component                          | Regular | Dev |  JB | EXP |
| ---------------------------------- | ------: | --: | --: | --: |
| AVPBooter                          |       1 |   1 |   1 |   1 |
| iBSS                               |       2 |   2 |   3 |   3 |
| iBEC                               |       4 |   4 |   4 |   4 |
| LLB                                |       6 |   6 |   6 |   6 |
| TXM                                |       1 |  12 |  12 |  12 |
| Kernel (base)                      |      28 |  29 |  28 |  28 |
| Kernel (JB methods)                |       - |   - |  59 |  59 |
| Kernel (EXP methods, `hv_vmm`)     |       - |   - |   - |   6 |
| DeviceTree base properties         |       4 |   4 |   4 |   4 |
| DeviceTree EXP identity properties |       - |   - |   - |   8 |
| DeviceTree EXP node additions      |       - |   - |   - |   1 (`/product/camera`) |
| Boot chain total                   |      46 |  58 | 117 | 132 |
| CFW binary patches (base)          |       4 |   5 |   6 |   6 |
| CFW EXP-only steps                 |       - |   - |   - |   5 (hv_vmm DSC, camera DSC ×12, watchdogd EXP-JB-3.5, post-restore DT EXP-JB-6, build-version EXP-JB-7 opt-in) |
| CFW installed components           |       6 |   7 |   9 |   9 |
| CFW total                          |      10 |  12 |  15 |  31 |
| Grand total                        |      56 |  70 | 132 | 163 |

## Ramdisk Variant Matrix

| Variant        | Pre-step             | `Ramdisk/txm.img4`               | `Ramdisk/krnl.ramdisk.img4`                                                      | `Ramdisk/krnl.img4`                            | Effective kernel used by `ramdisk_send.sh`          |
| -------------- | -------------------- | -------------------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------- | --------------------------------------------------- |
| `RAMDISK`      | `make fw_patch`      | release TXM + base TXM patch (1) | base kernel (28), legacy `*.ramdisk` preferred else derive from pristine CloudOS | restore kernel from `fw_patch` (28)            | `krnl.ramdisk.img4` preferred, fallback `krnl.img4` |
| `DEV+RAMDISK`  | `make fw_patch_dev`  | release TXM + base TXM patch (1) | base kernel (28), same derivation rule                                           | restore kernel from `fw_patch_dev` (29)        | `krnl.ramdisk.img4` preferred, fallback `krnl.img4` |
| `JB+RAMDISK`   | `make fw_patch_jb`   | release TXM + base TXM patch (1) | base kernel (28), same derivation rule                                           | restore kernel from `fw_patch_jb` (28+59)      | `krnl.ramdisk.img4` preferred, fallback `krnl.img4` |
| `EXP+RAMDISK`  | `make fw_patch_exp`  | release TXM + base TXM patch (1) | base kernel (28), same derivation rule                                           | restore kernel from `fw_patch_exp` (28+59+6)   | `krnl.ramdisk.img4` preferred, fallback `krnl.img4` |

## Cross-Version Dynamic Snapshot

| Case                | TXM_JB_PATCHES | KERNEL_JB_PATCHES |
| ------------------- | -------------: | ----------------: |
| PCC 26.1 (`23B85`)  |             14 |                59 |
| PCC 26.3 (`23D128`) |             14 |                59 |
| iOS 26.1 (`23B85`)  |             14 |                59 |
| iOS 26.3 (`23D127`) |             14 |                59 |

## Swift Migration Notes (2026-03-10)

- Swift `FirmwarePatcher` now matches the Python reference patch output across all checked components:
  - `avpbooter` 1/1
  - `ibss` 4/4
  - `ibec` 7/7
  - `llb` 13/13
  - `txm` 1/1
  - `txm_dev` 12/12
  - `kernelcache` 28/28
  - `ibss_jb` 1/1
  - `kernelcache_jb` 84/84
- JB parity fixes completed in Swift:
  - C23 `vnode_getattr` resolution now follows the Python backward BL scan and resolves `0x00CD44F8`.
  - C22 syscallmask cave encodings were corrected and centralized in `ARM64Constants.swift`.
  - Task-conversion matcher masks and kernel-text scan range were corrected, restoring the patch at `0x00B0C400`.
  - `jbDecodeBranchTarget()` now correctly decodes `cbz/cbnz`, restoring the real `_bsd_init` rootauth gate at `0x00F7798C`.
  - IOUC MACF matching now uses Python-equivalent disassembly semantics for the aggregator shape, restoring the deny-to-allow patch at `0x01260644`.
- C24 `kcall10` cave instruction bytes were re-verified against macOS `clang`/`as`; no Swift byte changes were needed.
- The Swift pipeline is now directly invokable from the product binary:
  - `vphone-cli patch-firmware --vm-directory <dir> --variant {regular|dev|jb}`
  - `vphone-cli patch-component --component {txm|kernel-base} --input <file> --output <raw>` is available for non-firmware tooling that still needs a single patched payload during ramdisk packaging
  - default loader now preserves IM4P containers via `IM4PHandler`
  - DeviceTree patching now uses the real Swift `DeviceTreePatcher` in the pipeline
  - project `make fw_patch`, `make fw_patch_dev`, and `make fw_patch_jb` targets now invoke this Swift pipeline via the unsigned debug `vphone-cli` build, while the signed release build remains reserved for VM boot/DFU paths
  - on 2026-03-11, the legacy Python firmware patcher entrypoints and patch modules were temporarily restored from pre-removal history for parity/debug work.
  - after byte-for-byte parity was revalidated against Python on `26.1` and `26.3` for `regular`, `dev`, and `jb`, those legacy firmware-patcher Python sources and transient comparison/export helpers were removed again so the repo keeps Swift as the single firmware-patching implementation.
- Swift pipeline follow-up fixes completed after CLI bring-up:
  - `findFile()` now supports glob patterns such as `AVPBooter*.bin` instead of treating them as literal paths.
  - JB variant sequencing now runs base iBSS/kernel patchers first, then the JB extension patchers.
  - Sequential pipeline application now feeds each patcher's patched output buffer into the next patcher for the same component, so later extension patchers see partially-patched VM trees correctly while still emitting normal `PatchRecord` output.
  - `apply()` now reuses an already-populated `patches` array instead of re-running `findAll()`, so `patch-firmware` / `patch-component` no longer double-scan or double-print the same component diagnostics on a single invocation.
  - unaligned integer reads across the firmware patcher now go through a shared safe `Data.loadLE(...)` helper, fixing the JB IM4P crash (`Swift/UnsafeRawPointer.swift:449` misaligned raw pointer load).
  - `TXMPatcher` now preserves pristine Python parity by preferring the legacy trustcache binary-search site when present, and only falls back to the selector24 hash-flags call chain (`ldr x1, [x20,#0x38]` -> `add x2, sp, #4` -> `bl` -> `ldp x0, x1, [x20,#0x30]` -> `add x2, sp, #8` -> `bl`) when rerunning on a VM tree that already carries the dev/JB selector24 early-return patch.
  - `scripts/fw_prepare.sh` now deletes stale sibling `*Restore*` directories in the working VM directory before patching continues, so a fresh `make fw_prepare && make fw_patch` cannot accidentally select an older prepared firmware tree (for example `26.1`) when a newer one (for example `26.3`) was just generated.
  - 2026-06-03: `IBootJBPatcher.patchSkipGenerateNonce()` now treats the already-applied `b <skip>` + `mov w0,#0` + `bl generate_nonce` shape as an idempotent no-op record, allowing `make fw_patch_jb` / `make fw_patch_exp` to recover from a VM tree where the nonce skip was written but later iBSS base patches were not saved.
  - 2026-06-03: `KernelEXPPatcher.patchHvVmmRename()` now emits no-op records for already-renamed Part A and already-mangled Part B bytes, so a fully patched EXP kernelcache does not trip the pipeline's "no patches found" guard on rerun.
  - 2026-06-03: `DeviceTreePatcher` now resolves the EXP gestalt-variants node by either the original `vphone600-gestalt-variants` name or the already-renamed `d47-gestalt-variants` name, keeping the node-rename patch re-runnable without weakening other DeviceTree path checks.
  - 26.0 and 26.0.1 GUI bring-up now patches installed DSC `IOMobileFramebuffer` only when `ProductVersion` starts with `26.0`: `_kern_SwapEnd` passes a 0x560-byte state to the 26.1 PCC userclient instead of the 26.0/26.0.1 0x548-byte state. JB host installs were validated on `17,3_26.0_23A341`, `17,3_26.0.1_23A355`, and unchanged `17,3_26.1_23B85`.
- IM4P/output parity fixes completed after synthetic full-pipeline comparison:
  - `IM4PHandler.save()` no longer forces a generic LZFSE re-encode.
  - Swift now rebuilds IM4Ps in the same effective shape as the Python patch flow and only preserves trailing `PAYP` metadata for `TXM` (`trxm`) and `kernelcache` (`krnl`).
  - `IBootPatcher` serial labels now match Python casing exactly (`Loaded iBSS`, `Loaded iBEC`, `Loaded LLB`).
  - `DeviceTreePatcher` now serializes the full patched flat tree, matching Python `dtree.py`, instead of relying on in-place property writes alone.
- Synthetic CLI dry-run status on 2026-03-10 using IM4P-backed inputs under `ipsws/patch_refactor_input`:
  - regular: 58 patch records
  - dev: 69 patch records
  - jb: 154 patch records
- Full synthetic Python-vs-Swift pipeline comparison status on 2026-03-10 using `scripts/compare_swift_python_pipeline.py`:
  - regular: all 7 component payloads match
  - dev: all 7 component payloads match
  - jb: all 7 component payloads match
- Real prepared-firmware Python-vs-Swift pipeline comparison status on 2026-03-10 using `vm/` after `make fw_prepare`:
  - historical note: the now-removed `scripts/compare_swift_python_pipeline.py` cloned only the prepared `*Restore*` tree plus `AVPBooter*.bin`, `AVPSEPBooter*.bin`, and `config.plist`, avoiding `No space left on device` failures from copying `Disk.img` after `make vm_new`.
  - regular: all 7 component payloads match
  - dev: all 7 component payloads match
  - jb: all 7 component payloads match
- Runtime validation blocker observed on 2026-03-10:
  - `NON_INTERACTIVE=1 SKIP_PROJECT_SETUP=1 make setup_machine JB=1` reaches the Swift patch stage and reports `[patch-firmware] applied 154 patches for jb`, then fails when the flow transitions into `make boot_dfu`.
  - `make boot_dfu` originally failed at launch-policy time with exit `137` / signal `9` because the release `vphone-cli` could not launch on this host.
  - `amfidont` was then validated on-host:
    - it can attach to `/usr/libexec/amfid`
    - the initial path allow rule failed because `AMFIPathValidator` reports URL-encoded paths (`/Volumes/My%20Shared%20Files/...`)
    - rerunning `amfidont` with the encoded project path and the release-binary CDHash allows the signed release `vphone-cli` to launch
    - this workflow is now packaged as `make amfidont_allow_vphone` / `scripts/start_amfidont_for_vphone.sh`
    - follow-up on 2026-06-03: `amfidont` 0.0.3 installs into the `xcrun python3` user script directory on this host and requires the `daemon` subcommand, so the helper now resolves that user-bin executable directly and invokes `amfidont daemon --path ... --cdhash ... --spoof-apple`
  - With launch policy bypassed, `make boot_dfu` advances into VM setup, emits `vm/udid-prediction.txt`, and then fails with `VZErrorDomain Code=2 "Virtualization is not available on this hardware."`
  - `VPhoneAppDelegate` startup failure handling was tightened so these fatal boot/DFU startup errors now exit non-zero; `make boot_dfu` now reports `make: *** [boot_dfu] Error 1` for the nested-virtualization failure instead of incorrectly returning success.
  - The host itself is a nested Apple VM (`Model Name: Apple Virtual Machine 1`, `kern.hv_vmm_present=1`), so the remaining blocker is lack of nested Virtualization.framework availability rather than firmware patching or AMFI bypass.
  - `boot_binary_check` now uses strict host preflight and fails earlier on this class of host with `make: *** [boot_binary_check] Error 3`, avoiding a wasted VM-start attempt once the nested-virtualization condition is already known.
  - Added `make boot_host_preflight` / `scripts/boot_host_preflight.sh` to capture this state in one command:
    - model: `Apple Virtual Machine 1`
    - `kern.hv_vmm_present`: `1`
    - SIP: disabled
    - `allow-research-guests`: disabled
    - current `kern.bootargs`: empty
    - next-boot `nvram boot-args`: `amfi_get_out_of_my_way=1 -v` (staged on 2026-03-10; requires reboot before it affects launch policy)
    - `spctl --status`: assessments enabled
    - `spctl --assess` rejects the signed release binary
    - unsigned debug `vphone-cli --help`: exit `0`
    - signed release `vphone-cli --help`: exit `137`
    - freshly signed debug control binary `--help`: exit `137`

## Automation Notes (2026-03-06)

- `scripts/setup_machine.sh` non-interactive flow fix: renamed local variable `status` to `boot_state` in first-boot log wait and boot-analysis wait helpers to avoid zsh `status` read-only special parameter collision.
- `scripts/setup_machine.sh` non-interactive first-boot wait fix: replaced `(( waited++ ))` with `(( ++waited ))` in `monitor_boot_log_until` to avoid `set -e` abort when arithmetic expression evaluates to `0`.
- `scripts/jb_patch_autotest.sh` loop fix for sweep stability under `set -e`: replaced `((idx++))` with `(( ++idx ))`.
- `scripts/jb_patch_autotest.sh` zsh compatibility fix: renamed per-case result variable `status` to `case_status` to avoid `status` read-only special parameter collision.
- `scripts/jb_patch_autotest.sh` selection logic update:
  - default run now excludes methods listed in `KernelJBPatcher._DEV_SINGLE_WORKING_METHODS` (pending-only sweep).
  - set `JB_AUTOTEST_INCLUDE_WORKING=1` to include already-working methods and run the full list.
- Sweep run record:
  - `setup_logs/jb_patch_tests_20260306_114417` (2026-03-06): aborted at `[1/20]` with `read-only variable: status` in `jb_patch_autotest.sh`.
  - `setup_logs/jb_patch_tests_20260306_115027` (2026-03-06): rerun after `status` fix, pending-only mode (`Total methods: 19`).
- Final run result from `jb_patch_tests_20260306_115027` at `2026-03-06 13:17`:
  - Finished: 19/19 (`PASS=15`, `FAIL=4`, all fails `rc=2`).
  - Failing methods at that time: `patch_bsd_init_auth`, `patch_io_secure_bsd_root`, `patch_vm_fault_enter_prepare`, `patch_cred_label_update_execve`.
  - 2026-03-06 follow-up: `patch_io_secure_bsd_root` failure is now attributed to a wrong-site patch in `AppleARMPE::callPlatformFunction` (`"SecureRoot"` gate at `0xFFFFFE000836E1F0`), not the intended `"SecureRootName"` deny-return path. The code was retargeted the same day to `0xFFFFFE000836E464` and re-enabled for the next restore/boot check.
  - 2026-03-06 follow-up: `patch_bsd_init_auth` was retargeted after confirming the old matcher was hitting unrelated code; keep disabled in default schedule until a fresh clean-baseline boot test passes.
  - Final case: `[19/19] patch_syscallmask_apply_to_proc` (`PASS`).
  - 2026-03-06 re-analysis: that historical `PASS` is now treated as a false positive for functionality, because the recorded bytes landed at `0xfffffe00093ae6e4`/`0xfffffe00093ae6e8` inside `_profile_syscallmask_destroy` underflow handling, not in `_proc_apply_syscall_masks`.
  - 2026-03-06 code update: `scripts/patchers/kernel_jb_patch_syscallmask.py` was rebuilt to target the real syscallmask apply wrapper structurally and now dry-runs on `PCC-CloudOS-26.1-23B85 kernelcache.research.vphone600` with 3 writes: `0x02395530`, `0x023955E8`, and cave `0x00AB1720`. User-side boot validation succeeded the same day.
- 2026-03-06 follow-up: `patch_kcall10` was rebuilt from the old ABI-unsafe pseudo-10-arg design into an ABI-correct `sysent[439]` cave. Focused dry-run on `PCC-CloudOS-26.1-23B85 kernelcache.research.vphone600` now emits 4 writes: cave `0x00AB1720`, `sy_call` `0x0073E180`, `sy_arg_munge32` `0x0073E188`, and metadata `0x0073E190`; the method was re-enabled in `_GROUP_C_METHODS`.
  - Observed failure symptom in current failing set: first boot panic before command injection (or boot process early exit).
- Post-run schedule change (per user request):
  - commented out failing methods from default `KernelJBPatcher._PATCH_METHODS` schedule in `scripts/patchers/kernel_jb.py`:
    - `patch_bsd_init_auth`
    - `patch_io_secure_bsd_root`
    - `patch_vm_fault_enter_prepare`
    - `patch_cred_label_update_execve`
- 2026-03-06 re-research note for `patch_cred_label_update_execve`:
  - old entry-time early-return strategy was identified as boot-unsafe because it skipped AMFI exec-time `csflags` and entitlement propagation entirely.
  - implementation was reworked to a success-tail trampoline that preserves normal AMFI processing and only clears restrictive `csflags` bits on the success path.
  - default JB schedule still keeps the method disabled until the reworked strategy is boot-validated.
- Manual DEV+single (`setup_machine` + `PATCH=<method>`) working set now includes:
  - `patch_amfi_cdhash_in_trustcache`
  - `patch_amfi_execve_kill_path`
  - `patch_task_conversion_eval_internal`
  - `patch_sandbox_hooks_extended`
  - `patch_post_validation_additional`
- 2026-03-07 host-side note:
  - reviewed private Virtualization.framework display APIs against the recorder pipeline in `sources/vphone-cli/VPhoneScreenRecorder.swift`.
  - replaced the old AppKit-first recorder path with a private-display-only implementation built around hidden `VZGraphicsDisplay._takeScreenshotWithCompletionHandler:` capture.
  - added still screenshot actions that can copy the captured image to the pasteboard or save a PNG to disk using the same private capture path.
  - `make build` is used as the sanity check path; live VM validation is still needed to confirm the exact screenshot object type returned on macOS 15.
- 2026-03-15 tooling source sync update:
  - removed ad-hoc `git clone` source fetching from `scripts/setup_tools.sh` and `scripts/setup_libimobiledevice.sh`.
  - added pinned git-submodule sources under `scripts/repos/` for: `trustcache`, `insert_dylib`, `libplist`, `libimobiledevice-glue`, `libusbmuxd`, `libtatsu`, `libimobiledevice`, `libirecovery`, `idevicerestore`.
  - setup scripts now initialize required submodules via `git submodule update --init --recursive <path>` and stage build copies under local tool build directories.
- 2026-06-15 cloudOS 26.5 (23F77) JB retargeting — P0 (sudo/setuid):
  - **JB-04 `patch_hook_cred_label_update_execve` (P0, sudo/setuid) — FIXED.**
    Root cause: `findVfsContextCurrentByShape()` pinned a 5-word prologue ending
    in `ldr x1, [x0, #0x3E0]`; the uthread offset drifted to `#0x3F0` on 26.5
    (`0x3E8` on macOS 26.5.1 KDK), so the exact match returned 0 hits.
    Fix: resolve `vfs_context_current` generically — symbol first, else the stable
    4-word prologue prefix (`pacibsp; stp x29,x30,[sp,#-0x10]!; mov x29,sp;
    mrs x0,tpidr_el1`) followed by *any* `ldr x1,[x0,#imm]` (imm left unpinned);
    uniqueness still required. Reveal: on the decompressed kernelcache the prefix
    matches 5 sites, exactly one followed by an `ldr x1,[x0,#imm]` →
    `vfs_context_current` @ va `0x8D7F39C` (foff `0x1D7B39C`). Validated via
    `make test_jb_patches`: both `jb.hook_cred_label.{ops_retarget,c23_cave}` emit.
  - Symbol oracle for the above: macOS 26.5.1 KDK (`KDK_26.5.1_25F80`) —
    `kernel.release.vmapple` + `Sandbox.kext`/`AMFI.kext` (arm64e) carry full nlist
    symbol tables for the XNU/Sandbox functions stripped from the vphone600 cache.
  - Remaining 26.5 JB failures (8) still open: `task_conversion_eval` (inlined),
    `proc_security_policy` + `proc_pidinfo` (shared `_proc_info` switch refactored,
    `cmp #0x21` bound gone), `io_secure_bsd_root` (iOS-only, absent from KDK),
    `mac_mount`, `spawn_validate_persona` (iOS-only), `vm_map_protect`,
    `kcall10`/`sysent`.
- 2026-06-16 cloudOS 26.5 (23F77) JB retargeting — the 8 remaining P1 failures, all FIXED.
  Ground truth: IDA (idasql) on the decompressed `kernelcache.research.vphone600`,
  symbolicated via the macOS KDK oracle; XNU source cross-check. Validation:
  `make test_jb_patches` → every supported cloudOS kernel applies with **0** `[-]`
  failures (84 patches each). All anchors are version-independent
  (semantic/Capstone/call-graph), no pinned offsets/indices.
  - **JB-11 `proc_security_policy` + JB-12 `proc_pidinfo` (shared root cause).**
    The `sub wN,wM,#1 ; cmp wN,#0x21` switch anchor matched TWO sites on 26.5; the
    naive first-match grabbed the wrong one (`decodeWakeReason`, lower address).
    Replaced the whole `findProcInfoAnchor` with two source-backed finders in
    `KernelJBPatcherBase.swift`: `findProcSecurityPolicy()` locates the unique
    function that loads `PRIV_GLOBAL_PROC_INFO` (1002 = `0x3EA`, a stable
    `bsd/sys/priv.h` ABI value) into `w1` ahead of `priv_check_cred` →
    `_proc_security_policy` @ va `0x927E330` (stub entry `mov x0,#0; ret`);
    `findProcInfoInternal()` = its sole caller via `blIndex` → `_proc_info_internal`
    @ `0x927B38C` (proc_pidinfo is now inlined there). proc_pidinfo NOPs the unique
    `ldr x0,[x0,#0x18]; cbz x0; bl; cbz/cbnz wN; mov w0,#0x16(EINVAL); sub wN,wM,#1`
    guard pair → `0x927BDA8` / `0x927BDB0`.
  - **JB-08 `task_conversion_eval_internal`.** Inlined; recovered via the unique
    `"…pineapple on pizza…"` panic-string function (`task_get_special_port_from_user`).
    The 26.1 matcher failed only because the compare operands swapped
    (`cmp x0,x9` vs `cmp x9,x0`). Rewrote `collectTaskConversionCandidates` to accept
    the kernel_task-vs-{X0,X1} compare in EITHER operand order. Unique hit
    `cmp x0,x9 → cmp xzr,xzr` @ va `0x8D087A8`.
  - **JB-?? `io_secure_bsd_root`.** `AppleARMPE::callPlatformFunction` (refs both
    `"SecureRoot"`+`"SecureRootName"`). The match-bit compare-context moved >0xA0 back
    (sync code inserted), breaking the old lookback. Re-anchored on the unique
    `csel Wd,wzr,Wn,<cond>` whose `Wn` is built as `kIOReturnNotPrivileged`
    (`movk Wn,#0xE000,lsl#16` — IOKit error high half). `csel w22,wzr,w9,ne →
    mov w22,#0` @ va `0x7B30E10`. Dropped the pinned `[x19,#0x11A]` field offset.
  - **JB-?? `mac_mount`.** Wrapper still uniquely identified by the twin gates among
    `mount_common` callers (`__mac_mount` @ `0x8EC04F0`). Site 1 (`tbnz wFlags,#5 →
    mov w?,#1` preboot reject) unchanged → NOP @ `0x8EC06FC`. Site 2 folded on 26.5:
    `add x?,#0x70 ; ldrb w8,[x?,#1] ; tbz w8,#6` → `ldrb w8,[x16,#0x71] ; tbnz w8,#6`.
    Re-anchored `findStateGate` on the `ldrb wN,[x,#imm] ; tbz/tbnz wN,#6` pair (the
    `#6` role bit is the stable semantic) and clear the loaded reg → `mov x8,xzr`
    @ `0x8EC072C`.
  - **JB-?? `spawn_validate_persona`** @ `0x91C0D4C` (reached from the spawn
    entitlement wrapper, intact). The trailing `mov x?,#0 ; ldr x?,[x?,#0x490] ; casa`
    corroboration lowered differently on 26.5; re-anchored `matchPersonaHelper` on the
    dual sibling reject `ldr [base,#8];cbz / ldr [base,#0xc];cbz` (same base + same
    deny target + deny `mov w?,#1`), preceded by the `[_,#0x18]` sibling guard. NOP
    both cbz → `0x91C0DF8` / `0x91C0E00`.
  - **JB-25 `vm_map_protect`** @ `0x8DCA0A8`. The 26.1 `mov #6;bics;b.ne;tbnz#22;and
    #~X` block was recompiled; the per-entry apply path now narrows protection with a
    runtime W^X mask register before `pmap_protect_options`
    (`lsr wT,wFlags,#7 ; and w3,wT,wMask`, `mov wMask,#5`). Widening the mask `#5 → #7`
    makes the AND a pass-through so the requested protection (incl. the stripped bit)
    reaches the pmap — strictly permissive (`prot&7 ⊇ prot&5`). `mov w27,#5 → mov
    w27,#7` @ `0x8DCA30C`.
  - **JB-?? `kcall10` / sysent.** `findNosys()` matched an unrelated tiny
    `mov w0,#0x4e; ret` stub; the real `_nosys` is a large handler the sysent rows
    actually point to (112/558 entries). Rewrote `findSysentTable()` to find the table
    STRUCTURALLY (no `_nosys` dependency): the longest run of valid 24-byte `sysent`
    rows (chained auth-rebase `sy_call` into __TEXT_EXEC + sane
    `sy_return_type/sy_narg/sy_arg_bytes`). Base @ foff `0x7693B0` (558 rows);
    `sysent[439]` (`SYS_kas_info`) @ foff `0x76BCD8`; cave + 3 entry writes emit.

## Structured kernel results (2026-09-09)

C3 migrates the existing kernel patch schedule to per-method outcomes. Base
kernel methods now fail on an incomplete group, including any missing member
of the five-hook Sandbox group. Conditional and ablated steps are intercepted
before discovery because kernel `emit()` writes through to the working buffer.
No new patch sites or replacement bytes are introduced. Method coverage and
record/payload parity evidence are tracked in
[the C3 kernel migration record](patch_results_c3_kernel_2026-09-09.md); historical
record totals above do not establish completeness for a new input.

### C3 后续结构化迁移（2026-09-09）

JB 33 个、EXP 1 个方法及 DeviceTree/Manifest/Filesystem 操作接入结构化结果。JB 的凭证标签更新与扩展 Sandbox、EXP 的 OID/调用者改名增加完整性判据；本次没有重新定位指令或改变替换字节。Manifest 记录使用实际输入/输出字节。

26.1、26.4 已运行用例的迁移前后记录与 payload 比较相等；26.4 dev 的 EXC_GUARD 与 JB 的 vm_map_protect 必要项失败，顺序组合也如实失败。未恢复已停用的 vm_map_protect Shape B，未扩大支持范围。输入哈希、验证结果、历史证据与未完成项见 [C3 内核记录](patch_results_c3_kernel_2026-09-09.md)、[EXP 记录](patch_results_c3_exp_2026-09-09.md)、[产物记录](patch_results_c3_artifacts_2026-09-09.md)。

### C3 26.4 内核重新定位（2026-09-09）

EXC_GUARD 从 entitlement 引用恢复调用关系，兼容 26.1 两层 BL 和 26.4 包装函数尾调用；核对 code/subcode 保存和 AST bit 更新后，只将目标入口替换为 RET。vm_map_protect 从主函数认证回调指针恢复 26.4 的 BIC/CMP/CCMP 执行权限 gate，仅改写 B.NE 为同目标 B；COW WRITE mask 保持不变。地址不参与运行时定位，必要性规则未改变。26.1/26.4 的目标地址、唯一写入、重复应用及异常锚点拒绝测试通过；26.4 必要集合与包含 Frida 的顺序组合通过，组合为 133 条记录。尚未进行修正后的 VM 实机测试。实现和验证见 [重新定位记录](c3_kernel_retarget_2026-09-09.md)，详细 reveal 见 [诊断记录](c3_acceptance_diagnosis_2026-09-09.md)。

### C3 远程迁移合并（2026-09-10）

合并保留双方历史记录，采用本地已验收的必要性、门控及匹配算法，接入远程明确的歧义、部分写入和幂等信号，并统一延迟准备过程。`patchVmMapProtect` 与 `patchCredLabelUpdateExecve` 保持 required。本次不新增补丁。主控逐文本核对 35 个变动既有 kernel 文件的 emit 调用块未变；24 个非 less 场景全部通过当前 legacy/structured 完整记录比较，以及合并前 CLI 实际产物的全部 9 个组件 payload 逐字节比较。less 真实产物只读比较通过；Filesystem 实现未变化，本次没有重新构建镜像。完整回归与构建签名通过。结论限于上述场景，不新增恢复或启动证据；取舍和验证见 [合并记录](c3_remote_merge_2026-09-10.md)。

### A3 临时运行时观测（2026-09-16）

仅在 rig2 26.1 / 23B85 EXP 的 SpringBoard 中加入透传观测及可撤销的 HID 边缘诊断断言，未修改内核、DSC、设备树或生产固件补丁。原输入失败，忽略 HID 边缘检查后两次成功，撤销后失败；隔离注入 FromEdgeTip 可进入应用切换器，尚未完成生产修复。临时注入文件已删除并重启 SpringBoard，不改变任何补丁计数或版本支持声明。见 [HID 边缘诊断](a3_hid_edge_diagnosis_2026-09-16.md)。

### A3 用户态触控修复与验收（2026-09-16 后续）

正式宿主传递可选 `edge` 字段，客户机在整段单指手势及断线释放中保持 `FromEdgeTip` 标记。rig2 26.1 / 23B85 EXP 的底部 Home 手势、点击、拖动、长按、三档窗口缩放及断线重连已取得实际证据。仅更新用户态宿主与 `vphoned`，不修改内核、DSC、设备树、固件补丁逻辑或补丁计数；其他版本及变体不扩大支持声明。部署备份、签名构建和支持限制见 [A3 验收](a3_touch_acceptance_2026-09-16.md)。

## 2026-09-29 — Restored offline Python/Swift comparison fixtures

PCC 26.1 / 23B85 archive SHA-256: `399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349`. Fixtures are generated by `scripts/prepare_firmware_fixtures.py` from this cached archive and the host AVPBooter, using the independent Python source at `08eb9d260f6494549220c3109eafd18da9fa75f4`. The generated provenance file records the host AVPBooter digest, dependency versions, source hashes and all fixture hashes.

The legacy export helper's uppercase iBoot defaults initially produced four label-byte mismatches. Generation now passes the same explicit `Loaded iBSS` / `Loaded iBEC` / `Loaded LLB` labels as that revision's actual firmware entrypoint. AVP reference records come from the real legacy entrypoint's writes. Current patcher code and reference instruction bytes were not adjusted to mask differences.

`make test_firmware` passed 13 tests in 11 suites. Patch comparisons: AVPBooter 1, iBSS 4, iBEC 7, LLB 13, TXM 1, TXM dev 12, kernel base 28, iBSS JB 1, kernel JB 84. IM4P payload/repack checks and the diagnostic kernel test also passed. This is offline evidence for the recorded inputs, not VM restore/boot acceptance. See `research/artifacts/upstream-remaining-2026-09-29/firmware-comparison-final.log`.

The separate full-pipeline gate also passed for PCC 26.1 / 23B85: regular 29 methods / 58 records, dev 34 / 70, jb 68 / 152, exp 88 / 178. Runs used isolated copies under `research/artifacts/upstream-remaining-2026-09-29/firmware-variants`, without booting a VM. The less pipeline and other cloudOS builds were not run in this batch. Structured reports and gate output are retained there.


### 2026-10-07 B07：DSC maxSlide 共享区域拒绝条件

`cfw_patch_dsc_maxslide.py` 在决定是否清零 maxSlide 前拒绝未知/非法区域容量，并拒绝缓存自身 sharedRegionSize 超过给定 kernel 区域的组合，包括 maxSlide=0、force 和 dry-run。显式 7 GiB 参数只表示调用者给定容量，不构成安装内核证明；默认仍保留既有 vphone600 6 GiB 路径。本轮没有增加内核扩容补丁或证明新区域可启动。合成缓存验证和原始日志记录在 B07 台账。


### 2026-10-09 B22：IcliKit JPEG 源码适配

新增`dependencies/daemon-api-overlays/icli-jpeg-copy.patch`，仅适配固定IcliKit0.7.16 / 702990b59ca412ad975f9f0ea5dafe95c30fac21截图编码：先复制到独立DeviceRGB位图，再生成JPEG，避免编码结果保留原screen image。manifest固定原始源码、patch及编译源码摘要，构建及运行时source marker一致；没有更改固件二进制补丁、内核/DSC/设备树或补丁计数。40次真实截图稳定采样19,071,480→4,555,256→4,555,256字节、FD15→15；90度旋转未生效，原因未查明，完整图像/服务矩阵尚未验收。证据见upstream_integration_2026-10-06/evidence/B22-summary.json及B22-bound-memory.json。

### 2026-10-09 B23 宿主与客户机监督进程验收

本批未修改固件补丁算法或补丁数量。T07在vm-new恢复副本的隔离API_ONLY进程中验证launchd监督、不同签名binary更新确认/回退及坏缓存回退；classic daemon和缓存恢复原摘要。不同binary的53个Mach-O section载荷相同，本结果不证明新功能、kernel或环境迁移。Safari旋转/JPEG及RootHide纯路径测试通过；实际RootHide未验。来源和限制见`upstream_integration_2026-10-06/evidence/B23-summary.json`。


### 2026-10-10 B30：RootHide 服务配置权限

实际RootHide中服务start在user501返回transport0/reply.error144。单项加入`com.apple.private.xpc.service-configure`后，start/stop返回0且实际PID存在；恢复原签名再次144，关闭诊断库后对照通过。经用户明确授权，产品API daemon entitlement增加该键。51个Mach-O section载荷保持，候选签名及文件摘要变化；未修改固件二进制补丁、内核、DSC或补丁计数。RootHide真实plist重写与独立服务生命周期通过；方向scene策略与完整T08验收保持未完成。证据见`upstream_integration_2026-10-06/evidence/B30/T08/REPORT.md`。


### 2026-10-10 B31：RootHide旋转运行时策略

B30单entitlement候选在实际RootHide完成24组方向观测，14成功、10拒绝且保持角度。临时控制应用提供四方向集合30，但UIKit解析控制器和场景集合为26；直接请求180度返回UISceneErrorDomain101。控制器集合2的可逆对照、截图摘要及尺寸通过。Settings/Safari直接场景策略与UIKit倒置方向过滤条件未完整取得。未修改产品源码、固件二进制补丁、内核或DSC，补丁计数不变。临时工件已清理并正常停机。证据见`upstream_integration_2026-10-06/evidence/B31/T08/REPORT.md`。


### 2026-10-10 B32：RootHide倒置方向过滤与系统场景策略

实际UIKitCore UIApplication私有方向方法在原生手机且UIDevice无Home键时执行mask & 26，系统应用自然调用与受控应用同PID的26→30→26对照已取得。Settings场景/客户端集合2，Safari均26；原API无Frida进程重跑8组，4接受、4拒绝且保持角度。受控B阶段公开180度请求未报告错误但实际仍0度，未计为旋转成功。未修改产品源码、固件二进制补丁、内核或DSC，补丁计数不变；临时AMFI detach失败与恢复核对、客户机清理失败及最终清理均保留。证据见`upstream_integration_2026-10-06/evidence/B32/T08/REPORT.md`。

### 2026-10-10 B35：RootHide 启动恢复源码修复

现代 API daemon 在完成标记有效、RootHide 链接修复成功后异步逐项准备并加载 LaunchDaemons；保留 API_ONLY 条件。实际函数红测试 4 项失败，最终相关回归 22 项通过；隔离 API、默认完整签名 app 与六项现代组件构建通过。默认 app 仍打包 classic，未部署新候选或验证真实冷启动。新宿主 --help 被 AMFI -424 拒绝，精确临时授权待批准。未修改固件二进制补丁、内核、DSC或补丁计数。证据见`upstream_integration_2026-10-06/evidence/B35/T08/REPORT.md`。

### 2026-10-11 B37：T08 离线准备

本轮新增显式 worktree 路径与离线迁移计划，复核 B35 冻结产物和 663 项生产输入；未修改 firmware/kernel/CFW 二进制补丁，补丁数量保持。68 项定向回归及现有组件宿主测试通过；默认仍 classic，未执行 VM 或磁盘迁移，未新增真实运行验收。证据见 `research/upstream_integration_2026-10-06/evidence/B37/T08/REPORT.md`。

## 2026-10-11：T08 独立 API 的默认 CFW 安装

B38 保留 classic `/usr/bin/vphoned`、1337 控制和 256 字节相机头。新增 `/usr/libexec/vphoned-api` 和 `com.vphone.vphoned-api`；API 的缓存为 `/var/root/Library/Caches/vphoned-api`，launchd 环境关闭 API 相机发布，RootHide 启动恢复继续执行。regular/dev/jb/exp 安装将其 plist 写入 System LaunchDaemons 及合并 launchd.plist 的 LaunchDaemons 字典；less 不安装该 API。没有新增内核或 Mach-O 指令替换，classic `/b` 环境保持。固定 7 项依赖、当前源码构建及默认 Bundle 校验通过；研究副本两次冷启动的 API 摘要与默认载荷一致，RootHide 服务自动加载，classic 缓存保持。106 项定向回归和组件 124 项检查通过；完整现代环境/相机迁移不在本次 T08 验收内。证据见 `research/upstream_integration_2026-10-06/evidence/B38/T08/REPORT.md`。


## 2026-10-11：T24 本地 Bundle 布局

B39将已知签名local-bound协议的CLI/VM布局与旧版含escalator布局区分；未知协议和错误主程序拒绝，store所有权、签名、receipt和锁定执行检查保持。没有新增firmware/kernel/CFW指令替换或二进制补丁，补丁数量保持。52项定向Swift回归、实际签名宿主归档private testRoot安装复验1项及5项脱敏回归通过；实际系统store与完整TCC路线等待本轮批准，不增加运行验收结论。证据见research/upstream_integration_2026-10-06/evidence/B39/T24/REPORT.md。

## 2026-10-02 — v2 环境 B3 的 launchd 修改范围

新增离线 v2 profile 安装器，仅接受 regular。首次安装对暂存 System 卷的 `/sbin/launchd` 添加 `LC_LOAD_WEAK_DYLIB /vh`，保留原 entitlements 后用已有 ldid/证书流程重签；重装已有加载命令时不重复注入。库、别名和 API 守护进程属于用户态安装范围，regular 的内核、TXM、DSC、设备树补丁集合未改变。

合成目录树安装后判定 already_current；真实 insert_dylib 对 clang 编译的 macOS 合成文件添加弱加载命令的测试通过。这些证据不建立真实 iOS launchd 可启动或 regular 内核可加载该库的结论；R4 与 D6 仍待用户授权后的真实验收。拒绝条件、写入范围和验证限制见 [B3 记录](v2_guest_environment_b3_2026-10-02.md)。

### 2026-10-02 v2 regular 真实验收 R1–R4

独立签名产物在测试 VM `lp-v2-accept-20261002` 完成创建、恢复、CFW、首次启动和启动验证。launchd 的 /vh 弱加载命令经离线安装后可启动；R2 只读判定 already_current、bootstrap.kind v2、disk.unchanged true。R3 经典/API daemon 并行连接，API device.info 成功。R4 扫描 282 个进程、无 uninspected，pid 1 映射当前 launchdhook，SystemHook 在所有扫描进程中 not_mapped；运行中的 cameracaptured 未映射它。注入失败原因未查明，不能据此确定 regular 内核补丁不足。按 D6 停止后续验收，未新增任何内核、TXM 或 DSC 补丁。详见 `v2_guest_environment_real_acceptance_2026-10-02.md`。

### 2026-10-02 R4 用户态注入修正候选（未安装）

实际 launchd 的反汇编包含 posix_spawnp 调用，本地 launchdhook 的 interpose 表未覆盖该入口。直接 cameracaptured 路径也不符合既有目标筛选。真实源码和插桩表边界测试修改前两项失败；修正增加 posix_spawnp 插桩及精确相机路径，两种 spawn 共用环境逻辑。Python 590 项通过，iOS 候选检查通过；仅 launchdhook 库摘要变化为 `157beaed8168fa53df58cdcf2d6181152bb4a5409a7ec1b093af21c394073027`，其余四个库不变。未新增 kernel、TXM、DSC 或 MIS 补丁；候选尚未写入客户机，真实因果验证等待批准。后续诊断发现 App 扩展已有 SystemHook 映射，早期无映射结果仅适用于原扫描时刻。详见 `v2_injection_diagnosis_2026-10-02.md`。

### 2026-10-02 launchdhook 修正的真实复核

用户批准后，T16 事务 `20261002T064301Z-rFaRcKXJ` 仅替换 launchdhook，旧盘保留，七项身份摘要在重启前核对一致。重启后原失败反馈两次通过，pid 1 映射新 launchdhook；cameracaptured 的 SystemHook 与 libvcamcaptured 均 current，App 与扩展亦有映射。日志显示相机服务经 xpcproxy 注入。没有增加 kernel/TXM/DSC/MIS 补丁。本次 regular 26.1 组合的 R4 加载复核通过，不证明功能验收或其他组合支持。详见 `v2_injection_diagnosis_2026-10-02.md`。

## 2026-10-12：handoff 合入固定上游开发线

以 `2c119ae6` 为基线合入 `959acfc0`。保留 B38 默认 classic 1337/1338 与固定依赖现代 API 1339；显式 regular-v2 使用单独 plist 候选、相机关闭配置及 handoff 用户态安装流程。API 更新标记保持最新实现。创建流程冻结两类 v2 输入，安装前核对固定 pins、overlay 声明与二进制 marker。

root-remount 仅在显式 regular-v2 实验路径启用，默认关闭，调用已有 `KernelJBPatcher.mountOnly` 路径。固件事务同时记录实验选项、冻结 plan、versionInputs 和 planBinding；未改写既有内核补丁算法。旧检查点省略新增可选字段时保持摘要兼容。

本轮 `make test_python`（679 项、无跳过）、`make test_swift`、现代组件构建及完整签名 app 构建通过；完整夹具下的 `make test_firmware` 共 15 项、12 个 suite 通过；不能据此确定恢复、启动、重挂或应用功能。Python 最终复跑与签名构建结果记录在 `research/handoff_merge_2026-10-12.md`。本轮未部署候选或启动 VM，历史验收保留原日期和组合范围。

## 2026-10-13：Task 5 guest 写入使用冻结计划

固定上游仍为 `2d21d21fbdd4f51f013616273ceda9b35a3e0789`。Swift 向现有 CFW Python/zsh 入口传递当前已验证 desired record 的原始字节摘要、semantic planDigest、VM/磁盘/generation/catalog 身份及实际 variant/profile。写入入口再次验证同一记录、写锁、私有暂存目录和证据文件；未知声明、未声明目标、变更计划、模式覆盖和旧 nil profile 均拒绝新增写入。直接 Python 写入也拒绝符号链接父目录。

本轮新增 9 个本地 guest 安装声明，保留固定上游 141 个声明及 2 个 local less 声明的来源区分，共 152 个 canonical ID。安装目标表由 `scripts/generate_guest_target_rules.py` 从明确路径及内置归档成员生成，SHA256 为 `7ac7230b7c075388d0d0dd2822acf896a82244e95f844e3faff451c3f190ba2f`；摘要进入冻结 recordRules。`guestEnvironmentV2` 为可选冻结字段，旧 nil 保持原编码但不获得新执行资格。less 仅通过已选 filesystem 声明授权已有三个 Python 子操作。EXP 专属声明继续受 EXP 范围约束；既有二进制补丁算法未改变。

Cryptex OS/App 分别作为两个精确完整目录树目标：原始镜像绑定 generation，未知来源缓存通过受控生成过程重建，挂载关系及完整拷贝成员读回需一致。操作证据记录声明、精确目标、实际前后摘要及同一 planDigest。该证据不等同于 Task6 component receipt 或最终应用结果；atomic Disk.img 交换后的身份重绑仍依赖 Task10。

最终命令、源码清单及原始日志的 gzip/SHA256 索引见 `research/evidence/2026-10-13-task5-frozen-guest/manifest.json`。合成目录树和命令替身测试不能证明真实镜像安装、恢复或启动成功。本轮未进行真实 mount、VM、AMFI/TCC 或系统安装操作；最终冻结工件的真实验收仍属 Task12。

本轮相关 Swift 58 项/5套通过，最终受影响 Python 41 项通过，三个生成器及六个 zsh 语法检查通过。完整 Python 运行 704 项，保留 3 个旧夹具失败和 3 个环境跳过的原始结果；三个失败在随后受影响 41 项测试中修正并通过，完整套件未重复。不能将该记录表述为完整标准套件全通过。

### Task5 审查修正 1

修正 build-version 的参数解析：缺少 build 参数时拒绝，合法 `--dry-run` 使用同一解析结果决定只读分派。DSC 写入前拒绝末级符号链接、非普通文件和底层枚举器可能接受的未声明同前缀成员。bootstrap 成员转换现在将 `var` 精确映射为 `procursus`，保留第二次 `procursus/jb/*` 移动所需的目录目标；未增加任意后代授权。目标表新 SHA256 为 `b8ec0af0c1628ac963a0aaa39429e097985c09c6e11af83840972d7ac38fad0c`，旧摘要对应计划不能取得新规则资格。

失败回归实际复现了未授权 plist 修改、DSC 外部链接目标修改和 JB/EXP 根目录移动拒绝。修正后 Python 54 项通过；Swift catalog/计划序列化/CFW 集成等 76 项、7套通过，三个生成器检查和六个 zsh 检查通过。JB/EXP 测试使用内置真实归档的 apt 文件字节及目录结构，执行各安装脚本的两条移动命令；未挂载镜像或执行完整安装。原始失败和成功日志及摘要见 `research/evidence/2026-10-13-task5-fix1/manifest.json`。


## 2026-10-13：Task 6A1 最终效果证据与 less 加密顺序

`CryptexFilesystemPatcher` 原先在 `mergeFilesystems` 内加密，随后 `apply` 才删除指定系统文件并生成 mtree、DigestDB 和封印。本次将加密移到这些最终明文修改之后，并在事务模式下解密最终 AEA，以只读挂载回调核验 producer 目录树及嵌套操作效果。安全文件替身回归复现了原顺序输出缺少最终修改；修正后的顺序为 prepare → encrypt → verify。该修改未新增二进制补丁规则或改变 variant 选择。

操作证据在现有 Task5 JSONL 中增加可选 `effect`，保留 generation、desired 原始摘要、plan 摘要及声明归属。证据保存实际前后状态和按 SHA256 寻址的流式文件快照。新增读回比较字节范围、plist 修改键与删除、Mach-O 新增加载项和非结构字节，以及 DeviceTree 声明中的节点/属性身份。Manifest 读回复用现有 `patchIm4pTypeTag` 摘要语义及引用工件验证。IM4P payload 先转成零起点 Data，避免容器切片索引被当成 payload 偏移。

6A1 的初始 receipt 仅表示 generated/committed 工件证据模型；本次未接入事务发布或 origin 写入。签名结构与 CodeDirectory 解析器仅为后续组合验证提供基础。shell 签名调用、Campo 嵌入 entitlement、DSC 同页摘要及 archive/move/消费关系由 6A2 接续。未完成的消费验证不会被调用来阻断现有受控写入；显式请求最终验证时，缺少上述关系的记录拒绝证明。Task6A 及 Task6 整体仍未完成。

最终聚焦测试命令、结果、源文件 SHA256 和全部 RED/GREEN 日志的原始/gzip 摘要见 `research/evidence/2026-10-13-task6a1/manifest.json`。本轮只使用安全合成文件、目录和命令替身；没有执行真实 mount、VM、sudo、AMFI/TCC 或系统安装。真实加密工具、挂载和 OS 签名接受行为仍需 Task12 验证。


## 2026-10-13：Task 6A2 签名、DSC 摘要和安装成员效果组合

固定上游仍为 `2d21d21fbdd4f51f013616273ceda9b35a3e0789`。本轮将已有 ldid 调用接入显式生产操作，记录实际输入、输出、参数和 entitlement 来源。签名验证解析每个 Mach-O/FAT slice 的结构和 CodeDirectory，保留先前代码及加载命令效果，并检查最终被覆盖页摘要。Campo 源 plist 的修改通过显式签名关系核对最终二进制内的 entitlement。该验证不证明 OS 接受签名。

`cfw_patch_dsc_maxslide.py` 的数值选择、默认 6 GiB 门槛、dry-run/no-op 和模式保持不变。当实际修改的头部页被已识别 CodeDirectory 覆盖时，操作先检查该页原摘要，再从现有 DSC mapping 推导修改页 VMA，并调用已有 `reattest_modified_pages` 更新对应槽。该变化新增 CodeDirectory 槽字节输出差异；此前只有 maxSlide 头部字段变化。未覆盖页不增加槽写入，坏的原页摘要拒绝修改。最终组合验证保留各次原始代码修改，并按最终页内容检查共享槽，拒绝恢复先前代码或写入错误页摘要。

固定上游二进制比较须将“maxSlide 字段变化”和“本地新增 CodeDirectory 槽更新”分别列出；不能把新增槽差异计为固定上游逐字节一致。本轮使用带 CodeDirectory 的安全合成缓存运行实际 maxSlide 入口，未重新执行真实固件对照或真实镜像验收。

归档、复制、两段 bootstrap 移动及删除容器通过实际来源成员和操作标识组合。EXP 在源 Cryptex 挂载上的 DSC 修改记录镜像身份、前后摘要、原始成员清单和操作行摘要；只读重挂载核验成员后，复制到最终 System 根。JB/EXP 的两个 LaunchDaemon plist 注入复用已有算法并增加显式效果记录。正常安装在 installer/v2 结束后、cleanup 前，只读挂载同一 staged Disk.img 并验证最终目标；该阶段早于后续 `apfs_snap_rename.py` 和 Disk.img 发布。此证据不能作为发布后磁盘摘要、receipt、origin 或启动验收。

最终受影响测试和失败日志、源码 SHA256、原始及 gzip 日志 SHA256 见本轮 `research/evidence/2026-10-13-task6a2/manifest.json`。本轮没有执行真实挂载、VM、sudo 系统安装或 AMFI/TCC 修改。Task6B/C 及真实系统验收仍由后续任务完成。


## 2026-10-13：Task 6B 同一事务日志发布 component receipt

FirmwarePipeline 将实际组件输出和完整 PatchRecord 集合交给最终效果验证。现有 FirmwareTransaction 日志同时管理输出目录、`.firmware-component-receipts.json` 和受限的 `launchpad.json` 元数据；发布后重新读取实际字节，核验通过后才写入 committed 日志。可选元数据保留原始字节或真实缺失状态，恢复过程拒绝覆盖未知字节。旧 nil 字段和旧日志恢复兼容；旧记录不因此获得新执行资格。未新增二进制补丁或改变既有算法。

less 的发布读回通过实际 CLI、Python proof 验证和同一事务锁执行；writer 仍限 building 阶段。测试替换解密及只读挂载操作，验证最终目录效果丢失或 detach 失败时拒绝提交。锁描述符继承保留同一 open-file-description，并核对事务目录身份；父进程退出后，worker/tool 在结束前保留恢复排他锁。

generated Restore/AVP 输出不更新已安装 VM origins。供 Task6C 使用的内部 hook 要求活跃的来源资格回调、精确目标及 proof 关联，并在元数据 rename 前和 committed 日志前复验；B 未提供生产 installed-component adapter。A2 的一般 CFW 最终验证仍位于 cleanup/snapshot 之前，不构成永久发布后授权。

较早受影响 Swift 132 项、16 套通过，DeviceTree 真实固件 parity 选择器关闭；Python 36 项通过。最后的 origin 资格窗口修正后，直接受影响 Swift 48 项、4 套通过。原始日志、gzip、命令、退出码及最终源码摘要见 `research/evidence/2026-10-13-task6b/manifest.json`。本轮只使用安全合成字节、目录和故障注入；未执行真实镜像挂载、VM、sudo、AMFI/TCC 或系统安装。Task6B 待独立审查，Task6C 和 Task12 验收尚未完成。


### Task6B 审查修正 1

最终 callbacks 和效果读回结束后、写入 committed journal 前，重新比较全部输出根与 journal 摘要，覆盖未列入 component receipt 的保留文件、新增成员和未变化的根。启动 worker 后发生 I/O 故障时，父进程先处理输出并等待 worker，再离开共享锁作用域；pipe 描述符由运行函数明确拥有，FileHandle 包装不重复关闭。真实 subprocess 故障测试中，工具存活期间的实际 recovery 被拒绝，stdout/stderr 共 4 MiB 输出完成后才返回原 I/O 错误。

两项审查问题均有实际 RED/GREEN；最终受影响 Swift 50 项、4 套和 Python worker 8 项通过。证据与最终源码摘要见 `research/evidence/2026-10-13-task6b-fix1/manifest.json`。C 生产来源资格和 legacy import 仍属下一步骤，真实固件/VM 与全标准验收仍属 Task12。本次未新增二进制补丁或执行真实挂载和 VM 操作。


## 2026-10-13：Task 6C1 来源资格、已安装读回与旧格式导入

C1 新增实际 Store 回调内的 kernelcache 来源适配器。当前有效 Bundle 可执行文件从 generation pristine 输入调用实际 Swift producer 重算，关联完整输入、输出及逐项记录；只读 Disk.img 的唯一 Preboot 目标须与完整重算 payload 一致。实际 B 事务日志同时提交 kernel 来源及 receipt，保留 host、guestEnvironment、bootChain。单个 bootChain 组件拒绝层来源晋升。没有新增二进制补丁或改变现有补丁算法。

外部 binding/receipt 读取拒绝 pending 事务及读期间目录变化；B 仅在事务内部读取过渡 binding。fixed 2d21d21 的 PatchReceipt.plist/原 PatchPlan.plist 以实际字段导入，保留原始字节、缺失、损坏、不支持及未知 part；导入不产生 applied 或 origin 资格。guest 最终效果和 live Bundle source 检查只返回 inspected-unqualified-producer。

Ruling21 将真实 CFW producer 捕获、sudo/VM 锁交接、Disk.img 身份转换、发布后 guest 资格及完整四层路由保留为 C2，并与 Task10 集成；C1 不构成 Task6 或原五项完成。最终 affected Swift 122 项/15 套通过；自审后仅补充测试并重跑直接受影响 10 项/2 套通过。Python 74 项在普通工具提权下通过；首次沙箱执行的合成 CFW 克隆 EPERM 失败日志保留。全部命令、原始/gzip 日志、源码摘要见 research/evidence/2026-10-13-task6c/manifest.json。未执行真实 VM、挂载、sudo、AMFI/TCC 或系统安装；实际固件、固定上游 producer 和完整标准验收仍属 Task12。

### 2026-10-13 Task 8 真实 VM 验收准备

本轮创建 `vm-new` 的隔离 APFS 副本，源与副本关键文件完整 SHA-256 一致。最终本地 Core Bundle `2.6.20261013-local` 已签名、安装并复验；本轮未改变内核补丁声明或补丁逻辑。新增从真实 IPSW 准备 generation 的入口；实际准备发现的目录 URL 比较问题已修复，49 项相关测试通过，修正版 `2.6.20261014-local` 的真实 IPSW 准备与 EXP desired plan 发布成功。最终 VM `--help` 预检退出 137，不能据此声明启动通过。已提交内核更新的精确回退尚无公开入口；`--recover` 只处理未提交事务。验收详细进度及证据见 `evidence/2026-10-13-task8/acceptance/acceptance-progress.md`。

### 2026-10-13 Task 8：JB 已应用输出证据

cloudOS 26.1 23B85 research vphone600 原件 payload SHA-256 为 `b6846048f3a60eab5f360fcc0f3dcb5198aa0476c86fb06eb42f6267cdbfcae0`。基础 KernelPatcher 先在文件偏移 23332268 修改 postValidation 比较，在 16177504 修改 bsd_init rootvp 分支。后续 JB 方法识别相同位置的已应用状态，但原实现未记录具体输出，严格声明门因此拒绝两条必需声明。

修复保留原有语义定位流程。唯一已应用位置通过只读 `emitVerifiedOutput` 核对当前字节并记录原字节等于输出字节的观察；不执行写入，结果仍为 `alreadyApplied`。StructuredExecution 将观察关联当前输入及输出摘要。声明门未放宽。基础阶段仍有两条真实修改，JB 阶段新增两条已验证观察、零条字节修改。摘要输出改为 byte records，避免将观察数量表述为写入次数。

离线重现命令和日志：`research/evidence/2026-10-13-task8/already-applied-red.*`、`already-applied-green.*`。最小真实 fixture 重现由失败转为通过；既有必需声明证据测试同时通过。真实 VM 更新和启动验收另行记录，离线通过不建立启动结论。

### 2026-10-14 Task 8：磁盘扫描内存诊断

第五版 `2.6.20261017-local` 的离线更新在 699.816 秒后 SIGKILL，未触发注入，日志为 building 且无 kernelDisk。正式恢复退出 0；六个关键文件完整 SHA-256、inode 与第五版绑定保持一致。SIGKILL 原因未查明，系统查询没有提供明确终止原因。

真实 `FirmwareKernelDisk.capture/validate` 的安全 64 MiB+3 稀疏文件回归确认逐块读取临时对象累积：重复 RED 的 RSS 增量约 137.7/204.1 MB；逐块 autoreleasepool 后 GREEN 为约 1.7 MB/64 KiB。该修改调整磁盘扫描临时对象释放，不改变二进制补丁算法、块比较或恢复资格。发布与反向恢复循环仍在单独复核。原始证据保存在 `evidence/2026-10-13-task8/acceptance/capture-memory/`；合成回归不证明真实磁盘发布、启动或提交后回退通过。

补充：发布及反向恢复循环亦以真实 helper、安全 16 MiB+3 全差异磁盘复现，RED RSS 增量分别 42,106,880 与 59,129,856 字节；逐轮释放后均为 196,608 字节。四条循环采用同一生命周期修正；写前 pending 日志、写入/fsync、afterWrite、游标保存及最终 SHA 校验顺序保持。独立源码审查无阻断发现，第六版签名工件正在准备，真实验收结果另行记录。

### 2026-10-14 Task 8：候选 payload 效果索引

第六版正式更新完成磁盘变更块扫描，但首次 candidate commit 读回拒绝 `kernel.apfs_root_snapshot`，发布游标 0、无 pending，未修改配置磁盘。正式恢复已退出 0。最小回归通过实际 IM4P/IMG4 API 复现：解码 payload 内容一致、Data.startIndex 非零，旧 `verifyEffect` 将相对文件偏移当作 Data 绝对索引，导致比较错误。

修正仅在通用效果检查中从 payload.startIndex 推导记录的相对偏移，保留原有 count 边界及字节相等检查，未改变内核补丁算法。12 个合法场景和 28 个非法效果拒绝场景通过。扩大定向 Swift Testing 汇总 82 项，4 个真实 fixture 入口未启用并跳过；四个隔离内存子操作均实际通过。证据见 `evidence/2026-10-13-task8/acceptance/effect-index/manifest.json`。真实候选提交、发布恢复及启动仍待新冻结工件验收。

### 2026-10-14 Task 8：第七版提交与真实启动范围

第七版正式更新退出 0，完整发布 10,159 个块并提交。journal/receipt/proof/报告及实际只读 Preboot 读回一致，原始 IM4M 保持；同一副本实际发布 5 块后的中断恢复和完整基线/身份/元数据核验通过，独立审查通过。新旧解码 kernel payload 同为 `d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb`，因此没有不同 payload 的更新或启动验收结论。

正式切回已授权第四版 host 后，VM 框架进入 running，但 guest 未连接，uname/sysctl 查询未执行成功，串口只取得 iBoot 输出；正常启动未通过，原因未查明，VM 已正式停止。只读完整容器对照确认 description 变化和原 IM4P PAYP 附加元素未保留；这不是启动根因结论，尚未据此修改算法。提交后回退入口未实现。临时 AMFI driver/debugserver 清理的精确系统暂停操作被自动审批拒绝，用户授权请求待回复；未修改 TCC 或持久 AMFI 配置。详细原始证据见 `evidence/2026-10-13-task8/acceptance/`。

### 2026-10-14 Task 8：临时 AMFI 状态收尾

用户授权一次暂停并恢复 amfid 88460 后，执行前复查确认旧 amfid、限定 driver89299 和 debugserver89316 均已退出。原驱动记录目标以内存问题终止且 detach 失败；当前新 amfid35998 由系统运行。没有执行暂停或恢复信号。本轮 VM 已停止，无临时进程、镜像挂载或 pending，未修改 TCC 或持久配置。该收尾不改变启动未通过、不同 payload 未验证及提交后回退未实现的结论。

## 2026-10-14 第八版提交与第四版启动结果

- 第八版无注入更新已正式提交，退出码 0，用时 3430.296 秒，事务 `2b52edcf-ac9b-4515-bb80-338d94bcbd2b`。`committed-readback-v8.json` 与 `v8-commit-independent-review.md/json` 验证 journal、receipt、proof、报告、实际 Preboot 和磁盘摘要关系通过；六文件 inode 保持，更新时其他五文件内容保持，无 pending 或挂载。
- 实际完整 IMG4 恢复为基线摘要 `5b90c5a0ee87bf810c7e90795d537265f39774fbf85c430263fd2f61fc41ce7a`。原 description、315 字节 PAYP 和 IM4M 保留。解码 payload 仍为 `d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb`，不能计为不同 payload 更新验收。
- 正式重绑为 host `2.6.20261016-local`、kernel `2.6.20261020-local`，receipt/proof/journal 保持。只执行已授权第四版 VM；本轮 `--help` 直接退出 0，没有启动临时 AMFI 驱动，没有扩大授权。
- 第四版 VM 实际启动通过 guest 状态验证，PID `22914`，实例 `D46D87C2-A877-4348-BA7F-A9410522C493`。guest 已连接，使用实际绝对路径执行 `uname`/`sysctl`，返回 `Darwin 25.1.0`、`iPhone17,3`，code=0，无超时或截断。证据为 `boot-v8-guest-state-absolute.json`；实际 argv 与绑定摘要见 `boot-v8-guest-command-discovery-retry.json`。
- 原 `boot-watch-v4-kernel-v8.json` 保留 passed=false：guest 已连接，但默认 PATH 不包含 `/var/jb/usr/bin` 和 `/var/jb/usr/sbin`，探针的两个命令返回 127。绝对路径查询补充成功，不覆盖原失败结果。description 和 PAYP 同时恢复；本次启动通过不能单独确定 PAYP 是前次启动异常的原因。
- 正式停止退出 0，用时 4.675 秒，日志记录 guest 优雅关机。`post-boot-v8-cleanup-v2.json` 验证无本轮 VM/临时驱动、无挂载或 pending，binding/receipt 保持；源 VM 六文件 device/inode/size/mtime/ctime 保持。未重新计算源 VM 全量内容摘要。第一次清理探针因裸历史 PID 已复用而误判，失败记录保留；v2 按实际命令身份核对，未向该进程发送信号。
- 暂停事务恢复及读回已通过，见 `kernel-update-v8-pause-recovery-readback.json`、`v8-pause-recovery-independent-review.md/json`。暂停时游标 0，不能作为写入后恢复证据；此前第七版实际发布 5 块后的中断恢复证据保持。
- 提交后 kernel-only 回退现已开始实施及回归。候选基于当前启动后的磁盘，只替换内核；目标须重新取得真实 producer 资格。初版限定同可信 producer、同 generation/catalog/版本上下文的不同内核计划，保留当前 desired 和非内核来源。旧第八版缺少 producer-only 实际产物协议，不能仅凭历史 JSON 或备份取得回退资格。
- Task 8/T34 尚未完整验收：不同 payload 更新与启动、提交后的公开回退及 guest marker 保留仍待完成。保留所有未提交修改，未提交 Git。

## 2026-10-14 不同内核计划与实际 DSC 校验

实际纯文件 EXP producer 对同一原始 IM4P（`b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac`）执行两组公开计划，完整 kernel Gate 与 ordered records 重建等于实际 payload。测试副本的实际 System 卷在目录锁内只读挂载；两组产物均通过现有生产 DSC 校验器。第二轮测试退出 0，用时 97.670 秒；该时间包含 16.07 秒构建。证据为 `acceptance/kernel-rollback/actual-plan-pair-dsc-v2.json`、对应 log 及 mount.json。

| 实验设置 | 计划 SHA-256 | payload SHA-256 | IM4P SHA-256 | 记录数 | DSC 结果 |
| --- | --- | --- | --- | --- | --- |
| EXP，forceExcGuard=false | `703f9ad46613fa819ec6460846865ba9cd3ccd389f4b03c078fbc9baae741a3c` | `d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb` | `b1f07780484d9dc88f989d6e236049050b38e50a1ddb94030dcecaed43f962db` | 119 | 通过 |
| EXP，forceExcGuard=true | `bb37c956b2bce344b65c6ca3fdea77065d9713f539f4a761823c2c8e5369e96c` | `a89e2e786dc61d93b14ea129072bc762594ca4cd1f54719810ea1cbf99c0e2c0` | `ecbea551116fbb2d10b0196d72ecd7f52f8f145b5ecd7632159c0025fb78bf98` | 120 | 通过 |

两组共享区域 base/size 均为 `6442450944` 字节。payload 摘要确实不同，未人工修改内核字节。这里建立实际生产算法、记录重建、区域与 DSC 兼容性证据；尚未通过第九版可信 Store 的正式更新提交，也未进行这两组内核的实际 A/B/回退启动。

首次 pair 因测试 gateSnapshot 的 guestEnvironmentV2=nil 与实际 false 不同而在补丁前拒绝；仅修测试参数，生产检查保持。首次挂载 DSC 重跑因路径拒绝而失败；挂载存活时的独立 Foundation 诊断确认 `/private/tmp/...` 标准化为 `/tmp/...`。仅规范化 fixture URL，未放宽生产 relative 检查。失败 log/mount.json 及 `dsc-path-diagnostic.json` 保留。两次只读 DSC 挂载和路径诊断均完成卸载，最终无 Task8 附件或 pending，Disk.img 的 device/inode/size/mtime/ctime 保持；该观察不包含新全盘内容摘要。

## 2026-10-14 提交后回退实现与独立代码审查

新增公开 `vm rollback-kernel NAME --list`、`--to-transaction UUID --preview` 和明确目标的发布入口。初版限定同一可信 producer 的版本与实际 executable SHA、同一 VM/generation/catalog/固件上下文及非内核选择。新 schema 4 单独记录 targetDesired 和 live desired/binding CAS；current desired 保持，候选来自回退开始时的当前磁盘。新正常更新与回退保存完整 installed-kernel.im4p；历史数据仅提供选择与预期摘要，发布重新运行活跃 Store → VM → worker 作用域中的真实 producer。旧第八版与跨 Bundle 回退明确拒绝。当前 IMG4 的 IM4M/IM4R 外围原字节在 candidate/published callback 重验；该检查只建立字节保留。

源码与测试共 16 项已冻结，`acceptance/kernel-rollback/manifest.json` 逐项摘要核对通过，独立代码/需求审查无阻断，见 `code-independent-review.md/json`。最终 Swift 定向汇总 101 个测试函数、13 个 suite：98 个通过，3 个实际 fixture 入口跳过；这些 fixture 的实际结果单独保存。新回退 suite 的 9 个通过函数覆盖 34 个参数场景及非参数场景。Python Bundle 协议 7 项通过。初次无效编译 RED、有效路由 RED、实际 fixture 参数/路径失败均保留。

第九版 `2.6.20261021-local` 的完整构建、签名与打包正在进行，之前八版工件保持。此时尚未正式安装第九版、执行新事务或进行 A/B/回退启动，不能将代码审查与纯文件测试写成真实回退通过。

## 2026-10-14 第九版 B 提交、启动及回退准备

B 事务 `2901d975-2379-4b50-9340-8580786aacc1` 正式更新退出 0、3389.396 秒，独立实际读回退出 0、110.513 秒。实际 payload `a89e2e786dc61d93b14ea129072bc762594ca4cd1f54719810ea1cbf99c0e2c0` 与 A 的 `d2b90150…` 不同；原 description、PAYP、IM4M 和 envelope 保持。六文件身份及其他五文件内容保持，独立提交审查通过。

B 首次 guest 观察 361.804 秒超时，无 VM target/socket，原失败保留。采样定位宿主 preflight 等待；原固定驱动虽记录 Detach(False)/CLEANUP_DONE，同 amfid95240 实际仍为 SSTOP4/xstatus17、非 traced。严格核对同 PID/path/UID/PPID/start 后仅发 SIGCONT，状态恢复运行，原正式 launch 继续，第四版 guest 系统查询通过。detach 后仍停止原因未查明。补充观察使用新标签 `kernel-v9-plan-b-resumed`，原/新 boot expectations 原始摘要一致；0.355 秒仅为补充观察时间，不是完整启动耗时。742 字节唯一 guest 标记实际创建及 file_get 读回通过，正式停止、清理和独立启动审查通过。

公开回退列表及预览允许明确选择 A 事务 `c0a0a7a8-3677-4a44-aa36-f370bb67b5ca`，旧第八版因缺少回退协议证据拒绝。当前 B 启动及标记后的六文件摘要已冻结，Disk.img 与 B 离线提交摘要不同。正式 `vm rollback-kernel --to-transaction` 正在执行，current desired B 保持；尚未确认回退提交、第三次启动或标记保留。性能[只读分析](evidence/2026-10-13-task8/acceptance/kernel-rollback/performance-analysis.md)已保存；未修改冻结 V9 以降低校验。


### 2026-10-14 回退 A 与独立性能工作覆盖状态

第九版公开回退 A 正式提交退出 0（4370.196 秒），独立实际读回（115.825 秒）及第四版 guest 启动通过；目标 A kernel 的 IMG4/IM4P/payload/119 条记录匹配，live desired B 保持。原 tmp 标记回退后 file_get 返回 ENOENT，数据保留验收未通过，原因未查明。新 Documents 标记已显式 sync 并同实例实际读回，正式停止及清理通过；停机落盘和跨回退保持仍待验证。旧失败证据保留。amfid 残留停止问题单独跟踪，回退 A 后实测已运行且未发送恢复信号。

用户授权独立优化工件先增加分项计时，再验证 capture/validate 的约 1 MiB 读取等价性和收益。冻结 V9、原 Task 8 工件及 AMFI 范围保持，不热替换、不在验收磁盘运行竞争性基准。SHA 合并、摘要/比较融合和 metadata 重验跳过均后置单独设计审查，不预先认定语义等价。见 `research/evidence/2026-10-14-kernel-io-performance/execution.md`。保留现有未提交修改，未提交 Git。

### 2026-10-14 独立 I/O 优化验证结果

仅在独立副本增加 opt-in 分项计时并将 capture/validate 底层读取改为 1 MiB，内存仍按 4096 字节比较。持久块、发布/恢复/写入/sync 代码段保持；没有新增内核指令补丁。尾部增长回归实际 RED 后补齐 EOF 检查；10 项读取、7 项差异/恢复、9 项计时器和 4 个内存子操作通过。更新/回退定向测试实际通过 18 项，真实 fixture 跳过 2 项。

三版本 24 次独立合成调用全部通过，预热 6 次排除。512 MiB+3 字节、暖缓存、三次计入测量中，完整 capture 中位数 1.908→1.661 秒（减少 12.9%）、validate 1.369→0.722 秒（减少 47.3%），相对未计时基线。范围不覆盖完整 64 GiB 发布或真实 VM，不外推全程加速与 SHA 占比。见 [performance-results.md](evidence/2026-10-14-kernel-io-performance/performance-results.md)。冻结 V9 未替换；Task 8 的旧数据标记失败和 amfid 停止继续分别记录，原因未查明。


### 2026-10-14 Documents 停机重启及跨回退验收结果

新 Documents 标记的两项持久性检查均通过：同 A 内核正式停机重启后读取原标记；再通过冻结 V9 的公开 `rollback-kernel` 回退到历史 B 并由第四版 VM 启动后读取原标记。两次实际内容均与原创建的 1254 字节一致，SHA-256 `a8faa4e5b805fd5a0ee0f8330296d168bb85f33c674748595d176df3714e418e`；未重新创建标记。

新回退事务 `0d6d197a-8b24-4944-bb38-16a60ed24fb0` 正式提交退出 0（4283.968 秒），schema 4、49/49 块、pending=false；目标历史 B 为 `2901d975-2379-4b50-9340-8580786aacc1`。独立实际 Preboot 读回退出 0（108.183 秒），B 的 IMG4/IM4P/payload、120 条记录、原 description/PAYP/IM4M/envelope 保持。live desired B 保持。第四版 guest 系统查询、正式优雅停机及清理通过。完整保存证据关联校验 `task8-final-documents-persistence.json` 通过；冻结 V9 的 16 源文件和已安装 CLI、第四版 CLI/VM 摘要保持。

旧 tmp 标记 ENOENT 失败记录和摘要保留，原因未查明。新结果仅建立这个 Documents 标记的持久性，不证明全部用户文件内容一致。旧失败汇总工具未改写或提升为通过。第一次 B 启动观察的证据文件权限失败、所有者修正及停机短标签的逐字节归档说明均保留。amfid 停止问题单独跟踪，原因未查明；本轮两次 preflight 均为 0，未运行临时驱动或发送 amfid 信号。AMFI 授权范围保持，优化不合入，保留现有未提交修改，未提交 Git，未推进 Task 9/10。

详见 `research/evidence/2026-10-13-task8/acceptance/documents-persistence.md` 及同目录 `amfid-stop-tracking.md`。前述历史待完成和失败状态保留为当时证据。


### 2026-10-14 已验证 I/O 优化合入源码

按用户本轮授权，将独立工件的 opt-in 分项计时和 capture/validate 约 1 MiB 读取合入当前源码。16 个非 Package 文件逐字节匹配已验证工件，完整生产 Package 仅新增计时 target/依赖；内存仍逐 4 KiB 比较，短读/EINTR/EOF、pending、外部修改拒绝、内存及恢复回归通过。原 SHA 次数、资格校验、4 KiB 持久块和同步顺序保持。没有新增内核指令补丁。

相关合成回归：XCTest 28 通过/3 跳过，Swift Testing 主组128通过/2真实fixture跳过，补充封装/DSC/效果/读回组7通过/2真实fixture跳过；4内存子操作实际通过。Python Bundle协议7项、trace分析器10项通过。合入二进制显式计时重复4个测试通过，两份trace共13962事件完整；6次capture各5SHA、17次validate各2SHA。未重新测性能，不推算完整64GiB发布或52次SHA耗时占比。

冻结V9归档/候选/安装产物、第四版CLI/VM及266份旧证据摘要保持，原证据树1181项元数据保持。原V9的16份源码另存精确快照；本轮只修改当前源码，不重建/安装/热替换冻结产物，不操作VM或AMFI。863个其他既有源码/测试摘要保持，现有未提交修改保留。其他优化继续后置，旧tmp标记失败和amfid停止原因仍未查明。独立审查及具体回归见 `research/evidence/2026-10-14-kernel-io-integration/README.md`。未提交Git。

### 2026-10-14 内核 I/O 第二、三项优化

第二项局部合并 kernelUpdate 候选摘要比较与 kernelMount 挂载前 SHA，published 单次整盘 SHA 由 5 次降至 4 次，candidate 回调由 3 次降至 2 次。保留事务入口、尾部、来源、计划、report、binding 及 metadata 循环校验。没有实现 published 5→2；任意并发修改后恢复的所有时间窗口与旧实现等价，尚未证明。

第三项将 capture 的两份备份 SHA 与 4 KiB 差异比较融合为同步后的 1 MiB 双流扫描。仍计算 5 次完整 SHA，显式逻辑读取由 7 倍镜像长度降至 5 倍，不含复制内部 I/O。源文件初始 SHA、扫描后的 live disk SHA、文件类型/单链接/路径关联/长度/时间检查保持；比较扫描移至同步后。发布、反向恢复、写块及同步实现保持。没有新增内核指令补丁。

最终定向 XCTest 35 项实际通过、1 项内存子进程入口跳过，4 个内存子操作通过；Swift Testing 28 项实际通过、2 项真实 fixture 跳过。补充事务/来源/generation/receipt 回归 63 项通过；新增 7 项 XCTest 在最终版本再次通过。detach 后来源复核期间的未知磁盘修改被事务尾部 SHA 拒绝，恢复拒绝覆盖该字节。动态 trace 核对 6 次 candidate 各 2 次 SHA、18 次 published 各 4 次 SHA；16 MiB+3 字节 capture 的 3 次独立 SHA、2 次融合 SHA 和 5 倍逻辑读取通过。未执行对照性能基准，不推算完整发布加速。

266 个冻结证据文件和 3 个已安装可执行文件摘要保持。仅修改工作区源码及测试，未提交或安装，未操作 VM、真实挂载或 AMFI。具体范围、失败记录、实际回归与计数见 [第二、三项结果](evidence/2026-10-14-kernel-io-fusion/results.md)。metadata 重验删减和 generation 验证复用仍未实施。

### 2026-10-14 第二、三项隔离对照性能基准

四份相同参数 release 产物分别为保留第 1 项的基线、仅第 2 项、仅第 3 项和组合版。使用完整写入的 512 MiB+3 字节暖缓存合成文件，新 XCTest 进程按四轮平衡顺序执行；40 次调用全部退出 0，8 次预热排除、32 次计入。此前 8 次小输入校验通过，5 项测量协议拒绝回归通过。四版只在 KernelDisk、KernelMount、KernelUpdate 三个生产文件按预定因素变化；工作区生产算法保持。

仅第 2 项的 6 次 published 校验累计中位数 8.002→6.482 秒（减少 19.0%），2 次 candidate 累计 1.625→1.103 秒（减少 32.1%）；此项仍为 published 5→4、candidate 3→2 的局部合并。仅第 3 项完整 capture 中位数 1.683→1.439 秒（减少 14.5%），SHA 计算仍为 5 次，显式逻辑读取由 7 倍降至 5 倍。其一次 1.832 秒测量保留，原因未查明。

组合版合成 publish helper 中位数 14.504→12.576 秒（减少 13.3%），略高于仅第二项版本的 12.526 秒。各比例对应不同范围，不能相加；未建立叠加收益结论。合成发布使用实际 publish/verifyOrigin 和模拟 producer/卷工具，模拟挂载仅读首个 4 KiB。prepare、文件生成和最终独立 SHA 读回在计时范围外。所有输入/输出摘要、块偏移、metadata、SHA 次数/字节、同步顺序和 trace 完整性通过动态核对；自动复核重新计算四轮统计，通过。结果不表示完整更新、真实 VM 或 64 GiB 镜像的加速比例。

266 个冻结证据文件、3 个已安装可执行文件和 16 个冻结 V9 源码快照摘要保持；文档更新前 1134 个既有源码/测试/脚本/文档摘要保持。未操作 VM、真实挂载、AMFI 或验收镜像，未安装或提交。全部范围、最小值/最大值、原始记录及源码/产物摘要见[隔离对照结果](evidence/2026-10-14-kernel-io-factorial/performance-results.md)。


## 2026-10-15：8a75092 声明与 IcliKit 适配

固定上游目标为 `8a75092013eda87a4e30ed029b72028cb9279ac4`。声明从 141 项变为 148 项：140 个原 ID 的声明元数据不变，ProMotion 发布 ID 更名，新增 7 项。保留 140 项本地 declaration/五模式适用性和 11 项 local-only；新增能力仍为 notImplemented，不据上游预设扩大执行范围。

`kernel-exp-display_refresh_120hz` 映射到 `kernel-cfw-display_promotion`，显式开关意图保留，重复/矛盾 alias 拒绝。本地 ProMotion 默认关闭，当前没有授权该声明执行的实现。当前目标绑定使用 catalog 唯一目标；旧目标日志只在通过原内容与身份核验后用于恢复，不取得新执行资格。

IcliKit 固定到 `0.8.5 / 815ef234df5461b8eb9455931d38cb1c37992fe6`，原 B22 JPEG 独立 bitmap 复制 overlay 重新绑定并校验源/补丁摘要。Release iOS 候选构建、签名、架构、部署目标、依赖与权限校验通过，未安装或激活。没有新增 kernel、DSC 或 Mach-O 指令补丁，没有执行固件比较或 VM 验收；同 ID 的上游实现变化仍需后续单独审查。

详细来源、适用性、默认值、相关验证与保留的全量失败记录见 [T08/T09 本轮记录](upstream_integration_2026-10-15/T08_T09_adaptation.md)。


## 2026-10-15：T59 设备状态按订阅轮询

固定上游目标保持 `8a75092013eda87a4e30ed029b72028cb9279ac4`，适配 `afc62ef0` 的事件订阅调度。无订阅时停用设备状态定时器，订阅恢复时立即查询并保持原 3 秒周期；补充快速重连的首次状态、回调乱序和释放处理。没有新增 kernel、DSC 或 Mach-O 指令补丁，既有补丁算法与模式选择未改变。

旧调度与缺少快速重连重置的临时对照分别被回归捕获；修改后生产源码的 Swift 6 调度夹具、独立 iOS Release 构建及两类签名候选校验通过。候选未部署，CPU/wakeups、实际重连和客户机功能未验收。标准 Swift 保留既有内核幂等测试失败（实际 2 条记录、断言 1 条）；没有改写该断言。分支合并、停止夹具、运行器修正、完整验证结果与原始失败见 [T59 记录](upstream_integration_2026-10-15/T59_event_polling.md)及其证据清单。


## 2026-10-15：T37 SIGTERM 与主 VM 窗口关闭

固定上游目标保持 `8a75092013eda87a4e30ed029b72028cb9279ac4`。本轮将 VM 运行进程的 SIGTERM 和主窗口关闭接入原有关机入口，保留 guest 写入等待、关机请求、超时及 force-stop 策略。主窗口保持到应用完成停止，不再依赖辅助窗口数量。没有新增 firmware/kernel/DSC/Mach-O 补丁或 entitlement，补丁算法和选择保持。

原生子进程的 SIGTERM 缺回调，以及主窗口 delegate 未发停止请求均已保存失败；修改后回归执行实际 AppDelegate 写入等待，并验证原信号处理器恢复。只执行宿主编译和测试，不构建/部署完整签名 App 或操作真实 VM。完整停止、磁盘释放和启动中竞态仍未验收，见 [T37 记录](upstream_integration_2026-10-15/T37_exit_routing.md)及其证据清单。


## 2026-10-15：guest DSC 后缀撤销与事务证据

新增实际 staged DSC 签名快照恢复、完整代码页核验、分组件效果 Receipt 及 guest 来源 unknown 的共同 journal 发布与恢复。未新增 firmware/kernel 补丁算法，IOMFB 生产门控保持。验证使用隔离文件系统与挂载替身；真实固件和 VM 行为尚未验收。范围、恢复边界及命令见 [专项记录](upstream_integration_2026-10-15/T32_T33_guest_undo_publication.md)。

2026-10-16 补充：CFW 交换的 generation 关联现通过已提交 v3 journal 和保留磁盘验证身份连续性；实际 Swift 验证器覆盖两次安装及 DSC 撤销。最终 Python 886 项（跳过 2 项）和完整 Swift 入口通过，宿主检查不构成真实固件或 VM 验收。

2026-10-16 vm-new 补充：已完成旧 VM 缺 generation/Undo 时拒绝和两次现有 iOS 26.1/23B85 启动及正常关机，禁用 daemon 更新。正向 DSC 撤销和重新安装仍未验收，不能以本轮启动结果推进补丁接受状态。见 [vm-new 验收记录](upstream_integration_2026-10-15/T32_T33_vm_new_acceptance.md)。


## 2026-10-18：新 VM 的 iBEC bootx 版本条件

原始 iOS/cloudOS 26.1 23B85 新 VM 准备成功；固件提交前因 bootx 声明缺成功记录而拒绝。该步骤此前 optional，声明表却为所有版本 required。现将两者统一为 cloudOS 26.4 及以后必需，独立于 Frida opt-in，保留缺少匹配、匹配不唯一及提交前证据拒绝。指令查找和替换算法保持。定向回归已捕获原问题并通过修复验证；完整测试与实际重试状态见 [新 VM 验收记录](upstream_integration_2026-10-15/T32_T33_new_vm_20261018.md)。用户明确批准当前 CDHash 的 amfidont 放行后，冻结程序已能执行；新 VM 固件事务提交和真实恢复均成功。CFW 当前等待系统管理员验证，guest 撤销和正常启动尚未验收。


### 2026-10-18：CFW 挂载写状态字段兼容性

新实例真实系统恢复后，首次 CFW 在 Cryptex 原始 DSC 基线检查失败，未交换 Disk.img。只读重新挂载的实际 diskutil plist 包含 `WritableVolume: false`，没有 `ReadOnlyVolume`；旧 Python 检查将缺字段当作未证明只读。现与 Swift 既有语义一致，支持两个明确的 volume 字段；缺失、非布尔或矛盾的字段仍拒绝，media/generic 字段不能代替 volume 观察。Cryptex 基线、最终 staged 只读核验和 Undo 可写预检共用此解释。挂载点、设备、来源、代码页及 journal 核验保持。相关 87 项通过；完整测试和真实重试结果见 [新 VM 记录](upstream_integration_2026-10-15/T32_T33_new_vm_20261018.md)。未改动固件或 DSC 指令算法。


2026-10-18 DSC 原始源补充：独立 iOS 26.0 23A341 + cloudOS 26.1 23B85、regular/classic 原始源只读诊断中，既有 SwapEnd 补丁定位载荷大小 `0x548`，目标为 `0x560`；对应 DSC 文件 6885 个代码页通过完整校验。源镜像及 DSC 摘要保持，挂载正常卸载。此项不证明安装、撤销或启动；无指令算法变更。volume 字段修复的完整 Python 892 项（跳过 2 项）和完整签名构建通过，真实 CFW 重试等待系统管理员验证。证据见 `upstream_integration_2026-10-15/evidence/T32-T33-new-vm-20261018/volume-state-fix/manifest.json`。

独立 26.0 DSC 实例后续固件事务已提交（7 组、58 条记录）；真实 SHSH 和 restore 均退出 0，DFU 进程退出并释放磁盘。尚未安装 CFW、执行 DSC 撤销或正常启动，不据此推进补丁接受状态。


2026-10-18 CFW 只读来源硬链接补充：真实 Cryptex 中稳定的 `CodeResources`（2467 字节、38 个硬链接）被复制前快照误拒绝。现仅对绑定来源启用由内核只读标志前后核对的读取；默认目标、镜像与 blob 的单链接限制保持。最终相关 147 项、完整 Python 900 项（跳过 2 项）、真实 2933 条目源树及签名/冻结核验通过；第三次真实安装正在执行。没有新增 DSC/内核指令修改；详细范围与证据见 `upstream_integration_2026-10-15/T32_T33_cryptex_source_hardlinks.md`。


2026-10-19 最终 APFS 核验补充：第三次 CFW 在首次 verify-final 拒绝，未交换磁盘。实际 APFS 清单不提供 MountPoint；修复改用卷和路径查询，核对同一设备、准确挂载路径及读写状态，保留覆盖挂载和矛盾状态拒绝。隔离原生可写→只读重新挂载、相关 58 项及完整签名构建通过；完整 Python 仍在运行，真实发布/启动/撤销尚未通过。未改变固件或 DSC 指令算法，接受计数保持。详见新 VM 记录的 2026-10-19 小节。

最终 Python 标准入口 906 项（跳过 2 项）通过，退出 0；首轮测试替身遗漏路径查询的失败与修正均已保存，原断言保持。签名资源与源码摘要一致，真实 CFW 重试仍待原生管理员验证。


2026-10-19 签名前复制属性补充：第四次 CFW 已通过实际最终 APFS 挂载检查；首次效果核验误将临时复制 GID 20 当作必须保留的属性，拒绝最终文件 GID 0。修复仅使签名前 copy 属性语义与主核验一致，显式 chmod/chown 约束保持。两个新增回归及三个真实保存签名链、全部 25 份保存操作链重放通过，签名构建通过，完整 Python 仍在运行。未改变固件或 DSC 指令算法；尚未发布磁盘或推进接受计数。

签名复制属性修复的最终完整 Python 908 项（跳过 2 项）通过，退出 0；四个相关签名资源摘要与源码一致，旧 VM 指定文件检查保持。第五次实际安装仍待原生管理员验证。


2026-10-19 后续结果：r2 第五次 CFW 已发布，事务 `20261019T013451Z-H0YWJ2mL`；正式 create 退出 0，首次及验证提示符启动通过。额外当前 classic API 的两次正常关机回归通过：启动时间和会话 UUID 不同，均收到 Guest stopped，磁盘/目录锁释放，配置与 daemon 摘要保持。运行后 v3 receipts/verify-plan 拒绝；整盘 SHA/mtime 变化，而封存检查点、5 文件、297 blob、配置及 generation 核对通过。正在实现新 v4 的独立发布后镜像和运行身份连续性，不改写历史 v3 journal，不授予当前效果或来源权限。独立 DSC 安装/撤销仍待验证，T32/T33 未 accepted。证据：`evidence/T32-T33-new-vm-20261018/runtime-boundary-20261019/manifest.json`。


2026-10-19 当前状态：r2 第五次 CFW 已发布、create 退出 0、两次提示符启动及额外两次 API 正常启动/关机通过。已实现 v4 独立发布后镜像、运行身份连续性及读取期间稳定性检查，旧 v3 严格拒绝条件保持。最终 Python 全量 919 项（跳过 2 项）退出 0，相关 Swift 12 个测试函数及实际签名 release verifier 回归、完整签名构建、六脚本资源摘要核对通过。DSC VM 正式安装命令已启动，等待原生管理员验证，尚无磁盘事务；最终 CDHash 89b70a253cad2adea133b3e875519afaf72c5d17 的补充批准尚待回复。实际 DSC 撤销未执行，T32/T33 未 accepted。 证据：`evidence/T32-T33-new-vm-20261018/runtime-v4-20261019/manifest.json`。运行证据边界与格式说明见 `T32_T33_runtime_publication_v4.md`。本阶段未更改新的固件指令匹配或替换算法。


2026-10-19 当前状态：合并已完成，r2 第五次 CFW 发布、提示符启动及额外两次 API 正常关机通过；v4 独立发布副本与运行后历史证据已实现。独立 DSC 首次 CFW 在后续 producer 枚举 .33.dylddata 时拒绝，原磁盘身份及 66 段采样保持，未交换。已完成只读来源检查和输入保留修复；完整 Python 922 项（跳过 2 项）、相关 Swift 12 个测试函数及实际 release verifier 通过。资源更新、依赖、签名和 entitlement 核验通过，VM CDHash 保持获批 89b70a253cad2adea133b3e875519afaf72c5d17。重试 session82810 等待原生管理员验证。用户已要求提交并 push；真实 DSC 发布、撤销及后续启动仍待验收，T32/T33 未 accepted。

修复前最小 producer→最终核验回归复现 `undeclared DSC write member`。真实只读检查记录 3 个普通伴随文件，包含执行权限映射，因此不将它们归为纯不可执行数据。现有写入目标规则及 catalog 保持；仅按精确编号名称将其作为输入，并在补丁前后核对完整字节、身份、属性和集合。任何变更仍拒绝发布。新增正向及五类变更拒绝、符号链接拒绝回归通过。一次相关套件运行被沙箱 EPERM 阻止，未弱化断言；标准宿主全量 922 项通过。

已批准最终 CDHash 的现有 amfidont 仅加载该值；不加载或修改持久允许列表。`--help` 实际返回 0 且无输出；提供必需 --config 后，当前与保留程序均按预期拒绝非法选项、退出 64，确认进入参数解析。可选的 root 私有日志读取请求已取消，没有干预正式安装。证据：`evidence/T32-T33-new-vm-20261018/dylddata-20261019/manifest.json`。


## 2026-10-19：DSC 完整伴随输入清单

2026-10-19 当前状态：b00e1d3c 已提交并 push。独立 DSC 第二次 CFW 在 .34.dyldreadonly 枚举处拒绝，原磁盘身份/mtime 与 66 段采样保持，未交换。完整只读清单确认 80 个成员及 10 个伴随输入。精确输入保持修复、实际隔离副本补丁与 6885 代码页验证通过；完整 Python 931 项（跳过 2 项）、相关 Swift 12 个测试函数及实际 release verifier 通过。签名资源/依赖/entitlement 核验通过，VM 字节及获批 CDHash 保持。第三次安装 session69696 等待原生管理员验证 PID39449；放行进程恢复等待 PID22867。真实发布、撤销与正常启动仍未验收，T32/T33 未 accepted。

最小 producer 回归在约 1 秒内复现第二次安装的同名拒绝。只读原始 Cryptex 包含 dylddata、dyldreadonly、dyldlinkedit 和 atlas；编号伴随文件包含执行权限的头部映射，未将其归类为纯不可执行数据。修复仅按精确名称保存输入前后完整摘要、身份、属性和集合，现有写入目标映射与 catalog 保持；任何变化仍拒绝发布。真实来源的 80 成员隔离副本中，仅 .42 发生 SwapEnd 0x548→0x560 与相应代码页摘要变化，全部 6885 代码页通过，10 个伴随输入保持。源缓存完整摘要前后相同。该隔离回放没有写入 VM，不构成实际发布或启动验收。

新增三类后缀的正向、五类变化拒绝、符号链接提前拒绝回归；完整 Python 931 项，跳过 2 项，242.969 秒，退出 0。实际签名 release verifier 的 12 个 Swift 测试函数通过，含 8 类身份/篡改参数及全部伴随类型。更新已完整构建应用的 Python 资源，先恢复外层签名，再记录依赖并最终封签；完整 bundle 校验通过，VM 二进制和已获批 CDHash 保持。证据：`evidence/T32-T33-new-vm-20261018/dsc-companions-20261019/manifest.json`。


## 2026-10-19：独立 DSC v4 发布与真实启动

2026-10-19 当前状态：83d4e69d 已提交并 push。独立 DSC 第三次 CFW 退出0，v4事务20261019T065441Z-XzJThk9M完成两次最终核验、快照、封存、交换及归档。未启动磁盘原件/补丁各6885代码页通过，w3从0x548改为0x560。首次启动与两次API正常启动/关机通过，读回26.0/23A341；运行后Receipt及generation verifier通过，当前镜像与发布镜像摘要分开，runtimeValidated:false。获批CDHash放行已生效。实际Undo的原生验证已完成，root73597/session58124开始；撤销、撤销后启动及重新应用的on→off→on仍待验收，T32/T33未accepted。

安装后持锁核对真实journal、独立发布副本和原始来源诊断：.42原件SHA为`e41db9aa09ab60cb6015282c9230fba89a8971129fae00c16156b29b1855c9b5`，补丁件SHA为`2fc23949b0ee8f17d01af28d83e814ee96aabc4918f46537f890843233a113ac`；Capstone语义读回w3 0x548→0x560，原件及补丁件各6885个CodeDirectory代码页通过。首次启动前当前整盘与发布摘要`ff453e298a2be2109b020f92e08f9f931f65f30a51efcbf347fa2b1f2762d10d`相同。

生产首次启动7条命令、提示符及正常关机通过。之后两次API启动读回26.0/23A341，启动时间和会话UUID不同，均记录apiAccepted、Guest stopped、退出0，无框架强制停止，磁盘/目录锁释放，配置/daemon摘要保持。真实运行后生产Receipt返回committed-publication，currentImageSHA256为`5948a0329f9ad0a469ce9c6ac851cbf90b18a41399e5b03eed6bb58e84c3184d`，runtimeImageChanged:true、runtimeValidated:false；实际Swift generation verifier也退出0。此结果证明已记录的启动和历史读取，不证明当前全部效果或显示行为。

此前放行worker附加失败后退出；之后只读观察到amfid出现及再次退出，原调用未保存LLDB错误细节，原因未完全确认。对同一获批程序执行有时限的非法参数探测后，目标62017持续存在；用户完成重试验证后，现有helper68388附加，精确CDHash放行及参数64通过。未加载或修改持久允许列表。实际Undo现由新staged事务执行，尚未登记成功。证据：`evidence/T32-T33-new-vm-20261018/dsc-publication-20261019/manifest.json`。


## 2026-10-19：Undo可写APFS分配统计

2026-10-19 当前状态：aef7f99c已push，独立DSC安装、原件/补丁各6885代码页、首次启动、两次API正常关机及运行后v4读取均通过。首次Undo在staged恢复后因整份可写APFS容器比较而拒绝，未发布；原盘身份/mtime与66样本保持。最小事务与原生隔离APFS确认容量统计变化足以触发同一错误。已仅在可写Undo比较中排除CapacityFree和卷CapacityInUse；其余容器字段、UUID、设备/路径/root身份及最终只读严格比较保持。相关27项、完整Python935项（跳过2项）及实际release verifier的Swift12函数通过，签名/依赖核验通过。修复后Undo已发起，状态见证据清单；真实重试、撤销后启动及重新应用on→off→on仍待验收，T32/T33未accepted。

真实事务`20261019T074108Z-8MSU4jQD`保留了guest-undo-applied：staged .42从2fc23949...写回原件e41db9aa...，实际写回及完整代码页检查已执行；随后第二次check_mount拒绝，未封存或交换。原盘保持检查仅覆盖身份/mtime及66样本，未在失败清理阶段重算整盘摘要。失败staged已按安装器流程移除，journal、请求、实际写入记录和blob保留。

最小事务回归2.496秒复现相同写入后拒绝。全新128MiB隔离APFS写8MiB后，仅CapacityFree与卷CapacityInUse改变，根目录身份、实际设备、路径及可写状态保持，正常卸载。修复仅在可写Undo比较排除此二统计字段，其他字段仍完整比较，最终只读比较未修改。新增写入后UUID变化拒绝、只读容量变化拒绝及容器字段保持回归。真实失败未保存前后完整容器快照，原运行是否仅此触发仍由重试验证。

完整Python935项（跳过2项），244.185秒，退出0；相关27项及新签名release CLI的Swift12函数通过。资源/依赖/签名/entitlement通过。后续boot继续使用原已放行程序，字节/inode保持；先前helper退出后该程序仍返回参数64，无需新增CDHash授权，周期探测已停止。证据：`evidence/T32-T33-new-vm-20261018/undo-allocation-20261019/manifest.json`。


## 2026-10-19：运行后保留文件漂移

2026-10-19 当前状态：aeb1651e 已 push。真实 Undo 重试的实际写回、完整代码页和可写挂载复核通过；首次最终核验发现保留文件不符，事务20261019T081934Z-JTYX6fft未发布，原盘身份/mtime与66样本保持。只读检查4686个输出，无读取错误，hardware:/AA.gl内容摘要从e221f140…变为4779643e…；其余内容/类型/链接/权限位一致。自动用户挂载未保留属主视图，UID/GID不作结论；正常卸载、镜像身份保持。未放宽生产校验。相关31项回归通过；同一独立VM完整CFW重装等待原生验证，之后先撤销未启动发布，再执行启停及同generation重新应用。运行后保留AA.gl变化的撤销仍拒绝，T32/T33未accepted。

撤销写回记录为`.42`从`2fc23949b0ee8f17d01af28d83e814ee96aabc4918f46537f890843233a113ac`恢复到原件`e41db9aa09ab60cb6015282c9230fba89a8971129fae00c16156b29b1855c9b5`。实际apply-undo退出0并进入第一次verify-final，确认原失败处的写入后可写挂载复核通过。随后保留输出核验拒绝；失败staged按安装器流程清理，journal、请求、写入记录和blob保留。

只读挂载对4686个发布输出进行比较：`hardware:/AA.gl`内容摘要由`e221f140369bf7b0b540793d068f72c7d7d086357aa70c9bd0ace7e7da1c6dd0`变为`4779643ee5398bcbea5eb5056e3966bccd31aa21fbb33ee2e5e5ad0ae1b31d9a`；其他输出内容、类型、链接与权限位一致，无读取错误。自动挂载的UID/GID视图未保留真实guest属主，不能据此判断属主变化。镜像身份保持，正常卸载。该文件变化的具体时间与原因未直接观测；最终拒绝符合保留效果严格核验，未修改生产校验。

新增copy-only hardware字节或权限变化拒绝回归，相关31项2.563秒退出0。下一次完整CFW重装后先验证未启动发布，再立即Undo；此边界与此前实际运行后Undo拒绝分开记录。继续保留真实Undo发布、恢复后启停和重新应用未完成状态。证据：`evidence/T32-T33-new-vm-20261018/retained-drift-20261019/manifest.json`。


## 2026-10-19：显式Cryptex重新安装

2026-10-19 当前状态：f1739ebc已push。重装事务20261019T090232Z-27r0QIUW已发布且未启动；新验收发现已有Cryptex被跳过、SwapEnd幂等，缺新原件复制链，撤销候选正确拒绝，未执行Undo。已新增显式regular/classic --reinstall-cryptex，保持默认跳过与全部证据门。真实安装脚本隔离回归从失败转为通过；相关Python33项、全量942项（跳过2项）254.634秒、Swift参数/传递12函数及实际release verifier3函数（5写入设置、8身份变化）通过。新host应用签名、依赖、资源和entitlement通过，原boot程序字节/inode/CDHash保持。显式原件重装已发起（CLI20039/session28495），新发布核验、未启动Undo、撤销后启停及显式重新应用仍待验收，T32/T33未accepted。

重装事务整盘发布SHA为`fcae888a5b9759efab692c4adbad80226dc33c779e876aaed28733059ea0d676`，生产v4核验确认当前与发布摘要相同。安装日志记录Cryptex已存在而跳过复制，SwapEnd已0x560且重新证明代码页未改变；新Undo索引entries为空。验收脚本在撤销候选处拒绝，顺序脚本停止，未启动或执行Undo。不得把旧journal或当前已安装字节补造为此新事务的原件。

新增`cfw install --reinstall-cryptex`，仅regular/classic，解析与冻结variant核对均限制范围。host驱动在sudo重执行中保留该参数，并显式向安装器传递0/1，环境变量本身不能启用。安装器在该选项下从绑定原始固件重新执行现有缓存、只读来源捕获、Cryptex复制和语义补丁流程；所有修改先在staged磁盘执行。默认已有Cryptex跳过规则保持，dev/jb/exp、v2、Undo/environment组合拒绝。

实际regular脚本在隔离树上的最小回归0.628秒确认原跳过现象；新增选项后3项0.651秒通过。实际host驱动及既有撤销/隔离回归33项53.325秒通过；首次沙箱EPERM记录保留，原断言在宿主重跑通过。完整Python942项（跳过2项）254.634秒退出0。Swift参数/传递12函数和最终签名CLI的3个verifier函数（5写入设置、8身份变化）通过。新host应用完整封签与7个原生依赖检查通过，原VM启动程序字节/inode与获批CDHash保持。

下一次基线和最终重新应用均明确使用新选项，避免再次只得到幂等记录。先保存新事务installed证明，再执行未启动Undo；随后验证原件/6885代码页、两次API启停与运行后读取。此前运行后AA.gl漂移拒绝仍是独立结果，不据此放宽保留效果检查。证据：`evidence/T32-T33-new-vm-20261018/cryptex-reinstall-20261019/manifest.json`。


## 2026-10-19：已有Cryptex替换与新Undo组合回归

2026-10-19 当前状态：6de04f15已push。显式Cryptex重装已获系统验证，root25634/session28495在staged .cfw_disk.vZh3Hh4C执行SystemOS缓存入口，未发布；已确认不走已有Cryptex跳过分支。新增已有补丁Cryptex整树替换→新发布→原件Undo组合回归通过，相关28项10.297秒退出0；生产代码未再修改，先前全量942项（跳过2项）结果保持，其后新增1项组合测试，未声称新全量943项已跑。顺序脚本session39110负责新发布证明及未启动Undo，session22627负责撤销后证明/API启停/读取、显式重新应用及重复验证，失败即停止。实际撤销发布和on→off→on尚待验收，T32/T33未accepted。

隔离测试使用已有producer、来源核验、整树删除/重建/复制、补丁、最终读取、journal封存和交换。先保留已有两次补丁的目标，重新挂载generation原始来源并替换已有树；新发布生成合格首个原件撤销候选，实际Undo写回原件后再次最终核验及发布通过。APFS调用使用已有隔离挂载替身，原件、效果、索引、代码页和journal代码照常运行；此结果不能替代当前真实VM验收。新增组合单项3.331秒；相关28项10.297秒退出0。

真实安装已通过原生验证，root25634运行并建立staged，当前进入SystemOS缓存入口。源发布前不启动VM。新增顺序验收脚本等待Undo成功后才读回原件及6885页、执行两次API启停和运行后读取；之后显式重新应用，再执行来源/DSC、两次启停和读取。同generation、三份不同journal、原件和补丁摘要一致才输出on/off/on通过；不修改Git、AMFI或VM启动程序，任何失败停止后续。证据：`evidence/T32-T33-new-vm-20261018/cryptex-composition-20261019/manifest.json`。
