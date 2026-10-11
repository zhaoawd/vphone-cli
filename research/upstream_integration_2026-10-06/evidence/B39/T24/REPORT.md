# B39 / T24 继续记录

日期：2026-10-11。实现提交：`3f50c591add2d8af6d9aceeb60db2be8ef05f365`。T24尚未验收。当前完成本地布局修复、相关离线回归、实际签名候选与运行准备；系统store安装和完整TCC链等待本轮批准。源VM、研究副本及现有AMFI会话未被本轮修改。

## 问题、原因与修改

事实：`sources/Info.plist`声明 `VPhoneBoundLaunchProtocol=vphone.local-bound-launch.v1`，本地构建没有 `vphone-escalator`；此前 `requireBundleLayout` 无条件要求该文件。新回归在原逻辑上出现3项断言失败：本地布局不能安装，未知协议却被接受。失败日志为 `layout-red-pinned.txt.gz`。该结果确认当前本地候选不能直接安装到 store；没有据此判定TCC问题原因。

修改：store与VM入口共享协议常量。仅已知签名协议且主程序为vphone-cli的本地布局要求CLI/VM；无marker的旧布局继续要求escalator，未知marker或错误主程序拒绝。所有权、ACL、链接、架构、完整签名、摘要、receipt和锁定执行检查沿用原实现。没有新增特权verb或通用执行入口。

回归包含6项新布局测试及1项可选实际冻结归档测试。首次扩展回归的失败是测试夹具重复创建input.tar；修改为独立tampered.tar后，签名拒绝和0777目录拒绝断言通过。该失败及重跑日志均保留。首次依赖解析漏加force-resolved-versions，SwiftPM改写3项传递依赖；已停止自己的构建进程组、恢复原锁文件，该次结果不计入验收，见dependency-resolution-trial.json。

## 验证

| 命令 | 结果 | 范围 |
| --- | --- | --- |
| swift test --disable-sandbox --force-resolved-versions --cache-path .build/research-b39/swiftpm-cache --filter 'LocalBundleLayoutTests\|CoreBundleStoreTests\|LauncherPolicyTests\|LaunchRouteTests\|ExpectedBindingCLITests\|ToolchainTests' | 52项通过 | store/policy及调用方route、冻结选择、签名toolchain；不启动VM |
| 同上，filter 'FrozenLocalHostBundleTests\|LocalBundleLayoutTests'，输入冻结archive/version/SHA256/VM CDHash | 7项通过，含实际归档1项 | 实际宿主Bundle安装到private testRoot并复验；不证明系统root store和跨UID行为 |
| python3 -B -m unittest discover -s research/upstream_integration_2026-10-06/evidence/B39/T24 -p test_attribution_filter.py -v | 5项通过 | 过滤未知字段/身份、坐标和无关事件；样本仅保留标记 |
| zsh scripts/build.sh --no-vphoned；zsh scripts/build_launchpad.sh | 两者退出0 | 采用固定解析输入、现有已校验guest组合；CLI宿主7个Mach-O、Launchpad外层2个及嵌入7个通过签名/依赖校验 |
| python3 -B scripts/check_bundle.py .build/vphone-cli.app --execute | 退出0 | 完整资源/签名/entitlements及仓库外工作目录、符号链接资源解析 |
| 主checkout现有.venv执行封装check_python_runtime.py --locked --json | 退出0，differences为空 | Python3.14.5版本锁与能力；不是字节闭包 |
| python3 -B research/upstream_integration_2026-10-06/evidence/B39/T24/scoped_amfi.py --check | 退出0 | 输入SHA/CDHash与工具存在性；未附加系统进程 |
| 冻结VM --help | -9 | SIGKILL终止；精确时间窗同一路径AMFI日志确认-424：ad hoc签名包含restricted entitlements |

命令完整参数、退出码和磁盘余量见 `*-result.json`，离线日志摘要及压缩件见 `log-manifest.json`。测试去重后为53项Swift与5项Python；不将重复运行重复计为独立测试。

实际统一日志的时间戳采用空格分隔日期时间；原过滤器只接受T分隔，新增回归先失败1项，放行两种严格时间戳格式后5项通过，见attribution-timestamp-red/green结果。后续运行守护新增UTC起止时间、PID/PGID和信号终止原因，避免依赖文件mtime确定窗口。AMFI精确查询以旧结果文件mtime和elapsed界定25秒窗口；仅找到候选完整路径的-424事件，见amfi-exact-window.json。该证据说明VM执行前的签名准入失败，未观察CoreLocation授权调用。

## 冻结与身份

版本 `2.6.1-local.f183c705c87b` 是B39研究打包标识，不是上游发布声明。为符合现有受控存储最低版本与目标功能校验，在打包副本中将Info短版本改为2.6.1、package type改为BNDL并重签外层。VM字节与直接CLI、Launchpad嵌入副本相同。归档SHA256 `3bae87c809c93e3868a0a77c3bc00a5c1bc3a789fc3292487bfd8da3f22d6552`；VM CDHash `26a49260cdfea504e17202693802cd6c3a3574c6`。完整身份、usage description、entitlements、依赖和生产源码摘要见 `frozen-candidates.json`。

源码显示VM内CLLocationManager拥有定位调用，工程没有独立location helper。Launchpad child设置responsibility disclaim，launcher不设置，直接boot通过exec进入配对VM。实际requesting/accessing/responsible尚未观察；VM没有内嵌Info.plist，codesign显示not bound，不能由此推定负责应用或usage description已生效，也不能由此确定拒绝原因。

只读核对源PID71457、精确监测PID72155，health=healthy。研究副本launchpad.json缺失；系统store根不存在。amfid PID6968由debugserver PID38530附加，flags含P_TRACED，现有amfidont PID38515。不能并行附加本轮驱动。身份需执行前重查，见 `preflight-state.json`。

## 验证限制与剩余工作

完整直接CLI与Launchpad→launcher→可信store TCC链未验；本轮没有store生产安装、VM启动、源维护、定位授权变化或AMFI附加。已保存具体运行/恢复方案并请求本轮明确批准。历史B28的源码重建v1 helper真实XPC拒绝证据保留，本轮未重装该服务；不将其当作历史原始二进制证据。

Python解释器/framework、site-packages及原生库、managed venv、PATH选择的bootstrap工具和现场clang编译不在封装宿主Mach-O检查范围内。当前版本锁探针通过；字节闭包仍未建立，T40继续跟踪。

本轮守护记录最低余量 `255.49` GiB，未触发5 GiB停止条件。主checkout保持clean的codex/handoff-20261001；开发在独立worktree，Package.resolved与原HEAD一致。未执行push。
