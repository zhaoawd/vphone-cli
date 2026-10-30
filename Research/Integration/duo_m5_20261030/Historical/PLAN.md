# vphone-cli 2.x × M5 × iPhone Duo：制作与升级方案 v1.4

**修订日期：2026-10-27（Asia/Tokyo）**  
**目标：实体 M5 Mac，iPhone19,4，iOS 27.1 / 24A94425。**  
**承接：v1.3；原始固件、旧 Bundle、旧 VM 和实验记录均保留。**  
**交付：更新后的实施方案及证据分级，不包含制作成功的虚拟机或已实现补丁。**  
**实测增补（2026-10-27 晚）：已在 M5 Pro 上完成 P1–P3（A 级系统来源 VM、X1 性能对照、I0/I1 安装与 food_ordering），结果见 §0.1 与 §13；C 级折叠仍未做。**  
**实测增补三（2026-10-29）：第二阶段改走 PR #728 的 guest 逻辑双显示（一个宿主输出），合入为本地分支 `duo-m5-v1.5`，新建 `duo-m5-fold728`；F0（显示模型）通过，同会话开合可用，开合黑帧已修复（26 次切换 0 黑帧）；F2 部分完成（输入跨开合保留；发现“带焦点输入框合拢后外屏空白”，模拟器对照待做）；F3、F4、F6 未做。见 §13.8。**

## 0. 本版结论

把 M5 路线明确写成：**CSSC 原生执行优先，arm64e.x1 使用经过审阅的非原生兼容路径；不能由 CSSC 通过推导 X1 原生通过。** Apple 当前文档把原生 arm64e.x1 的 Mac 支持范围列为 M6 及以后；LLVM 的 M5 定义包含 CSSC。两者是不同条件。[S1][S2]

上游其他机型指南说明，在不具备原生 X1 的宿主上，standard preset 对不支持的指令做 lowering（兼容转换），并指出这会削弱 PC 绑定的指针认证语义。[S3] 这项机制可作为 M5 方案的基础，但该指南中的已记录机型结果不是 Duo 24A94425 的成功证明。

本次还新增两个审查点：

- **Duo / PAC：** #751 的原始标题经索引转载，涉及 native-X1 宿主上的 bootstrap lowering 和 libmisfix trampoline 两类 EXC_ARM_PAC_FAIL 报告；尚未取得正文、完整环境和修复提交。它是具体审查线索，不是 M5 已复现故障或最新版已修复的证据。[L2]
- **固件封装：** 读取到转载的 2.13.1 上游 release 正文，明确提到 fw patch 封卷后 new.trustcache 自移动冲突。增加该阶段的检查，不把它当作 ISA 故障，不以删除 trustcache 绕过。[S4]

不改变的主干：先做单显示面的 Duo 系统来源 VM，再做开发测试；真实开合、内外显示和半折叠仍是独立交付。默认 PCC 路线 A 保持 23E5207q；Research Board 路线 B 仍要求确切 recipe 和独立验证，没有新证据就不换底座。

### 0.1 实测更新（2026-10-27，M5 Pro，P1–P3）

以下为本机实际运行结果，详细数据和日志位置见 §13 与 EXPERIMENT.json。它们修正了本版若干推测：

1. **版本：** 实时上游 latest 为 2.13.8（2026-10-26），main = `7d633c9a` = 2.13.8；不是索引中的 2.13.5。[G1]
2. **路线 A 可行：** 2.13.8 stock + standard preset + PCC 23E5207q，在 M5 Pro 上完成 prepare → patch → restore → cfw install，首启到 Setup Assistant，vphoned 应答，`device.info` 报 iPhone19,4 / 27.1。T0–T2 通过；封装阶段无 trustcache 自移动冲突。
3. **M5 的真正阻碍不是 CSSC，也不是 #751，而是 X1 按需处理的性能。** stock 2.13.8 只预先 lowering bootstrap（38 个映像），共享缓存中其余 X1 指令在运行时逐条陷入内核处理：launchd CPU 在 2,063 s 开机时间内累计 874 s 且持续上升，出现 MercuryPosterExtension 场景创建看门狗、Setup 场景更新超时 ×6、小组件空白、设置约 10 s 才绘制完成。
4. **上游 PR #728（草稿，head `b03f0b82`）解决了该问题：** 在同一 VM 的 APFS 克隆上 `cfw update-environment` 预先 lowering 整个 X1 共享缓存（4,508 映像、24,606,071 处改写），launchd CPU 在 1,218 s 时仅 11 s 且保持平稳，看门狗消失，设置 1 s 内绘制，VirtualAudio 补丁全部成功、audiomxd 单实例无崩溃。该 PR 未合并，采用它即属于“采用未发布源码”，需要单独记录。[G2]
5. **#751 不在 M5 复现：** 正文针对 native-X1 宿主（M6）；M5 上 `vp_probe_native_x1` 不成立，lowering 照常进行。I1（installd）安装后 5 分钟 installd 无崩溃、无 PAC 失败。#751 的规避办法（阻止 bootstrap lowering）**不得**用于 M5：P1 中 restore 后未 lowering 的系统首次启动即 launchd SIGILL panic。[G3]
6. **应用：** I0（vphoned）与 I1（installd）均通过；food_ordering（Expo 53，Xcode 27.1 / iOS 27.1 SDK 构建）需要采用 UIScene 生命周期，否则 iOS 27 UIKit 在启动时主动陷入。这是应用侧问题，不是 Duo 或 VM 问题。

## 1. 这次实际取得了哪些资料

### 1.1 证据分级

| 内容 | 取得方式 | 可以采用 | 不能据此宣布 |
|---|---|---|---|
| M5 的 CSSC | LLVM 原始 PR／代码定义 | 编译目标的特性基线 | 目标 Mac 和 guest 已实测 |
| 原生 X1 的支持范围 | Apple 官方文档 | M5 不作为原生 X1 目标；按兼容路径核对 | 报告中的 native-X1 宿主就是 M5 |
| 非原生 X1 lowering | 上游作者的机型指南镜像 | 现有兼容策略和安全语义边界 | Duo 的全部代码均正确转换 |
| 2.13.1 trustcache 修复 | RepoRadar 中的上游 release 原文区段 | 该故障与修复的说明 | 新版本完整 guest 测试已经完成 |
| 2.13.5 发布候选 | 第三方发布索引 | 索引显示 2026-10-26 的 2.13.5，值得优先核实 | 它已被本次官方 API 确认为最新，或包含 #751 修复 |
| #751 | GitHubHelp／Good First Issue 的原始标题与元数据 | 新增 PAC 专项审查 | 完整根因、当前实时状态或修复范围 |
| 实时源码 | 本轮 Git／API 访问未取得完整对象 | 如实保留空缺 | 已获取 HEAD、已审查全部 diff |

**2.13.5 目前是本次最新可见的发布线索，不是本次已认证的实时 latest。** 索引没有明确时区的发布时间，不擅自换算成日本时间。2.13.1 是本轮读取到具体上游发布说明的版本，不是推荐降级目标。最终选择目标 Mac 从官方入口实际取得、验签并锁定的同系列构建。[L1][S4]

> **实测更正：** 本机 `gh release list` 显示 2.13.8 为 Latest（2026-10-26T18:57Z），本地 main `7d633c9a` 即 2.13.8 标签。P1 用该源码自建 Bundle；P2/P3 另用 PR #728 head `b03f0b82`（基于 2.13.7，已含 2.13.8 的 #761、#762，只差版本号提交）自建 Bundle。两者的 vphone-vm cdhash 分别为 `531517b0…3f3c`、`775ec296…481c`。[G1][G2]

第三方页面同时存在明显过时或错误的安装摘要；本方案不采用其 npm 安装、旧版 -V jb、Homebrew/Python 依赖等指导。只使用明确标注的上游作者原文及可辨识元数据，版本发现不能替代代码验证。

本轮没有取得 2.13.2–2.13.5 的完整官方说明／diff，故不把有关 CSSC 模拟、Debug Session、脚本 API、磁盘最低值等二手报道写成当前可执行契约。它们列入待查项，不进入首次制作依赖。

### 1.2 与 v1.3 的关系

v1.3 已有同系列配套、VM 三层来源、环境／内核更新、自动 guest 同步和恢复阶段分流。本版不将这些再次说成新功能；只完善 ISA 决策、PAC 调查、封装错误定位和采用新构建的准入条件。

本版仍是**方案差异**，不是两个已知远端 SHA 的完整代码差异。用户未提供此前实际制作的源码 SHA、已运行 Bundle 或成功 VM，本方案默认仍走首次制作路径 F。

## 2. 固定输入、宿主与交付边界

### 2.1 固件输入

以下元数据沿用用户已给出的页面与截图，本轮未下载实物：[U1]

