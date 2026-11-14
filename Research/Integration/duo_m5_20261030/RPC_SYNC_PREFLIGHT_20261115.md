# 恢复客户端来源核对与 RPC 同步预检，2026-11-15

本轮从 `837a3c53` 推进两步：确认恢复连接重试的实际来源与已有实现；评估 RPC 同步依赖和 Duo 兼容性，并保存可重复执行的预检。没有修改 RPC 生产代码，没有启动 VM，没有修改宿主准入，也没有推送或发布。RPC 全量移植与新旧 host/guest 组合验收仍待完成。

## 恢复客户端

来源为 [#854](https://github.com/Lakr233/vphone-cli/pull/854)，改动提交 `f20bf92a`，合并提交 `bb79a93b`。#849 是 Remote Pairing 预设改动，不能作为恢复重试的来源。

#854 在 `irecv_open_with_ecid` 入口及各失败清理路径清空 `*pclient`，避免调用方的重试清理继续使用已关闭／释放的客户端。当前分支的 `3b4ac980` 已包含完整改动；当前 `MobileRecoveryCore/libirecovery.c` 与 `bb79a93b` 对应文件逐字节一致，SHA-256 均为 `f84bb59f027f891cd6a29af302cddb1893799f45791982cd2554363c077694e7`。

原有回归只编译 libusb 条件分支。本轮新增 IOKit fixture，将同一生产函数用 `HAVE_IOKIT` 再编译一次，覆盖异步事件源创建失败时的 `free` 调用和输出指针清空，以及其余错误／成功路径。fixture 替换 USB、CFRunLoop 和释放操作，不连接设备，不代表实际 IOKit 资源释放或 USB 恢复已经验收。

命令：

```zsh
zsh VPhoneExecutable/VPhoneCommand/VPhoneRestore/VPhoneRestoreTests/run-recovery-client-tests.sh
```

证据位于 `.build/rpc-contract-20261115/`：

| 源码 | libusb fixture | IOKit fixture | 日志 |
| --- | --- | --- | --- |
| `bb79a93b^1` 的旧函数 | 1/7 通过 | 1/8 通过 | `recovery-client-before.log` |
| 当前函数 | 7/7 通过 | 8/8 通过 | `recovery-client-after.log` |

旧函数的失败均包含失败返回后输出指针未清空；成功路径通过。CI 已调用该脚本，扩展后会同时执行两个条件分支。未进行涉及擦除的恢复操作；实际 USB/DFU 重试与恢复空间峰值仍需独立目标和对应授权。

## RPC 来源与依赖

读取了八个 PR 的正文、最终提交及本地差异。预检固定使用 `13169405` 的最终源码，不以 PR 正文中的早期行为说明替代最终代码。

| 来源 | 主要改动提交 | 同步内容 |
| --- | --- | --- |
| [#841](https://github.com/Lakr233/vphone-cli/pull/841) | `9f3974e2` | 方法枚举、统一派发、force 准入、全量目录 |
| [#857](https://github.com/Lakr233/vphone-cli/pull/857) | `29fca910` | 结果声明、静态生产者漂移检查 |
| [#884](https://github.com/Lakr233/vphone-cli/pull/884) | `46247e4a` | 方法／参数说明及约束元数据 |
| [#892](https://github.com/Lakr233/vphone-cli/pull/892) | `3c98cd88` | 类型与 nullable、独立方法声明、编译生成目录 |
| [#908](https://github.com/Lakr233/vphone-cli/pull/908) | `2e69d82d`、`b039a5a8`、`83800068` | 名称与单位统一、旧 guest/client 兼容 |
| [#914](https://github.com/Lakr233/vphone-cli/pull/914) | `d5177279` | 错误码／hint、未知参数拒绝 |
| [#915](https://github.com/Lakr233/vphone-cli/pull/915) | `5e3c56bf`、`050bf3bd` | 列表分页、进程输出暂存、相关回归时序修正 |
| [#916](https://github.com/Lakr233/vphone-cli/pull/916) | `b704260f`，最终分支含合并 `b2938025` | 输入后观察及与前述改动的合并 |

派发／目录基础先于结果声明和类型化；#914 依赖 #908，#915 依赖 #914，#916 依赖 #915。#908 的 PR 正文仍写旧名移除，但最终代码已经加入兼容翻译和旧结果键；必须同时保留 `b039a5a8` 与 `83800068`，不能只移植最初改名提交。

结果漂移工具使用固定版本 `swift-syntax 604.0.0`，属于开发测试依赖。正式同步仍须运行该工具；本轮没有将它加入生产 Bundle，也没有把目录比较当作生产者漂移检查。

## 兼容性结果

预检编译最终上游 `GuestMethodSpec.swift`、真实 `GuestPaging.swift` 和全部方法声明，再与当前 `GuestDuoMethod.swift` 编译生成的局部目录比较。上游共 203 项声明，当前 Duo 局部目录共 12 项；12 个名称均出现在上游。当前局部目录并不表示全部实际 handler 数量。以下 8 项的参数或结果声明不同：

| 方法 | 已确认的声明差异 | 适配要求 |
| --- | --- | --- |
| `display.auto_lock.set` | Duo 接受可选 `seconds` 或 `never:true`；上游只声明必填 `seconds` | 保留 Duo 的替代参数和严格数值校验；直接使用上游准入会以 `invalid_param` 拒绝 `never:true`，预检已复现 |
| `display.capture_active` | 上游另有 13 个可选图像／渲染诊断字段 | 对照当前实际生产者调整声明；保留原生来源身份校验与 worker 恢复，不能以目录差异证明捕获实现必须更换 |
| `display.posture` | `hinge_hid`、`sweep` 的 `open` 元数据不同 | 对照 Duo 的实际嵌套结果声明 |
| `display.rotation` | `accelerometer` 的 `open` 元数据不同 | 保留实际方向与姿态来源，不因元数据差异改变运行行为 |
| `input.tap` | 上游增加两个 observe 参数和 `observed` 可选结果 | observe 校验在动作前；观察在动作成功后；保留 Duo 点坐标与活动面板检查 |
| `methods.list` | Duo 还声明 `scope`、`complete`，且 `methods.open` 不同 | 全量目录上线时同步更新范围语义与声明，避免继续报告局部目录；核对旧客户端对顶层字段的读取 |
| `ui.element_at` | `element.open`、`error`、可选 `x/y` 声明不同 | 保留 display ID、AX ABI、PID、前台及几何复核；按实际结果适配类型声明 |
| `ui.tap_element` | `element.open` 元数据不同 | 保留命中后的前台／几何复核，再调整声明 |

这些是声明比较结果。除 `never:true` 已实际驱动上游准入复现拒绝外，不能将声明差异直接写成运行时缺陷。

另有以下跨版本约束：

- 最终上游将 `process.spawn` 翻译为 `processes.spawn`，秒参数翻译为毫秒参数；新、旧 timeout 同时存在时保留新值并移除旧键。host 仍需兼容旧 daemon，不能仅更改 guest 名称。
- 旧四坐标形式的 swipe 单独传入时可转换为 `from/to`；新旧 swipe 字段同时传入会因旧字段残留而触发未知参数拒绝，预检实际观察为 `invalid_param`。后续须明确覆盖混合字段的兼容行为。
- 分页默认 200 项，最多 1000 项；cursor 是新一次列表中的十进制偏移，不提供跨请求快照一致性。旧的单次列表消费方可能只读取首批结果，需要逐个检查 host、Launchpad 及保存的验收脚本。
- 输出暂存改变 `process.spawn` 的 inline 回复与后续读取；同步时须保留现有进程退出／管道回归，覆盖释放、过期、容量、UTF-8 边界、超时和 spool 写失败后的继续排空。
- #914 的错误对象要经过现有 HTTP／代理传递；保留 render-server 代次切换时的 RPC 准入、活动请求排空和响应刷新时间。`observe` 的等待与观察同样属于活动 RPC 的范围。
- `required`、类型和范围元数据不等于全局参数验证。最终准入负责未知键与 force，具体数值类型仍须由 handler 验证。

## 已执行回归与限制

保存入口：`Regression/rpc-contract-preflight.zsh` 和 `Regression/RPCContractPreflight.swift`。

```zsh
zsh Research/Integration/duo_m5_20261030/Regression/rpc-contract-preflight.zsh
zsh VPhoneDaemon/Tests/run-auto-lock-tests.sh
zsh VPhoneDaemon/Tests/run-element-tap-tests.sh
```

最终证据：`.build/rpc-contract-20261115/preflight.8njnHgIF/`。

- 24/24 预检通过：旧名称／单位转换、新 timeout 优先、未知参数和 force 拒绝、observe 准入和故障隔离、分页边界。还保存了上述 `never` 不兼容的直接复现。handler 使用隔离测试替身，未执行 guest 操作。
- 对固定上游源码运行其原有离线逻辑套件，1262 项通过，包含真实输出暂存／排空、清理和观察逻辑。源码及日志分别保存在证据目录的 `reference/` 和 `upstream-logic.log`；临时输出使用测试创建的文件目录。
- 当前 Duo Auto-Lock 81 项通过；AX API 240 项及几何 31 项通过，原生 display/context/ABI 测试通过。日志为证据根目录的 `auto-lock.log`、`element-tap.log`。
- `upstream-catalog.json`、`duo-catalog.json`、`catalog-differences.json`、`summary.json` 和两个 revision 文件保留编译生成的比较结果。

研究预检依赖本地 Git 中存在固定上游对象，因此没有加入浅克隆 CI；恢复客户端的两分支回归沿用现有 CI 入口。本轮没有修改生产文件，不重建 Bundle。上述结果不代表 RPC 已全量集成，不包含新旧 host/guest 的 VM 验收、生产者静态漂移检查或 WDA 验证。

## 后续实施顺序

1. 移植声明、派发与类型基础，适配上述 Duo 差异；保留 Auto-Lock `never`、原生 AX 和 render-server 生命周期，运行目录／生产者漂移及现有回归。
2. 统一改名与双向兼容，再加入错误准入、分页／输出暂存和 observe。逐组检查旧消费者，并在新身份隔离副本上验证新旧组合；测试后恢复原组件并正常关机。
