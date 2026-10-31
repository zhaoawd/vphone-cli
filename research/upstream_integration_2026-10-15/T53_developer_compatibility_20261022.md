# T53 开发工具组合兼容：源码审计与隔离候选

固定目标为 `2a0d3aca9fb79344d939365cc337b915ae9f2f97`。本轮完成源码核对、三个上游 C 测试程序，以及 DeviceHub 和含 Flutter 修复的 SystemHook 隔离构建。尚未接入本地产品、安装客户机载荷或执行开发工具真实验收；`accepted=false`。

## 源码与本地条件

| 对象 | 固定上游事实 | 本地状态 |
| --- | --- | --- |
| DeviceHub | `DeviceHubFix/libdevicehubfix.c` 处理 cryptexd、dtremotedisplayd、dtdeviceinfod 和 avconferenced；Makefile 构建，StageBundle/ValidateBundle 封装检查，Shared/InjectionEnvironment 选择目标 | 对应载荷与注入选择未接入 |
| Flutter AOT | Makefile 第44行将 `FlutterRemapFix/*.c` 直接编入 SystemHook，第45行纳入头文件；修复限制同一 app 的引擎/AOT 映像、同任务复制及已观察的32 KiB布局，执行覆盖、复制和 RX 权限确认 | 本地 SystemHook 构建未包含该源文件；本地产品支持未建立 |
| InstallCoordination persona | LaunchHook 包含限定服务、操作、过滤器、root所有且不可由组/其他用户写入的普通文件标记、可执行路径、签名身份与 audit token 的检查；Swift GuestSystemPatchSet 管理标记 | 载荷未接入，声明仍为 `notImplemented` |
| 条件 force-kern | 本地已有隔离条件算法和旧实现识别测试 | 生产 Gate 仍拒绝缺少可信原件/Undo及事务迁移发布链的执行 |

初次按库文件名检索没有识别到 Flutter 的产品构建入口。随后检索目录名并核对 Makefile，确认其直接编入 SystemHook。初始观察保存在 `r1/audit-initial.json`，纠正后的观察见 `r2/audit.json`。单独构建的 `libflutterremapfix.dylib` 仅为实验，不作为上游产品结构。

T53 依赖 T08/T18/T24/T32/T33/T35/T43/T44。当前台账仍记录 provider、TCC、Receipt/Undo 发布、kernel 证明及 hook 适配等未完成项。上游研究记录的 24A446/cloudOS26.4/Xcode27.0 结果不构成本地 26.1/23B85 VM 的验收。

## 验证

本机工具链为 Xcode 27.1（27A9269），iPhoneOS SDK 27.1。候选为 arm64e、IOS、最低26.0；签名检查通过。未构建或声明 arm64e.x1 支持。

```sh
.venv/bin/python -B research/upstream_integration_2026-10-15/tools/prepare_t53_developer_candidate.py \
  --output .build/t53-developer-20261022-r2
swift test --skip-build --skip FirmwareIntegrationTests \
  --filter 'PatchUndoLogTests|FirmwareComponentUndoTests'
```

候选工具要求输出目录不存在，从固定 Git 对象提取源码和 MIT 许可证，记录 Git blob/SHA-256，执行三个 C 程序并构建隔离库，保存编译、签名、架构、平台与依赖日志。r2共24个步骤通过。SystemHook 使用上游 Makefile 中的四个源文件组合，未替换本地或已安装 SystemHook。

| 验证 | 结果 | 范围 |
| --- | --- | --- |
| InstallCoordinationPersonaTests | 通过 | 服务/过滤器、标记类型/权限/归属、路径、签名及过期token的模拟拒绝 |
| FlutterRemapPolicyTests | 通过 | 同app路径与复制参数边界；输入路径约定已规范化 |
| FlutterRemapRepairTests | 通过 | 模拟原子覆盖、复制、RX转换、失败释放；不执行真实客户机remap |
| 本地 Python 组合 | 106项通过 | test_iomfb_conditional、test_patch_plan_gate、test_undo_provenance、test_guest_components |
| 本地 Swift 组合 | 14项通过 | PatchUndoLogTests、FirmwareComponentUndoTests；使用已构建测试程序 |

Python 初次组合106项出现1个失败、37个错误。37个错误均为 Undo 夹具 `_dispatch` 替身不接收 `guest_environment` 关键字参数。修改夹具为显式接收并断言与冻结计划一致，保留原件、篡改、事务和拒绝断言。另一失败日志包含沙箱 EPERM。同一组合在修正夹具后于沙箱外执行，106项全部通过；保留两轮日志。本轮没有修改生产 Gate、补丁字节或固件基线。

## 后续实施与验收

1. 按本地固定来源与产品清单接入 DeviceHub、Flutter/SystemHook、persona/LaunchHook，保留既有 spawn、相机、定位和 RootHide 行为；完整记录派生修改。
2. 为载荷及 persona 标记增加确切的安装/撤销目标、适用条件、Receipt/Undo与原件来源；已有旧实现或无可靠 Undo 时拒绝生产迁移。
3. 与 T32/T33/T35 的 staged DSC、签名页及 kernel 证明共同发布，再准备独立 VM 和完整恢复点。
4. 分别验证 DDI挂载、配对、DeviceHub画面/多流、CoreDevice真安装、LLDB、Flutter debug及AOT。宿主截图和 `apps.install` 通过不替代这些结果。

这些步骤仍未完成。本轮仅生成仓库内候选，不修改系统 Bundle、VM 磁盘或主机安全设置。证据见 `evidence/T53-developer-20261022/manifest.json`。
