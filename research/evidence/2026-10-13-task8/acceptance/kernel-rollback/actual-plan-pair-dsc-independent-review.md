# 两计划实际 payload 与当前 System DSC 证据独立审查

结论：现有 V2 证据足以支持两个 EXP 计划实际产出不同 payload，且各自通过完整 kernelGate、记录重建、shared region 检查和当前 System DSC 校验。该结论限定于实际文件及只读 DSC 校验；可信 Store 发布、schema 4 回退和新 payload 正常启动尚未验收。生产实现尚未最终冻结。

| 实验设置 | forceExcGuard=false | forceExcGuard=true |
| --- | --- | --- |
| payload SHA-256 | `d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb` | `a89e2e786dc61d93b14ea129072bc762594ca4cd1f54719810ea1cbf99c0e2c0` |
| IM4P SHA-256 | `b1f07780484d9dc88f989d6e236049050b38e50a1ddb94030dcecaed43f962db` | `ecbea551116fbb2d10b0196d72ecd7f52f8f145b5ecd7632159c0025fb78bf98` |
| plan SHA-256 | `703f9ad46613fa819ec6460846865ba9cd3ccd389f4b03c078fbc9baae741a3c` | `bb37c956b2bce344b65c6ca3fdea77065d9713f539f4a761823c2c8e5369e96c` |
| 记录数 | `119` | `120` |
| sharedRegionBase | `6442450944` | `6442450944` |
| sharedRegionSize | `6442450944` | `6442450944` |
| DSC | `passed` | `passed` |

输入 IM4P SHA-256 为 `b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac`。test 实际调用 `reproduceInstalledComponentReport`，执行 `PatchDeclarationGate.enforceKernel`。每条记录核对原件当前字节，按报告顺序应用，并核对最终 effect；完整重建必须等于实际产出 payload。随后检查实际 kernel region，再调用生产 `FirmwareKernelDSC.validate`。记录条数仅作结果信息，不用于推定 payload 不同。

V2 test 退出 0，耗时 97.670067 秒，日志显示 Swift Testing 实际执行 1 test / 1 suite 并通过。日志前面的 XCTest 0 tests 不表示该 Swift Testing case 跳过。pair JSON 与 mount JSON 内嵌 pair 完全一致。

只读 System 来自 task8-copy 的 Disk：`/dev/disk10s1` physical store 对应 `/dev/disk12s1` System-role volume，VolumeUUID 为 `61706673-7575-6964-0001-766F6C756E00`。driver 持有 VM 目录排他锁，执行 readonly/nomount attach 与 rdonly mount；test 前后断言 readonly、相同 MountPoint/UUID。finally detach disk10，检查无 task8 附件和两个 pending 标记，并核对 Disk 的 dev/inode/size/mtime/ctime 五项一致。此处没有重新计算完整 Disk SHA-256。

首次失败保留为 exit 1、`Component receipt: output escapes publication root`，附件已清理且 Disk 五项 metadata 保持。后续实际路径诊断有 84 行 Foundation URL 输出，均显示 `/private/tmp/...` 经 standardized/resolved 转为 `/tmp/...`；对应 Python filesystem 检查中三个路径均非 symlink。V2 仅在 fixture 调用前规范化 System URL。生产 relative 路径门保持原有检查，DSC validator 未改动。路径诊断自身不计作 DSC 通过证据。

该 test 在测试二进制中调用实际 producer；未经过可信已安装 Bundle 的签名、资源闭包与 installed-origin session。不同 payload A/B 的正式发布、回退 A、三次 V4 启动及 guest marker 保持仍须后续联合验收。本次审查没有重复 mount/test，也未操作 VM、guest 或 AMFI。

证据与所读源码的完整 SHA-256 记录在同名 JSON。
