# T32/T33 EXP 签名与 Cryptex 部署续推（2026-10-25）

## 最新执行状态

原root71942和只读收尾75263已结束，计划b2f587be…结果failed。launchd补丁与签名通过，首次on在JB-2新增未声明归档成员时被拒绝，没有发布、撤销或重应用。独立收尾源备份10项完整读回、290/94输入、10个保留磁盘身份及无附件通过。未重试或启动VM/辅助窗口。后续修复和准备见`T32_T33_dev_overlay_20261025.md`；以下为当时签名修复准备阶段的记录。

## 当前结果

regular 三项 Mach-O 的完整应用→撤销→精确重应用结果保持。EXP 原执行器4181在01:31失败停止；首次应用未发布，撤销和重应用未执行。原执行结果记录源备份10项完整读回通过、目标无附件，VMStarts=0、securityWindows=0。09时本轮只读复核再次完成源备份10项完整字节及身份、10个保留磁盘身份检查。

本轮完成三个问题的复现或修复，未安装新候选、写入 VM 或启动 VM。真实 EXP 循环和 Settings/AA.gl/应用消费仍未通过，整体 `accepted=false`。

## 问题、证据和修改

1. **classic 注入后缺少签名命令空间。** 冻结候选 caa8df845ab6 的 `cfw.py` 没有调用已有的 `reserve_signature_command`。失败事务 `20261024T171227Z-aJA6rrkA` 保存的签名前字节经实际 ldid 稳定复现 `signature load command overwrote non-padding bytes`：命令区从3208扩展到3224。当前工作区已接入该步骤，本轮核实其相对安装候选的精确差异。实际原件经过受限注入→jetsam补丁→实际签名→最终效果读取，共5项操作，通过原签名变化检查、全部代码页、CMS完整性及 entitlements 比较。回归同时保留禁用预留步骤时的原错误。没有更改原覆盖非零字节的拒绝条件。
2. **EXP 缓存修改未必复制到现有 Cryptex。** 原基础安装器只按目录非空判定跳过，忽略 EXP 预先修改的缓存。执行实际 Shell 分支的目录夹具复现旧内容保留；regular和显式重装对照通过。基础安装器现对 EXP 执行原有缓存复制路径；其他变体保持原来的跳过条件。两份缓存复制后的最终成员验证仍由原效果读取器执行。没有使用环境变量临时绕过正式入口，也没有向旧计划追加参数。
3. **合法 `__LINKEDIT` 保留空间被误拒绝。** 剩余实际 BaseBin 资源预检在 `libellekit.dylib` 复现 `linkedit sizes do not describe actual signature layout`。原 arm64 slice 的 vmsize=229376、filesize=199744；重新签名后 filesize=210080、vmsize仍为229376。Apple 的 [loader.h](https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h) 允许 vmsize大于filesize，额外部分按需补零。校验器现接受输入已有的页对齐保留空间；输出只能保持该数值或使用原有4/16KiB向上对齐大小，且必须覆盖实际文件范围。任意额外扩张、无效输入、实际文件范围不符、非签名字节变化仍拒绝。最小回归先复现误拒绝再通过；原巨量扩张拒绝用例保持。

## 可重复验证与限制

