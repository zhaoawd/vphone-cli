# 离线标记镜像工具独立审查

本次审查版本 SHA256 为 `fd4df3dd4b7043809e7b47691010d14dcc0156001f19da7730dedffe57dd7395`。结论：默认归档检查的静态边界未发现阻断；可选当前 Documents 检查存在一项阻断，修复后需要复审。未执行工具入口、真实进程检查、VM、客户机、hdiutil 或挂载。

独立运行现有纯测试退出 0，23 项通过。测试全局替换 subprocess.run；FakeOperations 仅创建普通临时目录和文件。测试结果不能证明真实 APFS 挂载兼容性。

## 问题

`main():403` 对 config.plist 调用 `load()`，但 `load():344–346` 无条件调用 `decode_json(raw)`。因此有效 XML plist 抛出 JSONDecodeError，有效 binary plist 抛出 UnicodeDecodeError；后续 plistlib.loads 无法执行。独立合成复现记录在 independent-tests.json。该错误在 current Disk 挂载前失败，不导致可写挂载，但阻止所需 Documents 落盘观察。要求明确区分 raw/plist/JSON 读取，保留输入 frozen SHA、普通文件身份和最终逐字节重验，并增加可选分支回归。

## 静态检查

- 固定 task8-copy、归档事务和两个 64 GiB 镜像摘要；已提交四 JSON 与归档逐字节相同，proof/receipt/report 摘要链和实际读回证据关联。当前 Disk 允许正常启动后全盘摘要变化，仍要求相同 device/inode/size 和本次前后完整 SHA256 相同。
- 排他目录 flock、pending 拒绝、Task8 附件拒绝和对应 vphone-vm 进程检查位于挂载前。目录逐级拒绝符号链接；镜像和证据文件要求 O_NOFOLLOW、单硬链接普通文件及前后身份稳定。
- 仅 attach -readonly -nomount -nobrowse；唯一 GUID backing device 必须映射回精确 image path。APFS container 的 PhysicalStores 必须精确等于该设备的单个 diskNs1，名称 Data/UserData 唯一。mount_apfs 仅 rdonly；前后 diskutil info 都验证 UUID、设备、卷名、PhysicalStore、MountPoint 和 WritableVolume=false。已出现的 encryption 字段须为 false；读取失败或未知值拒绝。
- 标记路径固定为 Data/tmp 或 UserData/Documents 下的 UUID 名称，逐级 openat/O_NOFOLLOW；存在则必须完整字节相同。归档缺失属于观察；当前 Documents 缺失失败。PermissionError、加密或清理失败不能升级为缺失。
- finally 仅清理本轮 attach 尝试后仍能关联到精确 image/backing device 的附件；已有附件在 attach_attempted=false 时不会被 detach。无 force detach；detach 未成功时不删除挂载目录内容。每个镜像 finally 再读完整 SHA256 与全部文件身份；结束再验 pending/附件及所有冻结小输入。

## 证据范围

纯测试覆盖错误 PhysicalStore、重复 container/卷、预存附件、部分 attach 失败、detach 失败、可写/加密拒绝、镜像变化、路径/硬链接/符号链接拒绝，以及旧标记与 v2 sync/file_get 的实际证据字段。现有测试未调用 main 的完整可选链，导致本次 plist 问题未被覆盖。真实挂载和实际两类卷结构仍由根任务后续验收。旧 tmp 标记缺失原因未查明。
