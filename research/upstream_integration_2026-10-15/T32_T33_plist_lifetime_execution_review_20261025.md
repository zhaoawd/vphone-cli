# T32/T33 EXP 暂存文件生命周期修复与离线执行审阅（2026-10-25）

状态：用户已批准f430/4376一次离线计划；原生root74293正在执行首次on，尚未发布或完成独立验收。f430 Store安装、12份完整写前备份及绑定/正式plan核验已通过。T32/T33整体未完成，accepted=false；regular三Mach-O完整应用→撤销→精确重应用已通过，不重复执行。EXP同一generation的完整离线序列、GUI及应用消费验收仍待完成。

## 上一轮结果和原因

已批准的3ffd候选/821b计划运行一次后失败，独立收尾完成。首次on事务20261025T114952Z-zhZ5OOCf在最终组合核验报告`transport input differs from preceding observed output`，未发布，off/reapplied未执行，原Disk未交换。旧批准已消费，旧执行器与记录保持；无自动重试、回滚、VM启动或辅助窗口。

33482条原始记录的状态衔接扫描发现一处不一致：index33459复制`.cfw_temp/launchd.plist`时输入为missing，基础阶段index753的先前输出为file。基础脚本已清理临时目录，EXP随后复用同一路径。回归使用实际基础复制/清理、两次EXP LaunchDaemon注入及真实最终效果核验复现同一报错。修复为EXP使用独立`jb_launchd.plist`；两次注入共6处引用改为该变量。生产校验器、目标表、签名算法和指令补丁均保持。

完整原始记录的诊断副本仅改6条私有暂存路径，before/after状态不变；状态衔接和必需生产步骤覆盖通过，包含24292个模型目标。119组保存的历史字节/签名链检查0失败。原始journal SHA-256为`f8f2d9963fef16e250663c956b515e702fd2c63470bd31229568706136d01be3`。这些检查使用历史状态或反事实模型，未读取失败事务的最终磁盘/当前Guest元数据，不能计实际部署或运行验收。失败暂存磁盘已经被原生产事务清理，`--keep-artifacts`未保留该盘。

## 候选和验证

新候选：`2.6.2-local.f43043c4c559`。以保留的3ffd tar为基线，仅`Contents/Resources/scripts/cfw_install_exp.sh`、provenance、build-dependencies、CodeResources及CLI签名相关字节发生变化。完整Bundle、签名和entitlements核验通过；CLI可执行内容及VM可执行文件保持。没有Swift重编译。

- tar SHA-256：`ccab620462599a22502510ff29861df158252c8f8ce8733060015eea32d86c73`
- CLI SHA-256：`d1d42dab02420b980854a27abd9a36d96dc4fa21104cb1f38656f7a751e9f96a`
- VM SHA-256：`c8cf3d3685557f7218f4cde13efc68590c80f4ec97f3274e904be721b23fa9e2`
- 目标规则SHA-256：`cf03209f536f245fb775a5a146eaa6a769d6c427ec061c644b9a5a1bc67354a8`

验证命令与结果：

- `.venv/bin/python -B scripts/run_tests.py python`：1139项，4跳过，325.124秒，退出0；日志`exp-plist-lifetime-python-20261025.log`。新回归先复现原错误后通过，未记录的Guest plist改动仍被拒绝。
- `PYTHONPATH=research/upstream_integration_2026-10-15/tools .venv/bin/python -B -m unittest test_t33_plist_lifetime_acceptance test_t33_dev_overlay_acceptance test_t33_consumer_preparation`：26项通过。覆盖新候选与既有generation、75/50 GiB、完整备份和缓存保留、批准缺失不执行、首次失败消费调用、重复启动拒绝及原始SSH元数据保留。
- 沙箱内首次执行器测试因`/bin/ps`权限被拒绝，未到达夹具执行步骤；保留日志。经原生只读权限运行后通过，没有降低断言或变更生产进程身份检查。
- `prepare_t33_plist_lifetime_acceptance.py`完整读取当前64 GiB Disk及10项源备份，Disk SHA-256均为`d17da7ea1734a1edeb92ee474a878b92d0e6717241f87df7c45732ddffcc8282`。核对8个无关磁盘身份、当前绑定、四份failed事务和无已发布Guest；未安装或运行CFW。

## 一次性离线范围

计划SHA-256：`4376d79c942fe26e04a8014d1de6d88c8bc5a49e61c58b49127cfa98e0d14dd7`。

