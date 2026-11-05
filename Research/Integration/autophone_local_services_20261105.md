# 本机 autophone 服务部署

日期：2026-11-05。用户在完成基础 VM 后要求继续下一步。本轮只操作 `autophone-a`，部署 bootstrap、SSH/Frida，并接入隔离 Control Plane。

## 实验设置

- VM 与固定 Bundle 沿用 [基础 VM 记录](autophone_local_20261105.md)。UDID 为 `0000FE01-D66A77D90F264B25`。
- autophone 现有端点合同使用 `/var/jb`，因此选择 rootless。没有调整宿主或 guest daemon 二进制。
- Irisin 固定为官方 `v5.1.6` 的 `iphoneos-arm64` 包，SHA-256 为 `db8ce306118e9e568631ba37b4dfc470332e07ff5574860ce34fa49938e0597f`。
- Frida host/server 固定为 17.16.1，沿用官方包的未修改 payload，server/agent 摘要与 autophone 已有清单一致。
- SSH 使用 autophone 已有 rootless Dropbear 2020.81 构建入口、信号启动器和密码库自检。固定来源及输入摘要来自已有 SSH 验证记录。本机 SDK 构建产生的新摘要单独记录，不冒用其他宿主的产物摘要。
- 专用 target：generation 1；宿主 SSH `127.0.0.1:22251`，Frida `127.0.0.1:37051`，guest Frida 27042。
- 专用 PostgreSQL 数据目录位于本任务 `.build/.../services/control/postgres`；只监听 `/private/tmp/ap-local-cp-20261105` 的 Unix socket，端口 55451。数据库 `autophone_local_20261105`，未连接日常控制面数据库。
- 隔离 Control Plane 监听 `127.0.0.1:18151`。

## 已验证与保留的失败

1. Irisin 安装、应用注册和 daemon 启动通过。
2. 默认 `bootstrap.packages` 刷新 BigBoss 时失败；当时 dpkg 只有 firmware 虚拟包，尚未写入基础包。显式选择 Procursus 与 OwnGoal 后，仓库刷新和依赖解析通过。
3. 长 `script.eval` 请求连接关闭，没有取得最终结果。独立回读的 dpkg 状态保持原字节，无残留安装进程。改用本任务一次性 launchd 作业运行官方 CLI，保留 stdout/stderr 和独立退出状态。
4. 显式仓库的完整 dry-run 退出码 0，日志为 completed。
5. 首轮实际安装使用 Procursus 3000，在 openssh-server.extrainst_ 处失败：launchctl 1:1.1.1 强引用 guest 缺失的 `_launch_active_user_switch`，dyld 中止，脚本退出 134。没有忽略脚本错误或改写 dpkg 状态。
6. 官方 Procursus 1800 的 launchctl 1:1.2.0 摘要为 `1ba223fed06d40d58e6d944e566519ee43d59af7d704fe2f9722d3e27cb428d3`。其同名符号为 weak reference；在相同 guest 暂存目录执行只读 help 退出 0。
7. 按首次安装失败的恢复流程卸载本轮失败的 `/var/jb`，重装相同 Irisin。原暂存安装包不可读的失败同样保留；重传后，重装结果独立校验通过。Procursus 1800 + OwnGoal、固定 `launchctl=1:1.2.0` 的第二轮实际首次安装退出 0。独立回读确认 89 个包全部为 `install ok installed`，一次性安装作业已卸载并移除。
8. 密码库首次构建误用了历史早期配方，因缺少 LTC_SOURCE 失败；改用仓库保留的 r2 配方后，LibTomMath/LibTomCrypt 和 rootless Dropbear 构建通过。旧证据未修改。
9. 八文件端点清单已部署：官方 Frida server/agent、Dropbear/dropbearkey、LibTomMath/LibTomCrypt、密码库自检程序和信号启动器。清单逐文件核对路径、大小与 SHA-256；密码库正向自检确认 math、ECC、23 个 cipher、29 个 hash、6 个 PRNG，跳过项为 0。bootstrap 安装的 OpenSSH 已禁用并卸载其服务，端点由 Dropbear 提供。
10. 首轮端点准备成功，但随后的 SSH 挑战退出 255，stdout/stderr 为空，原因未查明。独立严格主机公钥检查通过；随后只读 root 登录控制试验退出 0。保留该失败，再用已运行服务的公钥验证模式执行完整检查，六项检查均通过。
11. autophone 的进程表解析把含空格的 Launchpad Bundle 路径拆成多个参数，导致实际运行的 VM 被判为不存在。独立工作树修复复用 `process_arguments` 读取内核 argv，保留目标配置路径和父 PID 归属检查；新增含空格路径、参数中的伪 VM 名称及进程已退出三项回归检查。修复前确认回归失败，修复后 81 项相关测试、Ruff 与 diff 检查通过。修复保存在本地分支 `fix/launchpad-process-paths`，提交 `75ac65bb3d4701ed535ef0a8302a9f4c9ceb22d1`，修复完成时尚未合入或推送，后续推送范围见本文末节。
12. 服务部署后通过 Launchpad 正常停止并启动 VM，vphoned 19 秒后响应。启动 UUID 从 `E7B02A74-C24A-493E-B8AD-61EBE32D47B9` 变为 `15CB48BC-70D0-4D50-A59F-ED5195DAEC5F`。按既有准备流程重新启动 Dropbear/Frida 后，完整端点验证再次通过；本轮没有配置 guest 服务开机自启。
13. 两次完整端点验证均核对 root/mobile 的主机公钥、UID、启动 UUID 和随机挑战，Frida 17.16.1 的 UDID、进程枚举及 native agent 身份，以及 guest DNS/TLS/HTTPS 响应。`https://example.com/` 返回 200；vphoned 的 PID 和二进制摘要在每轮检查前后不变。SSH 与 Frida 的宿主监听器均绑定 loopback，冷启动后归属目标 VM PID 95231。
14. 隔离 Control Plane 与 Rig Agent 均从上述干净修复提交启动，源码摘要同为 `960b0109ee94d9697abcbe9c56d742c42eef7ca05b48014fe7d7c4dd605580bb`。数据库实查为 `autophone_local_20261105`、用户 `qcz3840`、Unix socket、端口 55451。现有 executor 与 device_session provider 各有一个。
15. `autophone-a` generation 1 注册为 `online`，Agent 已连接；注册能力为 `vm_uds`、`app_install`、`frida`。Host 的 `max_active_rigs=1`，没有调整为双 VM 并发。能力注册不替代业务 IPA 安装验证。
16. 针对该 socket 的既有健康守护持续读取 UDS 和 guest 通信，收尾时已完成 102 次探测，当前状态为 `healthy`。Control Plane 设备交互通道返回 `online=true`；预览帧首次为熄屏画面。随后在控制台 ScreenLock 会话内执行两次 Home，已查看回传画面并确认主屏幕可见。会话以 `closed` 结束、`error_reason=null`；结束后锁未持有，数据库预留状态为 `released`。

