# Task 8 真实 VM 验收进度（2026-10-13）

用户本轮授权准备最终签名工件、测试 VM 副本，并验证内核更新、启动和回退。所有测试 VM 操作限定于 `/private/tmp/vphone-task8-acceptance-vms/task8-copy`；源为工作区 `vm-new`。

## 当前状态（2026-10-14 第九版 A/B 和回退 A 启动通过，数据保留验收未通过）

- 第八版无注入更新已正式提交，退出码 0，用时 3430.296 秒，事务 `2b52edcf-ac9b-4515-bb80-338d94bcbd2b`。`committed-readback-v8.json` 与 `v8-commit-independent-review.md/json` 验证 journal、receipt、proof、报告、实际 Preboot 和磁盘摘要关系通过；六文件 inode 保持，更新时其他五文件内容保持，无 pending 或挂载。
- 实际完整 IMG4 恢复为基线摘要 `5b90c5a0ee87bf810c7e90795d537265f39774fbf85c430263fd2f61fc41ce7a`。原 description、315 字节 PAYP 和 IM4M 保留。解码 payload 仍为 `d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb`，不能计为不同 payload 更新验收。
- 正式重绑为 host `2.6.20261016-local`、kernel `2.6.20261020-local`，receipt/proof/journal 保持。只执行已授权第四版 VM；本轮 `--help` 直接退出 0，没有启动临时 AMFI 驱动，没有扩大授权。
- 第四版 VM 实际启动通过 guest 状态验证，PID `22914`，实例 `D46D87C2-A877-4348-BA7F-A9410522C493`。guest 已连接，使用实际绝对路径执行 `uname`/`sysctl`，返回 `Darwin 25.1.0`、`iPhone17,3`，code=0，无超时或截断。证据为 `boot-v8-guest-state-absolute.json`；实际 argv 与绑定摘要见 `boot-v8-guest-command-discovery-retry.json`。
- 原 `boot-watch-v4-kernel-v8.json` 保留 passed=false：guest 已连接，但默认 PATH 不包含 `/var/jb/usr/bin` 和 `/var/jb/usr/sbin`，探针的两个命令返回 127。绝对路径查询补充成功，不覆盖原失败结果。description 和 PAYP 同时恢复；本次启动通过不能单独确定 PAYP 是前次启动异常的原因。
- 正式停止退出 0，用时 4.675 秒，日志记录 guest 优雅关机。`post-boot-v8-cleanup-v2.json` 验证无本轮 VM/临时驱动、无挂载或 pending，binding/receipt 保持；源 VM 六文件 device/inode/size/mtime/ctime 保持。未重新计算源 VM 全量内容摘要。第一次清理探针因裸历史 PID 已复用而误判，失败记录保留；v2 按实际命令身份核对，未向该进程发送信号。
- 暂停事务恢复及读回已通过，见 `kernel-update-v8-pause-recovery-readback.json`、`v8-pause-recovery-independent-review.md/json`。暂停时游标 0，不能作为写入后恢复证据；此前第七版实际发布 5 块后的中断恢复证据保持。
- 提交后 kernel-only 回退现已开始实施及回归。候选基于当前启动后的磁盘，只替换内核；目标须重新取得真实 producer 资格。初版限定同可信 producer、同 generation/catalog/版本上下文的不同内核计划，保留当前 desired 和非内核来源。旧第八版缺少 producer-only 实际产物协议，不能仅凭历史 JSON 或备份取得回退资格。
- 两组真实 EXP 计划已经证明 payload 不同，并在只读测试副本 System 上通过实际 DSC 校验：false 为 `d2b90150…`，true 为 `a89e2e78…`，完整记录重建与实际产物一致，区域均 6 GiB。`kernel-rollback/actual-plan-pair-dsc-v2-mount.json` 记录测试退出 0、只读关联和最终卸载/磁盘元数据保持；首次测试参数/路径失败保留。此项不计正式 Store 提交或两组实际 VM 启动。
- 回退实现已冻结并通过独立代码/需求审查：16 项源码/测试摘要匹配，schema 4、真实同 producer 资格、当前磁盘候选、双计划 CAS、envelope 保留、恢复边界及公开/launcher 路由对应要求。定向 Swift 为 98 通过/3 fixture 跳过，新回退 suite 覆盖 34 场景，Python Bundle 协议 7 通过。第九版已完整签名冻结；实际回退尚未执行。
- 第九版完整签名工件已冻结、正式 Store 安装和复验通过。计划 A 更新退出 0，用时 3240.822 秒，事务 `c0a0a7a8-3677-4a44-aa36-f370bb67b5ca` 已提交。`kernel-v9-plan-a-readback.json` 和独立审查通过：实际 Preboot、归档 IM4P、proof、receipt、报告、原件记录重建和容器字段相符，六文件身份保持，其他五文件内容保持，无 pending 或挂载。计划 A payload 为 `d2b90150…`，与此前基线相同；不能计为不同 payload 更新。
- 公开 `rollback-kernel --list --json` 已将本次 A 事务列为可选择目标；旧第八版事务因缺少所需回退协议证据而拒绝。该结果仅证明历史选择资格，发布仍须重新验证 producer。
- 正式 host 重绑第四版后，kernel 来源仍为第九版，receipt/desired/历史证据保持。root 执行绑定产生的 root:wheel、0600 文件导致用户读取失败；已仅恢复测试副本 `launchpad.json` 的用户属主，权限、inode、内容摘要保持。证据为 `kernel-v9-plan-a-host4-binding-owner-check.json`。
- 第四版 `--help` 预检退出 -9，原因未查明。随后使用既有固定 CDHash 的一次临时 AMFI 驱动，两个匹配钩子完成、断点删除及 detach 均成功，驱动退出 0（24.987 秒），没有额外暂停、持久配置或授权范围变更。实际第四版 VM PID14713、实例 `BF494884-1005-4FDB-8504-C14DA034354D` 在约 61 秒连接 guest，严格系统查询通过；正式停止退出 0、7.016 秒，cleanup 通过。独立审查见 `kernel-v9-plan-a-boot-independent-review.md/json`。
- B 首次公开 desired-plan 预览因根目录缺少 Restore 输入而退出 1，未发布。随后完整复制可信 generation 原件 Restore 树；源前后与候选目录摘要均为 `a3712fa7…`，两个 manifest 摘要单列，六文件元数据、generation manifest、binding/receipt/desired 保持。正式预览重跑及 CAS apply 均退出 0，B plan 为 `bb37c956…`，新 desired 摘要 `3ad404b6361d1989bda18be961ce72d1415f6e84025138ec6623bc0578aad949`，非内核选择与上下文保持。证据见 `kernel-v9-plan-b-restore-input-check.json`、`kernel-v9-plan-b-desired-preview-check.json` 和 `kernel-v9-plan-b-desired-apply-check.json`，独立输入审查通过。B 六文件完整快照已冻结（51.520 秒），正式 `vm update-kernel` 正在执行；尚未认定 B 已提交。
- B 事务 `2901d975-2379-4b50-9340-8580786aacc1` 已正式提交，退出 0、3389.396 秒；独立实际读回退出 0、110.513 秒。实际 Disk 为 `df1f5f4f…`，IMG4 为 `744be24e…`，IM4P 为 `ecbea551…`，payload 为 `a89e2e78…`，符合冻结 B 并与 A 不同。原 description/PAYP/IM4M/envelope 保持，六文件身份和其他五文件内容保持，无挂载或 pending。候选与正式提交/物理读回分别独立审查通过，见 `kernel-v9-plan-b-commit-independent-review.md/json`。
- B 第一次 guest 观察在 361.804 秒超时，始终没有 VM target/socket，失败文件保留。CLI 采样定位为等待宿主 preflight，尚未启动 VM。固定一次驱动虽报告 Detach(False)/CLEANUP_DONE，实际同一 amfid95240 仍为 SSTOP4/xstatus17、非 traced。严格核对 PID/path/UID/PPID/开始时间后仅发送 SIGCONT，状态恢复为运行，没有新增暂停、attach 或放行范围。恢复后预检及原正式 launch 继续执行；具体为何 detach 成功仍停止，原因未查明。证据为 `kernel-v9-plan-b-amfi-resume-check.json`。
- 补充观察 `kernel-v9-plan-b-resumed-boot-watch.json` 已通过，实际第四版 VM PID35061、实例 `CC65D525-3CE7-41F4-83A8-937095907BD7`，guest 系统查询 code=0，无超时/截断。0.355 秒为补充观察耗时，不是完整启动耗时。742 字节唯一标记已写入并实际 file_get 读回，SHA-256 `2f30a9afeae97959ee833db90f12cdd0b4c22c932257e1d8f689ce5b5958162f`。正式停止退出 0、5.777 秒，`kernel-v9-plan-b-resumed-post-boot-cleanup.json` 通过。补充观察使用新标签，未覆盖首次失败。
- 用户提出耗时问题后，已完成冻结 V9 的只读[性能分析](kernel-rollback/performance-analysis.md)。一次 published 来源验证含 5 次整盘摘要，commit 成功路径静态推导 41 次完整摘要、39 轮 generation 验证；完整命令路径的逻辑读取下界约 3.75 TiB。该计数不代表 SSD 物理 I/O 或全程实测占比，未实施优化。当前开始公开回退准备，目标为实际 A UUID，当前 desired B 保持。
- 公开回退 A 事务 `58597f0a-e94c-4f69-86af-b0fdfa9fd3f3` 已进入 schema4 publishing，49/49 个变更块、pending=false；仍待发布后校验及正式提交。最初用户态观察器漏 sudo，对 root:0700 目录的 Path.exists 误报不存在，原记录保留且不作为阶段证据。已改为 root 只读观察器，`kernel-v9-rollback-a-observer-permission-correction.json` 记录纠正；该工具权限错误未中断或重启正式回退。
- 公开回退 A 已正式提交，退出 0、4370.196 秒，独立实际读回退出 0、115.825 秒。schema4 事务 `58597f0a-e94c-4f69-86af-b0fdfa9fd3f3` 恢复目标 A 的 IMG4/IM4P/payload 与 119 条有序记录；当前 desired B 保持。独立提交审查通过。第四版 VM 实例 `F8D80EFD-9D81-43E3-8103-E8B1D0910C34` 启动及严格 guest 系统查询通过。
- 回退 A 后，原 `/private/var/tmp/task8-kernel-rollback-682d8cbe-429b-4c4a-95fb-e6dfa945aa35` 的 file_get 返回 ENOENT。旧标记缺失原因未查明，数据保留验收未通过；原创建流程没有显式 sync，这一事实尚不能解释缺失。旧失败文件保持。
- 新 v2 工具经 11 项纯模拟及独立审查，在当前回退 A guest 的 Documents 写入唯一标记，实际 `/var/jb/usr/bin/sync` 成功并读回 1254 字节，SHA-256 `a8faa4e5b805fd5a0ee0f8330296d168bb85f33c674748595d176df3714e418e`。此结果仅证明同一次启动内创建与读回，不证明跨回退保留。正式停止退出 0、4.537 秒，launch 退出 0，清理通过。待只读比较回退前备份、候选与当前 UserData，分别记录旧标记位置和新标记落盘。
- amfid 停止问题独立跟踪：B 的残留停止已严格同身份 SIGCONT 恢复，原因未查明；回退 A 临时驱动退出后实测同一 amfid 已运行，外部检查 `signals_sent=[]`。未新增暂停或放行范围。
- 用户已指定独立性能工作顺序：先分项计时，再验证 capture/validate 的约 1 MiB 读取等价性及收益。隔离源码为 `/private/tmp/vphone-kernel-io-optimization-20261014`；冻结 V9、当前 Task 8 工件保持，不热替换，不在验收磁盘运行基准。SHA 合并、比较与摘要融合、跳过 metadata 重验均后置单独设计和审查。
- Task 8/T34 尚未完整验收：不同 payload 更新、提交后公开回退 A 及启动已通过；数据保留验收仍未通过。保留所有未提交修改，未提交 Git。

