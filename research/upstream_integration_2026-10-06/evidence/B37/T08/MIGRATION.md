# T08 完整现代环境迁移准备

本文件仅为离线方案，差异列表由 offline.py 生成于 migration-plan.json。实际修改、签名后 launchd、磁盘事务和运行验收均未执行。B36 分类记录经过摘要核对，但不代表当前客户机磁盘状态已重新检查。

## 已核对的输入

代码根、冻结工件根、VM 根和本轮输出根分别由 workspace.json 声明。B35 构建的 663 项生产输入与当前代码及冻结快照一致。固定 IcliKit 为 0.7.16 / 702990b59ca412ad975f9f0ea5dafe95c30fac21，七项 checkout 与 JPEG overlay 核对通过。现代 API、六项组件和完整默认 Bundle 的静态验证通过。

B36 已保存报告分类为 full_migration_required。该报告记录 launchd 的定制加载路径为 /b、/vh 缺失、五项现代环境库缺失。完整迁移涉及启动链加载路径、daemon、相机和宿主通道；现有 cfw_env_update.py 的 apply 只支持已完整部署现代环境后的库替换，不能执行本方案。

## 迁移差异

| 对象 | 已有证据 | 拟议操作 | 执行前要求 |
| --- | --- | --- | --- |
| /sbin/launchd | B36 记录 /b | 从已验证原始备份重建，保留必要 jetsam 修改，用 /vh 加载现代 LaunchHook | 核对 launchd.bak 与适用版本；按语义锚点处理；保留 entitlement；签名后核对加载命令；拒绝 /b 与 /vh 同时生效 |
| /vh | B36 记录缺失 | 指向 /usr/lib/launchdhook-vphone.dylib | 在暂存系统卷创建；验证目标、符号链接和载荷摘要 |
| 五项 /usr/lib 环境库 | B36 记录缺失 | 安装固定 stage 中 LaunchHook、SystemHook、VCamCaptured、CamFix、LocationFix | 路径、摘要、IOS/arm64e、最低版本和签名核对；清单保存在 migration-plan.json |
| /usr/bin/vphoned | 默认 Bundle 为 classic | 切换为固定现代 API 是拟议目标 | 先解决宿主 1337 控制兼容性及缓存启动选择；不得单独替换 daemon 后宣称整体验收 |
| LaunchDaemons 与 launchd.plist | 两套 daemon 使用同一 com.vphone.vphoned 标识 | 更新同一服务及缓存配置，保留无关服务 | 盘点实际 /cores、Preboot 与 RootHide 服务，识别重复/旧作业；逐项备份与核对 |
| 相机发布和读取 | classic 头 256 字节；现代头 64 字节 | 现代发布端与现代读取端成组切换 | 先停用旧发布端及旧 TweakLoader 相机注入；不能靠监听端口失败避免共享内存已被改写 |
| 宿主自动更新与默认资源 | build.sh 仍选择 classic guest-resources | 增加完整现代组合的选择及来源校验 | 不能让自动更新把现代客户机换回 classic；同时保存 less 等变体的适用条件 |

GPU 候选已通过静态验证；不属于 guest_environment.json 的五项环境库，本方案未安排其部署。libmisfix 属于 T18 的 upstream-only 项，不纳入本轮安装清单。

## 尚未实现的兼容性条件

VPhoneControl.swift 固定使用 vsock 1337。classic vphoned.m 提供该通道，并无条件调用 vp_vcam_start；现代 vphoned_vsock.c 提供 1339 API。因此，简单替换 /usr/bin/vphoned 会移除现有 classic 控制服务。完整迁移必须实现宿主控制路径适配，或提供关闭相机发布的 classic 兼容进程及独立服务标识。当前两种方式均未实现或验证，方案不能直接执行。

默认现代打包还需要资源角色、组件清单、CFW 选择和自动更新策略形成一致组合。此次仅核对现有默认产物，未修改默认选择，未重新构建。保持 classic 不代表现代默认验收完成。

## 后续执行与恢复条件

后续获准进行实际迁移时，先重新核对源与副本身份、当前磁盘状态、冷态恢复副本和可用空间。源与同身份副本不得同时运行；源自动重启时暂停。当前批准范围仍限定研究副本，不能把源 vm-new 作为迁移目标。

所有改动应在独立暂存磁盘完成：验证原始输入，安装匹配组合，核对签名与加载路径，保持 VM 身份文件，使用已有磁盘事务和启动快照处理机制，全部检查通过后才发布。失败时恢复 B36 冷态副本；发布与恢复步骤必须在具体实现中验证，不能由本计划推定成功。

真实冷启动验收需排除手动 Irisin 激活和 services.load，核对 RootHide 完成标记、物理根、加载后的 plist、Irisin/SSH 服务及实际 daemon/库来源。API_ONLY 会跳过相机与启动恢复，只能作为控制组。该验收不在 B37 范围内。
