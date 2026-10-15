# T11/T12：稳定 VM 身份与固件 generation

## 实现边界

本次实现稳定 VM 身份、原件集合与 prepare 来源验证。未新增二进制补丁，未修改内核匹配、替换指令、补丁偏移或五模式声明成员。

`VPhoneFirmwareIdentity.read(in:)` 严格读取 `config.plist` 的 `machineIdentifier`，使用 `VZMacMachineIdentifier(dataRepresentation:)` 验证，并记录 SHA-256。读取拒绝缺失、空值、损坏、符号链接和未知配置 schema。磁盘身份记录配置中的文件名、`st_dev`、`st_ino` 和 birthtime 秒/纳秒；正常原位写入不改变这些字段。替换、复制或导入产生的磁盘文件需要显式重新绑定。身份不包含 bundle 绝对路径、目录 inode、磁盘 mtime、ctime、长度或内容摘要。新建 bundle 在初始化时生成 machineIdentifier，未启动 VM。

新 `FirmwarePlanBinding` 使用 schema 2。新 journal 在目录改名后可以恢复，仍验证原件内容和磁盘身份。旧 schema 1 的缺省字段重新编码时保持缺省，保留目录 inode、配置摘要和绝对路径的恢复语义；其 `currentCatalog: true` 验证拒绝新执行。journal v1/v2 的显式恢复不升级旧数据。旧 create checkpoint 的路径约束没有迁移。

## 来源和公开接口

`FirmwareGeneration.Source` 仅遵循 Sendable，没有公开构造函数，也不遵循 Codable/Decodable。可解码 `Provenance` 是记录数据，不能转成 Source。原有 native prepare 实现移入 `FirmwarePreparation`，CLI 使用类型别名保留入口。

- `FirmwarePreparation.prepareWithSource(iPhone:cloudOS:bundle:bootROMSource:preserveExistingRestore:isCancelled:)` 从本地档案重新提取，执行真实合并与 manifest 生成。它固定生产 generator；原有故障注入 `generateManifest` closure 仅在模块内部测试重载可用。来源记录两个输入 BuildManifest 的精确字节 SHA-256、两个完整档案 SHA-256、build、当前组合设备、AGX 文件名集合和捕获的工具 ROM 摘要。档案提取前后核对完整摘要；原件集合从本次生成树和已比对的工具 ROM 取得。
- `FirmwarePreparation.verifyPreparedSource(iPhone:cloudOS:bundle:bootROMSource:isCancelled:)` 是旧树和 script 输出的显式识别路线。它在临时目录中执行独立的新 prepare，逐字节摘要比较当前树和 ROM。缺来源或输出不同则拒绝。该接口不从文件名、版本元数据或旧原件目录猜测来源。
- `FirmwareGeneration.prepare(in:inputs:source:) -> Prepared` 在 `.firmware-generations/.pending-*` 中创建完整原件快照；源和副本逐字节摘要读回，拒绝同长度改写、符号链接、硬链接和特殊节点。预检完整原件逻辑字节数并保留 10 GiB 余量。
- `FirmwareGeneration.publish(_:planSHA256:) -> Manifest` 再次检查身份、manifest 和原件后，使用排他 rename 发布到 `.firmware-generations/<id>`。已有 generation 不覆盖。manifest 和计划关联使用临时文件、fsync 和排他 rename；失败与取消不删除旧 generation。
- `FirmwareGeneration.loadVerified(in:id:) -> Manifest` 校验 schema、内容身份、稳定 VM 身份及完整原件集合。`originalURLs(in:id:)` 返回已验证原件路径；使用者仍需持有 bundle 锁并在事务中读回。
- `FirmwarePipeline.resolvedPlan()` 返回与事务预检相同的计划。`FirmwareGeneration.planDigest(_:)` 对完整计划编码求摘要。`FirmwarePipeline` 的可选 `generationID` 进入新绑定；绑定验证 generation 原件集合必须与事务输入完全一致。

