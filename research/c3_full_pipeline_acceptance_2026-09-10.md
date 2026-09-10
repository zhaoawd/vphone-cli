# C3 精确 26.1 引导链流水线验收

日期：2026-09-10。

## 实验范围与输入

本轮运行 regular / dev / jb / exp 四种非 less 引导链流水线，覆盖 AVPBooter、iBSS、iBEC、LLB、TXM、kernelcache、DeviceTree 的生产编排和结构化报告。没有修改磁盘镜像，没有执行恢复或启动，也没有覆盖 less 的 Filesystem / Manifest 阶段。此结果不表示完整恢复镜像或端到端运行验收通过。

精确输入为 iPhone17,3 iOS 26.1 / 23B85 与 cloudOS 26.1 / 23B85。原始归档成员通过远程提取取得，来源 URL、成员路径、长度、CRC32 与 SHA-256 保存在 `research/artifacts/c3-full-pipeline-2026-09-10/stock/sources.json`。内核 SHA-256 为 `b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac`，与既有 26.1 样本一致。

AVPBooter 来自宿主 macOS 26.5.1 / 25F80 的 `/System/Library/Frameworks/Virtualization.framework/Versions/A/Resources/AVPBooter.vresearch1.bin`，长度 305928 字节，SHA-256 为 `fc94622f710a83b36c65cfd06345b0535880c74195b1ed58967c9ef7c0e740f5`。

TXM 按生产合并规则取 cloudOS 的 `Firmware/txm.iphoneos.research.im4p`。本轮确认两份归档均含该文件；cloudOS 与 iPhone 版本长度均为 161043 字节，SHA-256 均为 `3912f361973d70090b1f15a6e4ec64bd12e457a06d73555ec8880b76c861aa3a`。既有引导链测试从 iPhone 提取 TXM 的事实保留；其输入字节与本轮 cloudOS TXM 相同。不能据此推断其他构建也相同。

## 结果

四种变体的生产 CLI 和 `scripts/check_patch_report.py` 均退出 0。报告中的 iOS 27、Frida、强制 EXC_GUARD 门控均关闭；dev 的 EXC_GUARD 条件按变体启用。

| 变体 | 声明方法数 | 补丁记录数 | 必要集合报告 |
| --- | ---: | ---: | --- |
| regular | 29 | 58 | 通过 |
| dev | 34 | 70 | 通过 |
| jb | 68 | 152 | 通过 |
| exp | 88 | 178 | 通过 |

方法数包含条件关闭的方法，不能与命中方法数互换。报告分别保存在 `research/artifacts/c3-full-pipeline-2026-09-10/runs/acceptance-01/<variant>/report.json`；同目录 `records.json` 保存补丁记录，`run.log` 保存运行日志。

主控独立核对 `sources.json` 所列 11 个原始文件，四变体 CLI 运行后长度和 SHA-256 均未变化。

组件记录数：regular 为 AVPBooter 1、iBSS 4、iBEC 7、LLB 13、TXM 1、基础内核 28、DeviceTree 4；dev 的 TXM 为 12、基础内核为 29，其余相同。jb 在基础路径上增加 IBootJB 1、KernelJB 82 条；exp 再增加 KernelEXP 7 条，并使用 23 条 DeviceTree 记录。这些是生产顺序执行的组件计数，不与独立补丁器计数混用。

## 验收限制与后续

本轮已补齐这组精确输入的四种非 less 引导链生产编排与必要集合证据。落盘验证已完成，使用以下两类判据：

- AVPBooter、iBSS、iBEC、LLB、TXM、kernelcache：独立解码原始及落盘 payload，按记录重放并比较完整结果。四种变体的六类二进制均通过；11 个原始文件及 3 个 plist 未变。结果为 `research/artifacts/c3-full-pipeline-2026-09-10/runs/acceptance-01/verification.json`，日志为 `research/artifacts/c3-full-pipeline-2026-09-10/verify.log`。
- DeviceTree：Swift 使用原始 26.1 输入，分别将 regular / exp 的 CLI 落盘完整序列化 payload 与 legacy、structured 结果比较，两个参数用例均通过（1 test / 1 suite，0.009 秒，退出 0）。regular / dev / jb 的完整 DeviceTree 文件另经主控核对相同，SHA-256 为 `3a6013602c5c57dc96722681bcb28af8994025a556495287f6f4852a9d6e8e64`。日志为 `research/artifacts/c3-full-pipeline-2026-09-10/devicetree-parity.log`。

