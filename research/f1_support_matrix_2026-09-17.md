# F1 支持矩阵（2026-09-17）

生成文件，请勿手工修改；修改输入后重新生成。

## 生成命令

```sh
python3 scripts/f1_support_matrix.py research/artifacts/f1-matrix --create-status P:regular=.build/d4acc/lib/d4-acc/.create-checkpoint/checkpoint.json --manual P:regular=.build/f1/logs/d4-acc/manual/manual_results.json --create-status P:dev=.build/f1/logs/f1-261-dev/create-status.json --manual P:dev=.build/f1/logs/f1-261-dev/manual/manual_results.json --create-status P:jb=.build/f1/logs/f1-261-jb/create-status.json --manual P:jb=.build/f1/logs/f1-261-jb/manual/manual_results.json --jb-setup-log P:jb=.build/f1/logs/f1-261-jb/vphone_jb_setup.log --create-status P:exp=.build/f1/logs/f1-261-exp/create-status.json --manual P:exp=.build/f1/logs/f1-261-exp/manual/manual_results.json --jb-setup-log P:exp=.build/f1/logs/f1-261-exp/vphone_jb_setup.log --create-status P:less=.build/f1/logs/f1-261-less/create-status.json --manual P:less=.build/f1/logs/f1-261-less/manual/manual_results.json --create-status N:jb:frida=.build/f1/logs/f1-2661-jb-frida/create-status.json --manual N:jb:frida=.build/f1/logs/f1-2661-jb-frida/manual/manual_results.json --jb-setup-log N:jb:frida=.build/f1/logs/f1-2661-jb-frida/vphone_jb_setup.log --create-status N:exp:frida=.build/f1/logs/f1-2661-exp-frida/create-status.json --manual N:exp:frida=.build/f1/logs/f1-2661-exp-frida/manual/manual_results.json --jb-setup-log N:exp:frida=.build/f1/logs/f1-2661-exp-frida/vphone_jb_setup.log --limits research/f1_known_limits_2026-09-17.json --title 'F1 支持矩阵（2026-09-17）' --json-out research/f1_support_matrix_2026-09-17.json --md-out research/f1_support_matrix_2026-09-17.md
```

## 单元格来源与合并规则

- 单元格来源标注：`auto` 为 `run.json`（验收脚本输出），`checkpoint` 为创建检查点（S1–S3），`manual` 为人工结果 `manual_results.json`；`checkpoint+manual` 表示 S3 由检查点推导，JB 收尾完成标记来自人工取回的 `vphone_jb_setup.log`。
- 合并规则：`manual` 的排序高于 `auto` 与 `checkpoint`；同一排序内时间最新的记录决定状态（`run.json` 用步骤 `finished_at`，检查点用阶段 `finished_at`，人工用 `recorded_at`）。人工结果在首次设置后的 GUI 复跑之后记录，因此首次设置后的 GUI 复跑与人工结果优先于首次设置前的 headless 结果。
- `failed` 保护：若某条 `failed` 记录晚于按上述规则选中的非 `failed` 记录，状态保持 `failed`；`failed` 只会被更晚且排序不低的记录替换。
- 被替换的记录保留在 JSON 的 `candidates` 与下方备注中。人工子项（如 `S12_graphics`、`setup_assistant`、嵌套的 `bottom_edge_swipe_home_guest_path`）只写入备注，不决定单元格状态；子项 `failed` 时 `passed` 降为 `partial`。
- 检查点推导：S1 要求 prepare/patch 成功、cfw 成功或 not_applicable、整体状态不属于失败类、prepare 的 iOS/cloudOS 版本与组合定义一致，patch 记录数与历史值不一致时降为 `partial`；S2 要求 `restore_update_exit=0` 且 `post_restore_dfu_outcome=matched`；S3 要求 first_boot `prompt=matched` 且 verification `succeeded`，jb/exp 的 `jb_finalize=unverified` 需人工取回日志含完成标记，否则为 `partial`。
- `(negative)` 表示负向检查，不计为功能通过；`*` 表示记录了失败分类；`L<n>`/`O<n>` 为下文已知限制与未解决问题编号。

## 矩阵

| Combo | Device | iOS | cloudOS | Variant | Options | VM | preflight | S1 | S2 | S3 | S4 | S5 | S6 | S7 | S8 | S9 | S10 | S11 | S12 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| P | iPhone17,3 | 26.1/23B85 | 26.1/23B85 | regular | - | d4-acc | passed [auto] | passed [checkpoint] | passed [checkpoint] | passed [checkpoint] | passed [auto] | partial [manual] O2 | partial [auto] | failed * [manual] O1 | blocked [manual] L1 | partial [auto] L3 | passed (negative) [auto] | not_applicable [auto] | partial (negative) [auto] L3 |
| P | iPhone17,3 | 26.1/23B85 | 26.1/23B85 | dev | - | f1-261-dev | passed [auto] | passed [checkpoint] | passed [checkpoint] | passed [checkpoint] | passed [auto] | passed [manual] | partial [auto] | failed * [manual] O1 | passed [manual] | partial [auto] L3 | passed (negative) [auto] | not_applicable [auto] | partial (negative) [auto] L3 |
| P | iPhone17,3 | 26.1/23B85 | 26.1/23B85 | jb | - | f1-261-jb | passed [auto] | passed [checkpoint] | passed [checkpoint] | passed [checkpoint+manual] | passed [auto] | partial [manual] O2 | passed [auto] | partial [manual] | passed [manual] | partial [auto] L3 | passed (negative) [auto] | not_applicable [auto] | partial (negative) [auto] L3 |
| P | iPhone17,3 | 26.1/23B85 | 26.1/23B85 | exp | - | f1-261-exp | passed [auto] | passed [checkpoint] | passed [checkpoint] | passed [checkpoint+manual] | passed [auto] | passed [manual] | passed [auto] | partial [manual] | passed [manual] | partial [auto] L3 | partial [manual] L2 | not_applicable [auto] | partial [auto] L3 |
| P | iPhone17,3 | 26.1/23B85 | 26.1/23B85 | less | - | f1-261-less | passed [auto] | passed [checkpoint] | passed [checkpoint] | partial [checkpoint] | passed [auto] | partial [manual] O2 | partial [auto] | failed * [manual] O1 | blocked [manual] L1 | partial [auto] L3 | passed (negative) [auto] | not_applicable [auto] | partial (negative) [auto] L3 |
| N | iPhone17,3 | 26.6.1/23G82 | 26.4/23E5207q | jb | frida=True | f1-2661-jb-frida | passed [auto] | passed [checkpoint] | passed [checkpoint] | passed [checkpoint+manual] | passed [auto] | partial [manual] O2 | passed [auto] | partial [manual] | passed [manual] | partial [auto] L3 | passed (negative) [manual] | failed [manual] O3 | partial (negative) [auto] L3 |
| N | iPhone17,3 | 26.6.1/23G82 | 26.4/23E5207q | exp | frida=True | f1-2661-exp-frida | passed [auto] | passed [checkpoint] | passed [checkpoint] | passed [checkpoint+manual] | passed [auto] | passed [manual] | passed [auto] | partial [manual] | passed [manual] | partial [auto] L3 | partial [manual] L2 | failed [manual] O3 | partial [auto] L3 |
| L | iPhone17,3 | 18.6.2/22G100 | 26.1/23B85 | regular | - | - | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run |
| L | iPhone17,3 | 18.6.2/22G100 | 26.1/23B85 | dev | - | - | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run |
| L | iPhone17,3 | 18.6.2/22G100 | 26.1/23B85 | jb | - | - | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run |
| L | iPhone17,3 | 18.6.2/22G100 | 26.1/23B85 | exp | - | - | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run | not_run |