## 此前状态（历史记录，由当前状态覆盖）

- 暂停事务正式恢复退出 0（507.386 秒）。`kernel-update-v8-pause-recovery-readback.json` 独立全量读回通过：六文件内容、inode、device、size 与暂停前快照一致，绑定、receipt 保持，同一归档事务 reverse/游标 0/pending=false，无挂载或 pending。暂停前游标为 0，不能将本次恢复记为磁盘写入后中断恢复；此前 v7 的实际 5 块发布恢复证据保留。第八版 Store 再次复验退出 0。新的无注入完整更新正在运行，使用 `kernel-update-v8-resumed.log/json` 和独立观察日志，旧暂停证据保留；本轮尚未启动 VM。
- **用户已恢复执行。** 暂停事务、绑定、receipt 与暂停记录一致，恢复前未发现旧更新或测试 VM 进程，无 Task8 镜像挂载。正式第八版 `--recover` 正在执行，当前事务已进入 rollingBack；完成后将以 `pre-update-v8-snapshot.json` 核验六文件完整摘要、身份、绑定及 receipt，再使用新证据文件名重跑。修复源码、测试和限定 AMFI driver 的摘要仍与冻结记录相同。下条为此前暂停记录，不再表示当前工作暂停。
- **用户已要求暂停。** 第八版更新进程已按请求收到 SIGTERM 并退出（returncode=-15，1150.169 秒），只读观察进程也已退出。事务 `76e115c5-70ff-4484-8358-a357e59ce1e5` 保留在 publishing，游标 `0/10094`、pending=false；尚未提交，没有运行恢复。绑定为 host 第八版、kernel 第七版，receipt 摘要保持。无 Task8 镜像挂载、VM 或临时 AMFI/debugserver 进程；amfid 35998 由系统运行。本轮没有启动 VM。下次继续须先正式恢复此未提交事务并核验当前磁盘状态，再重跑更新。详见 `pause-v8-request.json`、`pause-v8-state.json`、`pause-v8-journal.json` 与 `kernel-update-v8.json`。下文“仍在执行”为暂停前记录，由本项覆盖。
- 用户于 2026-10-14 要求先修复 PAYP/原 description 保留，回归通过后正式更新并使用已授权第四版 VM 验证启动，启动通过后继续提交后 kernel-only 回退。现有未提交修改保留，AMFI 授权范围保持。
- 新增生产封装回归已 RED→GREEN。可信 generation 原始 IM4P 的 SHA-256 与第七版 proof.inputSHA256 一致，其 description 和 PAYP 原字节与更新前容器一致。真实容器回归将第七版缺字段的 IMG4 恢复为与基线逐字节一致的文件。37 项定向测试汇总退出 0，含 1 个其他 region fixture 入口跳过；实际元数据 fixture 执行，独立审查无阻断。
- 第八版 `2.6.20261020-local` 完整构建、打包、冻结、正式 Store 安装及复验通过，ZIP SHA-256 为 `8d444a08377eb7a8e69ba011f56c30db7cabe11ce4a2f2a64fa15d00d98971c0`。正式 host 绑定第八版，kernel 来源仍为第七版。`kernel-update-v8.log` 记录本轮无注入正式更新，当前仍在执行；没有启动第八版 VM 或扩大 AMFI 授权。
- `pre-update-v8-snapshot.json` 记录本轮更新前六关键文件完整摘要、inode 和绑定；Disk.img 仍为第七版提交摘要，无挂载或 pending。后续非 Disk 文件比较使用本次快照，因为前次启动已改变 nvram.bin。
- 第七版 `2.6.20261019-local` 正式离线更新已提交；journal、receipt、proof、报告、完整磁盘摘要及实际 Preboot 读回一致，独立审查通过。原始 IM4M 保持。
- 新旧解码 kernel payload 相同，IMG4 封装字节不同。本次建立同一 payload 的重新发布，不证明不同 payload 更新后的启动兼容性。
- 真实磁盘发布 5 块后中断、正式恢复及完整基线/身份/元数据核验通过，独立复核通过。
- 正式 host 切回已授权第四版，kernel 来源仍为第七版。第四版 VM 实际执行且框架进入 running，但 guest 未连接、shell 拒绝、串口停留 iBoot；正常启动验收未通过，原因未查明。VM 已正式停止。
- 用户已授权一次暂停并恢复 amfid 88460。执行前复查发现旧 amfid、driver 89299 和 debugserver 89316 均已退出；当前新 amfid 35998 由系统运行，无需发送暂停或恢复信号。本轮 VM、临时进程、挂载和 pending 均无残留。没有修改 TCC 或持久 AMFI 配置。
- 已提交且启动后的 kernel-only 回退入口尚未实现。Task 8/T34 保持未完整验收。

