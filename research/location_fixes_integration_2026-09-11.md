# 定位修复分支整合

日期：2026-09-11。基线：`da678a3`。来源：`codex/app-knowledge-compiler-fixes` 的 `82dae74`、`fb57473`。状态：代码移植、回归、宿主机和客户机构建签名完成，未部署或运行 VM。

## 差异与原因

基础提交 `baccfc2` 已存在等价补丁，但两个后续修复没有被等价纳入。核对当前实现后确认下列差异存在，因此移植这两个提交的行为和测试，不重复应用基础功能。

| 问题 | 修改 | 原因 |
| --- | --- | --- |
| 异步交付期间其他请求可进入控制器 | 将激活、交付、停止及重连操作纳入串行交付；等待任务支持取消 | `@MainActor` 方法在 await 时允许重入，不能单凭 actor 隔离保证整个异步操作串行 |
| 客户机已应用但 ACK 丢失 | 保留待确认交付的序号和完整样本；重试同一交付后再推进 | 丢失响应不能证明客户机未执行；用新内容复用原序号会改变幂等语义 |
| 客户机明确拒绝与传输失败混淆 | 保留客户机错误码，显式记录 definitiveGuestRejection，按原因释放待交付或重新绑定 | 明确拒绝与结果未知需要不同重试处理 |
| 重连或定时任务覆盖后续暂停/恢复 | 检查 generation 与控制版本，保留暂停和 watchdog hold 意图 | 旧异步操作完成时不能恢复已被后续操作替代的控制状态 |
| 停止和切换时持久状态删除失败 | 增加 pending-delete 暂存、提交、回滚及重启恢复；GUI 切换失败保留原状态 | 内存、客户机状态与持久文件可能在不同阶段失败 |
| GUI 与排队的外部请求竞争 | 增加外部控制 token，在实际提交前重新检查 | 请求开始时取得所有权不代表等待期间仍持有所有权 |
| JSON 类型隐式转换 | 严格区分数字、布尔和字符串，整数限制为 JSON 安全整数 | NSNumber 桥接可能把布尔值作为数值接受；超出安全范围会丢失序号精度 |
| 旧客户机仅声明 location | 增加 location_owned 能力检查及客户机声明；保留旧命令路径 | 新协议需要 generation 绑定及清除/重启能力，不能仅凭旧能力声明使用 |
| 客户机 begin 后残留旧模拟位置 | begin 在状态锁中清除并重启模拟器，再绑定 generation | 新源开始时需要清除旧源位置；stopLocationSimulation 路径后还需要重新启动模拟器 |

## 移植方式

- 保留当前 `VPhoneCore` 模块边界和 `VPhoneSystemLocation*` 公共类型，不把控制器移回可执行模块。
- 保留当前公共定位参数校验和 value initializer；客户机适配器继续位于 `sources/vphone-cli/VPhoneControlLocationAdapter.swift`。
- 使用三方合并保留当前分支其他改动。参数测试仍分为 Core 数值校验与 CLI JSON 解析；修复分支的并发 fixture 修正一并纳入。
- 存储故障注入接口保持 internal，公共调用仍使用 `init(url:)`。
- 首次编译发现旧分支默认参数引用 private `TimeoutAction.hold`，跨模块 public API 不允许该引用；恢复当前公共 API 使用的 `"hold"` 默认值，语义不变。
- 没有修改固件补丁匹配或替换指令，因此不更新二进制补丁比较表。

## 分支附带核对

`origin/codex/vphone-core-integration` 的 `c22d179` 与当前历史 `4dcbdb8` 都将 signcert 复制到 `Contents/Resources/scripts/vphoned/signcert.p12`。两者上下文不同，`git cherry` 未判为等价补丁，但本次逐行核对确认实际新增 mkdir/cp 行相同，当前已具备该行为，无需再合并该提交。

本次未修改工作区已有的 Markdown 预览相关 Makefile、脚本和说明，也未移动或删除分支。

## 调用方可见变化

- 新源命令要求客户机声明 `location_owned`；仅声明 `location` 的客户机继续使用旧 `location` / `location_stop` 路径。
- `location_source_stop` 在宿主机 JSON 入口要求显式字符串 `generation`，用于校验源归属；原有 Core 停止接口保留可选参数供内部调用。
- `heartbeat_s` 与 `watchdog_s` 接受 0.01–86400 秒的有限数值；布尔值、字符串数字和 JSON null 不作为数值接受。
- 序号在 JSON 边界必须为安全整数，源序号及客户机交付序号不得为负；固定源的 `producer_sequence` 必须为 0。
- 持久化切换失败时 GUI 操作返回失败，不提前更新菜单为成功状态。

## 验证

日志目录：本机 `/tmp/vphone-location-integration/`，该目录不随仓库交付。

| 检查 | 结果及范围 |
| --- | --- |
| 定位专项 Swift 测试 | 75 项通过、0 失败：控制器 63 项、CLI 参数/错误映射 7 项、Core 参数 5 项 |
| `make vphoned` | iOS arm64 交叉编译及 ldid 签名通过；没有部署到 VM |
| `make test` 的 Python 阶段 | 73 项通过；同次 Swift 的定位用例通过，但 VMStop 出现 9 条 issue，其中进程查询报 Operation not permitted，整条命令退出非零 |
| 允许进程查询后 `make test_swift` | 退出 0；XCTest 76 项中跳过 1 项、实际执行 75 项通过；Swift Testing 314 项 / 51 suites 通过 |
| `make build` | 沙箱内先遇到 ModuleCache 写权限及 sandbox-exec 拒绝；在允许构建的环境重跑退出 0，release 与应用包构建签名通过 |
| `codesign --verify --strict` | release 与应用包内宿主机可执行文件均通过 |

专项测试覆盖丢失 ACK、明确 NACK、排队取消、源替换、暂停/重连竞争、停止失败恢复及损坏持久状态；测试使用客户机适配器替身。客户机 CoreLocation 私有接口仅完成交叉编译，尚未在真实 VM 上验证。

E5 仍未完成：真实 socket、宿主程序重启、两个 VM 的状态隔离、GUI 与外部请求竞争仍需运行验收。旧客户机没有 `location_owned` 时，新源命令将明确失败；部署新 vphoned 并重新连接后才能使用该能力。
