# T32/T33 文件读取的静态证据（2026-10-24）

仅只读提取已有发布产物和当前候选签名中的entitlements，未启动VM、开启窗口、修改签名权限或部署探针。AA.gl EPERM的具体拒绝机制原因未查明。

核查对象为regular已发布事务`20261024T004144Z-SaOxXsod`（4f9d10893183候选）的effect-blobs，以及当前a84f5889b159候选中的classic/API程序。blob按原记录摘要核对后提取，不涉及当前运行中事务的暂存文件。

原始seputil和该次已发布seputil的三项entitlement完全相同：`com.apple.private.applesepmanager.allow`、`com.apple.private.kernel.get-kext-info`、`com.apple.security.iokit-user-client-class=[AppleSEPUserClient]`。在该发布产物中未发现这些entitlement丢失；该结果不证明此前诊断VM实际加载同一产物。

候选classic有250个顶层entitlement键，API有265个；二者没有上述SEP manager键或AppleSEPUserClient类。此静态差异尚未与文件open拒绝建立因果关系，不能据此添加权限或认定拒绝由该差异导致。

两个候选LaunchDaemon plist未显式设置UserName、GroupName或SandboxProfile。本次没有读取旧运行进程实际UID、有效权限、沙箱状态或文件数据保护属性。

后续实际诊断需同时记录读取时的锁屏状态、调用程序身份和错误；原观察器在解锁前读取AA.gl，解锁后的可读性尚未验证。当前未重新挂载或完整审计该历史磁盘，没有取得或保存新的gigalocker原始内容。既有失败及严格验收要求保持。

完整entitlements、原件索引、发布输出索引和原始记录的副本及摘要见`evidence/T32-T33-completion-20261023/runtime-access-static-20261024/manifest.json`。本项不提升T32/T33运行验收状态。

## 已有观察接口

等待离线重应用期间，只读核对了当前仓库的接口实现。`processes.list`会添加UID、PPID和启动时间；Native实现从`sysctl`取得`kinfo_proc`并读取`e_ucred.cr_uid`及`p_starttime`。查询失败可能省略该进程，不能把缺少记录写成进程不存在。

`files.list`显式补充大小、权限和mtime；本次未完整查证底层原始条目的所有字段。`files.read`接受`binary`及`limit`参数，可作为后续对照读取入口；本次未查证其底层返回格式，也未读取AA.gl。现有宿主另有`shell`路由，本次没有执行或纳入运行计划。

这些是仓库源码事实，尚未通过当前候选的实际运行能力和回复验证。后续具名计划可在读取失败前后记录进程身份、锁屏快照和元数据，保留每个接口的错误，并比较读取条件。它们不证明当前EPERM的原因，也不授予修改UID、权限、entitlements或安装探针的范围。原锁屏状态在SpringBoard未就绪时的限制保持。

源码与核对记录：`evidence/T32-T33-completion-20261023/runtime-access-interface-review-20261024/manifest.json`。新增VMStarts=0、securityWindows=0，未创建新运行计划。


## 旧请求顺序复核

已按原manifest摘要重新核对short/display两次运行的requests.jsonl和serial.log。两次观察器均先调用device.snapshot，再通过classic file_get读取AA.gl并收到EPERM，随后才尝试screen.unlock；记录的请求流中，AA.gl拒绝前没有app_foreground请求。两份宿主serial.log均没有orig_euid/now_euid日志；这不能证明客户机进程当时的有效UID，也不排除未记录的其他请求。

当前classic源码将app_*请求分派到并发worker；file_get在reader线程同步执行，app_foreground会临时seteuid(501)并调用seteuid恢复，恢复结果未检查。该源码提示可核对身份与并发条件，但未证明上述历史EPERM由身份变化导致。静态代码与旧运行二进制/当时进程状态的对应仍有限，原因未查明。未修改身份、权限、daemon或本轮冻结输入。核对记录及源码副本见runtime-request-order-review-20261024/manifest.json。
