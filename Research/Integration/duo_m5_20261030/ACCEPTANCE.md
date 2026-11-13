# VM acceptance record and remaining checks

## Current state and approval scope

The user approved closing `duo-m5-fold214` on 2026-10-30. Its original CLI
performed a normal stop (SIGINT), returned success, and both launch/VM processes
exited. lsof then found no open Disk.img/SEPStorage/nvram.bin handles.

After shutdown, its disk was 64,000,000,000 logical bytes and 27,766,452,224
allocated bytes. An APFS copy-on-write seed and two new-identity clones now
exist below `.build/acceptance/machines`. The source's inode/size/mtime/ctime
and small-state hashes did not change during copying. Clone disk inodes are
distinct; SEP/NVRAM hashes matched and clone identities were reset before
their first boots. Details: `runtime-preparation.json`.

Runtime preparation status:

1. Gracefully stopping the existing `duo-m5-fold214` VM: approved and complete.
2. Copying that stopped source into an isolated seed and creating baseline
   and candidate clones with new identities, entirely inside `.build`: complete.
3. Applying the matching bundle's offline CFW environment update to each clone:
   complete, through the user's Terminal execution of `prepare-root.zsh`.
4. Allowlisting the two built `vphone-vm` binaries through `vphone-escalator`:
   complete in that same run. The marker is dated 2026-10-30T07:29:53Z.

Both update logs ended with successful environment-update messages. Both
receipts contain the same 54 Guest patches, including fold display/guard;
the optional inner cutout patch is absent. The allowlist output contains
both expected VM CDHashes from `validation.json`.

These actions do not include deleting a source VM, rebuilding/restoring its
disk, pushing branches, or merging into `main`. The user's repository-external
modification approval gate remains in effect.

## Completed setup commands

Use absolute paths from `validation.json` for the final candidate, and the
preserved baseline at `.build/validation/baseline/artifacts/VPhone.bundle`.
The stop/copy/clone commands below are retained as an execution record and
must not be repeated against the existing directories. The user has run
the root commands. Their reviewed wrapper verifies outer bundle CDHashes, CLI/VM binary
hashes, signatures and stopped state before invoking sudo:

```zsh
zsh /Users/kolar/github/vphone-cli/.worktrees/duo-integration-20261030/Research/Integration/duo_m5_20261030/Regression/prepare-root.zsh
```

The user ran it in Terminal so sudo could authenticate there. `--check` runs
read-only checks without invoking sudo; that mode passed before execution. The default run
updates only the two isolated clones and allowlists the two recorded VM
binaries. It saves logs and patch receipts and writes
`.build/acceptance/root-steps-complete.json` only if all three steps succeed.

```zsh
repo=/Users/kolar/github/vphone-cli/.worktrees/duo-integration-20261030
old_cli=/Users/kolar/github/vphone-cli-up/.build/fold214/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli
baseline="$repo/.build/validation/baseline/artifacts/VPhone.bundle"
candidate="$repo/.build/XcodeDuo/Build/Products/Debug/VPhone.bundle"
library="$repo/.build/acceptance/machines"

# Only after permission to stop the existing VM; verify stopped state before copy.
"$old_cli" vm stop duo-m5-fold214
test ! -e "$library"
mkdir -p "$library"
cp -cR /Users/kolar/.vphone/machines/duo-m5-fold214 "$library/seed"
"$candidate/Contents/MacOS/vphone-cli" vm clone seed duo-baseline-20261030 --new-identity -l "$library"
"$candidate/Contents/MacOS/vphone-cli" vm clone seed duo-candidate-20261030 --new-identity -l "$library"

# Run the root steps in the user's Terminal after reviewing their exact paths.
sudo "$baseline/Contents/MacOS/vphone-cli" cfw update-environment duo-baseline-20261030 -l "$library"
sudo "$candidate/Contents/MacOS/vphone-cli" cfw update-environment duo-candidate-20261030 -l "$library"
sudo "$candidate/Contents/MacOS/vphone-escalator" allow \
  "$baseline/Contents/MacOS/vphone-vm" "$candidate/Contents/MacOS/vphone-vm"
```

The copies and root steps are complete. Any later root action still needs
concrete preparation and authorization for its particular scope.

## Runtime checks

Run one clone at a time using its matching CLI and `-l "$library"`.
Capture boot logs and time to vphoned. Once its socket answers:

```zsh
zsh Research/Integration/duo_m5_20261030/Regression/vm-smoke.zsh \
  "$library/duo-baseline-20261030/vphone.sock" \
  "$repo/.build/acceptance/baseline-smoke-1"
```

