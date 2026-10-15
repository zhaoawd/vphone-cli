# Task 8 第七版正式提交与读回独立审查

日期：2026-10-14。审查者：acceptance_audit。只读检查正式更新、归档 journal/receipt/proof/report、第七版 manifest、只读读回脚本及结果、第四版 host 正式重新绑定证据。仅写本文件及对应 JSON；未读取或操作运行中的 VM 磁盘，未挂载、启动 VM 或修改 AMFI。

结论：证据支持第七版正式离线发布、同 journal 的 installed kernel receipt/来源提交及提交后只读读回成功。第四版 host 正式重新绑定保留第七版 kernel 来源。基线与提交后解码内核 payload 相同，本次属于相同 payload 的重新发布，不能据此证明不同 payload 的更新或启动。真实启动尚不在本审查范围内；提交后 kernel-only 回退入口尚未实现，Task 8/T34 保持未完整验收。

## 正式提交及来源关联

kernel-update-v7.json 记录已安装 `2.6.20261019-local` CLI 对限定 task8-copy 执行无注入正式 `vm update-kernel`，退出 0，用时 3,291.158519 秒。命令显式使用项目 .venv 与 PYTHONDONTWRITEBYTECODE=1。日志只声明 offline publication verified，实际 kernel boot 未验证。

归档 transaction ID 为 `1526d1ea-9f0c-48ae-ae06-f1d65394759b`。独立解析保存文件并执行关联断言，结果通过：

- journal version=3、kernelOnly=true、phase=committed；kernelDisk 为 forward、pending=false，cursor=10,159，等于差异块总数。
- journal、publication、proof 的 transaction ID 一致；publication.records 为空，仅 installed kernelcache receipt，originLayer=kernel，scope=installedComponent，state=committed。
- receipt 唯一输出为 Disk.img，摘要等于候选及 proof.imageSHA256；receipt/proof/report 文件摘要与 journal、publication 及 metadata 输出关系一致。
- proof.version 为第七版，executableSHA256=`28e87067ce7c569cf2d1bd72c33b045f3b9bdb151e2f6291db38b7fbbf452ef3`，匹配冻结第七版 manifest 的 CLI 摘要。
- generation ID、desiredSHA256 和冻结计划关联一致；plan SHA 为 `703f9ad46613fa819ec6460846865ba9cd3ccd389f4b03c078fbc9baae741a3c`，generation 为 `d8d780c97a23b5ea398df872a73ad7aead24af90a08e35cea39c08524e927d62`。
- 119 条 effects.record 与报告全部记录按原顺序完全一致，归属 42 个声明，outputPath 均为 Disk.img。119 条记录包含已核验输出证据，不能表述为 119 项新增修改。
- binding-after-update-v7.json 相对更新前仅新增 kernel=`2.6.20261019-local`；host 仍第七版，guestEnvironment/bootChain 原未知状态保持。

## 实际只读读回

committed-readback-v7-run.json 记录审阅后的独立脚本退出 0，用时 111.910629 秒。脚本持有副本和首次绑定备份的排他目录锁，检查无 pending；分别只读附加、关联唯一 physical store/container/Preboot 卷，验证卷 UUID、精确挂载目录、只读状态和挂载目录身份；遍历错误不忽略，内核目标必须唯一普通文件；finally 卸载并复核附件。结果中 20 条外部命令均退出 0，passed=true，最终两个镜像的 remaining_attachments 均为空。

| 对象 | 基线 SHA-256 | 提交后 SHA-256 | 结果 |
| --- | --- | --- | --- |
| Disk.img | `391c05e119055a10b477d8ba73bb69188c4856f80ac6e69a09856a3e24baa7f0` | `9918d2bdd8f4cb9b653ebe0a5d552cd3f61bb4986421652f08c4049adfb82531` | 提交后等于候选、proof 和 receipt；只读检查前后相同 |
| Preboot IMG4 文件 | `5b90c5a0ee87bf810c7e90795d537265f39774fbf85c430263fd2f61fc41ce7a` | `e8ead0a8a83b4e68254b73cc2f70fe5df7486f5ea91f0bd217b34f4a5a87dcf2` | 文件字节改变 |
| 解码内核 payload | `d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb` | 同基线 | 等于本次 producer proof，payload 未改变 |
| IMG4 内原始 IM4M TLV | `ec08fc625f7f8b76861b93fb9a950022103fe4031ead235f64daad1df8c4c657` | 同基线 | 原始 DER 字节摘要保持；未以重新编码结果替代 |