## 备注

### P:regular（d4-acc）

- run.json 工具提交：22a7c02b9334, 5fd007ce73a5
- 创建工具 vphone-cli SHA-256 636f3032b0677f2058eb1722c2dc83886db37042bb17f26db08985830d320c89
- run `f1-P-regular-20260917T130619Z` launch=headless, screen_available=False
- run `f1-P-regular-20260917T130619Z-s4verify` launch=headless, screen_available=False
- run `f1-P-regular-gui-20260917T155133Z` launch=gui, screen_available=True
- preflight `passed` [auto] 选用 `f1-P-regular-gui-20260917T155133Z`。其他记录：auto `f1-P-regular-20260917T125810Z`=passed，auto `f1-P-regular-20260917T125810Z-s4verify`=passed，auto `f1-P-regular-20260917T130619Z`=passed，auto `f1-P-regular-20260917T130619Z-s4verify`=passed
- S1 `passed` [checkpoint] 选用 `.build/d4acc/lib/d4-acc/.create-checkpoint/checkpoint.json`。说明：overall_status=succeeded（由阶段状态推导）；attempts=15；采用各阶段最终记录；prepare iOS 26.1/23B85、cloudOS 26.1/23B85 与组合 P 定义一致；patch_records=58，与历史值一致
- S2 `passed` [checkpoint] 选用 `.build/d4acc/lib/d4-acc/.create-checkpoint/checkpoint.json`。说明：restore status=succeeded, restore_update_exit=0, post_restore_dfu_outcome=matched
- S3 `passed` [checkpoint] 选用 `.build/d4acc/lib/d4-acc/.create-checkpoint/checkpoint.json`。说明：first_boot status=succeeded, prompt=matched; verification status=succeeded；子项 setup_assistant [manual] passed：note: 代理经 file_put 预先写入 en0
- S4 `passed` [auto] 选用 `f1-P-regular-20260917T130619Z-s4verify`。其他记录：auto `f1-P-regular-20260917T125810Z`=partial（boottime_recorded=blocked: shell command unavailable; kern.boottime has no file-interface source; second_boot_verify=not_run: run again after the second boot with --second-boot-phase verify --s4-stat…），auto `f1-P-regular-20260917T125810Z-s4verify`=partial（boottime_changed=blocked: shell command unavailable; kern.boottime has no file-interface source），auto `f1-P-regular-20260917T130619Z`=partial（second_boot_verify=not_run: run again after the second boot with --second-boot-phase verify --s4-state /Users/kolar/github/vphone-cli/research/artifacts/f1-matrix/f1-P-regular-20260917T130619Z/steps/…）
- S5 `partial` [manual] 选用 `.build/f1/logs/d4-acc/manual/manual_results.json#S5`。说明：checks: bottom_edge_swipe_home=failed (鼠标原生路径，用户观察)；bottom_edge_swipe_home_guest_path: passed（宿主 swipe x1=645 y1=2790→1600 300ms；manual/home-swipe 的首次尝试起始于主屏，无结论）。未解决问题：O2
- S6 `partial` [auto] 选用 `f1-P-regular-20260917T130619Z`。分类/原因：list=blocked: host control exposes no file_list/file_rename/file_delete and shell is unavailable; rename=blocked: host control exposes no file_list/file_rename/file_delete and shell is unavailable; d…。其他记录：auto `f1-P-regular-20260917T125810Z`=partial（list=blocked: host control exposes no file_list/file_rename/file_delete and shell is unavailable; rename=blocked: host control exposes no file_list/file_rename/file_delete and shell is unavailable; d…）
- S7 `failed` [manual] 选用 `.build/f1/logs/d4-acc/manual/manual_results.json#S7_after_setup`。分类/原因：capability_declared_but_uiopen_missing。说明：classification: capability_declared_but_uiopen_missing；note: 客户机为旧 vphoned（未含 5fd007c 能力拆分）。其他记录：auto `f1-P-regular-20260917T125810Z`=failed（app_launch returned ok=false: uiopen unavailable to launch com.apple.Preferences），auto `f1-P-regular-20260917T130619Z`=failed（capability_declared_but_uiopen_missing；app_launch returned ok=false: uiopen unavailable to launch com.apple.Preferences），auto `f1-P-regular-gui-20260917T155133Z`=failed（capability_declared_but_uiopen_missing；app_launch returned ok=false: uiopen unavailable to launch com.apple.Preferences）。未解决问题：O1
- S8 `blocked` [manual] 选用 `.build/f1/logs/d4-acc/manual/manual_results.json#S8`。分类/原因：Developer Mode disabled；regular 变体上未能开启。说明：reason: Developer Mode disabled；regular 变体上未能开启；attempts: 5 项；note: 原因未查明。已知限制：L1
- S9 `partial` [auto] 选用 `f1-P-regular-20260917T130619Z`。分类/原因：app_layer_reading=not_run: no guest application probe reads CoreLocation (plan §3 S9)。其他记录：auto `f1-P-regular-20260917T125810Z`=failed（location_source_set returned ok=false: timestamp must be > 0）。已知限制：L3
- S10 `passed` [auto] 选用 `f1-P-regular-20260917T130619Z`。其他记录：auto `f1-P-regular-20260917T125810Z`=passed
- S11 `not_applicable` [auto] 选用 `f1-P-regular-20260917T130619Z`。分类/原因：plan applies S11 only to jb/exp --frida combinations。其他记录：auto `f1-P-regular-20260917T125810Z`=not_applicable（plan applies S11 only to jb/exp --frida combinations）
- S12 `partial` [auto] 选用 `f1-P-regular-20260917T130619Z`。分类/原因：hv_vmm_sysctl=blocked: shell command unavailable; dt_model_via_hw_machine=blocked: shell command unavailable; dt_target_type_compatible=blocked: no guest interface reads DeviceTree target-type/compat…。说明：子项 S12_graphics [manual] not_applicable：限定：negative variant。其他记录：auto `f1-P-regular-20260917T125810Z`=partial（hv_vmm_sysctl=blocked: shell command unavailable; dt_model_via_hw_machine=blocked: shell command unavailable; dt_target_type_compatible=blocked: no guest interface reads DeviceTree target-type/compat…）。已知限制：L3

### P:dev（f1-261-dev）