首次研究验证脚本将旧偏移记录重放判据应用于 DeviceTree，因属性头长度、flags 及布局重建不由旧偏移记录完整表示而失败（原 payload 68380 字节，最终 68336 字节）。此后将二进制重放范围限定为上述六类，并对 DeviceTree 使用序列化结果比较。该失败没有提供生产补丁缺陷证据。`verification.json` 的 `devicetree_parity_verified=false` 表示 Python 未验证该项；DeviceTree 证据来自独立 Swift 日志，不修改原始 JSON。

负例验证将原始未补丁 DeviceTree 作为 `VPHONE_TEST_DT_BASE_OUTPUT_IM4P`，测试按预期退出 1，两个 payload 比较断言失败，证明验收能拒绝未改写输出。日志为 `research/artifacts/c3-full-pipeline-2026-09-10/devicetree-negative.log`；该预期失败不表示生产问题。

C1 新增 `pv-261-c3-bootchain-20260910`，保留旧 `pv-261-parity` 历史条目。

26.3 精确原始样本、其他固件构建的完整组件组合、less 完整流水线以及恢复和启动仍未完成。LLB `patchRootfssBypass` 的必要性仍需运行证据，当前成功命中不能单独证明其必要性。C3 保持进行中，详见 [剩余验收范围](c3_acceptance_remaining_2026-09-10.md)。

## 可复现步骤

以下命令从仓库根目录执行。`fetch` 仅用于首次准备；已有 `stock` 时会拒绝执行，本轮缓存已存在，不再运行该命令：

```sh
.venv/bin/python research/c3_full_pipeline_acceptance.py fetch
```

每次重跑使用全新 run 名。以下以 `acceptance-02` 为例；若该名称已存在，必须换名。`stage` 拒绝已有目录，不能覆盖本轮 `acceptance-01` 证据。

```sh
set -euo pipefail
c3_run=acceptance-02
.venv/bin/python research/c3_full_pipeline_acceptance.py stage "$c3_run"
make build
c3_root="$PWD/research/artifacts/c3-full-pipeline-2026-09-10"
c3_run_dir="$c3_root/runs/$c3_run"
for c3_variant in regular dev jb exp; do
  .build/release/vphone-cli patch-firmware \
    --vm-directory "$c3_run_dir/$c3_variant/vm" \
    --variant "$c3_variant" \
    --report-out "$c3_run_dir/$c3_variant/report.json" \
    --records-out "$c3_run_dir/$c3_variant/records.json" \
    > "$c3_run_dir/$c3_variant/run.log" 2>&1
  .venv/bin/python scripts/check_patch_report.py "$c3_run_dir/$c3_variant/report.json"
done
.venv/bin/python research/c3_full_pipeline_acceptance.py verify "$c3_run"
```

Python `verify` 检查六类二进制；DeviceTree 另用现有 Swift 真实输入测试比较完整序列化 payload。下面同时设置两个输出变量，分别验证 regular 与 exp：

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache"
env VPHONE_TEST_DT_IM4P="$c3_root/stock/cloudos/Firmware/all_flash/DeviceTree.vphone600ap.im4p" \
  VPHONE_TEST_DT_BASE_OUTPUT_IM4P="$c3_run_dir/regular/vm/iPhone17,3_26.1_23B85_Restore/Firmware/all_flash/DeviceTree.vphone600ap.im4p" \
  VPHONE_TEST_DT_EXP_OUTPUT_IM4P="$c3_run_dir/exp/vm/iPhone17,3_26.1_23B85_Restore/Firmware/all_flash/DeviceTree.vphone600ap.im4p" \
  swift test -c release --disable-sandbox --cache-path .build/test-cache \
  --filter DeviceTreeStructuredParityTests
```

内核矩阵设置与命令见 [C3 剩余验收的回归步骤](c3_acceptance_remaining_2026-09-10.md#本轮回归结果)。本轮最终 `make build` 成功；Python 清单测试 14 项通过，Swift `C1AlignmentTests` 与 `FirmwareCompatibilityManifestTests` 共 10 tests / 2 suites，通过耗时 0.046 秒。
