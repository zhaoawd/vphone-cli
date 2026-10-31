# T32/T33 generation 原件来源恢复审阅（2026-10-26）

新候选 `2.6.2-local.729bd605278a` 与具体续行计划已准备，尚未批准或安装。原只读认证session40433退出0，唯一root91034完成真实打包代码完整预检：四镜像完整摘要、父事务发布链、完整Undo预览、历史索引逐字节重建及W7保留来源核验通过。没有来源注册、事务写入、磁盘发布或VM启动。已消费的73b/2e计划不重跑。


## 已确认的问题与证据

73b/2e 已安装新 Store、创建12份完整写前备份、注册四份镜像的跨重启身份，并将 W7 原事务完整移入 `.cfw-recovery-sources/20261025T144138Z-W7aZSh3x`。恢复工作进程在完整 Undo 预览的 `undo_provenance.build` 拒绝 `Undo source no longer matches original observation`，未创建新 transaction.json 或磁盘克隆，未发布撤销盘，未执行重应用。仅保留空 `.cfw_disk.reboot20261026`。

原生及独立收尾已结束。源备份10项、完整备份12项、两类缓存、四份失败记录、SSH存档和 W7 全部5343个文件完整核对通过。收尾 manifest 为 `1d6ab2a0ce3d5c90e7a6d664aad9c273cdba18d8fba60ec3d46800d3dc63eac8`。首次 EXP 应用仍为 f430/adMN63qO，磁盘完整摘要 `104c89afb70841172e6eb8bd0991c4d1b7b72fde763731af4c8258b5ba301358`。

独立 root 只读诊断复现原错误，确认两份 generation 加密原件的唯一资格字段差异为 `generationSource.source.device`：16777231→16777234。inode、大小、完整摘要及 manifest/原件目录摘要保持。两份原件分别为 `090-88605-626.dmg.aea`（7784628224字节，SHA `c2e8e7becd7652cb455ed3fe6354ee49723673a91f1573bd1f7c6f8595846f9d`）和 `090-89678-659.dmg.aea`（1879048192字节，SHA `bef7674cb8a6f679840eea040a944d8c6002cdac01e44fb99b18dba8f7518e8b`）。历史来源记录未包含 mtime/ctime，不补造这些历史字段。

只在内存中替换设备号后，完整两份 SystemVersion Undo 预览与原索引逐字节重建通过。这是诊断模型证据，未注册实际来源恢复权限，不计磁盘恢复验收。证据保存在 `generation-source-reboot-probe-20261026/result.json`。

覆盖遗漏已明确：原四盘身份与历史发布链预检没有执行完整 Undo 预览，未覆盖 generation 原件来源观察。新预检使用新打包代码、真实当前父记录、完整 Undo 预览和 W7 来源验证；只把经过完整读取的来源关联放入内存。正式执行还必须在注册后、克隆前再次通过实际注册读取路径。

## 实现与验证

新增 `scripts/cfw_source_identity.py`。独立 root/0444/单链接记录 `.cfw-reboot-source-identity.json` 只列出上述两个明确来源，绑定 VM、generation、卷 UUID 和批准计划摘要。历史资格保持原文；当前 dev/inode/大小/mtime/ctime/mode/UID/GID/nlink 另存。只允许 device 变化，必须保留 inode、大小、完整来源摘要、manifest/原件目录摘要。实际资格读取仍返回当前原生字段，比较时要求精确有效关联。没有全卷设备别名，没有改写旧 journal 或放宽字节/来源/签名校验。

`undo_provenance` 的 build/recheck 与 `file_originals` 的历史来源比较接入该限定匹配；bundle 依赖检查加入新模块。

| 实验设置 | 结果 | 验证限制 |
| --- | --- | --- |
| 原始来源错误回归 | 0.761秒复现原拒绝，修复后通过 | 隔离 generation 夹具 |
| 新来源身份与组合 Undo 定向验证 | 11项通过 | 含混合 DSC/file Undo、部分密封、克隆、密封、发布；APFS 挂载由夹具提供 |
| `.venv/bin/python -B scripts/run_tests.py python` | 1171项，4跳过，301.298秒，退出0 | 无VM启动 |
| 新执行/收尾/consumer/watcher与恢复工作进程组合 | 23项通过，1.631秒 | 不代表真实恢复发布或运行验收 |
| 新候选打包核验 | 签名、entitlements、12个宿主Mach-O依赖闭包、精确变更集合通过 | 未安装 |
| 实际打包代码完整只读预检 | 全部通过，原session40433退出0 | 只在内存提供已完整核验的来源关联，无真实注册/克隆/发布 |