```text
ProductType: iPhone19,4
Version: 27.1
Build: 24A94425
Filename: iPhone19,4_27.1_24A94425_Restore.ipsw
Expected SHA-256:
58fbfda85615e90221136d55288f64c9f41386510f8cd77feb8c9d20cc0a782e
PCC 路线 A 候选: cloudOS 26.4 beta / 23E5207q
```

保留实际下载来源、完整字节数、哈希、清单、选中恢复身份和组件路径。页面签名标记不能替代恢复当次的票据结果。

路线 A 审查原生虚拟平台组件；路线 B 审查研究板、recipe、KDK／内核输入与生成目标。不可用 A 的 vphone600 原包存在性条件一律否定 B，也不可为通过旧工具伪造清单。旧审计工具本轮不修改。

### 2.2 交付与资源

| 级别 | 验收内容 |
|---|---|
| A：系统来源 VM | Duo 系统内容、恢复、CFW、界面、vphoned、基础 App |
| B：开发测试 VM | CPU／动态链接、显示／输入、网络、安装双路径、冷启动、回滚与导出 |
| C：Duo 行为 | guest 实际感知姿态和显示变化，窗口／场景／应用及输入同步 |

A/B 不能冒充 C；修改分辨率或设备名称不是折叠实现。

继续使用专用实验库与 APFS 工作卷。原方案约 200 GB 可用空间和 6 vCPU／8 GiB guest RAM／64 GB 虚拟盘是工程起步预算，不是已验证最低要求。不依据未核实的新版本报道调低磁盘门槛；每个特权阶段服从当前预检和实际峰值需求。

## 3. M5 的 ISA 策略从一般提醒变成明确分流

### 3.1 分开四个维度

| 维度 | M5 本轮策略 | 所需证据 |
|---|---|---|
| CSSC | 优先原生执行，不在首轮添加旧 Mac 指令模拟器 | 宿主查询＋实际指令探针；guest 另测 |
| 原生 arm64e.x1 | 不把 M5 当作 Apple 所列原生 X1 目标 | Apple 支持范围、实际检测逻辑和平台记录 |
| X1 lowering | 检查并保留当前上游适用的非原生兼容策略 | 实际作用目标、输入／输出 hash、补丁记录 |
| PAC／ABI 运行结果 | 不因代码转换完成就认定正确 | bootstrap、动态链接、系统服务和应用的运行证据 |

> **实测（M5 Pro，macOS 27.0.1 / 26A434）：** `hw.optional.arm.FEAT_CSSC=1`、`FEAT_PAuth2=1`、`FEAT_FPAC=1`、`FEAT_CPA=0`、`FEAT_PAuth_LR=0`。CSSC 原生可用（仅 sysctl 查询，未另跑指令探针）；kernelcache 仍装入了 standard preset 的 EL0 CSSC 模拟入口（`kernel-boot-cssc_emulation`，挂在未定义指令分流之前），原生执行时不会进入。X1 非原生：cfw install 对 launchd、dyld、fsck、mount 和 38 个 bootstrap 缓存映像做了 lowering（`pacibsppc→pacibsp`、`retabsppc→retab`、`addpt→add` 等），其余共享缓存靠内核按需处理（`kernel-boot-arm64e_x1`）。**按需处理在功能上正确，但在 M5 上开销过大**，见 §13.2；全缓存预先 lowering（PR #728）才可用于日常。
>
> 因此本节“X1 lowering”一行的所需证据应再加：**launchd／kernel_task CPU 随开机时间的曲线**和场景看门狗报告，而不仅是改写记录。

Apple 对 X1 返回地址保护的说明包括 PC 与 SP 的参与；这是理解签名／验证两端一致性和搬移代码风险的依据，不是 #751 的已证实根因。[S1] 不以更改 CPU subtype、伪造能力报告或将所有 PAC 指令无条件去掉作为兼容实现。

### 3.2 预检与探针

```bash
# 在目标 Mac 查询，不修改宿主配置。
uname -m
/usr/sbin/sysctl -n machdep.cpu.brand_string
if value=$(/usr/sbin/sysctl -n hw.optional.arm.FEAT_CSSC 2>/dev/null); then
  printf 'FEAT_CSSC=%s\n' "$value"
else
  printf 'FEAT_CSSC=unknown\n'
fi
```

查询结果和执行探针分别记录。缺键不是 0；Mach-O 含 arm64e slice 也不是原生 X1 证明。不编造一个“X1=true”的 sysctl 键或 vphone 开关。检查当前源码真正用什么条件分流，保留条件来源。

复用已有 CSSC 测试设计：W/X 宽度、UMIN/UMAX、CTZ(0)、边界和副作用。宿主和 iPhoneOS guest 分别构建。基础 guest 的成功只证明该虚拟配置的对应指令可执行，不能代替 Duo dyld 和全部服务验收。

### 3.3 源码审查项：一致而非一刀切

建议为每个目标写一行审阅记录：

```text
组件名 / 原始 hash / slice / 实际 X1 特性
宿主能力判定 / guest 有效能力 / 本组件所选兼容策略
补丁规则与适用范围 / 输出 hash / receipt / 首次执行结果
```

覆盖实际早期启动程序、dyld、共享缓存及会执行到的系统程序；不是要求所有映像逐字节采用同一改写，而是同一兼容策略下不能留下相互矛盾的调用、返回、签名和验证语义。已经由当前上游正确处理的目标不重复改写；无法证明适用的输入先停止。

对 M6 及以后原生 X1 宿主另建实验，不把其成功或失败外推到 M5，也不把 M5 的已转换成品自动当作原生 X1 测试样本。[S1][S3]

## 4. #751：具体线索、两类审查，不能当已知修复配方

本轮索引转载的原始标题为：

> iPhone Duo on a native-X1 host: two EXC_ARM_PAC_FAIL bugs (bootstrap lowering + libmisfix trampoline)

索引显示问题在 2026-10-25 创建，抓取时标记 open。没有取得完整正文、实际宿主型号、目标构建、堆栈、补丁或维护者结论；实时状态未知。[L2]

### 4.1 对 M5 的正确影响

标题说的是 native-X1 宿主，不等于 M5。M5 仍沿非原生 X1 兼容路线推进，不因为这个标题全盘取消 lowering，也不先换机器。

同时，它提示本项目必须审查两个共享环节：

| 环节 | 本方案要求检查 | 尚不能断言 |
|---|---|---|
| bootstrap／X1 转换 | 检测条件、转换目标、签名／返回验证是否成对，是否与其他系统映像保持适用关系 | 当前 main 一定存在同样错误或某版本已经修复 |
| libmisfix／trampoline | 实际载入版本、代码搬移与认证上下文、寄存器和控制流保持、原始与修改地址映射 | 两个问题都影响 M5，或仅更新该库即可解决 Duo |

> **实测更正（已取得 #751 正文，2026-10-27 仍 open）：** 两个 PAC 故障都只在 native-X1 宿主上出现，M5 上被掩盖，因为 `vp_probe_native_x1` 在 M5 上不成立，bootstrap 照常 lowering，libmisfix trampoline 也不经过会失败的认证路径。实测：P1／P2 两台 VM 均无 EXC_ARM_PAC_FAIL；P3 经 installd 安装两个应用后 installd pid 不变、5 分钟内无崩溃。**#751 中“阻止 bootstrap lowering”的规避不适用于 M5**：P1 的 DFU 会话中，restore 后未 lowering 的系统被启动，launchd 立即 SIGILL（`panic-full-2026-10-27-173630`，initproc namespace 2 subcode 4）。M5 上 §4.2 取证包仍保留，用于以后的回归。[G3]

这些是由线索引出的审查和实验设计，不是已完成根因分析。Apple 的指针认证资料说明，带地址判别信息的签名不能在改变位置后直接沿用；具体 trampoline 是否触发哪种认证仍需实际源码和故障现场证明。[S5]

### 4.2 建议的 PAC 取证包

发生故障时收集：系统／进程版本、异常类型及原始报告、PC/LR/SP、附近指令、寄存器、映像 UUID／基址、已加载库和哈希、补丁前后目标及 trampoline 范围、X1 决策和 guest 环境同步日志。

不只保存“可能 PAC 失败”这一行。Apple 指出其他高位地址损坏也可能显示类似现象，应结合异常上下文判断。[S1]

严格区分：

- 未定义指令／SIGILL：先核实实际 opcode、有效指令集及控制流。
- EXC_ARM_PAC_FAIL 或疑似 PAC：检查认证上下文和代码／指针变化，不一概归为缺 CSSC。
- TXM／签名准入拒绝：检查相应策略与实际补丁，不套用 PAC 诊断。
- 共享缓存映射失败：比较缓存布局和实际内核区域，不靠加 RAM 消除。

不要跳过认证检查、手改 receipt 或以旧 dyld 覆盖来制造“已开机”结果。

## 5. 2.13.1 的封装修复与版本采用方式

取得的上游发布原文说明：fw patch 在封卷后尝试将已位于 Firmware 中的 new.trustcache 移动到自身，在观察到的 macOS 27 环境被 FileManager 拒绝。2.13.1 修正该问题；说明还写明完成了 Debug Bundle 构建及该文件操作的隔离复现。[S4]

