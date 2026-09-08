# A1 测试基线执行记录

日期：2026-09-08。对应[迭代清单 A1](/Users/qcz3840/github/vphone-cli/research/project_iteration_checklist_2026-09-08.md)。

## 结果与范围

A1 已完成。`make test` 退出码为 0：Swift Testing 180 项、XCTest 20 项、Python unittest 22 项，共 222 项通过。`make setup_venv`、`make build` 和生成的两个主程序文件的签名校验均通过。

本次基线为 `4dcbdb8fc6dbc0103bbade9972dc60b5f60a73cd` 加工作区修改，不是一个已提交的干净版本。已有的 3 个 CFW 脚本、触控相关的 3 个文件和 2 个 `.ips` 文件未由 A1 修改。本次未新增二进制补丁，未启动、恢复或挂载 VM。

## 运行入口

在仓库根目录执行：

```sh
make setup_venv
make test
```

首次安装需要能够访问依赖源。`setup_venv.sh` 使用当前 PATH 中的 Python，并依赖本机 Homebrew Keystone 静态库和 clang。当前环境已具备这些工具。

| 命令 | 范围 | 缺少输入时的行为 |
| --- | --- | --- |
| `make test` | 全部无固件 Python 与 Swift 测试 | Python 环境缺失或运行探测失败时返回非零 |
| `make test_python` | Python 运行探测与 unittest | 同上 |
| `make test_swift` | Swift Testing 与 XCTest；排除 `FirmwareIntegrationTests` | Swift 依赖、编译或断言失败时返回非零 |
| `make test_fixtures` | 检查 17 个固件输入是否为非空文件 | 列出全部缺失或空文件并返回非零；不运行固件测试 |
| `make test_firmware` | 固件输入检查后运行 `FirmwareIntegrationTests` | 检查失败时在 Swift 编译前返回非零 |
| `make test_fw_patches` / `make test_jb_patches` | 既有完整固件流程与 JB 内核矩阵 | 保留既有脚本行为；本次未运行 |

固件比较默认从 `ipsws/patch_refactor_input` 读取输入，也可指定目录：

```sh
VPHONE_TEST_FIXTURES=/absolute/path/to/patch_refactor_input make test_firmware
```

需要 6 个 raw payload、9 个参考 JSON 和 2 个 IM4P 文件，完整路径见 [run_tests.py](/Users/qcz3840/github/vphone-cli/scripts/run_tests.py)。输入检查只确认文件存在且非空；格式、语义和字节一致性由后续 Swift 测试验证。输入目录应包含对应的同一组固件和参考结果。

`FirmwareIntegrationTests` 包含 9 个补丁比较测试、3 个 IM4P 测试和原有的 1 个 `VerboseJBDebug` 诊断测试。后者主要打印定位结果，没有完整的补丁成功断言，不能单独证明补丁正确。新增需要真实固件的 Swift 测试应放入这个目标，并在需要新输入时更新文件清单。直接执行不带过滤的 `swift test` 仍会运行此目标。

VM 启动、GUI 触控、客户机控制、相机、位置和恢复验证需要专用 VM 与明确的固件组合，按 A3、E、F 项记录。本次测试入口不自动运行这些操作，也不把它们计入通过数量。

## 已确认的问题与处理

| 问题 | 本次证据 | 处理 |
| --- | --- | --- |
| 沙箱内无法获取依赖 | `curl` 无法连接 `127.0.0.1:10808`；获准的沙箱外请求经相同代理访问 GitHub、PyPI 均返回 HTTP 200 | 使用获准的网络权限完成安装；未修改全局代理配置 |
| Make 入口缺失 | `make setup_venv` 返回 `No rule to make target` | 补齐目标，调用现有脚本 |
| Python 依赖缺失 | 初始没有项目 `.venv`；安装进行中运行的 Swift Python 探测也失败 | 完成项目环境安装后重新验证；未跳过该断言 |
| 只验证 import 不足以确认原生库可用 | 原脚本只导入模块 | 共享运行探测实际汇编两条 ARM64 指令并解码，同时检查 `IPSW.create_from_path` |
| 固件测试混入无固件测试 | 旧名称过滤仍运行 3 个 IM4P 用例，因缺失文件失败 | 将相关测试迁移到独立 SwiftPM 测试目标，按目标选择运行范围 |
| 路径别名断言失败 | 实际返回 `/private/var/...`，期望为 `/var/...`；生产代码使用 `FileManager` 目录枚举 | 断言比较双方解析符号链接后的 URL；未修改生产查找逻辑 |
| 运行入口切换目录后相对样本路径含义改变 | 新入口回归测试先复现失败 | 在调用 Swift 前将样本目录转为绝对路径；回归通过 |

