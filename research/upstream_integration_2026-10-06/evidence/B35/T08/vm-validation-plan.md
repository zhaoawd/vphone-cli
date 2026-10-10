# B35：具体运行验证对象与条件

状态：准备完成，临时 AMFI 尚未执行。`scoped_amfi.py --check` 退出 0。新工件 `--help` 退出 -9；精确时间窗/路径日志记录 AMFI -424。已有批准限定其他冻结 CDHash，不能自动延伸到本次工件。

## 对象

- 宿主：仓库 `.build/research-b35/source/.build/vphone-cli.app/Contents/MacOS/vphone-vm`。
- SHA256：`a4f8a4155a95e3d0c9067f856bb09a165df22cc9e55fcf9356f01ab16b0d11f4`。
- CDHash：`62026af109b33fdd468c2c2df2fcdb4211136bf0`。
- 现代 API：该隔离快照 `.build/daemon-api-v2/candidate/vphoned`，SHA256 `36005e2af21d8e72e0b944e5f38c0bdfa373b86e3bb67b889ec4245c3165dd1a`。
- 现代组件：该快照 `.build/guest-components-v2/stage`；六项映像、来源及摘要见 `guest-components-manifest.json`，相机共享内存头为 64 字节。
- 客户机：仅 `vm-roothide-b33-20261010`。源 `vm-new` 的健康监测暂停、正常停止及实验后恢复沿用已批准方案。

## 需要批准的动作

暂时向系统 amfid 附加调试会话，仅允许上述单一宿主 CDHash，`paths=[]`、`allow_all=false`、`spoof_apple=true`。驱动使用进程内固定空配置，不读取或重载持久允许列表。实验结束删除调试断点、detach 并停止本轮辅助进程；独立核对系统 amfid 状态。此操作需要管理员执行；不在聊天中提供密码。

用户在本会话提供的 AGENTS.md 执行约定 4 要求：“删除数据、强制推送（force push）或修改当前仓库以外的内容之前，停止并请求确认。”该会话修改系统进程的临时验证结果；既有精确哈希批准不包含本次新 CDHash。这里只准备本地驱动，未执行附加。若已有其他调试会话，不停止或修改该会话。

## 批准后的顺序与断言

1. 重新核对 SHA256、CDHash、完整 Bundle 签名及候选 manifest；先验证宿主 `--help`，不启动 VM。
2. 核对源身份和原健康监测身份；按已批准方案暂停精确监测、正常停止源。确认源磁盘释放。源再次自动启动则暂停实验，不重复停止。
3. 对研究副本保存冷态恢复副本；通过现有 `cfw_env_update.py check-vm` 取得只读兼容性报告。本轮 `sudo -n` 退出 1，原因是需要密码，没有发生 attach/mount，不能宣称已完成兼容性分类。
4. 按分类准备完整 guest 组合。若是 classic `/b`，现有 updater 会返回 `full_migration_required`；不能用只替换 dylib 的方式宣称完成迁移。实际磁盘分类和适用迁移步骤未确认前不写入。迁移若涉及现有批准之外的对象或动作，先提交具体差异。
5. 用新宿主 `--no-vphoned-update` 保持显式 guest 来源。API_ONLY 仅作为控制组：它继续跳过 RootHide 恢复和相机启动。完整启动组必须使用匹配的现代相机组合，并停用旧 classic 发布端，避免两个发布端改写同一共享内存。
6. 冷启动后不调用显式 Irisin 激活或 `services.load`。核对完成标记、物理根、加载后的 plist、Irisin/SSH 服务状态及 SSH banner，保存 daemon/组件运行摘要。单独区分启动恢复验收与默认产物验收。
7. 正常停止研究副本，验证磁盘释放；按原 argv 恢复源并 SIGCONT 原健康监测，核对新 healthy 采样。清理本轮临时工具，保留证据和恢复副本；退出本轮 AMFI 会话，独立核对清理结果。

运行期间持续监测磁盘。低于 5 GiB 时停止研究操作并正常停止本轮研究 VM；不继续安装、构建或复制。真实 VM 自动激活和默认现代 daemon 打包的接受条件仍未满足，不能由构建成功推定。