本项目据此新增：

1. 保存文件系统修改、seal 完成、trustcache 生成和 manifest 更新各自结果，不能只记录 fw patch 最后退出码。
2. 选择确实包含该修复或等价实现的实际源码／构建。版本号较大仅是线索，不能代替代码关系或资产核对。
3. 出现同名冲突时先确认源／目标是否同一文件及生成状态；不删除 trustcache 后跳过清单更新，不让错误输入继续恢复。
4. 在该阶段失败，尚不能证明 Duo 用户态或 X1 运行失败。先修宿主文件处理，再进入恢复。

该说明不是 M5＋Duo 的运行记录。2.13.1 也不是本版指定的“最终版”：官方入口若已提供更高同系列发布，应先核实新资产与需要的修复，再固定它。[S4]

仍采用同 major.minor 的 Launchpad／Core 配套原则。优先使用官方提供的公证 GUI；CI zip 是否公证与 Core 是否具备某个修复是两回事。[S6]

## 6. 获取真实基线及聚焦审查

### 6.1 新建独立工作区

下列 Bash 示例在目标 Mac 执行，本包只做语法检查，不执行下载或创建。目录已存在则退出。

```bash
set -euo pipefail
umask 077
export LAB="$HOME/vphone-duo-m5-v14"
export REPO="$LAB/src/vphone-cli"
mkdir -p "$LAB/src" "$LAB/evidence/source" "$LAB/ipsw" "$LAB/artifacts"
test ! -e "$REPO" || { echo '源码目录已存在，请使用新的实验目录。' >&2; exit 1; }
git clone --no-checkout https://github.com/Lakr233/vphone-cli.git "$REPO"
git -C "$REPO" fetch origin --tags
BASE="$(git -C "$REPO" rev-parse 'refs/remotes/origin/main^{commit}')"
git -C "$REPO" switch --detach "$BASE"
printf '%s\n' "$BASE" > "$LAB/evidence/source/full-sha.txt"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$LAB/evidence/source/fetched-at.txt"
git -C "$REPO" status --porcelain=v1 > "$LAB/evidence/source/worktree.txt"
git -C "$REPO" for-each-ref --format='%(refname:short) %(objectname)' refs/tags \
  > "$LAB/evidence/source/tags.txt"
git -C "$REPO" log -60 --date=iso-strict --format='%H %cI %s' \
  > "$LAB/evidence/source/history.txt"
```

main 不是 release 的同义词。若选择官方发布资产，应另存真实 tag 对象、完整源码 SHA、下载来源、哈希、签名和 Bundle 版本。不要猜标签前缀，不假定 2.13.5 与当天 main 相同。

### 6.2 只读定位

```bash
set -euo pipefail
: "${REPO:?}"
: "${LAB:?}"
git -C "$REPO" log --all --extended-regexp --regexp-ignore-case \
  --grep='Duo|751|CSSC|X1|PAC|bootstrap|libmisfix|trustcache' \
  --format='%H %cI %s' > "$LAB/evidence/source/relevant-history.txt"
git -C "$REPO" grep -n -i -E \
  'iPhone19,4|24A94425|ARM64E_X1|arm64e[.]x1|CSSC|PAuth|libmisfix|new[.]trustcache' \
  HEAD -- > "$LAB/evidence/source/locations.txt" || [ "$?" -eq 1 ]
```

搜索只是定位，不以命中数量签署兼容性。针对实际文件和修改检查完整上下文、测试和运行分支。只有取得真实旧 SHA 才生成两点 diff；v1.3 文档日期不是源码基线。

本轮重点不是再次统计几十项无关 UI 提交，而是：M5 X1 路由、bootstrap 转换范围、trampoline、trustcache 文件处理、guest 资源版本及其安装方式。

## 7. 构建与输入验证

沿用完整工作区构建，不只替换宿主 CLI 或 guest daemon。构建前固定 Xcode 路径和版本，不把安装更高 SDK 当作重新编译 IPSW 系统二进制。[S7]

```bash
set -euo pipefail
: "${REPO:?}"
: "${LAB:?}"
cd "$REPO"
mkdir -p "$LAB/evidence/build"
xcodebuild -version > "$LAB/evidence/build/xcode.txt"
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build \
  2>&1 | tee "$LAB/evidence/build/build.log"
export BUNDLE="$REPO/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle"
export VP="$BUNDLE/Contents/MacOS/vphone-cli"
test -x "$VP"
"$VP" host preflight
```

保留宿主／guest 平台和架构检查、实际依赖、签名、cdhash、构建与测试结果。每次重签或宿主授权状态改变重新 preflight；Recovery 安全设置必须由机主明确授权，不能由本版脚本自动降低系统保护。

两份固件只读审计、身份选择和私有工作目录校验继续保留。不要将整个实验目录改成 root 或全员可写；只为当前操作提供所需权限。研究板链接属于独立权限与输入关卡，不默认与路线 A 共用所有规则。

## 8. 路径 F：新的 Duo 制作仍是默认

### 8.1 新的开工门槛

开始制作前确认：

- 实际 Bundle 来源已固定，当前 CLI／preset 能力已读取。
- M5 CSSC 与非原生 X1 策略分别明确；不伪造 host 或 guest 能力。
- Duo 输入、恢复身份、PCC 路线和补丁适用范围已核对。
- 包含封装修复或已解释为何该路径不受影响。
- #751 作为未完全核实线索登记；不要求“必须有人先修好”才能做探索，但不能称为已经验证的配方。

此前同宿主、同 Bundle、同 PCC 与主要配置的控制 VM 证据可复用。发生大范围变化则补做控制实验；不要不加区分地重复下载固件。

### 8.2 手动流程

以下是继承自 2.x 指南的操作骨架，执行前逐项以本次构建的帮助核对。[S8] 两终端 source 同一个环境文件，设置 VP、VM、RUN、DUO_IPSW、PCC_IPSW、PRESET、VPHONE_ROOT、VPHONE_LIBRARY_ROOT，禁止在文件中写密码或 token。

```bash
set -euo pipefail
: "${VP:?}"
: "${VM:?使用新实验名称}"
: "${RUN:?}"
: "${DUO_IPSW:?}"
: "${PCC_IPSW:?}"
: "${PRESET:?当前源码已确认适用的 preset}"
mkdir -p "$RUN"
test -f "$DUO_IPSW"
test -f "$PCC_IPSW"
"$VP" vm new "$VM"
"$VP" fw prepare "$VM" \
  --iphone-source "$DUO_IPSW" --cloudos-source "$PCC_IPSW" \
  2>&1 | tee "$RUN/prepare.log"
"$VP" fw patch "$VM" --preset "$PRESET" \
  2>&1 | tee "$RUN/patch.log"
"$VP" fw patches "$VM" > "$RUN/patch-state.txt"
"$VP" vm info "$VM" > "$RUN/before-restore.txt"
```

不猜 duo preset。上游历史文档的 standard 有非原生 X1 处理，不等于本次 Duo 所需补丁全已覆盖；填写 PRESET 前仍要读实际实现。

进入恢复前检查文件系统／trustcache／manifest、各 ISA 转换目标和 receipt。终端 A：

```bash
set -euo pipefail
"$VP" vm launch "$VM" --dfu 2>&1 | tee "$RUN/dfu.log"
```

终端 B：

```bash
set -euo pipefail
"$VP" restore "$VM" 2>&1 | tee "$RUN/restore.log"
"$VP" vm stop "$VM"
```

恢复成功、已停止并确认相关文件无占用后，按当前 helper 或 standalone 契约执行 CFW。不能对整个 GUI 和制作过程随意 sudo；独立 CLI 示例只适用于自己已审查的 Bundle 和路径：

```bash
set -euo pipefail
: "${VPHONE_ROOT:?}"
: "${VPHONE_LIBRARY_ROOT:?}"
sudo /usr/bin/env \
  VPHONE_ROOT="$VPHONE_ROOT" \
  VPHONE_LIBRARY_ROOT="$VPHONE_LIBRARY_ROOT" \
  "$VP" cfw install "$VM" 2>&1 | tee "$RUN/cfw.log"
"$VP" vm launch "$VM" 2>&1 | tee "$RUN/first-boot.log"
```

首轮不用模板和系统精简，保留阶段产物。不因已有模板能启动而宣称重新执行了新固件制作。prepare 中临时 PCC／GPU 的恢复与目标 Duo 恢复分别记录。

## 9. 路径 U：何时更新、何时重做

继承 v1.3 的分层维护，但加入本轮两个变化的作用范围。以下是本项目的变更评审规则，最终服从当前实现支持范围：[B1][S9]