Swift 缓存与模块缓存默认位于 `.build/test-cache`、`.build/test-module-cache`。模块缓存尊重调用者已有的环境变量设置。pip 缓存默认位于 `.build/pip-cache`，允许 `PIP_CACHE_DIR` 覆盖。最终快速测试可以在当前沙箱内复用已获取的依赖运行；首次下载仍需要可用网络权限。

## 本次环境与依赖

| 对象 | 版本 |
| --- | --- |
| macOS | 26.5.1，25F80，arm64 |
| Xcode | 26.4，17E192 |
| Swift | 6.3，swiftlang-6.3.0.123.5 |
| Python | 3.14.4 |
| Homebrew Keystone / Python keystone-engine | 0.9.2 / 0.9.2 |
| Python capstone | 5.0.9 |
| pyimg4 | 0.8.8 |
| pymobiledevice3 | 11.9.2 |
| ipsw-parser | 1.7.5 |

全部 102 个 Python distribution 版本、Swift 依赖提交和子模块提交见[依赖快照](/Users/qcz3840/github/vphone-cli/research/test_baseline_dependencies_2026-09-08.json)。`.venv/bin/python3 -m pip check` 返回 `No broken requirements found.`。

此快照记录本次实际解析结果，不是依赖锁文件。`requirements.txt` 保持原有约束；未来重新安装可能解析出不同版本。依赖固定与跨环境验证由 D2 继续处理。

## 验证记录

| 验证 | 结果 |
| --- | --- |
| `make setup_venv` | 退出 0；实际 ARM64 汇编、解码和 Python API 探测通过 |
| `make test` | 退出 0；Swift 200、Python 22，共 222 项通过 |
| `make test_firmware`，当前无样本 | 退出 2（Make 转发脚本退出 1）；列出全部 17 项；固件测试未执行 |
| 新增测试入口回归 | 5 项通过：缺失输入、空文件/目录、仅预检不宣称通过、相对路径、子进程失败码传递 |
| `make build` | 退出 0，生成签名程序及 `.app` 目录 |
| `codesign --verify --strict .build/release/vphone-cli` | 退出 0 |
| `codesign --verify --strict .build/vphone-cli.app/Contents/MacOS/vphone-cli` | 退出 0 |
| `zsh -n scripts/setup_venv.sh`、`git diff --check` | 退出 0 |

构建时通过 `CLANG_MODULE_CACHE_PATH`、`SWIFT_MODULECACHE_PATH` 将模块缓存指向项目 `.build/test-module-cache`，使用项目规定的 `make build` 完成编译和签名。

本地原始日志：[完整测试](/Users/qcz3840/github/vphone-cli/research/artifacts/a1-2026-09-08/test.log)、[环境安装](/Users/qcz3840/github/vphone-cli/research/artifacts/a1-2026-09-08/setup.log)、[签名构建](/Users/qcz3840/github/vphone-cli/research/artifacts/a1-2026-09-08/build.log)、[缺失样本检查](/Users/qcz3840/github/vphone-cli/research/artifacts/a1-2026-09-08/missing-fixtures.log)。日志位于已忽略的 `research/artifacts`，不会随源码提交自动分发。

首次 Swift 编译输出第三方依赖的兼容性与弃用警告；沙箱内还输出用户级 SwiftPM 配置目录不可写的警告。最终测试未出现失败。这些结果只证明当前环境下的无固件测试和上述文件签名校验通过，不代表完整分发资源、固件兼容矩阵或 VM 运行验证通过。

后续优先执行 A2，对已有 AEA 输入状态识别修改做独立验证。
