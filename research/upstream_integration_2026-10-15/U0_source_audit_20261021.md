# 新目标 U0：固定 Git 范围和首轮源码对账（2026-10-21）

本轮承接用户“继续推进TODO”的请求，执行 T00–T02 的固定对象核验、当前修改摘要和首轮源码对账。没有合入上游实现、改变默认值、运行 VM、提交或推送。T60 具名矩阵和 DSC 局部验收沿用各自证据，不提升为新目标验收。

## Git 证据

| 对象 | 结果 |
| --- | --- |
| 本地 HEAD | `9e1c31bd`，完整值见 `evidence/U0-20261021/wip.json` |
| 既有目标 | `8a75092013eda87a4e30ed029b72028cb9279ac4` |
| 新目标 | `2a0d3aca9fb79344d939365cc337b915ae9f2f97`，已从 upstream 取得固定对象 |
| 祖先关系 | 既有目标为新目标祖先；仓库非 shallow |
| 增量 | 57 条提交：20 条 merge、37 条其他提交；first-parent 19 条 |
| 端点差异 | 215 条路径，新增 59、修改 156；内容统计 +14,553/−542 |
| 合并记录 | 20 条 merge 的全部父差异已归档；remerge-diff 均退出 0、输出为空。这不证明不存在独立解决内容或语义冲突 |
| 附件枚举 | 原附件在当前机器不可读；未执行独立附件集合比对，`observed_attachment_set_match=null` |

57 条记录已逐条路由到任务及处置类别，完整集合与 `git rev-list` 相等。该结果是首轮处置表，不是 57 条语义评审通过。旧 194 条审计只适用于旧范围，不与本轮相加。根目录 `TODO.md` 未读取；本轮端点元数据也未包含该路径。

原始审计工具要求输出在输入仓库外。本轮在当前仓库的 `.build/u0-20261021/input.git` 建立共享对象的 bare 副本，审计输出位于同级 `git-audit`，满足该约束。当前工作目录、分支和索引未切换。对象库依赖当前 `.git/objects` 的 alternates，不作为独立离线备份；原始审计输出已压缩归档。

## 源码对账

下表仅记录本轮实际检查的源码事实及后续处理。上游路径均绑定新目标；具体路径、内容摘要及行号见 `source_observations.json`。未分析内核补丁语义，也未采用其他内核数据集。

| 对象 | 证据与本地关系 | 结果 |
| --- | --- | --- |
| T08 IcliKit | 上游 workspace 和 daemon 两份锁文件为 `0.8.6 / 651ce0d0aed59d2601c35595f1a2ba7e29bb4169`；本地 daemon 为 `0.8.5 / 815ef234df5461b8eb9455931d38cb1c37992fe6`。已枚举新目标全部 7 份 Package.resolved | 固定依赖差异已确认；升级与 guest RPC 验证待执行，不自动改锁文件 |
| T15/T52 容量 | 上游 installer 在 resource key 返回 0 时使用 statfs；本地 `cfw_disk_txn.stage_copy` 已用 statvfs 的 `f_bavail * f_frsize`，资源快照另用 statfs | 存在不同实现，尚未证明全部入口合同等价；不能按上游文件名直接移植 |
| T49/T50 首启 | 上游 `VPhoneTemplateSetupBoot` 区分首启停滞并最多重启一次；本地当前创建检查点不能单独证明已有此行为 | 跟随显式模板/精简范围对账，不增加默认重启行为 |
| T61 OpenROM | OpenAVB pin `65a776e9ae00b2e1de22b18cbbad1359945d7277`，460,057 字节；OpenSEP pin `8b1633f7e6606f0bc9e1422c93e8d2e056154d2f`，147,512 字节。Git 中两份二进制 SHA-256 均与固定 README 记录相等；本地资源快照仍绑定 AVPBooter/AVPSEPBooter | 后续固定版本已明确；未重建 ROM，未验证低内存恢复或启动；本地默认值保持 |
| T62 视频 | 上游包含 `VPhoneHostScreenService`、编码器和协议；本地 `VPhoneHostScreenAdapter` 提供截图及输入能力，本轮未找到 `/v1/host/screen` 路由 | 需要协议、认证和生命周期适配；截图能力不作为编码视频已接入的证据 |
| T63 文件 | 上游 `pushFile/pullFile` 使用分块 HTTP 和临时目标。本地 API 路线已有带 session identity 的文件上传/下载和临时发布，但 `VPhoneAPIClient` 下载最大 64MiB；classic 控制及文件浏览器仍传递整份 Data | 承接已有 API 安全边界，扩展大文件合同及各客户端；不整体替换为较弱的上游临时文件创建方式 |
| T23 指针 | 上游四条非 merge 提交覆盖 guest 虚拟指针、窗口滚动/悬停、本地跟踪及非 key window | 成组路由至 T23，完整 guest/host 语义与实际输入待验证 |
| T24 AMFI | 上游新增按 requirement 内容判断 adoption；本地现有入口为 amfidont/CDHash 路线 | 机制不同；上游修复不直接证明本地同类缺陷，不执行宿主安全修改 |
| T09/T10 seal | 上游最终 pipeline 在 selection 条件满足后读取 SystemVolume hash metadata，对 SHA-256 标记 not applicable；后续提交保留显式选择 | 两条提交作为最终组合审阅，不能只移植版本条件或覆盖用户选择 |
| T64 tvOS | 范围含 HD/4K、OTA 配对和 RootHide parent 缺失修复；本地 `bootstrapRoots` 直接枚举该 parent | 待选择 tvOS 范围；缺失 parent 的本地适用性和回归待验证，不声称已复现 |
| T65 X1/工具链 | X1 提交与 `.github/workflows/build.yml` 的 `xcode-27` runner 分别记录 | 保留可选范围；CI runner 不证明最终 escalator 切片或运行兼容 |
| GPU 索引 | 两条提交涉及 ParavirtGPU 索引修改和更新入口文档 | 路由 T10/T17/T32；尚未审阅补丁语义或实施新补丁 |
| 发布元数据 | 2.9.5、2.10.1 和下载记录分别路由 T28/T29 | 保留本地版本及产物来源，不复制上游公证结论 |

