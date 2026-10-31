# T32/T33 EXP 暂存文件生命周期修复与离线执行审阅（2026-10-25）

状态：新候选和一次性计划已准备，尚未批准、安装或执行。T32/T33整体未完成，accepted=false；regular三Mach-O完整应用→撤销→精确重应用已通过，不重复执行。EXP同一generation的完整离线序列、GUI及应用消费验收仍待完成。

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