Repeat with the candidate socket and a new candidate evidence directory.
The script asserts RPC success, six supported hinge/rotation combinations,
two upstream-defined unsupported physical poses, stable SpringBoard/backboardd
processes, and locked state after a fold in the dark. Unsupported pose checks
require the exact structured error and unchanged orientation. Geometry and
screenshots are recorded for assessment; syntax validation alone is not
runtime evidence. `Regression/probe-run.zsh` adds installd installation,
app-owned geometry, CSSC correctness, and focused-field continuity checks.

New execution results and limits are recorded in [RUNTIME.md](RUNTIME.md).

The remaining acceptance matrix includes:

- F0 display model and DeviceHub/RPC posture agreement.
- F2 focused-field behavior, soft/hardware keyboards, cart/navigation continuity.
- F3 both touch paths, directions, edge gestures, and coordinate error.
- F4 lock/power, folds while dark, rapid reversal, no stale unlocked content.
- F5 lit-screen transition frames separately from intentional dark/wake fades
  and app launch cards; use repeatable recording and action timestamps.
- F6 repeated cold starts, 120-minute locked idle, snapshots, full export/import
  including allocation and imported boot, then host restart when authorized.
- Networking, installd IPA installation and launch, and audible audio checks.
- Static `outer` / `inner` / `fold` changes and patch on/off/on behavior on
  disposable clones. Static-inner compatibility on the new upstream device
  tree is not yet established by this integration.

The local `fb41cd6b` hold was not active in this candidate. It was ported to
the current upstream hooks on 2026-11-13; see "F5 上一帧保持验证" below.
Host restart, account-dependent application checks, and any additional root
actions need their own concrete preparation before execution.

## Duo 27.1 运行验收

本轮比较 `4cb164c8` 与 `84e3ce54`，两组固定 iPhone19,4、iOS 27.1
（24A94425）和 cloudOS 26.4（23E5207q）。两台副本来自同一份停机种子，
首次启动各自生成机器身份。补丁收据、补丁选择、配置、SEP、NVRAM 的起始
内容一致；两台副本与种子的磁盘 inode 各不相同。

| 组 | 源码 | 隔离副本 |
| --- | --- | --- |
| A | `4cb164c8773a530c4e463ea654428d5825c0f1c6` | `duo-baseline-4cb164c8` |
| B | `84e3ce54a30836b0220bc95b910afeed587dc83b` | `duo-upstream-84e3ce54` |

两组均从干净检出构建。Bundle 的 `VPhoneBuildHash` 与表中提交匹配，
且 `codesign --verify --deep --strict` 通过。当前宿主上的两次
`host preflight` 均返回 AMFI 拒绝（`-424`）。日志及二进制 SHA-256 位于
`.build/duo-runtime-84e3ce54/`。两台副本仍处于停机状态，未更新 guest 环境。

拒绝原因是宿主准入，不是构建或签名方式：

- 本机走 `vphone-escalator allow` 路径（SIP 自定义配置、调试限制关闭、
  Research Guests 开启、无 boot-args）。`allow` 把 cdhash 写入
  `/Library/Preferences/com.apple.security.coderequirements.plist`，
  并改 amfid 堆中一个字节让它读取该要求。偏好文件跨重启保留，堆补丁不保留。
- 2026-11-13 核对：宿主自 11-01 未重启，但 amfid 在 11-09 22:59 单独重启，
  堆补丁随之失效。偏好文件仍有 11-04 的 16 个 cdhash，所以未改动的旧 Bundle
  也被拒绝。与 [F6 宿主重启记录](F6.md) 是同一机制。
- 两组 `vphone-vm` 的 cdhash 不在偏好文件中：A `57e1c81172f9dbf679312fa593ac131b21593b0d`，
  B `85ddbef7f7d046205cd7b12354f020bd182c0c10`。
- ad hoc 签名带私有虚拟化权限正是该路径的设计用法，不需要换签名身份，
  也不需要重建 VM 或 guest。

修复：对两组各执行一次（需在用户终端用 sudo）：

```zsh
for sha in 4cb164c8 84e3ce54; do
  b="$run/source-$sha/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS"
  sudo "$b/vphone-escalator" allow "$b/vphone-vm"
  "$b/vphone-cli" host preflight
done
```

2026-11-13 00:22 CST 已执行（amfid 仍为 pid 3682，未再重启）：两次 `allow`
均 exit 0，偏好文件追加 A、B 两个 cdhash，`status` 显示
`requirement in force: the preference's Entitlements`；随后 A、B 的
`host preflight` 均为 `Host preflight passed: vphone-vm can launch`。
两台副本仍停机，guest 环境尚未更新。

