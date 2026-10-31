# 项目空间清理评估（2026-10-25，T32/T33续验前）

建议优先清理重新生成的构建输出和测试缓存，分配量共2.27GiB；另有5份旧候选解包目录共0.91GiB，可从保留tar恢复。8个对象分配量合计3.18GiB。尚未删除任何文件，当前请求仅授权评估。

按statvfs口径，本次检查可用80691200000字节（75.15GiB），已超过离线计划75GiB初始门槛，余量约0.15GiB。本轮未删除数据，空间增长原因未查明。是否执行仍由正式执行器在写入前重新核对；不以本次容量读数保证后续空间。

## 优先对象

路径相对 `/Users/kolar/github/vphone-cli/`。

| 路径 | 分配量GiB | 影响 |
| --- | ---: | --- |
| `.build/out` | 2.159 | 构建产品、编译中间文件及内部缓存；`.build/debug`、`.build/release`所指产品需重建 |
| `.build/test-module-cache` | 0.114 | 后续测试需重新生成模块缓存 |
| `.build/test-cache` | 0.0003 | 后续测试需重新生成manifest缓存 |

当前运行VM PID33355使用独立 `.build/vphone-cli.app/Contents/MacOS/vphone-vm`，不位于上述目录。本次未观察到构建或CFW进程。

## 可从tar恢复的旧解包目录

以下路径均位于 `.build/t32-t33-completion-20261023/`。仅评估解包目录，保留tar、候选JSON、日志及研究证据。

| 解包目录 | 保留tar | 分配量GiB |
| --- | --- | ---: |
| `producer-package-final-20261024` | `2.6.2-local.4f9d10893183.tar` | 0.181 |
| `origin-identity-package-20261024` | `2.6.2-local.a84f5889b159.tar` | 0.181 |
| `exp-cryptex-links-package-20261024-r3` | `2.6.2-local.16f1cc296c84.tar` | 0.181 |
| `exp-target-binding-package-20261025` | `2.6.2-local.caa8df845ab6.tar` | 0.181 |
| `exp-signing-package-20261025` | `2.6.2-local.702b93cd192a.tar` | 0.181 |

5份tar完整SHA-256与候选记录相同；1395个普通文件逐字节摘要、模式、成员类型和符号链接比较通过。部分旧构建/重放工具引用这些解包路径，删除后须先从保留tar恢复相同路径；不因此丢弃旧候选或更改历史记录。

## 核验与保留范围

活动计划b2f587be…及其执行输入合并后382个唯一文件路径均不引用这8个目录；这些目录没有Git跟踪文件。8次lsof +D均退出1且无输出或诊断；当前7个hdiutil附件均不位于候选目录。清理执行前仍须重新检查。

保留当前候选 `exp-signing-package-20261025-r2` 及a480e6e8785e的tar、全部VM和绑定前备份、pre-acceptance-backup、原始IPSW/ROM、锁定Python环境及研究证据。不得单独清理 `.cfw-history` 的Disk.img、guest-postimage.img或effect-blobs；它们参与来源、磁盘身份和撤销核验。

当前源备份及原件目录仍有root私有内容；本次没有把不可读内容记作零，也没有将它们列为缓存。此前已退役的旧r2 VM及四项旧实验状态不再计入可清理量。

上述数值是du/st_blocks分配量，APFS克隆可能共享物理块；未测量独占extent，因此不能承诺实际可释放3.18GiB。检查未运行产品测试。

证据：`research/evidence/project-storage-review-20261025/assessment.json`、`open-handles.json`及`attachments.plist`。实际删除需按AGENTS.md执行约定4取得具名确认。