以下为按发生顺序保留的验证记录，各版失败结果不作为最终通过证据。

## 首版准备

- 持有源目录锁，以 `cp -cR` 创建完整测试副本。`clone.json` 记录源文件身份和时间未变，副本 Disk.img inode 与源不同。
- `baseline-digests.json` 记录源与副本 Disk.img、nvram.bin、SEPStorage、config.plist、两个 ROM 的 SHA-256 全部相同。Disk.img 逻辑大小 64 GiB。
- 独立构建最终签名 app；补入经过历史归档摘要和签名核验的 B22 本地构建 escalator，记录混合来源，没有执行该程序。Bundle 版本 `2.6.20261013-local`，ZIP SHA-256 `765619552c2861d108acc03284f32a8cc04869ee58f3a3f249436b2735091c47`。
- `core-store-install.json` / `core-store-verify.json` 记录系统可信存储安装、复验成功。
- 新增 `fw generation-prepare`，从两份本地 IPSW 和独立系统 ROM 创建 generation 与初始 desired plan，不替换已安装 ROM/Restore/Disk。48 项定向测试通过，见 `generation-preparation-tests.log`。独立审查未发现明确阻断问题；随后真实输入验证发现路径校验问题，见下文。

## 真实验证结果

- `generation-prepare.json`：使用 iPhone17,3 / iOS 26.1 / 23B85 与 cloudOS 26.1 / 23B85、EXP 变体。实际归档提取完成后拒绝，错误为 `original is outside the VM directory`，退出码 1。尚未发布 generation、desired plan 或内核。最小回归已确认原因：CLI 目录 URL 带末尾 `/`，原件父 URL 与来源目录的路径一致，但 Foundation URL 相等比较失败。已改为比较标准化并解析符号链接后的路径；先 RED 后 GREEN，49 项定向测试通过（`generation-url-red.log`、`generation-url-green.log`），等待新签名版本重跑真实场景。
- `final-vm-preflight.json`：系统 `allow-research-guests` 已启用；最终已安装 VM CDHash `2ce532c039be2dd010f009625079aabba20b9d0b` 的 `--help` 退出 137，执行策略检查拒绝。未修改 AMFI/TCC，未启动 VM。此结果不能作为启动验收通过。
- `vm update-kernel --recover` 只恢复未提交事务。已 committed 事务仅核验后归档，已归档事务没有公开回退入口。重新生成旧 desired plan 内核不能证明精确恢复更新前的磁盘及来源。本轮须分别记录中断恢复与提交后回退。

