# T32/T33 EXP bootstrap续验审阅（2026-10-25）

待批准对象为候选`2.6.2-local.3ffd9e46ee74`和新计划`821b1d69278b77cb650a7a4b11cccc8bfb5b373928dcae8515e1307b0d8d15bc`。候选尚未安装，新计划未执行。T32/T33整项accepted=false；真实Settings、AA.gl及应用消费仍待验收。

前次9770的安装/绑定/写前备份通过，首次CFW全部生产步骤执行，最终效果核验拒绝`consumed container still has required members`。事务20261025T100633Z-Bvlz2q7C未发布，off/reapplied未执行，原Disk未交换。原生/独立收尾已结束，源备份10项、写前12份完整备份、872/102输入、8个保留盘和无附件通过，最终manifest49456ade43024eb9a30559afe2c594657769a53170df03b9f2baf5b7458088f7。旧计划98a945b1已消费，不得重跑。

只读重放33481条原始记录，在index33417复现同一错误。必需文件.procursus_strapped从var/jb移至procursus/jb后，未被`*(N)`移至最终目录，随后删除容器时一并删除。现有目标表已声明正确移动路径。EXP改为`*(DN)`保留隐藏成员，并移除吞并移动错误的处理；目标表、校验器、其他变体和指令算法保持。

验证结果：

- 两项实际EXP Shell、真实guard和最终transport回归先失败后通过；原错误和吞并错误均可复现，未记录标记变化仍拒绝。
- 完整真实bootstrap的6528成员经过受限复制/解包、两次移动、容器和归档清理，32639条效果记录得到19583个最终目标，严格最终读回通过，标记漂移仍拒绝。计划与客户机根为夹具，不计真实部署。
- `.venv/bin/python -B scripts/run_tests.py python`：1137项，4跳过，308.834秒，退出0。新执行器及既有执行门联合19项通过；Shell语法、目标规则生成一致性检查通过。
- 新候选从摘要核验的9770 tar生成独立基准，完整资源/签名/entitlements检查通过。变化仅EXP Shell、来源/构建记录和CLI/资源签名；CLI非签名内容、VM和客户机资产保持。VM SHA-256为c8cf3d3685557f7218f4cde13efc68590c80f4ec97f3274e904be721b23fa9e2，目标规则仍cf03209f536f245fb775a5a146eaa6a769d6c427ec061c644b9a5a1bc67354a8。

候选tar：`.build/t32-t33-completion-20261023/2.6.2-local.3ffd9e46ee74.tar`，SHA-256`fe682f4acd26974834ebd8a8776c63626022277df26ff0e4ef4008b6b7723991`。计划路径：`.build/t32-t33-completion-20261023/exp-bootstrap-acceptance-20261025/offline-plan.json`。

本次范围：复用t33t和generation e45c2fedee57f70b05bf7e4fe8fc6946b21b0aded7dadf4f66760f0304274308，不创建VM或重新生成固件。先完成原生完整预检，再创建12份完整启动/绑定/desired写前备份；现存cfw_input及cfw_jb_input移入新备份，不删除旧缓存。安装3ffd到Store并绑定，执行一次EXP应用→SystemVersion声明撤销→精确重应用，各阶段独立读取完整目标、来源及原件，重应用比较完整字节和mode/uid/gid。任一失败即停止，无自动重试或回滚。

本次普通用户已完整重读当前Disk，SHA-256 d17da7ea1734a1edeb92ee474a878b92d0e6717241f87df7c45732ddffcc8282与保留源相同。其余可读启动输入、本轮三份failed transaction记录、源备份10项完整内容及8个保留磁盘身份通过。私有desired摘要仍来自前次原生完整读回，本次只核身份；新root预检必须完整重读并精确核对后才能写入。

上一轮新增的空`.ssh_forward`所有者为UID0。其完整内容及原始mode/uid/gid/mtime/身份已记录，归档载体为普通用户UID501；原始所有权单独保存在计划中。原生开始前同时精确核对源和存档，完成后核对不可变存档及原始元数据记录。此处不把载体所有权写成原始所有权；若以后恢复原始UID0，仍需另行授权的管理员恢复。第一份未批准准备在物理所有权相等检查时停止，原日志和原载体保留；本计划明确采用内容加原始元数据记录的归档方式。没有删除或覆盖前次失败记录。