## 当前入口与运行范围

运行源码位于 `/Users/qcz3840/.codex/worktrees/launchpad-process-paths/autophone`。原 autophone 工作区中的四项未提交文档修改未被覆盖。该修复工作树正在被 Control Plane、Agent 和健康守护使用，暂时保留。

本任务环境入口为 `.build/autophone-local-20261105/services/runtime/session.env`。在 zsh 中加载后进入 `$AUTOPHONE_SOURCE_DIR`，可用现有 CLI 查询本 Rig：

```zsh
source /Users/qcz3840/github/vphone-cli/.build/autophone-local-20261105/services/runtime/session.env
cd "$AUTOPHONE_SOURCE_DIR"
"$AUTOPHONE_CONTROL_PY" -m autophone.cli control rig list
```

`runtime/control-plane.env` 只在在线、源码身份和交互检查通过后写入；已有控制面配置后连接失败按项目规则拒绝执行。该环境入口和 target 用于隔离本任务状态，不能省略后改用默认 `vm-2607` 或日常数据库。Control Plane、PostgreSQL 和 Agent 是本机当前会话的进程，本轮没有安装宿主开机服务。

冷启动验证使用的固定输入清单及日志保留在证据目录。本轮独立 `tools.probes.upstream_endpoints` 检查发生在写入控制面回执之前：`--prepare-manifest` 用于没有端点进程的 guest，已运行服务使用 `--host-public-key` 验证模式。控制面配置后，独立探针会拒绝绕过控制面；后续设备执行应继续遵守控制面路由和 ScreenLock 约束。VM 停止和启动仍使用 Launchpad。

## 证据与剩余事项

本轮证据位于 `.build/autophone-local-20261105/services/`，包括 release 元数据、源码及依赖摘要、构建 receipt、包数据库快照、失败日志、dry-run/安装作业 plist 和 target。账户密码、私钥及密码摘要不进入研究文档。

关键证据包括：`dpkg-installed.txt`、`package-status-check.json`、`endpoint-manifest.json`、`endpoints-r3/result.json`、`endpoints-restart/result.json`、`control/health-fixed.json`、`control/rigs-online-final.json`、`control/host-online-final.json`、`control/device-status-final.json`、`control/console-verification.json`、`control/reservations-final.jsonl` 和 `deployment-result.json`。失败日志、初次安装日志与历史源码输入未覆盖。

