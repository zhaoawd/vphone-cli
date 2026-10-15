# 命令与证据

所有 Swift 命令均使用独占 scratch，`--force-resolved-versions --no-parallel`，未构建签名 Bundle。本子任务没有操作真实 VM、挂载或 AMFI。根任务独立管理 DSC 临时只读挂载，其脚本与清理记录在本目录。

共同前缀：

```sh
PYTHONDONTWRITEBYTECODE=1 CLANG_MODULE_CACHE_PATH=$PWD/.build/test-module-cache SWIFT_MODULECACHE_PATH=$PWD/.build/test-module-cache swift test --disable-sandbox --scratch-path /private/tmp/vphone-five-tasks-swift-20261012 --cache-path $PWD/.build/test-cache --force-resolved-versions --no-parallel
```

- `--filter 'routesExplicitCommittedKernelRollback|permitsExplicitCommittedKernelRollbackRoute'`：`route-red.log` 首次因测试缺少 Foundation import 编译失败；修正测试后 `route-red-valid.log` 在真实 CLI/launcher 路由失败，构成有效 RED。`route-green.log` 同两项通过。
- `--filter FirmwareKernelRollbackTests`：`behavior-01.log` 为初步 3 项函数、15 个场景通过；后续矩阵见最终定向日志。
- `--filter actualPublicForceExcGuardPlansProduceDifferentPayloads`，增加 `VPHONE_TEST_ROLLBACK_PRISTINE=/private/tmp/task8-pristine-kernel.im4p`、`VPHONE_TEST_ROLLBACK_INPUT_SHA256=b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac`、`VPHONE_TEST_ROLLBACK_PAIR_OUT=$PWD/research/evidence/2026-10-13-task8/acceptance/kernel-rollback/actual-plan-pair.json`：`actual-plan-pair-01.log` 因 fixture 的 guestEnvironmentV2=nil 与实际 false 不同被 producer 拒绝，尚未执行补丁；显式 false 后 `actual-plan-pair-02.log` 通过，JSON 记录两组实际不同 payload，未提供 DSC fixture。
- 根任务同 filter 增加 `VPHONE_TEST_ROLLBACK_DSC_SYSTEM=<只读System根>` 并采用独立输出路径。`actual-plan-pair-dsc.log` 首轮路径校验拒绝，原始 `/private/tmp` URL 与 Foundation standardized `/tmp` URL 不同；`dsc-path-diagnostic.json` 仅证明路径诊断。只规范化 fixture URL 后，`actual-plan-pair-dsc-v2.log/json` 通过。对应 `*-mount.json` 保存只读关联、退出码、卸载和磁盘元数据核对；未覆盖首轮失败。
- 最终定向：`--filter 'FirmwareKernelRollbackTests|FirmwareKernelUpdateTests|FirmwareKernelOrchestrationTests|KernelcacheMetadataTests|KernelcacheSwapTests|FirmwareComponentEffectIndexTests|FirmwareInstalledOriginTests|FirmwareInstalledReadbackTests|FirmwarePlanBindingTests|FirmwareTransactionTests|KernelUpdateCLITests|LauncherPolicyTests|LaunchRouteTests'` → `targeted-01.log`。
- `PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -m unittest discover -s tests -p test_bundle_validation.py -v` → `bundle-protocol-python.log`，7 项通过。

最终计数、退出码、失败保留和源码摘要见 summary.json/manifest.json。Swift Testing 汇总按测试函数计数；参数化场景另列，避免与函数数混淆。fixture 跳过项及真实回退/启动未验证范围单独保留。
