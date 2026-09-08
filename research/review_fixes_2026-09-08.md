# A2/B1/B2 与触控评审修复记录

## 范围与执行顺序

依据两轮评审及用户确认，在当前分支修复，不开始 B3。保持目录 inode `flock` 协议，不修改二进制补丁。

1. CFW：限制属主恢复范围；启动与恢复属主前检查 VM 目录内的挂载；使用 attach plist 识别基础设备；解析失败保留原始记录；普通卸载最多尝试三次，失败时不分离基础设备、不翻转快照。
2. 缓存：区分已确认的无效元数据与工具、解析错误；后者保留缓存并停止；输出不含 AEA 密钥的错误；验证真实 SystemOS 专用副本。
3. 锁：运行记录写失败只告警，继续持锁；测试只读 bundle 导出、记录路径不可写、同一 VM 两个 Shell 安装入口互斥；可选固件清理失败不阻止后续步骤。
4. 触控：手势开始时固定注入路径与连接代次；断连后丢弃该手势后续事件；来宾会话结束时释放触点；禁止孤立 move/up 创建触点。
5. 完成快速测试、原生测试、主机及来宾构建；修正研究文档路径和证据限制。真实来宾交互与完整 CFW 安装分别记录，不能由单元测试替代。

## 实现与测试文件

- [CFW 驱动](../scripts/cfw_install_host.sh)、[入口回归](../tests/test_cfw_host_isolation.py)、[原生挂载回归](../tests/cfw_host_mount_native.py)。
- [缓存](../scripts/cache_systemos.py)、[缓存回归](../tests/test_systemos_cache.py)、[原生镜像验证](../tests/systemos_cache_native.py)。
- [Swift 锁](../sources/VPhoneCore/VPhoneVMLock.swift)、[Python 锁](../scripts/vm_lock.py)、[Swift 回归](../tests/VPhoneCoreTests/VMLockTests.swift)、[Python 回归](../tests/test_vm_lock.py)。
- [手势路由](../sources/vphone-cli/VPhoneTouchRoute.swift)、[路由回归](../tests/VPhoneCLITests/TouchRouteTests.swift)、[来宾 HID](../scripts/vphoned/vphoned_hid.m)、[IOKit 边界测试](../tests/test_guest_touch.py)。

## 缓存行为与真实镜像证据

校验仅确认工具可识别的文件系统及分区容量范围，不确认文件内容完整性，不确认缓存与源固件版本一致。

明确的空文件、加密标志、非法容量、分区越界、无可识别文件系统会触发重建。`hdiutil` 返回非零、plist 无法解析、预期键缺失或类型不符时，无法确定缓存损坏，保留缓存并停止。截断镜像可能触发工具失败，因此不能概括为所有截断均自动重建。

已在临时目录复制并校验以下两个实际文件；临时副本均已清理，未挂载 VM 磁盘：

| 输入 | 大小 | SHA-256（副本） | 结果 |
| --- | --- | --- | --- |
| `vm-2607/.cfw_temp/CryptexSystemOS.dmg` | 4,951,375,872 字节 | `9f884b58c33071a164c4242a8610947a95f1b35cdd4131de136f4f55d4747d7e` | 通过 |
| `vm-2607-rig2/iPhone17,3_26.1_23B85_Restore/043-54303-126.dmg.aea` | 4,951,375,872 字节 | `2bc28dbe8305a392ffd75e5fdfb5a904ce389c14296742b94dd00cced28f38dd` | 通过，输入已解密 |

该固件路径由 `iPhone-BuildManifest.plist` 的 `cryptex-paths` 解析结果确认。两者 `imageinfo` 均返回：`partition-scheme=none`、`block-size=512`、`partition-start=0`、`partition-length=9670656`、`partition-hint=Apple_APFS`、`partition-filesystems={APFS: Untitled}`。本次未验证 Apple FCS 密钥获取；两个文件哈希不同，未将缓存等同于原始输入。

复现方式：

```sh
.venv/bin/python3 tests/systemos_cache_native.py
.venv/bin/python3 tests/systemos_cache_native.py --firmware-source /path/to/SystemOS.dmg.aea
.venv/bin/python3 tests/cfw_host_mount_native.py
make test
make vphoned
make build
```

原生脚本须能访问 macOS DiskImages 服务。`--firmware-source` 只向临时目录输出，不改输入。原生测试不会被默认 unittest 收集。

## CFW 失败状态与恢复限制

