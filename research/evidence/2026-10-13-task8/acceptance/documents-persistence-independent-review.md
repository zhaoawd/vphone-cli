# Documents 持久性证据工具独立审查

结论：Verifier 在本轮静态审查和 18 个纯测试覆盖范围内未发现新增阻断。freeze helper 存在前置条件校验缺口；修正和纯负例验证完成前，不应使用该 helper 写入 boot expectations。该结论只针对工具，不确认跨 R_B 的真实读回、启动、marker、停止或清理已经完成。

审查只读取 `verify-documents-persistence.py`、`test-verify-documents-persistence.py`、`freeze-documents-rollback-b-boot.py` 和纯测试使用的已保存小型证据文件。没有运行 verifier 主入口或 freeze helper，没有读取 VM 当前状态、磁盘、Store、进程或 AMFI。没有修改源文件或测试文件。

## 问题

1. `freeze-documents-rollback-b-boot.py` 只要求 `rebind` 和 `owner` 的 `passed` 为 true，并比较 `after.binding` 及部分摘要。它没有验证正式 host4 的 command、target_version、before→after 的 binding 变化范围与 receipt/desired/journal/proof 不变关系；没有核对 owner 的 rebind_label、uid/gid/mode/inode 合同。最终 verifier 的 `validate_rebind` 包含这些门，但 helper 不调用该验证。因此，helper 的现有条件不足以保证只有满足完整 formal host4/owner 合同后才写 expectations。应在执行 helper 前补全同等校验，并增加缺失或错误 command、target_version、owner label/属性和被改变元数据的纯负例。
2. helper 使用 Python `assert` 作为全部前置门。`python -O` 或非零 `PYTHONOPTIMIZE` 会移除这些门。当前未观察到正式执行使用优化模式；这是源码中的条件性缺口。应改用显式异常校验，或使正式执行入口明确拒绝优化模式。现有 18 个测试没有导入或模拟执行 helper，不能作为这两个问题已验证的依据。

以上问题不表示正式 host4/owner 证据已经错误，也不推断当前 VM 状态；它们说明 helper 的代码门未完整强制任务要求。

## 已核对的 Verifier 边界

- 输入限定固定证据根目录下的普通、单链接、有限大小文件。逐级 `O_NOFOLLOW` 打开，检查 fd 与路径的设备、inode、大小、时间、模式和链接数；缓存首次快照，退出前重新读取全部已使用输入。JSON 拒绝重复键、NaN 和 Infinity。输出使用 `O_EXCL`，不覆盖旧证据。
- 原 Documents create 和旧 tmp 失败分别使用固定 SHA256。create 的 intent、UUID 路径、canonical 内容、1254 字节和固定 marker SHA 与 actual file_get 全字节绑定。六个实际请求限定 capabilities、sync 探测、no-clobber create、显式 sync、file_get、capabilities，并核对原始 stdout/response、目标实例和 shell 结果。
- 原 create 关联 A 的正式 boot、expectations 和 committed receipt。后续 read 只允许 capabilities/file_get/capabilities，不允许创建或 sync；其完整字节与原 create 相同。实例 UUID 必须不同，process_started_at 递增；跨 R_B 还要求与原 create、同 A reboot 三个实例均不同且顺序递增。
- 正式公开 rollback command 精确要求 frozen V9 CLI 和历史 B transaction；拒绝 preview、recover、list 或不同目标。schema4 的 operation、target、live desired 和 binding 双 CAS、trusted producer/version/executable、committed cursor 与原始/候选盘摘要、receipt/report/proof 原始 JSON 摘要链和 saved actual readback 相互绑定。
- 历史 B 的 payload 固定且与 A 不同，R_B 实际 readback 必须与 B 的 payload、IM4P、IMG4 和 envelope 字段对应。targetEvidenceSHA256 由历史 journal/report/receipt/proof 和 IM4P 摘要重新构造。live desired B 保持，source9 rebind 及最终 host4 rebind/owner 的正式合同由 verifier 核对。
- 最终 boot 的 actual command 限定 V4 VM 路径、目标 config、binding SHA 和 no-vphoned-update；成功 capabilities 与 guest state 要有实际 command/stdout 证据。正式 stop 日志须对应接受的实例 UUID/PID，launch 日志须有 graceful stop。cleanup 检查无进程、挂载或 pending、源六文件 metadata、测试六文件身份和静态 config/ROM 摘要。
- 缺失最终证据返回 pending 且 passed=false；输入不符返回 refused。旧 tmp ENOENT 记录必须保持原 SHA 和 passed=false。输出明确不改写、不运行、不宣称通过历史 V2 join。Verifier 不自行重跑 DSC 或读取磁盘；实际内容判断范围依赖正式 producer/commit 和已保存 readback 的证据。

## 纯测试结果与证据

独立运行 18 个既有测试，全部通过，用时 0.789 秒。外层在模块导入前屏蔽 `subprocess.Popen/run/call/check_call/check_output`、`os.kill/killpg/system/posix_spawn/posix_spawnp`，测试内部还单独屏蔽子进程和信号入口。测试只使用内存中的合成最终 R_B 证据、已保存小型前置文件和临时普通文件；没有产生真实最终 R_B 通过记录。

测试覆盖 actual file_get 字节、旧失败保留、原 create/intent 和 provenance、只读请求、实例和顺序、committed/public target、双 CAS、guest 错误与超时/截断、stop/cleanup、rebind、输入稳定性、JSON/路径/链接和输出独占。测试中的完整合成 fixture 通过，只说明被测证据合同能够接受该内存构造；不能替代真实跨回退验收。

日志为 `documents-persistence-independent-tests-01.log`，结构化审查为同名 independent-review JSON。三个工具源码 SHA256 和日志 SHA256 均保存在 JSON；旧工具、旧失败和既有审查未覆盖。