| 变化 | 建议动作 | 限制 |
|---|---|---|
| 仅宿主 UI／通信 | 工作副本绑定目标 Bundle，再验证 | 首次连接可能同步 guest，不能假定纯宿主实验 |
| 已安装 guest 资源中的单独修复 | 满足当前契约时 update-environment | 必须确认系统映像／bootstrap／缓存不需要重做 |
| 适用的既有内核补丁 | 满足契约时 update-kernel | 不是更换 PCC、recipe 或任意系统的升级器 |
| bootstrap／dyld／缓存的 X1 转换策略改变 | 默认新 VM 从原始 IPSW 重做 | 旧磁盘不会因换 Bundle 自动变回原始指令 |
| trustcache 封装修复 | 从干净原始输入重新生成受影响产物 | 不删除后继续，不拿半成品反复覆盖 |
| PCC／iOS build／recipe／恢复启动链变化 | 完整新制作 | 保留旧成品，不混 Disk／SEP／NVRAM |
| 仅 libmisfix 版本变化 | 先审阅实际部署层再决定环境更新或重做 | 从标题不能决定更新入口；失败半成品不走维护 |

> **实测补充：** PR #728 新增的 `dyld-cfw-arm64e_x1_cache` 是在原有 bootstrap lowering 之上追加全缓存 lowering，而不是改变已有改写的方向。在 stock 2.13.8 VM 的 APFS 克隆上用 #728 Bundle 执行 `cfw update-environment` 即可生效（7 个待应用补丁，另含 VirtualAudio 与折叠姿态设备树），无需重做 restore。仍先克隆再更新，保留原 VM 作对照；若将来上游改变已有 lowering 规则本身，仍按上表从原始 IPSW 重做。

记录 bundle、guestEnvironmentBundle、bootChainBundle 三层来源和真实已应用补丁，不用版本字段代替磁盘内容验证。启动时的自动环境同步、重启要求、库哈希和 daemon 实例变化继续记入证据。

## 10. 本轮新增验收与顺序

下面是建议的项目验收，不是上游已完成的测试。

| 阶段 | 要取得的证据 | 失败时先看 |
|---|---|---|
| T0 构建与来源 | 实际源码、Bundle、签名、Xcode、两份固件 | 构建／打包／来源，不进入 guest 推测 |
| T1 封装 | seal、trustcache、manifest 独立结果 | 同路径操作、组件引用、原件完整性 |
| T2 早期启动 | init／dyld 执行、X1 决策、缓存映射 | bootstrap、ABI、TXM、ISA |
| T3 系统服务 | 关键进程持续存活和 vphoned | 异常报告、已载入库、PAC／trampoline |
| T4 安装 | I0 快速安装与 I1 系统 installd 分别成功 | 安装服务、注册、实际库版本 |
| T5 应用 | 原生 Probe，再 food_ordering iPhoneOS 产物 | 应用平台、链接、输入与业务状态 |
| T6 稳定与迁移 | 多次冷启动、网络、回滚、完整导入 | 来源混配、自动同步、快照旁档 |

T3 建议在 UI 就绪后持续观察关键服务，而不是看到一次 daemon 响应就签收；本项目可以采用至少 10 分钟观察窗口。稳定性仍建议至少 10 次冷启动，一次宿主重启后的启动。时间和次数是验收建议，不是已执行结果。

安装 I0 使用 vphoned 路径；I1 经系统安装服务，再用相应 guest API 启动。简单 App 通过后再测 food_ordering；不同时更改 Expo/RN、编译配置和镜像。拓展能力只有实际需要时单独加用例。

> **实测状态（2026-10-27）：** T0 通过；T1 通过（seal／RestoreTrustCache 重算，cdhash `3ee3cd0f…` → `4f9541a0…`）；T2 通过（stock 与 #728 均可开机）；T3 stock 不通过（X1 按需处理致 launchd 持续高 CPU 与看门狗），#728 通过（20 分钟空闲观察）；T4 通过（I0、I1）；T5 通过（原生 Probe App、KFC 两个第三方 IPA；food_ordering 在补 UIScene 生命周期后通过）；T6 通过（§13.5，含宿主重启后启动）。原生 Probe App 与 CSSC 探针见 §13.6。
>
> **food_ordering 构建注意：** 使用 Xcode 27.1 时，Expo 53 模板缺少 `UIApplicationSceneManifest`，iOS 27 UIKit 在 `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption` 中 EXC_BREAKPOINT。补 `SceneDelegate`（在 `scene(_:willConnectTo:)` 中启动 React Native）与场景清单后通过。`expo prebuild` 会重建 `ios/`，长期修复应写成 config plugin 或升级到支持场景的 Expo SDK。经 installd 安装 ad hoc 签名的应用时，必须带 `application-identifier` 授权，否则返回 ApplicationVerificationFailed。

原有九点点击、旋转接受／拒绝、网络长连接空闲、快照及宿主旁档、完整导出全部保留。原生 X1 与非原生 X1 的结果不得合并一行；M5 成品不默认适用于旧 Mac或原生 X1 对照。

## 11. 下一轮具体交付证据

最有价值的不是再给所有门槛加一张空表，而是完成以下实际材料：

1. 官方目标构建的完整来源及包含修复的文件关系；没有取得则明确空缺。
2. M5 CSSC 实际执行、X1 兼容分支选择和产物覆盖清单。
3. fw patch 封装阶段的干净成功结果，或首个明确失败点。
4. Duo 启动及关键服务异常报告；若 PAC 失败，包含上下文而不是仅异常名称。
5. 一份可复现的成功或失败结论，明确是否受 #751 对应机制影响，不能只靠相同标题类比。

附带 EXPERIMENT.json 是待填模板，null 均表示未测／未取得，不是默认成功或不支持。

## 12. 本次完成与未完成

本次完成：全文读取 v1.3；检索新发布线索、转载的上游 release 与 issue 标题；核对 Apple／LLVM 主资料；修订方案、变更单和证据索引；检查文档、Bash 示例语法与归档完整性。

未完成：实时 HEAD／完整 checkout、2.13.2–2.13.5 完整官方 diff、#751 正文与闭环状态、发布资产验签、实物 IPSW 处理、Xcode 构建、M5／guest 指令执行、恢复／启动／应用／折叠测试。没有新增生产执行器，没有更新旧探针或审计器，也不复用旧工具的测试次数。

> **实测增补后：** 上述“未完成”中，实时 HEAD／最新发布、#751 正文、实物 IPSW 处理（SHA-256 与 U1 一致）、Xcode 构建、M5 启动、恢复、应用均已完成，见 §13。2.13.2–2.13.8 逐版差异、宿主／guest CSSC 指令探针已在 §13.6 完成（2026-10-28）。10 次冷启动、宿主重启、网络长连接、旋转、快照／导出、折叠（C 级）已在 T6 完成，见 §13.5。

**本版有实质的新决策依据，但不是“最新上游已经完整支持 Duo”的证明。** 默认继续在 M5 上制作，不转到旧 Mac 模拟路线、不因原生 X1 问题标题误改 M5 分支、不因版本号变化盲目重刷所有成品。

## 13. 实测记录（2026-10-27，M5 Pro）

### 13.1 环境与输入

| 项 | 值 |
|---|---|
| 宿主 | M5 Pro，macOS 27.0.1（26A434）；SIP 自定义（Debugging Restrictions 关闭），AMFI 放行经既有 allowlist 工具，`host preflight` 通过 |
| Xcode | 27.1（27A9269） |
| 源码 | 控制组：`7d633c9a`（2.13.8）；实验组：PR #728 head `b03f0b82`（2.13.7＋#761／#762＋PR，即 2.13.8 内容＋PR），独立 worktree 构建 |
| Duo IPSW | `iPhone19,4_27.1_24A94425_Restore.ipsw`，12,724,731,538 字节，SHA-256 `58fbfda8…0a782e`（与 U1 一致） |
| PCC | cloudOS 26.4 / 23E5207q（`vphone-cli` 目录推荐配对，即路线 A） |
| VM | 8 CPU／8 GiB／64 GB，OpenAVB＋OpenSEP，preset standard，`--no-template`，无服务精简 |

### 13.2 P1 制作（`duo-m5-p1`，stock 2.13.8）

- prepare：GPU 驱动来自临时 cloudOS 恢复；patch：preset standard（10 个补丁集，152 项启用，3 项不适用本 OS），11 个启动链组件，`apfs_sealvolume`／RestoreTrustCache cdhash `3ee3cd0f…` → `4f9541a0…`；无 trustcache 自移动冲突。
- restore：启动链 102 项补丁；restore 完成后 DFU 会话自行启动了未 cfw 的系统，产生 launchd SIGILL panic（见 §4.1），非制作故障。
- cfw install：launchd 2,735、dyld 5,299 条 X1 指令 lowering，bootstrap 缓存 38 映像 228,314 处改写，重新签名 corecrypto FIPS HMAC 与缓存签名槽；4 项 VirtualAudio 补丁因 `no retab after the throw at 0x171cd0` 失败（已知，#728 修复）。cfw 收据记录的设备为 `iPhone99,11`，待查。
- 首启：Setup Assistant，vphoned 应答；`device.info`：iPhone19,4，27.1。TXM 日志有 `selector: 38 | 15`、`Constraint not matched` 噪声，未与 iPhone17,3 VM 对比。