候选 `2.6.2-local.729bd605278a` 的 tar SHA 为 `fa6c147325734a99d5567441c1016340317d9158e11227da8cdd6c730deb470e`；CLI SHA 为 `00c7c1c36993b4becc6c6978c40c551b7ad415c994e2f925c4b84d7bb0942677`。CLI 非签名代码、VM 和客户机载荷相对73b保持。VM SHA `da07a849d794c501d85b74c003b4d0af4ccbd4ef11dee39086f45842a203d279`，CDHash `f5966c5e0d003dc964c1ab898b1ff1aba32aaa58`；目标规则 `cf03209f536f245fb775a5a146eaa6a769d6c427ec061c644b9a5a1bc67354a8` 保持。旧候选和失败输出保留。

## 已冻结的一次续行计划

复用已核验的12份完整写前备份及两类保留缓存；增加当前 launchpad.json、运行诊断、SSH标记、四盘注册记录共四份小型写前备份。SSH另保留用户所有的完整内容载体及原始UID0元数据。正式root预检仍重新完整读取当前12份输入、四份镜像、原备份及 W7 全部文件，不用准备阶段摘要替代。

只新增两个 generation 原件来源关联，不替换四盘注册、不再次移动 W7。先用真实注册读取器通过完整 Undo 预览及保留来源校验，再把原空工作目录完整移入 `.cfw-recovery-sources/2e489523-empty-work-20261026`。复用四盘注册已列明的恢复事务ID `20261026T000000Z-reboot20261026` 和暂存路径；该ID尚未创建任何事务记录。

从 W7 已恢复磁盘创建新事务，仅执行最终读回、密封和撤销发布；不重复原撤销回写。独立目标审计及两份完整原件恢复通过后，才执行剩余一次 EXP 精确重应用。首次应用来源仍为 f430，新重应用来源为729。

初始75GiB、每次CFW50GiB。失败停止，无自动重试、回滚、新退役、regular重跑、首次应用重跑、VM启动或辅助窗口。后续运行入口只在完整独立离线收尾通过后准备待审阅运行计划；Settings、显示、完整AA.gl及应用消费仍未验收，整体 accepted=false。运行批准必须明确既有EXP首次启动脚本在完成标记缺失时可能进行软件包安装、APT源修改及更新/升级。

计划SHA-256：`3d98012abcd1bd61105d38ce7f042f46eca2ee2d9159d3e26cdc1691a3d88490`。计划文件为 `.build/t32-t33-completion-20261023/exp-source-identity-acceptance-20261026/offline-plan.json`，2189项计划输入、114项执行输入已冻结。源备份10项完整读取与旧预期相同；当前12份输入取自本次root完整预检并在准备时核对元数据，实际写入前仍须root重新完整读取。准备可用138.85GiB，初始75GiB门通过。新执行claim、批准标记、来源注册和729 Store版本尚未创建。新Store位于 `/Library/Application Support/vphone-launchpad/Bundles/`；依据用户提供的AGENTS.md执行约定4“修改当前仓库以外的内容之前，停止并请求确认”，新版本安装需新批准。旧一次批准不用于重试。

准备证据归档：`evidence/T32-T33-completion-20261023/source-identity-repair-preparation-20261026/manifest.json`，33项逐文件复制与完整读回通过，manifest SHA `3718d83a1d3d790597abe39358e6f395fdebfc1025f30e8af81851712b535e75`。归档时实际打包代码预检尚待认证，不计预检成功。

本次具体计划只复用现有四盘身份注册和W7保留位置；新来源注册仅限两份原件。实际恢复ID及路径仍使用已批准注册列明的名称，原空工作目录移入新保留目录，不删除。新建4份小型备份将保留原始UID/GID；准备阶段额外的用户所有SSH载体与原始UID0元数据另列。新root将完整复核旧12份备份、两缓存及W7全部5343文件后才续行。

恢复工作进程失败时保留其新暂存事务。后续精确重应用沿用现有CFW正常临时产物清理；`--keep-artifacts`不保证保留本次失败的新暂存Disk.img。旧W7、原完整备份、四盘注册及其余现有数据均保留。

具体计划与实际预检归档：`evidence/T32-T33-completion-20261023/source-identity-reviewed-plan-20261026/manifest.json`，25项完整复制/读回通过，manifest SHA `073ed107190630e3f6e3db310d2aa4d7861908aebe40c3b0bffe0092876db597`。2189/114冻结输入、8个无关磁盘、无目标附件及无新执行/批准/Store/来源注册再次核对通过。

2026-10-26 09:46 用户明确批准729/3d98012a一次离线续行，原问题/答复及精确approval.json已保存。2189/114输入、8盘、目标无附件及初始149094400000字节（高于75GiB）通过；唯一原生认证93131/session13507退出0，root93178于09:46:10启动source-backup。独立只读收尾93204/session50437跟踪同一身份，仅全离线成功后准备待审阅运行计划；无VM/窗口。所有冻结源码保持，旧2e不重跑。
