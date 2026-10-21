# T51：磁盘 rebase 与物理共享计量（2026-10-21）

本轮实现 `vm rebase`、显式恢复入口及 Launchpad 物理计量，完成隔离 APFS 文件回归。未运行真实 VM，未操作冻结 `.app`。模板基准、真实跨卷/非 APFS 故障和实际界面验收仍未完成，T51 不登记为 accepted。

## 范围与来源

固定审阅目标为 `2a0d3aca9fb79344d939365cc337b915ae9f2f97`，本地 HEAD 为 `9e1c31bd856c4433e0058b0564471821dd851db1`，实现包含保留的未提交工作。源码来自隔离仓库 `.build/u0-20261021/input.git`，核对 `2a1e03ae`（rebase）、`eec7350e`（新增/已有共享）、`ab441ae4`（文案）、`9e063a7d`（物理 extent）和 `e31942a9`（运行/忙碌磁盘访问）。六份端点参考文件及摘要与本轮证据一起归档。

上游模板 API 在本地尚未实现。本轮 `--onto` 只接受同一 library 中另一台 VM；不宣称模板标识符、模板使用记录或同模板提示已接入。

## 实现结果

| 对象 | 行为 | 证据 |
| --- | --- | --- |
| 磁盘重建 | 克隆基准磁盘到目标私有 staging，按 VM page 单元写入差异、对完整零单元打洞；保留目标逻辑大小，验证后发布 | `VPhoneDiskRebase.swift`；APFS 稀疏文件、增长/缩短、部分尾块及物理共享回归 |
| 新增/已有共享 | 通过两份原磁盘的 `F_LOG2PHYS_EXT` 映射区分已有共享；相同逻辑字节不直接计为新增收益 | 已共享克隆报告新增量为0；独立写入文件、目标空洞及 physical run 交集测试 |
| 准入 | 两台 VM 按目录路径排序取得排他 flock，持续至结束；检查状态文件占用、同 inode、自引用、普通单链接文件、压缩/占位标志、同设备及 APFS | 双机写入锁拒绝、普通读者占用、别名、硬链接、路径检查；真实跨卷/非 APFS 未实测 |
| 发布检查 | 限制每次写入后保留4 GiB空间；稀疏区间逐字节比较后，再对原件/候选计算完整 SHA-256；摘要后重新检查两台 VM 占用与磁盘状态 | 低空间、坏候选、目标/基准漂移、取消拒绝；小文件与64 MiB稀疏文件测试 |
| 事务与恢复 | 发布前保存 `RebaseJournal.json`；`RENAME_SWAP` 后原盘暂留在 staging。两份文件身份/摘要复核后移除等价旧副本，将 journal 归档至 `.disk-rebase-history` | 交换后注入中断、交换前 verified journal、保留副本篡改拒绝及恢复后的目录锁释放 |
| 恢复门控 | Swift锁、BundleGuard及Python `vm_lock.py` 拒绝带 pending journal 的目标；只有 Swift `vm rebase --recover` 取得恢复入口 | Swift boot/config/CFW/snapshot拒绝；Python boot/CFW/固件/导出和继承描述符拒绝 |
| 身份与来源 | SEPStorage、NVRAM、config、launchpad.json及固件元数据不改写。替换磁盘产生新 inode，旧来源资格继续拒绝 | 元数据逐字节保持；实际 `FirmwareDesiredPlanStore` 在rebase前ready、之后返回identityMismatch，desired文件字节保持 |
| 归档/克隆 | 排除 `.rebase-*` 暂存和 `.disk-rebase-history`，不传播本地维护事务 | 导出排除回归和扩展Core/Kit验证 |
| 物理计量 | `SEEK_DATA/SEEK_HOLE` 跳过空洞，`F_LOG2PHYS_EXT` 获取设备物理区间；按设备、按VM目录合并并扫描独占区间 | 区间重叠、同一owner重复、跨设备数字相同及真实APFS克隆回归 |
| 计量访问 | 每30秒尝试一轮，15秒预算；只对元数据变化的文件重映射。映射前复查Launchpad状态和lsof，映射期间持共享目录锁，阻止遵守同一flock协议的启动/写入 | 缓存不重复打开、临时拒绝保持缓存、排他锁/pending事务拒绝、最后时刻拒绝不调用mapper |
| 未知计量 | 任一目录物理归属不完整时，不报告整组独占量；忙碌缓存、超时、不支持映射、目录缺失/不可读保持Unknown，符号链接不跟随 | `DiskUsageTests`；检查器Allocated/Exclusive/Unknown及缓存提示，英/中目录检查 |

计量共享锁不写运行记录，只在变化文件映射期间短暂持有。运行状态轮询仍不探测锁。普通外部程序可以不遵守flock；占用复查无法为此类程序提供原子文件系统快照保证。