2026-11-13 00:24 CST 用各组 Bundle 执行 `cfw update-environment`，日志、
前后 `PatchReceipt`/`PatchSelection`/`PatchPlan` 位于
`.build/duo-runtime-84e3ce54/results/env-update-20261113-002450/`：

| 组 | exit | vphoned SHA-256 | 收据变化 |
| --- | --- | --- | --- |
| A | 0 | `9dbc9b45…5c9be3dbf4` | 2.14.1 → 2.15.2，54 → 55 项 |
| B | 0 | `afde7444…5e70ce65` | 2.14.1 → 2.15.2，54 → 55 项 |

- 两组 `PatchSelection` 与 `PatchPlan` 均未变；新增的一项都是
  `system-paravirt_gpu-cfw-primitive_restart`。更新后 A、B 收据只有 `Date` 不同。
- 两组均报告 `restored the seal 6067 other bundles share`（共享封条修复），
  无 `[!]`/错误行。
- 启动后核对 guest 内 vphoned 哈希与上表一致。

宿主重启、amfid 重启或重新构建后都要重跑 `allow`。cdhash 未变却出现
`-424` 时，先用 `ps -o lstart -p $(pgrep -x amfid)` 看 amfid 启动时间。

从仓库根目录设置路径。下面以 B 为例；测试 A 时成对替换 `bundle` 和 `machine`：

```zsh
root="$PWD"
run="$root/.build/duo-runtime-84e3ce54"
library="$run/machines"
reg="$root/Research/Integration/duo_m5_20261030/Regression"
sha=84e3ce54
machine=duo-upstream-$sha
# A: sha=4cb164c8; machine=duo-baseline-$sha
bundle="$run/source-$sha/.build/XcodeBundle/Build/Products/Debug/VPhone.bundle"
cli="$bundle/Contents/MacOS/vphone-cli"
socket="$library/$machine/vphone.sock"
out="$run/results/$machine-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
codesign --verify --deep --strict "$bundle"
test "$(plutil -extract VPhoneBuildHash raw -o - "$bundle/Contents/Info.plist")" = "$sha"
"$cli" host preflight
print -r -- "$out"
```

预检通过后，使用各组的 Bundle 更新对应停机副本的
guest 环境（`cfw update-environment "$machine" -l "$library"`）。保存更新日志
和补丁收据，核对已部署的 vphoned 和补丁选择，再启动：

```zsh
"$cli" vm launch "$machine" -l "$library" -v
```

在另一个终端设置同一组变量，沿用第一终端打印的 `out`，等 SpringBoard 稳定后执行：

```zsh
# A 省略 --active-display；新增原生捕获 RPC 只在 B 中要求通过。
VPHONE_EXPECTED_DAEMON_SHA256=$(shasum -a 256 "$bundle/Contents/Resources/guest-resources/vphoned" | awk '{print $1}') \
  zsh "$reg/vm-smoke.zsh" "$socket" "$out/smoke" 6 --active-display
zsh "$reg/f3-touch.zsh" "$socket" "$out/f3-touch"
zsh "$reg/f3-edge.zsh" "$socket" "$out/f3-edge"
zsh "$reg/f5-record.zsh" "$socket" "$out/f5"
zsh "$reg/f5-analyze.zsh" "$out/f5"
```

- **显示与旋转**：检查内外屏的原生 PNG 和捕获回执中的 `identity_binding`；
  分别记录 UUID 与无 UUID 路径实际覆盖情况。另测仅竖屏 App、旋转锁和熄屏：
  分别记录请求结果、`degrees`、可用时的 `device_degrees` 和唤醒后的界面；
  不把 Duo 专用铰链路径等同于通用加速度计路径。
- **F2**：两组使用同一份 `food_ordering.ipa`（`com.autophone.foodorderingdemo.v2`，
  `UIRequiresFullScreen=false`；已核对本地包 SHA-256
  `610fc702fc43e867d35237bf3a23cf10e1e38b59b8e473a4805ffe63526b6885`）。
  经 installd 安装，启动后聚焦 Email 并输入测试文字，不提交表单。保持焦点
  从内屏合拢，记录画面、AX 树、前台 App 和 PID；再验证外屏实际可输入且展开后
  内容仍在。分别测试硬件和软件键盘，并保留合拢前结束编辑的对照。
