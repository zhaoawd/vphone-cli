# D1 → D2 构建与依赖推进记录

日期：2026-09-14。D1、D2 的本地实现及验收已完成，清单更新为 16/28。远端 GitHub 工作流未运行；不包含 VM 验收或未列明平台。

后续续跑的最终结果见下方“续跑验收”；第一轮记录保留其当时的证据。

## D1 实现

- `make build`、`make bundle`、release 共用 `scripts/build.sh`。不再保留精简包构建路径。`--no-vphoned` 只跳过编译，仍要求已有签名 daemon。
- 构建重新创建应用包，写入全部资源后签名应用包，再执行 `scripts/check_bundle.py`。校验必要脚本、patcher 入口、两个资源档案、dev overlay、工具权限、daemon、requirements 和 `scripts/vphoned/signcert.p12`；读取签名权益逐项比较。
- 新增 `resources` 只读命令和 `check_bundle.py --execute`。后者在仓库外临时目录分别通过真实二进制路径和符号链接启动，不初始化 VM 或 Python 环境。
- checks 新增完整包检查作业；release 共用相同检查器及 `build_runtime_tools.sh`。远端工作流尚未运行。

## 第一轮本地验证

宿主：macOS 26.5.1 / 25F80，arm64；Xcode 26.4 / 17E192；Swift 6.3。

| 验证 | 结果 |
| --- | --- |
| `make build`、`make check_bundle` | 完整包资源、最终签名和权益检查通过 |
| 资源被修改后的签名验证 | 临时副本中修改 requirements.txt，codesign 拒绝该副本 |
| `make test_python` | 90 项通过，包含新增 5 项包资源测试 |
| `make test_swift` | 沙箱外 332 项、53 个 suite 通过；包含符号链接资源解析测试 |
| 沙箱内 Swift 回归 | 9 项 issue；沙箱外复验全部通过 |
| 脚本语法、actionlint、diff 空白检查 | 通过 |
| 已签名应用 `resources` | 沙箱内外均收到 SIGKILL；原因未查明 |

D1 的实际执行验收未通过。由于第一个真实路径执行即失败，符号链接的实际执行尚未进入；单元测试不能替代该验收。未修改宿主安全设置，未执行 VM 验收。

日志位于 `.build/d1/`：`build.log`、`execute.log`、`signature-negative.log`、`python-tests.log`、`swift-tests-unsandboxed.log`、`runtime-tools.log`。这些日志受 Git 忽略，其他 checkout 不保证具备。

## 第一轮 D2 范围

已将现有 `Package.resolved` 纳入版本控制，并让完整构建使用 `--force-resolved-versions`：

| 依赖 | 版本 | revision |
| --- | --- | --- |
| swift-binary-parse-support | 0.2.1 | 5fb96b503672ea4752eded6b4e301fd87214b03b |
| swift-fileio | 0.13.0 | d589ff3966f9f064574780f527449a946736b989 |
| swift-fileio-extra | 0.2.2 | 8d83506dd4dff737807d90dbf2264096ed98c7a7 |

本地 Python 3.14.4 的运行时探测通过。完整 freeze 保存在 `.build/d1/python-freeze.txt`，仅为诊断快照，未作为支持环境锁文件。CI 当前 Python 3.13 不能由该快照推定已验证。

资源来源：`scripts/resources` 子模块提交 `2ef6b06a10cdd7a667d337d50cbdb52fd24249c9`。

| 资源 | SHA-256 |
| --- | --- |
| cfw_input.tar.zst | 8749ba5fbd2a45f01903f1e6f331316ec5fb56329eaf7f2a1a77174234b3cf65 |
| cfw_jb_input.tar.zst | 8ae14132ff33234e7af14c6b92ce226a5c47bec4a370b18c9c5c429eaca1272a |
| cfw_dev/rpcserver_ios | 4e2b6e349faedcad08bd2487944c556ccf47f31dfe5a10c546ed655bf7cd3fad |

## 第一轮后续步骤

1. 查明已签名命令 SIGKILL 的原因，完成仓库外及符号链接执行验收；运行远端完整包检查。
2. 为实际支持的 Python 环境生成并验证依赖锁，统一 Swift 与脚本能力探测，包括 Keystone 实际汇编。
3. 验证空缓存初始化、兼容环境复用、损坏环境、下载失败及升级回退；补充依赖差异诊断。

