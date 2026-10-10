# B32：T08 倒置方向过滤与系统应用场景策略（2026-10-10）

本轮完成用户指定的180°过滤条件定位及Settings/Safari实际运行时场景策略采集。T08仍为部分完成，未新增整项accepted，未修改产品源码、固件补丁、内核或DSC。

## 实验设置

运行对象为独立RootHide研究VM `vm-roothide-20261010`，源`vm-new`保持停机。沿用B29显式激活流程与原API_ONLY daemon（SHA256 `83075a0c9de2ff5bbfd01b211ce204f59bd18cdf9eb0efb7bd0891a62f00bc07`）；classic系统、缓存和VM载荷均保持原摘要。B30 entitlement候选的旋转矩阵已在B31验证，本轮没有替换该候选或宣称默认产物已更新。

宿主仅复用已获用户授权的冻结VM工件，CDHash `62a1f395413f6878c4de0042f6e77962aa2b1219`、SHA256 `c8e8be423f47c2bc85a7bca5715c306a49cbacba1442a5882416493660a5f8ff`。首次启动被SIGKILL，`--help`亦被拒绝，amfid记录-424。随后恢复同一单哈希临时驱动，paths=[]、allow_all=false、spoof_apple=true；没有修改持久SIP/AMFI/TCC设置。`host-scope.json`保留准备阶段状态，实际执行及清理见本报告和驱动日志。

客户机临时运行缓存deb提取的Frida 17.17.0，宿主客户端17.16.1。仅绑定VM私有IP的39032端口并启用随机令牌；未安装Frida系统服务。包、服务端和agent摘要见`frida-package.json`。系统应用只读场景查询及返回值记录；改变返回值的对照严格限定测试应用进程，并检查主可执行文件名。令牌与私有启动脚本不归档。

## 过滤条件与证据

实际UIKitCore方法`-[UIApplication _supportedInterfaceOrientationsForWindow:]`取得候选集合后执行：

```
if (_UIDeviceNativeUserInterfaceIdiom() == 0 && ![UIDevice _hasHomeButton]) {
    mask &= 0x1a;
}
```

该伪代码只表示已观察的过滤分支。运行时方法地址`0x18c1f906c`；`0x18c1f9154`调用原生设备类型，`cbnz`跳过手机过滤；`0x18c1f9164`调用`_hasHomeButton`，随后`mov w8,#0x1a`、`and`、`cmp`和`csel ... ne`在false时选择过滤值。0x1a=26=portrait(2)|landscapeRight(8)|landscapeLeft(16)，不含portraitUpsideDown(4)。原始字节、反汇编及分支目标见`application-orientation-methods.json`及两份`*-filter-condition.json`。地址是本次运行观测值，不是补丁逻辑。

在两项系统应用内记录UIKit自然调用的返回值，均取得原生设备类型0以及`UIDevice _hasHomeButton`返回0。接收对象地址解析为`UIKitCore!OBJC_CLASS_$_UIDevice`。没有通过改变系统应用返回值构造结果。

受控应用沿用B31 v4 IPA，初始安装查询为空。相同PID、控制器声明30、公开UIApplication集合30保持不变，仅在该进程将`_hasHomeButton`调用结果临时改为true：

| 实验设置 | 私有UIApplication集合 | 解析后的控制器集合 | 场景集合/客户端集合 | 公开180°请求 | 实际场景方向 |
| --- | --- | --- | --- | --- | --- |
| A：原值false | 26 | 26 | 26/26 | UISceneErrorDomain 101 | 1（0°） |
| B：临时true | 30 | 30 | 30/30 | 观测窗口内未报告错误 | 1（0°） |
| A：恢复原值 | 26 | 26 | 26/26 | UISceneErrorDomain 101 | 1（0°） |

`fixture-aba.json`保留每阶段策略、自然条件返回值及应用内计时日志。该A/B/A验证本样本30→26过滤由上述分支控制。B阶段没有观察到实际180°旋转；“未报告错误”不能记为旋转成功，原因未进一步查明。本轮不绕过产品方向策略。