新计划冻结1159项计划输入及102项执行输入。准备时可用110397820928字节（102.82GiB）；初始75GiB、每次CFW前50GiB门槛保持。保留其余所有VM、磁盘、源备份、regular已通过链、三次失败历史和所有tar。旧hnTJT23g effect-blobs及旧DSC完整CFW历史已在清理96cd7a4f中退役，不宣称完整可重放。

本计划没有VM启动、辅助窗口、新数据退役或发布。consumer准备等待器已随上次失败停止，没有生成实际运行计划或备份。后续准备入口已绑定本次新执行器，并会在离线完整通过后备份启动文件/绑定/主机标记、绑定实际Store VM身份，再生成待审阅运行计划；仍需新的运行/辅助窗口批准。

确认依据是用户提供的AGENTS.md执行约定4：“删除数据、强制推送（force push）或修改当前仓库以外的内容之前，停止并请求确认。” 新Store位置`/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.3ffd9e46ee74/`不在已消费的9770批准范围内。

2026-10-25 19:42 用户明确批准3ffd及821b计划，原文/批准标记已保存；1159/102输入、SSH源与存档、8盘及无附件通过，初始可用110337474560字节。原生认证session9855生效，唯一root12587已启动并正在完整预检。独立只读收尾session67411跟踪同一进程，consumer准备等待session44457只在完整离线/独立收尾通过后生成待审阅计划，VM/辅助窗口不自动启动。

2026-10-25 19:49 本次root12587完成12份完整写前备份读回、cfw_input/cfw_jb_input两类缓存保留，3ffd安装/Store核验、绑定和正式plan验证通过；首次on暂存zhZ5OOCf开始。另确认EXP正常首次启动脚本会在done marker缺失时安装包、执行APT update/upgrade及uicache，后续计划现明确列出这些自动行为，当前离线不启动VM。准备等待器原session44457因源码更新按守卫停止，r2/session70506另名继续等待；独立离线收尾session67411不变。


## 821b执行结果与暂存生命周期修复

原生root12587及独立收尾session67411已结束。首次on事务20261025T114952Z-zhZ5OOCf完成全部生产步骤，最终核验报transport input differs from preceding observed output，未发布，off/reapplied未执行。源备份10项和写前12项完整读回、SSH完整内容及原始UID0元数据存档、1159/102输入、8盘及无附件通过；manifest5d5a3039a107d3e2fc618b5b8966845d3728643d90b79dbee2f48a67bdddea5a。原Disk未交换；原生original_check仅身份和66段采样通过，不宣称新完整盘读回。consumer r2/session70506因离线失败停止，未生成实际运行备份/计划或启动VM/窗口。原821b计划不得重跑。

33482条原始记录的全部状态衔接扫描只发现一处：index33459对.cfw_temp/launchd.plist的复制输入为missing，基础阶段index753的上次记录仍为file。基础脚本通过cfw_guest_write清理临时目录；私有临时删除不会形成Guest目标效果。EXP后续复用同名文件使两次暂存生命周期混在同一路径中。实际base复制/清理、EXP两次LaunchDaemon注入、真实guard和完整最终transport回归先复现同一错误后通过；EXP使用独立jb_launchd.plist，不改目标表、权限边界或校验器。

针对完整原始记录，诊断副本只改EXP后续6条记录中的临时路径，所有before/after状态保持不变；真实组合谓词和必需效果覆盖通过，24292个模型目标。另按现有保存BLOB验证接口检查119组历史字节/签名链，0失败，原始journal SHA f8f2d9963fef16e250663c956b515e702fd2c63470bd31229568706136d01be3保持。模型不读取最终磁盘或Guest当前元数据，不计部署或运行验收；没有修改原始失败记录或放宽生产校验。证据transport-continuity-scan-20261025.json、transport-chronology-analysis-20261025.json、recorded-effect-chains-20261025.json。

完整Python1139项（4跳过）、325.124秒、退出0。新候选与新具名计划尚待准备，没有新Store安装、CFW、VM启动或辅助窗口。