## 首版检查后的待办记录

当时尚待修复真实准备失败、重建 Bundle、创建来源与计划、绑定副本、实际内核更新与读回、中断恢复和启动验证。后续结果见下文；未提交 Git。

## 修正版真实准备通过

修正版 `2.6.20261014-local` 已构建、安装并复验。ZIP SHA-256 `102711d0db8f08aed749713fbc057e77304389e99ee0526b44c5537bd1cc9a17`。首版工件与证据保留未覆盖。

`generation-prepare-v2.json` 记录同一完整 IPSW 场景成功，退出码 0，用时约 171 秒。generation ID `d8d780c97a23b5ea398df872a73ad7aead24af90a08e35cea39c08524e927d62`，plan SHA-256 `703f9ad46613fa819ec6460846865ba9cd3ccd389f4b03c078fbc9baae741a3c`。来源清单与 desired plan 分别保存为 `prepared-generation-manifest.json`、`prepared-desired-plan.json`。

`final-vm-v2-preflight.json` 记录最终 VM CDHash `e4260a03082ac4ffdf79eee2f7f96e1ecfd80361` 的启动预检仍退出 137。没有修改 AMFI/TCC。

`bind-test-vm.json`：正式首次绑定命令成功，完整备份保存为 `/private/tmp/vphone-task8-acceptance-vms/task8-before-binding`，主机绑定 `2.6.20261014-local`；组件来源仍未声明。备份复制前后逐文件摘要核验通过。`source-final-metadata.json` 记录源 VM 六个关键文件的 inode、大小和时间仍与建立副本时一致。

## 实际内核更新被声明校验拒绝

`kernel-update.json`：正式可信 Bundle 的 EXP 内核更新执行约 288 秒后退出 1。`patchPostValidationAdditional` 和 `patchBsdInitAuth` 报告 `alreadyApplied`，但缺少声明特定输出证据；对应两个必需声明因此缺少成功记录。校验没有放行该结果。

`kernel-failed-journal.json` 记录事务 `8a082f72-b09d-45ef-ae55-a086b79011f3` 的 phase 为 building，kernelOnly 为 true，无 kernelDisk 记录。该失败发生在候选磁盘建立及磁盘发布之前。正在定位报告与真实输出证据的关系，不能通过放宽必需声明解决。

`kernel-failure-recover.json`：正式 `vm update-kernel --recover` 退出 0，将失败事务归档到副本 `.firmware-history/8a082f72-b09d-45ef-ae55-a086b79011f3`。此结果只证明发布前失败事务恢复；不证明中途磁盘写入恢复或已提交内核回退。

`kernel-failure-recovery-readback.json`：恢复后 Disk.img、nvram.bin、SEPStorage、配置和两个 ROM 的完整 SHA-256 与副本基线全部相同，inode 保持；launchpad.json 与更新前相同，没有待恢复事务。

独立核验：实际 generation 内 `kernelcache.research.vphone600` 解压 payload SHA-256 为 `b6846048f3a60eab5f360fcc0f3dcb5198aa0476c86fb06eb42f6267cdbfcae0`，与研究 fixture `raw_payloads/kernelcache.bin` 逐字节一致。最小 fixture 重现确认 EXP 流水线的 base 阶段先修改目标，JB 阶段识别为幂等而未提供记录。不能将该现象解释为原始研究内核天然满足补丁。

已应用输出修复：新增只读 `emitVerifiedOutput`，保留真实同值 before/after，JB outcome 保持 alreadyApplied，description 明确 no byte change，既有 Gate 不放宽。真实 fixture 的最终 12 项测试通过，确认基础阶段 2 条实际修改、JB 阶段 0 条字节修改及精确载荷/输出摘要。独立审查通过，见上级目录 `already-applied-structured-green.json`。用户摘要改称包含已核验未改输出的字节记录，不将观察数称为新增修改数。

`installed-baseline.json`：独立只读挂载首次绑定备份的 Preboot 和 System，核验只读状态并成功卸载。Preboot 有唯一普通 kernelcache，IMG4 文件 SHA-256 `5b90c5a0ee87bf810c7e90795d537265f39774fbf85c430263fd2f61fc41ce7a`。实际 DSC 目录有 `.atlas` 辅助文件；现枚举规则可能将它作为 cache 主体解析，正在用生产验证器确认。该手工只读检查不替代生产更新验收。

## 提交后回退的实现缺口

独立审查确认，已提交且启动后的 kernel-only 回退不能逆向恢复整盘 4 KiB 差异，因为启动可能已经改变 guest 数据。需要明确选择并核验旧内核和来源，在当前磁盘候选上只替换 Preboot 内核，重新检查 IM4M/DSC，以新事务提交回退 receipt 和 kernel 来源，并验证再次启动。现有锁、候选挂载、payload swap、DSC 校验与未提交事务恢复可复用；公开回退入口、归档目标核验和旧来源资格适配尚未实现。不能把备份或 origin 字符串直接当作可信 producer。

