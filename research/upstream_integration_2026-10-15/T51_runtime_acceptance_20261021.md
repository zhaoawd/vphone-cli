# T51/T52 真实磁盘、VM 与界面验收：2026-10-21

本次具名验收范围已完成：真实64GiB磁盘rebase、两次正常启动/关机、运行期间互斥，以及签名Launchpad实际界面回归均通过。用户指示暂缓外置物理卷验收。所有结果保留accepted=false，供人审；未提交或推送。

## 对象与磁盘结果

- 原始输入为停止的 `vm-new`。只读目录锁、lsof和挂载检查通过后，APFS clone建立 `.build/t51rt/lib/base` 与 `target`。两次启动只使用target；原始VM和base均未启动。现有 `vm-2607` 保持原PID33355。
- 目标副本先重写64MiB相同内容，形成私有块。磁盘逻辑大小68,719,476,736字节。正式CLI预演、rebase、交换后预演均退出0。
- published journal报告比较25,081,413,632字节，新增共享67,108,864字节，写入和打洞均为0。交换耗时139.53秒。交换后预演新增共享0.00GB、已有共享25.08GB。该报告不证明系统空闲空间立即增加。
- Disk.img inode从248260891变为248276858。启动前，目标和base的9个具名文件完整SHA-256与原输入一致；另1份SHSH票据摘要相同。并未对整个约1.47万文件目录声称完整摘要验证。
- 无 `.rebase-*` 待恢复目录，published journal位于目标 `.disk-rebase-history`。启动后target继续保留rebase产生的inode；Disk/NVRAM/SEP允许正常guest写入，因此不声称运行后的内容仍等于启动前摘要。
- 两次启动结束后，原输入9个文件的完整摘要、dev/inode、大小、mtime/ctime和分配量复核保持；base磁盘身份及stat版本保持。target的config、staged daemon、两份ROM和UDID记录摘要保持。

## 两次真实启动与关机

使用r2候选内嵌的已批准VM程序，以 `--headless --no-vphoned-update` 启动target；未安装或更新guest组件。通过生产host-control socket查询capabilities、kern.boottime与SystemVersion.plist。生产 `vm stop` 执行关机。

| 实验设置 | 第一次 | 第二次 |
| --- | --- | --- |
| VM PID | 8754 | 9350 |
| bootSeconds | 1792582426 | 1792582489 |
| instanceID | 26BACE60-CD60-4BC2-A6D6-B313A8D26717 | A8A28F28-15D9-41AC-ADE4-6FC063761118 |
| guest连接 | 通过 | 通过 |
| 系统 | iOS26.1（23B85） | iOS26.1（23B85） |
| vm stop / VM退出码 | 0 / 0 | 0 / 0 |
| Guest stopped / 强制Framework停止 | true / false | true / false |
| lsof无磁盘持有者 / 目录排他锁可取得 | 通过 / 通过 | 通过 / 通过 |

两次bootSeconds和instanceID不同。运行中执行rebase预演退出1，报VM lock unavailable，目标磁盘inode保持。普通Python读进程持有磁盘时，另一组预演退出1并明确说明该进程不运行VM；其释放由本次具名停止文件完成，没有向其他进程发信号。

## 实际界面与计量修复

独立r1候选在rebase期间显示操作中并禁用启动。停止后两次保存的界面回归均发现计量长期Unknown。实际副本各约14,707个文件，目录枚举约0.1秒。同样2秒预算下，无逐文件持有者检查映射9709文件，逐文件lsof只映射9文件；预算耗尽还使后一目录的已分配量变为Unknown。最小回归首次有4个断言失败。

修复将元数据枚举预算与物理映射预算分开。实际映射时，共享目录锁覆盖该目录整次计量；持有者预检在锁内每目录一次。每个改变的文件仍复查本地状态，Disk/SEP/NVRAM映射前即时检查持有者。pending journal逐文件门控保持。缓存未变时不取得该映射锁。正式回归覆盖共享锁排除写者、逐文件后续拒绝、预算耗尽、读错误、缓存和真实APFS克隆。

r2为新建签名候选，r1和冻结应用保留。保存的cua模块实际执行以下断言，并归档AX和截图：