### 13.3 P2 X1 性能对照

| | stock `duo-m5-p1` | #728 克隆 `duo-m5-728` |
|---|---|---|
| X1 缓存 lowering | 38 映像，228,314 处 | ＋4,508 映像，24,606,071 处（212,573 页段），250,449 未访问候选 |
| launchd CPU | 837 s 时 410 s；2,063 s 时 874 s（约 23 s／分钟，未收敛） | 135 s 时 9 s；1,218 s 时 11 s（平稳） |
| 看门狗 | MercuryPosterExtension 场景创建、Setup 场景更新 ×6 | 无新增 |
| 界面 | 天气、日历小组件空白；设置约 10 s 绘制完 | 小组件正常；设置 1 s 内 |
| VirtualAudio | 4 项失败 | 全部成功；audiomxd 单实例无崩溃 |
| 20 分钟空闲新增崩溃 | duetexpertd ＋1、geod ＋1、ReportSystemMemory ＋2 | duetexpertd ＋8 |

两台 VM 都有 duetexpertd 的 `Failed to initialize datavault for DuetExpertCenterAsset` 循环崩溃（#751 也提到），与 X1 无关，未解决。#728 下未访问候选和独立 X1 二进制仍走按需处理。

### 13.4 P3 安装与应用（`duo-m5-728`）

| | I0：vphoned `apps.install` | I1：installd（`ideviceinstaller`） |
|---|---|---|
| IPA | KFC Prod 6.36.0（arm64，cryptid 0，26.2 SDK） | KFC Knight 9.1.1（arm64，cryptid 0） |
| 安装 | 1 s | 6 s，Verifying → Sandboxing → Complete |
| 启动 | <1 s，首屏绘制 | 登录页及网络验证码绘制（网络可用） |
| installd | — | pid 302 不变，5 分钟 0 s CPU，无崩溃 |

- vphoned 签名器拒绝含 armv7 slice 的 fat 二进制（KFC Knight 内 3 个百度人脸 SDK 资源包：`unsupported slice: slice at 16384 is not 64-bit little-endian`）；installd 路径接受同一 IPA。与 Duo 无关，已报上游 Lakr233/vphone-cli#766（2026-10-28）。M5 Pro A/B 与 T6 数据已评论到 #728。
- 旧 SDK 应用以内缩圆角窗口（兼容框）运行；新 SDK 且采用场景生命周期的 food_ordering 全屏运行。右上角常驻时钟／充电胶囊。
- food_ordering：见 §10 实测状态；最终 `apps.launch` 返回 `frontmost_verified: true`。
- `apps.launch` 对两个旧 SDK 应用返回 `frontmost_verified: false`，但画面上已在前台。

### 13.5 T6 稳定性与 C 级初测（`duo-m5-728`，2026-10-28）

| 项 | 结果 |
|---|---|
| 冷启动 ×10（无窗口） | 10/10：vphoned 6–10 s 应答；开机 180 s 时 launchd 9–11 s CPU，SpringBoard 存活；新增崩溃仅 duetexpertd、SiriSearchFeedback、mediaremoted、ExtensibleSSOSubscriber 各 ≤2。第 8 次（vphoned 14 s，launchd 20 s）与宿主上的 Xcode 构建重叠。无窗口启动后屏幕停在锁屏且熄灭，截图全黑；解锁后主屏正常 |
| 宿主重启后启动 | 通过（2026-10-28）：重启后 amfid 内存中的白名单失效，首次启动被 AMFI 拒绝（cdhash `775ec296…`）；机主重跑 `sudo vphone-escalator allow` 后启动，vphoned 8 秒就绪，launchd 68 秒时 CPU 10 秒，解锁到主屏（小组件已绘制），3 个用户 App 均在 |
| 旋转 | 方向名用连字符（`landscape-left`）。Safari 90°／270°／0° 均生效且 SpringBoard 回读一致；仅竖屏的 KFC、food_ordering 拒绝（正确）；主屏保持竖屏 |
| 网络长连接 | SSE 连接空闲 600 s 后同一连接收到事件，ack 4 ms 内返回 |
| 拔插网线 | `vm network --link down`：en0 地址消失、DNS 0 结果；`up` 后 3 s 恢复地址，DNS、EventSource 重连、页面重载均正常 |
| 快照 | `pre-t6` 回滚后可启动（9 s）；回滚前另存 `post-t6` |
| 导出／导入 | `vm export`（zstd）65 s、15 GB；`vm import` 31 s；导入副本可启动，含 3 个用户应用，状态与 `pre-t6` 一致 |
| 音频 | Safari 中 WebKit 播放 WAV 3 次（playing→ended 均约 5.5 s），设置中铃声预览（RingtonePreview）3 次；audiomxd pid 不变、无崩溃。2026-10-28 重放，机主确认宿主扬声器可听到 440 Hz 音 |
| 折叠（C 级） | 设备树 `target-sub-type` 已改为 `V68VM2025`；`display.posture` 各铰链状态均被接受，SpringBoard 不重启；单显示下主屏无变化；带方向的姿态可让 Safari 横屏。内外屏切换需要双显示与 V68 `product-id`，上游尚未实现 |

新发现：
- **Auto-Lock 设不成 Never：** `display.auto_lock.set` 只写入 UserSettings.plist，profiled 不重新生成 EffectiveUserSettings.plist（仍为 120 s）；在设置界面选 Never 后，UserSettings 中的值为 0、`rangeMinimum` 为 120，生效值仍为 120 s，屏幕 2 分钟后照常锁定。没有任何描述文件限制该项。推测：iOS 27 以 0 表示 Never，被 vphoned 补写的 `rangeMinimum` 120 截断。未证实，待查。长时间测试须定时轻触屏幕。
- 宿主侧测试服务器要在 VM 启动后再监听：nat 网桥只在有 VM 运行时存在，且宿主重启后网段可能变化（重启前 `bridge101` 192.168.65.1／guest .2；重启后 `bridge100` 192.168.64.1／guest .4），测试脚本须按当次地址监听。

### 13.6 补充证据（2026-10-28）

第一阶段基线快照：`duo-m5-728` 的 `phase1-baseline`（2026-10-28 08:20，T0–T6 全部通过后、安装 Probe 之前）。

**原生 Probe App。** 最小 Objective-C UIKit 应用（采用 UIScene 生命周期），用 Xcode 27.1 工具链以 `clang -arch arm64` 构建 iphoneos 产物，ad hoc 签名并带 `application-identifier`，经 installd（`ideviceinstaller`）安装，`apps.launch` 启动：全屏绘制，无崩溃报告。源码：`~/vphone-duo-m5/src/cssc-probe/`；结果：`~/vphone-duo-m5/run/evidence-probe/`。T5 中“Probe 原生 App 未单独构建”一项由此补齐。

**CSSC 执行探针（宿主与 guest）。** 同一份 C 代码分别构建为宿主命令行程序和上述 Probe App：先校验 ABS／CNT／CTZ／SMAX／UMIN（寄存器与立即数形式）的结果，再各执行 200 万次，与 ADD 对比每次耗时。

| | 结果正确 | ADD | ABS | CNT | CTZ | SMAX | UMIN #imm |
|---|---|---|---|---|---|---|---|
| 宿主 M5 Pro | 6/6 | 0.50 ns | 0.51 | 0.98 | 0.73 | 0.75 | 0.73 |
| guest iPhone19,4 27.1 | 6/6 | 0.54 ns | 0.53 | 1.05 | 0.75 | 0.75 | 0.77 |

guest 中 CSSC 与宿主同速，均在 ADD 的 2 倍以内。2.13.2 起内核带 CSSC 回退模拟（`kernel-boot-cssc_emulation`，本 VM `patch.log` 已应用），但走回退时每次执行都要经过一次未定义指令异常，耗时为微秒级。因此结论是：**M5 上 guest 原生执行 CSSC，内核回退未被进入。** CSSC 原生通过不代表 X1 原生通过；X1 仍走 lowering（§3、§13.3）。

**2.13.2–2.13.8 逐版差异（只列与本 Duo 镜像相关的部分）。**

