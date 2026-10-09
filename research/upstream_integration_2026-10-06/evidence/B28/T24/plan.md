# B28 T24 历史源码重建签名候选

所有本轮写入限于 `/private/tmp/vphone-b28-t24/`。仓库 HEAD 为 `3eea98a9e6b13efc4b9e477334bbcb6041ac978a`，最终产品源码基准为 `b4e80c57`。没有修改最终产品源码、台账、共享 `.build` 或 SwiftPM checkouts，没有读取仓库根 `TODO.md`。

## 已执行

历史源码取自 `dd3c800277605589ae1cb2466a2b33fa33e549d1`。仓库内 VPhoneArchiveKit、VPhoneBundleStore、VPhoneHelperKit 和 entry 共 19 个源码文件逐字取自 Git blob；加 Package.swift、Package.resolved、历史构建脚本，共 22 个文件。全部摘要在 `source-manifest.json`。生产 listener、auditToken 校验、逐消息签名要求和授权逻辑没有修改。

没有直接复用当前 helper objects，因为当前对象包含协议 2。使用独立 swiftc module cache / object / module 输出目录重编译历史仓库模块。外部 ArchiveKit.swift.o 和 module 复制自 B26 已冻结输入；其源码 checkout HEAD 为历史 Package.resolved 所列 `82687c75e530917b7fbeb15cd5f9369524637155`。复制的静态 libarchive framework 摘要也已保存。没有执行 SwiftPM。`otool -L` 的候选结果仅包含 Apple 系统框架和 `/usr/lib` 库，不含临时目录或外部动态 framework；无需为系统部署另放一个私有 framework。构建为 swiftc debug/WMO 重建，不是历史 release 构建复现。

两份临时副本以 SHA1 `5620D69F097306848C7CCD69F0B796A3C588BF28` 的 Apple Development 证书正常签名，Team 为 `3AA3QL69MQ`。这是 Apple Development，不是 Developer ID。没有出现钥匙串提示或超时，没有绕过授权。helper 与客户端均通过 `codesign --verify --strict --deep -R=<anchor apple generic + identifier + OU>`。helper 仅执行了普通用户的 `--check-configuration`，退出 0，输出 `configured: 3AA3QL69MQ, protocol 1`。没有执行无参数 helper。

| 对象 | SHA256 | CDHash |
| --- | --- | --- |
| 历史源码重建 helper `com.vphone.cli.helper` | `b9f7383e73892dbb6a89931ec233c84a4028dce4cc3a52a42ca34358e21723b4` | `c49d6e2018641d6aff8001310cca0d1a62420adb` |
| 最终客户端签名副本 `final-client.app/Contents/MacOS/vphone-cli` | `0422726dff884254f8c2cde09b4a59c28d73db7130e3f3746ed4cbc32cddb468` | `5160c4728d322314187a4cb187b3316d87087c6f` |

原 B13 adhoc 实物路径为 `.build/acceptance/B13/prior-helper-candidate/com.vphone.cli.helper`，SHA256 仍为 `bbc0917c2d5551de48b2eff7db8396c1c1d9a7d62f48eecdacf66a82da48b3c4`。当前 `.build/helper-candidate/com.vphone.cli.helper` 是另一份 SHA256 `728b03532d1792cf2ef54077ac98cbcece910a55b367d00af1e3178e383b60ce` 的产物，不能混用。

客户端原实物主程序 SHA256 为 `8d18f0e6a65dcd963c41a2c81c43f56922f425f708b0dba086778c7bbf458714`，全树 206 个文件签名前后重新核对，原实物保持不变。签名临时副本仅改变 `Contents/MacOS/vphone-cli` 和 `Contents/Info.plist`；其余 204 个文件（包括 VM、ldid、动态库和 `_CodeSignature/CodeResources`）摘要、权限及大小相同。只给临时 plist 添加 Team 和 SMPrivilegedExecutables，没有内嵌 v1 helper，未重签嵌套代码。

原始与去签名副本都保留。去签名主程序原始字节不完全相等：客户端仅 `__LINKEDIT.vmsize` 从 11141120 变为 11157504，helper 从 491520 变为 507904；其余全部字节一致。字段偏移通过 Mach-O load commands 解析得到，比较没有修改签名候选。具体原始 SHA、字段偏移和比较结果在 `candidate-summary.json`。

## 只读系统基线

`system-baseline-readonly.json` 记录：`launchctl print system/com.vphone.cli.helper` 退出 113；`/Library/PrivilegedHelperTools/com.vphone.cli.helper` 和 `/Library/LaunchDaemons/com.vphone.cli.helper.plist` 不存在；`security authorizationdb read com.vphone.cli.helper.privileged` 返回 `NO (-60005)`。本机 SDK AuthorizationDB.h 对 AuthorizationRightGet 的 -60005 定义为 `No definition found`。后续系统变更前必须重新读取，不能假定基线一直不变。

## 仅准备：系统部署及回滚

以下命令均未执行。它们会安装 root 所有文件、注册系统 Mach service、启动 root daemon，并由原生产 daemon 调用 AuthorizationRightSet 写入 `com.vphone.cli.helper.privileged`。需要另行获得系统变更授权；本轮没有请求或获得执行该段的授权。

