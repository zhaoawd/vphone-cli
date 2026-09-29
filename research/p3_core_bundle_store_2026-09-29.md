# P3 Core Bundle 安装存储与收据

本批以固定上游 `2.0.8`（`9d218dedf58d4b19db5e51c8b584c1f14a96eee3`）的 `VPhoneLaunchpadBundleStore`、`VPhoneLaunchpadHelperBundleInstaller` 和 `VPhoneLaunchpadHelperCodeCheck` 为参考，新增独立 `VPhoneBundleStore` SwiftPM 模块。CLI 与后续 helper 可共享该模块，模块不依赖 VM 框架。

## 入口与授权范围

- `vphone-cli core-bundle install --version VERSION --archive PATH --sha256 HEX`：要求有效 UID 为 root，由用户显式通过 sudo 调用。没有自动 sudo 重执行、AMFI 修改或 VM 激活。
- `vphone-cli core-bundle verify --version VERSION`：只读验证，可由普通用户调用。
- 生产存储固定为 `/Library/Application Support/vphone-launchpad/Bundles`，与上游一致；没有 `--store`、任意 executable 参数或环境变量覆盖。临时目录和非 root 所有者只通过模块内部测试初始化器注入。
- `withVerifiedExecutable` 只接受枚举 `vphone-cli` / `vphone-vm`，完成复核后在持锁回调中交付路径。未来消费者必须在回调内完成子进程等待。
- SHA-256 是已获授权调用者提供的预期值。ad hoc 签名证明内容完整性，不能证明发布者身份；此模块没有实现远程发布来源认证。

XPC 连接身份、Authorization Services 管理员授权、Launchpad 调用、系统 helper 注册，以及 CFW 受控操作接线仍未完成。本批没有安装系统 helper，也没有把现有 CFW 入口切到新存储。

## 安装与验证

1. 检查版本格式及最低版本 2.0.8。遍历系统存储祖先，要求真实目录、root 所有、无组/其他用户写权限及扩展 ACL。拒绝路径中的符号链接。
2. 在存储内创建排他锁和 0700 暂存目录。从普通文件描述符使用 `pread` 复制并计算 SHA-256；不重新打开调用者路径，不修改其共享 seek offset。最大归档 8 GiB。
3. 解包前检查成员：只允许 `VPhone.bundle` 下的目录、普通文件和受限相对符号链接。拒绝重复路径、绝对路径、`.`/`..` 成员、硬链接、特殊文件、setuid/setgid/sticky；最多 100,000 个成员、总声明大小 16 GiB。libarchive 的安全路径选项继续有效，不恢复归档用户、ACL 或文件标志。
4. 再次遍历解包树，拒绝硬链接、越界符号链接和扩展 ACL；安装目录与可执行文件规范为 0755，其他文件为 0644，所有者为 root。校验 Info.plist 版本，以及 `vphone-cli`、`vphone-vm`、`vphone-escalator` 普通可执行文件。
5. Security.framework 严格校验 bundle、嵌套代码、所有架构及资源，记录 CLI/VM cdhash。使用 `kSecCSSingleThreaded` 进行资源校验，保留全部校验项。
6. 收据兼容上游字段 `version`、`sha256`、`installedAt`、`cdhashes`。bundle 与收据先写入同一暂存目录，再通过 `renamex_np(RENAME_EXCL)` 一起发布。同版本已有目录（含悬空链接）一律拒绝，不删除原安装；本批没有提供删除或替换入口。
7. 使用前再次检查目录树、所有权、权限、ACL、收据结构与版本、bundle 签名和二进制 cdhash。仅读取 CodeDirectory 不足以发现保留 CodeDirectory 的二进制页面修改，因此 cdhash 读取前也执行完整签名校验。

## 验证记录

专项测试使用临时目录中的实际 ad hoc 签名 bundle；载荷由系统 `true` 的副本重新签名生成，不运行 VM。覆盖发布成功、重复安装保留原内容、摘要错误、版本错误、危险链接、权限/ACL、收据与二进制篡改，以及命令行禁止绕过参数。

首次编译修正 Darwin 的 mode_t 与 ACL 常量类型。归档 reader 保留原 `entries(of:)`，新上限参数使用独立重载，避免已有目标链接入口变化。宿主实测无 ACL 的既有目录返回 `ENOENT`，实现增加 `lstat` 存在性复核。并行测试采样显示多个测试线程在 `SecStaticCodeCheckValidityWithErrors` 的资源任务组等待；据此改用 SDK 定义的单线程资源校验选项，未关闭任何签名检查。

完整回归首次另发现资源型 bundle 夹具在修改 Info.plist 后未重签内部可执行文件，导致 `-67030 invalid Info.plist`。已将夹具签名移至最终 Info.plist 编辑之后，顺序与上游 StageBundle.sh 一致。另一个既有 0.5 秒进程超时测试未读到 `ready`；原因未查明。新增签名测试改为串行，以减少测试间资源竞争；没有修改进程 runner 或延长该超时。`umask 077` 下 23 项 Core Bundle/CLI/进程 runner 专项通过，包含上述两项。

完整回归最终结果：Python 391 项通过；修正测试夹具后，`make test_swift` 的 Swift Testing 725 项 / 102 suites 通过，XCTest 178 项完成（3 项跳过、0 失败）。归档内存检查、RootHide loader-link 检查、相机 data-plane 124 项检查通过。日志分别为 `research/artifacts/upstream-remaining-2026-09-29/core-bundle-regression.log`（首次完整运行，保留两项失败）、`core-bundle-private-umask.log` 和 `core-bundle-swift-final.log`。

完整上游 Core Bundle 发布归档、系统 root 安装、跨 UID 读取及真实 helper/VM 验收尚未执行。当前本地 `make build` 产物仍是既有 app 布局，不能把测试夹具的成功安装记为 v2 分发包验收。

提交 `d0efbf4` 的 `make build` 通过，包含资源、签名与 entitlements 隔离校验。签名 CLI 的新增安装帮助返回 0；普通用户调用安装返回 64，明确要求 sudo，未打开归档或创建系统存储。产物摘要和日志摘要见 [构建记录](upstream_core_bundle_artifacts_2026-09-29.json)。新 VM cdhash 为 `e8bd850394e4b8bd6af78461a1e0178312ef3954`，本批未对其执行 AMFI 放行或 VM 启动。
