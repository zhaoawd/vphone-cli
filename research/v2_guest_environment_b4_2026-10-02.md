# v2 环境 B4：T15 驱动接入

日期：2026-10-02。依据 v2 设计第 3.1、3.4、7.1、8 节。

驱动新增 `--guest-environment classic|v2`，默认 classic。v2 首批只接受 regular，并且只适用于完整 install 模式。非法 variant/profile/mode 在提权、锁或磁盘工具运行前拒绝。`--install-environment` 入口暂时拒绝，迁移留给 B6。

install 模式在同一 T15 暂存副本上依次运行原变体安装器与 B3 安装器，然后清理、翻转一次快照、发布一次。API 候选路径来自 `VPHONE_API_DAEMON` 或独立候选目录；安装报告带当前 transaction.json 的 ID，并随该事务归档。所有 Python 导入设置 PYTHONDONTWRITEBYTECODE，避免写入 root 所有的资源缓存。

canonical restore-info.json 中已记录 v2 时，缺少 v2 选项的完整安装在提权前拒绝，提示 `--guest-environment v2`。此处用 zsh 匹配标准写入器产生的字面 JSON 字段；Swift 端的结构化记录校验留给 B5。

## 验证

- 新增成功测试修改前因未知 --guest-environment 退出 1；实现后发布的合成 tar 磁盘包含预期库与 API，旧盘字节保留，报告事务 ID 与 transaction.json 一致，快照工具与变体安装器各调用一次。
- 新增已记录 v2 的无选项重装测试修改前退出 0并发布；修正后退出 1且无工具调用。
- 第二个库 EIO：安装失败；原盘 inode、mtime、SHA-256 不变；没有旧盘发布记录；失败报告归档；未调用快照工具。
- dev/jb/exp/less + v2、非 install 模式、未知 profile 均在工具运行前拒绝。classic 无选项不调用环境安装器。
- `.venv/bin/python3 -B -m unittest tests.test_cfw_disk_transaction tests.test_cfw_host_isolation tests.test_cfw_env_update tests.test_cfw_env_install`：107 项通过（72.311 秒）。
- 安装器与驱动 16 项单独复核通过。
- `zsh -n scripts/cfw_install_host.sh`、`git diff --check`：通过。

## 验证限制

磁盘为临时 tar 文件；挂载、磁盘工具、提权、签名和快照操作使用替身。T15 发布与原盘保护代码实际运行。未验证真实 sudo、APFS、系统卷安装或 VM 启动。
