# 第九版计划 B 输入与 desired 发布独立审查

结论：可信 generation Restore 输入补齐、恢复输入后的公开 desired preview 和正式 B desired apply 证据通过，未发现阻断。本结论不包含 B 内核实际发布或启动。审查仅读取 E 冻结证据和源码，未读取活跃 VM，未操作 VM、guest、挂载、AMFI 或进程，未改生产源码。

`prepare-acceptance-restore-input.py` 限定 task8-copy、固定 generation 和唯一 `iPhone17,3_26.1_23B85_Restore` 原件。manifest 与冻结 prepared manifest 一致；tree 摘要算法与生产 treeDigest 相同，包含类型标记、全部相对名称/空目录和文件字节，拒绝链接或特殊文件，文件读取核对 descriptor/named 身份、大小和时间。source-before、stage candidate、source-after 的完整树 SHA 均为 `a3712fa7d96ebe8c2899af2c728e30d6f50543e3b8cec3af23a60cee7196b03a`，等于 generation 原件。

两个实际版本 manifest 的 SHA 分别为 iPhone-BuildManifest `00316e31d8439a6ef89b74932ca1521b760b6e0761ab06bc679ef23c903c5c87` 与 BuildManifest `96a6fc9e7f279d591f23ba3385c12194c6d9bdcab71d45f07e6a963ccb04a2e5`，source/stage 相同。工具持有 VM 目录锁，使用唯一 stage、校验后 rename 到原先不存在的根 Restore，前后六文件五项 metadata、generation manifest SHA、binding/receipt/current desired SHA 完全相同。该范围没有重新计算六文件完整内容 SHA。

源码确认公开 desired-plan 经 resolvedPlan/prepare 揭示当前版本，要求 VM 根 Restore；随后另行校验可信 generation 与 desired。installed producer 仍从 generation.originalURLs 读取原件。此次补齐根输入没有改变生产门或替代 producer 资格。

首次公开 preview 缺根 Restore，exit1/19.866802 秒，失败原文保留。补齐输入后的同命令 preview exit0/52.413274 秒，applied=false。正式 apply 使用固定 V9 CLI、同 VM/library/generation、EXP --force-exc-guard，并显式 `--expected-sha256 ea1f464ba1ffb63737082879323cdac4a1efc8b40aa30e7ee7e505606a7fac34`；退出0/101.968363 秒。preview record、apply record 与实际 desired 完全相等；实际 raw desired SHA 为 `3ad404b6361d1989bda18be961ce72d1415f6e84025138ec6623bc0578aad949`，plan SHA 为 `bb37c956b2bce344b65c6ca3fdea77065d9713f539f4a761823c2c8e5369e96c`，均与冻结 operation expectations 一致。

B 与 A 的 generation、stable identity、catalog、upstream、variant 及全部非内核选中/排除/enabledSteps 集合保持，仅 forceExcGuard/excGuardActive 由 false 变 true。plan SHA 与先前实际 producer+当前 System DSC 的 true 计划一致。apply 后 receipt 仍为 A 的 e59819…，binding43ac7…保持；desired 发布不会建立 B 已安装结论。

工具是一次性输入补齐；失败可保留 stage 或已 rename 的根输入，独占输出禁止静默重复。本次实际执行通过。下一步需正式 B kernel 更新、独立物理读回和启动，再完成公开明确 UUID 回退 A 与 marker 保持。完整输入摘要见同名 JSON。
