# RPC 契约后续集成与验收（2026-11-15）

本轮对象为 #908、#914、#915、#916 的五项契约改动：名称与单位兼容、错误码与未知参数、列表分页、进程输出暂存、输入后观察。基础为本分支 `d54ed8e7`；未合入上游的其他设备能力。证据保存在 `.build/rpc-contract-next-20261115/`。

## 实现

1. 名称和单位：集成 `2e69d82d`、`b039a5a8` 和 `83800068` 的相关改动。目录采用 `processes.spawn`、毫秒超时和 swipe `from`/`to`；旧方法名、秒参数、旧 HTTP 路由及兼容结果键继续接受。新旧参数同时出现时，新字段优先，并在未知参数检查前移除旧字段。秒参数中的 Boolean 保持原类型，避免将 `true` 转换为 1000 毫秒。完整新 swipe 端点优先于旧坐标。
2. 错误契约：集成 `d5177279` 的现有模块范围。区分 `invalid_param`、`not_found`、`unavailable`、`permission`、`force_required` 和 `invalid_operation`；保留已有组件错误码。未知参数返回有长度限制的提示；近似方法名可返回建议。未加入本分支没有的 Cryptex／Location Services 设置模块。
3. 分页：集成 `5e3c56bf` 的八项列表分页。默认 200 条，最多 1000 条；返回 `total`、`truncated` 和可选 `next_cursor`。游标是重新枚举结果中的十进制偏移，列表变化时条目可能移动。宿主 App、文件、进程、服务和崩溃报告列表，以及模板校验，使用 `VPhoneGuestListPages` 收集完整结果。旧 daemon 没有分页元数据时，一次回复即完成。原始 RPC 调用保留分页契约。
4. 进程输出：stdout／stderr 分别限制首段和捕获总量。未超时且首段截断时返回输出标识；新增 `processes.output` 和 `processes.output_release`。暂存期限 10 分钟，共用 64 MiB 上限，优先淘汰已完成的最旧输出。保留现有管道所有权和进程退出处理。带 offset／limit 的 `files.read` 使用原生边界读取及 errno 分类。
5. 输入观察：集成 `b704260f`。所有 `input.*` 接受严格 Boolean 的 `observe` 与 0–5000 的整数 `observe_delay_ms`。观察参数在动作前校验并移除，动作成功后再等待和观察；观察失败保留动作成功结果并返回 `observe_error`。默认回复不增加观察结果。

目录由 195 项增加到 197 项。保留 `scope: guest` 和 `complete: true`、原生 AX PID 声明、活动面板坐标、Auto-Lock 严格 `never:true` 和 render-server 准入／排空。手势仍位于本分支的 `GuestAPI+Gestures.swift`。原生 Snapshot 策略未修改；本轮没有新增固件补丁声明。

## Trust 提示

历史证据 `rpc-foundation-20261115/worker-cold.XSoXdHK4` 中，Don't Trust 返回 `tapped:true` 后提示仍存在。该记录仍有效，不追溯改写为通过。

本轮以精确的两个 lockdown AX 标识和 SpringBoard 前台为前提，只点击 Don't Trust。`trust-probe.mjs ax` 在未修改 AX 点击实现的基础 daemon `c1d320…` 上通过：即时采样仍有四个提示元素，后续 50 ms 延迟采样为空，再后续为 23 个 Home 元素。最终候选 `c04e362a…` 的 `live-final-2/trust.json` 也记录提示存在、点击成功及其后 20 次每次间隔 250 ms 的采样均无该提示。

本轮未稳定复现旧失败，原因未查明。没有基于未验证假设修改 native 点击路径。`tapped:true` 仍只表示动作提交；正式脚本单独断言提示持续消失。`live-final-3` 启动时提示已不存在，因此该次 Trust 前提未满足，未计为独立 Trust 通过。

## 离线验证