- run.json 工具提交：22a7c02b9334, 5fd007ce73a5
- 创建工具 vphone-cli SHA-256 6da0a19f4284f7064a0de4bd8094674dc218f1bea9e472dba763af5ef9b08bc2
- run `f1-P-dev-20260917T131734Z` launch=headless, screen_available=False
- run `f1-P-dev-20260917T131734Z-s4verify` launch=headless, screen_available=False
- run `f1-P-dev-gui-20260917T154524Z` launch=gui, screen_available=True
- preflight `passed` [auto] 选用 `f1-P-dev-gui-20260917T154524Z`。其他记录：auto `f1-P-dev-20260917T131734Z`=passed，auto `f1-P-dev-20260917T131734Z-s4verify`=passed
- S1 `passed` [checkpoint] 选用 `.build/f1/logs/f1-261-dev/create-status.json`。说明：overall_status=succeeded；prepare iOS 26.1/23B85、cloudOS 26.1/23B85 与组合 P 定义一致；patch_records=70，与历史值一致
- S2 `passed` [checkpoint] 选用 `.build/f1/logs/f1-261-dev/create-status.json`。说明：restore status=succeeded, restore_update_exit=0, post_restore_dfu_outcome=matched
- S3 `passed` [checkpoint] 选用 `.build/f1/logs/f1-261-dev/create-status.json`。说明：first_boot status=succeeded, prompt=matched; verification status=succeeded；子项 setup_assistant [manual] passed：note: 代理经 file_put 预先写入 en0
- S4 `passed` [auto] 选用 `f1-P-dev-20260917T131734Z-s4verify`。其他记录：auto `f1-P-dev-20260917T131734Z`=partial（second_boot_verify=not_run: run again after the second boot with --second-boot-phase verify --s4-state /Users/kolar/github/vphone-cli/research/artifacts/f1-matrix/f1-P-dev-20260917T131734Z/steps/S4/s…）
- S5 `passed` [manual] 选用 `.build/f1/logs/f1-261-dev/manual/manual_results.json#S5`。说明：observation: 用户报告三指从底部上滑可回主屏（观察，未计入判定；具体在哪台 VM 上观察到未确认）
- S6 `partial` [auto] 选用 `f1-P-dev-20260917T131734Z`。分类/原因：list=blocked: host control exposes no file_list/file_rename/file_delete and shell is unavailable; rename=blocked: host control exposes no file_list/file_rename/file_delete and shell is unavailable; d…
- S7 `failed` [manual] 选用 `.build/f1/logs/f1-261-dev/manual/manual_results.json#S7_after_setup`。分类/原因：capability_declared_but_uiopen_missing。说明：classification: capability_declared_but_uiopen_missing；note: 客户机为旧 vphoned（未含 5fd007c 能力拆分）。其他记录：auto `f1-P-dev-20260917T131734Z`=failed（capability_declared_but_uiopen_missing；app_launch returned ok=false: uiopen unavailable to launch com.apple.Preferences），auto `f1-P-dev-gui-20260917T154524Z`=failed（capability_declared_but_uiopen_missing；app_launch returned ok=false: uiopen unavailable to launch com.apple.Preferences）。未解决问题：O1
- S8 `passed` [manual] 选用 `.build/f1/logs/f1-261-dev/manual/manual_results.json#S8`。说明：note: 首次查询报 device must be paired；devicectl manage pair 成功后 ddiServices isUsable=true contentIsCompatible=true
- S9 `partial` [auto] 选用 `f1-P-dev-20260917T131734Z`。分类/原因：app_layer_reading=not_run: no guest application probe reads CoreLocation (plan §3 S9)。已知限制：L3
- S10 `passed` [auto] 选用 `f1-P-dev-20260917T131734Z`
- S11 `not_applicable` [auto] 选用 `f1-P-dev-20260917T131734Z`。分类/原因：plan applies S11 only to jb/exp --frida combinations
- S12 `partial` [auto] 选用 `f1-P-dev-20260917T131734Z`。分类/原因：hv_vmm_sysctl=blocked: shell command unavailable; dt_model_via_hw_machine=blocked: shell command unavailable; dt_target_type_compatible=blocked: no guest interface reads DeviceTree target-type/compat…。说明：子项 S12_graphics [manual] not_applicable：限定：negative variant。已知限制：L3

### P:jb（f1-261-jb）

- run.json 工具提交：22a7c02b9334, 5fd007ce73a5
- 创建工具 vphone-cli SHA-256 6da0a19f4284f7064a0de4bd8094674dc218f1bea9e472dba763af5ef9b08bc2
- run `f1-P-jb-20260917T130931Z` launch=headless, screen_available=False
- run `f1-P-jb-20260917T130931Z-s4verify` launch=headless, screen_available=False
- run `f1-P-jb-gui-20260917T153640Z` launch=gui, screen_available=True
- run `f1-P-jb-gui-20260917T153713Z` launch=gui, screen_available=True
- run `f1-P-jb-gui-20260917T153946Z` launch=gui, screen_available=True
- preflight `passed` [auto] 选用 `f1-P-jb-gui-20260917T153946Z`。其他记录：auto `f1-P-jb-20260917T130931Z`=passed，auto `f1-P-jb-20260917T130931Z-s4verify`=passed，auto `f1-P-jb-gui-20260917T153640Z`=passed，auto `f1-P-jb-gui-20260917T153713Z`=passed
- S1 `passed` [checkpoint] 选用 `.build/f1/logs/f1-261-jb/create-status.json`。说明：overall_status=completed_unverified；prepare iOS 26.1/23B85、cloudOS 26.1/23B85 与组合 P 定义一致；patch_records=152，与历史值一致
- S2 `passed` [checkpoint] 选用 `.build/f1/logs/f1-261-jb/create-status.json`。说明：restore status=succeeded, restore_update_exit=0, post_restore_dfu_outcome=matched
- S3 `passed` [checkpoint+manual] 选用 `.build/f1/logs/f1-261-jb/create-status.json`。说明：first_boot status=succeeded, prompt=matched; verification status=succeeded；jb_finalize unverified：检查点按设计不读取客户机收尾日志；JB 收尾完成标记见人工取回日志 `.build/f1/logs/f1-261-jb/vphone_jb_setup.log`；子项 setup_assistant [manual] passed：note: 代理经 file_put 预先写入 en0
- S4 `passed` [auto] 选用 `f1-P-jb-20260917T130931Z-s4verify`。其他记录：auto `f1-P-jb-20260917T130931Z`=partial（second_boot_verify=not_run: run again after the second boot with --second-boot-phase verify --s4-state /Users/kolar/github/vphone-cli/research/artifacts/f1-matrix/f1-P-jb-20260917T130931Z/steps/S4/s4…）
- S5 `partial` [manual] 选用 `.build/f1/logs/f1-261-jb/manual/manual_results.json#S5`。说明：checks: bottom_edge_swipe_home=failed；bottom_edge_swipe_home_guest_path: failed（宿主 swipe x1=645 y1=2790 → y2=1600 300ms 两次；客户机声明 touch_edge。锁屏界面底部上滑解锁可用（用户观察）。exp 上同一手势通过。原因未查明）。未解决问题：O2
- S6 `passed` [auto] 选用 `f1-P-jb-20260917T130931Z`
- S7 `partial` [manual] 选用 `.build/f1/logs/f1-261-jb/manual/manual_results.json#S7_after_setup`。说明：note: launch_pid/terminate 通过。此前 f1-P-jb-gui-20260917T153640Z、153713Z 及直接请求失败（uiopen ok but no pid），同期 screenshot 返回 encodingFailed；用户确认窗口为黑屏锁定，解锁后复跑通过。其他记录：auto `f1-P-jb-20260917T130931Z`=failed（app_launch returned ok=false: com.apple.Preferences did not start (uiopen ok but no pid)），auto `f1-P-jb-gui-20260917T153640Z`=failed（app_launch returned ok=false: com.apple.Preferences did not start (uiopen ok but no pid)），auto `f1-P-jb-gui-20260917T153713Z`=failed（app_launch returned ok=false: com.apple.Preferences did not start (uiopen ok but no pid)），auto `f1-P-jb-gui-20260917T153946Z`=partial（screenshot_shows_app=not_run: manual review required: screenshot shows the application; ipa_install=not_run: no --ipa test package provided）
- S8 `passed` [manual] 选用 `.build/f1/logs/f1-261-jb/manual/manual_results.json#S8`。说明：note: ddiServices isUsable=true contentIsCompatible=true
- S9 `partial` [auto] 选用 `f1-P-jb-20260917T130931Z`。分类/原因：app_layer_reading=not_run: no guest application probe reads CoreLocation (plan §3 S9)。已知限制：L3
- S10 `passed` [auto] 选用 `f1-P-jb-20260917T130931Z`
- S11 `not_applicable` [auto] 选用 `f1-P-jb-20260917T130931Z`。分类/原因：plan applies S11 only to jb/exp --frida combinations
- S12 `partial` [auto] 选用 `f1-P-jb-20260917T130931Z`。分类/原因：dt_target_type_compatible=blocked: no guest interface reads DeviceTree target-type/compatible directly。说明：子项 S12_graphics [manual] not_applicable：限定：negative variant。已知限制：L3

