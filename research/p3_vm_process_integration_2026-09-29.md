# P3 VM 运行进程拆分

日期：2026-09-29。采用固定上游 2.0.8 的独立 `vphone-vm` 进程布局，保留本地 VM 实现、Unix socket、锁和停止身份校验，没有整文件替换运行层。

## 实现

SwiftPM 将原 CLI 实现编译为共享模块，增加两个独立 executable product。`vphone-cli` 解析管理命令；启动命令在创建 VM 或获取锁之前通过 execv 转交同目录 `vphone-vm`。新运行入口只接受启动参数。`vm launch` 直接启动该运行程序；创建流程已有 CLI 子进程也会在原 PID 上 exec 为运行程序，现有子进程清理保持有效。缺少配套运行程序时拒绝启动，不回退到开发目录。

VM 程序继续由 VPhoneAppDelegate 获取 VM 锁和写入运行状态。停止与 DFU owner 检查同时识别 `vphone-vm` 和历史 `vphone-cli --config`，保留 PID、启动时间、配置路径和锁检查。CLI 父进程不写 VM 身份。

构建分别签名：VM 程序具有原有 virtualization entitlements，CLI 不再带这些私有权限。完整 app 检查要求两个可执行文件，并验证 VM 签名及 entitlements。doctor 读取配套 VM 的签名，明确该结果不证明宿主执行准入；boot preflight 和已有 amfidont 脚本的 cdhash 目标改为 VM 程序。本批未执行 amfidont 或调整宿主安全策略。

创建检查点的工具指纹改为 CLI 与 VM 可执行文件摘要的组合。已有检查点与新工具不匹配时仍走已有显式工具变更处理，不静默继续。

## 验证与限制

- 首轮进程、停止、DFU 锁及诊断专项 75 项通过。
- 追加真实 CLI 到临时替身运行程序的 exec 检查：带空格参数、显式 boot/默认 boot、退出码 23 及缺失运行程序拒绝通过；没有启动 VM。
- 停止夹具同时覆盖旧 CLI 名称和新 VM 名称；schema 与运行入口相关 22 项测试通过。
- 完整 app 编译、签名和资源检查通过。最终回归及产物摘要见本轮汇总记录。
- 签名 CLI `--help` 退出 0；签名 VM `--help` 被 SIGKILL 终止。当前未完成真实 VM 启动、双 VM 或恢复验收。amfid 日志确认 `AppleMobileFileIntegrityError -424`：ad-hoc 签名包含受限 entitlements。不能用 codesign 成功替代执行成功。

原生 Restore 仍未接入阶段 runner；Launchpad helper、root Core Bundle 收据/执行复核、受控安装及真实生命周期验收仍待完成。P3 保持部分完成。