| 项目 | 命令或证据 | 结果 |
| --- | --- | --- |
| 旧名称／混合参数／未知字段 | `zsh VPhoneDaemon/Tests/run-rpc-compatibility-tests.zsh` | 38 项通过；指定基础旧 `GuestMethodSpec.swift` 时 12 项失败，日志 `compat-before.log`／`compat-after.log`。 |
| 分派、错误、分页、暂存和观察逻辑 | `zsh VPhoneDaemon/Tests/run-logic-tests.sh` | 1148 项通过。 |
| 目录 | `zsh VPhoneDaemon/Tests/run-methods-tests.sh` 及 `--self-test` | 197 个方法和 38 项目录自测通过。 |
| schema 提取器 | `RS_ICLI=… xcrun swift test --package-path VPhoneDaemon/Tests/ResultSchema --scratch-path .build/rpc-foundation-20261115/result-schema -j 4` | 132 项通过。 |
| 真实生产者漂移 | `zsh VPhoneDaemon/Tests/run-result-schema-check.sh --icli …` | release 检查通过。icli 固定为 `bd25a1d0…`；未弱化现有断言。 |
| HTTP fixture | `zsh VPhoneDaemon/Tests/run-methods-live-stub-tests.sh` | 109 项通过；使用已有 Swift server。沙箱拒绝回环监听的尝试不计为产品失败，允许系统访问后原测试通过。 |
| AX | `zsh VPhoneDaemon/Tests/run-element-tap-tests.sh` | API 240 项、几何 31 项和 native ABI／显示身份检查通过。 |
| Auto-Lock | `zsh VPhoneDaemon/Tests/run-auto-lock-tests.sh` | 84 项通过。 |
| 其他输入／进程／生命周期 | point geometry、process output、process pipe、render-server lifecycle 现有脚本 | 通过。 |
| 宿主列表收集／模板 | `xcodebuild … -scheme VPhoneCoreKitTests … test` | 首轮 687 项通过；旧 daemon 超时兼容补充回归另见下文。 |
| 完整 Bundle | `xcodebuild … -scheme VPhone … build`；`codesign --verify --deep --strict …/VPhone.bundle` | 构建、Bundle admission 和严格签名通过。 |

## 实际隔离 VM

仅使用 `.build/duo-runtime-84e3ce54/machines/duo-rpc-foundation-20261115`。宿主为已批准原 executable，CDHash `d85f81edab6cc06b9589205ecec130585ac941e8`。未新增 AMFI allowlist，未接受 Trust，未启动原始 `duo-rpc-accept-205443` 或保留身份副本。

最终 daemon SHA-256 为 `c04e362ae02b6b521bac06d1f2833850935e8e88ea121b8d7fd8fb139dd48593`，固定副本为 `candidate-final/vphoned`。安装后 21 项库保持原摘要，根挂载只读。实际回归入口为 `Regression/rpc-contract-next-live.mjs <socket> <output> <hash>`。

`live-final-3` 的 28 项契约断言和 73 次实际成功回复 schema 检查通过，包括旧方法与混合单位、错误码、三页进程列表、暂存输出逐段重建与释放、分页文件读取、无效观察参数不得执行 power 动作，以及实际输入后观察。AX 15/15 和锁屏拒绝通过；respring 后 worker 415→554，原生截图来源恢复通过。

首次实际脚本有两处检查范围错误，已保留失败日志：未分页的旧 icli `files.read` 保持 `operation_failed`，errno 分类属于新增分页读取路径；目录只列 canonical 名称，因此旧 `process.spawn` 的结果应对照 `processes.spawn` schema。修正脚本后继续验证，未因此修改生产错误码或删去 schema 校验。

## 冷启动与回滚状态

候选冷启动 `contract-session.vsuRYgiV` 的原摘要／21 项库／根只读检查通过。`live-cold` 的 29 项契约断言、91 次实际回复 schema、Trust 提示拒绝后的 20 次消失采样、AX 15/15、锁屏拒绝及 worker 119→484 后来源恢复均通过。

新增模板回归复现仅发送毫秒字段的兼容遗漏，见 `host-compat-before.log`。模板请求现同时发送 `timeout_ms` 和旧 `timeout_s`；创建器读取 bootstrap 失败时先读 `message`，再回退旧 `error`。修改后的全部 687 项 CoreKit 测试通过。最终完整 Bundle 再次构建和严格签名通过，guest daemon 摘要仍为已实测的 c04e362a…。

`contract-rollback.log` 已核对恢复原 daemon `446925b6…`、原标记、全部 21 项原库以及根只读。该次正常关机后状态句柄释放。

再次冷启动 `contract-session.E6EeraJ5` 未完成连接：前 150 次就绪查询均未得到可用 guest RPC；清理阶段正常关机请求也因 `guest not connected` 未执行，仍有 VM 服务持有状态文件。串口已到 early boot complete，之后出现 DriverKit 启动失败；该日志不能证明 daemon 失败的原因。只读截图请求因输入显示几何不可用被拒绝，原因未查明。最终原组件冷启动复核和正常关机因此尚未通过；不得将该次启动记为已完成清理。

五项 RPC 的候选验收通过；新宿主与旧 daemon 的真实混合运行主要由宿主契约测试覆盖，未另行启动新宿主 GUI。列表变化时的游标一致性不提供快照保证。未分页旧 icli 错误分类和历史 Trust 失败的原因仍保留上述限制。