上述发现来自固定 Git 源码和本地代码。README 中对 ROM 低内存问题的解释仍是上游记录，本轮只验证 pin、二进制大小和摘要对应关系，没有独立复现。

## 验证与限制

执行入口：

```sh
git fetch --no-tags upstream 2a0d3aca9fb79344d939365cc337b915ae9f2f97
git clone --bare --shared --no-hardlinks . .build/u0-20261021/input.git
/usr/bin/python3 research/upstream_integration_2026-10-15/tools/audit_upstream_scoped.py --repo .build/u0-20261021/input.git --out .build/u0-20261021/git-audit --base 8a75092013eda87a4e30ed029b72028cb9279ac4 --target 2a0d3aca9fb79344d939365cc337b915ae9f2f97 --ledger .build/u0-20261021/unavailable-input-ledger.json
/usr/bin/python3 research/upstream_integration_2026-10-15/tools/reconcile_oct20_range.py --repo .build/u0-20261021/input.git --audit .build/u0-20261021/git-audit --out .build/u0-20261021/reproduced-dispositions.json
/usr/bin/python3 research/upstream_integration_2026-10-15/tools/reconcile_oct20_range.py --repo . --audit .build/u0-20261021/git-audit --out research/upstream_integration_2026-10-15/evidence/U0-20261021/commit_dispositions.json --verify
```

工具拒绝已存在的输出目录/文件；复跑时使用新输出路径。首轮没有附件枚举文件，`--ledger` 明确指向不存在的路径，没有用本轮 Git 集合冒充独立附件。结构验证、重复生成比较、错误范围/遗漏提交拒绝和证据摘要检查见 manifest。

当前 `.venv` 指向已不存在的 `..venv.generations/env-pereh1d9`。本轮只使用 Python 3.9.6 标准库执行审计，没有运行依赖虚拟环境的测试、Swift 构建、固件或 VM 验证。WIP 摘要和 tracked diff 不是完整备份，目录条目仅记录状态；既有未提交文件原地保留。

T00–T02 的 Git 核验和首轮路由已完成，完整语义评审仍待继续。下一项先恢复受锁文件约束的项目 Python 环境，再审阅 T08 的 0.8.6 依赖差异及 guest RPC 兼容；随后按现有依赖推进 T47/T48 的来源与恢复边界。T61–T65 的范围、默认值和实际 VM 验收条件不由本轮路由自动满足。

证据：[manifest](evidence/U0-20261021/manifest.json)、[逐提交处置](evidence/U0-20261021/commit_dispositions.json)。
