# B39 / T24：实际运行验证方案

状态：候选、安装输入和离线回归已准备；以下系统修改、源维护和定位授权尚未执行，须获得本轮明确批准。

## 工件与对象

- 开发 worktree：`/Users/kolar/.codex/worktrees/t08-roothide/vphone-cli`；主 checkout 保持 `codex/handoff-20261001`。
- 直接 CLI：`.build/vphone-cli.app/Contents/MacOS/vphone-cli`。
- Launchpad：`.build/vphone-launchpad.app`；其内嵌 CLI/VM 摘要与直接候选相同。
- VM CDHash：`26a49260cdfea504e17202693802cd6c3a3574c6`；SHA-256：`75229dd9e23dd3d5acdef50a162011f61d7c21888b5625f285badf27e62f2e52`。
- 归档：`/Users/kolar/.codex/worktrees/t08-roothide/vphone-cli/.build/research-b39/2.6.1-local.f183c705c87b.tar`；SHA-256：`3bae87c809c93e3868a0a77c3bc00a5c1bc3a789fc3292487bfd8da3f22d6552`。
- 目标：`/Library/Application Support/vphone-launchpad/Bundles/2.6.1-local.f183c705c87b`。`2.6.1-local.f183c705c87b` 是本轮研究打包标识；`2.6.1` 不构成上游发布版本声明。仅打包副本的 Info.plist 短版本和 package type 改为 `2.6.1`/`BNDL` 并重签外层；VM 字节保持一致。
- VM 仅用 `/Users/kolar/github/vphone-cli/vm-roothide-b33-20261010`。不替换客户机载荷，不进行 RootHide 迁移，不改内核。
- 源仅 `/Users/kolar/github/vphone-cli/vm-new`。只读核对时源 PID71457、精确健康监测 PID72155、health=healthy；执行前重新核对身份，禁止依赖旧 PID。
- 系统 `amfid` PID6968，flags `4804` 含 SDK `P_TRACED=0x800`，父 debugserver PID38530；已有 amfidont PID38515。其 argv 保存于 `preflight-state.json`。并行附加不可行；不擅自停止该会话。

## 需要批准的动作

1. 用冻结 CLI 的 `core-bundle install --version 2.6.1-local.f183c705c87b --archive <上述归档> --sha256 3bae87c809c93e3868a0a77c3bc00a5c1bc3a789fc3292487bfd8da3f22d6552`，以管理员身份创建上述唯一 root-owned store 版本。目标 store 当前不存在。执行后普通用户 `core-bundle verify` 及精确 launcher 验证；禁止 0777、覆盖现有版本或新增任意执行 verb。
2. 研究副本首次绑定前用现有 `vm bind-core-bundle --backup <worktree>/.build/research-b39/research-binding-backup` 保存完整冷态备份。以正常接口绑定本轮版本；结束恢复原先不存在的 `launchpad.json` 状态，仅删除本轮新增绑定文件。保留研究副本及完整备份。绑定不会更新 guest/kernel/bootChain 来源。
3. 按源维护方案临时 SIGSTOP 精确匹配 vm-new/vphone.sock 的监测进程；正常 SIGINT 源并等待磁盘句柄释放；研究结束按捕获的原 argv 恢复源，再 SIGCONT 同一监测进程并核对新 healthy 采样。源自动重启、监测身份变化或被意外恢复时暂停实验，不重复停源。其他 VM 与监测不操作。
4. 若获准暂时让已有 amfidont 正常退出，先重新核对 PID38515 的完整 argv 和父子链，再发送 SIGINT，等待它与其 debugserver 退出及 amfid 解除 traced 状态。无法正常退出时停止，不强杀 amfid/debugserver。随后才可执行本轮 `scoped_amfi.py --run`，仅 CDHash `26a49260cdfea504e17202693802cd6c3a3574c6`，`paths=[]`、`allow_all=false`、`spoof_apple=true`，固定空持久配置读取；结束删除本轮断点并 detach，核对清理，再按已捕获的原 argv 与现有持久配置重启原会话并核对身份。该临时替换期间，其他工件的新启动可能受限；不修改持久允许列表、SIP 或系统启动配置。
5. 正常打开候选 GUI 会写入 `~/Library/Logs/vphone-cli-launchpad` 的本轮运行日志，并使用应用的参数域选择库；不持久改变已添加库列表。允许实际定位请求出现提示时，授权本轮已冻结 CLI/VM 或 Launchpad 应用。提示归属其他应用时先记录并暂停该授权动作；不 reset TCC、不直接修改 TCC 数据库。结束仅清理本轮新建运行日志，保留原有日志与应用设置。报告仅保留脱敏身份/授权状态/样本标记。
6. 结束正常停止研究 VM，恢复源和原 AMFI 会话；核对后仅清理本轮新建的系统版本与空 store 目录/锁文件。出现其他安装或锁占用时保留目录并报告，不扩大删除范围。