最终协议 2 客户端的 `helper register` 会在读取 v1 内嵌 metadata 时拒绝，不能用它安装 v1。下面使用标准 system launchd 部署，目标是验证历史生产 listener 的身份校验及客户端协议协商；该路线不能验证 SMJobBless 注册。`System-Launchd.prepared.plist` 保留历史 Label/MachServices，补充标准 ProgramArguments 和独立 root 日志路径。它是外部 system launchd 部署配置，候选中的历史 `__launchd_plist` 保持原字节。

先重新保存 job、安装文件、授权项基线。若 job、任一安装路径或授权项定义与上面的“不存在”基线不同，停止，重新准备备份与恢复方案，禁止覆盖现存服务。再次核对候选 SHA、CDHash、签名及 --check-configuration。确认文件与目录不是符号链接，且 `/Library/PrivilegedHelperTools` 与 `/Library/LaunchDaemons` 为 root 所有；若不满足就停止。

准备执行的具体命令：

```zsh
# 系统变更：仅后续获得明确授权后执行
sudo install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools
sudo install -d -o root -g wheel -m 0700 /private/var/tmp/vphone-b28-t24-system
sudo install -o root -g wheel -m 0755 /private/tmp/vphone-b28-t24/com.vphone.cli.helper /Library/PrivilegedHelperTools/com.vphone.cli.helper
sudo install -o root -g wheel -m 0644 /private/tmp/vphone-b28-t24/System-Launchd.prepared.plist /Library/LaunchDaemons/com.vphone.cli.helper.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.vphone.cli.helper.plist
sudo launchctl kickstart system/com.vphone.cli.helper
launchctl print system/com.vphone.cli.helper
security authorizationdb read com.vphone.cli.helper.privileged
```

root daemon 运行后应保存实际 PID、磁盘 SHA/CDHash、root UID、Mach service、stdout/stderr 和授权项定义。授权项预期为 class=user、group=admin、authenticate-user=true、timeout=300、shared=false、allow-root=false、version=1；原生产源码还检查没有 rule 字段。任何项不一致就停止矩阵并回滚。不要修改 AMFI、TCC、Security 设置，不打开 UI，不降低 caller requirement。若签名身份未通过，只能记录拒绝，不能调整 listener 绕过。

按当前“不存在”基线准备的回滚命令：

```zsh
sudo launchctl bootout system/com.vphone.cli.helper
# 先保全本轮 stdout/stderr 和 job/授权项 readback 至证据目录，再移除独立日志目录。
sudo rm /Library/LaunchDaemons/com.vphone.cli.helper.plist
sudo rm /Library/PrivilegedHelperTools/com.vphone.cli.helper
sudo security authorizationdb remove com.vphone.cli.helper.privileged
sudo rm /private/var/tmp/vphone-b28-t24-system/helper.stdout.log /private/var/tmp/vphone-b28-t24-system/helper.stderr.log
sudo rmdir /private/var/tmp/vphone-b28-t24-system
launchctl print system/com.vphone.cli.helper
security authorizationdb read com.vphone.cli.helper.privileged
```

bootstrap 或 kickstart 失败时仍须回读 job、文件和授权项，按实际已发生的变更逐项恢复。日志不存在时不执行对应 rm。不要删除预先存在的父目录。恢复后必须验证 job 113、两安装路径缺失、授权项 -60005，helper PID 已退出，并复核原 B13 实物及原最终客户端文件摘要。若基线存在旧授权项，必须恢复其原始 plist，不能用 remove；本段方案当前只针对已记录的空基线。

## 仅准备：最终客户端六行矩阵

矩阵未执行，`six-row-matrix.prepared.json` 的六行全部为 `prepared_not_executed`。`matrix-commands.prepared.json` 保存完整 argv 和期望结果。每行使用独立目录，已有日志保存 SHA256、mode、owner、size、mtime_ns 后再执行。install 的 archive 先打开为只读文件；客户端源码在 requireVersion 后才调用 externalForm 和 outputReceiver。六行都必须得到准确的协议不匹配错误；连接失败、签名拒绝、超时和 crash 均不能计为协议拒绝通过。

| 实验设置 | 预期结果 |
| --- | --- |
| verify / 无日志 | 非零退出，明确协议不匹配 |
| verify / 新日志 | 非零退出，明确协议不匹配，新日志不存在 |
| verify / 已有日志 | 非零退出，明确协议不匹配，原文件全部基线属性不变 |
| install / 无日志 | 非零退出，明确协议不匹配，不请求管理员授权 |
| install / 新日志 | 非零退出，明确协议不匹配，新日志不存在，不请求管理员授权 |
| install / 已有日志 | 非零退出，明确协议不匹配，原文件全部基线属性不变，不请求管理员授权 |

该矩阵仅在真实 system Mach service 上执行才构成 T24 生产路径补充证据。本轮静态签名校验与配置检查不能证明运行时 auditToken 接受、逐消息身份通过、协议拒绝或日志行为。不要将旧受控 v1 harness 矩阵重复计为本轮新验收。
