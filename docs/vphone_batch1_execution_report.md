# 第一批工作执行报告

日期：2026-09-26。范围：P0 前置检查与执行工具、P1c NVRAM / 克隆候选修正。

## 结论

**候选代码与隔离测试已交付；尚未修改用户 Mac 上的仓库，P0/P1c 不能标为整体完成。**

本次能够读取公开固定 SHA 的源码，但当前 Linux 会话未挂载 `/Users/qcz3840/github/vphone-cli`；Git 网络拉取未成功，没有原工程完整 checkout、Xcode、固件输入或 VM。因此没有生成用户仓库提交，也没有执行原项目 make 测试、构建或 VM 验收。

## 实际交付

生成 4 个既有文件的精确修改规则与 5 个新源码/测试文件，按 nvram、clone 两个阶段组织。应用器在真实工作区读取基线完整文件，校验后生成完整补丁，不依赖片段 diff 直接应用。

NVRAM：移除初始化时的 allowOverwrite，已有普通文件打开、缺失时无覆盖创建；链接、非普通文件、打开失败和创建竞争均不以重建处理。保留既有 boot-args 设置。实际 Virtualization API 仍待 Mac 编译和运行确认。

克隆：保留完整持久身份，排除根级宿主运行状态和控制 socket；持源锁复制，在私有 staging 验证后于库锁内发布。保留 APFS 优先与普通复制回退，对 copy 失败仅清理自有暂存，不删除其他最终目标。新增测试覆盖 fallback、目标竞争和实际 Unix socket 排除。Foundation / APFS 在 Mac 上的运行行为仍需验证。

更新原“清除身份”测试断言与 README 说明；另提供 6 项依赖原工程的集成测试。未修改固件补丁、变体默认值、Hook、协议或用户环境。未覆盖两份已修订研究文档，也未改动仓库根 TODO.md。

## 证据账本

| 项目 | 本次结果 | 证据 / 限制 |
| --- | --- | --- |
| 执行环境 | Linux x86_64、Swift 6.2.1、Python 3.13.5、Git 2.47.3 | `logs/environment.log`；不是用户 Mac 工具链 |
| 独立 Swift 辅助逻辑测试 | 15 项、2 个 suite 通过 | `logs/isolated-delivery-runner.log`；不含原工程 |
| 应用器防误覆盖测试 | 9 项通过 | `logs/apply-safety-tests.log`；使用人工构造的临时 Git 仓库 |
| 验收脚本环境门禁 | 通过，Linux 退出 2 | `logs/verifier-linux-guard.log`；未调用 make/Xcode |
| 接入代码与集成测试语法 | parse 通过 | `logs/integration-syntax-only.log`；不代表类型检查通过 |
| 实际工作区应用检查 | 未执行 | 不知道当前文件是否仍匹配公开固定基线 |
| 原工程 Swift / Python 测试及构建 | 未执行 | 需要实际 Mac checkout 与依赖 |
| 新增 6 项工程集成测试 | 未执行 | 只有语法检查 |
| 实际 APFS、目录锁、VZ API | 未验证 | APFS 成功分支在隔离测试中为模拟 |
| 完整备份、连续启动、克隆与导入后启动 | 未执行 | 不具备用户 VM 环境 |
| P0 合并关系与固件/ABI 全面对照 | 未完成 | 提供了部分取证命令；不能复用历史冲突和夹具计数 |

应用器测试覆盖：只检查不改文件；正确应用；源文件或 index 有更改时整体拒绝；不相关研究文档保留；两阶段独立应用及重复应用拒绝；符号链接、新 payload 哈希异常、基线缺失拒绝。

独立 Swift 测试覆盖：重复打开、损坏状态不重建、正常/悬空符号链接、目录/FIFO、ENOENT 与 ENOTDIR 区分、竞争创建不覆盖、创建错误传播、非文件 URL；fallback、模拟 native 分支、已有/竞争/悬空目标保护、部分复制清理、真实 Unix socket 排除。正常启动会改变 NVRAM；实际源锁也会更新运行诊断记录，因此并非承诺所有文件永不变化。

## 尚未关闭的交付条件

实际 Mac 上需要先记录 P0 基线，协调可能存在的源码修改，再依次应用两个候选阶段并执行原工程测试和构建。完整 P0 的逐变体映射、固件和相机 ABI 对照、真实夹具检查与停机备份也不能略过。P1c 签字需有连续启动、克隆启动及导入后启动证据，并检查 CLI 帮助与翻译文档；这些没有被 README 修改或隔离测试替代。

应用工具默认只检查；真实目标文件必须在工作区和 index 都匹配固定基线。若不匹配，保留当前修改，交由有工作区的 Codex 整合，不应为套用本包执行 reset。原研究文档保留原样，待实际验证后再写入真实状态。

## 固定源码来源

本地源码基线：`bc3bfa83ee8d3397e1caa08ce580e24407de17cd`。上游参考：`9d218dedf58d4b19db5e51c8b584c1f14a96eee3`。

- [本地 VM 初始化](https://github.com/zhaoawd/vphone-cli/blob/bc3bfa83ee8d3397e1caa08ce580e24407de17cd/sources/vphone-cli/VPhoneVirtualMachine.swift)
- [本地 bundle 操作](https://github.com/zhaoawd/vphone-cli/blob/bc3bfa83ee8d3397e1caa08ce580e24407de17cd/sources/VPhoneCore/VPhoneBundleOps.swift)
- [本地旧 clone 测试](https://github.com/zhaoawd/vphone-cli/blob/bc3bfa83ee8d3397e1caa08ce580e24407de17cd/tests/VPhoneCoreTests/BundleOpsTests.swift)
- [本地 README](https://github.com/zhaoawd/vphone-cli/blob/bc3bfa83ee8d3397e1caa08ce580e24407de17cd/README.md)
- [上游固定版本 VM 初始化](https://github.com/Lakr233/vphone-cli/blob/9d218dedf58d4b19db5e51c8b584c1f14a96eee3/VPhoneExecutable/VPhoneVirtualization/UI/VirtualMachine/VPhoneVirtualMachine.swift)

公开固定源码不能代表用户之后的本地修改；两份 2026-09-26 修订文档的当前工作区副本未读取。实际整合以应用前检查和用户工作区为准。
