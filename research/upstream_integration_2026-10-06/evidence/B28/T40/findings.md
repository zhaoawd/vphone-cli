# T40 Python 外部依赖闭包调查（2026-10-09）

本轮只进行限定根目录的只读库存和临时副本试验。未修改生产源码、台账、共享 `.build`、系统设置；未安装或下载依赖；未枚举 USB 设备、创建 VM、挂载 VM 磁盘或执行 restore/boot。所有新文件位于 `/private/tmp/vphone-b28-t40/`。未读取或写入仓库根 `TODO.md`。

已验证：在拒绝读取原 Homebrew、源 venv 和源 worktree 的子进程中，临时启动器可以直接执行项目 `check_python_runtime.py --locked --json`，并通过限定的 Python/native 功能探测。该结果支持“当前 Python 3.14.4 环境的已测调用可以使用独立副本”。它不证明所有 Python 调用、网络、设备、CFW 或 VM 行为均已闭合。

## 实验设置与来源

- 工作树：`/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli`。
- 指定源提交：`b4e80c57`。调查结束时工作树 HEAD 为 `3eea98a9e6b13efc4b9e477334bbcb6041ac978a`。本试验复制的 requirements、checker、3.14 lock、lock metadata、bridge 五个文件均逐字节等于 `b4e80c57` 中的文件；详见 `source-identity.json`。
- 选中的 venv：`/Users/qcz3840/github/vphone-cli/..venv.generations/env-9asn3gud`。
- 原 Python framework：`/opt/homebrew/Cellar/python@3.14/3.14.4_1/Frameworks/Python.framework`。
- 库存使用 `-I -S -B`，避免执行 site 初始化和生成字节码；遍历仅限 framework、选中 venv 的 site-packages、bin，以及 Mach-O 声明的具体 Homebrew dylib。
- 不跟随 framework 中越出范围的 site-packages symlink，不复制 Homebrew 配置或个人配置。
- 临时 runtime：`runtime-v1/`。复制保留文件内容、mode、symlink 目标文本、`_CodeSignature` 目录和二进制中的签名；没有重签名或修改 Mach-O load command。

## 库存结果

| 对象 | 文件数 | 字节数 | 证据 |
| --- | ---: | ---: | --- |
| Python.framework（包含 stdlib） | 3,570 | 77,345,613 | `framework-entries.json` |
| stdlib 子树（上行的子集） | 2,871 | 65,239,752 | `verification.json` |
| venv site-packages | 15,592 | 197,000,590 | `packages-entries.json` |
| venv bin（仅库存，未复制 console scripts） | 42 | 27,954 | `venv_bin-entries.json` |
| 6 个递归 Mach-O 链接的 Homebrew dylib | 6 | 8,023,696 | `inventory.json` |
| 延迟 ctypes 加载的 libusb | 1 | 178,224 | `lazy-native-copy-trial.json` |
| 最终临时 runtime 普通文件 | — | 282,620,062 | `runtime-manifest.json` |

site-packages 内有 114 个 distribution。初始两主根中共有 170 个 Mach-O。六个声明链接的外部库分别为 mpdecimal、libcrypto、libssl、xz/liblzma、sqlite、zstd。libusb 通过 PyUSB 延迟加载，未出现在这些 Mach-O 的加载依赖中。实验目录结束前实际占用 332,552 KiB；低于 1 GiB 预算。未删除已有副本。

最终 runtime 清单 SHA256：`44d3132cd4f0ed9d9326436a54837e3c5f0bf3fd270fa5ba989329fd38611a09`。这是本实验定义的条目序列摘要，不是产品 Core Bundle receipt，也没有绑定 VM。

复制后再次读取源与副本：19,162 个 framework/package 文件的 SHA256 和 mode 均一致；源 venv bin 42 个文件 SHA256 未变；framework symlink 目标文本全部保留。七个外部 dylib 的源/副本 SHA256 也一致。`verification.json` 中 mismatches 为空。

## 启动范围与隔离对照

