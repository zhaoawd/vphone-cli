# E6 相机回执契约与隔离验证

日期：2026-09-14。已完成两端编号与回执检查，修复隔离测试复现的问题。真实 VM、应用显示和 QR 识别未验收，E6 保持进行中。

## 第一阶段记录（后续协议变更见下文）

### 回执含义

本轮明确沿用“当前 generation 至少有一帧完成共享内存复制”的契约，不要求读取最新帧，也不指定某个宿主帧编号。返回的 `transport_receipt.semantics` 为 `same_generation_frame_copied`，并附带 generation。

| 字段或阶段 | 含义 |
| --- | --- |
| 宿主 wire `fi` | 宿主定时器安排帧的编号；新源可以重置计数，安排不等于写入完成 |
| `host_published_frame_index` | 保留的历史字段，实际含义仍是定时器计数；新增 `host_scheduled_frame_index` 和 `host_frame_index_semantics=scheduled_tick` 明确说明 |
| `vphoned_published_frame_index` | 客户机发布者在本次运行中写入共享内存的计数；接收端没有使用 wire `fi` 作为这个计数 |
| `libvcam_observed_frame_index` | 消费端完成复制的客户机发布编号；允许落后于当前发布编号 |
| 应用显示、QR 识别 | 独立验收阶段；共享内存观察回执不能证明这些结果 |

宿主接受回执时要求当前源仍在 streaming、相机与控制连接可用、generation 相等、`0 < observed <= published`。在等待客户机响应前后都复查当前源；`camera_status` 在等待结束后重新读取宿主状态。

客户机仅采用稳定发布快照，并要求观察记录的 generation 匹配、编号有效，观察时间不早于发布者本次初始化时间。观察文件过短时返回无有效观察。三个相机命令统一限制 generation 为 1–79 个 UTF-8 字节且不包含 NUL，以符合客户机固定字段容量。

## 复现与修复

| 问题 | 修复前证据 | 修改与复验 |
| --- | --- | --- |
| 发布者初始化后接受保留的旧观察 | 生产 `vp_vcam_status` 测试：旧时间戳记录仍返回 observed=1 | 增加本次发布者初始化时间检查；原用例通过 |
| 观察编号超过发布编号 | published=1、observed=9 仍被接受 | 客户机与宿主均拒绝该关系；原用例通过 |
| 停止后仍返回旧回执 | 宿主命令测试：streaming=false，但仍附带旧回执 | 等待前后检查活动源，停止后不附带回执 |
| 查询期间切换源 | 客户机响应期间切换源，仍返回旧回执和旧状态 | 复查活动源，并在等待后重新生成状态 |
| 消费端分配失败仍报告观察 | 提取生产读取函数做分配故障注入，结果为 result=1、observations=1、bytes=0 | 分配失败直接返回，不生成观察记录；清除无效尺寸 |
| 撕裂读取的像素仍被暴露 | 复制期间改变 seq，函数返回 0，但公开缓冲区仍有 bytes=4 | 在持有应用读取锁时完成 seq 复核；不稳定时清除缓冲区有效长度及尺寸 |

另将菜单源切换与停止时的 producer generation 检查补齐；耗时帧生成结束后再次检查 token。显式断开会使待完成的连接尝试失效。这些修改不代表已经验证实际 vsock 写入、重连或队列积压行为。

## 验证范围

- 宿主相机命令回归复现停止、切换和无效编号错误；修复后通过。新增 UTF-8 边界检查。
- 客户机发布者测试直接编译 `vphoned_vcam.m`，使用临时 publish/observe 文件；覆盖有效滞后帧、旧 generation、发布者初始化、非法编号和截断文件，共 5 项。
- 消费端测试从生产文件提取原始类型与读取函数，注入分配失败、复制期间 seq 变化和正常复制，共 3 项。测试不链接实际 cameracaptured，也不表示应用显示通过。
- 独立 scratch/cache 中的完整 Swift 无固件回归通过：Swift Testing 333 项、53 个 suite；XCTest 133 项，其中 3 项跳过。
- 最终完整 Python 回归 111 项通过，包含上述发布者与消费端用例。
- vphoned 与 libvcamcaptured 分别输出到 `.build/e6/` 交叉编译，不覆盖运行中 VM 使用的客户机文件。未部署、未重建共享签名应用包。编译仍输出 packed 共享结构的 atomic alignment 等警告，原始日志保留；本轮未调整共享内存布局。

