# P1a/P1b 上游整合记录

提交记录（2026-09-28）：按用户要求，将本记录对应的代码、测试及相关文档纳入本次整合提交。下文的“未提交”描述保留各阶段记录时的状态；验收范围和未验证项目不变。

日期：2026-09-28。当前分支为 `codex/upstream-4bab3b7-integration`，起点为 `bc3bfa8`。用户要求跳过 P1c 真实导入及导入后启动验收，继续其他整合；本轮未删除 VM、导入磁盘、启动 VM 或调整宿主执行准入。P1c 未验证项目保持未验证。

## 来源与应用方式

- P1a 来源：上游 `1.0.14` 的 `9c23c8adcd4b362120988ab9d228b959bcc23ae3`，涉及 catalog、FirmwarePickerTests 和四份 README。已通过 Git 获取固定提交并核对原始差异。
- 工作区已有 P1c 及 README 修改。本轮从固定提交生成仅含上述六个文件的补丁，经 `git apply --check` 后应用；未执行会要求索引与工作区匹配的 cherry-pick，未覆盖既有修改、暂存或创建提交。后续拆分提交需保留来源 `(cherry picked from commit 9c23c8adcd4b362120988ab9d228b959bcc23ae3)`，并说明本地清单及测试适配。
- P1b 参考固定 `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3` 的 `VPhoneExecutable/VPhoneCommand/FirmwarePatcher/DyldSharedCache/Patchers/DyldSharedCacheCameraPatcher.swift`。已核对源码中的全站点预检查、已补丁识别及页签名处理。本地保留 Python 入口、ipsw 符号解析、Keystone 编码和 EXP 调用范围。

## P1a 结果

新增 iOS 26.6.2/23G90、27.0 RC/24A435，均配对 cloudOS 26.4。目录由 23 条增至 25 条。兼容性 JSON 与说明、英文/中文/日文/韩文 README 同步；五个变体的新增组合仅为 `code_selectable`。原条目、默认选择和已有实测等级保持不变。

保留上游 Tested Environments 两行，并明确其来源与本地未验证状态。新增参数化菜单测试，验证两个构建号都能选择到对应 IPSW 与 cloudOS URL。

## P1b 行为与边界

1. 两组符号全部解析后，读取并分类六个目标。分类为原始、已补丁、不匹配。原始入口通过 Capstone 解码识别 `pacibsp`；替换指令由 Keystone helper 生成。
2. 默认不匹配、缺符号、短读、跨 chunk 或重叠目标在指令写入前拒绝。`force` 仅允许覆盖不匹配指令，不跳过输入完整性与页签名检查。日志记录符号、VMA、chunk 文件偏移、状态和前后字节。
3. 写入前要求目标页存在完整、可读取的 SHA-256 CodeDirectory slot。只写入尚未匹配的指令；包括已有补丁在内的所有目标页统一重新校验签名，覆盖跨页的 8 字节指令范围。写入后检查目标字节和实际页哈希；签名 helper 静默跳过也不能计为成功。
4. 全部已补丁的有效输入保持字节不变。混合输入只补齐剩余指令；之前中断导致的陈旧页哈希可在重跑时修复。
5. 保留 AVF-only、dry-run、显式 force 和两组/一组的返回值。dry-run 完成目标分类后不写入指令或页哈希，不代表签名验收通过。
6. I/O 写入及哈希失败继续抛错，不承诺回滚。`cfw_install_exp.sh` 原有“相机补丁失败后继续安装”的策略未改变；只修正过时的幂等性注释，因此安装继续不能证明相机补丁成功。

## 验证

- 新增 17 项相机 DSC 测试已通过。夹具为约 12 KiB 的合成文件，使用实际 DSCChunks、CodeDirectory 解析、页重签和完整哈希比较；符号解析结果由测试注入，不是实际固件证据。
- 覆盖全部原始/全部已补丁、NU 已补丁与 AVF 原始、NU 组内混合、最后目标不匹配、缺符号、短读、dry-run、force、AVF-only、写入失败/重跑、哈希失败/重跑、静默跳过、缺 CodeDirectory、写后字节异常、跨页和重叠目标。
- `make test` 退出 0：Python 369 项通过（含 17 项新增相机 DSC 测试），Swift Testing 497 项、67 个 suite 通过；XCTest 145 项、3 项跳过、0 失败。目录/清单一致性和新增两个条目的菜单选择通过。
- 原有归档传输内存回归通过：file/producer 两条 1 GiB 路径峰值 RSS 分别为 8,585,216 / 8,978,432 字节，字节计数及单调进度通过。
- `.build/debug/vphone-cli fw catalog --json` 退出 0，实际输出 25 条配对；23G90 与 24A435 均推荐 cloudOS 26.4。`zsh -n scripts/cfw_install_exp.sh` 与 `git diff --check` 通过。本轮未执行签名 Release 构建或 VM 执行验收。
- [完整测试日志](artifacts/p1ab-2026-09-28/make-test.log)和 [CLI catalog 输出](artifacts/p1ab-2026-09-28/catalog.json)保存在忽略的 artifacts 目录，不随文档提交自动分发。
- 工作区未找到已解出的 `dyld_shared_cache_arm64e*` 实体输入；未挂载或解包 VM/固件。真实 DSC 副本上的字节、页哈希及 EXP 运行验收保持未完成。

## 后续工作

P1a 完成后保留目录可选择语义。P1b 仍需真实 DSC 副本验收。P0 的逐变体补丁映射、相机 ABI、夹具准备及 P2–P8 尚未完成；P1c 真实导入、导入后启动和相应数据验收按用户要求跳过。以上工作区修改尚未提交。