### P:exp（f1-261-exp）

- run.json 工具提交：22a7c02b9334, 4ece8ea74ec5
- 创建工具 vphone-cli SHA-256 6da0a19f4284f7064a0de4bd8094674dc218f1bea9e472dba763af5ef9b08bc2
- run `f1-P-exp-20260917T130732Z` launch=headless, screen_available=False
- run `f1-P-exp-20260917T130732Z-s4verify` launch=headless, screen_available=False
- run `f1-P-exp-gui-20260917T151435Z` launch=gui, screen_available=True
- preflight `passed` [auto] 选用 `f1-P-exp-gui-20260917T151435Z`。其他记录：auto `f1-P-exp-20260917T130732Z`=passed，auto `f1-P-exp-20260917T130732Z-s4verify`=passed
- S1 `passed` [checkpoint] 选用 `.build/f1/logs/f1-261-exp/create-status.json`。说明：overall_status=completed_unverified；prepare iOS 26.1/23B85、cloudOS 26.1/23B85 与组合 P 定义一致；patch_records=178，与历史值一致
- S2 `passed` [checkpoint] 选用 `.build/f1/logs/f1-261-exp/create-status.json`。说明：restore status=succeeded, restore_update_exit=0, post_restore_dfu_outcome=matched
- S3 `passed` [checkpoint+manual] 选用 `.build/f1/logs/f1-261-exp/create-status.json`。说明：first_boot status=succeeded, prompt=matched; verification status=succeeded；jb_finalize unverified：检查点按设计不读取客户机收尾日志；JB 收尾完成标记见人工取回日志 `.build/f1/logs/f1-261-exp/vphone_jb_setup.log`；子项 setup_assistant [manual] passed：note: 用户完成首次设置并进入主屏；代理经 file_put 预先写入 en0
- S4 `passed` [auto] 选用 `f1-P-exp-20260917T130732Z-s4verify`。其他记录：auto `f1-P-exp-20260917T130732Z`=partial（second_boot_verify=not_run: run again after the second boot with --second-boot-phase verify --s4-state /Users/kolar/github/vphone-cli/research/artifacts/f1-matrix/f1-P-exp-20260917T130732Z/steps/S4/s…）
- S5 `passed` [manual] 选用 `.build/f1/logs/f1-261-exp/manual/manual_results.json#S5`
- S6 `passed` [auto] 选用 `f1-P-exp-20260917T130732Z`
- S7 `partial` [manual] 选用 `.build/f1/logs/f1-261-exp/manual/manual_results.json#S7_after_setup`。说明：note: launch_pid/terminate 通过；截图人工确认未单独记录。其他记录：auto `f1-P-exp-20260917T130732Z`=failed（app_launch returned ok=false: com.apple.Preferences did not start (uiopen ok but no pid)），auto `f1-P-exp-gui-20260917T151435Z`=partial（screenshot_shows_app=not_run: manual review required: screenshot shows the application; ipa_install=not_run: no --ipa test package provided）
- S8 `passed` [manual] 选用 `.build/f1/logs/f1-261-exp/manual/manual_results.json#S8`。说明：note: devicectl 隧道建立，ddiServices isUsable=true contentIsCompatible=true；设备已为 paired 状态，无需信任操作
- S9 `partial` [auto] 选用 `f1-P-exp-20260917T130732Z`。分类/原因：app_layer_reading=not_run: no guest application probe reads CoreLocation (plan §3 S9)。已知限制：L3
- S10 `partial` [manual] 选用 `.build/f1/logs/f1-261-exp/manual/manual_results.json#S10_after_setup`。说明：copy_receipt: passed (run f1-P-exp-gui-20260917T151435Z 及手动 present)；camera_view: passed (用户截图与宿主截图均显示推送的 QR 图像)；system_camera_qr_banner: not_observed (URL QR 完整位于取景框内，12 秒 12 张宿主截图无识别提示；原因未查明)。其他记录：auto `f1-P-exp-20260917T130732Z`=failed（app_launch returned ok=false: com.apple.camera did not start (uiopen ok but no pid)），auto `f1-P-exp-gui-20260917T151435Z`=partial（qr_recognition=not_run: QR text requires research/probes/camera_qr_probe (external); camera_view_screenshot=not_run: manual screenshot review required）。已知限制：L2
- S11 `not_applicable` [auto] 选用 `f1-P-exp-20260917T130732Z`。分类/原因：plan applies S11 only to jb/exp --frida combinations
- S12 `partial` [auto] 选用 `f1-P-exp-20260917T130732Z`。分类/原因：dt_target_type_compatible=blocked: no guest interface reads DeviceTree target-type/compatible directly; graphics=blocked: requires VZ window review and AppleParavirtGPU evidence; compute=blocked: Met…。说明：子项 S12_graphics [manual] passed。已知限制：L3

### P:less（f1-261-less）