证据位于 `.build/e6/`：`guest-before.log`、`host-before.log`、`host-after.log`、`swift-full.log`、`consumer-before.log`、`consumer-after.log`、`guest-build.log`、`consumer-build.log`。最终 Python 回归见 `.build/d3/python-final.log`。

## 后续条件与未验证行为

1. 每次新呈现应使用新的 generation。当前协议没有独立的呈现请求标识；主动重复使用同一 generation 仍无法可靠区分新旧内容。本轮未引入跨宿主/客户机的请求标识扩展，也不承诺重复 generation 的内容新鲜度。
2. `camera_stop` 仅停止宿主生产，客户机可能保留最后一帧；它没有呈现中性画面。需要中性画面时，先以新 generation 和 `role=neutral` 呈现，再单独核对复制与应用显示。视频源目前在 EOF 后循环读取，不能将 EOF 视为已停止。
3. 实际 generation 切换、积压帧、客户机重启、阻塞写入及视频 EOF 仍需专用 VM 验收。已经进入 socket 写入的帧不能由 token 检查撤回；回执不表达“旧帧已经全部排空”。
4. 应用侧至少分别记录测试图像显示和 QR 内容识别，并保留时间、截图或应用输出。不得用端口连通、生产计数或共享内存回执代替应用结果。
5. 用户说明其他任务使用 VM 后，本轮保持离线验证；不查询控制 socket、不更新客户机、不切换现有相机源。

本轮没有增加或修改固件二进制补丁。

## 第二阶段：呈现标识与停止策略

当前协议使用 `pv=3`，客户机声明 `vcam_receipt_v3`。每次呈现生成独立 UUID `presentation_id`，即使公开的 generation 相同也不会复用。发布者和消费端在共享内存保留区传递 16 字节标识；头部容量仍为 256/128 字节。回执要求 generation、presentation_id、编号关系和当前活动源均有效，语义为 `presentation_frame_copied`。上述第一阶段“重复 generation 无法区分”的限制已由此修改替代；实际 VM 帧流仍未验收。

宿主、vphoned、libvcamcaptured 必须配套更新。旧消费端没有有效呈现标识，不能满足新版回执；缺少客户机能力时宿主拒绝新版呈现请求。

`camera_stop` 默认 `policy=keep_last`：停止宿主生产，返回 `guest_frame_cleared=false`。显式 `policy=neutral` 创建新的 generation 和 presentation_id，持续发送白色 BGRA 画面，并检查该呈现的复制回执；不承诺应用已经显示白色。可提交 `presentation_id` 保护停止操作，避免停止同 generation 的后续呈现；省略时仍按 generation 匹配。

隔离测试新增重复 generation 旧回执、等待期间同 generation 替换、旧呈现停止保护、中性画面及能力不足场景。客户机测试新增旧呈现观察记录和旧消费端记录拒绝。Swift Testing 333 项/53 个 suite 通过；XCTest 138 项、3 项跳过、0 失败。客户机与消费端的 10 项隔离测试通过。独立签名构建、仓库外及符号链接资源执行检查通过。消费端单独交叉编译通过，日志仍包含 packed atomic alignment 警告。

证据：`.build/offline-next/swift-tests.log`、`guest-tests.log`、`build.log`、`consumer-build.log`。构建包包含安装源码；单独编译的新版消费端位于隔离目录 `.build/libvcamcaptured.dylib`，未替换仓库中的预编译 dylib，未部署到客户机。运行中 VM 的完整验收和模块升级仍待安排。

## 2026-09-15：rig2 部分运行验证

已在独占 rig2 上验证同 generation 新呈现标识、旧呈现停止拒绝、暂停接收后新源发布、中性源发布、keep_last 停止和完整重启后的旧源隔离。未取得消费回执；Camera 与 Code Scanner 未启动，截图停留欢迎画面，应用显示与 QR 识别未通过。原客户机与消费端已恢复，rig2 已关闭。范围与证据见 [rig2 运行记录](camera_e6_rig2_2026-09-15.md)。E6 保持进行中。