你在本会话提供的执行约定第4条要求：“删除数据、强制推送（force push）或修改当前仓库以外的内容之前，停止并请求确认。”旧 T08 已结束运行的批准不自动授权本轮新 store、新 CDHash 或已有其他 AMFI 会话的替换。

## 验证顺序与证据

1. 重新校验冻结签名、摘要、guest cohort 与 Package.resolved；先确保 VM --help 能执行。当前 --help 退出 -9；查询的5分钟日志未得到本候选精确路径的 AMFI 错误，终止原因未查明。
2. 在源停机且研究副本未绑定时，直接已签名 CLI `boot --config <副本/config.plist> --variant jb --no-vphoned-update`。不加 headless/dfu/no-vphoned。记录 PID 从 CLI exec 为配对 VM 的路径及签名身份。
3. GUI 启动完成、guest location capability 可用后，操作 `Location > Sync Host Location`；记录请求调用、授权状态和样本标记；请求没有提示也须记录实际状态。失败边界明确保留，不从菜单点击或 started host location tracking 推定已授权。
4. 研究 VM 正常停机后才安装/绑定、运行第二条路线。设置 `VPHONE_LIBRARY_ROOT=/Users/kolar/github/vphone-cli`，只选择研究副本；Launchpad 实际 GUI → 签名 launcher → 冻结内嵌 CLI wrapper → 可信 store VM。检查完整 PID/路径及绑定 SHA；bound 路线自动传 no-vphoned-update。不要把直接运行 launcher 的命令冒充 GUI 路线。
5. 两条路线分别采集 requesting/accessing/responsible 身份字段；必要时管理员只读 `launchctl procinfo <本轮PID>`。TCC 日志通过 `attribution_filter.py tcc --identities attribution-allowlist.json` 在报告保存前过滤；VM输出通过其 vm 模式保存样本标记。字段为 private 或未匹配冻结身份时保持未确认，不由父 PID 或 actor 名称推定责任归属。
6. 第二条路线同样调用宿主定位，保存实际负责应用、usage description、entitlement、签名与回调证据。权限状态或责任身份未能观察完整时，T24保持待验；已授权状态不能替代首次提示/拒绝矩阵。
7. 持续监测磁盘与源状态。低于5 GiB立即停止研究操作，正常关闭本轮研究 VM与本轮临时会话，进行必要恢复；不继续安装、复制或构建。

## 已完成的独立验证

52项定向 Swift 回归通过，涵盖 store/policy/调用方 route/frozen selection/toolchain；6项新布局回归含未知协议、旧布局缺 escalator、错误主程序、已签资源篡改及0777目录拒绝。实际冻结宿主归档在 private testRoot安装和复验通过；此结果不证明 root-owned系统store或跨UID运行。4项脱敏回归通过。CLI签名资源解析在仓库外工作目录和符号链接入口通过。宿主7个Mach-O、Launchpad外层2个Mach-O及嵌入7个Mach-O校验通过。

外部 Python 3.14.5 环境的版本锁及能力探针通过。Python解释器/framework/site-packages、managed venv及其原生依赖、PATH选出的bootstrap Python和现场clang编译不属于上述宿主Mach-O封装校验；字节闭包尚未建立，继续在T40记录，不将版本锁探针等同于封装完整性。
