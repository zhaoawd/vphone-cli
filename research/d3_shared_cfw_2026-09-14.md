# D3 共用 CFW 安装步骤

日期：2026-09-14。公共函数提取和无 VM 回归已完成；各变体的真实安装、重复安装和安装产物比较未执行，D3 保持进行中。

## 实现范围

- 新增 `scripts/lib/cfw_common.sh`，四个入口共用 Python 选择与校验、继承锁检查、错误退出、普通签名、挂载路径初始化、卷挂载、资源搜索、SystemOS/AppOS 缓存和 Cryptex 清理函数。
- Python 选择顺序仍为 `VPHONE_PYTHON`、项目 `.venv`、PATH。安装入口新增 D2 的 `check_python_runtime.py --locked` 检查，验证实际汇编/反汇编、API 和锁定版本。检查失败即退出，不在安装过程中创建或替换 Python 环境。
- SystemOS 仍由 `cache_systemos.py` 完成 AEA/DMG 识别、校验和缓存发布；AppOS 保留已有缓存复用规则。
- 四个入口保留各自阶段。REGULAR 保留已安装 Cryptex 时跳过复制的规则；DEV 保留其 overlay、显式 sudo 和带 entitlements 签名参数；JB 继续先执行基础安装；EXP 的 DSC 前置步骤及 EXP 专用步骤留在原入口。不同 tar 参数也保留在调用处。
- `check_bundle.py` 增加公共脚本必需资源检查；`.gitignore` 对该源文件增加例外，避免被通用 `lib/` 规则忽略。

公共库不取得新锁、不挂载磁盘。调用相应函数的安装入口仍须由 `cfw_install_host.sh` 提供容器、独立挂载目录和继承锁。真实安装的最终挂载清理、退出码处理与 snapshot 修改继续由 host driver 管理。

## 验证

| 实验设置 | 结果与限制 |
| --- | --- |
| 四个安装入口，AEA 与已解密 DMG 两类输入，临时目录及命令替身 | 进入首次 attach 前使用正确缓存；不挂载真实磁盘 |
| 公共函数专项 8 项 | 资源搜索优先级、重复调用、缓存复用、解包失败码、无效 Python、缺失锁、限定清理范围和路径拒绝通过 |
| 既有 host driver 回归 | 不同 VM 并行、同 VM 拒绝、部分 attach、挂载清理失败、SIGINT 和退出码保留通过 |
| 阶段语句比较 | 展开新缓存调用后，REGULAR/DEV 主阶段语句与修改前一致；JB/EXP 从依赖检查开始的后续阶段语句一致。这是源码比较，不是安装产物比较 |
| 最终完整 Python 回归 | 111 项通过，包含新增公共函数及相机故障用例 |
| 脚本语法及 diff 空白检查 | 通过 |

日志：`.build/d3/targeted.log`、`common.log`、`stage-comparison.json`、`python-full.log`；修改前脚本保存在 `.build/d3/before/`。完整 Python 最终结果见本轮清单更新及 `python-final.log`。这些本地产物受 Git 忽略。

## 剩余验收及影响

用户说明其他任务正在使用 VM，本轮不执行真实 CFW 安装、VM 启停、恢复、客户机部署或镜像清理。已有 D1/D2 修改保留，本轮仅在其包检查器中补充公共库资源项。

后续需要为 REGULAR/DEV/JB/EXP 分别准备确定的输入、专用磁盘和必要空间，确认没有其他任务占用后再执行首次安装、重复安装与故障清理，并比较迁移前后调用及产物。正式签名包重建也留待协调共享构建产物后执行。

源脚本的修改会影响其他任务之后从该工作区发起的安装；它不会直接修改已经运行的 VM。公共库必须与四个入口一同交付，不能只复制入口脚本。