generation ID 是 Content 的 SHA-256，Content 包含 VM 身份、来源和完整原件摘要，不包含计划摘要。目录树摘要覆盖节点名、节点类型、空目录及所有文件字节。计划摘要在 `plans/<planSHA256>.json` 单独记录，状态为 `prepared`。该文件不声称补丁已经应用，不能替代后续执行收据。

来源边界是“本程序从指定本地档案重新生成并验证的字节”。公开来源接口拒绝 VM 内 ROM 自身作为独立参考。本次未验证 Apple 签名，也未引入抵御本地持有写权限者同时重写全部记录与摘要的签名机制。`gpuInputs` 表示真实 AGX 输入文件名，不声称已识别宿主 GPU 型号或验证 GPU 兼容性。

## CLI 接入与成本

`vm create` prepare 阶段取得 Source 后，在 bundle 锁内捕获 generation、解析计划并发布，记录 `firmware_generation_id`。patch 阶段拒绝无 generation 的旧 prepare evidence，提示从 prepare 重新开始；有效 ID 传入真实 FirmwarePipeline 和 transaction 绑定。prepare 恢复验证完整保存原件；当前 restore 树即使已经 patch，原件快照仍单独保留。

script backend 保持默认，less 保持其现有入口。脚本成功后写出实际 IPSW 路径记录。create 使用这两个档案独立重建参考树并比较，因此路径记录本身不授予来源资格。真实 `fw_prepare.sh` 的 regular 和 less 小型 ZIP 测试均通过；less 使用预置临时 seal 工具文件，未下载、执行工具或挂载磁盘。native backend 对 less 的既有限制保持不变。

script 来源识别增加一次完整 IPSW 提取、合并和多次流式摘要读取。临时参考树在失败、取消和完成时清理；native 提取预检和 generation 快照预检均保留 10 GiB。保存的 generation 和旧 prepare 备份没有自动清理策略。真实固件成本、容量和时间尚未测量。

磁盘替换必须使 generation 失效。CFW 的原子磁盘替换、clone/export/import 后的显式生命周期重新绑定尚由后续任务处理。既有旧 create checkpoint 的目录路径迁移也未实现。独立 `fw prepare` 的普通调用保留原行为；后续计划工作可以调用公开来源接口取得资格，不能将旧目录直接加载为 Source。

## 验证

Swift 使用 `/private/tmp/vphone-five-tasks-swift-20261012`，未覆盖主 `.build`。Python 使用项目 `.venv`。

- RED：旧实现编译通过后，目录改名恢复被 vmPath 拒绝；相同字节的新磁盘文件仍被旧绑定接受。2 项测试、2 个 issue，退出 1。
- 包含修复夹具的回归：430 项测试、52 个 suite，通过，退出 0。范围为 FirmwarePatcherTests、CreateCheckpoint、CreateLiveStages、NativeFirmwarePrepareTests、DoctorCLITests。
- 最终任务指定范围 136 项通过，退出 0；追加原子写入验证见 evidence 索引和任务报告。覆盖 A→A、计划 A→B→A、来源 A→B→A、改名、磁盘替换、正常磁盘写入、坏原件、链接替换、中断、取消、独立识别路线、旧 schema 恢复及真实 native create prepare 接入。
- prepare Python 回归：20 项通过，退出 0。初次受限运行 4 个本地 HTTP 测试因沙箱禁止 bind 失败；正常提权后通过。
- 完整 firmware-free 首批：1340 项测试、22 个 issue。15 个 issue 来自旧合成夹具缺少新的严格身份，已补齐并在 430 项回归中通过。其余 7 个 issue 为既有 CLI 测试硬编码主 `.build/debug/vphone-cli`，该文件不存在。没有弱化这些断言或写入主 `.build`。本次不声称全量通过。

原始日志以 gzip 保存，原始及压缩字节的 SHA-256 见 [证据索引](evidence/2026-10-12-firmware-generation/index.json)。本次未执行真实固件创建、恢复、VM 启动、应用、AMFI/TCC 操作或系统服务安装。测试结果不构成五模式 VM 验收。
