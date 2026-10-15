# Task 8：kernel-only 停机更新与恢复

日期：2026-10-13。

## 实现范围

`FirmwareKernelUpdate.prepare` 只保存预览数据。`publish` 重新取得可信 Store 来源、VM 锁及 worker 锁，并重新校验绑定、desired plan、generation 原件及磁盘摘要。实际 producer 使用 generation 中的内核原件和完整冻结计划；报告保留实际组件结果及声明记录。

候选磁盘位于事务的 work 目录。只有候选 Preboot 以可写方式挂载；System 和 Hardware 保持只读。目标必须是唯一普通 kernelcache 文件。替换复用 `VPhoneKernelcacheSwap`，保留 IM4M。候选内核共享区域由镜像内语义锚点和 Capstone 数据流识别；已安装 DSC 的映射、子缓存引用、UUID、地址范围和 maxSlide 必须通过容量检查。未知布局拒绝更新。

事务使用 schema 3。旧 reader 会拒绝该版本。generation 原件仅作为来源引用，kernel-only 操作不发布 Restore/AVP 根目录。完整 plan 和 digest 保持；执行门只缩小必需声明的组件范围，并拒绝任何非内核记录。每条必需内核声明缺失均拒绝发布。

首次磁盘修改前保存并同步完整原件、候选磁盘、文件身份和变更块位置。每次 pwrite 前保存 pending 状态，并在同一文件描述符上核验磁盘身份、长度和目标块原字节。发布、磁盘回滚、receipt 和 `launchpad.json` 来源提交使用同一 journal。只有 kernel 来源被替换；不生成其他组件 receipt。提交前再次核验来源、计划、磁盘和元数据。

## 恢复范围

未提交事务按持久游标反向恢复。单次 pwrite 的已知前缀写入可恢复；未知字节、磁盘替换、损坏备份或身份变化保留为待恢复错误。已提交但归档失败的事务只验证并归档，不重新运行 producer，也不回滚成功提交。

候选镜像的挂载可由事务恢复过程卸载。若发布后的 `Disk.img` 只读挂载卸载失败，恢复会拒绝写入该磁盘；必须先释放挂载再执行恢复。失败不会被报告为更新成功。

## 审查结果

独立只读审查发现并复核了两项修复：pending 日志保存后的目标替换/修改窗口，以及无需 live origin 即可直接发布磁盘的内部入口。当前实现已移除该入口，并增加写入前文件描述符校验。最终独立只读复审覆盖 launcher 入口、恢复路由、设备选择和卷写入状态兼容，未发现尚未处理的明确问题。复审未独立运行测试，也不是实际 VM 验收。

## 验证记录

区域专项 `region-review-verified.json` 退出码 0，6 项测试通过，包含真实研究内核的 base/size 识别。`task8-final-serial.json` 退出码 0，412 项 Swift Testing 通过；XCTest 5 项中 3 项跳过、0 失败。`bundle-protocol-green.json` 记录 6 项 Python 测试通过。`task8-final-source.json` 退出码 0，最终设备选择及入口修正后的 48 项定向 Swift 测试通过。`task8-platform-readonly.json` 退出码 0，最终平台兼容修正后的 49 项定向 Swift 测试通过。`bundle-protocol-final.json` 的 6 项 Python 测试通过。目录内每份 JSON 记录命令、退出码、源码摘要及日志摘要；是否通过以退出码和日志为准。历史 `region-green.json` 的退出码为 1，不能作为通过证据。

此前 `task8-expanded.json` 并行回归中 worker 故障测试的两个参数用例失败；`worker-io-recheck.json` 单独重跑通过，完整串行回归亦通过。首次失败原因未查明，不能将其直接归因为调度负载。

共享区域的具体镜像、XNU 参考版本、识别过程和分析限制见 `region-review.md`。

## 实际 APFS 设备关联实验

使用 `hdiutil create -size 64m -fs APFS -volname Task8MountProbe` 创建临时镜像，再以 `-readonly -nomount -nobrowse -plist` 连接。返回同时包含 GUID backing disk 和 APFS synthesized disk，证实原先要求仅有一个 `/dev/diskN` 的实现会拒绝该正常布局。实现改为复用 `FirmwareTransaction.detachDevice` 的分区及物理设备关联。