| 版本 | 合入 | 对本镜像的影响 |
|---|---|---|
| 2.13.2 | #752 CSSC 内核回退模拟；#753 账户提示 hook 可选；#750 完整 OTA 保留已删除系统 App；#754 更新时磁盘空间检查 | CSSC 回退已打入内核，但 M5 原生执行，不触发（见上）；账户 hook 在 `standard` 中默认开启，行为不变；OTA 项本轮未用 |
| 2.13.3 | #755 iPhone17,3 改为呈现独立设备树；vphoned 脚本会话与终端 | iPhone17,3 专项，不影响 iPhone19,4（本 guest 已报告 iPhone19,4，收据中的 `iPhone99,11` 仍为平台身份）；终端为新增功能，本轮未用 |
| 2.13.4 | 终端菜单名与资源包位置 | 无 |
| 2.13.5 | 脚本会话改用 IcliKit probe | 无 |
| 2.13.6 | Apple TV RootHide 引导与环境 hook | 仅 tvOS；iPhone 补丁集未变 |
| 2.13.7 | #763 tvOS 原生 vphoned | 仅 tvOS |
| 2.13.8 | #761 AKS keybag 解锁接受 5 个标量参数（iOS 26.6 及以上 userland 在 26.4 内核上的加密备份）；#762 蓝牙 BTVC LE 连接 | 二者都适用于本镜像：`patch.log` 中 `aks_unlock_bag` 已应用，cfw 收据中 `EnableBTVCLeConnection` 已开启 |

PR #728 head `b03f0b82` 已包含 #761 和 #762，与 2.13.8 只差版本号提交，所以用它执行 `update-environment` 没有回退 2.13.8 的补丁（`728-update-env.log` 中 BTVC 显示为保持不变）。各版均未改动 X1 lowering 和 Duo 设备树补丁。

### 13.7 结论与下一步

1. M5 上做 Duo 开发测试 VM，建议使用包含 #728 全缓存 lowering 的构建；在 #728 合并前，按 §9 补充记录“采用未发布源码”的 SHA、cdhash 与差异。
2. T6 全部完成（含宿主重启后启动），见 §13.5。宿主每次重启后需重新执行 `vphone-escalator allow`。

   **第一阶段（单显示 Duo 开发测试 VM）完成**，基线快照 `phase1-baseline`；附带条件是依赖未合并的 #728。#728 合并发版后，用正式 Bundle 执行 `cfw update-environment`（或重做），并复跑 T3 与 §13.6 探针，即可去掉该条件。方案原列的证据项（逐版差异、CSSC 探针、原生 Probe App）已在 §13.6 补齐。
3. 已结论：duetexpertd datavault 循环是所有 iOS 27 guest 的已知现象（上游 `Research/Host/machine_templates.md`），精简服务配置可关闭；收据设备 `iPhone99,11` 是 vphone600ap 平台身份，属预期；TXM `selector: 38 | 15` 噪声随 #728 从 2,981 条降到 1 条，是 X1 按需处理的副作用。
4. 已报上游：签名器 armv7 slice（#766）。待查：Auto-Lock Never 不生效；双显示／折叠（C 级，依赖上游）。（2026-10-29 更新：折叠改走 #728 的 guest 逻辑双显示，已可在同一会话内开合，见 §13.8；两个独立宿主输出仍受 VM 服务门禁限制。）
5. 原始日志：`~/vphone-duo-m5/run/`（prepare、patch、restore、cfw、728-update-env、first-boot、728-boot、`p2/`、`p2-728/`、`p3/`、`crash/`、P2-summary.md、P3-summary.md）；证据：`~/vphone-duo-m5/evidence/`。

### 13.8 第二阶段：#728 逻辑双显示（`duo-m5-v1.5`／`duo-m5-fold728`，2026-10-29）

**路线。** 两个独立宿主输出仍被 VM 服务门禁挡住（phase2/README.md）。PR #728 后续提交（`spike/duo-virtual-inner`，经 `4410ed73` 并入）改走另一条路：backboardd 在 guest 内发布一个软件内屏（`VPhone Duo Inner`，2853×2007，内置、非 Main），SpringBoard 用原生内容模式解析 FoldingDual／FullyClosed，并把内屏画面合成到唯一的 PG 输出上。它不解除门禁，只是不再依赖第二个端口。

**合入。** 本地分支 `duo-m5-v1.5`（worktree `~/vphone-duo-m5/src/fold728`）＝ `duo-m5-v1.4` ＋ PR head `3da02943`（比分析所用 PDF 的 `f680c8c` 新一个提交），合并提交 `297add30`，未推送。X1、VirtualAudio、服务保留与旧 PR head `b03f0b82` 是同一批提交，无需去重；新增的是 spike 分支的 23 个提交。12 个冲突文件，规则由机主确认：

| 规则 | 内容 |
|---|---|
| 启动尺寸 | iPhone19,4 默认按折叠模式启动，单个 PG 输出 2007×2853；`vm config --display outer\|inner` 在 VM 目录写 `display-choice`，改为静态单屏；`--display fold` 删除该文件。不改 config.plist 格式（Launchpad 读取） |
| ppi | 内屏统一为 2007×2853 @460（v1.4 为 430） |
| 互斥 | SpringBoard 中 SystemHook 仅在 `libvphonefolddisplay.dylib` 不存在时加载 `inner-cutout-fix`（cutout 修正把 Main 当内屏，折叠路线 Main 是外屏）；静态内屏须 `fw set-patches --block system-springboard-cfw-fold_display --allow system-springboard-exp-inner_cutout` |
| 设备树 | 本地 `preboot-exp-devicetree_inner_panel_display` 与 #728 `preboot-exp-devicetree_foldable_product_id` 并存，均在 standard 中关闭 |
| 默认开启 | `fold_display`、`fold_guard`、`hinge` 是 cfw 补丁，standard 下对 iPhone19,4 默认开启：**不得用 v1.5 Bundle 更新 `duo-m5-728` 或静态 E1 VM** |

构建：`VPhone` 通过（含 ValidateBundle），`vphone-vm` cdhash `2fb0bec7…`（已加入 allowlist）。VPhoneCoreKitTests 663/663，vphoned 逻辑检查 394/0 失败，FoldGuard 7/7；FirmwarePatcherTests 134 项失败，均为本机缺参考固件（`pristine` fixture、`ibss.bin` 等），与 Duo 无关。

**VM。** `duo-m5-fold728` ＝ `duo-m5-p1` 的 APFS 克隆（`--new-identity`，已信任宿主）＋ v1.5 的 `cfw update-environment`（X1 缓存 24,606,071 处改写，与 `duo-m5-728` 相同；`target-sub-type` V68AP → V68VM2025）。首次 update-environment 被 Ctrl-C 中断于 X1 全缓存阶段，清理挂载后重跑成功（`UPD_EXIT=0`）。

| 关卡 | 结果 |
|---|---|
| F0 显示模型 | **通过。** `CADisplay.mainDisplay` = `LCD primary`（id 1，type 0，外屏）；`VPhone Duo Inner`（id 7，非外接，独立 UUID）；SystemHook：SpringBoard 加载 `fold-guard`、`fold-display`，backboardd 加载 `hinge`、`fold-display`，无 `inner-cutout-fix`。vphoned 8–10 s，launchd CPU 10 s |
| F1 同会话开合 | **冒烟通过。** `display.posture` open／closed 逾百次（F0、锁屏测试与 4 轮 F5 录制），SpringBoard pid 不变、无新崩溃；合拢为竖屏外屏主屏，展开为横屏内屏主屏（侧边 Dock）；Safari 跨开合保持同一页面 |
| 锁屏 | 开合不锁屏（主屏、Safari 前台、内屏解锁后合拢、重启后按 F0 顺序重放，均以 0.5／2／5 s 采样）。F0 首次启动时见过一次展开后锁屏，未能复现（当时 pose `hinge: 0` 且有“信任此电脑”弹窗） |
| 旋转 | 外屏主屏拒绝横屏、内屏主屏拒绝竖屏（与 iPhone 主屏语义一致）；其余旋转请求生效 |
| F5 输出一致性 | **开合黑帧已修复**，见下 |

**F5 黑帧。** 用 VM 窗口自带录制（截取 ▸ 开始录制，⇧⌘R，录的是 PG 输出本身）在固定序列下逐帧统计（`~/vphone-duo-m5/run/fold728/f5-*.sh`，30 fps）：

| | run1（合入原样） | run3（第一版修复） | run4（最终） |
|---|---|---|---|
| 含黑像素帧 | 121 | 100 | 27（全部为 App 启动） |
| 主屏展开／合拢 | 6–7 帧／1–2 帧 | 2–3／0 | **0／0** |
| Safari 前台展开 | 11–30 帧 | 26–29 | **0** |
| 快速开合（1 s 间隔） | 6–7／1–2 | 1–2／0 | **0／0** |

原因（毫秒日志对齐）：一是交接分步，SpringBoard 先把外屏场景撤离 Main，约 130–190 ms 后合成器第一帧才到；App 在前台时内屏本身还会先黑约 1 s。二是 `vpApplyPanelStates` 在内屏已持有面板、但尚未收到内屏供电请求时关闭了唯一输出（27 次中 4 次）。修复提交 `fb41cd6b`：内容模式切换开始时由 render server 把 Main 当前帧画进 IOSurface，置于 Main 根场景窗口最上层，展开时等内屏画出非黑内容、合拢时外屏取回主场景后 150 ms 再撤下，最长 2 s；内屏未请求供电前输出保持点亮。代价是切换时静止 260–420 ms（Safari 前台 0.9–1.4 s），不再黑屏。