两个 Preboot 内核相对路径相同。Disk.img inode 保持 589096904。其余五个关键文件 nvram.bin、SEPStorage、config.plist 和两个 ROM 的完整摘要与基线一致；全部六文件 inode 与基线一致。审查者核对保存结果中的实际数值与 baseline-digests.json，未仅依赖 passed 标记。

本次独立脚本不重新运行 DSC 验证，DSC 兼容性证据来自正式 commit 的生产候选和已发布只读校验。未独立比较整盘内全部 guest 文件，不能由五个非 Disk 文件摘要外推全部 guest 数据不变。

## 第四版 host 重新绑定

bind-test-vm-v4-after-kernel-v7.json 记录正式 `vm bind-core-bundle ... --version 2.6.20261016-local` 退出 0。binding-before-boot-v4-kernel-v7.json 为 host 第四版、kernel 第七版；相对提交后的绑定仅 bundle 字段改变。host-rebind-v4-kernel-v7-check.json 记录 receipt、proof、journal 保持，pending_transaction=false。该观察为后续启动准备，不能当作启动证据。

## 验收范围

本次已证明实际磁盘完整提交、已安装字节与 producer 输出关联、IM4M 原字节保持和独立 host/kernel 来源。由于新旧 payload 相同，后续若成功启动，也只能支持本次重新发布后的磁盘在指定 host 上启动，不能支持不同内核 payload 的替换后启动，更不能支持全部补丁运行行为。已提交且启动后的 kernel-only 回退仍需公开入口和独立验收，不可用此前未提交事务恢复替代。

审查者仅复核实施者保存的磁盘读回结果和脚本，未独立执行 live 读回。正在或随后发生的启动及 guest 磁盘变化不属于此停机摘要观察。

## 审查输入摘要

| 文件 | SHA-256 |
| --- | --- |
| kernel-update-v7.json | `263404548f5a303c26cbcc5fd4b277513cca4a7b44a2b51c3feb61b93dad2e68` |
| committed-v7-journal.json | `36d36433919283a0e9bbf70f15856ebb8a136efccf40c7f2b9026694bd73e4b6` |
| committed-v7-installed-component-proof.json | `d69f2f3de29a27ae22820f828392ca9d869cbd36055aaf7fba07eff1eccba904` |
| committed-v7-component-receipts.json | `003953ec6c64a099981f999bfa81b7d5f29efcf3c395a65029529e164dc92c8c` |
| committed-v7-report.json | `94dc7a38765e98689456d5c3905b766f51dd6d4690044267cdd529fe50d65d29` |
| core-candidate-v7-manifest.json | `3d99a39117c06c772b8e3dcb25786203055f48f26d0e1beb0cf1222960d8f16f` |
| committed-readback-v7.py | `4c8bb89eec585b66ca3e6f2ad5633fe11d0436d522739bd47e15bb2d94318dff` |
| committed-readback-v7-run.json | `a111f6dae33c0d95eabebbd298f74c2952cb1e6bc749e38a4537044f88f5d380` |
| committed-readback-v7.json | `83f6fa99599bded4d055cd26c6cc1f725f6d7741ad8181a522193b984dba75a2` |
| bind-test-vm-v4-after-kernel-v7.json | `1309bbb0d32cef053460a36b157c671fcfab3f286d89b2fb88dffdbf527cc7fc` |
| binding-before-boot-v4-kernel-v7.json | `c56120f82f6ec310f95b97164269352c912a61e8d6dcd64476fa1a97f3d02059` |
| host-rebind-v4-kernel-v7-check.json | `8087b4112126bba2050cd287440d79fdd35f21a5089ec27e2b3841fcd7a4a641` |