设备列表见 `apfs-probe-attach.plist`；对应 backing device 已成功卸载，结果见 `apfs-probe-detach.log`。实际观察还发现当前系统使用 `WritableVolume` 而非 `ReadOnlyVolume` 表达卷写入状态；校验需兼容两个显式字段，字段冲突或缺失仍拒绝。另一次实验使用 `/sbin/mount_apfs -o rdonly` 在当前用户下成功挂载该临时卷；`diskutil info` 的 `WritableVolume` 为 false，且没有 `ReadOnlyVolume` 字段，随后成功卸载；临时镜像和空挂载目录已删除。证据为 `apfs-probe-mount-attach.plist`、`apfs-probe-mounted-volume.plist`、`apfs-probe-mount-detach.log`。两次较早的创建命令使用了当前系统不支持的 `-type UDRW` 和空白镜像 `-format UDRW` 参数，均退出 1，未生成镜像；删除这些选项后的创建退出 0。该实验没有挂载真实 VM，没有验证 iOS 分卷内容或更新后启动。

## 未验证范围

本轮尚未修改、启动或更新真实 VM。真实 APFS 磁盘挂载、最终签名 Bundle 的更新入口、更新后实际启动及内核回退仍需针对具体冻结工件和 VM 副本验收。离线测试不能据此提升为 Task 8/T34 完整验收。

## 后续真实验收

2026-10-13 用户授权准备最终签名工件和测试副本，开始真实验收。后续过程见 [验收进度](acceptance/acceptance-progress.md)；此前离线测试结论不代表真实启动或回退已通过。

## 真实验收后的磁盘循环内存修正（2026-10-14）

第五版离线更新在 building 阶段 SIGKILL，未发布磁盘关系；正式恢复及六关键文件完整摘要、inode、绑定核验通过。终止原因未查明。

安全合成回归调用真实 capture、validate、publish 和 reverse helper，使用隔离 XCTest 子进程测量 ru_maxrss 增量。capture/validate 输入为 64 MiB+3 稀疏文件、仅尾部变化；publish/reverse 输入为 16 MiB+3 全差异磁盘，并使用无操作 save/afterWrite 回调隔离 helper 内存。四条原路径均复现超阈值增长，逐轮 autoreleasepool 后均通过。发布及恢复的持久化、写入和游标顺序未改，二进制补丁算法未改。最终命令、原始日志、源码摘要和独立审查保存在 `acceptance/capture-memory/`。该合成证据支持临时对象累积修复，不直接证明此前 SIGKILL 原因，也不替代真实磁盘发布与启动验收。

## 候选效果读回索引修正（2026-10-14）

第六版真实更新完成候选与备份准备，首次 commit candidate 的效果检查拒绝；日志为 building，kernelDisk cursor=0、pending=false，正式恢复成功。`verifyEffect` 的最小实际 IM4P/IMG4 回归确认 payload 为非零起始索引的 Data 切片时，旧检查错误解释记录的相对文件偏移。通用检查现从 payload.startIndex 计算区间，保留非负、非空、count 边界与字节相等约束；未修改内核算法或效果规则。

12 个合法输入与 28 个非法效果拒绝场景通过；扩大定向 Swift Testing 汇总 82 项，其中四项真实 fixture 入口跳过，四个独立内存子操作实际通过。独立审查无阻断发现；命令、原始 RED/GREEN、源码摘要和审查记录见 `acceptance/effect-index/`。第七版真实发布和启动结果仍另行记录。

## 第七版真实结果与剩余范围（2026-10-14）

正式完整离线更新和实际发布后中断恢复均通过，独立提交读回与审查通过。实际解码 payload 与基线相同，不能据此认定不同 payload 的更新启动兼容性。正式第四版 host/VM 启动只取得 Framework running，guest 未连接、shell 拒绝；正常启动验收未通过，原因未查明，VM 已正式停止。只读容器对照确认原 PAYP 附加元素未保留和 description 变化，与启动现象的关系待验证。提交后回退入口仍未实现。临时 AMFI 驱动清理曾被精确系统暂停授权阻塞。用户授权后复查，旧目标及 driver/debugserver 均已退出，新 amfid 由系统运行，无需发送暂停或恢复信号。最终无本轮临时进程、挂载或 pending；其余证据见 acceptance/acceptance-progress.md，Task8 保持未完整验收。

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