- **F5**：分析脚本生成黑帧时间表；另按原始录制记录停帧、首次有效输入和锁屏
  撤层。没有输入证据的片段不计入首次有效输入结果。录制脚本按所选 VM 的
  保存对话框定位视频，复制到验收目录并保留原文件。
- **维护**：检查环境更新是否报告共享封条修复，验证音频和 Instruments 能否
  显示具名调用栈。已转换的种子可以覆盖现有 undo 的再更新，不能算作本轮重测
  旧 JSON 迁移。

本文件的命令仅针对上述隔离副本。运行结果以每组日志为准。

### 27.1 A/B 运行结果（2026-11-13）

证据位于 `.build/duo-runtime-84e3ce54/results/runtime-ab.oXsZCNyW/`。
两组宿主预检均通过，各冷启动一次；guest 中运行的 `vphoned` SHA-256
分别与固定的 A、B 构建一致。两份更新后收据仅 `Date` 不同。

| 用例 | 实测结果 |
| --- | --- |
| 基础回归 | 两组各通过 6 次开合、6 个受支持的旋转组合、2 个预期的姿态拒绝，以及熄屏开合后保持锁定。两组 SpringBoard 和 backboardd 的 PID 在用例前后均一致。 |
| B 原生捕获 | 外屏 1398×2034 PNG，走无 UUID 的显示绑定路径；内屏 2007×2853 PNG，走 UUID 匹配路径。 |
| F2 聚焦合拢 | 两组已安装测试 App 的 Info.plist 完全相同，且 `UIRequiresFullScreen=false`。硬件和软件键盘各测一次：两组外屏合拢后都读到原文字，均可追加字符，展开后文字保留，前台 App 的 PID 不变。未提交表单。 |
| F3 点击 | 两组各有 40/40 宿主点击及 40/40 guest 点击到达测试页面。外屏两组均报告 466×678 点；展开至竖屏时 A 的 `device.screen` 仍报 466×678 点，B 报内屏的 669×951 点。 |
| F3 边缘手势 | 两组的宿主路径内外屏各 3/3。首次 guest 边缘事件测试中，B 内屏为 1/3，失败时已转到横屏。随后每次固定并直接回读方向，A、B 内屏均为竖屏 3/3、横屏 0/3。因此首次 1/3 不计作 B 独有回归。普通 guest swipe 在两组均未触发 Home 手势。 |
| F5 窗口录制 | 两组都保存了约 31 秒的宿主窗口录制，电源事件和随后的展开后均保持锁定。对前 12.5 秒的窗口内容区域取样，A 出现 1 段近黑，B 出现 3 段，单段约 0.21–0.25 秒。宿主窗口输出包含缩放和填充，且采集时的窗口可见状态不同；不能据此判定原生呈现流的黑帧、停帧或首次有效输入时延。 |

F5 宿主窗口视频分别为 `A-f5-window-retry/recording.mov` 和
`B-f5-window-final/recording.mov`；手势定向复测的记录为
`A-edge-controlled/result.tsv` 和 `B-edge-controlled/result.tsv`。

### F5 原生录制和 Instruments 复测（2026-11-13）

证据位于 `.build/duo-runtime-84e3ce54/results/follow-up.kXAVdpz2/`。
两套固定 Bundle 分别冷启动，用同一个 VPhone 录制菜单和同一份
`native-actions.zsh`，录制 `VZGraphicsDisplay`，两组视频均为
1398×2034、标称 30 fps。每次启动仅为该进程指定工作区录制目录，
在桌面界面启动和停止录制；两份视频均写在工作区。

| 项目 | A | B |
| --- | --- | --- |
| Home Screen 6 次开合，共 12 次转换 | 1/12 检出黑帧，共 4 帧 | 12/12 检出黑帧，共 47 帧；每次 2–6 帧 |
| 整段动作回执 | 19/19 成功 | 19/19 成功 |
| 电源事件及展开后锁定状态 | 两个检查点均锁定 | 两个检查点均锁定 |
| SpringBoard、backboardd、audiomxd | 前后 PID 一致 | 前后 PID 一致 |

黑帧使用同一 FFmpeg 像素阈值统计，动作与视频用文件创建时间近似对齐；
数字表示采样帧数，不是精确墙钟时延。两组 FoldDisplay dylib 的
SHA-256 完全一致，录制器和图形采集器源码在两提交间无变化。本次证据
表明 B 的这组转换更频繁检出黑帧；原因未查明。未用静止 Home Screen
画面推断停帧时长。本地 Safari 输入探针在 A 上未收到预热回执，
不计为首次有效输入时延结果。保留 F5 验收项。