完整包静态检查通过不表示依赖安装、恢复或 VM 启动已通过。


## 续跑验收

本次没有修改宿主安全设置。起始复验和最终重建后的 `check_bundle.py --execute` 均通过，真实二进制路径和符号链接均解析到应用包 Resources。此前 SIGKILL 的原因仍未查明，不将此次成功归因于某项未验证的宿主变化。

### D2 实现

- `dependencies/python-darwin-arm64-3.13.lock` 固定 103 项包；3.14 锁固定 102 项包。对应 JSON 记录下载 URL、SHA-256、解析平台和 requirements.txt 输入摘要。锁包含 pip/setuptools；安装禁用未锁定的 build isolation。
- `scripts/python_environment.py` 为脚本与 Swift 的共同环境管理实现。兼容环境直接复用；重建在独立目录完成，验证通过后才切换符号链接。`setup --force` 不再预先删除旧环境。
- `check_python_runtime.py --locked --json` 统一实际 ARM64 汇编/反汇编、所需 API 与版本差异检查。显式 `VPHONE_PYTHON` 同样必须通过，缺少 requirements/平台锁不再降级到未固定的安装。
- 每个新环境的 `vphone-environment.json` 记录版本、锁摘要和 Keystone 本地库修复的输入/输出摘要。应用包 `build-dependencies.json` 记录工具链、子模块、资源摘要及工具动态库引用。
- CI 快速测试改为 Python 3.13/3.14 矩阵；完整包携带两份锁和来源记录。`setup_tools.sh` 增加其 Python 准备步骤需要的 Homebrew keystone。

### 最终结果

| 实验设置 | 结果 |
| --- | --- |
| Python 3.13.13，独立空 pip 缓存 | 103 项锁定包安装、pip check、实际能力检查通过 |
| Python 3.14.4，另一独立空 pip 缓存 | 102 项锁定包安装、pip check、实际能力检查通过 |
| 已有兼容环境，禁止索引访问 | 复用同一环境目录，通过 |
| 强制重建，无可用索引 | 安装失败，原环境选择和能力检查保持有效 |
| 强制重建，索引指向拒绝连接的本地端口 | 下载失败，原环境选择保持不变 |
| 新锁指定不可安装的 pip 版本 | 升级失败，原环境选择保持不变 |
| 移除 Keystone 动态库 | 锁定能力检查拒绝；随后重建发布新的可用环境 |
| 已签名应用 setup | 使用指定管理环境，通过 |
| 已签名应用 setup --force，禁止索引访问 | 失败后仍保留原管理环境 |
| Python 完整回归 | 两个新环境各 95 项通过 |
| Swift 完整无固件回归 | 沙箱外 333 项、53 个 suite 通过 |
| Swift 独立 scratch/cache 解析 | 三个远程依赖 revision 均与 Package.resolved 一致；vendor 子模块仍使用当前固定 checkout |
| 最终 make build 与包校验 | 资源、签名、权益及仓库外/符号链接执行均通过 |
| actionlint、修改脚本语法、diff 空白检查 | 通过 |

升级失败实验验证的是新环境未发布时仍保留旧环境，不表示完成了任意历史版本之间的成功迁移。旧环境代际目录保留用于检查；未执行缓存清理。旧的真实 venv 目录转换为符号链接时包含 rename 窗口，本次没有验证该窗口内的断电或强制终止。Linux 脚本及其他架构/解释器不获得本轮锁文件验收。

最终日志与测试环境位于 `.build/d2/`，包括 `setup-313.log`、`setup-314.log`、`reuse.log`、`download-failure.log`、`upgrade-failure.log`、`damaged-probe.log`、`repair-313.log`、`app-force-failure.log`、`python-313.log`、`python-314.log`、`swift-unsandboxed.log`、`swift-cold.log`、`final-build.log`、`final-execute.log`。这些是本地忽略产物。锁文件、来源记录和回归用例可随代码提交。

使用和更新方法见 [依赖锁说明](../dependencies/README.md)。远端 checks/release 实际运行尚未验证；本地通过不等于发布或 VM 启动通过。
