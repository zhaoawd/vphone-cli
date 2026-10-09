# T40 B25 创建资源副本增量

## 范围与证据

工作树：`/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli`。基线 HEAD `2b6c28f7`。B24 创建实现晚于静态证据冻结 `11064b07`，相关实现为 `a45c9191`。固定上游为 `2d21d21fbdd4f51f013616273ceda9b35a3e0789`。

B24 创建阶段边界只比较 CLI/VM 内容摘要。资源实际解析链为 `VPhoneResources.resolve → Contents/Resources 或开发资源根目录 → scripts、辅助脚本、patchers、lib、resources 归档、.tools/bin、guest payload、guest-components stage`。固件事务及 less 文件系统补丁器在进程内自行调用 `resolve()`。

Python 使用 `VPHONE_PYTHON`、开发 venv 或 managed venv。本地开发 venv 指向 generation，其解释器依赖 Homebrew Python.framework。CFW driver 将 Homebrew 加入 PATH，JB 调用 xcrun/clang。

## 实现

每个 attempt 使用一份独占内容副本。开发布局仅复制 CLI/VM、其同目录 dylib/bundle、scripts、dependencies、requirements、debs.list、README 固件选择输入、.tools/bin、apfs helper、guest 和 guest-components stage。安装布局复制 `Contents`，包括 Info.plist、签名目录、Resources 和 Frameworks。不会遍历开发根目录的整个 .build。源节点名称或链接解析后的目标名称为 Disk.img 时拒绝，覆盖递归目录和链接链。

复制解引用链接，拒绝目录循环和特殊节点。文件通过 O_NOFOLLOW 描述符读取，比较前后 dev、inode、mode、size、mtime 与 SHA-256；复制后重新检查来源内容。ctime、owner、ACL、xattr 和触碰历史未冻结。移除 ctime 比较降低了对检查间修改后恢复的瞬时 ABA 变化的检测强度；本轮承诺为实际复制内容及 rwx 权限，未承诺检测全部来源触碰。相对路径、节点类型、权限、文件大小和 SHA-256 进入聚合内容摘要。目录中的 .git、__pycache__ 和 .pyc 不复制。

`VPhoneCreateRunner`、executor、verifier 和 prober 共用副本。内部资源解析使用 TaskLocal 作用域，显式 executablePath 解析保留原含义。Python 候选保留原 venv generation 路径解释；解释器及包内容没有冻结。创建期间禁止 Python 写字节码。CFW 的 guest-components 参数固定为副本路径。

创建在分配新 VM 磁盘前生成副本并检查容量。副本最多 8 份、合计不超过 2 GiB，并要求 64 MiB 可用空间余量。复制循环在每次写入前检查登记文件大小的剩余量和本次副本的剩余总预算；来源增长时拒绝当前块，不先写入越界数据。超限拒绝新副本，不自动删除既有失败证据。每个已接受 attempt 在 `.create-checkpoint/attempts/<attempt>-toolchain.json` 保存 manifest，每个实际执行阶段记录副本摘要、路径及 closure_limits。正常返回后释放副本；已开始且失败或中断的 attempt 保留副本。临时存储可能被操作系统清理，因此未承诺跨重启保留二进制副本。

每次 resume 重新生成完整副本，并比较完整内容摘要。变化未经确认则运行前拒绝；`--accept-tool-change` 接受完整新副本。已完成并跳过的阶段保留原 evidence，先前 checkpoint 仍按既有机制归档。跨 attempt 比较内容，不承诺物理同一目录。

## 未完成

Python interpreter/framework/第三方包及其原生依赖，外部 PATH 工具，宿主 SDK/编译器和 JB 现场编译，Virtualization framework ROM，VM 已有 cfw_input/cfw_jb_input、固件和可变缓存没有形成不可变闭包。新机可信 store binding 未发布。本轮资源副本不构成可信 Bundle receipt。T40 不能整项验收。

## 验证与限制

RED：4 项可编译生产连接测试确认原路径替换、资源摘要遗漏、链接与缺资源处理的缺口；另有 Disk.img 拒绝测试的行为 RED。TaskLocal 新 API 的初始编译失败另存 scope-red.log，不计作行为 RED。

受影响 suite 覆盖资源复制、实际脚本可执行文件、链接、容量和配额、只读目录清理、失败保留、末阶段副本变化、resume 确认与历史来源、内部解析作用域、创建 checkpoint、native prepare 和真实 CLI 取消测试。取消测试仅运行 prepare 替身，没有启动 VM。

审查修复后的实际开发构建副本只读探针：252 条目、181,699,541 字节，包含 debs.list，CLI resources=0，VM --help=0，外部 Python locked probe=true。实际签名 App 副本：156,051,358 字节，CLI resources=0，codesign --verify --strict=0。原 App 和副本的 VM --help 均退出码 9；独立原件探针显示 SIGKILL，原因未查明。该结果不证明 App VM 可执行，更不证明创建、恢复或启动成功。

## 独立审查后的修复

B25-R1：开发布局补充 debs.list。测试确认复制内容、聚合摘要变化，以及未确认变化的 resume 拒绝并保留原 checkpoint。

B25-R2：Disk.img 排除同时检查源名称和链接解析目标名称。1–3 层链接测试的中间节点放在资源树外，确保实际从资源树中的链尾完成解析。

B25-R3：源文件在复制前 fstat 后追加 64 KiB 时，0 字节和 1 MiB + 7 字节两种预检输入的目标 inode 实际写入量均不超过预检大小。测试持有目标 inode，在失败副本清理后继续检查实际写入量。生产默认没有测试同步回调。

相关 suite 初次运行因取消 fixture 的 requirements.txt ctime 变化失败。独立运行复现相同现象。revision 诊断显示 dev、inode、mode、size、mtime 相同，仅 ctime 变化。15 秒只读 fs_usage 记录 QzhddrSrv 在 inventory 和 copy 之间成功 setxattr；具体属性名未记录。顶层日志只保留本轮 fixture 行，原始记录位于 raw-unfiltered 子目录，过滤规则和原始 SHA 见 review-fs-usage-collection.json。

fixture 预读与有界等待未解决现象，该测试准备变更已撤销。经父任务与 reviewer 核对实际 manifest 合同后，仅移除 ctime 比较，其余一致性检查保留。afterInventory 和 beforeCopy 两时点的确定性 xattr-only 用例均观察到 RED，修复后成功且聚合 SHA 不变。同长度内容改写并恢复 mtime、来源增长、链接重定向到不同内容的拒绝测试仍通过。没有停止安全软件或修改其配置。

最终验证：review-related-final.log 为 143 项测试 / 9 个 suites 通过，退出码 0。定向验证 review-xattr-green.log 为 15 项 / 2 个 suites 通过。SwiftPM 槽位已归还父任务；后续未改生产或测试源码。
