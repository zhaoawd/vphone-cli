# T52 共享相机 provider 为 nil 的修复候选

当前需要用户批准新候选的部署计划：`.build/t52-provider-fix-20261023/deployment-plan.json`。候选 `2.6.2-local.4bd0cce62c46` 已构建、签名和封装，尚未安装。t52-v2 仍运行 cc05d88f441f；定位两点各 5 条正确回调的结果保持，相机复制回执通过，QR 仍未通过，T52 `accepted=false`。

## 实际诊断

用户批准的限定重启已执行。首次前置检查发现探针 PID735 正在运行，工具在发信号前拒绝；该轮没有 processes.kill 请求，也没有 signal-intent。停止具名探针后，第二轮重新核实 cameracaptured PID70、UID501、启动时间1792683621.488895及两库摘要，仅发送一次 TERM。launchd 正常创建 PID809，UID501、启动时间1792686567.919082。7个重叠4秒窗口采集561条初始化日志，无采集错误；探针阶段217条日志，结束时探针停止。

日志确认 BGRA/420v 两个格式和虚拟 backing 创建成功，`native sourceBackings provider installed`。之后原生硬件来源信息仍为空，出现 `captureSourceBackings.count` 断言；视频类型1返回0个源。重启没有消除空设备现象，故没有再次发送 TERM。

同版本 CMCapture UUID `56F23E85-0EA1-34F1-AAEC-FFE67067538A` 的只读元数据确认：sourceBackings 属性声明 NSArray，实例变量声明 NSMutableArray。此前“非 NSArray 返回值”解释没有取得支持。只读控制流显示，共享 provider 在原生源信息数组 count 非0时才分配；count为0且没有既有实例时，返回 nil。该路径使用 Objective-C direct 初始化实现，运行时 selector 查询没有对应初始化方法。

正常相机授权后，临时探针调用原生共享 getter，实际记录 `providerIsNil=1`、`sharedMethodAvailable=true`、`initializerAvailable=false`。这是应用进程内的实际查询。结合新 cameracaptured 的初始化日志与同版本控制流，证据支持原生 provider 缺失使实例 getter hook 无法参与本轮枚举的解释；daemon 内修复效果仍需部署验证。

## 修改与回归

原实现只 hook 实例 getter。新增真实代码回归先复现 `shared != nil` 断言失败：原生共享 getter 返回 nil 时，实例 getter 的合并代码没有接收者。修复增加共享 getter hook；原生返回有效实例时原样保留，返回 nil 时仅构造一次该原生类实例，由已有实例 getter 合并实际 backing。不写框架共享实例全局变量或私有实例变量，不修改原生指令页。

5种集合/实例场景通过：nil列表、空列表、已有原生来源、重复旧虚拟来源、共享实例为nil。已有原生实例身份、原有来源和恰好一个当前虚拟 backing 的断言保留。

同权限临时探针在自身进程编入实际 backing 构造和两项 getter hook。原生共享查询先返回 nil，修复后返回 FigCaptureSourceBackingsProvider，backings 为 NSMutableArray、count=1，并包含同一个实际构造的 backing。该诊断不计为 QR 消费验收，未将 hook 安装到 daemon。结束后恢复原探针摘要 `02795c7a8bf30799bd309832f1bad6f70200fcc5b2bdc04cc417c773108faaee` 并停止。

候选仅改变 libvcamcaptured。其他库、API、classic/v2发布端、GPU、Framework及宿主VM可执行文件逐字节保持。宿主VM CDHash仍为 `89cb8ee4c9f47b15a1c63bd73c99b53a0d43a541`。首次给库使用探针的项目CMS签名时，macOS严格核验报 `CSSMERR_TP_NOT_TRUSTED`；失败产物和日志保留。最终库采用与已部署基线一致的ad-hoc签名，严格核验通过，没有更改核验条件。

| 对象 | 结果 |
| --- | --- |
| 完整 Python | 1017项，跳过4项，退出0；沙箱外运行 |
| 单库完整克隆事务 | 9项通过；仅一个库变化，API不重写，旧盘保留和故障恢复通过 |
| 验收及辅助清理工具 | 24项通过；保留身份、错误期望、QR、回执断言 |
| 原生 nil/fallback 诊断 | 应用内查询与实际构造通过；daemon效果未验证 |
| 重启后真实 QR 复验 | 原设备列表为空；v3复制回执通过，消费失败 |

完整Python的沙箱内运行出现宿主进程及脚本执行限制失败，保留日志，向逐字核实的该测试PID30060发送SIGINT停止；没有操作VM进程。随后同一标准入口 `make test_python` 在沙箱外通过。

真实消费工具首次读到旧诊断的大文件时因1MiB内联上限提前失败。工具改用正常文件下载，仍核对新runID、PID及原消费断言；新增回归确认旧身份仍拒绝。复验进入本轮run，得到空设备和no usable input，失败证据保留。该工具修正没有改变设备枚举结果。

## 具名候选与部署范围

- 版本：`2.6.2-local.4bd0cce62c46`。
- 归档SHA-256：`a9f2967aff15201335067fa4499c6efa02c754bb05fdf03c53209120faa16639`，194512896字节。
- 新库SHA-256：`d5ca2de19077080387b6fcaf9a26f50648f6dc1b64f9992c94c4158be07b90b4`。
- 仅正常停止并重绑t52-v2；完整克隆停机磁盘，仅替换System上的libvcamcaptured，独立只读复核后原子发布；完整旧盘保持。
- API作为固定只读输入核对，摘要 `f5ce73f00f5694b1639d735af8106436aaf2cfd1bd3dc7211aef6041149cd2a8`；API及发布端均不重写。Data不离线挂载。
- 新窗口最多900秒、单一原CDHash、一次附加、无持久允许名单，独立进程监督。就绪即停止；若本次附加留下暂停状态，只有在辅助退出、debugserver不存在且启动身份匹配时才向同一amfid发送SIGCONT，并核实恢复状态。不得操作新PID或重新附加。
- 原探针数据和程序保留；临时验收完成后恢复原程序并停止。其他VM和既有历史不变，仅允许清理本次事务新建暂存文件。

本次新候选部署超出刚批准的一次cameracaptured重启范围，已提交具体计划请求补充批准。新维护事务、安装和安全窗口均未执行。

部署前只读复核：旧五库、API、新旧发布端缓存及原探针摘要符合基线；来源均off，探针停止。原VM PID33355及base、target、t52-environment三个受保护副本保持。所有旧运行证据和新候选首次失败均保留。