- run.json 工具提交：22a7c02b9334
- 创建工具 vphone-cli SHA-256 6da0a19f4284f7064a0de4bd8094674dc218f1bea9e472dba763af5ef9b08bc2
- run `f1-P-less-20260917T142944Z` launch=headless, screen_available=False
- run `f1-P-less-20260917T142944Z-s4verify` launch=headless, screen_available=False
- preflight `passed` [auto] 选用 `f1-P-less-20260917T142944Z-s4verify`。其他记录：auto `f1-P-less-20260917T142944Z`=passed
- S1 `passed` [checkpoint] 选用 `.build/f1/logs/f1-261-less/create-status.json`。说明：overall_status=completed_unverified；prepare iOS 26.1/23B85、cloudOS 26.1/23B85 与组合 P 定义一致；cfw not_applicable（variant less installs no CFW）；patch_records=26，与历史值一致
- S2 `passed` [checkpoint] 选用 `.build/f1/logs/f1-261-less/create-status.json`。说明：restore status=succeeded, restore_update_exit=0, post_restore_dfu_outcome=matched
- S3 `partial` [checkpoint] 选用 `.build/f1/logs/f1-261-less/create-status.json`。说明：first_boot status=succeeded, prompt=matched; verification status=unverified；verification unverified（less boot has no success marker; its exit status after the operator quits is not boot evidence）；子项 setup_assistant [manual] passed：note: 代理经 file_put 预先写入 en0（root）；用户解锁进入系统
- S4 `passed` [auto] 选用 `f1-P-less-20260917T142944Z-s4verify`。其他记录：auto `f1-P-less-20260917T142944Z`=partial（second_boot_verify=not_run: run again after the second boot with --second-boot-phase verify --s4-state /Users/kolar/github/vphone-cli/research/artifacts/f1-matrix/f1-P-less-20260917T142944Z/steps/S4/…）
- S5 `partial` [manual] 选用 `.build/f1/logs/f1-261-less/manual/manual_results.json#S5`。说明：checks: bottom_edge_swipe_home=failed (鼠标原生路径，用户观察)；bottom_edge_swipe_home_guest_path: not_run（测试方法错误：为让普通用户连接，less_gui.zsh 将 root 进程的 vphone.sock 属主改为 kolar；宿主控制对普通用户连接返回 no valid JSON response，root 运行的客户端又因 socket 属主不是当前用户拒绝连接（host_control_client.endpoint）。探测与 S7 GUI 复跑均未发出请求，无效运行已移至 manual/invalid-runs/）。未解决问题：O2
- S6 `partial` [auto] 选用 `f1-P-less-20260917T142944Z`。分类/原因：list=blocked: host control exposes no file_list/file_rename/file_delete and shell is unavailable; rename=blocked: host control exposes no file_list/file_rename/file_delete and shell is unavailable; d…
- S7 `failed` [manual] 选用 `.build/f1/logs/f1-261-less/manual/manual_results.json#S7`。分类/原因：capability_declared_but_uiopen_missing。说明：classification: capability_declared_but_uiopen_missing；note: GUI 复跑未执行（见上）。其他记录：auto `f1-P-less-20260917T142944Z`=failed（capability_declared_but_uiopen_missing；app_launch returned ok=false: uiopen unavailable to launch com.apple.Preferences）。未解决问题：O1
- S8 `blocked` [manual] 选用 `.build/f1/logs/f1-261-less/manual/manual_results.json#S8`。分类/原因：Developer Mode disabled；less 变体上未能开启。说明：reason: Developer Mode disabled；less 变体上未能开启；attempts: 2 项；note: 原因未查明；与 regular 表现一致。已知限制：L1
- S9 `partial` [auto] 选用 `f1-P-less-20260917T142944Z`。分类/原因：app_layer_reading=not_run: no guest application probe reads CoreLocation (plan §3 S9)。已知限制：L3
- S10 `passed` [auto] 选用 `f1-P-less-20260917T142944Z`
- S11 `not_applicable` [auto] 选用 `f1-P-less-20260917T142944Z`。分类/原因：plan applies S11 only to jb/exp --frida combinations
- S12 `partial` [auto] 选用 `f1-P-less-20260917T142944Z`。分类/原因：hv_vmm_sysctl=blocked: shell command unavailable; dt_model_via_hw_machine=blocked: shell command unavailable; dt_target_type_compatible=blocked: no guest interface reads DeviceTree target-type/compat…。说明：子项 S12_graphics [manual] not_applicable：限定：negative variant。已知限制：L3

### N:jb:frida（f1-2661-jb-frida）

- iOS 23G82 为非 catalog 构建（catalog 配对为 23G83），经本地路径指定
- run `research/artifacts/f1-matrix/f1-N-jb-20260917T164243Z-s4verify/run.json` options.frida=False 与规格 N:jb:frida 不一致；按 bundle 归入本行
- frida: client=17.16.1 (autophone venv)，server_deb=frida_17.18.0_iphoneos-arm64.deb，kernel_patches=cloudOS 26.4, Frida kernel patches enabled; patch_records 157
- run.json 工具提交：205ea0155354
- 创建工具 vphone-cli SHA-256 6da0a19f4284f7064a0de4bd8094674dc218f1bea9e472dba763af5ef9b08bc2
- run `f1-N-jb-20260917T164243Z` launch=headless, screen_available=False
- run `f1-N-jb-20260917T164243Z-s4verify` launch=headless, screen_available=False
- run `f1-N-jb-gui-20260917T165606Z` launch=gui, screen_available=True
- preflight `passed` [auto] 选用 `f1-N-jb-gui-20260917T165606Z`。其他记录：auto `f1-N-jb-20260917T164243Z`=passed，auto `f1-N-jb-20260917T164243Z-s4verify`=passed
- S1 `passed` [checkpoint] 选用 `.build/f1/logs/f1-2661-jb-frida/create-status.json`。说明：overall_status=completed_unverified；prepare iOS 26.6.1/23G82、cloudOS 26.4/23E5207q 与组合 N 定义一致；patch_records=157；无同输入历史值可比较
- S2 `passed` [checkpoint] 选用 `.build/f1/logs/f1-2661-jb-frida/create-status.json`。说明：restore status=succeeded, restore_update_exit=0, post_restore_dfu_outcome=matched
- S3 `passed` [checkpoint+manual] 选用 `.build/f1/logs/f1-2661-jb-frida/create-status.json`。说明：first_boot status=succeeded, prompt=matched; verification status=succeeded；jb_finalize unverified：检查点按设计不读取客户机收尾日志；JB 收尾完成标记见人工取回日志 `.build/f1/logs/f1-2661-jb-frida/vphone_jb_setup.log`；子项 setup_assistant [manual] passed
- S4 `passed` [auto] 选用 `f1-N-jb-20260917T164243Z-s4verify`。其他记录：auto `f1-N-jb-20260917T164243Z`=partial（second_boot_verify=not_run: run again after the second boot with --second-boot-phase verify --s4-state /Users/kolar/github/vphone-cli/research/artifacts/f1-matrix/f1-N-jb-20260917T164243Z/steps/S4/s4…）
- S5 `partial` [manual] 选用 `.build/f1/logs/f1-2661-jb-frida/manual/manual_results.json#S5`。说明：checks: bottom_edge_swipe_home=failed (鼠标原生路径，用户观察)；bottom_edge_swipe_home_guest_path: failed（宿主截图返回 encodingFailed（同期 app_launch 成功，原因未查明），改由用户目视：未回到主屏）。未解决问题：O2
- S6 `passed` [auto] 选用 `f1-N-jb-20260917T164243Z`
- S7 `partial` [manual] 选用 `.build/f1/logs/f1-2661-jb-frida/manual/manual_results.json#S7_after_setup`。说明：note: launch/terminate passed。其他记录：auto `f1-N-jb-20260917T164243Z`=failed（app_launch returned ok=false: com.apple.Preferences did not start (uiopen ok but no pid)），auto `f1-N-jb-gui-20260917T165606Z`=partial（screenshot_shows_app=not_run: manual review required: screenshot shows the application; ipa_install=not_run: no --ipa test package provided）
- S8 `passed` [manual] 选用 `.build/f1/logs/f1-2661-jb-frida/manual/manual_results.json#S8`
- S9 `partial` [auto] 选用 `f1-N-jb-20260917T164243Z`。分类/原因：app_layer_reading=not_run: no guest application probe reads CoreLocation (plan §3 S9)。已知限制：L3
- S10 `passed` [manual] 选用 `.build/f1/logs/f1-2661-jb-frida/manual/manual_results.json#S10`。说明：限定：negative。其他记录：auto `f1-N-jb-20260917T164243Z`=passed
- S11 `failed` [manual] 选用 `.build/f1/logs/f1-2661-jb-frida/manual/manual_results.json#S11`。说明：checks: device_connect、hook_message、hook_counts_open（open() 32 次）、hook_unload、stalker_follow_existing_thread（blocks=1）passed；stalker_unload、session_detach 20 秒内未返回；SpringBoard pid 487 未变，用户确认主屏操作正常；note: 与 N-exp 表现一致，原因未查明。未解决问题：O3
- S12 `partial` [auto] 选用 `f1-N-jb-20260917T164243Z`。分类/原因：dt_target_type_compatible=blocked: no guest interface reads DeviceTree target-type/compatible directly。说明：子项 S12_graphics [manual] not_applicable：限定：negative variant。已知限制：L3