B 在 developer tunnel 关闭时被 Instruments 列为离线；对该隔离副本
启用 tunnel 后重新启动，Instruments 列为在线。5 秒 SpringBoard
Time Profiler 录制、导出均成功，导出含 16 个 binary 记录和具名帧
（例如 `-[SBSceneRegionsUpdater poseProvider:didUpdateFromPose:toPose:]`）。
音频状态回执在两组均可读取，未验证实际听感。测试结束后两台副本均已
正常关机，B 的 developer tunnel 已恢复为关闭。

RPC、GLES、27.2 三套后续候选复查宿主预检仍被拒绝。未启动它们，
也未混入本次 27.1 对照。

### F5 最小复测

用同一个 B 构建和隔离副本重新冷启动，录制前核对外屏、竖屏和亮屏。
动作仅保留主屏幕上的六次开合，不启动 Safari，不发送电源事件。
结果为 **1/12 次转换检出黑帧，共 4 帧**，均出现在首次展开。
这与前一次 A 的观测相同。B 的前一轮 47 帧仍是有效记录，但现有实验
不足以认定它是可稳定复现的 B 独有回归，也不能据此认定差异已消失。

证据和动作脚本在 `.build/duo-runtime-84e3ce54/results/f5-repro.onBEyTGO/`。
`Regression/f5-analyze.zsh` 现在单独输出 `fold-blackframes.tsv`；
用同一统计规则回放三份原生录像，依次得到 4、47、4 个样本。
录制器以已接受的帧序号生成 30 fps 时间戳，掉采样时视频时轴会压缩；
FoldDisplay 日志尾部使用本地时钟文本，现有分析器未能从其中提取可对齐的
事件。因此三个结果只用于比较帧样本，不能确认黑帧位于哪一步，也不能
换算成实际停帧时长。下一轮需记录每次开合前后的姿态、显示归属，
以及与录制帧共用时钟的时间标记。B 已正常关机。

### F5 同时钟采样

证据位于 `.build/duo-runtime-84e3ce54/results/f5-clock.mgQC6WgC/`。
`Regression/f5-clock.mjs` 记录姿态请求、方向回执和宿主呈现截图请求的
单调时钟时间；`Regression/f5-clock-report.mjs` 解码截图并按同一阈值
统计近全黑样本。使用原 A/B Bundle，启动后核对 guest daemon 哈希。

| 实验设置 | A | B |
| --- | --- | --- |
| 外屏竖屏起步，默认姿态参数 | 前 6 次转换中 3 次检出，4 个样本 | 6 次全部检出，10 个样本 |
| 分别指定内外屏姿态，以保持界面方向 | 冷启动复测 3/6 检出；仅采到 0° 的 4 次中 2 次检出 | 5/6 检出；6 次均只采到 0° |

旋转锁试验中，B 已回报锁开启，开合时仍读到 0° 与 90° 交替，
因此该轮不能当作固定方向对照。分面板指定姿态后，两组都能在采样方向
仅为 0° 的转换中检出黑帧；持续的界面方向变化不是必要条件。截图采样
不能排除两次请求之间未观测到的短暂变化。A 也有黑帧，B 在本轮同条件
样本中检出更频繁；两组采样间隔不同（分面板指定姿态时最长间隔
A 722 ms、B 414 ms），不能把未检出当作没有黑帧，也不能把时间区间
当作停帧时长。仍需在同一次开合中比较 guest 合成输出和宿主呈现输出，
定位近黑内容最先出现在哪一侧。当前未确认根因，未修改产品逻辑。

### F5 guest 和宿主配对采样

证据位于 `.build/duo-runtime-84e3ce54/results/f5-dual.fY4FmPHO/`。
使用原固定构建。每组执行三次展开和三次合拢，按面板指定姿态以维持
竖屏；仍以每次回读为准。两个截图请求并行发出，保留同一宿主单调
时钟上的发送和收包时间。

| 构建与 guest 捕获 | 宿主近黑样本 | guest 近黑样本 | 两边均检出的转换 |
| --- | ---: | ---: | ---: |
| B，按显示身份绑定的原生 PNG，第 1 轮 | 5 | 2 | 2/6 |
| B，按显示身份绑定的原生 PNG，第 2 轮 | 5 | 4 | 3/6 |
| B，普通 guest JPEG | 7 | 28 | 3/6 |
| A，普通 guest JPEG | 9 | 40 | 6/6 |

