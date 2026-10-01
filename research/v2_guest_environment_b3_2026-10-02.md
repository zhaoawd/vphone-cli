# v2 环境 B3：离线安装器

日期：2026-10-02。依据 v2 设计第 2、3.1、3.4、7.1、8 节。

## 实现

新增 `scripts/cfw_env_install.py`。CLI 只接受位于 VM 目录内的 System 挂载点；T15 驱动接入留给 B4。安装前检查候选摘要与代码签名加载命令、API plist 身份、CFW 完成标记、目标文件类型和 bootstrap 状态。接受清洁 classic System 卷，或已记录且库与候选一致的 v2 重装。其他状态退出 3，并写 refused 报告；系统树不变。

写入 5 个库、`/vh`、API 二进制与 plist。在缺少 `/vh` 加载命令时，备份 launchd、调用已有 `cfw.py inject-dylib` 弱注入，再用原 entitlements 与证书调用 ldid；核对加载命令、签名命令与 entitlements 后才写回 launchd。重装时保留两个备份，不重复注入或签名。新增 `cfw.py inject-daemon`，只修改当前 launchd.plist 的指定条目；保留其他条目与 `.bak`。

报告 schema 为 `vphone.guest-environment-install/1`，记录源清单摘要、每个写入文件的前后摘要、权限与属主、launchd 加载命令和 entitlements 摘要、前后判定、预留文件及事务 ID。后置要求 already_current，API 摘要与注入键均一致。写入或卸载失败标记 failed；上层 T15 必须拒绝发布。

## 测试与证据

- 首个成功路径测试在文件不存在时失败，实施后通过。
- 增量失败复现：已有不同库原先被覆盖（0 != 3）；缺少 CFW 标记原先在写入后失败（1 != 3）；单守护进程命令原先不存在；卸载失败原先仍记录 installed。修正后对应断言通过。
- `tests.test_cfw_env_install`：11 项通过。覆盖成功、不同库拒绝、缺标记拒绝、classic/unknown/冲突别名拒绝、摘要/签名拒绝、重装、第二个库 EIO、entitlements 改变、卸载失败和真实 insert_dylib。
- 真实工具测试用 clang 编译 macOS 合成可执行文件，再执行项目 `cfw.py inject-dylib`；核对恰有一个 `/vh` 弱加载命令。未执行该二进制。
- `.venv/bin/python3 -B -m unittest tests.test_cfw_env_install tests.test_cfw_env_update.AssessTests tests.test_bundle_validation`：34 项通过。
- `make test_python`：575 项通过（148.358 秒）。该次全量运行含前 10 项安装器测试；最后新增的卸载失败测试与对应修复由上述 34 项相关测试复核。
- `git diff --check`：通过。包资源检查已要求携带新安装器。

## 验证限制

合成树测试以调用者 uid/gid写文件；产品默认 root:wheel（0:0）。合成 launchd 的 ldid 与注入命令为替身，真实工具测试只验证 macOS 合成文件的弱加载命令。未验证真实 iOS launchd 签名、系统卷挂载、root:wheel 文件安装或启动。未安装到任何 VM。原生 APFS 安装脚本未执行。