DSC 修复已通过真实 RED→GREEN：只排除准确的 `dyld_shared_cache_arm64e.atlas`，仍拒绝引用表将 atlas 列为子缓存，其他相似后缀仍按子缓存检查。Apple dyld 构建器将 atlas 作为缓存主体之外的独立输出；独立审查通过。完整 EXP 生成→声明门→内核区域识别→实际 DSC 验证通过（`../dsc-atlas-exp-verified.json`），候选共享区域 base/size 均为 6442450944（6 GiB），实际 DSC 79 子缓存、102 映射；span 加 maxSlide 为 `0x14fafc000`，小于 6 GiB。该测试未发布到 VM 磁盘，也未启动 VM。

## 第三版与运行环境

最终第三版 `2.6.20261015-local` 的 ZIP SHA-256 为 `0f51dc797183f9236587e3ef85b7868840f1da553a05230e6a6a0708f55b3e1b`，CLI CDHash 为 `f62699afdd673a2bca341c5414d524d232060b9c`，VM CDHash 为 `14d87bc3cf997469a27cb98514cf4b0e5c9a1e28`。安装、复验与测试副本重绑定已通过。用户明确授权只对该 VM CDHash 临时 AMFI 放行，仅启动 task8-copy，结束后清理本次放行进程；没有获得 TCC 修改授权。

第三版第一次尝试在建立候选后触发 root Python 环境自动准备。锁定包 `certifi==2026.7.22` 无可用下载版本，该准备没有发布新环境。`python-bootstrap-cancel.json` 记录取消自有更新/安装子进程前事务仍为 building、无 kernelDisk；`kernel-bootstrap-recover.json` 记录正式恢复成功。此次没有执行计划中的写入后中断，不能计为该验收通过。

`project-python-locked.json` 记录项目 `.venv/bin/python` 通过最终 Bundle 的锁定依赖校验，differences 为空。后续通过受支持的 `VPHONE_PYTHON=/Users/qcz3840/github/vphone-cli/.venv/bin/python3` 显式选择该环境，重新执行发布中断验证。没有放宽 Python 锁定校验。

## 限定 AMFI 与签名缓存检查

用户已明确授权第三版最终 VM CDHash 的本次限定 AMFI 放行。`scoped-amfi-vm-help-retry.json` 记录该 VM 的 `--help` 返回 0；随后 LLDB 报告 amfid `Terminated due to memory issue`，driver/debugserver 均已退出。此结果仅为可执行文件预检，不是 VM 启动通过；未修改 TCC。

`kernel-pycache-rejected.json` 记录重试因 Bundle 新增两个 `check_python_runtime` pyc 文件被严格签名校验拒绝，尚未创建新事务。已仅删除这两个本次生成的缓存，`codesign --verify --deep --strict` 返回 0。后续验收显式设置 `PYTHONDONTWRITEBYTECODE=1`，不修改冻结工件内容。

## 真实卷关联检查失败与恢复

`kernel-volume-association-failed.json`：第三版更新约 387 秒后在候选卷关联检查处拒绝，错误为 `Installed volume association differs`。事务仍为 building，尚无 kernelDisk，未执行发布中断注入。`kernel-volume-association-recover.json` 记录正式恢复成功并归档事务 `6c48b89a-5dea-4eea-9c91-97d6f5b3102e`。

`kernel-volume-recovery-readback.json`：恢复后 Disk.img 与其余五个关键文件的完整摘要和 inode 均与基线相同，绑定保持第三版，无待恢复事务。真实 APFS 观察回放已重现原错误：`diskutil apfs list -plist` 的 volume 条目未提供 MountPoint，而 `diskutil info -plist` 的 MountPoint 与实际挂载目录一致。正在修复字段来源假设并独立审查；不能将此发布前恢复计为磁盘写入后恢复通过。

真实卷关联修复已通过 RED→GREEN 与独立审查：APFS 列表验证唯一容器成员；对应设备 info 始终验证精确挂载目录与读写状态；列表若携带 MountPoint 必须一致，同时核对两份观察的卷 UUID。`../volume-association-real-green.json` 与相关日志保存真实 plist 回放和拒绝用例结果。正在构建第四版 `2.6.20261016-local`，尚未用于真实磁盘发布或启动。

## 第四版工件

第四版 `2.6.20261016-local` ZIP SHA-256 为 `96b608f1ac3722516d02c41281c9d102cb4b983b4c306570c408056e425cf1c3`；CLI CDHash `eba1b73c59773863934410a182bfd92a640425d5`，VM CDHash `43c00d51b4c7f07a5feba006f3c244edbac39cea`。完整构建、资源/依赖闭包、严格签名、源码清单核验通过；前三版工件与证据保持。可信 Store 安装、复验及副本重绑定均退出 0。VM entitlements 未变，实际代码字节及 CDHash 改变，第三版限定 AMFI 授权不能据此扩展；已申请第四版具体授权，等待回复时继续离线验收。

## 第四版候选读写状态检查失败

`kernel-readonly-state-failed.json`：第四版更新约 371 秒后拒绝，错误为 `Installed volume is not the exact readonly mount`，事务 building、无 kernelDisk，未触发发布中断。`kernel-readonly-state-recover.json` 记录恢复成功，事务归档为 `966d6048-d03c-449e-8b89-a4a75d361a27`。此前全盘 readonly 挂载的回放未覆盖 writable 候选与逐卷 rdonly/rw 组合，正在以独立候选 clone 捕获真实状态，并验证完整 live 挂载/内核替换/DSC/卸载/readonly读回路径。第四版尚未 AMFI 放行或启动。

`kernel-readonly-recovery-readback.json` 记录第四版恢复后六个关键文件完整摘要和 inode 均与基线一致，第四版绑定未变，无待恢复事务。独立候选 mixedmount 回放中 Hardware/System 的 WritableVolume=false、Preboot=true，且与实际挂载标志一致；原只读状态错误原因仍在排查，不能归因为 WritableVolume 语义差异。

## 系统路径别名修复及完整候选验证