B 的 6 张近黑原生 PNG 逐像素检查均为不透明纯黑，包含 LCD（ID 1）
和 VPhone Duo Inner（ID 7）。五次两边均检出的原生捕获转换中，
guest 与宿主黑样本请求区间均有重叠。guest 原生捕获另有 9 个请求因
显示身份或几何在捕获期间变化而拒绝。JPEG 无显示 ID，宿主呈现截图
也不报告对应的 guest 显示 ID；两类截图间不能做逐面板的像素对应。

guest 截图路径本身能产生黑色画面，宿主录制编码不是这些样本的唯一
来源。请求区间包括图像处理和传输，且两条采集路径可能影响采样间隔；
无法由这些区间确定先后，也不能由样本数比较真实黑屏时长。相同 JPEG
路径在 A 也能检出，未证明 B 独有回归。下一步要区分 SpringBoard
切屏淡出和共享 scanout 交接：在 guest 内记录淡出开关、面板归属切换
和首次有效合成帧的单调时钟时间。现有固定 Bundle 没有这组事件；
修改 guest 或宿主采集逻辑后需要单独的验证构建，不能替代本轮证据。
两台隔离副本均已正常关机。

### F5 部分原因：面板交接时共享 scanout 被关闭

以下分析最初基于代码和现有日志；后面的“保持点亮验证”已上机复测，
结论是这只是部分原因。`FoldDisplayPanel.m` 中，主屏
CADisplayStateControl（显示 1）是唯一 scanout，其状态取当前所有者的
“期望状态”：内屏所有时取 `vpInnerWantedState`，外屏所有时取
`vpPrimaryWantedState`。归属在 `handleSwapTransition…` 或内容模式转换
时立即切换，但 SpringBoard 点亮新所有者的请求晚于切换：

- 合拢：展开时 SpringBoard 已把显示 1 设为 0。归属切到外屏时
  `vpPrimaryWantedState` 仍为 0，FoldDisplay 自己调用原始
  `transitionToDisplayState:0` 关闭 scanout，并移除内屏图层；
  直到 SpringBoard 发出 `display 1 wants state 1` 才重新点亮。
- 展开：合拢约 3 s 后 SpringBoard 把折走的内屏设为 0
  （`display 7 wants state 0`）。之后再展开，归属切到内屏时
  `vpInnerWantedState` 仍为 0，scanout 同样被关闭，直到
  `display 7 wants state 1`。

这些自发的关闭不写日志。现有四份 `folddisplay.log` 中，每次合拢都按
`panel owned by the cover` → `shown=0` → `display 1 wants state 1`
的顺序出现，两者有时跨越秒边界，例如 B 的 `1:10:22` → `1:10:23`。
展开出现同样问题的，都是前面已有 `display 7 wants state 0` 的那次，
例如 `7:44:56` 之后的 `7:45:26`，以及 `1:10:19` 之后的 `1:10:20`。
这与“首次展开检出黑帧”的最小复测一致。显示断电时，guest 合成截图
可得到不透明纯黑，宿主呈现截图也会变黑，与 A、B 两侧都能检出、
与界面方向无关的结果相符。A、B 共用同一 FoldDisplay，因此不是 B 独有
的问题。历史 fold214 日志中，合拢时 `display 1 wants state 1` 先于或
同毫秒于归属切换，当时没有这段空窗。

第一步改动：归属切换时，若面板已亮而新所有者的期望状态
为 0，保持 scanout 和内屏点亮（`handoff held`）。新所有者收到请求、屏幕
变为 blanked 或 2 s 超时后释放（`handoff released (…)`），并按真实期望
状态重新应用。该保持只会让面板保持点亮，不会主动关闭面板。日志时间戳
改回毫秒级 epoch 秒，使 `Regression/f5-analyze.zsh` 的 `events.tsv`
重新可用。这正是 `fb41cd6b` 两部分中的“不提前关输出”；“保留上一帧”
部分在下一步恢复，见“F5 上一帧保持验证”。

### F5 保持点亮验证

证据位于 `.build/duo-handoff-84e3ce54/results/f5-handoff.La88rNRC/`。
Bundle 由 `.build/duo-handoff-84e3ce54/source` 构建：`84e3ce54` 加上上述两份
FoldDisplay 改动，guest vphoned SHA-256 `6c565d2b…`。副本
`duo-handoff-84e3ce54` 由 B 的停机副本 `--new-identity` 克隆，执行
`cfw update-environment` 后冷启动；B 本身未改动。

| 同时钟采样，分面板指定姿态保持竖屏 | 检出转换 | 近黑样本 |
| --- | ---: | ---: |
| B（前一轮） | 5/6 | — |
| 保持点亮，第 1 轮 | 3/6 | 12 |
| 保持点亮，第 2 轮 | 2/6 | 5 |
| 保持点亮，第 3 轮 | 4/6 | 6 |