`deny-original.sb` 拒绝读取 `/opt/homebrew`、源 venv generations、源 worktree、`/Library/Python`，并拒绝网络。首次在外层执行 sandbox 中应用该规则时，系统返回 `sandbox_apply: Operation not permitted`；通过自动审批后只在独立实验子进程中重试，未更改系统 sandbox 设置。

| 实验设置 | 结果 | 证据 |
| --- | --- | --- |
| 原 Python，拒绝原 Homebrew | 执行被拒绝，exit 71 | `sandbox-baseline-denied.stderr` |
| framework 原样副本，无重定位设置 | 仍使用原 Cellar prefix；隔离中 dyld 加载原 framework 被拒绝，signal 6 | `naive-copy-info.stdout`、`sandbox-naive-copy-denied.stderr` |
| 在 sandbox 之前继承 DYLD 设置 | 仍失败；DYLD 设置必须在受保护的系统启动器之后显式设置 | `sandbox-controlled-locked.stderr`、`sandbox-env-trial.json` |
| 在 sandbox 内使用 `/usr/bin/env` 设置副本路径，`-S -B` 与受控 sys.path | locked probe exit 0 | `sandbox-env-locked.stdout` |
| 临时 zsh 启动器直接运行项目 checker，包含原 Homebrew 的继承 PYTHONPATH | locked probe exit 0，differences={} | `sandbox-launcher-locked.stdout`、`launcher-trial.json` |
| 同一隔离设置，SQLite 内存查询、LZMA/Zstd 往返、Decimal 运算、SSL context 构造 | exit 0 | `sandbox-env-extended.stdout` |
| bridge `--help` | exit 0；不构成恢复验收 | `sandbox-launcher-bridge-help.stdout` |

临时 `runtime-v1/python-runtime` 通过自身路径确定根，设置 `PYTHONHOME`、唯一的 `PYTHONPATH`、`DYLD_FRAMEWORK_PATH`、`DYLD_LIBRARY_PATH`，清除已识别的 Python 启动路径覆盖，并执行副本 Python `-S -B`。`-S` 跳过 sitecustomize 与两个 `.pth` 文件。这改变了 Python 的启动契约；当前产品的 `pythonIsUsable` 不具备该契约。

扩展探测加载 447 个 image，其中 59 个非系统 image 均位于 runtime 副本；582 个带文件路径的已导入模块也均位于副本。系统 image 仍依赖本机 `/System`、`/usr/lib`。该观察仅覆盖这些已执行操作。

## 已复现的闭包缺口

1. Homebrew `sitecustomize.py` 包含外部 Homebrew site-packages 与 split-module 路径逻辑。framework 的 stdlib/site-packages 是越出原 framework 根的 symlink。副本保留了该 link 文本但不复制其目标；受控启动器通过 `-S` 和显式 package 路径绕过它。通用 Python site 启动尚未闭合。
2. 源 framework `codesign --verify --deep --strict` 在复制前就失败，报告 sealed resources missing/invalid、added/modified 文件。副本得到同类失败。源和副本 `bin/python3.14` 的独立签名验证均成功；复制 libusb 的签名验证成功。签名拓扑保留不等于 framework 已通过深度签名验证，原因未查明，未尝试修复或重签。
3. locked probe 与 bridge help 均通过时，PyUSB `_load_library()` 在隔离中仍失败 `LibraryNotFoundException`。原环境解析为 `/opt/homebrew/lib/libusb-1.0.dylib`。追加原 libusb 的 178,224 字节副本后，同一操作解析副本路径并通过。该试验只加载库，不调用 `libusb_init`、不枚举设备。证据为 `lazy-native-trial.json` 和 `lazy-native-copy-trial.json`。
4. 隔离中的 `ssl.create_default_context()` 可以构造，但默认 CA 路径仍为 `/opt/homebrew/etc/openssl@3/cert.pem` 与 `certs`，有效 cafile/capath 为 null，证书统计 x509/x509_ca 均为 0。显式 `SSL_CERT_FILE=副本/site-packages/certifi/cacert.pem`、`SSL_CERT_DIR=副本/empty-ca-dir` 后，x509/x509_ca 均为 121。没有进行网络 TLS 握手。证据为两个 `sandbox-launcher-tls-*.stdout`。
5. `sysconfig.get_paths()` 在 PYTHONHOME 重定位后仍给出 `/opt/homebrew` 的 purelib、platlib、scripts、data。没有在副本执行安装或编译；不能将该副本作为通用可安装 Python 环境。
6. 当前 `VPhoneCreateResourceSnapshot.inventory` 先解析 symlink，再复制 regular/directory，并排除 `__pycache__`、`.pyc`。将签名 framework 直接加入该复制流程，会改变 symlink 拓扑与封装内容；需独立支持保留签名树的复制语义。
7. 用户环境、子进程自行调用 `sys.executable`、multiprocessing、其余 ctypes 路径、OpenSSL 配置/providers、其他 package 功能、不同 macOS/CPU 版本均未全面验证。macOS 系统框架不属于本轮复制范围。

