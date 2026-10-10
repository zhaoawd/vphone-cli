# B31：T08 RootHide 旋转运行验收

日期：2026-10-10（Asia/Shanghai）。工作区基线 `cd6a8b29`。本批仅新增研究证据，未修改产品源码、权限、固件、内核或 DSC。T08 保持部分完成，整项 accepted 数量不变。

## 结果与证据范围

在 `vm-roothide-20261010`、iPhone 客户机 iOS 26.1 上，B30 单 entitlement 修正候选的实际 health binary_hash 为 `177e8d9a7c103d9be206800bde2b118852bd9a64115ac6127f762035c122b59e`。最终矩阵的 API 进程未加载诊断库；临时 UIKit 应用在自身进程读取方向策略。候选编译载荷与 B30 相同，本批没有全量重新构建。

| 实验设置 | 0° | 90° | 270° | 180° | 应用内运行时证据 |
| --- | --- | --- | --- | --- | --- |
| 控制应用，控制器集合 30，首次 | 200/0° | 200/90° | 200/270° | 400/保持270° | 实际集合26 |
| 同一应用，控制器集合 2 | 200/0° | 400/保持0° | 400/保持0° | 400/保持0° | 实际集合2 |
| 同一应用，控制器集合 26 | 200/0° | 200/90° | 200/270° | 400/保持270° | 实际集合26 |
| 同一应用，恢复控制器集合 30 | 200/0° | 200/90° | 200/270° | 400/保持270° | 实际集合26 |
| Settings | 200/0° | 400/保持0° | 400/保持0° | 400/保持0° | 未直接取得其场景支持集合 |
| Safari | 200/0° | 200/90° | 200/270° | 400/保持270° | 未直接取得其场景支持集合 |

共24组方向观测：14组成功、10组拒绝。所有项均保存前后角度、HTTP结果、runningboard 前台身份和独立文件名截图。这里的拒绝项不计为成功旋转。`verify.py` 复核24张 JPEG 的摘要、原图尺寸与 API 元数据一致；16组控制应用的场景角度、实际支持集合与 API 读回一致。竖屏原图1290×2796，横屏2796×1290；已视觉检查控制应用0°和90°截图中的上下标记、文字方向及窗口尺寸。45°输入返回400；方向锁设置为 true/false 后分别读回 true/false。本批未验证锁定状态下旋转请求的全部行为。

集合数值使用 UIKit 的 UIInterfaceOrientationMask：2=portrait，26=portrait/landscapeLeft/landscapeRight，30为四方向。角度与 UIInterfaceOrientation 映射为0→1、90→4、270→3、180→2。

## 运行时策略与180°拒绝

临时应用 `research.vphone.b31.rotation` 的 Info.plist 声明四方向。初版控制器在运行时返回30，原 API 仍拒绝180°。因此，单凭 Safari 的静态声明缺少 portraitUpsideDown，不能解释全部180°现象。

应用内直接调用公开的 `UIWindowScene.requestGeometryUpdateWithPreferences`：0°、90°、270°实际生效；180°返回 `UISceneErrorDomain` code101，原文为 `None of the requested orientations are supported by the view controller. Requested: portraitUpsideDown; Supported: portrait, landscapeLeft, landscapeRight`。控制器仅返回2时，直接请求横屏也返回101，支持集合原文为 portrait。原始错误、请求ID和实际场景采样见 `geometry-matrix.json`。该阶段的 `error=null` 只表示采样时未收到错误回调；成功结论依据实际场景方向变化。

随后按客户机实际方法签名读取 `_FBSScene.clientSettings.supportedInterfaceOrientations`、`_currentlySupportedInterfaceOrientations`、控制器 `__supportedInterfaceOrientations` 和 `_orientationDebugDescription`。本样本中，公开控制器方法返回30、UIApplication公开查询返回30，而三个解析后的集合均为26。调试说明同时记录 `providedSupportedOrientations=( Pu Ll Lr Pd )` 与 `resolvedSupportedOrientations=( Pu Ll Lr )`。当控制器集合切换到2时，三个实际集合均为2；恢复30后均回到26。最终候选复验保全了这个可逆对照。