### N:exp:frida（f1-2661-exp-frida）

- iOS 23G82 为非 catalog 构建（catalog 配对为 23G83），经本地路径指定
- run `research/artifacts/f1-matrix/f1-N-exp-20260917T163631Z-s4verify/run.json` options.frida=False 与规格 N:exp:frida 不一致；按 bundle 归入本行
- frida: client=17.16.1 (autophone venv)，server_deb=frida_17.18.0_iphoneos-arm64.deb (~/.vphone/debs)，kernel_patches=cloudOS 26.4, Frida kernel patches enabled; patch_records 183
- run.json 工具提交：205ea0155354
- 创建工具 vphone-cli SHA-256 6da0a19f4284f7064a0de4bd8094674dc218f1bea9e472dba763af5ef9b08bc2
- run `f1-N-exp-20260917T163631Z` launch=headless, screen_available=False
- run `f1-N-exp-20260917T163631Z-s4verify` launch=headless, screen_available=False
- run `f1-N-exp-gui-20260917T164056Z` launch=gui, screen_available=True
- preflight `passed` [auto] 选用 `f1-N-exp-gui-20260917T164056Z`。其他记录：auto `f1-N-exp-20260917T163631Z`=passed，auto `f1-N-exp-20260917T163631Z-s4verify`=passed
- S1 `passed` [checkpoint] 选用 `.build/f1/logs/f1-2661-exp-frida/create-status.json`。说明：overall_status=completed_unverified；prepare iOS 26.6.1/23G82、cloudOS 26.4/23E5207q 与组合 N 定义一致；patch_records=183；无同输入历史值可比较
- S2 `passed` [checkpoint] 选用 `.build/f1/logs/f1-2661-exp-frida/create-status.json`。说明：restore status=succeeded, restore_update_exit=0, post_restore_dfu_outcome=matched
- S3 `passed` [checkpoint+manual] 选用 `.build/f1/logs/f1-2661-exp-frida/create-status.json`。说明：first_boot status=succeeded, prompt=matched; verification status=succeeded；jb_finalize unverified：检查点按设计不读取客户机收尾日志；JB 收尾完成标记见人工取回日志 `.build/f1/logs/f1-2661-exp-frida/vphone_jb_setup.log`；子项 setup_assistant [manual] passed
- S4 `passed` [auto] 选用 `f1-N-exp-20260917T163631Z-s4verify`。其他记录：auto `f1-N-exp-20260917T163631Z`=partial（second_boot_verify=not_run: run again after the second boot with --second-boot-phase verify --s4-state /Users/kolar/github/vphone-cli/research/artifacts/f1-matrix/f1-N-exp-20260917T163631Z/steps/S4/s…）
- S5 `passed` [manual] 选用 `.build/f1/logs/f1-2661-exp-frida/manual/manual_results.json#S5`
- S6 `passed` [auto] 选用 `f1-N-exp-20260917T163631Z`
- S7 `partial` [manual] 选用 `.build/f1/logs/f1-2661-exp-frida/manual/manual_results.json#S7_after_setup`。说明：note: launch/terminate passed。其他记录：auto `f1-N-exp-20260917T163631Z`=failed（app_launch returned ok=false: com.apple.Preferences did not start (uiopen ok but no pid)），auto `f1-N-exp-gui-20260917T164056Z`=partial（screenshot_shows_app=not_run: manual review required: screenshot shows the application; ipa_install=not_run: no --ipa test package provided）
- S8 `passed` [manual] 选用 `.build/f1/logs/f1-2661-exp-frida/manual/manual_results.json#S8`。说明：note: ddiServices isUsable=true contentIsCompatible=true
- S9 `partial` [auto] 选用 `f1-N-exp-20260917T163631Z`。分类/原因：app_layer_reading=not_run: no guest application probe reads CoreLocation (plan §3 S9)。已知限制：L3
- S10 `partial` [manual] 选用 `.build/f1/logs/f1-2661-exp-frida/manual/manual_results.json#S10`。说明：harness_run: f1-N-exp-gui-20260917T164056Z failed: camera_present 在相机应用启动约 1 秒后返回 two-level transport receipt unavailable；manual_retry: 相机启动 4 秒后 present：复制回执 passed，2 秒内帧序号 1→17（manual/s10-manual/requests.jsonl）；首次启动显示“全新相机设计”引导，用户点继续后确认 QR 完整显示；qr_recognition: not_run（用户决定暂不复测）。其他记录：auto `f1-N-exp-20260917T163631Z`=failed（app_launch returned ok=false: com.apple.camera did not start (uiopen ok but no pid)），auto `f1-N-exp-gui-20260917T164056Z`=failed（camera_present returned ok=false: 'two-level transport receipt unavailable for f1-0cd11e03ce554f1b9afb4a6057404a52'）。已知限制：L2
- S11 `failed` [manual] 选用 `.build/f1/logs/f1-2661-exp-frida/manual/manual_results.json#S11`。说明：checks: device_connect、hook_message、hook_counts_open（宿主启动/终止设置期间 open() 8 次）、hook_unload、stalker_follow_existing_thread（blocks=1）passed；stalker_unload 与 session_detach 20 秒内未返回；SpringBoard pid 602 未变，用户确认主屏操作正常；note: 首次运行（Stalker 与 hook 同一脚本）在 detach 阶段挂起 6 分钟后被终止。Stalker 卸载挂起原因未查明。未解决问题：O3
- S12 `partial` [auto] 选用 `f1-N-exp-20260917T163631Z`。分类/原因：dt_target_type_compatible=blocked: no guest interface reads DeviceTree target-type/compatible directly; graphics=blocked: requires VZ window review and AppleParavirtGPU evidence; compute=blocked: Met…。说明：子项 S12_graphics [manual] passed。已知限制：L3

### L:regular

- 不纳入：用户决定旧版本组合 L（18.6.2/22G100）暂不纳入，未下载 IPSW，全部步骤记为 not_run

### L:dev

- 不纳入：用户决定旧版本组合 L（18.6.2/22G100）暂不纳入，未下载 IPSW，全部步骤记为 not_run

### L:jb

- 不纳入：用户决定旧版本组合 L（18.6.2/22G100）暂不纳入，未下载 IPSW，全部步骤记为 not_run

### L:exp

