# 评审后修复记录（2026-11-02）

本轮范围为 `duo-integration-20261030` 上主页 AX 与自动锁屏修改的评审问题。
用户已授权修复、提交并推送该分支到 `origin`。本轮未启动或修改 VM。

## 修改与证据

| 问题 | 修改 | 证据 |
| --- | --- | --- |
| plist 读取、解析失败后覆盖已有配置 | 仅文件不存在时创建配置；拒绝读取错误、解析错误和非字典结构；两份输入均校验后才写入 | 保存的回归在旧实现产生 25 个失败断言，修复后通过；验证两份文件字节均未变化 |
| 单显示 SpringBoard 点击选择不可见元素 | 查询时启用可见性过滤 | 新增 3 个断言在旧实现失败，修复后通过；覆盖不可见同名元素优先出现和仅匹配不可见元素 |
| `rangeMinimum` 移除未覆盖 | 分别向两份 plist 预置 `rangeMinimum: 120`，再请求 0、60、1800 秒 | 检查字段移除或保留、设置值与其他配置字段保留 |
| Never 请求处理缺少测试 | 将实际处理函数放入 `GuestAPI+AutoLock.swift`，由 `executeDevice` 调用并由本地脚本直接编译测试 | 覆盖 `never: true`、`seconds: 0/1800`；拒绝错误类型、非整数和越界值，错误请求不改写文件 |
| 完成状态超出验证范围 | `TASKS.md`、`ELEMENT_TAP.md`、补丁比较文档与 README 明确区分历史 App 验收、本地测试和待完成的 VM 验收 | 主页图标点击、系统计时、通知及重启持久性均未计为通过；旧 CFPreferences/profiled 原因解释标为待验证假设 |
| KFC 与固件测试结论不准确 | KFC 保留“原因未查明”的开放状态；固件按 issue 和失败测试名称分别计数 | `F6.md`；`baseline-firmware-failures.json` 的 134 条 issue、128 个失败名称；candidate 比较记录没有新增或移除的失败名称 |

## 回归结果

命令在仓库根目录执行。日志保留在 `.build/review-followup-20261102/`。

| 命令 | 结果 | 日志 |
| --- | --- | --- |
| `zsh VPhoneDaemon/Tests/run-element-tap-tests.sh` | API 236 checks，0 failures；几何 31 checks；原生显示和 AX context 检查通过 | `element-tap-after.log` |
| `zsh VPhoneDaemon/Tests/run-auto-lock-tests.sh` | 81 checks，0 failures | `auto-lock-after.log` |
| `zsh VPhoneDaemon/Tests/run-logic-tests.sh` | 394 checks，0 failures | `logic.log` |
| `zsh VPhoneDaemon/Tests/run-hierarchy-tests.sh` | 冷启动防护通过；`vphoned_ax_hierarchy.m` 行覆盖率 99.40% | `hierarchy.log` |
| `zsh VPhoneDaemon/Tests/run-system-maintenance-tests.sh` | 148/148；解析器 13/13 | `system-maintenance.log` |

复现日志为 `auto-lock-before.log`（58 checks，25 failures）和
`element-tap-before.log`（API 236 checks，3 failures）。实际请求处理函数的
测试在修复阶段加入，未计入上述 58 checks。

## 完整构建

完整 `VPhone` 构建返回 0，日志末尾为 `BUILD SUCCEEDED`，包含 iOS/tvOS daemon
和 `Bundle admission passed`。命令为：

```sh
xcodebuild -workspace /Users/kolar/github/vphone-cli/VPhone.xcworkspace \
  -scheme VPhone -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /Users/kolar/github/vphone-cli/.build/review-followup-20261102/XcodeBundle \
  -clonedSourcePackagesDirPath /Users/kolar/github/vphone-cli/.build/test-audit/dd-VPhoneArchiveKitTests/SourcePackages \
  -disableAutomaticPackageResolution build
```

日志为 `.build/review-followup-20261102/bundle-build.log`。

另外执行了 `codesign --verify --deep --strict --verbose=2
.build/review-followup-20261102/XcodeBundle/Build/Products/Debug/VPhone.bundle`，
返回 0，日志为 `signature.log`。`xcrun dyld_info -exports` 确认 bundle 中的
iOS 和 tvOS daemon 均导出 `icli_ax_elements_json`、`icli_ax_element_at_json`；
这项静态检查不证明 guest 中的 AX 调用成功。日志为 `ax-exports-ios.log` 和
`ax-exports-tvos.log`。

构建输入为 `c742a06a` 加本轮工作区修改。bundle 中 daemon 的 SHA-256 为：

| 文件 | SHA-256 |
| --- | --- |
| `Contents/Resources/guest-resources/vphoned` | `e9bda60023a00bed058fd49c378b3c2272f04d1bab0cd8062f3b1744b1fd3edb` |
| `Contents/Resources/guest-resources/vphoned-tvos` | `0f098649743611b65aa227759bd54b8eb0ffc4f4810470e2da74bb1d39dba400` |

## 验证限制

- 主页 Swift API 测试使用 IcliKit/VphonedNative 替身；不验证 guest 的进程查询、
  AX 动态符号或实际图标点击。
- 自动锁屏测试读取、写入临时文件，偏好写入使用替身；不验证 SpringBoard 实际计时、
  通知送达、profiled 后续合并或重启持久性。设置回读来自同一份磁盘文件，不能独立证明系统采用该值。
- 每份 plist 分别原子写入，两份文件之间没有事务保证；写入阶段的部分失败可能留下不同步状态。
- 本轮未重新执行依赖固件输入的完整 FirmwarePatcher 套件；134 条 issue 和 128 个失败名称引用历史基线及候选比较记录。
- 安全区/导航栏评估、baseline F6、`--max` 传输和低剩余空间导入仍为既有未覆盖范围。