- `.venv/bin/python -B -m unittest tests.test_component_signatures tests.test_classic_launchd_signing tests.test_exp_cryptex_install tests.test_exp_cryptex_skip_transport`：签名结构、实际ldid、原错误对照、Shell分支及最终transport读取器回归通过，原始失败日志保留。
- `verify_t33_launchd_preflight.py --history .build/t33s-20261025/.cfw-history/20261024T171227Z-aJA6rrkA --certificate .build/t33s-20261025/cfw_input/signcert.p12 --output <新JSON路径>`：真实保存字节及生产补丁、签名、证据、最终读取器通过。plan和挂载根为隔离夹具，不构成真实 APFS 部署。
- `preflight_t33_remaining_resources.py` 对实际候选执行三项原 Shell 编译函数，并检查三份实际 BaseBin 库、debugserver、watchdogd及6529项bootstrap成员。前三类签名产物的CMS/全部代码页通过；watchdogd按生产约定只重新证明代码页，不声称CMS重签名。没有执行debugserver。bootstrap实际原生解包及权限设置仍待验收。
- Preboot/System尾部只读检查已完成原生认证和正常只读挂载：两份真实System plist的副本修改、恢复、精确重应用通过；实际DeviceTree IMG4副本修改及重复执行通过，Preboot对应plist缺失。正常卸载、磁盘身份保持、目标无附件；没有创建替代文件。原诊断JSON的`changedProperties=1`是生产函数返回值1，表示文件改变，不表示只改变一项属性；日志实际列出model、target-type和compatible三项。工具已将字段更正为`producerReturnValue`，原结果保持。
- 最终全量Python回归通过：1123项，4项跳过，312.478秒，退出0，命令 `.venv/bin/python -B scripts/run_tests.py python`，日志 `python-full-v2.log`。首次完整1122项（4跳过）、314.799秒、退出0覆盖新增LINKEDIT修复之前的状态，单独保留。
- Shell语法、目标表生成器及候选三份修复资源与当前源码的逐字节比较通过。原执行器7项隔离回归通过；这些回归不包含真实生产阶段。

## 新候选与计划

候选 `2.6.2-local.a480e6e8785e`，归档SHA-256 `3853f706395a15f53ab1ce586596775633f8cc49c9a24af133166457804f9ce7`，195004928字节。相对caa8df845ab6仅修改三份修复脚本、来源/构建记录及签名记录；CLI非签名字节及entitlements、VM程序和客户机资产保持。完整Bundle资源、签名与entitlements核验通过。没有安装到仓库外的Store。

新离线计划 `.build/t32-t33-completion-20261023/exp-signing-acceptance-20261025-r2/offline-plan.json`，SHA-256 `b2f587bee45825e50f997f289d2a08724eb42acf958ceb8673db0b6b02e627c9`，冻结290项计划输入及94项执行输入。只在尚未创建的 `.build/t33t-20261025` 执行EXP两份System plist声明的应用→撤销→精确重应用，逐阶段独立审计、来源和完整原件核验。复用锁定Python环境，保留regular、失败t33s、原件、历史、备份和其他VM，不重跑regular，不启动VM或辅助窗口，不自动重试或回滚。旧候选702b93及其未批准草案保留为本轮预检过程记录，不再建议执行。

准备时可用78643200000字节，低于原75GiB门槛80530636800字节；没有降低门槛或删除数据。新候选安装涉及仓库外 `/Library/Application Support/vphone-launchpad/Bundles/`，按当前AGENTS.md执行约定4，需要用户对具体对象和范围确认。真实尾部只读预检现已完成；取得确认且容量满足后才可执行新计划，失败时停止，不重跑旧计划。真实运行另以离线成功后的实际磁盘和候选形成具名范围。

归档：`evidence/T32-T33-completion-20261023/signing-followup-20261025/manifest.json`（39份，归档时尾部认证尚未返回）；完成后的真实尾部结果及最终报告另存`supplement/manifest.json`，不覆盖原清单。

本轮证据工作目录：`.build/t32-t33-completion-20261023/signing-followup-20261025`。归档仅包含源码、JSON及日志；不归档签名密钥或客户机二进制。

## 用户批准后的复核

用户明确批准a480e6e8785e安装及b2f587be…一次离线范围，前置条件满足后执行；原文及批准标记已保存。290项计划输入和94项执行输入全部摘要复核通过，目标与execution目录不存在。当前78643200000字节（73.24GiB），距75GiB门槛1887436800字节（1.76GiB）；容量条件未满足，尚未安装、创建目标、写盘或发起该写盘范围的认证。批准继续有效，无需重复询问；本次批准不含删除数据、VM启动或辅助窗口。复核见exp-signing-acceptance-20261025-r2/approved-preflight-20261025.json。