完整 liveOperations RED 确认正式路径 `/tmp` 或 `/var` 与 diskutil 返回的 `/private/tmp` 或 `/private/var` 字符串不同；读写状态符合预期。修复仅规范化这两个系统别名，同时覆盖镜像和挂载目录观察，不解析任意 symlink 或 `..`。真实回放和拒绝用例通过。

`../mixedmount-live-green.json` 记录完整生产候选路径退出 0、耗时 170.131 秒：实际 EXP producer/声明校验、候选内核替换/DSC、即时读回、卸载、只读重新挂载的内核/DSC 验证以及前后整盘摘要一致。四组十二次卷状态观察均正确；测试候选已卸载清理。`mount-path-alias-independent-review.md` 记录独立审查通过。

用户已明确授权第四版 VM CDHash 的本次限定 AMFI 放行。第五版仅用于修复后的离线更新；正式更新成功后，使用公开绑定命令将 host 切回第四版，并核验 kernel 来源仍为第五版，再启动已授权的第四版 VM。不对第五版 VM 扩展 AMFI 授权，不手动混装 Bundle 文件。

## 第五版冻结与交接

第五版 `2.6.20261017-local` 已完整构建、打包并冻结，尚未安装。ZIP SHA-256 `bd489d3cb1828d1868118a7bba9a82fdb668f4a0b981f7164bc81a61731b4008`；CLI CDHash `1e220b779807696d8189206a4a83d097e60c4018`；VM CDHash `5ab540e7f73f17d68aefa20838326456a5178d48`。构建/打包会话均结束。下一步为第五版离线更新及发布中断恢复，再正式将 host 绑定已获授权的第四版进行启动。第五版 VM 不在 AMFI 授权范围内。

用户要求交接至 GPT-6.1 Sol、高推理强度继续工作。交接时没有运行 VM、临时 AMFI driver 或待恢复事务；测试副本仍为第四版绑定及基线磁盘。交接文档保存于 `/private/tmp/vphone-task8-handoff-2026-10-13.md`。

## 第五版离线尝试及进程终止（2026-10-14）

第五版 Store 安装、复验和正式 host 绑定均退出 0。`binding-before-update-v5.json` 保存更新前绑定，只有 host 字段。第五版 VM 未执行、未放行。

`kernel-v5-capture-killed.json`：正式更新子进程 PID 30808 在 699.816 秒后以 SIGKILL 退出（returncode=-9），`injected=false`。事务 `e230b6e0-a7f5-4496-b06b-871aad064a72` 仍为 building，没有 kernelDisk 发布记录；不能计为计划中的发布后中断。`/private/tmp/task8-v5-update-sample.txt` 的采样显示当时位于 `FirmwareKernelDisk.capture`，physical footprint 1.2 GiB、peak 1.4 GiB。后续进程终止原因未查明；`kernel-v5-kill-system.log` 没有提供明确终止原因。

正式 `--recover` 退出 0，将同一事务归档。完整基线读回正在进行。正在使用安全合成文件验证 4 KiB 扫描循环临时对象累积的假设；未将该假设记为本次 SIGKILL 的已确认原因。当前没有运行 VM 或本轮 AMFI driver。提交后 kernel-only 回退缺口保持。

`kernel-v5-capture-killed-recovery-readback.json` 已逐项断言六文件完整 SHA-256 与 inode、第五版绑定均保持一致，无待恢复事务；`v5-recovery-attachments.plist` 核对无 Task8 镜像附件。第五版失败日志及采样已保留，后续修复不覆盖该结果。

## 第六版冻结和重新验收（2026-10-14）

四个真实 helper 的合成内存回归均已 RED→GREEN，capture、validate、publish、reverse 每轮加入 autoreleasepool；独立审查确认块语义、持久化顺序和异常传播保持。最终 Swift Testing 汇总 53 项，其中四项真实 fixture 入口未启用并跳过；四个独立 XCTest 内存子操作均实际通过。精确命令、源码和原始日志摘要见 `capture-memory/manifest.json`。此前 SIGKILL 原因未查明。

第六版 `2.6.20261018-local` 完整构建与打包退出 0，ZIP SHA-256 `dd7cb63100e41966fc89226ba58a8a8e343077a2de261541eb35497c02ea5aef`，CLI CDHash `f73340bba9178a85933b69d4b021191031808b1a`，VM CDHash `eb667b4c294a63584c6f5163028802a05f1fdfc4`。签名、依赖闭包、源码冻结和 v1–v5 保留复核通过；首次沙箱缓存权限失败的日志保留。Store 安装、复验、正式 host 绑定均退出 0。`binding-before-update-v6.json` 仅含 host 字段。第六版只运行离线更新工具，VM 未执行或 AMFI 放行；启动仍使用已授权的第四版。

`interrupt-publication-v6.py` 的真实更新正在运行；必须确认 publishing 且持久游标至少 1、子进程已退出且尚未 committed 后，才进入发布后恢复验收。当前结果尚未完成，不计为通过。

## 第六版候选效果读回拒绝（2026-10-14）

`kernel-v6-effect-rejected.json` 记录本次正式更新 929.136 秒后退出 1，`injected=false`，children max RSS 为 1,185,546,240 字节。事务 `e6bdfe5a-0bb7-42da-918e-7bc2d40bf7bb` 的 kernelDisk 已识别 10,159 个变更块，cursor=0、pending=false，phase=building。producer 的逐项效果和重构检查已通过，报告及磁盘备份已保存；首次 commit candidate 读回返回 `Component receipt: required effect absent from final output: kernel.apfs_root_snapshot`。尚未写入 installed proof，也未发布配置磁盘。

已保留 journal/report/component receipt 原始证据，正在正式恢复；效果检查的 Data 切片索引解释仍属待验证假设。没有放宽 Gate 或改动内核补丁算法，不将本次尝试计为写入后中断恢复通过。

`kernel-v6-effect-rejected-recover.json` 记录正式恢复退出 0、487.098 秒，归档同一事务。`kernel-v6-effect-rejected-recovery-readback.json` 已逐项断言六文件完整 SHA-256 和 inode、绑定均与基线一致，无 pending。实际 IM4P/IMG4 Data 切片最小回归已两次复现相同拒绝，通用索引修正 RED→GREEN，独立审查通过；第七版正在构建。

