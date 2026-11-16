# 剩余功能整体接入

固定上游：`13169405`。工作分支：`duo-integration-20261030`。已验证的上一批接入保存为本地提交 `119f1529`。本记录区分生产实现、静态回归和运行验收；未推送、发布或修改生产环境。

## 第一组：旧固件与 PCC GPU

生产接入包含 #909 `b41ad87c`、#911 `12378954`，以及必要依赖 `8fadd384`（SE 3）、`24fd20d7`（iOS 18 GPU transport）、`89f325c7`（Home 按钮）。未整体替换 Duo 共享文件。

- SE 3 登记为 iPhone14,6／D49AP，保留本地 Duo 设备定义。安装树从实体板树读取具体的 32 位 `home-button-type`；恢复树继续使用既有虚拟属性。缺失、占位符或长度错误时拒绝。
- `system-systemhook-cfw-ios18_gpu_transport` 限于 iOS 18.6 + cloudOS 26.1。准备阶段选择 iOS 同发行版 cloudOS 的 GPU，安装阶段再次核对实际驱动版本。TV／HomePod／HomeView 预设关闭该项。
- PCC OS image 支持只读提取 GPU。AEA 内嵌密钥必须为 32 字节；没有内嵌密钥时回退临时恢复。挂载失败且无法确认卸载时保留工作目录。
- 仅临时 PCC 恢复 VM 在 cloudOS 主版本小于 26 时使用 1 vCPU，其余或无法解析的版本使用 8 vCPU。普通 Duo VM 配置不变。

验证证据保存在 `.build/overall-port-20261116/`。`make -C VPhoneGuestComponents OUT="$PWD/.build/overall-port-20261116/guest-tests" test-ios18-gpu` 通过（ASan／UBSan）；CoreKit 的 `PCCGPUDriverTests`、`FirmwareCatalogReportTests`、`GuestDeviceTests` 共 45 项通过。`Regression/pcc-recovery-policy.zsh` 编译实际生产恢复源码，8 项策略断言通过。

DeviceTree 首轮新增测试将既有恢复树值误写为 0；代码中 `DeviceTreePropertyPatches` 的既有值为 2。测试改为安装源值 1／恢复值 2，直接区分两条路径；保留首轮失败日志。DeviceTree／目录 65 项随后通过（`group1-patcher-tests-fixed.log`）。完整 Bundle 构建与后续组集中进行。

限制：本轮未启动旧固件 VM，未执行新的恢复、GPU 运行验收或 Duo 组合运行验收。旧固件的具体兼容范围仍需对应镜像验证。

## 第二组：SPTM

接入 #921 `bb82a72a` 的生产差异：独立 `SPTM` firmware target、`SPTMSecondaryCPUPatcher`、boot-chain 声明、pipeline、恢复收据／drift、minimal／watchos 预设和 Launchpad 组件分类。只有 cloudOS 18 构造 SPTM pipeline 组件；其他 cloudOS 保持原始 SPTM。IM4P 重封装为 `sptm` 保留 PAYP 尾部。

发现过程：在 `__TEXT_EXEC,__text` 解码 `mrs MIDR_EL1` → `and #0xfff0` → `cmp #0`，核对条件分支与紧随跳转的目标关系，再要求目标块中的寄存器索引 `ldr`／`str` 使用相同内存操作数。唯一匹配时将 `b.eq` 替换为 `ARM64.nop`；多匹配拒绝，零匹配不写入。没有硬编码补丁地址或替换指令字。

上游比较记录将该路径关联到 cloudOS 18 次 CPU reset 中未实现的核心寄存器访问，并报告旧固件多 vCPU 启动结果。本轮未独立重现该运行结果，不将上游运行证据计为本地验收。当前仓库 `ipsws/` 未提供该 suite 自动读取的 IPSW；实际镜像／PAYP 回归和多 vCPU 恢复仍需独立输入。本轮先执行语义 fixture、版本门槛、目录和 drift 回归。