**新发现（未处理）。** 内屏启动“设置”“照片”时启动卡片为黑色（16／8 帧，修复前即有，与折叠无关）；外屏 Safari 状态栏时间压住地址栏（作者已记录横屏，竖屏同样）；合拢时外屏占满整块面板，不裁到 466×678（作者已记录）。

**F2 应用连续性（部分完成，2026-10-29）。** food_ordering 生产包（`food_ordering.ipa`，Appwrite 登录，仅竖屏，单场景，`UIRequiresFullScreen=false`）经 installd 装入 `duo-m5-fold728`（UDID `0000FE01-0931B54BFFF5E54B`）。登录页输入跨开合：进程不重启，输入的邮箱、密码在内屏保留。购物车与应用内导航未测：生产包需要账号（不在机主后端建号），verification 包需 fixture 选择文件并在 `food_ordering-testchannel` 做 `expo prebuild`。

**F2 发现：带焦点输入框合拢后外屏空白。** 输入框有焦点（硬件键盘模式，屏上无软键盘）时合拢，food_ordering 在外屏只剩状态栏或只画出上方约 669 pt（＝内屏高度），可访问性树为空、触摸不达，同一进程内一直如此；再展开内容恢复，输入仍在。用同一脚本（`~/vphone-duo-m5/run/fold728/tools/kb-cycle.sh`，以 AX 树中出现键盘按键确认焦点）逐项排除：

| 变体（合拢时输入框有焦点） | 合拢后外屏 |
|---|---|
| 原包 `UIRequiresFullScreen=false` | 空白，或只画上方约 669 pt |
| 加横屏方向／改通用设备族（键仍为 false） | 空白 |
| 重签为 `UIRequiresFullScreen=true` | 正常 |
| 合拢前在内屏收起键盘／无焦点 | 正常 |
| 设置（未声明该键）搜索框有焦点 | 正常 |
| 原生 UIKit 最小探针 KBProbe（`UIRequiresFullScreen=false`，有焦点） | 正常 |

触发条件是 food_ordering（React Native／Expo）＋ `UIRequiresFullScreen=false` ＋ 合拢时输入框有焦点三者同时成立；单独的键或单独的焦点都不触发。仅失败时 SpringBoard 记录 `Keyboard can't be hosted inside app scene - app is not full screen` 与 `Cover-display … cover-size reduction`；应用端 UIKit 记录场景已移回外屏（几何 669×951）。规避：应用设 `ios.requireFullScreen: true`，或测试流程中合拢前结束编辑。是否属于 iOS／应用自身行为，正用 Xcode 27.1 的 iPhone Duo 模拟器对照（已装模拟器版 food_ordering，外屏为 `--display=1`、内屏 `--display=3`；开合需机主在 Device Hub 中操作），结果未出。记录：`~/vphone-duo-m5/run/fold728/f2/F2-notes.md`、`kb/`。

**未做。** F2 的购物车与导航、F3（两面板触摸与各方向完整回归）、F4（自动锁屏、睡眠中开合）、F6（冷启动、长时间、导出导入、宿主重启）。测量与修复是否回报 #728 由机主决定。

### 13.9 v1.6：合并 main 2.14.0（`duo-m5-v1.6`／`duo-m5-fold214`，2026-10-29）

**上游。** main `2a8ee8b0`（2.14.0）已合入 #728，合并时 head 即 v1.5 所取的 `3da02943`；其后 Duo 相关提交：外屏原生尺寸开机 1398×2034（`5713cc40`）、内屏铺满外屏面板（`737591ff`）、内屏 120 Hz（`16795479`）、注入触摸只路由到存在的显示（`e60c2a56`）、点按唤醒黑屏（`10a71f4f`）。上游没有与 `fb41cd6b` 等价的交接保持。

**合并（`a1ec2f75`，worktree `~/vphone-duo-m5/src/fold214`）。** 按机主决定采用上游模型：fold 按 config.plist 的外屏尺寸开机，不再强制内屏尺寸面板；`display-choice` 与 `iPhone19_4InnerScreen` 只用于 `vm config --display inner`；`VPHONE_SCREEN` 保留为实验开关；`fb41cd6b` 的保持层叠在上游铺满＋120 Hz 面板之上（按 Main 自身尺寸截帧，与面板尺寸无关）。冲突 3 个文件。构建：独立 DerivedData `.build/fold214`，`vphone-vm` cdhash `39c2349e…`。测试：CoreKit 664 通过，FoldGuard 7 通过，FirmwarePatcher 失败集与 v1.5 相同（134 项，依赖本机缺少的固件样本），无新增。

**新 VM `duo-m5-fold214`。** 由 `duo-m5-p1` 克隆（`--new-identity`），`--display fold`，`cfw update-environment` 后回执含 fold_display／fold_guard／devicetree_foldable_vm_subtype，`libinnercutoutfix` 未装；guest `libvphonefolddisplay` 与构建一致（`79f01d877a8f`）。

| 项 | 结果 |
|---|---|
| F0 | 通过：外屏原生 466×678 pt 布局；展开内屏 951×669 pt 铺满（缩放 0.697／0.713），120 Hz；开合 SpringBoard 不重启；vphoned 8 s |
| F5（run1，30 fps 录制，26 次开合） | 交接黑帧 0；hold 26 次全部撤下（展开 215–250 ms，Safari 前台 820–932 ms；合拢约 310 ms）。唯一暗段 14 帧为 Safari 在外屏启动的深色启动卡，非交接；v1.5 中内屏“设置”“照片”的黑启动卡本轮未出现 |
| F2 焦点合拢 | 未复现：food_ordering 原包（`UIRequiresFullScreen=false`）、Email 有焦点合拢，硬件键盘模式 3/3、软键盘模式（`GSEventHardwareKeyboardAttached` bit 0 清零）3/3 均正常：外屏内容完整、AX 36 元素、合拢后点外屏键盘字符进入输入框（展开后为 `kbtestq`） |

**F4 锁屏与电源（`run/fold214/f4.sh`，run1）。** 每步记录 `device.screen`（locked／screen_off）、fold-display 日志与截图：

| 场景 | 结果 |
|---|---|
| s1 合拢、按电源黑屏后展开 | 唤醒到内屏锁屏；hold 1／1 撤下 |
| s2 展开、黑屏后合拢 | 唤醒到外屏锁屏；hold 1／1 |
| s3／s4 内屏／外屏黑屏时点按 | 点按唤醒（2.14.0 `10a71f4f`），保持锁定 |
| s5 Safari 在外屏，展开后 0.15 s 内按电源 | 显示锁屏，无 Safari 旧帧；约 250 ms 后屏幕再亮，停在锁屏 |
| s6 Safari 在内屏，合拢后 0.1 s 内按电源 | 同上；按电源时 hold 已撤下，再亮由 SpringBoard 请求，推测是晚到的姿态变化被当作唤醒，未验证 |
| s7 黑屏中 0.5 s 间隔开合 8 次，停在展开 | hold 9／9 撤下；锁屏显示，解锁后内屏主屏幕正常 |
| s8 Safari 在内屏，空闲超过自动锁屏（300 s）后合拢 | 300 s 时黑屏锁定；合拢唤醒到外屏锁屏；hold 1／1 |
| s9 外屏主屏幕，空闲自动锁屏后展开 | 展开唤醒到内屏锁屏，解锁后主屏幕正常；hold 1／1 |

未发现 hold 在锁屏或黑屏后残留旧内容，也未发现快速反向开合时延迟回调撤错覆盖层。真机上“交接期间按电源后再亮”是否相同，没有对照数据。

**F3 触摸与旋转（`run/fold214/f3.sh`，Safari 打开宿主触摸页 `f3/touch-server.mjs`，页面回报 touchstart 的 client 坐标）。** 每个姿态 × 方向点 5 个点，vphoned `input.tap`（CoreDevice 触摸屏，pt）与宿主 `tap`（VZ 触摸屏，截图像素）各一次：

| 姿态 | 方向 | 结果 |
|---|---|---|
| 合拢 | 竖屏、左横、右横、倒置 | 10／10 命中，偏移恒定（0；右横 −84 为 Safari 安全区），两路径一致 |
| 展开（`open-flat`） | 竖屏、左横、右横、倒置 | 10／10 命中；注入坐标为面板 pt（466×678），落到内屏为线性缩放 669／466＝1.435、951／678＝1.403（横屏对调），与铺满画面一致，残差 ≤0.4 pt；两路径一致 |

手势与 Dock：宿主路径从底边上滑回主屏幕在两块屏都成功；vphoned `input.swipe`（不带边缘标志）在外屏 0／6、内屏成功；vphoned `input.touch` 带 `edge:2` 在外屏 3／3、内屏 0／3。本地 `vphoned_touch.m` 显示关联实验未开（标志文件不存在），属上游行为：vphoned 自有 digitizer 的边缘事件在内屏点亮时没有到达内屏（参照 `e60c2a56` 的路由说明，原因未查）。用户经窗口（鼠标／触控板，VZ 触摸屏）不受影响，影响的是自动化。两块屏 Dock 点按两路径均响应。

