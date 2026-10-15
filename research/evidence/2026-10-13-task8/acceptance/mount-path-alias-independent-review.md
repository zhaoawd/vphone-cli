# Task 8 系统路径别名修复独立复核

审查者为最终签名工件代理，未实施本次生产代码修改。审查范围为第四版构建副本与当前 `FirmwareInstalledReadback.swift` 的差异、调用方目录约束、拒绝测试及真实 GREEN 证据。

未发现阻断问题。新增比较仅把完整 `/tmp`、`/var` 前缀映射到 `/private/tmp`、`/private/var`，不解析任意符号链接、不折叠 dot components、不接受 `/tmp-other` 等相似前缀。使用点限于镜像路径与两个挂载路径观察。

镜像/设备唯一对应、APFS physical-store、唯一容器、固定卷切片、成员唯一性、UUID交叉校验及每卷读写状态比较均保持。`FirmwareKernelMount.withVolumes` 仍要求三个准确卷名，并在body前后核对lstat目录设备号/inode；`FirmwareComponentReceipt.relative` 保留事务工作目录范围及中间目录检查。

拒绝测试覆盖任意symlink、dot-component、相似前缀、错误设备/挂载点/UUID、重复或缺失成员；既有readback测试覆盖目录替换、linked subtree、镜像变化和detach错误。两个系统别名均有正反向比较测试。

已核对真实观察回放和完整live测试结果均exit0，解压日志SHA与结果文件一致，结果中生产源SHA与当前文件一致。完整live测试执行候选EXP producer/gate/region/DSC、真实kernelcache swap、写后读回、detach、readonly重新挂载读回，最后比较只读阶段磁盘SHA；测试170.131秒通过。最终附件记录无残留挂载。

这些证据支持本次兼容修复和候选读写链；不证明正式事务发布、真实VM启动或回退已通过。
