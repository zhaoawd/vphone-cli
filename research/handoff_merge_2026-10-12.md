# Handoff 与固定上游开发线合并（2026-10-12）

实施计划：`docs/superpowers/plans/2026-10-12-handoff-merge.md`。

## 范围

- 开发基线：`2c119ae60996ddd59783327b063a2a4aeeb297b1`。
- 待合入：`959acfc0b08d433520c976c693a0a2076499dfbf`。
- 共同祖先：`e8d825b3723d9ec72d31b050a79d353acd4b59bf`。
- 本轮工作树：`/Users/qcz3840/.codex/worktrees/handoff-merge-20261012/vphone-cli`。
- 用户已批准合并、解决冲突和工程验证。本轮不推送远端，不操作 VM、磁盘映像或宿主安全设置。

## 决策

1. 现有开发工作树属于另一聊天；本轮使用新工作树。基线直接取远端最新提交，目标本地分支最后在干净状态下快进。错误判断的影响：需重新检查其他聊天的开发状态后再更新分支。
2. 默认保留 classic 控制/相机与独立现代 API；显式 regular-v2 保留 handoff 的相机关闭设置。两套安装候选使用同一 API 编译产物与不同的 plist/清单，避免默认构建校验被旧候选身份覆盖。错误判断的影响：需要调整候选选择和组合校验，不能以历史 VM 验收替代。
3. API 缓存及 pending/confirmed 标记保留新开发线的名称；v2 profile 跟随该实际实现。API_ONLY 与 proxy 信号/文件描述符清理约束保留。错误判断的影响：旧 v2 缓存标记需兼容处理；本轮不宣称旧 v2 原地迁移已验证。
4. 固件事务保留最新 plan/versionInputs 绑定并记录实验选项。root-remount 保持显式 regular-v2 实验，不修改补丁算法或扩大默认变体范围。错误判断的影响：需要重跑对应固件及检查点验证。
5. create 将 v2 组件与 API 候选复制到签名 Bundle 外的 `GuestInputs`，包括环境变量指定的输入，摘要纳入资源快照。CFW 使用快照路径。v2 安装器同时核对固定 API pins、overlay 声明与二进制 marker，拒绝过期候选。

## 合并修正与审查

- 12 个文本冲突保留最新事务计划、版本输入、API_ONLY、缓存及 proxy 连接清理逻辑，并接入 handoff 的显式 v2 与实验选项。
- 冲突处理脚本的一次正则匹配跨越多个冲突块，造成文件截断。已从合并索引的三侧完整版本恢复后重新合并；最终未保留截断内容，后续验证均使用恢复后的完整文件。
- `GuestDaemonMode` 兼容 `VPHONED_VCAM=off`。默认及显式 v2 使用同一固定依赖 API 编译产物，候选分别为 `candidate` 与 `candidate-v2`，各自使用对应 plist。
- API updater、native proxy 与 v2 profile 统一使用最新 `vphoned.api-v2` / `.pending` 标记；二进制缓存仍为 `vphoned-api`。
- 新版固件事务要求已知版本。原实验测试夹具未声明版本，已补充 26.1 BuildManifest，并断言 plan、versionInputs、planBinding 和实验 gate 同时存在。
- 独立审查发现快照遗漏候选、v2 安装缺少依赖及 overlay 校验两项问题。新增测试在修复前分别因缺少快照输入、错误接受过期候选失败；修复后安装测试通过，静态复核未发现剩余 P1/P2 缺口。

## 验证进度

- 基线 daemon：46 项，失败 0，跳过 3。日志 `research/artifacts/handoff-merge-2026-10-12/baseline-python.log`。
- 基线 Swift 首次因新工作树子模块未初始化失败；随后初始化固定子模块并复验。
- 基线 Swift 定向测试：146 项通过。
- 相机配置兼容回归：新增 `VPHONED_VCAM=off` 输入后断言失败；证明基线的 `GuestDaemonMode` 未识别该 v2 设置。日志 `v2-camera-red.log`。
- API 双候选验证及身份回归 9 项通过，v2 安装相关测试 17 项通过，固件实验事务定向测试通过。
- 第一次全量 Python：678 项通过、跳过 3 项。审查修复与依赖构建后的最终 `make test_python`：679 项通过、无跳过，耗时 342.577 秒；包含真实 insert_dylib 合成文件检查及固定 IcliKit 的两项宿主测试。日志 `final-python.log`。
- 资源结构增加字段后的 Swift 增量测试两次以信号 11 退出，栈位于 Fixture 初始化复制。原因未查明；已清理本工作树 debug 构建缓存后重新运行全量验证。
- 固件夹具预检：现有目录 17 个必需文件完整；预检本身不执行固件比较。
- 清理 debug 缓存后 `make test_swift` 通过：254 项 XCTest（跳过 3 项）、1311 项常规 Swift Testing、9 项时限测试；tar/file digest 内存检查、RootHide loader links、VCam 与 VirtIOSound 宿主测试均通过。新增 v2 输入快照测试的默认及外部覆盖两组均通过。日志 `full-swift.log`。
- `VPHONE_TEST_FIXTURES=/Users/qcz3840/github/vphone-cli/ipsws/patch_refactor_input make test_firmware`：15 项、12 个 suite 通过。输入夹具未改写；本结果不建立 restore、boot 或应用功能验收。日志 `firmware.log`。
- `make guest_components_build` 与完整 `make build` 通过。默认 classic/API 组合、两个候选、7 个宿主 Mach-O 映像、最终 Bundle 资源/签名/权限检查通过；未部署或启动 VM。日志 `guest-components-build.log`、`signed-build.log`。
- 实际 v2 签名候选通过安装器只读预检。两候选在签名区之前的字节一致，签名区独立生成，文件摘要不同。
- 18 个 Python 与 6 个 zsh 变更文件的语法检查通过。两条远端分支在提交前复核时仍对应本轮基线与待合入 SHA。
- 实际签名 Bundle 快照只读检查通过：CLI resources 退出 0、复制后严格签名检查退出 0、22 个 `GuestInputs` 条目纳入快照。VM 运行时 `--help` 在原产物和复制产物均返回 9；本轮原因未查明，不据此认定运行时可用。默认外部 Python 只读可用探测为 false；显式指定项目 `.venv/bin/python3` 后为 true。两次检查均通过，未自动创建 Python 环境。

## 证据与分支收尾

验证日志归档在 `research/handoff_merge_2026-10-12/evidence/`，摘要、命令和日志 SHA-256 见同目录上层 `validation.json`。完整未压缩日志保留在本轮独立工作树的 `research/artifacts/handoff-merge-2026-10-12/`。

合并提交的两个父提交应为本记录的开发基线与待合入 SHA。提交后仅在目标分支仍为预期 `d3933189` 且工作树干净时快进本地 `codex/upstream-2d21d21-integration`；最终 HEAD 以 Git 历史及会话最终核对为准。远端不推送。主工作区保留原分支和三份未跟踪研究记录。已签名产物保留在本轮独立工作树，目标工作树现有构建产物未重建。

## 验收限制

历史 `accepted` 项保留原日期、源码与实验范围。本轮源码组合改变后，不自动扩大其验收范围。完整现代环境/相机迁移、T17 可写重挂、在线替换与成功回退、新 Bundle 独立 VM 启动仍须真实验收。