## 第七版冻结及离线重新执行（2026-10-14）

第七版 `2.6.20261019-local` 已完整构建签名，ZIP SHA-256 `fc76c6ff26fadfd6ae9eda9cfebabba15c0166bdbb83e6b19861f499ac9f15fc`，CLI CDHash `df8384e696521c8c4d47dd955b056642a6563878`，VM CDHash `530654ea459feab3ea7a78fe515a62aac9bf4eaa`。构建/打包、签名/依赖闭包、源码冻结与 v1–v6 保留复核通过。Store 安装、复验及正式 host 绑定均退出 0。`binding-before-update-v7.json` 保存更新前绑定。第七版 VM 未运行或 AMFI 放行。

`interrupt-publication-v7.py` 已开始真实更新；此前第六版失败证据保持。后续仍需实际 publishing 游标、正式恢复全盘核验、成功更新、第四版 host 重绑定和真实启动证据。

Python 环境核验：项目 `.venv` 的 Python 3.14 无法加载本机 LLDB Python 3.9 模块；只读 import 失败和系统 Python 兼容 import 成功分别保存为 `scoped-amfi-project-python-import.json`、`scoped-amfi-compatible-python-import.json`，两者均未 attach。固件构建、更新和证据脚本使用项目 `.venv`；限定 AMFI 驱动使用交接指定的兼容系统 Python。所有脚本显式禁用 pyc，未修改 TCC。

## 第七版真实磁盘发布后中断（2026-10-14）

事务 `057edee1-adee-4535-b13f-0a2778470dc4` 已通过首次 candidate commit 效果读回并保存 installed proof，随后进入 publishing。`kernel-interruption-v7.json` 记录监督脚本确认持久游标至少 1 后发送 SIGTERM，`injected=true`，子进程 returncode=-15，耗时 1337.990 秒；退出后 journal 为 publishing、cursor=5、pending=false，未 committed。变更块总数 10,159。该注入不证明短写或固定块边界场景。

`kernel-interruption-v7-physical-readback.json` 在子进程退出并取得 VM 排他锁后，对全部 5 个已发布块逐项读取：实际字节均等于候选且不同于原件，Disk.img inode 589096904，绑定与 `binding-before-update-v7.json` 相同。该证据建立实际块发布后的中断；正式恢复及完整基线读回仍在进行，尚不计为恢复通过。

`kernel-interruption-v7-recover.json`：正式恢复退出 0、482.232 秒，归档同一事务。归档 journal 为 rollingBack、reverse、cursor=0、pending=false；metadata 两项恢复至原摘要/原始缺失状态。`kernel-interruption-v7-recovery-readback.json` 已逐项断言六文件完整摘要及 inode、绑定保持；Disk.img 恢复基线 `391c05e119055a10b477d8ba73bb69188c4856f80ac6e69a09856a3e24baa7f0`。无 pending 或 Task8 附件。该结果建立实际发布后未提交事务恢复通过，不建立提交后回退通过。

## 第七版完整更新提交（2026-10-14）

`kernel-update-v7.json` 记录正式无注入更新退出 0、3291.159 秒；事务 `1526d1ea-9f0c-48ae-ae06-f1d65394759b` 完整发布 10,159 块并提交。CLI 报告 generation `d8d780c97a23b5ea398df872a73ad7aead24af90a08e35cea39c08524e927d62`、plan `703f9ad46613fa819ec6460846865ba9cd3ccd389f4b03c078fbc9baae741a3c`。尚未启动 VM，提交后的独立只读读回正在执行。

## 提交后独立读回及第四版启动尝试（2026-10-14）

`committed-readback-v7-run.json` 退出 0、111.911 秒。归档 journal 为 committed、schema 3、kernelOnly，游标 forward 10159/10159、pending=false。Disk.img SHA-256 `9918d2bdd8f4cb9b653ebe0a5d552cd3f61bb4986421652f08c4049adfb82531` 与 candidate/proof/receipt 一致，六文件 inode 保持，五个非 Disk 文件内容保持。实际 installed payload 与 proof 一致，raw IM4M 与基线一致，读回前后整盘摘要相同，无附件。

基线与 installed 解码 payload 均为 `d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb`；IMG4 文件摘要由 `5b90c5a0ee87bf810c7e90795d537265f39774fbf85c430263fd2f61fc41ce7a` 变为 `e8ead0a8a83b4e68254b73cc2f70fe5df7486f5ea91f0bd217b34f4a5a87dcf2`，raw IM4M 均为 `ec08fc625f7f8b76861b93fb9a950022103fe4031ead235f64daad1df8c4c657`。这不建立不同 payload 的更新或启动结论。`commit-independent-review.md/json` 记录范围及限制。

正式 host 绑定第四版退出 0，kernel 来源仍为第七版，receipt/proof/committed journal 不变。第四版 Store 再验证通过。限定 AMFI 的路径列表为空、allow_all=false，仅 CDHash `43c00d51b4c7f07a5feba006f3c244edbac39cea`，没有持久配置或 TCC 修改。VM `--help` 预检成功，随后正式启动的实际 VM PID 90543、instance `CAAA862F-BB3A-4D08-A00A-8210BF655B36`，config 指向 task8-copy，实际 argv 含 `--no-vphoned-update`。

`vm-boot-v4-kernel-v7.json` 的退出 0 来自后续停止；运行期间 framework 报告 started，guest capabilities 为 guest_connected=false，shell 返回 `guest not connected`，未取得 uname/sysctl。串口仅观察到 Supervisor LLB/iBoot，无足以确认内核或 guest 正常启动的证据。原因未查明；没有更新前基线启动对照，不能将现象直接归因于本次容器修改。

正式 `vm stop` 退出 0，先发 SIGINT，请求 guest 优雅关机超时后由框架停止。停机后 Disk.img 全盘摘要仍为已提交值，源 VM 六关键文件的 device/inode/size/mtime/ctime 均与 clone 前记录一致，无 pending。临时驱动清理尚待精确授权，详见 `amfi-cleanup-review-rejection.json`；不能报告清理全部完成。

