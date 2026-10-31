# T32/T33 后续观察器的 RPC 期限（2026-10-24）

当前离线事务继续运行，未改变其571项计划输入和94项执行输入。本项仅准备后续观察器的独立传输模块，未启动VM或开启辅助窗口，未安装客户机程序。

## 问题与复现

当前宿主的RPC预算为75秒，但`observe_t32_runtime.py`中`call`将外层host-control套接字等待设为20秒。外层可在合法RPC结束前超时。该发现是独立的期限缺陷；未在真实VM上复现新的20秒失败，不能将它作为此前5秒`api_timeout`或AA.gl EPERM的已确认原因。

复现运行真实`observe_t32_runtime.main`、`collect_observations`及`host_control_client.request`，后端为临时Unix套接字。VM生命周期、API回复、AA.gl内容及显示帧均为夹具，未执行任何VM程序。时间按0.005缩放：旧20秒等待对应0.10秒，合法50秒回复对应0.25秒，75秒预算对应0.375秒。新100秒等待对应0.50秒。

首次沙箱运行在`bind`被EPERM拒绝，未到达缺陷；同一夹具在沙箱外稳定复现。实际main返回1、display失败，原文`vm host-control request failed: timed out`。即时有效回复对照通过，延迟有效回复失败；初始复现和对照均保留。

排名假设依次为外层期限不足、回复/显示数据不合格、连接提前关闭。即时回复对照核验原有数据和协议；只延长RPC外层等待后，同一慢回复在实际观察器通过，支持本夹具中的期限原因。

## 修改及验证

新增`t32_runtime_rpc_transport.py`，仅将RPC外层等待下限设为100秒。原观察器源码保持，后续具名运行计划需生成包装入口、接入并冻结该模块及100秒预算；目前没有实际运行计划使用它。能力探测仍为5秒，file_get及截图仍为20秒。

5项隔离回归通过（1.558秒、退出0）：慢RPC完整回复成功；旧观察器仍复现提前超时；即时回复通过；AA.gl EPERM在显示通过时仍保留总失败；`verified=false`前台仍失败。未弱化原有原件、签名、前台、显示或AA.gl断言。完整初始复现经修复模块复验通过。

命令：

```sh
cd /Users/kolar/github/vphone-cli/research/upstream_integration_2026-10-15/tools
/Users/kolar/github/vphone-cli/.venv/bin/python3 -m unittest test_t32_runtime_rpc_transport
```

Unix套接字夹具需允许本机bind；无真实外部服务或VM。没有临时调试日志或生产插桩；夹具为保留的回归资产。预防措施是后续计划显式记录并冻结两层期限，并保留覆盖完整观察器与传输链的集成回归。

## 后续运行证据边界

当前`GuestAPI+SetupAssistant.swift`以mobile的`com.apple.purplebuddy`偏好`SetupDone`和`SetupVersion`相对于`BYBuddyIOSCurrentVersion`判断`setup_pending`。它不是通用的启动完成信号。源码语义不单独证明此前运行的客户机二进制完全同版本，也不能由该字段判定长期停滞。

原观察器在`screen.unlock`之前执行AA.gl读取。既有失败不覆盖已确认解锁后的读取条件；解锁状态与文件访问拒绝之间的因果关系仍未验证。当前`vphoned_files.m`对file_get调用`open(..., O_RDONLY)`并返回errno；EPERM的具体拒绝机制原因未查明。

本模块只修复隔离夹具已确认的外层等待缺陷，不证明真实显示、AA.gl读取或补丁运行效果通过。历史失败保持，T32/T33整项accepted=false。

证据目录：`evidence/T32-T33-completion-20261023/runtime-transport-preparation-20261024/`。