这确认了控制应用中的180°请求受到 UIKit 运行时支持集合拒绝；尚未定位 UIKit 过滤 portraitUpsideDown 的具体条件，不能归因于某一硬件型号、RootHide或权限。Settings和Safari的直接运行时集合未取得；B30静态声明与本批观测一致仍只作为相关证据。本批没有绕过应用方向策略，也没有把拒绝响应改为成功。默认启动链整体验收仍未完成。

最终矩阵中 `geometry_request` 字段可能保留应用启动时的上一个直接请求结果；不能把该字段中的旧错误当作当前 API setter 的原始错误。当前 API 结果见对应 `change`；直接请求结果见具有匹配 request_id 的 `geometry-matrix.json`。客户机时间戳来自客户机时钟，不用于与宿主绝对时钟比较耗时。

## 查询限制与脚本失败

先在 API 进程内读取真实类与方法签名，确认存在场景支持字段。AX focused/application 查询返回 nil；`FBSceneManager.sharedInstance` 后未取得返回或场景计数。该路径未取得跨进程前台场景，后续已关闭并恢复原 API。启动选项元数据检查也未取得可用的环境变量字段；未向系统应用注入诊断库，未修改系统应用二进制。

以下诊断脚本失败均保留，不计为产品失败：ldid最初使用分隔的 `-K` 参数导致签名错误，修正为 `-K<path>` 后成功；临时库 ARC 指针转换编译错误修正后成功；主队列查询未执行，改用后台队列后记录到查询入口，但场景管理器查询未完成；错误的 RPC `health` 返回 unknown method，后改用 GET `/v1/health`；首次矩阵因自动锁屏而未满足前台身份断言，保全独立失败图后重跑；候选首次上传的 perm 使用数值493，被现有字符串八进制接口错误解释而返回 Permission denied，改用字符串 `755` 后启动。早期数据文件上传也使用数值权限，控制应用仍实际读到策略；最终矩阵统一使用字符串 `644`。最终方向矩阵和候选健康摘要均在修正后重新取得。继承的请求id为B30，证据目录、脚本、进程和阶段名区分本批B31。

## 清理、磁盘与剩余工作

已恢复0°、方向锁false，发送 Home 键。Home前台读回 verified=false，不能把它单独作为强身份验证。临时应用登记、Bundle和Data容器已卸载，apps.search为空，两个父目录独立列举确认容器名称缺失。客户机本轮14个诊断/候选/日志文件已删除，目录复查无本轮前缀。

原 API_ONLY 已恢复，health摘要为 `83075a0c9de2ff5bbfd01b211ce204f59bd18cdf9eb0efb7bd0891a62f00bc07`。系统和缓存 classic 都为 `306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001`。默认启动产物未更新。没有新增宿主 AMFI/TCC 或系统服务操作。

独立磁盘监视器每0.5秒检查5GiB阈值，低于阈值仅请求一次停止。本轮最低35,663,552,512字节（约33.21GiB），未触发阈值。测试 VM 正常退出0，日志含系统关机及 Guest stopped；独立 lsof 确认样本与源 vm-new 的磁盘句柄释放。既有 vm-2607 PID35668保持运行。源 VM 的4个小文件摘要、Disk.img容量与mtime保持；未计算64GiB全盘摘要。停机后独立余量为35,724,140,544字节（约33.27GiB）。

T08剩余：Settings/Safari直接场景策略证据、UIKit倒置方向过滤条件的进一步定位，以及旧CFW自动激活与默认产物整体验收。控制应用的运行时拒绝已取得，不再仅依赖静态方向声明；整项T08仍未验收通过。