## 实际系统应用场景策略

| 应用 | 运行时集合 | 窗口控制器 | 控制器声明/解析 | 私有/公开应用集合 | 方向运行结果 |
| --- | --- | --- | --- | --- | --- |
| Settings | 当前场景2、客户端2 | SwiftUI UIHostingController | 30/2 | 2/2 | 0°接受；90°、270°、180°拒绝且保持0° |
| Safari | 当前场景26、客户端26 | BrowserSplitViewController | 30/26 | 26/26 | 0°、90°、270°接受；180°拒绝且保持270° |

完整窗口、有效几何、客户端设置和`_orientationDebugDescription`见`com.apple.Preferences-policy.json`、`com.apple.mobilesafari-policy.json`以及`*-filter-condition.json`。Safari另有UITrackingElementWindowController，其声明与解析均为26。Settings的应用集合本身为2，Safari公开应用集合本身为26；不能把系统应用所有拒绝都归因于本轮受控应用所验证的30→26分支。

停止Frida进程、卸载测试应用后，原API独立重跑8组；该轮目录删除返回400，Frida文件目录仍残留，稍后的仅清理启动才完成删除。4组HTTP200接受，4组HTTP400拒绝且保持角度；RunningBoard确认对应前台应用，8张独立JPEG摘要及方向尺寸复核通过。见`clean-matrix.json`与`clean-images/`。本轮未重建产品，因此未重复运行与研究记录无关的Swift/Python全套测试。

## 失败记录、清理及限制

初始`dispatch_get_main_queue`导出查询失败，改用SDK所定义的`_dispatch_main_q`后策略采集成功，错误保留。随后主动调用内部条件函数的读取尝试未返回，Settings进程退出，客户端报告script destroyed；原因未查明。改为只记录UIKit自然调用后，两项应用采集完成。原始失败日志及进程检查保留；成功的后续读取不能消除先前失败。

首次测试策略文件为root所有、0600，测试应用未读取到几何请求；该轮仅验证集合变化，见`fixture-aba-policy-only.json`。改为0644后取得公开请求的101/未报告错误/101对照。Frida首次启动曾受RootHide路径重映射影响而失败，随后通过原生串口bash启动；串口记录保留。

第一次目录删除缺少recursive，返回HTTP400，随后正常停机。最终核对发现残留后执行仅清理启动，使用recursive删除整个`/var/root/vphone-b32`，又删除独立目录检查发现的`b32-frida-help.log`；前两次失败记录均保留。最终父目录列表、进程列表及应用搜索确认本轮诊断目录、b32文件、Frida进程和测试应用不存在，安装容器也通过父目录列表核对。原API和classic摘要保持，方向0°、方向锁false。

临时AMFI驱动收到进程状态10并报告detach失败。独立launchctl记录原amfid退出原因`JETSAM_REASON_MEMORY_IDLE_EXIT`；未将该记录解释为正常detach。随后kickstart原系统服务，新amfid PID49825、PPID1、Ss及launchctl running独立核对通过；驱动及其debugserver已不存在。最终空闲快照中amfid再次退出，服务仍记录同一空闲退出原因，没有停止态进程。未使用执行缓存中的`--help`成功来证明单工件放行已经撤销。仅清理启动复用同一工件的执行缓存，未再次运行临时AMFI驱动。

两次成功启动均正常停机（Guest stopped、ApplePSCI system off、退出0），源与clone磁盘句柄均释放。源vm-new四个小文件摘要以及Disk.img大小和mtime保持；未计算64GiB磁盘全量摘要。既有vm-2607 PID35668保持运行，未连接其诊断端点。

独立0.5秒磁盘监测及每次API前检查保持5GiB阈值。两次成功运行最低余量分别35352100864与35273768960字节（约32.92与32.85GiB），未触发阈值。最终余量见`host-final.json`。

T08剩余为旧CFW自动激活RootHide及默认产物完整构建、来源一致性和整体验收；本轮B阶段180°实际未转动的现象也不能计为已解决。系统应用场景策略和本研究样本的UIKit过滤条件已取得。