安装会同时修改 System 卷和数据卷。清理失败且未翻转 System 快照时，已有数据卷修改不会回滚；可能形成旧 System 根与已修改数据卷的混合状态。失败不代表干净回滚。

恢复步骤：保留终端输出及 `.cfw_mount.*/attach.log`；用 `hdiutil info -plist` 和 `mount` 核对镜像、设备、挂载路径的对应关系；停止占用本次挂载的操作，然后普通卸载相关卷和镜像。无法确认设备归属时不得按猜测分离设备。确认 VM 目录下无残留挂载后，使用原 variant 重新运行 `cfw_install_host.sh`。这会重新执行安装，不是从失败阶段继续；完整的部分安装重跑仍未实机验证。不要在卷挂载期间直接运行离线快照工具。

驱动不强制卸载、不删除残留挂载目录内的数据；未知 attach 输出无法确认设备时保留记录并报错。未挂载的旧空目录不会自动清理。

## 触控验证边界

路由测试覆盖原生手势中来宾连接、来宾手势中断连及重连、结束后新手势。Objective-C 测试直接编译实际 HID 实现，替换 IOKit 函数边界，确认释放事件使用最后坐标、重复 reset 不产生额外事件、孤立 move/up 被忽略。它不证明 BackBoard 接收或显示触控结果。

来宾新增 `vp_hid_touch_reset`，必须部署新 `vphoned` 才有会话结束释放行为。现有运行中的 `vm-2607` 有健康监控，本次未重启、未部署或注入触控。26.x 真实点击、拖动、边缘手势仍需验证；来宾协议仍不携带 VZ `swipeAim`，不能宣称两条路径等价。

## 证据与文档可移植性

历史 231/237 是当时 Swift 与 Python 合计，不是当前 Python 用例数。原始 `research/artifacts/` 日志被 Git 忽略，存在与否取决于工作区，不保证其他机器可访问。本文保存关键输入、哈希、命令、结果与限制；历史文档链接改为仓库相对路径。历史测试结果保留原日期，不替换为当前计数。

## 已确认的运行限制

`make build` 与 `make vphoned` 成功，主机 release 与 app 的 `codesign --verify --strict` 均通过。但两者执行 `--help` 均返回 `-9`（SIGKILL），stdout 和 stderr 均为空，原因未查明。此前 B2 已记录同类现象，本次未修改系统安全设置或移除生产二进制私有权限来绕过它。26.x 真实触控与完整 CFW 安装仍未完成，因此 B3 保持未开始。

原生 attach 测试曾发现 APFS plist 同时列出物理磁盘与合成容器。解析现优先选取 `GUID_partition_scheme` 等分区表实体；无分区表时只有唯一基础设备才接受，歧义时保留输出并停止。新增回归覆盖该实际输出形状。测试失败留下的临时设备已通过 `hdiutil info -plist` 确认归属并普通分离；原生测试也已补充异常退出后的镜像清理。

## 最终验证结果

| 验证 | 结果 |
| --- | --- |
| `make test` | 退出 0：Python 53、Swift Testing 196、XCTest 20，共 269 项通过 |
| 同一 VM Shell 入口及 CFW 回归 | 13 项通过，已包含在 Python 53 项内 |
| 原生 APFS/AEA | 通过；测试密钥解密、工具失败时保留缓存、错误输出不发布缓存 |
| 真实已解密 SystemOS | 上表两个专用副本通过；未验证 Apple 密钥获取 |
| 原生 APFS 挂载清理 | 通过；其他任务的挂载保留；退出 37 保留；真实 attach plist 识别物理磁盘并分离 |
| 来宾 HID 回归 | 通过，已包含在 Python 53 项内；IOKit 边界替身，不代表真实交互验证 |
| `make vphoned` | 退出 0，iOS arm64 交叉编译与 ldid 签名完成 |
| `make build` | 退出 0，release 与 app 构建完成 |
| 主机 `codesign --verify --strict` | release 与 app 均退出 0 |
| 四个修改后安装脚本 `zsh -n`、`git diff --check` | 通过 |
| 签名主机程序 `--help` | release 与 app 均 SIGKILL，返回 -9，无输出；原因未查明 |

构建仍报告既有 `VPhoneMenuRecord.swift` 的 `shouldReveal` 未使用警告；本次未修改该文件。快速测试不包含固件夹具集，不能据此宣称固件补丁验证通过。

原始日志保存在当前工作区被 Git 忽略的 `research/artifacts/review-fixes-2026-09-08/`，其他 checkout 不保证具有这些文件。以上结果与样本元数据直接保存在本跟踪文档中，便于跨机器核对。