## 容器结构只读对照与清理阻塞（2026-10-14）

`container-export-v7-run.json` 退出 0，8.404 秒，只读导出基线及归档候选的完整 IMG4，摘要与提交前读回一致，均成功卸载。`container-format/manifest.json` 记录纯文件 DER 对照：raw payload 均为 43,991,040 字节，SHA-256 相同，压缩类型均 NONE；description 由 `KernelManagement_host-487.0.4` 改为 `kernelcache`，缩短 18 字节；基线存在 315 字节的 PAYP 附加元素，安装后不存在。IM4P/IMG4 均缩短 333 字节，raw IM4M 保持，均无 IM4R。启动现象原因未查明，不能将该差异直接写为因果。尚未修改封装策略，后续应验证保留原容器语义的候选及基线启动对照。

`final-before-amfi-cleanup-attachments.plist` 确认本轮镜像均无附件；VM 已停止，无 pending。driver 89299/debugserver 89316 仍在，attached amfid PID88460。SIGINT 已发送但未完成 finally。自动审批拒绝了 `kill -STOP 88460`：认为暂停系统代码签名服务超出现有精确授权。该操作没有执行；已请求用户一次暂停并恢复的精确授权，尚未收到。未尝试绕过。

## 临时进程清理状态确认（2026-10-14）

用户明确回复“授权一次暂停并恢复 amfid 88460”。执行前复查发现 PID88460、driver89299、debugserver89316 均已不存在，因此未发送 STOP 或 CONT。原驱动日志记录 inferior `Terminated due to memory issue`，随后 detach 失败，驱动退出 1；不能表述为成功 detach。旧目标和全部本轮临时进程已退出，当前 `com.apple.MobileFileIntegrity` 为 running，新 PID35998、PPID1。launchctl 的 last-exit 字段仅为当前服务观察，不额外归因为旧 PID88460 的精确退出原因。

`amfi-cleanup-resolution.json`、`amfi-cleanup-final-service.log`、`amfi-cleanup-final-processes.log` 和附件 plist 保存最终状态。本轮 VM 已停止，无临时 driver/debugserver、Task8 挂载或 pending 事务。历史审批拒绝和当时等待状态保留。启动未通过、相同 payload 的验证限制及提交后回退缺口保持，不提升 Task8/T34 验收状态。


离线标记诊断补充：`kernel-v9-rollback-a-marker-images-01-environment-limitation.json` 记录归档原盘 Data 的 Encryption=true、FileVault=true、Locked=true。工具按约定拒绝读取，无标记内容观察，未继续候选和当前 UserData，未尝试解锁。原盘检查前后完整 SHA/身份保持，最终无附件或 pending。旧标记缺失原因仍未查明；新 Documents 标记只证明同实例 sync/读回，停机落盘与跨回退保持尚未验证。

## Documents 停机重启通过，跨回退验证运行（2026-10-14）

前述限制保留为当时证据。PAYP/原 description 修复、不同 payload 的 A/B 正式更新、公开回退 A 的实际读回与第四版正常启动均已通过，详见 `kernel-rollback/` 及 `0_binary_patch_comparison.md` 的后续记录。旧 tmp 标记在回退 A 后 ENOENT，失败文件保持，原因未查明。

用户重新授权继续验证新 Documents 标记。第四版新实例 `3EF0B0A0-DB1C-4FBB-8E4E-CD8E3E15B888` 启动正常，实际只读取得原有 1254 字节，SHA-256 `a8faa4e5b805fd5a0ee0f8330296d168bb85f33c674748595d176df3714e418e` 与原创建时一致，无重新创建。正式停机及清理通过。本次 preflight 退出 0，未运行临时 AMFI 驱动或发送 amfid 信号。

已对停机后的磁盘冻结完整基线，并使用冻结 V9 正式 `rollback-kernel` 回退到已有 B 事务 `2901d975-2379-4b50-9340-8580786aacc1`；当前 desired B 保持。跨回退提交、实际读回、第四版启动和同一标记读取尚待完成。优化不合入，旧失败证据保留。见 [documents-persistence.md](documents-persistence.md)；amfid 停止原因未查明，见 [amfid-stop-tracking.md](amfid-stop-tracking.md)。


### 2026-10-14 Documents 停机重启及跨回退验收结果

新 Documents 标记的两项持久性检查均通过：同 A 内核正式停机重启后读取原标记；再通过冻结 V9 的公开 `rollback-kernel` 回退到历史 B 并由第四版 VM 启动后读取原标记。两次实际内容均与原创建的 1254 字节一致，SHA-256 `a8faa4e5b805fd5a0ee0f8330296d168bb85f33c674748595d176df3714e418e`；未重新创建标记。

新回退事务 `0d6d197a-8b24-4944-bb38-16a60ed24fb0` 正式提交退出 0（4283.968 秒），schema 4、49/49 块、pending=false；目标历史 B 为 `2901d975-2379-4b50-9340-8580786aacc1`。独立实际 Preboot 读回退出 0（108.183 秒），B 的 IMG4/IM4P/payload、120 条记录、原 description/PAYP/IM4M/envelope 保持。live desired B 保持。第四版 guest 系统查询、正式优雅停机及清理通过。完整保存证据关联校验 `task8-final-documents-persistence.json` 通过；冻结 V9 的 16 源文件和已安装 CLI、第四版 CLI/VM 摘要保持。

旧 tmp 标记 ENOENT 失败记录和摘要保留，原因未查明。新结果仅建立这个 Documents 标记的持久性，不证明全部用户文件内容一致。旧失败汇总工具未改写或提升为通过。第一次 B 启动观察的证据文件权限失败、所有者修正及停机短标签的逐字节归档说明均保留。amfid 停止问题单独跟踪，原因未查明；本轮两次 preflight 均为 0，未运行临时驱动或发送 amfid 信号。AMFI 授权范围保持，优化不合入，保留现有未提交修改，未提交 Git，未推进 Task 9/10。

详见 `research/evidence/2026-10-13-task8/acceptance/documents-persistence.md` 及同目录 `amfid-stop-tracking.md`。前述历史待完成和失败状态保留为当时证据。