服务部署阶段完成 bootstrap、SSH/Frida、冷启动检查和隔离 Control Plane 接入。后续 food_ordering_v2 精确安装、校准、菜品默认态 D0 与验收已完成，见下述业务与归档章节；定位、真实 QR、第二台独立身份 VM 及本机并发容量仍未验证。

## 后续业务验证（2026-11-05）

本机重建并精确安装 `food_ordering_v2` Build `bld-52086253…`，三次正式校准与菜品默认态 D0 均 passed。比较为 0 Finding、变化像素 0 / 2,638,237、required 覆盖 19/19。该阶段出口闸为 12/13；Before Snapshot 原图尚未满足 Git 可重放归档条件，`REQ-20261105-001` 保持 active，尚未验收。构建期间的健康超时、两项 guest 前置条件缺失和派生输入过程均保留，详见 [本机业务验证](autophone_local_business_20261105.md)。Rig 收尾为 online、health healthy、ScreenLock 已释放；Host 并发上限保持 1。

## 归档与验收完成（2026-11-05）

后续已完成本机独立证据归档；原始 local_only、AI 和外发规则保持不变，归档仓库未配置远端或发布。原状态目录、独立检出和无控制面配置的独立检出均通过 13/13；正式 accept 将 `REQ-20261105-001` 收为 accepted，验收后新检出复算同样通过。证据快照提交为 `ec27d174ee8aea53026503f48c56183de73f9a00`，67 个冻结文件摘要不变，仅 Requirement 当前态和账本按正式入口更新。完整过程见 [本机业务验证](autophone_local_business_20261105.md)。VM 当前 online、health healthy、ScreenLock 空闲；第二台 VM 和并发容量仍未验证。

## IPA 验证与旧 VM 替换评估（2026-11-05）

新增验证七个本机 IPA，安装及身份回读均通过。最近一轮两次冷启动即时校验通过五款；肯德基 Prod 和飞书仍有安装后第一次即时校验失败，后续约 14 秒的前台采样均通过；企业微信首轮同类异常保留，复测两次通过。靶 A 补入既有 baseline selection 后显示首页且选择回执一致。未执行登录和商业业务流程，尚未替换 vm-2607。详细版本、原始结果、证据与替换条件见 [IPA 兼容性验证](autophone_ipa_compatibility_20261105.md)。

验证后已恢复默认 Agent 及原已验收 food_ordering_v2 Build 的 Provisioning 观测；Rig online、health healthy、ScreenLock 空闲，Host 并发上限仍为 1。旧 VM 未启动，四个小文件的哈希及元数据和 Disk.img 元数据未变化；69 个受保护业务证据文件与 accepted 提交一致。

## 启动就绪校验修复（2026-11-05 17:42）

已在 autophone 本地提交 `b15fb6cfdd7e1b7282a87a887dd72f056c53ee14` 修复已复现的前台确认延迟：只发一次启动，在同一绝对截止时间内确认同 Bundle ID、原 PID 和已验证前台。最终版本下肯德基 Prod、飞书、企业微信六次启动均通过；肯德基 Prod 再次产生 pending 返回并由独立回读确认。飞书、企业微信历史失败原因未独立确认。278 项相关隔离检查及 Ruff 通过，详情见 [启动就绪校验修复](autophone_launch_readiness_20261105.md)。

标准 Agent 和原已验收 food_ordering_v2 Build 的安装事实已恢复；控制面与 Agent 源码身份一致、Rig 健康且空闲。旧 VM、69 个受保护业务证据文件保持不变。该节记录修复验证完成时的状态，当时尚未推送、合入、发布或替换 vm-2607；后续推送见下一节，账号、数据和关键业务用例仍需验证。

## 本次提交与推送范围（2026-11-05）

autophone 两个修复提交 `75ac65bb3d4701ed535ef0a8302a9f4c9ceb22d1`、`b15fb6cfdd7e1b7282a87a887dd72f056c53ee14` 已推送到 `fix/launchpad-process-paths`，尚未合入 main。推送前在同一最终提交上复核 301 项相关隔离测试，Ruff 和 diff 检查通过。

vphone-cli 的本次文档使用独立分支 `codex/autophone-local-validation`，基于 origin/main，只包含五份 autophone 记录和补丁总览的本次补记；原工作区的 Duo 集成提交及其他未跟踪内容不在该分支内。VM、IPA、原始日志、独立本机证据仓库、密码和私钥不随文档提交。本文中的设备状态取自相应验证阶段，本次提交操作不构成新的设备探测或业务验收。
