# Task 8 最终签名工件准备（2026-10-13）

本轮在 `/private/tmp/vphone-task8-acceptance-build` 建立当前工作区源码副本。副本包含未提交的 Task 8 实现和 Capstone `Instruction.swift` 修改。主工作区 `.build` 未用于此次构建。未读取根目录 `TODO.md`。

`make build` 完成 release 编译、CLI/VM 签名、classic 和 v2 guest daemon 构建、资源封装、原生依赖闭包处理和最终 Bundle 签名。`check_bundle.py`、`codesign --verify --strict --deep` 和签名 app 中的 `vm update-kernel --help` 均通过。构建出现既有编译警告，日志保留。

候选路径：`/private/tmp/vphone-task8-acceptance-build/.build/vphone-cli.app`。`CFBundleShortVersionString` 为 `2.6.20261013`，`CFBundleVersion` 为 `202610138`，拟用存储版本为 `2.6.20261013-local`。版本修改仅发生在构建副本。

- `build-source-manifest.json`：源码文件 SHA-256、主仓库提交、子模块版本、Capstone 差异及构建输入。
- `signed-app-manifest.json`：最终工件路径、SHA-256、CDHash、验证结果及 Bundle 文件清单。
- `signed-build.log`：完整成功构建日志。
- `signed-build-sandbox.log`：首次构建受 Swift ModuleCache 沙箱写入限制的日志。
- `signed-build-missing-tests.log`：独立副本初次缺少 SwiftPM 测试目标目录；补齐后重建成功。

API daemon 使用已缓存且固定版本的 SourcePackages。缓存记录中的 libarchive 二进制路径指向既有 handoff 工作区的下载工件；本轮只读取该文件。最终 Bundle 的可移植原生依赖检查通过。

`make build` 的 app 布局不包含 Core Bundle store 硬性要求的 `vphone-escalator`。最终本地候选已加入下述历史组件，完成 `VPhone.bundle` 布局归档。已找到 B22 历史本地构建，归档 SHA-256 与既有研究记录一致，解包文件与归档成员 SHA-256 一致，签名验证通过。`escalator-provenance.json` 记录该组件来源及检查结果。它来自固定上游版本的历史本地编译；未将其描述为官方发布工件，也未执行它。

本记录只证明工件准备和静态验证。未安装系统 Core Bundle，未更改 AMFI/TCC，未启动或修改 VM。

## 最终 Core Bundle

新增 generation 准备入口经过相关测试后，已同步到构建副本并重新执行 `make build`。最终签名 app 的 `fw generation-prepare --help` 和 `vm update-kernel --help` 均通过。前版 app 清单保存为 `signed-app-before-generation-preparation-manifest.json`；其哈希不代表最终工件。

最终候选为 `/private/tmp/vphone-task8-acceptance-build/core-candidate/VPhone.bundle`，ZIP 为同目录的 `VPhone.zip`，SHA-256 为 `765619552c2861d108acc03284f32a8cc04869ee58f3a3f249436b2735091c47`。存储版本为 `2.6.20261013-local`。CLI CDHash 为 `37ce558ac9f4b40894bb8c475910482190cf76ed`；VM CDHash 为 `2ce532c039be2dd010f009625079aabba20b9d0b`。

`core-candidate-manifest.json` 记录最终逐文件哈希、签名和依赖验证。`package-core-candidate.py` 记录打包操作。初次打包在增加资源后、重新签名前进行依赖检查，被资源封印验证拒绝；调整顺序为先重新签名，再检查并更新依赖记录，最后再次签名后通过。失败日志保留为 `core-candidate-package-before-reseal.log`。未忽略签名检查。

历史 escalator 字节与已记录 B22 归档完全一致，来源 JSON 和 MIT 许可证已纳入最终 Bundle。该组件未执行。本构建子任务未安装系统存储，也未改变 AMFI/TCC。