- 不纳入：用户决定旧版本组合 L（18.6.2/22G100）暂不纳入，未下载 IPSW，全部步骤记为 not_run

## 已知限制

| 编号 | 内容 | 适用单元格 | 决定 | 证据 |
| --- | --- | --- | --- | --- |
| L1 | regular、less 客户机开发者模式无法开启，S8 DDI 阻塞（ddiServices 报 Developer Mode is disabled；amfi reveal-developer-mode 后开关出现，开启并重启后该项消失，developer-mode-status=false；原因未查明） | P:regular S8；P:less S8 | 用户决定 B：不再复测 | `.build/f1/logs/d4-acc/manual/manual_results.json`：S8 blocked 及 5 次尝试<br>`.build/f1/logs/d4-acc/manual/ddi/ddi.txt`：Developer Mode is disabled<br>`.build/f1/logs/f1-261-less/manual/manual_results.json`：S8 blocked<br>`.build/f1/logs/f1-261-less/manual/ddi/ddi.txt`<br>`research/f1_p_matrix_run_2026-09-17.md`：人工步骤结果 Developer Mode 条目 |
| L2 | exp 系统相机 QR 识别提示未观察到，未用 E6 探针复测（P-exp：URL QR 完整位于取景框，12 秒 12 张宿主截图无识别提示，原因未查明；N-exp：复制回执与画面通过，QR 识别检查未执行（qr_recognition=not_run）） | P:exp S10；N:exp:frida S10 | 用户决定 B：不再复测（不用 E6 探针复测） | `.build/f1/logs/f1-261-exp/manual/manual_results.json`：S10_after_setup.system_camera_qr_banner=not_observed<br>`.build/f1/logs/f1-261-exp/manual/qr-url2/requests.jsonl`<br>`.build/f1/logs/f1-2661-exp-frida/manual/manual_results.json`：S10.qr_recognition=not_run |
| L3 | S9 应用层定位读数、S12 DeviceTree target-type/compatible 与计算路径无探针（S9 仅协议层 set/status/stop 通过（app_layer_reading=not_run）；S12 dt_target_type_compatible、compute 为 blocked；exp 图形由人工观察 VM 窗口判定） | P:regular S9/S12；P:dev S9/S12；P:jb S9/S12；P:exp S9/S12；P:less S9/S12；N:jb:frida S9/S12；N:exp:frida S9/S12 | 用户决定 B：不再复测，不新建探针 | `research/artifacts/f1-matrix/f1-P-exp-20260917T130732Z/run.json`：S9 app_layer_reading=not_run；S12 dt_target_type_compatible/graphics/compute=blocked<br>`research/artifacts/f1-matrix/f1-N-jb-20260917T164243Z/run.json`：S12 dt_target_type_compatible=blocked<br>`research/f1_e2e_matrix_plan_2026-09-17.md`：§3.2 S9/S12 判据 |

## 未解决问题

| 编号 | 内容 | 适用单元格 | 跟踪 | 证据 |
| --- | --- | --- | --- | --- |
| O1 | regular、dev、less 客户机缺少 uiopen，应用启动失败（vphoned 声明 apps 但 app_launch 返回 uiopen unavailable（classification capability_declared_but_uiopen_missing）；能力声明修正 5fd007c 未部署到客户机，部署后 S7 启动检查预期为 not_applicable（待验证）） | P:regular S7；P:dev S7；P:less S7 | 单独跟踪：部署含 5fd007c 的 vphoned 后复测 S7；不计为通过 | `research/artifacts/f1-matrix/f1-P-regular-gui-20260917T155133Z/run.json`<br>`research/artifacts/f1-matrix/f1-P-dev-gui-20260917T154524Z/run.json`<br>`research/artifacts/f1-matrix/f1-P-less-20260917T142944Z/run.json`：headless；less GUI 复跑无效，未计入<br>`research/host_control_e2_2026-09-12.md`：应用与 URL 能力映射修正 |
| O2 | 底部边缘上滑回主屏失败：jb（P、N）宿主注入路径失败；regular、less 鼠标原生路径失败（P-jb 宿主 swipe 645,2790→1600 两次前后截图相同；N-jb 注入与鼠标路径均失败（注入结果由用户目视）；regular 鼠标路径失败、宿主注入通过；less 鼠标路径失败、宿主注入未测（测试方法错误的运行已移出）；原因未查明） | P:jb S5；N:jb:frida S5；P:regular S5；P:less S5 | 单独跟踪；不计为通过 | `.build/f1/logs/f1-261-jb/manual/home-swipe/requests.jsonl`<br>`.build/f1/logs/f1-261-jb/manual/manual_results.json`：S5.bottom_edge_swipe_home_guest_path=failed<br>`.build/f1/logs/f1-2661-jb-frida/manual/home-swipe/requests-visual.jsonl`<br>`.build/f1/logs/f1-2661-jb-frida/manual/manual_results.json`<br>`.build/f1/logs/d4-acc/manual/manual_results.json`：鼠标 failed；宿主注入 passed<br>`.build/f1/logs/f1-261-less/manual/manual_results.json`：鼠标 failed；宿主注入 not_run |
| O3 | Frida Stalker 脚本卸载与会话分离挂起（device_connect、hook_message、hook_counts_open、hook_unload、stalker_follow_existing_thread 通过；stalker_unload 与 session_detach 20 秒内未返回；SpringBoard pid 未变；原因未查明） | N:exp:frida S11；N:jb:frida S11 | 单独跟踪；S11 记为 failed | `.build/f1/logs/f1-2661-exp-frida/manual/s11/s11.json`<br>`.build/f1/logs/f1-2661-jb-frida/manual/s11/s11.json`<br>`research/probes/f1_frida_s11.py`：S11 探针脚本 |

## 不纳入的组合

- L（regular/dev/jb/exp）：用户决定旧版本组合 L（18.6.2/22G100）暂不纳入，未下载 IPSW，全部步骤记为 not_run。证据：`research/f1_e2e_matrix_plan_2026-09-17.md`

## 输入清单

