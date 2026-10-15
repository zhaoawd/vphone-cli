# Task 8 提交后 kernel-only 回退验收设置

2026-10-14。第八版 metadata 修复已经实际提交、独立读回和第四版 guest 启动验证通过。不同 payload 更新及提交后回退尚未通过。以下是后续执行设置，不是结果。

操作限定于 `/private/tmp/vphone-task8-acceptance-vms/task8-copy`。源 `vm-new` 不启动、不挂载、不写入。所有未提交修改与第一至第八版工件保留，不提交 Git。新第九版仅执行可信离线 CLI；实际 VM 始终为已授权第四版完整 Bundle 的 `vphone-vm`。新 VM CDHash 不放行，不修改 TCC 或持久 AMFI 配置。

| 顺序 | 操作 | 所需结果与证据 |
| --- | --- | --- |
| 1 | 回退实现、故障回归与独立审查 | 公开 UUID 目标、schema 4 双计划关系、可信 producer 重算、Store → VM → worker、当前磁盘候选、非内核来源与当前 desired 保持；普通 schema 3 不变 |
| 2 | 第九版完整构建、签名、打包、冻结、Store 安装与复验 | 来源与资源闭包核验；第一至第八版工件和源码改动清单保留 |
| 3 | 正式提交计划 A | 相同 generation/catalog/固件上下文；kernel 来源为第九版；保存明确事务 UUID、实际 IM4P/payload 与 receipt/proof/报告关系 |
| 4 | 正式 host 重绑第四版并启动 A | 冻结 binding/receipt 摘要、核对实际 V4 argv 与目标 PID/instance、guest capabilities 和绝对路径 uname/sysctl 严格成功；正式优雅停止 |
| 5 | 正式 desired-plan CAS 只调整内核选项并提交 B | 优先验证已有 force-exc-guard 选项；实际生产 payload A/B 摘要必须不同，DSC 兼容性及完整必需声明通过。不能从选项名称或记录条数推定字节不同 |
| 6 | 第四版启动 B 并写唯一 guest marker | 状态查询成功；创建 `/private/var/tmp/task8-kernel-rollback-<uuid>`，立即 file_get 实际字节并计算 SHA-256；保存 B 的绑定、receipt、计划、PID/instance 和内容；正式停止 |
| 7 | 公开 list/preview/明确 UUID 回退 A | 从启动后的当前磁盘创建候选，只替换 Preboot 内核；保存回退前后六宿主文件摘要/身份和 guest 关键文件对照、新事务、目标 UUID、实际内核与非内核来源。当前 desired B 保持，不逆转历史整盘 |
| 8 | 第四版启动回退后的 A | 新 PID/instance 对应新启动；guest 状态成功，file_get 相同 marker 字节/SHA 保持；离线目标内核与 A 一致。正式停止并核对清理和源六文件元数据 |

新回退事务自身中断恢复返回该次回退开始状态。旧第八版缺少 producer-only 实际输出协议，初版不凭历史 JSON、备份或版本字符串取得资格。不把 `--recover`、相同 payload 重新发布或仅元数据变化计作不同 payload 回退。

独立读回验证实际 Preboot、IM4M/IM4R 保留、原 description/PAYP、IM4P/payload 与 proof，及 archive/receipt/report/generation/来源关系。DSC 若仅由正式生产校验建立，应明确该证据范围。正常启动会更新 Disk/NVRAM/SEP；宿主文件的离线回退边界与启动后观察分别记录。marker 保持仅证明该项 guest 写入未丢失，不能单独证明全部文件系统保持。

通用取证工具 `watch-boot-v4-rollback-acceptance.py` 与 `guest-rollback-marker.py` 尚未执行，需独立审查。每轮使用新 label 和冻结期望文件，不覆盖历史失败记录。第八版旧 watch 因默认 PATH 命令未找到而失败，其绝对路径补充证据已通过；后续直接使用经过实际确认的 `/var/jb/usr/bin/uname` 和 `/var/jb/usr/sbin/sysctl`。
