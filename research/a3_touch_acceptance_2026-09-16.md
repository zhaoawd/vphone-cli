# A3：客户机触控优先策略验收

日期：2026-09-16。仅操作 `vm-2607-rig2`（ECID `F400A64BECB946FA`）；主 VM 未收到控制请求或 UI 操作。宿主 macOS 26.5.1 / 25F80，Xcode 26.4 / 17E192。客户机 iOS 26.1 / 23B85 EXP，1290×2796，简体中文、中国大陆，未登录 Apple 账号。

结论：A3 按本文支持范围完成；项目累计 18/28 项完成。其他版本与变体未验证，不影响既定“缺少组合明确记录”的关闭条件。

## 修复

原客户机事件不携带 HID 边缘类型，应用内底部手势被 SpringBoard 的边缘检查拒绝。[诊断记录](a3_hid_edge_diagnosis_2026-09-16.md)包含原事件失败、临时忽略检查成功、撤销后失败的对照。

正式实现复用宿主已有的按下位置边缘判定，将可选布尔字段 `edge` 传给客户机。客户机仅在 down 时记录该值，将 `FromEdgeTip` 传给父事件及手指事件；move、up、会话断开释放均保持该值，释放后清空。普通触摸、孤立 move/up、连接代次隔离及原生回退策略保持不变。没有将底部上滑替换成 Home 键，没有新增 SpringBoard 运行时修改，也没有修改 Hand 类型。

新增能力 `touch_edge` 表示客户机理解此字段。缺少字段等同 false；旧客户机仍可处理原有触摸字段，但不能据 `touch` 声明推定边缘手势已修复。完整边缘行为需要本轮宿主与客户机配套使用。

## 实机结果

证据目录前缀为 `research/artifacts/`，每个目录均保存 `requests.jsonl`、截图与退出记录。

| 实验设置 | 证据 | 结果 |
| --- | --- | --- |
| 原始服务，设置根页底部上滑 | `rig2-setup-20260916-205403/baseline-*` | FAIL，仍在设置 |
| 仅实验客户机推导底边标记，原宿主时序 | `rig2-setup-20260916-210222/verified-edge-*`、`verified-edge-repeat2-*` | 两次 PASS；仅用于定位，不作为最终实现 |
| 正式宿主传递 `edge`，正式客户机 | `rig2-setup-20260916-211830/production-edge-*` | PASS，最后两帧均为主屏 |
| 主屏点击设置 | 同目录 `basic-06` 至 `basic-08` | 进入设置，双帧判据通过 |
| 设置列表内部拖动 | `basic-10-list-drag-final.jpg` | 列表滚动到通知、隐私等下方条目 |
| 原地按住设置图标 1500 ms | `basic-15-long-press-final.jpg` | 显示设置快捷菜单；未选择删除或编辑操作 |
| 窗口视图 323×699、430×932、538×1165 | 同目录 `scaling-*` | 三档点击及底部返回主屏均通过；恢复至 430×932 |
| 实际 down、move 后主动关闭会话 | 同目录 `disconnect-visible-*` | down 截图显示条目按下高亮，move 截图显示列表位移；随后断线 |
| 断线后孤立 up、新原生拖动 | `disconnect-visible-16` 至 `-20` | 能力显示未连接；新原生拖动使列表继续滚动，无卡住按下现象 |
| 重新连接、旧尾部事件、新手势 | `disconnect-visible-23` 至 `-35` | 会话 10→13；旧 move/up 后，新点击及 Home 手势通过。首次独立运行 7→10 亦通过 |
| 连接但明确缺少 `touch` 能力 | `rig2-setup-20260916-210222/native-live-caps`、`native-confirmed-prepared-*` | 原生底部 Home 手势失败；Home 键对照通过，原生点击设置通过 |

按下、缩放和主动断线由隔离测试 app 的临时入口调用真实 view/control 方法完成。入口只存在于 `.build/a3-final` 的验收副本，差异保存为 `acceptance-screen-hook.patch`、`acceptance-command-hook.patch`；没有加入生产协议。该阶段宿主 PID 18724，退出码 0，socket 已删除。

每轮自动判定均检查客户机连接及亮屏解锁状态；自动锁屏导致的前置失败单独保留，不计作手势失败。`--prepare` 仅在已知状态下唤醒无密码 rig2 并打开设置，不更改锁屏设置。截图分类器限于本轮语言与布局；拖动、长按和按下状态还进行了图像检查。

## 回归验证

HID 边界测试先在缺少边缘标记时触发断言失败，修复后通过。测试覆盖父/子事件、手势期间固定标记、最后坐标释放、重复 reset、孤立 move/up、普通新手势不继承旧标记及重复 down。真实鼠标入口测试覆盖三档缩放、四边/角点、越界钳制、普通触摸、能力缺失与断线；既有连接代次测试覆盖重连和不中途切换路径。

`make test` 最终通过：113 项 Python；141 项 XCTest，3 项跳过、0 失败；336 项 Swift Testing / 53 suites。证据为 `rig2-setup-20260916-211830/final-regression.log`。受限沙箱运行曾因 Unix socket、进程查询或 Swift 缓存权限失败；允许这些本地测试操作后重跑通过，没有将环境失败记作通过。未运行固件比较、恢复或其他固件变体。