| 类型 | 规格 | 路径 | SHA-256 |
| --- | --- | --- | --- |
| run.json | - | `research/artifacts/f1-matrix/f1-N-exp-20260917T163631Z/run.json` | `83a11a815c5796f1d822e275a90bb36b8bba30809e01d99634b62b5503d157ad` |
| run.json | - | `research/artifacts/f1-matrix/f1-N-exp-20260917T163631Z-s4verify/run.json` | `dddb5dabaa4b296b2f27debed9a1db12a93ecd2afceab81ab245bb20a4f591d5` |
| run.json | - | `research/artifacts/f1-matrix/f1-N-exp-gui-20260917T164056Z/run.json` | `f2dff9d5c9c8ed0ebb41c01654e71bee999f3569f3c5183c407fde8b48f9e577` |
| run.json | - | `research/artifacts/f1-matrix/f1-N-jb-20260917T164243Z/run.json` | `3f4fc2ab4e3a41f24aff2b2cb10f719047d4112a5a39a936eefb7bf3cd3f3aa0` |
| run.json | - | `research/artifacts/f1-matrix/f1-N-jb-20260917T164243Z-s4verify/run.json` | `a30ab8eeb7cadddf5792ff4ca8b628529467f49cfb2627a2b726de71820ca28e` |
| run.json | - | `research/artifacts/f1-matrix/f1-N-jb-gui-20260917T165606Z/run.json` | `8a0b4616c1718827aaeea820ec2aa282d215c0eb48a7c4a90bb95058181cd1f3` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-dev-20260917T131734Z/run.json` | `b0c8feb4d2c9e70a2e0645a298bc934ec131f20fb497ebf0cba0ff5f533f8046` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-dev-20260917T131734Z-s4verify/run.json` | `c63e20d56dde720ff75256e6edfc52787e1da442d3179e940af1b44b4f33db6b` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-dev-gui-20260917T154524Z/run.json` | `ca1ec107916554b73c972d96063c753e726599f5c04bad2fae45be96b85c34e1` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-exp-20260917T130732Z/run.json` | `79c7877c364a8a2421ade70fb18b1f2eaa7c8721f249a7215cf6b7184e25b96f` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-exp-20260917T130732Z-s4verify/run.json` | `c56876751623b571468b22f2dc0cdadc46b65f9f853d22406cd5ac2c5e060181` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-exp-gui-20260917T151435Z/run.json` | `22b72751c1032f665521532d00c948d8e80e2b775c946516ee3c55f01d6d702d` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-jb-20260917T130931Z/run.json` | `79a3e8661b7300269637178f4c845c3c56a87d2653e0067992bf38bfcc575b2b` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-jb-20260917T130931Z-s4verify/run.json` | `2d83664979fdafb3aa524dbd3d257e52cdc19e86011f2fc10e42512fdb4feeb5` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-jb-gui-20260917T153640Z/run.json` | `f3049eb78e04b3815d32a58b6b3ddee6f21236bfbe7631429f3d1a1564f12b87` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-jb-gui-20260917T153713Z/run.json` | `c680ffc1407dc63159434b57be3cde5d2a749765d4913cf4c6c17d3909572862` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-jb-gui-20260917T153946Z/run.json` | `34ba1d59d9d974cf2ce893daffb71f6ee39992a4aaf07685d06447833c5fff46` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-less-20260917T142944Z/run.json` | `8c73c5e5fa46f3179d6b980bf7f8b8fa23a84f4f616bc1db93642145647d47de` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-less-20260917T142944Z-s4verify/run.json` | `5c442a9264ce048d4fdb560b7fbc5508e87e2657edee5de71a4c4e97568a8561` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-regular-20260917T125810Z/run.json` | `fdadcf57b0faab7aec6d176496b8665c93a76ecf83895ce0bea1bcf31c32e2e7` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-regular-20260917T125810Z-s4verify/run.json` | `ea432e47a929d57e99e849a7c5173def095f6aacf3a6b112caa47a63940c0c16` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-regular-20260917T130619Z/run.json` | `8a40d52d08f771a641d11b49a74221d0cd75fc51acf0a82bf890dee4bd666b5c` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-regular-20260917T130619Z-s4verify/run.json` | `fb0083739ce45d8a06977e12b49af1f8df003557cf0ceac8010c6cf5453d22e1` |
| run.json | - | `research/artifacts/f1-matrix/f1-P-regular-gui-20260917T155133Z/run.json` | `cc3a06e692382bb04b01412dd2a0aebe184c86d8f46cf8081bd0efef574ca48f` |
| create-status | P:regular | `.build/d4acc/lib/d4-acc/.create-checkpoint/checkpoint.json` | `40319a1d9eb586e3f48bab3b67679cc5997767da88fad0ca638e63c2d2a1f3b9` |
| create-status | P:dev | `.build/f1/logs/f1-261-dev/create-status.json` | `a9409db3a5412527fe60892a70bb159ec5f1c026aade10f9063ec5926d983b97` |
| create-status | P:jb | `.build/f1/logs/f1-261-jb/create-status.json` | `fd7b40771493a558c0482a27d6e78c65c0867e8ed6ec4d56c65c42d4e06799f2` |
| create-status | P:exp | `.build/f1/logs/f1-261-exp/create-status.json` | `f1c65c7911df609acfcc4351c888dc0104318a0ca2afdf72b0b809294b6c86aa` |
| create-status | P:less | `.build/f1/logs/f1-261-less/create-status.json` | `a207c63bad398f5a7409abcf6149142c9ef840962c75436276a582d28c4a2c43` |
| create-status | N:jb:frida | `.build/f1/logs/f1-2661-jb-frida/create-status.json` | `c4a86ac33def9b7a580f983a74eaf2c3a578f77d14a321a751e9f7047f2bb49f` |
| create-status | N:exp:frida | `.build/f1/logs/f1-2661-exp-frida/create-status.json` | `fbef3d8cb4251f90afa5f5a8cc9a8b8bfac843b0d9a1f0217e7754a88b509d6b` |
| manual | P:regular | `.build/f1/logs/d4-acc/manual/manual_results.json` | `e705503c58fd7c14323e9f7a113027697ffb280ba303abb1803654d7f202536c` |
| manual | P:dev | `.build/f1/logs/f1-261-dev/manual/manual_results.json` | `bab7a8ebe857b22f35301ebf371c70c2239c17ee33f89d9b4543c54a8edded2e` |
| manual | P:jb | `.build/f1/logs/f1-261-jb/manual/manual_results.json` | `87c2286a08aa8cbd159414f01879ed45b18973a1491fa32803ef3b42a995c961` |
| manual | P:exp | `.build/f1/logs/f1-261-exp/manual/manual_results.json` | `f14b4f023a17857bf1c0ec273e964bdda6bb15df8822e5c6a8d3bc88d2d975db` |
| manual | P:less | `.build/f1/logs/f1-261-less/manual/manual_results.json` | `5afdc2af40a57d79668eb9e667a9f04fbfb6fee21a30050745cbcc42b6fac3e7` |
| manual | N:jb:frida | `.build/f1/logs/f1-2661-jb-frida/manual/manual_results.json` | `750da115b446d9ae01e0ac9725034b003e0d908de9b7d0253f67f3bec9bae0af` |
| manual | N:exp:frida | `.build/f1/logs/f1-2661-exp-frida/manual/manual_results.json` | `d85c88531e1bed6aad06202d09fb2f485592c49721549ab2cf5298565696704a` |
| jb-setup-log | P:jb | `.build/f1/logs/f1-261-jb/vphone_jb_setup.log` | `df5a311b068642615eb1f21e9a7d920b894bc426fad80892e505ff11f9225c5d` |
| jb-setup-log | P:exp | `.build/f1/logs/f1-261-exp/vphone_jb_setup.log` | `bf7d801d8e8ce48b2463b0051f44ed2655d7481ee718520e33b8fd9bf7c15576` |
| jb-setup-log | N:jb:frida | `.build/f1/logs/f1-2661-jb-frida/vphone_jb_setup.log` | `3c68c80da84424f7abd739251d17c267a9a3905a66104c4e650bb14b858198ed` |
| jb-setup-log | N:exp:frida | `.build/f1/logs/f1-2661-exp-frida/vphone_jb_setup.log` | `cb7c9e53d77d098bb6801d269953b6ee6b07f4aeebe8462057f263d63e56f4d4` |
| limits | - | `research/f1_known_limits_2026-09-17.json` | `6ddc9b1baa0a6fb819f46233a7b567f4a882dfe32a13f25d54ac325b506f10c2` |
