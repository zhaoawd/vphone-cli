# Task 8 kernel-only 回退源码与需求独立审查

结论：本次冻结实现未发现阻断项，可进入第九版完整构建、签名及限定范围真实验收。此结论是源码和既有证据审查结果；不同 payload 正式发布、提交后回退、回退后正常启动及 marker 保持仍待验收。

冻结时间为 `2026-10-14T03:31:38.166905+00:00`。manifest 的 16 个源码/测试文件、23 个证据文件、3 个输入文件均逐项核对 size 与 SHA-256，一致。审查未改生产或测试，未构建签名工件，未运行 VM、挂载、guest 或 AMFI。已通过的定向回归未重复运行。

| 对象 | 审查结果 |
| --- | --- |
| producer 来源与锁 | public publish 重新取得 Store → VM → worker；实际运行 executable 与 verified source 相同，Session 在回调结束失效。Store/代码摘要在作用域内复核。worker 覆盖实际生产、candidate、发布、读回、origin 提交和归档 |
| 同 producer 资格 | 历史 producer version 与绑定来源一致，实际 Session executableSHA 与历史目标一致；pristine 有序记录重建必须等于本次真实 payload，且完整 kernel Gate 通过 |
| schema 4 双计划 | targetDesired 决定实际 journal plan/options/receipt；liveDesiredSHA 独立作为当前 CAS。bindingSHA 与真实 InstalledOrigin.expected 关联，actual binding 在发布各阶段检查；schema/selection 不匹配拒绝 |
| VM/generation/catalog/非内核选择 | stable identity、generation 原件、当前 catalog、固件 gate 上下文及全部非内核选中/排除/enabledSteps 保持，不能通过换历史 plan 绕过 |
| 历史 reader | canonical UUID、普通目录/无额外硬链接文件、committed journal/report/receipt/proof/artifact/effects 关联完整。读取历史目标不要求启动后 live Disk 等于旧整盘摘要。历史数据不能构造 Session 或 InstalledOrigin |
| 当前磁盘发布 | candidate 从本次开始的 current Disk 克隆并核对整盘摘要，仅写唯一普通 Preboot kernel；当前 IMG4 外部 envelope、完整 IM4P、payload、effects 和当前 System DSC 在 candidate/published 读回复核 |
| metadata | replacement 使用本次 verified pristine input，保留 raw description/PAYP，拒绝未知或不一致 metadata。当前 IM4M/IM4R 原字节保持；不据此认定签名或启动适用性 |
| 回退自身恢复 | 复用 durable cursor 与 Disk 身份。未提交恢复返回本次开始的 Disk/binding/receipt；已提交恢复仅校验与归档。不重跑 producer、不回写历史 desired。未知外部 Disk 修改保留 pending 并拒绝 |
| CLI 与 launcher | 公开 list/preview/明确 canonical UUID；list 标明 selection-only。sealed launcher 校验独立 rollback marker 并在 verified callback 内运行实际 Store CLI；原正常 launch 路线保持 |
| 旧 v8 与跨 Bundle | 旧 v8 缺新证据合同拒绝；另一 producer version/code 拒绝。Bundle marker 是路由能力声明，没有实现跨 Bundle producer-only 子进程协议 |
| 普通 schema 3 | rollbackSelection 缺失时保留原 schema 3 desired 相等校验、publisher 和恢复路径，定向正常更新与共享事务回归通过 |

最终定向证据为 101 个选中函数、13 个 suite、112.116 秒、退出 0；98 个执行通过，3 个跳过：`actualPublicForceExcGuardPlansProduceDifferentPayloads`、`actualCandidateRegionUsesSourceFlow`、`actualPristineMetadataRestoresBaselineContainerExactly`。rollback 套件实际执行 9 个函数、34 个场景，90.820 秒。Python Bundle protocol 7 项通过。实际两计划 producer 与当前 System DSC 已在独立证据中单独通过，不把该结果改记为本次定向 suite 的跳过项通过。

故障覆盖包括：启动后非内核 sentinel 保持；desired/binding/Disk/history/代码变化；callback 失效；实际输出中未解释修改；必需记录缺失；Disk 写入、receipt、binding、commit、archive 及 desired CAS 中断；全部摘要自洽的伪造历史；跨 VM/非内核选择/链接/UUID；schema 4 双计划；编码 artifact；envelope 变化及未知外部磁盘写入。合成测试替代 Store/签名 verifier、补丁算法、region 揭示及挂载适配，继续执行生产 Session 重建、声明、容器、DSC parser、磁盘块发布、origin、receipt 和恢复逻辑。实际 signed Store 发布和启动证据仍需独立建立。

非阻断事项：list 的 eligible 明确只表示历史选择资格，不是发布权限；当前 CLI 不直接显示相同内容目标的 before/after payload 比较，最终验收须依据实际摘要，不按新事务或成功消息推定内容改变。generation 重核验会重复读取原件，真实回退耗时尚未测量。

后续必须完成：冻结并复验第九版可信工件；正式 A/B 不同 payload 提交和实际 Preboot 读回；三次授权第四版正常启动；从启动后的 current Disk 公开 UUID 回退到 A；离线六文件、非内核来源和 live desired 比较；回退后新实例读取 B 写入的唯一 marker。marker 只证明该项数据保持，不证明全部 guest 文件系统不变。

冻结文件摘要、逐项需求对应及测试范围见同名 JSON。
