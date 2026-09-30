# vphone-cli 第一批候选补丁：P0 检查工具 + P1c 状态修正

**交付状态：候选源码、应用工具与隔离测试已完成；未应用到用户的 Mac 工作区，P0/P1c 整体验收未完成。**

本包不是完整仓库，不包含固件、VM、依赖、签名产物或设备票据。执行环境为 Linux x86_64，未挂载 `/Users/qcz3840/github/vphone-cli`。代码整合基于公开固定提交读取的源码片段，而不是用户当前未提交工作区。

| 对象 | 固定值 |
| --- | --- |
| 本地仓库源码基线 | `bc3bfa83ee8d3397e1caa08ce580e24407de17cd` |
| 上游参考 | `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3` |
| 范围 | NVRAM 初始化、完整状态克隆、相关测试与 README；另提供 Mac 基线取证工具 |
| 不在范围内 | P1a/P1b、Xcode/2.x 迁移、HTTP 认证、固件补丁、Hook、Irisin、相机协议 |

## 1. 已提供的实际内容

NVRAM 分为“打开已有普通文件”和“无覆盖创建”两条路径；符号链接、非普通文件与打开错误不触发重建。初始化仍保留既有 boot-args 逻辑。本包的 lstat 检查不是对任意恶意文件系统竞争的完整防护，仍依赖既有 VM 锁和可信 bundle 路径。

克隆保留 machine identifier、NVRAM、SEPStorage、SHSH、预测文件及其他持久数据，先在自有私有 staging 目录复制，验证 manifest 后在库锁内发布。继续持有源 VM 锁，排除根目录运行记录与 `vphone.sock`，不复用原进程停止身份。fallback 在复制前跳过真实 Unix socket；失败只清理自有 staging，不清理最终名称下的其他目录。克隆是同设备身份的状态副本，不是独立新设备。

应用工具会读取真实 Git 基线和完整文件，再生成正常的 unified diff；本包不提供可脱离基线检查直接使用的片段补丁。可以用 `--patch-out` 保存两个独立补丁。

| 阶段 | 路径 | 动作 |
| --- | --- | --- |
| nvram | `sources/vphone-cli/VPhoneVirtualMachine.swift` | 替换初始化分支，去除 allowOverwrite |
| nvram | `sources/VPhoneCore/VPhoneNVRAMStorage.swift` | 新增可单测的选择逻辑 |
| nvram | `tests/VPhoneCoreTests/NVRAMStorageTests.swift` | 新增测试 |
| clone | `sources/VPhoneCore/VPhoneBundleOps.swift` | 替换 clone/resetIdentity 部分，保留状态并私有暂存 |
| clone | `sources/VPhoneCore/VPhoneCloneCopy.swift` | 新增复制及临时文件过滤逻辑 |
| clone | `tests/VPhoneCoreTests/BundleOpsTests.swift` | 将旧“重置身份”断言改为“保留状态” |
| clone | `tests/VPhoneCoreTests/CloneCopyTests.swift` | 新增复制辅助逻辑测试 |
| clone | `tests/VPhoneCoreTests/BundleCloneStateTests.swift` | 新增 6 项原工程集成测试，尚未执行 |
| clone | `README.md` | 修正 clone 示例与同身份说明 |

两份已经修订的 `research/upstream_comparison.md`、`research/upstream_implementation_plan.md` **不被本包覆盖**。公开基线不能代表它们当前的未提交修订。仓库根目录 `TODO.md` 不在读取或修改清单中。

## 2. 真实测试结果

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 两个辅助 Swift 文件与对应测试 | 15 项测试、2 个 suite 通过 | `logs/isolated-delivery-runner.log` |
| 应用器的临时 Git 仓库测试 | 9 项通过 | `logs/apply-safety-tests.log` |
| Linux 下验收脚本拒绝冒充 Mac 运行 | 通过，退出 2；未调用 make/Xcode | `logs/verifier-linux-guard.log` |
| 新集成测试及接入片段语法检查 | 通过；仅 parse，不是类型检查 | `logs/integration-syntax-only.log` |
| 原项目 make test / test_swift / build | 未运行 | 缺少实际 Mac 工作区与 Xcode |
| 原项目 6 项新集成测试 | 未运行 | 需要原工程、Darwin 与真实目录锁实现 |
| APFS clonefile、VZMacAuxiliaryStorage、VM 启动 | 未验证 | Linux 测试不能覆盖这些实现 |

15 项测试不是完整原工程测试；其中“原生复制成功分支”使用注入的模拟复制，不能写成 APFS 实测。真实 Unix socket 排除测试是在 Linux 上执行的。源锁会更新诊断运行记录，所以“源不变”仅指已验证的持久状态，不承诺整个目录包括诊断文件逐字节不变。