计划文件：`.build/t32-t33-completion-20261023/exp-plist-lifetime-acceptance-20261025/offline-plan.json`。1460项计划输入、102项执行输入已冻结。准备时可用空间100750770176字节（93.83 GiB），初始75 GiB门通过；执行时重新核对，后续每次CFW须50 GiB。

目标仍为`.build/t33t-20261025`，generation `e45c2fedee57f70b05bf7e4fe8fc6946b21b0aded7dadf4f66760f0304274308`。先通过原生完整预检、锁和无附件检查，再创建12份完整启动/绑定/desired写前备份到`.build/t32-t33-completion-20261023/t33t-before-plist-lifetime-20261025`，将现存`cfw_input`和`cfw_jb_input`移入该备份。私有desired文件当前仅继承上次原生完整摘要并核对未变lstat；新root预检必须在任何写入前重新完整读取，不能只用继承记录。

空`.ssh_forward`的完整内容、mtime、mode及原始UID0/GID20已冻结并复制为用户所有的存档文件；原始所有权单独记录，存档载体UID501/GID20。不得将它表述为物理所有权相同的第13份备份。

通过预检后安装f430到`/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.f43043c4c559/`，核验Store并重绑现有t33t，执行一次EXP应用→SystemVersion声明撤销→精确重应用。目标为SystemVersion两个路径；构建号23Z999999。各阶段独立读取完整目标、来源及原件，重应用比较完整字节和mode/uid/gid。

保留全部其余VM、磁盘、备份、候选tar以及四份失败记录和剩余产物。先前获批96cd清理已退役旧DSC完整历史和hnTJT23g部分effect-blobs，不能声称旧状态仍有完整重放链。本计划不新增数据退役。正常事务清理按现有生产行为执行。

任一失败即停止；不重试、不自动回滚、不启动VM或辅助窗口。独立收尾核对同一个root进程身份和输出。离线全部成功后，才可生成后续待审阅运行计划；生成计划不会启动VM。

## 后续运行限制和批准依据

运行准备入口已改为读取本轮执行器及本轮独立收尾manifest，避免继承旧候选的证据路径。实际VM启动/单次辅助窗口仍须单独批准；About必须实际显示23Z999999，完整AA.gl读取安排在解锁尝试之后，并核对PID、AX和截图。每次RPC有独立100秒预算，不能使用宿主75秒调用上限推断Guest总预算。

EXP正常首次启动在done marker缺失时会执行已部署`vphone_jb_setup.sh`：安装暂存Sileo/额外包、修改APT源、update/upgrade、安装libkrw0-tfp0/TrollStore Lite并运行uicache。后续运行计划必须明确列出这些自动行为。实际运行计划和运行备份尚未生成。

本轮需要新的具名批准，依据是用户提供的AGENTS.md执行约定4：“删除数据、强制推送（force push）或修改当前仓库以外的内容之前，停止并请求确认。” f430的仓库外Store安装超出已消费的3ffd/821b批准范围；当前只完成仓库内准备工作。

2026-10-25 续验准备证据归档完成：40份文件逐一复制及完整读回，manifest `12d833e09f757485aad9d466f2dfd031f318aec1dc774905437d4f16276d5255`；包含56,008,539字节原始失败journal，摘要保持。候选f430/计划4376d79c…d14dd7尚未批准、未安装或执行。下一步仅等待本轮具名Store及一次离线计划批准；没有VM/辅助窗口批准。

2026-10-25 21:22 用户明确批准f430/4376一次离线计划，原文与批准标记已保存。1460/102输入、SSH存档、8盘、无附件及初始101694894080字节通过；原生认证session24930完成，唯一root74293（21:21:44）启动完整预检。只读收尾与consumer准备等待器跟踪本轮；无重试/回滚/VM启动/辅助窗口，candidateInstalled尚待确认。

2026-10-25 21:29 唯一root74293完成12份完整写前备份读回及cfw_input/cfw_jb_input移入新备份；f430 Store安装/核验通过（安装时间13:28:19Z、VM CDHash f5f400e7e2c9e582059f52080dafe66850444973）。执行到bind/verify-plan，首次on尚待日志确认。独立收尾session20331、consumer等待session63044保持；无VM启动或辅助窗口。

2026-10-25 f430首次on全部生产步骤完成，进入暂存磁盘最终Guest效果核验。原生命令观察确认bootstrap移动包含.procursus_strapped，sshd回写使用独立.cfw_temp/jb_launchd.plist；jb-setup/sshd注入及两份SystemVersion改写均有完成日志。尚无最终效果通过、发布或独立审计报告；off/reapplied未执行。root74293及两等待器保持，冻结输入未修改。