第九版 `2.6.20261021-local` 已完整构建、签名、打包并正式 Store 安装和复验，之前八版工件保持。计划 A 正式更新退出 0（3240.822 秒），独立实际读回和审查通过。第四版 VM 执行计划 A，guest 查询通过，随后正式停止并通过清理检查。公开列表允许选择 A，拒绝旧第八版；历史选择资格不代替发布时的真实 producer 验证。计划 B 的不同 payload 更新、启动后 marker、回退 A 及第三次启动仍待完成，尚不认定真实回退通过。

本轮第四版预检退出 -9，原因未查明。既有固定 CDHash 的一次临时 AMFI 驱动实际完成两个钩子、删除断点、detach 并退出 0，无额外暂停或持久配置。root 正式重绑产生的 root:wheel/0600 绑定文件导致当前用户读取失败；仅恢复测试副本绑定文件的原用户属主，0600、inode 和内容摘要保持。详见 `acceptance/kernel-v9-plan-a-host4-binding-owner-check.json` 和 `kernel-v9-plan-a-amfi-once.log`。

## 2026-10-14 第九版 B 提交、启动及回退准备

B 事务 `2901d975-2379-4b50-9340-8580786aacc1` 正式更新退出 0、3389.396 秒，独立实际读回退出 0、110.513 秒。实际 payload `a89e2e786dc61d93b14ea129072bc762594ca4cd1f54719810ea1cbf99c0e2c0` 与 A 的 `d2b90150…` 不同；原 description、PAYP、IM4M 和 envelope 保持。六文件身份及其他五文件内容保持，独立提交审查通过。

B 首次 guest 观察 361.804 秒超时，无 VM target/socket，原失败保留。采样定位宿主 preflight 等待；原固定驱动虽记录 Detach(False)/CLEANUP_DONE，同 amfid95240 实际仍为 SSTOP4/xstatus17、非 traced。严格核对同 PID/path/UID/PPID/start 后仅发 SIGCONT，状态恢复运行，原正式 launch 继续，第四版 guest 系统查询通过。detach 后仍停止原因未查明。补充观察使用新标签 `kernel-v9-plan-b-resumed`，原/新 boot expectations 原始摘要一致；0.355 秒仅为补充观察时间，不是完整启动耗时。742 字节唯一 guest 标记实际创建及 file_get 读回通过，正式停止、清理和独立启动审查通过。

公开回退列表及预览允许明确选择 A 事务 `c0a0a7a8-3677-4a44-aa36-f370bb67b5ca`，旧第八版因缺少回退协议证据拒绝。当前 B 启动及标记后的六文件摘要已冻结，Disk.img 与 B 离线提交摘要不同。正式 `vm rollback-kernel --to-transaction` 正在执行，current desired B 保持；尚未确认回退提交、第三次启动或标记保留。性能[只读分析](acceptance/kernel-rollback/performance-analysis.md)已保存；未修改冻结 V9 以降低校验。


### 2026-10-14 回退 A 与独立性能工作覆盖状态

第九版公开回退 A 正式提交退出 0（4370.196 秒），独立实际读回（115.825 秒）及第四版 guest 启动通过；目标 A kernel 的 IMG4/IM4P/payload/119 条记录匹配，live desired B 保持。原 tmp 标记回退后 file_get 返回 ENOENT，数据保留验收未通过，原因未查明。新 Documents 标记已显式 sync 并同实例实际读回，正式停止及清理通过；停机落盘和跨回退保持仍待验证。旧失败证据保留。amfid 残留停止问题单独跟踪，回退 A 后实测已运行且未发送恢复信号。

用户授权独立优化工件先增加分项计时，再验证 capture/validate 的约 1 MiB 读取等价性和收益。冻结 V9、原 Task 8 工件及 AMFI 范围保持，不热替换、不在验收磁盘运行竞争性基准。SHA 合并、摘要/比较融合和 metadata 重验跳过均后置单独设计审查，不预先认定语义等价。见 `research/evidence/2026-10-14-kernel-io-performance/execution.md`。保留现有未提交修改，未提交 Git。