## 后续最小实现设计

- 在 attempt 接受前只选择一次已经通过 locked probe 的 Python，冻结选择结果；快照后的 Python 解析只返回该快照入口。该入口不可用时明确拒绝，禁止重新解析外部 venv 或 bootstrap 下载。
- Python 子快照记录真实 interpreter/framework 根、选中 packages 根、声明的 native dylib、额外声明的延迟加载库、CA 文件与 lock/checker 的来源和内容摘要。初始可只支持已实测的 macOS arm64 Homebrew Python 3.14 布局，其余布局显式拒绝或保留 external 限制。
- 独立复制 framework 签名树：记录 link 文本，保留内部 link，不展开 framework symlink，不移除签名可能覆盖的 `.pyc`。对越界 link、`.pth`、sitecustomize 明确分类并拒绝未知外部引用；不遍历任意指向的个人目录。源签名不合格的接纳策略需在产品实现前确定。
- 采用快照内 callable 启动器适配已有 `VPHONE_PYTHON` 调用点，设置本试验验证的 PYTHONHOME、package 路径与 DYLD 路径，并加入固定 CA 路径。启动器在 sudo/受保护系统程序之后自行设置 DYLD，避免依赖继承 DYLD 环境。是否接受 `-S` 带来的 `.pth` 行为变化必须有明确支持范围。
- 将内容清单与 capability probe 分开验证。runtime 内容摘要加入 attempt manifest；实际入口和 SDK/JB/PATH/CFW 缓存限制继续分别记录。不得只凭版本和 locked probe 宣称完整工具链闭包。
- quota 将 Python 内容计入原有快照字节和并发保留限制，检查可用容量和复制期间源变更；失败不删除已有证据。

## 后续行为 RED 测试点

- 原 venv/Python 路径被拒绝后，当前实现不能完成 locked probe；新快照入口须通过。
- package/native 文件改动且 distribution version 不变时，locked probe仍可能通过；快照 fingerprint 必须变化或捕获拒绝。
- 只复制 Mach-O 链接依赖时，locked probe/help 可以通过但 libusb 延迟加载失败；新增声明依赖及实际加载测试须覆盖。
- 默认 CA 缺失时 SSL context 可以构造；新验证应检查非空固定信任库，网络握手另行验收。
- framework 内部 symlink 与签名文件必须保持字节/目标文本一致；当前通用 inventory 的 link 展开与 pyc 过滤应触发拒绝或不再适用。
- 继承 PYTHONPATH、用户 sitecustomize、外部 `.pth` 和 DYLD 路径不能改变快照选择；遇到未支持的引用须 fail closed。
- 副本中 interpreter/package 缺失时禁止 fallback 和 bootstrap；源改变、超预算时禁止发布不完整清单。
- 未来 root CFW 路径只验证同一启动器的传递与 import/CA/native选择；设备、restore、boot、JB 编译及 SDK 行为须独立验收。