guest 日志显示保持按设计生效：全部 `handoff held` 都以 `asked` 释放，
未见 `timeout`，保持时长 40–120 ms。也就是说，交接期间 scanout 一直
未关闭，但黑帧仍然存在。例如第 1 轮首次合拢在动作后 68–222 ms 检出，
晚于 `cover asked`。因此 scanout 断电只是部分原因；其余黑帧来自内容
本身，如外屏场景移出 Main 后尚未重绘，或内屏重新点亮后的最初几帧。
这正是 `fb41cd6b` 保留上一帧所处理的部分。

两点采样缺陷影响以上计数：

- 快速开合（约 0.8 s 一次）时，SpringBoard 会合并部分折叠。第 3 轮
  6 次转换只记录到 4 次归属切换；第 2 轮只有前 3 次有记录。部分“未检出”
  实际没有发生交接。
- 两轮 guest 原生配对采样（`native-1`、`native-2`）在首次展开后，
  所有捕获都来自内屏（ID 7），包括“合拢”试验，也没有外屏归属切换。
  这两轮不能作为交接证据。其中唯一的黑样本是首次展开：宿主 2 个，
  guest 内屏 1 个，发生在保持释放之后。

手动慢速开合（间隔 2 s）可正常交接，在 40–75 ms 内以 `asked` 释放。
下一步若继续，需要先让采样器校验每次转换确有归属切换（读 guest 日志
或 `display.capture_active` 的显示 ID），再决定是否恢复 `fb41cd6b` 的
上一帧保持，并复测 F4 锁屏用例。副本已正常关机。

> 补记：`duo-handoff-84e3ce54` 后来确认处于持续异常状态，即使换回 84e3ce54
> 的 FoldDisplay 也会停止响应折叠（见下节）。本节在该副本上的计数仅供参考。

### F5 上一帧保持验证

2026-11-13 决定恢复 `fb41cd6b` 的上一帧保持，取代 2026-10-30 的不移植
决定。改动在 `VPhoneGuestComponents/FoldDisplay/FoldDisplayPanel.m`，
说明见 `Research/0_binary_patch_comparison.md` 末节。要点如下：

- SpringBoard 开始内容模式转换时，把 Main 渲染进独立 IOSurface，盖在
  Main 的 `UIRootSceneWindow` 最上层。
- 展开时，内屏渲染出现非黑内容后再等一帧释放；合拢时，外屏取回主场景
  150 ms 后释放。
- 最长保持 2 s；面板断电或屏幕 blanked 时立即释放。
- 面板关闭、刚点亮不足 1 s，或屏幕 blanked／解除 blanked 不足 1 s 时
  不保持，暗屏开合仍由上游的淡入淡出处理。
- 上节的“保持点亮”一并保留。

采样器同时补充了两项功能：`f5-clock.mjs --settle=<ms>`，以及记录单调
时钟原点对应 epoch 的 `clock.json`。新增 `Regression/f5-handoff-report.mjs`，
逐次转换对照 guest 日志中的归属切换、保持起止和释放原因。

**副本异常的排查。** 在 `duo-handoff-84e3ce54` 上，SpringBoard 会在
数次开合后长时间不响应折叠：hinge HID 回报 `applied:true`，但没有
归属切换，也没有电源请求，最长持续约 95 s。用诊断开关逐项关闭
“提前点亮内屏”“保持点亮”“上一帧保持”后，该副本仍然停滞；冷启动
后同样如此。交叉对照的结果：

| 副本 | FoldDisplay | 有效交接 |
| --- | --- | ---: |
| `duo-handoff-84e3ce54`（多次更新环境、数百次开合） | 84e3ce54 原版 | 6/18 后停滞 |
| `duo-ctrl-84e3ce54`（B 的新克隆） | 84e3ce54 原版 | 18/18 |
| `duo-diag-84e3ce54`（B 的新克隆） | 上一帧保持（诊断版） | 18/18 |

因此停滞来自旧副本自身的持续状态，与 FoldDisplay 改动无关。诊断开关
未进入最终版本。

**最终验证。** 证据在 `.build/duo-handoff-84e3ce54/results/f5-final.*/`。
Bundle `bundles/final` 由 `84e3ce54` 加 FoldDisplay 改动构建，
FoldDisplay SHA-256 `86ecf0de…`。副本 `duo-final-84e3ce54` 是 B 的新克隆，
冷启动后连续执行三轮，每轮 6 次转换，转换间隔 4 s，分面板指定姿态以
保持竖屏。

