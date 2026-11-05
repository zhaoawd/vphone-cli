# 本机 autophone VM 准备记录

日期：2026-11-05。用户授权在本机构造独立的 autophone 测试 VM，先准备 `autophone-a`，验证后再准备第二台。

## 实验设置

- 宿主：macOS 27.0（26A428），8 核、16 GiB 内存；开始时可用磁盘约 55 GiB。
- 管理工具：官方已公证 Launchpad 2.15.0。安装包 SHA-256：`952cdc5232d589159f58e41eb9060bb4631889af5b9ed451dfbfc7cddf5c231d`。
- Bundle 源码：固定标签 `2.15.0-ap.2`，提交 `bb533bd7`。
- 独立构建工作树：`.worktrees/autophone-local-20261105`。
- 固件：iPhone17,3 / iOS 27.0.1（24A446）与 cloudOS 26.4（23E5207q），来源取自该提交的固件目录。
- 新 VM：`~/.vphone/machines/autophone-a`，8 vCPU、8192 MiB 内存、64 GiB 稀疏磁盘、NAT、standard preset。第二台并发前另做本机容量验证。
- 首台独立创建，不预建模板；通过验证后再评估以新身份克隆第二台。
- 现有 `vm-2607` 和 Duo 测试 VM 不作为本轮修改对象。

## 已验证

- Launchpad 安装包摘要与 GitHub 官方发布记录一致。
- 沙箱外 `codesign --verify --deep --strict` 与 `spctl --assess` 通过，公证来源为 `Notarized Developer ID`。沙箱内首次签名检查失败，不能据此判定安装包损坏。
- 用户完成 Host Setup 后，实际 status 返回 `developerTools=true`、`helper=ready (21)`、`hostReady=true`、`canInstallBundles=true`。
- 开始时没有运行中的 vphone VM 进程。
- 固定标签完整 `VPhone` scheme 构建成功；Bundle admission 与严格签名检查通过，内嵌源码标识为 `bb533bd7`。
- Launchpad 安装版本为 `2.15.0-local.ec12bbac`，运行策略与宿主预检均 passed；`accepted=false` 表示没有使用手动忽略失败的覆盖选项。
- 安装位置：`/Library/Application Support/vphone-launchpad/Bundles/2.15.0-local.ec12bbac/VPhone.bundle`。
- `vphone-vm` CDHash：`38b4ed96800b4329c8e424e6662a9365b7f42225`。
- cloudOS 固件下载完成，大小为 1199454323 字节，BuildManifest 为 `26.4 / 23E5207q`；SHA-256 与官方 URL 的摘要段一致：`c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64`。
- 用户明确授权清理旧版固件缓存和旧 Xcode 中间缓存。已删除两份 iOS/cloudOS 26.1 IPSW，以及清单中的 `Intermediates.noindex`、`SourcePackages`；保留 `Products`、所有 VM 与研究证据。清单及二进制摘要核对见 `.build/autophone-local-20261105/approved-cache-paths.txt`、`preserved-vm-binaries-{before,after}.txt`。
- 清理后 `df` 可用空间约 58 GiB。固定版本 CFW 安装器要求安装时 Foundation `volumeAvailableCapacityForImportantUsage` 大于 50 GiB，后续仍须在安装阶段复核。

## 创建与验证结果

- iOS 固件完整下载与 SHA-256 校验通过；BuildManifest 为 `27.0.1 / 24A446`，大小 12343857610 字节，摘要为 `fc87bb9da8c03d0154d87531950f4a170195f6663ee5208653fa7a26bafb9469`。
- `autophone-a` 已完成固件准备、补丁和正式 DFU 恢复。首次 CFW 安装在空间检查处拒绝，VM 正常停止；原始失败日志保留在 `create-progress.log`。
- 确认 CFW 消费解包恢复树后，移除本任务已完整解包的重复 iOS IPSW 下载缓存，保留 BuildManifest、摘要和恢复树。随后用同一 Launchpad 会话的 `vm create autophone-a --from installCFW` 重试，完成 CFW、初始化及首次启动，创建报告的全部 11 个阶段 passed。正式恢复 127 秒，CFW 130 秒，初始化 161 秒。
- UDID：`0000FE01-D66A77D90F264B25`。创建后再正常停止并独立启动一次，vphoned 约 7 秒后响应，启动 UUID 已变化。
- 设备实际回读：iPhone17,3、iOS 27.0.1、430×932 points、scale 3；截图为 1290×2796 像素。
- 宿主能力回读：`protocol=upstream_v1`、`guest_connected=true`；guest 声明 `location_owned` 与 `vcam_receipt_v3`。能力声明不替代定位与扫码业务验证。
- guest daemon 的实际 SHA-256 与固定 Bundle 中的 vphoned 相同：`4b5e7bb2f42844d63b92e7860314c0d8dd309fed39675dc1192f221f984f5cb0`。
- 已核对主机名 `SGHQCZ3840`，在新 VM 上完成信任本机提示；已查看截图，确认主屏幕可见且信任提示已消失。
- 收尾时 VM 保持运行。宿主可用空间约 49 GiB。
- 初始化脚本曾清理 16 条 crash report，其中包含 `panic-full ×1`。本轮未分析这些已由初始化脚本清理的报告；基础启动通过不能外推长期稳定性。
- 完整构建日志：`.build/autophone-local-20261105/bundle-build.log`；安装结果：同目录 `bundle-install.json` 与 `bundle-install.log`。
- 创建结果：同目录 `create-retry-result.json`；独立重启结果：`start-progress.log`；设备及能力：`device-info-final.json`、`capabilities.json`；主屏幕截图：`verified-home.png`。创建脚本是本次单次执行记录，不应对同名 VM 重复运行。

## 后续验证进展（截至 2026-11-05）

1. bootstrap、SSH/Frida 的部署与端点身份验证已在后续服务部署中完成，冷启动后重新启动端点并复验通过，见 [服务部署记录](autophone_local_services_20261105.md)。本节之前的设备读数为基础 VM 阶段的历史读数。
2. 独立 target 与隔离 Control Plane 已配置；Rig Agent 注册为 online，源码身份和交互通道验证通过，Host 并发上限保持 1。
3. food_ordering_v2 已完成固定 Build 安装、三次校准、菜品默认态 D0 及 13/13 出口条件验收，见 [业务验证记录](autophone_local_business_20261105.md)。定位与真实 QR 业务流程仍未验证。
4. 七个选定 IPA 已完成安装与启动检查，后续完成了宿主侧启动就绪校验修复，见 [IPA 兼容性验证](autophone_ipa_compatibility_20261105.md) 和 [启动修复记录](autophone_launch_readiness_20261105.md)。旧 VM 尚未替换。
5. 第二台独立身份 VM 与本机并发容量仍未验证。

本记录的基础 VM 阶段已完成管理工具、固定 Bundle、第一台 VM 与独立重启检查。后续菜品默认态验收范围以业务记录为准；完整商业业务和本机并发容量仍未验证，不复用其他宿主的双 Rig 容量结论。