**发现：`display.posture hinge:open`（4）下 `display.rotation` 失败。** 上游文档说明 hinge 4 时两块面板方向都是 ambiguous，只有 `open-flat`（3，`position: open`）能旋转；本轮用 `open-flat` 后内屏 0／90／180／270 全部生效。F4／F5 脚本使用的 `hinge:open` 不影响其结论，F5 中 “rotate-inner-portrait” 失败即此原因。

**F6 部分：冷启动与锁屏空闲（`run/fold214/f6-coldboot.sh`、`f6-idle.sh`，无窗口启动，bundle cdhash `39c2349e…`）。** 宿主重启与导出导入未做（前者要机主重启 Mac，后者磁盘只剩约 29 GiB）。

| 项目 | 结果 |
|---|---|
| 冷启动 5 次（`f6/cold1`） | 5／5：vphoned 就绪 8–9 s；180 s 时 launchd CPU 8 s、kernel_task 3 s；解锁成功；vphoned 点设置、宿主点 Dock Safari 都进到对应 App；展开截图 2034×1398、内屏 shown=1，合拢回 1398×2034；hold 2／2；SpringBoard pid 37 开合前后不变 |
| 冷启动新增崩溃 | 仅 duetexpertd（每次 0–2 份）、SiriSearchFeedback（0–1 份），均为已知后台进程；无 SpringBoard／backboardd |
| 锁屏空闲 120 min（`f6/idle`） | 合拢、按电源黑屏后每 10 min 采样 13 次：SpringBoard 37、backboardd 73、vphoned 114 全程不变；launchd 占用 0.12%、kernel_task 0.43%，均为线性增长、无突增；memorystatus_level 58→53，压力级别 1；崩溃只有开机最初 10 min 内的 duetexpertd 2、SiriSearchFeedback 1，此后无新增 |
| 空闲后操作 | 锁屏中展开为内屏锁屏（678×466 pt，截图正常）；解锁成功；合拢后 vphoned 点设置、宿主点 Dock Safari 都成功；SpringBoard 仍为 37 |

此前 `logs.crashes` 中的 SpringBoard 报告（`SpringBoard-2026-10-27-174016.ips`）早于 `duo-m5-fold214` 创建，是从 `duo-m5-p1` 克隆带来的，不计入 v1.6。

**F6 导出导入（`run/fold214/f6/export`）。** 为腾空间删除了 `duo-m5-728`、`duo-m5-dd`（含其快照）及旧构建缓存。`vm export duo-m5-fold214 --max`：912 s，归档 13.7 GB（.txz），成功。`vm import` 三次均在剩余空间低于阈值时由守护中止，未完成。原因：归档中 `Disk.img` 没有稀疏记录（pax／GNU sparse 头不存在），导出时空洞被当作零数据打包；原机 `Disk.img` 逻辑 64 GB、实占 27.7 GB，导入已解压的 37.4 GB 全部实占，完整导入需写满 64 GB。即导出→导入会让 VM 磁盘占用从 27.7 GB 胀到 64 GB；`VPhoneTreeFingerprint` 把稀疏占用列为应保持的差异，说明这不是预期行为。原因在 `VPhoneArchiveWriter` 读盘设置还是 libarchive 在 APFS 上的空洞识别，未查。v1.5 期 `duo-m5-728` 导入成功只因当时空间足够，未检查占用。归档已删除。

**F6 宿主重启（`run/fold214/f6/hostreboot`，2026-10-30 09:42 重启 Mac，机主重新执行 `vphone-escalator allow`）。** 冷启动 2／2 通过，结果与 cold1 一致：vphoned 8–9 s；180 s 时 launchd 8–9 s、kernel_task 3 s；解锁、vphoned 点设置、宿主点 Dock Safari 成功；展开 2034×1398 内屏 shown=1，合拢 1398×2034；hold 2／2；SpringBoard pid 37 不变。与上一份清单相比新增崩溃只有 duetexpertd、SiriSearchFeedback。第 1 次输出中的长串（含 `panic-full`、SpringBoard、Setup）是整份历史清单，全部为 2026-10-27，来自 `duo-m5-p1`：脚本在 VM 停止时取基线得到空表，已改为 vphoned 就绪后取。

未做原因分析：v1.6 与 v1.5 的差异主要是外屏以原生尺寸开机（v1.5 外屏是在内屏尺寸面板上裁出），推测 v1.5 的 “cover-size reduction” 路径与此有关，未验证。记录：`~/vphone-duo-m5/run/fold214/`（`f0/`、`f5/run1/`、`kb/`）。仍未做：F2 购物车与导航；模拟器对照的意义降低，可作为可选。

## 来源与读取渠道

[S1] Apple：Preparing your app to work with pointer authentication。当前检索正文包含 arm64e.x1、PAuth_LR 和 M6+ 的支持说明；检索日 2026-10-27。  
https://developer.apple.com/documentation/security/preparing-your-app-to-work-with-pointer-authentication

[S2] LLVM 原始 PR #171187：Define apple-m5/a19 CPUs，M5 特性定义含 CSSC。  
https://github.com/llvm/llvm-project/pull/171187

[S3] 上游作者 Other iPhone models 文档，通过镜像读取；用于现有 X1 lowering 机制，不当作实时支持表。  
原址：https://github.com/Lakr233/vphone-cli/blob/main/Documents/Guides/iphone-models.md  
读取：https://upd.dev/Lakr233/vphone-cli/src/branch/main/Documents/Guides/iphone-models.md

[S4] 上游 release 2.13.1 的作者原文，通过 RepoRadar 的 Releases and announcements 区段读取；仅采用该原文区段，不采用页面 AI 摘要或其 latest 标签。  
原入口：https://github.com/Lakr233/vphone-cli/releases  
读取：https://reporadar.spreix.com/repos/Lakr233/vphone-cli

[S5] Apple：Improving control flow integrity with pointer authentication；用于认证方案与地址判别信息，不当作 #751 已确诊根因。  
https://developer.apple.com/documentation/Apple-Silicon/improving-control-flow-integrity-with-pointer-authentication

[S6] 上游 README／Downloads：配套 Bundle 与公证入口。  
https://github.com/Lakr233/vphone-cli  
https://github.com/Lakr233/vphone-cli/blob/main/Documents/Downloads/README.md

[S7] 上游 Host setup／AGENTS：完整工程与预检，执行时使用锁定 checkout。  
https://github.com/Lakr233/vphone-cli/blob/main/Documents/Guides/host-setup.md  
https://github.com/Lakr233/vphone-cli/blob/main/AGENTS.md

[S8] 上游 Create and run：分阶段流程；本版未在最新二进制运行。  
https://github.com/Lakr233/vphone-cli/blob/main/Documents/Guides/create-and-run.md

[S9] 上游 Launchpad CLI；部分维护规则承接 v1.3，执行前以当前帮助验证。  
https://github.com/Lakr233/vphone-cli/blob/main/Documents/Guides/launchpad-cli.md

[L1] 发布候选元数据，非技术实现依据：GitHub Store 索引显示 2.13.5，日期 2026-10-26。  
https://git.hiwiki.org/en/repo/lakr233/vphone-cli

[L2] #751 原始标题／日期的转载索引，正文未取得，Open 仅为抓取快照。  
原址：https://github.com/Lakr233/vphone-cli/issues/751  
读取：https://githubhelp.com/Lakr233/vphone-cli  
日期补充：https://www.goodfirstissue.org/Lakr233

[U1] 用户此前提供的 Duo 固件页面与截图。  
https://ipsw.me/download/iPhone19,4/24A94425/

[B1] 2026-10-25 v1.3 制作与升级方案，本轮已全文读取；具体文件哈希见 EVIDENCE.json。

[G1] 实时上游发布与源码：`gh release list -R Lakr233/vphone-cli`（2.13.8 Latest，2026-10-26T18:57:02Z）；本地 `git describe --tags 7d633c9a` = 2.13.8。读取于 2026-10-27。

[G2] PR #728（`0xJacky:iphone-duo-x1`，draft，head `b03f0b82`，更新于 2026-10-26T18:58:35Z），全文 diff 已审阅后本地构建。  
https://github.com/Lakr233/vphone-cli/pull/728

[G3] Issue #751 正文（2026-10-27 读取时 open，更新于 2026-10-25T06:12:13Z）。  
https://github.com/Lakr233/vphone-cli/issues/751

[R1] 本机运行证据：`~/vphone-duo-m5/evidence/`（xcode、source-sha、cdhash、IPSW 哈希、preflight、目录）与 `~/vphone-duo-m5/run/`（各阶段日志、采样、截图、崩溃报告）。