首次独立编译暴露了 Linux Foundation 的 delegate 协议要求，已补齐并重新通过。原失败日志作为过程证据保留，不是最终结果。

## 3. 在实际 Mac 工作区执行

需要 Python 3.10+、Git，以及项目本来要求的 Xcode/Swift 和依赖。将本包放在仓库外，进入本包目录执行。不需要以 sudo 运行应用器。不要为了通过检查而 reset、丢弃或覆盖现有修改。

### 3.1 先取基线

```bash
REPO="/Users/qcz3840/github/vphone-cli"
EVIDENCE="$HOME/vphone-batch1-evidence-$(date +%Y%m%d-%H%M%S)"

python3 verify_batch1.py \
  --repo "$REPO" --phase baseline --output "$EVIDENCE/baseline"
```

工具记录 HEAD、工作区、子模块、工具链、固定对象、merge-base/merge-tree、make test 与夹具存在性。如果本机缺少固定上游对象，先检查结果；允许联网抓取时，在一个新的输出目录重跑并增加 `--fetch-upstream`。该选项只 fetch 固定 SHA，不切分支、不改 remote 配置。

基线有失败或输入缺失时先调查，不将旧报告的“缺 17 个夹具”等数字复用为本次结果。此脚本不是全 P0 签字：完整 VM 备份、逐变体映射和相机 ABI 核对仍需另行记录。

### 3.2 默认只检查，随后分两批应用

```bash
# 不修改仓库；检查全部目标文件及 payload
python3 apply_batch1.py --repo "$REPO" --stage all

# 第一份补丁：仅 NVRAM
python3 apply_batch1.py --repo "$REPO" --stage nvram \
  --patch-out "$EVIDENCE/01-nvram.patch" --apply

# 第二份补丁：克隆、相关测试与 README
python3 apply_batch1.py --repo "$REPO" --stage clone \
  --patch-out "$EVIDENCE/02-clone.patch" --apply
```

每条命令成功后再执行下一条。应用器不自动 commit、push、安装依赖、启动 VM 或更新研究文档。

安全检查会要求：固定基线对象存在且属于当前 HEAD 的祖先；被修改文件在工作区和 index 都与该基线完全一致；源码块精确且唯一；新增路径未占用、不是符号链接；新文件 SHA-256 正确。生成完整补丁后先执行 `git apply --check`，再按授权应用。不使用 `--reject`、`--3way`、`--unsafe-paths`。

**出现 REFUSED 时停止。** 它可能意味着你已在这些文件上继续开发，应在 Codex 中基于现有代码逐项整合，而不是回退工作区来适配这个包。不相关的已修改文件，包括两份研究文档，会保持原样。

### 3.3 应用后的原工程验证

```bash
python3 verify_batch1.py \
  --repo "$REPO" --phase post --output "$EVIDENCE/post"
```

post 记录 `make test`、`make test_fixtures`、`make test_swift`、`make build` 和 `git diff --check`。项目 make 命令可能进行其正常的依赖解析和构建产物生成。即使脚本退出 0，也只表示执行的检查通过；它不会启动 VM，也不会把完整 P0/P1c 标为通过。

### 3.4 必须另做的验收

在停机备份和测试副本上验证：原 VM 至少两次正常启动；停机克隆可启动；导出/导入后可启动；设备身份、票据及业务数据符合预期；运行中源拒绝；目标冲突与失败清理；真实 APFS 与复制回退行为。

备份要包括相配的宿主产物、完整 VM 和 guest 状态，不能仅复制 Disk.img。运行后的 NVRAM 允许正常变化，不应以全文件哈希不变作为启动验收条件。独立设备身份、多 VM 同身份并发不是本批已经交付的能力。

CLI 可执行帮助、翻译 README 的旧语义还需要在实际仓库检查；本包只修改已核对的根 README。签字前同步这两处和两份研究文档的状态，但不能预先将未执行的测试写为完成。

## 4. 复现本包测试

```bash
python3 run_isolated_tests.py
python3 tools/test_apply_batch1.py
```

第一个命令在临时目录重建一个仅含两个辅助文件的 SwiftPM 子集，不是原工程。第二个命令只在人工构造的临时 Git 仓库验证应用器；不证明真实工作区一定接受补丁。

## 5. 回退与审核

应用后先审核 `git diff`。本包不创建提交，便于按 nvram / clone 两个范围分别评审和提交。保存通过 `--patch-out` 生成的补丁；需要回退时先确认期间没有其他编辑，再使用 Git 的反向检查与对应补丁，不执行破坏性的整仓 reset。代码回退不能撤销已经发生的 VM 磁盘写入，VM 恢复必须使用匹配备份。

`REPORT.md` 提供执行记录与限制；`STATUS.json` 提供机器可读状态；`SHA256SUMS` 覆盖包内文件。`review/` 是接入片段与语法检查包装，只供评审，不能作为完整源文件覆盖原文件。
