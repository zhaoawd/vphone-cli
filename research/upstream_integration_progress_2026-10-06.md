# 上游整合进度（2026-10-06）

## 范围与依据

上游目标固定为 `2d21d21fbdd4f51f013616273ceda9b35a3e0789`；本地起点为 `e8d825b3723d9ec72d31b050a79d353acd4b59bf`。隔离工作区为 `/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli`。

用户要求开始推进[上游增量核对](chatgpt-conversation://6ac4c887-910c-83ec-9915-8b1e2e52906b)中的整合方案。已通过 `read_thread` 取得两段正文；返回 `attachments: []`。正文提到的总体方案、47 项执行清单和 JSON 台账未取得。已请求本地路径，尚未按摘要重建 T32–T46 的逐项定义、依赖或验收条件。

执行决定：先落实[10 月 1 日交接](upstream_handoff_2026-10-01.md)执行顺序第 1、2 项明确的小修复，同时核对新目标基线。该范围不依赖缺失附件。误判该范围的影响：需按附件调整任务归属；本批没有修改固件补丁或客户机环境。

本记录是执行进度，不代替缺失的原方案。原有历史报告和通过记录保留日期及范围。未创建、读取或修改仓库根目录 `TODO.md`。

## 基线

固定上游对象已在临时裸仓库取得。共同祖先仍为 `87f796c62a7cb385cd37afce121f6e222d83e5b5`；双方独有提交为本地 262、上游 566。`a969cd5..2d21d21` 为 218 个提交、158 个非合并提交；端点变化为 357 个文件、+46,978/-2,067 行。统计排除根目录 `TODO.md`，不表示待实施任务数量。详细 SHA 见[基线 JSON](artifacts/upstream-integration-2026-10-06/baseline.json)。

创建前主工作区干净。隔离工作区通过 APFS 副本复用 vendor 和依赖缓存，`.venv` 指向原项目的已验证环境；没有安装或改写该环境。编译产物位于隔离工作区 `.build`；测试临时文件位于系统临时目录。未运行主工作区 `make build`。

容量采样：建立工作区前约 14.8 GiB 可用，完成无签名测试构建后约 11.7 GiB 可用。尚未核算固件解包、完整 VM 备份或真实恢复所需空间，T03 不标记为通过。

## 首批实现

| 问题 | 修改 | 回归验证 |
| --- | --- | --- |
| `cfw update-environment --check` 提权提示混入 stdout | Swift 提权提示与真实宿主脚本的检查进度改写 stderr；JSON 报告与退出状态保留 | 实际 CLI 运行临时报告驱动；成功 stdout 可解析为 JSON；失败 stdout 为空、保留阶段诊断和退出码。真实宿主脚本的提权及磁盘命令使用测试替身，分别检查两个输出流 |
| `vm clone` 复制根目录 `.cfw-history` | 加入根目录排除名单 | 默认原生克隆尝试与强制复制回退；源历史、持久身份、嵌套同名目录保留。默认路径是否实际回退未记录 |
| Swift 6.3 下 Launchpad 测试宏编译失败 | 辅助函数 `failure` 改名为 `verificationFailure`，避免与局部变量同名 | 原编译错误记录和修正后的 ToolchainTests |

`vm_backup.sh` 没有修改。未改变固件变体、补丁范围、相机 ABI、定位所有权或客户机自动更新策略；没有执行 sudo、客户机命令、真实磁盘挂载或 VM 启停。

## 验证记录

- 初始 Swift 编译：`#require` 宏展开把同名辅助函数解析为局部 `Failure` 值，编译失败。修正后新工作区暴露缺失的忽略文件 `VPhoneBuildInfo.swift`；按现有 `build.sh` 生成该元数据后继续。此文件未纳入提交。
- 修改前回归：52 项测试、6 个 suite；克隆的两个路径均保留不应复制的根历史；CLI 成功报告含提示导致 JSON 解析失败，失败路径 stdout 含提示。
- 修改后专项：相同 52 项测试通过。
- 初始 `make test_python`：558 项，1 项失败、1 项错误、1 项跳过。`test_root_popup_path_returns_artifacts_without_sudo_variables` 在 30 秒内未退出；`test_same_vm_shell_entry_rejects_second_installer` 在 15 秒内未取得 ready 文件。原因未查明。
- 两项 Python 用例单独重跑：2 项通过，8.488 秒。没有修改这些用例或对应生产路径；不能据此认定初始失败原因。
- 独立代码审查发现真实宿主脚本的检查进度仍写 stdout。补充实际脚本输出流断言后，6 项测试中 4 项失败；修复后 6 项通过。Python 判定器在 `--report` 模式下已经将诊断写 stderr。
- 完整 `make test_swift`：1030 项、158 个 suite，19 个 issue。包括 API 等待超时、HTTP fixture 未就绪、取消和 XPC 超时、一次 Range 断言失败，以及两项 `.ustar` 写入错误。
- 失败套件重跑：84 项、10 个 suite，剩余 2 个 issue，均为 `.ustar` 的 `Numeric user ID too large`。宿主 UID 采样为 `2035870432`；相关归档代码和测试不在本批修改范围。其余初始失败未在该次重跑中复现，原因未查明。不能把本批专项通过写为全量通过。
- 完整 `make test_python` 第二次：558 项，295.564 秒，通过，跳过 1 项。
- 最终专项 Swift 复验：52 项、6 个 suite，36.173 秒，通过。
- `check_tar_pipe_memory.py`：file/producer 两种模式分别处理约 1 GiB，计数单调，峰值 RSS 约 8.4/7.4 MiB，退出 0。
- `make test_guest_components`：退出 0；camera data-plane 124 项检查、0 项失败；loader-link 检查通过。
- `zsh -n scripts/cfw_install_host.sh`：通过。源代码、Markdown 和 JSON 的空白检查通过；原样日志包含编译器输出的行末空格，空白检查排除 `.log`，日志内容未重写。
- 完整 `make test_swift` 单独复验：1030 项、158 个 suite，70.749 秒，18 个 issue。等待超时、取消断言和两项 `.ustar` 错误再次出现；Range 断言未在这次复验中失败。
- 排除两个新增测试函数的对照：1028 项、157 个 suite，77.176 秒，19 个 issue。相同的 API 等待、HTTP fixture、取消、XPC 和 `.ustar` 错误仍出现；另外 `ConsoleLogRotationTests.firstStartHasNoPreviousLog` 的 shell 日志含 `getcwd: cannot access parent directories: No such file or directory`。原因未查明。该对照只排除新增测试函数，没有回退本批生产修改；不能据此确认全部失败原因。
- 真实 sudo、管理员弹窗、真实挂载和 VM 启动未验证。

验证输出保存在 `research/artifacts/upstream-integration-2026-10-06/`。基线及测试记录仅适用于本文列出的固定对象和执行环境。

## 提交记录

隔离分支为 `codex/upstream-2d21d21-integration`。尚未将新目标的上游功能合入主工作区；当前完成的是首批准备修复。

| 提交 | 内容 |
| --- | --- |
| `5005f55d` | ToolchainTests 辅助函数重命名 |
| `8d7eda2e` | 克隆排除根目录 CFW 回滚历史 |
| `ad0e6507` | 检查模式的提示和进度写入 stderr |

主工作区分支和文件未修改。后续实现基于本隔离分支继续；不能把这三项提交计为新台账中任意 T 项的完整验收。

## 后续动作

全量 Swift 失败需在后续基线核对中独立诊断；本批没有将失败套件设为永久跳过，也没有放宽断言。

1. 取得引用对话中的三个原始附件，以其精确任务定义完成 T00–T03 对账。原 2.2.3 台账不能直接标记为 47 项新台账的完成状态。
2. 按新目标核对 T04–T08、T24、T40、T46 的依赖与接受条件；已有等价实现复验，不重复迁入。
3. 固件、客户机写入和真实 VM 验收前，核对完整恢复点、容量及已声明的宿主约束。120 Hz/FPS 保持引用方案中的延后状态。
