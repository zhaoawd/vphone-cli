# T32/T33 文件读取的静态证据（2026-10-24）

仅只读提取已有发布产物和当前候选签名中的entitlements，未启动VM、开启窗口、修改签名权限或部署探针。AA.gl EPERM的具体拒绝机制原因未查明。

核查对象为regular已发布事务`20261024T004144Z-SaOxXsod`（4f9d10893183候选）的effect-blobs，以及当前a84f5889b159候选中的classic/API程序。blob按原记录摘要核对后提取，不涉及当前运行中事务的暂存文件。

原始seputil和该次已发布seputil的三项entitlement完全相同：`com.apple.private.applesepmanager.allow`、`com.apple.private.kernel.get-kext-info`、`com.apple.security.iokit-user-client-class=[AppleSEPUserClient]`。在该发布产物中未发现这些entitlement丢失；该结果不证明此前诊断VM实际加载同一产物。

候选classic有250个顶层entitlement键，API有265个；二者没有上述SEP manager键或AppleSEPUserClient类。此静态差异尚未与文件open拒绝建立因果关系，不能据此添加权限或认定拒绝由该差异导致。

两个候选LaunchDaemon plist未显式设置UserName、GroupName或SandboxProfile。本次没有读取旧运行进程实际UID、有效权限、沙箱状态或文件数据保护属性。

后续实际诊断需同时记录读取时的锁屏状态、调用程序身份和错误；原观察器在解锁前读取AA.gl，解锁后的可读性尚未验证。当前未重新挂载或完整审计该历史磁盘，没有取得或保存新的gigalocker原始内容。既有失败及严格验收要求保持。

完整entitlements、原件索引、发布输出索引和原始记录的副本及摘要见`evidence/T32-T33-completion-20261023/runtime-access-static-20261024/manifest.json`。本项不提升T32/T33运行验收状态。