## 支持范围

- 已验收：上述精确 26.1 EXP 组合的单指客户机触控、点击、列表拖动、长按、底部 Home 手势、窗口缩放和断线恢复。没有复现卡住按下、重复注入或坐标错误；有限测试不证明所有应用都不存在这些问题。
- 原生回退保留：本组合的点击、列表拖动有实际证据；底部 Home 手势不支持，使用已有 Home 键。缺少能力或未连接时仍选择原生路径，不将失败的客户机手势尾部重新注入原生路径。
- 旧版 iOS、其他 26.x、27.x，以及 Regular/Development/JB 的完整交互矩阵均未验证，不据本次 EXP 结果扩大支持声明。没有为取得这些证据新建 VM 或下载固件。
- 不覆盖多指、旋转、全部系统边缘手势、长时压力测试或主 VM。

## 部署与恢复依据

先前“上传缓存后启动独立服务”的方式曾出现 `bind: Address already in use`，原服务仍运行；这些候选结果已排除。正式部署关闭 rig2、取得任务锁及目录锁，仅离线替换 System 卷 `/usr/bin/vphoned`，每次备份后写入、逐字节比较并卸载专用挂载；没有重装 CFW 或改快照名称。缓存同步为正式客户机，运行能力包含 `touch_edge`。

原安装文件保存在 `rig2-setup-20260916-205403/installed-original-vphoned`，SHA-256 `a0e0140a70fcf63b1e91f3bb92cd84b21ea105325841f20c56f091337ade0fc2`。原缓存为同目录 `original-vphoned`，SHA-256 `2b90b8e555c86e794733e661e9bdee4dae510e7f5fcc0ef0e9396f673a168cf4`。正式客户机 SHA-256 `630ee4c8d87c0f2336f566a84dc5204ea719c75fa1818c85040b9fbfcfd7f45e`。

独立构建避免覆盖主 VM 所用 app。测试 app 初次执行被系统终止后，临时签名辅助只允许 `.build/a3-final/.build/vphone-cli.app`，未使用 `allow-all`，未修改 SIP 或启动参数。

## 纯生产构建复验

移除两个临时宿主入口后，与仓库对应源码逐字节一致；整棵 `sources/` 仅自动生成的 `VPhoneBuildInfo.swift` 不同（隔离构建记录当前基线 `980ea18`，原工作目录生成文件仍为 `bc7f075`）。`make build`、最终资源签名与 bundle 检查通过，日志为 `rig2-setup-20260916-211830/production-build.log`。

纯生产宿主 SHA-256 `2bca5cf3580bc7cdedcb15b7bac951d4f79881955ef3c9fb66cc279cdd8d318a`。证据目录 `rig2-setup-20260916-212719/`：`a3_acceptance` 明确返回 unknown command；`final-production` Home 手势通过，`final-basic` 点击、滚动和长按再次通过，截图已检查。客户机声明 `touch_edge`，前后亮屏解锁。

从客户机下载的已测缓存 SHA-256 为 `4a1d4503976b831ed4b9527ec85eba080c48ef069939bf35a82eefe9ffba8620`；最终 bundle 内客户机 SHA-256 为 `9f5f4752489e1408b3e29f2e69b0966842b46cb3216d788a62da882ce4ee0bff`。两者 CodeDirectory SHA-256 完全相同：`f7709a32238fc48897900f0ceb56baa9fd4c193ce8128bb2740307af88641735`，不混淆代码身份与完整签名文件哈希。

最终 bundle 客户机再次部署到缓存并重启服务，重新连接后 `final-bundle-reconnect` Home 手势通过；下载最终缓存与 bundle 的 SHA-256 相同（`9f5f475…0bff`）。正式修复保留在 rig2，原安装文件及原缓存备份保留；主 VM 仍使用原 app，未部署此修复。

## 收尾

客户机临时状态探针已删除，SpringBoard 两份诊断注入文件均不存在，检查退出码 0。最终宿主 PID 22424 退出码 0，socket 已删除，任务锁释放。临时签名辅助 PID 18598 已不在运行，进程扫描无其他 amfidont 实例，`/var/root/.amfidont` 不存在；未留下全局允许路径配置。主 VM 原宿主 PID 21605 仍在运行。

生产源码无 `a3_acceptance` 或 `[DEBUG-a3]`；诊断源码仅保留于明确标注的 `research/probes/`，不进入生产构建。最终 app 位于 `.build/a3-final/.build/vphone-cli.app`，未覆盖主 app。签名构建、完整无固件回归、探针语法、plist 与 `git diff --check` 均通过。证据、备份及隔离构建保留，未执行项目级磁盘清理。

本问题可由“宿主鼠标事件→协议边缘字段→客户机父/子 HID 事件”的回归断言提前发现；本轮已补齐该测试范围。实际系统手势仍需精确版本 GUI 验收，不能由字段单测替代。
