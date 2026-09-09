# C3：less 独立镜像验收

独立目录：`research/artifacts/c3-less-2026-09-09/work/restore`。源为 `vm-2607/iPhone17,3_26.1_23B85_Restore` 的 APFS 克隆。源 VM 不用于此次挂载或写回。

## 工具来源

Apple macOS 26.1 / 25B78 原始 IPSW：
`https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-04148/791B6F00-A30B-4EB0-B2E3-257167F7715B/UniversalMac_26.1_25B78_Restore.ipsw`

通过 HTTP Range 读取 BuildManifest，按首个 BuildIdentity 的 RestoreRamDisk 路径下载 `043-56831-106.dmg`（209715227 字节）。解包后只读挂载恢复 ramdisk，提取 `System/Library/Filesystems/apfs.fs/Contents/Resources/apfs_sealvolume`，复制为本次工具目录中的 `apfs_sealvolume_26.1` 并重新签名。已卸载此次 ramdisk。

签名后工具 SHA-256：`3b1e1e7190456cd51100e76a3b7fca71524848e951a4baaf9d754ec0b3f6a9d4`。验收通过 `VPHONE_SEAL_DIR` 指向隔离工具目录。相同签名文件另已安装到 `/Users/qcz3840/.vphone/tools/apfs_sealvolume_26.1`，供正常工具缓存解析使用。

## 首次完整运行

显式启用 `LessFilesystemAcceptanceTests`，使用真实 Filesystem 和 Manifest 结构化执行器。测试只接受本次研究产物目录，输出分组件 JSON 报告。

首次通过解密、OS 转换、App/System Cryptex 合并、dyld/GPU/activation 修改、vphoned 与 binpack 安装阶段，在最终 `hdiutil convert` 返回“设备上无剩余空间”。Filesystem 报告 failed，Manifest 未执行，总耗时 101.735 秒。运行前可用约 41 GiB；进程结束后临时镜像与挂载清理，可用空间恢复约 40 GiB。失败日志和报告已保留。

该流程一直把解密 OS、解密 SystemOS 和原始合并镜像保留到整个 patcher 销毁。现在在成功转换后删除本次解密 OS，在成功复制并卸载后删除本次解密 SystemOS，在成功重封装后删除原合并镜像。AppOS 和 restore 原输入保留。此修改缩短临时文件的保留时间，不改变复制、补丁或加密算法。

## 完整流程重跑

调整临时文件释放后，同一隔离目录的真实 `LessFilesystemAcceptanceTests.completeFilesystemAndManifest` 通过，耗时 1207.272 秒。Filesystem 和 Manifest 报告均为 applied，无必要步骤失败。测试实际执行挂载、合并、重封装、AEA 加密、trustcache、mtree、digest.db、root hash 生成及 Manifest 哈希更新。

| 组件 | 输出 | 字节数 |
| --- | --- | ---: |
| OS | `new-filesystem.dmg.aea` | 9797894144 |
| StaticTrustCache | `Firmware/new.trustcache` | 162412 |
| Ap,SystemVolumeCanonicalMetadata | `Firmware/metadata.mtree` | 49376379 |
| SystemVolume | `Firmware/metadata.root_hash` | 229 |

四个组件的 SHA-384 均通过独立流式计算，与输出 BuildManifest 的 Digest 相等。IM4P 类型分别检查为 trst、msys、isys；canonical metadata 解包得到 mtree.txt 与 digest.db；root-hash payload 为 208 字节。重新解密最终 AEA 成功；只读挂载检查确认 vphoned、launchd_cache_loader、SystemOS dyld cache、dyld 符号链接及 mobileactivationd 存在。

源目录和克隆目录的三份 OS/AppOS/SystemOS 输入 SHA-256 相等，记录于 `input-hashes.json`。本结论只确认这些输入一致，不将已有 VM restore 目录直接认定为未修改的原始发行镜像。

## 独立根哈希验证

生产流程先加密合并镜像，再从未加密副本删除以下目录、生成 canonical metadata 和 root hash：

- `private/var/MobileAsset/PreinstalledAssets`
- `private/var/MobileAsset/PreinstalledAssetsV2`
- `private/var/staged_system_apps`

因此验证使用最终 AEA 的独立解密副本，按生产流程删除这些路径，并从已输出 mtree 的 `private/var` 修改时间恢复 remap plist：`MODIFICATION=1788942618641165271`。不能直接把含这些目录的交付镜像与删除后的 canonical root hash 比较。

最初校验返回 65。完整 mtree 比较发现 446996 项 modification time 差异，以及唯一额外目录 `.fseventsd`。时间差异对应前一次 seal remap 的全局修改时间；`.fseventsd` 是此次可写挂载后新增的目录，不在 canonical mtree 内。小型 APFS 对照中，同一未重新挂载的卷生成后立即校验成功；重新挂载后 inode 数增加并出现 `.fseventsd`，验证失败。仅根据此前失败不能归因于 ctime 或封装参数。

从验收副本删除额外的 `.fseventsd` 后，卸载卷，以原 remap、原 digest.db、原 IM4P root hash 执行以下校验，退出码为 0：

```sh
apfs_sealvolume_26.1 -R remap.plist -u digest.db -P -I metadata.root_hash "$volume_device"
```

`$volume_device` 必须来自本次隔离镜像的挂载结果。未修改预期 root hash，未使用允许摘要不匹配的 `-a`。此次验证不要求改动生产加密顺序或新增时间归一化规则。

随后在同一已卸载的验收副本上去掉 `-u digest.db`，再次执行 `-R remap.plist -P -I metadata.root_hash`，退出码同样为 0。此步骤没有从外部 digest.db 导入摘要。两种校验均使用原始输出 root hash，未重写预期值。

## 复跑与证据

环境门控测试需要独立的 restore 克隆和匹配版本的 seal 工具。`VPHONE_LESS_ACCEPTANCE_RESTORE` 只允许本研究产物目录；测试会写入该克隆，不能指向使用中的 VM。

```sh
sudo -n env \
  VPHONE_LESS_ACCEPTANCE_RESTORE="$PWD/research/artifacts/c3-less-2026-09-09/work/restore" \
  VPHONE_SEAL_DIR="$PWD/research/artifacts/c3-less-2026-09-09/tools" \
  VPHONE_PYTHON="$PWD/.venv/bin/python" \
  VPHONE_ROOT="$PWD/research/artifacts/c3-less-2026-09-09/cache" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache" \
  SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache" \
  swift test -c release --skip-build --disable-sandbox --cache-path .build/test-cache \
  --filter LessFilesystemAcceptanceTests
```

再次执行完整流程前，需要从源重新建立隔离克隆及输入 Manifest；不要把上一次已改写的 Manifest 当作新输入。

证据归档目录为 `research/artifacts/c3-less-2026-09-09/`（Git 忽略的大型产物）：完整运行日志、分组件报告、输入哈希、`verify/manifest-hash-verification.json`、`verify/content-check.json`、解包 metadata、remap、根哈希验证及小型对照日志。完整默认回归重跑通过：Python 73、XCTest 20、Swift Testing 296。第一次回归有一个进程清理测试超时，单测及完整重跑均通过，超时原因未查明。

本次覆盖 less 的真实 Filesystem → Manifest 产物链。未执行刷写、恢复或 VM 引导；不表示 C4 跨文件回滚或 C3 全部支持矩阵已经完成。

验收完成后已卸载真实镜像与小型 APFS 实验镜像，`hdiutil info` 确认没有本次验收挂载。已删除独立解密验证副本和小型实验镜像；最终 AEA、Manifest、metadata、哈希与日志保留。