`newlySharedBytes` 表示重建可共享的逻辑单元。APFS快照、其他克隆或未纳入计量的目录可能保留旧物理块，不能据此保证立即释放相同数量的卷空间。计量中的“独占”只相对于本次测量目录；不使用 APFS private-size 作为全部目录的共享证明。

## 验证结果

| 实验设置 | 结果 | 日志 |
| --- | --- | --- |
| 初始上游算法移植 | rebase16项通过 | `swift-core-initial.log.gz` |
| 扩展Core/Kit及相邻功能 | Core XCTest93项及Swift Testing498项（跳过1）、Kit244项（跳过11）、相关CLI4项、来源19项通过，退出0 | `swift-expanded.log.gz` |
| 最后源码收尾 | Kit245项（跳过11）、相关Core48项、CLI2项、来源19项通过，退出0 | `swift-closeout.log.gz` |
| 最终专门回归 | rebase22项、计量6项、CLI2项；来源19项包含rebase inode验证 | `swift-file-errors-final.log.gz`、`swift-closeout.log.gz` |
| CLI最终范围检查 | 2项通过；拒绝路径形式VM名及指向其他library的别名，既有合法命令仍执行 | `swift-cli-paths-final.log.gz` |
| Python标准入口 | 958项，跳过4项，4项失败；失败为3项历史边界断言和1项本地化目录检查 | `python-full.log.gz` |
| Python受影响模块复验 | 边界/本地化38项全部通过，退出0；原4项失败已解决，未重复其余全量用例 | `python-boundaries-final.log.gz` |
| Python锁专项 | 9项通过，含pending rebase和继承描述符门控 | `python-lock.log.gz` |

分组有重复，不将测试数量相加。Swift Kit跳过具名CLI/smoke/父进程场景；Core跳过实际资源复制构建场景。Python跳过4项，涉及缺失的固定依赖checkout等条件，具体原因保留于原日志。没有用这些跳过项建立运行验收结论。

完整Python暴露的3项历史边界失败涉及T47快照参数、T52绑定/更新调用及纯Swift `bind` 闭包与socket函数同名。修订保留全局禁止项，只按文件允许具体字符串/调用，并为快照、克隆参数转发及绑定命令保留精确断言。T51仅允许 `withMeasurementLock`，其他BundleGuard/VM锁、进程、安装和控制socket调用仍拒绝。本地化目录补入实际使用的6个键，未改动检查器的完整性和占位符断言。

主要命令：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache" SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache" swift test --disable-sandbox --filter 'VPhoneCoreTests|VPhoneLaunchpadKitTests|VMRebaseCLITests|FirmwareDesiredPlanStoreTests|VMSnapshotAndCloneCLITests'
CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache" SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache" swift test --disable-sandbox --skip-build --filter 'VPhoneLaunchpadKitTests|DiskRebaseTests|FirmwareDesiredPlanStoreTests|VMRebaseCLITests|VMOperationTests|VMLockTests|BundleGuardTests'
.venv/bin/python3 -B scripts/run_tests.py python
PYTHONPATH=tests .venv/bin/python3 -B -m unittest test_launchpad_bundle test_launchpad_strings -v
.venv/bin/python3 -B -m unittest discover -s tests -p 'test_vm_lock.py' -v
.venv/bin/python3 -B scripts/check_launchpad_strings.py
```

Swift和需要进程/原生磁盘操作的Python测试在沙箱外运行；数据均为隔离临时文件，不调用真实VM。所有断言保留为仓库回归测试。

## 未完成范围

- `--onto`模板标识符及同模板Build提示等待T49，不自动引入模板或改变默认创建行为。
- 未对真实64 GiB恢复VM执行rebase后启动，未执行真实APFS系统快照保留/释放空间或实际外置卷、跨卷、非APFS及外置盘故障验收。
- 未执行完整SIGKILL/断电矩阵；本轮恢复证据来自持久journal与故障注入，覆盖交换前verified、交换后中断及保留副本篡改。移除旧副本后的归档失败等剩余中断位置需另验。
- 没有测试签名安装后的Launchpad界面及运行期计量，也没有重新打包冻结应用。UI源码编译和Kit回归不替代视觉/真实操作验收。
- 完整摘要与恢复复查增加I/O；未测量真实大盘耗时。旧inode绑定保持无资格，用户在真实VM执行前须考虑后续固件预检/来源流程。
- 本轮没有新增固件补丁，历史`status`、`target_review`、依赖和其他任务记录保持。未提交或推送。

证据：[`evidence/T51-20261021/manifest.json`](evidence/T51-20261021/manifest.json)。
