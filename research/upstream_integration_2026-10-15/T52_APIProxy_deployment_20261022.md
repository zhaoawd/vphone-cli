# APIProxy 修复提交与本地部署（2026-10-22）

修复已提交为 `a0119127a5ba7fbbebc1d5d883e4f7eaaae9b78d`，未推送。提交只包含 APIProxy 停止竞争修复、回归、研究记录与证据；共享台账只暂存本轮段落，其他未提交工作保持。用户完成终端认证后，新版本已安装并核验，独立 `t52-v2` 的宿主绑定已切换。旧版本保留，目标 VM 保持停止；本次未启动 VM，未修改 AMFI。

## 对象与范围

- 新 Core Bundle：`2.6.2-local.266810c8ae29`。
- 安装目录：`/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.266810c8ae29`。
- 目标 VM：仓库内 `.build/t51rt/lib/t52-v2`；原绑定 `2.6.2-local.af333c78ac3b`，现绑定 `2.6.2-local.266810c8ae29`；本次仅替换宿主选择。
- 原版本保留；不覆盖旧版本，不重新安装客户机环境，不更新 daemon，不启动 VM，不修改 AMFI。

用户已明确要求“提交和部署修复内容”。部署沿用本会话既有系统 Store 和独立 VM。首次 `sudo -n` 返回 `a password is required`，未执行安装脚本。用户随后在自己的终端执行具名脚本并回复“已完成”；收据记录安装时间为 2026-10-22 10:46:25（Asia/Shanghai）。

## 构建来源与结果

release CLI 和 VM 在提交后构建，生成的 `VPhoneBuildInfo` 标记为 `a0119127`。构建保留现有工作区作为已验收基线，提交仅覆盖本次 APIProxy 修改；构建记录列出其他工作区差异以及 512 个源码文件摘要。构建后逐项核对摘要未改变，并核对 APIProxy 源码及回归与该提交一致。该包从保留已有改动的工作区构建，未使用干净提交检出作为构建输入。

新 Bundle 从已安装并核验的 `2.6.2-local.af333c78ac3b` 复制资源，替换两个宿主程序，重新执行权限签名、原生依赖封装、构建记录与最终签名。`check_bundle.py --execute` 的资源、权限、依赖和外部目录/符号链接资源解析均通过；该检查不启动 VM。

逐文件比较仅发现以下变化：`vphone-cli`、`vphone-vm`、新增 `api-proxy-fix-provenance.json`、`build-dependencies.json`、签名资源表。客户机资源和 Framework 库保持字节一致。

| 对象 | 摘要 |
| --- | --- |
| 归档 SHA-256 | `00a12bba36b45355ca53bb73065315c78959676dd620e008d4efb0e840bbbb76` |
| CLI SHA-256 | `3be5bc6c90397b79e160c42c27b70f01298582b2678ea380b9ca4e57e79f12c8` |
| VM SHA-256 | `266810c8ae29af8fbc8e54a2c0a684b439dfea55f96b503aa8e6d4fa2ab3b439` |
| CLI CDHash | `c0b6d378e2f3076b9dc0f81fe9c4e4aba8a36d4c` |
| VM CDHash | `89cb8ee4c9f47b15a1c63bd73c99b53a0d43a541` |

归档保存在 `.build/t52-api-proxy-deploy-20261022/2.6.2-local.266810c8ae29.tar`，185183232 字节。二进制和归档不纳入 Git 提交。

## 安装与核验流程

`install-api-proxy-fix.zsh` 固定现有安装器和归档摘要，使用既有 root-owned 安装器新增新版本并核验收据。脚本不重绑 VM，不请求临时安全放行。

安装后已执行 `.venv/bin/python -B research/upstream_integration_2026-10-15/tools/finish_t52_api_proxy_deployment.py`，退出码为 0。脚本核对新版本收据、两个可执行文件摘要、停止状态、磁盘释放和受保护文件基线，再通过生产 `vm bind-core-bundle` 入口仅重绑 `t52-v2`。命令携带旧绑定 SHA-256 `6af5c034a1837f05b3f4246203c0ff42240913f532c6e73bf026d9891510fabc`，拒绝选择后的绑定变化。随后核对新绑定、磁盘元数据和选定配置摘要、其他独立副本及原 VM 状态，重新核验新旧 Bundle 收据。

此前源码验证包括 APIProxy 13 项，以及原混合组合增加 2 项回归后的 110 项连续 3 轮通过；详见 [排查记录](T52_APIProxy_stop_race_20261022.md)。本部署不包含新二进制的真实 VM 启动验证；该 VM 二进制的新哈希如需临时放行，仍须单独批准，不复用已结束的窗口。

安装、绑定和保留检查均通过：新旧 Bundle 收据有效，已安装 CLI/VM 摘要匹配候选；新绑定 SHA-256 为 `6f33f9c5c95d402dcf93b492f7f30e0910238a8da0a1b128907f93bdf70694f2`。客户机磁盘的设备号、inode、大小和修改时间保持，选定小型配置文件的摘要保持；未执行整盘内容摘要核验。其他验收副本的受保护文件保持，原 VM PID 33355 的进程记录保持，目标磁盘无进程占用，临时 AMFI 辅助进程不存在。结果保存为 `deployment-result.json`。

本次提交和部署已完成，未推送。新版本的真实 VM 启动未验证；T52 的摄像头/定位应用行为仍未验收，物理外置卷按用户指示暂缓，整项 `accepted=false`。

提交、构建与部署证据见 [部署证据清单](evidence/T52-APIProxy-deployment-20261022/manifest.json)。
