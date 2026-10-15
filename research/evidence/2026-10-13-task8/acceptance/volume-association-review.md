# Task 8：APFS 卷关联检查修复

日期：2026-10-13。

## 现象与根因

真实 v3 kernel-only 更新在发布磁盘前返回 `Installed volume association differs`。生产检查同时要求 `diskutil apfs list -plist` 的成员记录和 `diskutil info -plist` 的单卷记录都包含精确 `MountPoint`。

对授权备份 `task8-before-binding/Disk.img` 的三卷只读挂载取证发现：APFS 列表的 System、xART、Preboot 条目均无 `MountPoint`；单卷 info 均包含精确挂载路径、正确设备及 `WritableVolume=false`。本次观察中的 physical store、容器及切片关系为 `disk7s1 → disk9 → disk9s1/s3/s5`。设备号为本次挂载动态分配，不进入实现。

字段来源差异导致拒绝。没有发现 Foundation 尾斜杠差异：attachment 的 `.path` 与三个 info `MountPoint` 均逐字符相同。

## RED 与最小化

`volume-association-real-red.json` 退出码 1；真实捕获的 hdiutil、APFS 列表及单卷 info 直接输入生产 `FirmwareInstalledReadback.validate`，得到同一错误。

`volume-association-minimal-red.json` 退出码 1；同一合法映射仅在 APFS 列表不带 `MountPoint` 时失败，带匹配字段的对照通过。测试固定 image、physical store、container、volume 和 info 路径，隔离列表字段是否存在这一变量。

真实捕获文件位于 `volume-association/`；`volume-association-capture-sha256.json` 记录文件摘要。`volume-association-capture.py` 只读挂载并在 `finally` 中卸载。`volume-association/detach.json` 记录卸载退出码 0。未修改 task8-copy 或其他 VM 磁盘。

## 修改与安全条件

APFS 列表负责证明 volume 是已关联容器中的唯一设备成员。该列表如果提供 `MountPoint`，仍必须与目标精确一致。单卷 info 始终负责证明精确的 DeviceIdentifier、MountPoint 和读写状态。

image → backing device → physical store → APFS container → volume 的关联检查保持不变。若 APFS 列表或 info 提供卷 UUID，要求双方均提供合法 UUID 且一致，以拒绝跨观察记录中的卷身份变化。

## GREEN 与范围

`volume-association-real-green.json` 退出码 0；4 tests / 3 suites 通过，包括真实三卷观察回放、10 个成员/挂载/UUID/设备/读写状态参数化场景、9 个原有 installed readback 场景和 detach 失败拒绝。独立审查确认字段来源和完整关联链保留，无新增阻断项。

该结果证明真实 APFS 观察可通过修复后的静态关联检查，且所列不匹配输入仍被拒绝。签名包的实际更新、发布中断恢复和 VM 启动由后续验收记录证明。