2026-10-25 f430首次on两轮最终效果核验均已越过旧失败点，正常卸载后seal/交换发布及finish完成；事务20261025T132920Z-adMN63qO，当前Disk inode251754611，原Disk保留在该事务/Disk.img。正式CLI日志完成并记录variant exp；尚无on.json，独立完整磁盘/目标审计待完成，不能计完整首次on验收，更不能计on/off/on或运行验收。root74293继续，不启动VM/辅助窗口。

2026-10-25 22:37 首次on独立审计通过：24292/24292完整目标字节及mode/uid/gid一致，14项DSC及7项file来源关联；当前完整盘SHA104c89afb70841172e6eb8bd0991c4d1b7b72fde763731af4c8258b5ba301358，同一generation，来源收据与host/guest绑定均f430。on.log21:28:43至22:23:43，on.json22:36:51；22:37:03进入off。独立审计本身originQualified=false，来源资格由sourceReceipt及componentReceipts明确给出true，来源producer精确匹配候选。整体未完成、runtimeValidated=false。

后续准备入口字段缺陷已独立复现并修正为prepare_t33_consumer_runtime_receipt.py，新增8项回归通过（含实际on报告字段合同＋夹具三阶段finalization，不能计真实离线/运行验收）。要求独立审计originQualified=false，同时严格核对来源收据资格、generation/transaction/完整盘摘要及producer版本/tar/CLI摘要；没有放宽来源门。旧consumer等待器63044及其源码保持冻结，预计完整离线成功后因旧字段拒绝且在创建备份前停止；届时先确认它已停止且无运行产物，再运行新入口一次。新入口未执行prepare，未生成实际运行备份/计划或启动VM。原离线1460/102冻结输入不包含这两个准备源码，执行器和finalizer未改。

2026-10-25 耗时观察：用户询问当前进度与耗时。实测写前备份记录21:28:16，首次on.log21:28:43至22:23:43，on.json22:36:51，off.log22:37:03。安装/两轮核验/发布约55分钟，随后独立读回及来源/Undo检查约13分钟；不能据此估算重应用剩余时间。代码audit_locked在实际目标读回前后均调用committed_guest_evidence；inspect_phase随后另调用committed_guest_evidence、inspect_guest及Undo预览/原件读取。重复调用为代码事实，其各自耗时占比未测出。普通用户sample74293被系统权限拒绝；未为此请求新管理员认证或修改执行器。撤销实际原生子进程12235为prepare-undo，观察CPU约90.5%，当前没有错误或off.json。

2026-10-25 22:53 撤销耗时的静态下界已查明：guest_undo.prepare先调用committed_guest_evidence，再不传已有parent调用preview；preview入口/末尾各调用一次committed_guest_evidence，prepare末尾再调用一次。因此此prepare成功路径至少4次完整已发布盘验证，另有checked_image_digest暂存盘1次。cfw_disk_txn.verify_guest_evidence每次先checked_image_digest，盘64GiB，故仅这些路径至少读取320GiB，尚不计BLOB复制/摘要、签名页和generation来源核验。preview已有_committed参数；prepare未复用parent。这是代码可证的重复读取机制，实际CPU/IO耗时占比未测出。当前root原生进程仍在prepare-undo，活动1460/102输入保持冻结，不热修或重跑。

2026-10-26 恢复核查：主机于2026-10-25 23:20:02重启；root74293和两个等待器均结束，原执行没有result/finalization，不能伪造为正常收尾或重跑4376计划。首次on完整64GiB摘要104c89…1358与原发布相同；24292/24292目标重新只读核对通过。撤销W7aZSh3x仍staged，未密封/未发布，完整盘摘要bdebbae8…92ef，24292/24292目标与保留final效果一致；不构成Undo发布成功。1460/102输入完整摘要及私有desired保持。两盘无挂载。st_dev从16777231变为16777234，inode/size/mtime保持，生产is_same实际返回false；当前卷UUID1986C66F-89E4-4E75-9F4F-1515116F1A52，历史记录没有该稳定卷身份。历史未改写，无CFW重试/恢复/密封/发布/VM启动。归档6项，manifest 8f280065c4a502693c223a13b1baa3684bd26dd2ab5ed8edee718e9f05201316。恢复方案需处理跨重启身份与未完成密封，现有自动recover不授予跨dev继续发布资格。