| 实验设置 | 结果 | 证据 |
| --- | --- | --- |
| 启动前停止、无人持有 | 36.9GB已分配，8kB独占，无缓存提示 | ui-stopped-current-r2.json |
| Python读进程持续持有 | 已停止；独占未知，显示上次计量提示 | ui-external-reader-r2-after-refresh.json |
| 读进程释放 | 恢复36.9GB/8kB，无缓存提示 | ui-reader-released-r2.json |
| 真实VM运行 | 实例ID与runtime一致；停止按钮；独占未知和缓存提示 | authorized-boots/ui-running-instance.json |
| 两次正常关机后 | 已停止；启动按钮；36.31GB已分配、612.3MB独占，无缓存提示 | authorized-boots/ui-stopped-after-two-boots.json |

计量按约30秒间隔刷新，持有者出现后的首次采样仍可能显示前一次计量；后续刷新及恢复均保存。运行后的分配量和独占量是当前计量结果，没有将差异归因为单一操作。

## 候选与临时主机授权

- CLI SHA-256：`22347003fc5a6045b0c90ca3eff88ea04b7a261b5bd3ed3adac3e38772fdce00`。
- VM SHA-256：`4e0487e69b57f5b77db73b1085e650d87d6f998f8e3ee07c98b2573de6a553c9`；CDHash：`419d5a6c67ab6328589d27246c5d09eb8cc18312`。
- 独立CLI/r2应用通过资源、native依赖、guest cohort、内嵌工具链、签名和VM权限检查。旧API资源与新依赖图不符时检查先拒绝；采用独立guest复制目录及T08已验证0.8.6 API候选后通过，旧guest目录保持。该封装没有部署到本次guest。
- 初次VM参数探测被AMFI Code=-424拒绝。用户随后明确批准仅本次上述CDHash临时放行，并在自己的终端完成sudo认证。helper日志确认allow_all=false、无路径规则、唯一CDHash；代码不加载或写入持久允许名单。
- helper PID8387，持续约148秒。启动回归结束后写具名停止标记；helper记录stopped，独立ps检查确认该PID已不存在。没有重启amfid或修改其他允许规则。
- 冻结T60候选CLI/VM摘要保持；现有VM、原始输入、base/target及全部验收应用保留。

## 命令、证据与范围

```sh
.venv/bin/python3 research/upstream_integration_2026-10-15/tools/accept_t51_runtime.py prepare
.venv/bin/python3 research/upstream_integration_2026-10-15/tools/accept_t51_runtime.py rebase --cli .build/t51-runtime-cli-20261021.app/Contents/MacOS/vphone-cli
.venv/bin/python3 .build/t51-runtime-20261021/run-authorized-boots.py
.venv/bin/python3 research/upstream_integration_2026-10-15/tools/accept_t51_runtime.py final-source
```

上述具名步骤均退出0；prepare只接受新目录，启动runner只接受新证据目录，不可直接覆盖现有夹具。两次启动由保存的 `tools/verify_t51_rebase_boot.py` 执行；界面由 `tools/accept_t51_ui.cua.mjs` 与 `tools/accept_t51_boot_ui.cua.mjs` 执行。helper的现有停止标记保留，原命令再次运行会拒绝启动。

计量修复定向9项通过，完整Kit汇总248tests、退出0（条件跳过详日志），Python边界24项通过。本次没有新增产品源码改动，真实启动和保存的cua回归是续验步骤，不重复计入单元测试数。

证据分阶段保留：初始磁盘/界面 `evidence/T51-runtime-20261021/manifest.json`；授权准备 `authorized-boot-preparation/manifest.json`；最终启动及界面 `authorized-boots/manifest.json`。历史快照不覆盖。

外置物理卷按用户指示暂缓，未用内部Recovery卷替代。非APFS/跨设备故障、完整SIGKILL/断电矩阵、模板基准、guest图形/应用交互和guest组件更新/CFW安装不在本次已通过范围。T52的setBundle实际界面接线仍未实现，本次没有据此提升整个T52状态。T51/T52历史status、target_review及依赖保持，accepted=false。


提交范围及索引独立构建结果见[T51_commit_scope_20261021.md](T51_commit_scope_20261021.md)。真实候选证据与提交范围的回归证据分别保存。
