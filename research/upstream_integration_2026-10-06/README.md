# 固定上游整合执行记录（2026-10-06）

本轮目标为 `2d21d21fbdd4f51f013616273ceda9b35a3e0789`。主工作区基线为 `e8d825b3723d9ec72d31b050a79d353acd4b59bf`，实施分支为 `codex/upstream-2d21d21-integration`，使用已经附加的隔离工作树。主工作区未修改，现有 VM 未操作。

`inputs/` 保存用户提供的三份附件原文；来源路径、摘要与大小见 `input_manifest.json`。附件内的历史状态、旧 sandbox 链接和实施授权字段仅表示原文状态。本轮授权来自用户“开始推进”“继续”；实际状态记录在 `tasks.json`。

## 结果与范围

| 任务 | 当前结果 | 限制 |
| --- | --- | --- |
| T00/T01 | 当前 Git 基线、干净主工作区和隔离工作树已固定 | 不替代 VM 恢复点 |
| T02 | 47 项能力、758 个任务路径条目、342 个提交的结构性台账已生成 | 文件名与摘要只能提供候选；逐项语义审查未完成 |
| T03 | 历史备份和验收 VM 路径在当前机器不存在；用户正在清理磁盘 | 本轮停机测试 VM 路径、备份目录及足够容量尚未确定 |
| T04 | 目标 Mach-O 文件唯一逻辑差异是保留 LC_UUID；定向签名与 codesign 检查通过 | 仍保留用户 10 月 1 日的决定；不能靠删除 UUID 接受空间不足的输入 |
| T05 | 保留 UTF-8 locale 与路径保护；修复归档遍历临时改变进程工作目录 | 当前高 UID 仅验证严格 ustar 拒绝；真实 VM 导入/导出未验收 |
| T06/T07 | 固定目标连接收尾、proxy 重试与 plist 已部分审查；18 项 Python、51 项相关 Swift 对照通过 | VSOCK、升级监听确认与每 VM 更新策略仍需审查和真实 VM 验证 |
| T08 | IcliKit 0.7.16、swift-collections 1.7.1 与其余五项 pin 已对齐；候选编译、签名与来源检查通过 | 未部署、未激活；客户机运行行为未验证 |

`commit_ledger.json` 共 342 个提交，其中 280 个非合并、62 个合并提交。8 个合并提交的 remerge diff 非空，仍需审查；37 个提交只涉及文档路径，转入 T28 审查。不得据此把所有提交标记为已合入。

## T05 证据

旧实现回归测试失败：另一个线程观察到遍历中的进程工作目录变化。新实现使用绝对路径与 `archive_read_disk_entry_from_file` 读取元数据，自己遍历物理目录；仍保留 libarchive 的硬链接解析、ACL、扩展属性和稀疏信息读取，不跨 `await` 使用线程 locale。

参考：[libarchive 读取磁盘接口](https://raw.githubusercontent.com/libarchive/libarchive/v3.8.1/libarchive/archive_read_disk.3)、[官方实现](https://github.com/libarchive/libarchive/blob/v3.8.1/libarchive/archive_read_disk_entry_from_file.c)。测试验证普通打包和取消时工作目录不变，并覆盖原子发布、路径穿越、符号链接、硬链接、稀疏文件、decmpfs 和多语言名称。

当前 UID 为 `2035870432`。严格 ustar 的数字 UID/GID 使用六位八进制；当前账号超出其范围。测试在该条件下验证明确拒绝及 staging 清理，保留可表示 UID 环境下的正向分支。没有修改源文件所有者或截断 ID。[官方 ustar 数字字段实现](https://github.com/libarchive/libarchive/blob/v3.8.1/libarchive/archive_write_set_format_ustar.c)

## 验证

| 实验设置 | 结果 | 证据 |
| --- | --- | --- |
| 签名与归档定向测试 | 78 项、12 个 suite 通过 | `evidence/T04-T05-green.log` |
| `make test_swift` 默认测试间并行 | XCTest 234 项、3 项跳过、0 失败；Swift Testing 1031 项、159 个 suite、16 issues；归档测试通过，未出现 getcwd 错误 | `evidence/T05-full-swift.log` |
| 相关失败套件单独并行 | 51 项、8 个 suite 通过 | `evidence/T05-isolated-control.log` |
| 完整 Swift，显式 `--no-parallel` | Swift Testing 1031 项、159 个 suite 通过，180.602 秒；仍包含各测试内部并发场景 | `evidence/T05-serial-control.log` |
| 1 GiB tar 管道，两种模式 | 通过；峰值 RSS 8601600 / 7847936 字节 | `evidence/T05-tarpipe.log` |
| guest components | 124 项检查、0 失败 | `evidence/T05-guest-components.log` |
| proxy 与 daemon 构建校验 | 18 项 Python 测试通过 | `evidence/T06-T07-python.log` |
| 0.7.16 pin 校验 | 旧 0.7.7 红测试失败；更新后 6 项通过 | `evidence/T08-pins-*.log` |
| 固定依赖 jsonSafe 源码，macOS 纯数据探测 | NaN、无穷值、嵌套 Data/日期、多语言字符串等通过 | `evidence/T08-json-safe.log` |
| `make daemon_api_build` | iOS arm64 候选编译、精确 checkout、签名、动态依赖与 manifest 检查通过 | `evidence/T08-candidate-build.log` |

标准 `make test_swift` 尚未通过。失败与测试间并行执行有关，具体阻塞来源未确定。没有修改标准测试入口或扩大超时时间；串行通过不能代替默认并行验收。

候选 binary SHA-256 为 `70a488a63d93c9a2b8a5b6c62598036532b0ca28207ba8855305d9552172cc3f`。完整依赖和三项产物摘要见 `evidence/T08-candidate-manifest.json`；该文件明确记录 `activated=false`、`runtime_validated=false`。

## 调整与后续工作

继续使用已附加的 `codex/` 分支；按实际 SwiftPM/Make 与独立 Xcode 工程分别验证。T04 保留 LC_UUID，仅回收 LC_SOURCE_VERSION，随后明确拒绝。T08 补入七个具体 entitlement，但保留现有两项 keychain-access-groups，未增加上游的 `*` 和 `apple`；跨组 keychain 能力留待 T41 审查。这些调整及成本写入 `tasks.json` 的 `execution_rulings`。

继续 T02 语义对账，随后核对 T09/T10/T11 的补丁选择、模式策略与持久化接口。T03、真实客户机运行、最终集成验收和默认并行测试问题仍未完成。T45 按原方案延后。