| 构建 | 有效交接 | 检出近黑的转换 | 近黑样本 |
| --- | ---: | ---: | ---: |
| 对照：84e3ce54 FoldDisplay（`duo-ctrl`，三轮） | 18/18 | 10/18 | 15 |
| 上一帧保持（`duo-final`，三轮） | 18/18 | 0/18 | 0 |
| 上一帧保持诊断版（`duo-diag`，三轮） | 18/18 | 0/18 | 0 |

保持时长和释放原因：

- 合拢 237–259 ms，全部以 `cover redrawn` 释放。
- 展开 198–721 ms，全部以 `inner display drawn` 释放。
- 18 次“保持点亮”均以 `asked` 释放，没有超时。

保持期间画面停在交接前一帧，这是消除黑帧的代价。

锁屏用例（每项两次）：

- 展开或合拢后 0.1 s 按电源：最终均为锁定且熄屏，唤醒后显示对应面板
  的锁屏。一次合拢的“保持点亮”因 `screen blanked` 提前释放。
- 先按电源使屏幕 blanked，再展开：不出现上一帧保持，唤醒后为内屏锁屏。
  上一版诊断构建在这种情况下仍会保持，已加入 blanked 时间判断修正。

未覆盖的项目：带 App 前台（Safari）的开合，v1.6 记录这时保持为
0.9–1.4 s；常亮锁屏下的开合；DeviceHub 连续扫动。四台测试副本均已
正常关机。

## 后续独立候选

以下候选均以 `84e3ce54` 为父系。前面的 A/B 继续使用原始固定构建。
候选源码和验证日志在 `.build/duo-next/`。
RPC 和 GLES 使用该目录下的 `machines/duo-rpc-271` 与
`machines/duo-gles-271`。这两台停机副本的起始配置与 27.1 B 组一致，
磁盘 inode 独立。三套后续候选均通过构建和签名校验，均被当前宿主的
AMFI 预检拒绝，原因同上：各自的 `vphone-vm` cdhash 尚未 `allow`。运行前
对各自 Bundle 执行 `vphone-escalator allow`。上游文档中的实机结果不计为本地验收。

| 候选 | 提交和本地源码目录 | 运行条件与验收 |
| --- | --- | --- |
| Duo RPC 目录 | `7ef638b4`，`source-rpc` | 27.1 A/B 后，用隔离副本查询 `methods.list`，确认 `scope=duo_display`、`complete=false`，比对两块屏的实际字段和类型。另测 AX 点击、Auto-Lock、未知方法报错。 |
| Duo 27.2 | `5ff0a0fe`，`source-27.2` | 用独立的 24B91020 VM。冷启动后保持铰链静止，晚启动 WDA 后读角度；退出并重启 WDA 后再次读取。两轮均不得先改变角度或重启 locationd。另测开合、旋转、锁屏与唤醒、声音和静音切换。 |
| GLES | `b36c11ba`，`source-gles` | 用独立的 27.1 副本，先核对正在使用的内核和 GPU 相关补丁收据。现有 27.1 种子的 `fw patches` 把 `kernel-cfw-paravirt_gles_renderer` 列为计划启用但未记录应用；仅更换 Bundle 不会改变内核。核对后在副本上按组件更新，记录 GLES 深度、点绘制、冷暖 shader cache、补丁撤销和原生 Metal 对照。 |

每组源码目录内的 Bundle 位于 `.build/XcodeBundle/Build/Products/Debug/VPhone.bundle`。
已验证的增量 Git bundle 为 `duo-rpc.bundle`、`duo-27.2.bundle` 和 `duo-gles.bundle`，
均以 `84e3ce54` 为导入前提。

GLES 已在 24A94425 的真实 DSC 副本上完成深度补丁的试运行、应用和撤销。
撤销后全部 82 个文件的 SHA-256 与应用前一致，包括原有 X1 undo 的
`.json` 和 `.words`。证据为 `gles-cache-*.log` 和
`gles-cache-{before,applied,reverted}.sha256`。该实验仅覆盖 DSC 的写入和撤销，
不能证明 guest 的图形输出或 GPU／compiler 环境更新成功。

DriverKit 单独评估：先确认故障是否发生在设备枚举。早期 27.1 Duo
已记录宿主和 guest 两条输入路径在 F3 共收到 80 次点击；这不覆盖新候选，
也不支持把先前状态栏截获归为虚拟 USB 枚举失败。调试库 X1 lowering
在有独立调试库失败证据时评估。TXM 和 Cryptex 保留在新制机评审范围。
