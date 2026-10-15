# Task 8 第八版正式提交与读回独立审查

日期：2026-10-14。审查者：acceptance_audit。只读核对第八版重跑更新、冻结工件 manifest、归档 journal/proof/receipt/report、绑定及 committed-readback-v8.py 的实际结果。仅写本文件及对应 JSON；未执行 VM、挂载、AMFI、恢复或修改生产代码。

结论：第八版正式离线提交及实际只读读回通过。安装后的完整 IMG4 与已核验基线相同，raw IM4P 与 proof 摘要相同，description/PAYP 恢复，IM4M 原字节保持。解码 payload 与此前相同，本次仍是同 payload 的容器修复及重新发布，不是不同 payload 更新或提交后回退验收。正常启动留待后续独立证据。

## 正式提交关联

kernel-update-v8-resumed.json 记录已安装 `2.6.20261020-local` CLI 对限定 task8-copy 正式执行 update-kernel，退出 0，耗时 3,430.296055 秒。命令使用项目 .venv、PYTHONDONTWRITEBYTECODE=1；此前暂停证据未覆盖。

独立解析保存文件并执行关联断言通过：

- transaction ID：`2b52edcf-ac9b-4515-bb80-338d94bcbd2b`，在 journal、publication、proof 及实际读回中一致。
- journal version=3、kernelOnly=true、phase=committed；forward cursor=10,094，等于 offsets 总数；pending=false。
- publication.records=[]、originLayer=kernel；仅 installed kernelcache receipt，scope=installedComponent、state=committed，唯一输出 Disk.img。
- receipt/proof/report 完整摘要与 journal、publication 和 metadata 输出一致；proof 的 CLI SHA `28192f56a228c856ecdda3f726d52f33e5ed3a0e852e772dd4855d32579c3b13` 匹配冻结第八版 manifest。
- generation、冻结 plan 和 desired 摘要一致。119 条效果记录与 report 全部记录按原顺序一致，归属 42 个声明；119 条记录不等于 119 项新增修改。
- binding-after-update-v8.json 相对 binding-before-update-v8.json 仅将 kernel 来源推进第八版；其他来源保持。

## 实际磁盘与内核读回

已审读回脚本的执行结果 passed=true、无 error 或附件查询错误；20 条外部命令均退出 0，最终副本与首次绑定备份的 remaining_attachments 均为空。脚本在排他目录锁下先要求无 pending，分别只读附加、关联和验证唯一 Preboot 卷，检查 UUID、精确挂载目录、只读状态和目录身份，读取唯一普通内核文件，并在 finally 卸载。

| 对象 | 实际结果 | 关联 |
| --- | --- | --- |
| Disk.img 完整 SHA | `87bb8221869e9904010931d750794ddcb144700c3decc512dc4c9d26103536c3` | 等于候选、proof.imageSHA256 和 installed receipt；只读检查前后相同 |
| 安装后的完整 IMG4 SHA | `5b90c5a0ee87bf810c7e90795d537265f39774fbf85c430263fd2f61fc41ce7a` | 等于本次备份读回及此前已核验基线 |
| raw IM4P SHA | `b1f07780484d9dc88f989d6e236049050b38e50a1ddb94030dcecaed43f962db` | 等于基线和 proof.im4pSHA256 |
| raw IM4M TLV SHA | `ec08fc625f7f8b76861b93fb9a950022103fe4031ead235f64daad1df8c4c657` | 与基线原始字节保持一致 |
| 解码 payload SHA | `d2b90150a12e1b5685b91a6b85e59f71cbff4896c49abc3b1c24fd386bd697fb` | 等于本次 producer proof、基线及第七版 payload |

完整 IMG4 与基线相等，同时关联此前容器对照，支持 description 恢复为 KernelManagement_host-487.0.4、315 字节 PAYP 恢复；没有仅依赖 payload 相等或重新编码后的 IM4M 判断。original_description_and_PAYP_restored=true 与这些实际摘要条件一致。

六文件集合与 pre-update-v8-snapshot.json 一致，六个 inode 数值及 inode_unchanged 均保持。Disk.img inode 为 589096904。nvram.bin、SEPStorage、config.plist、AVPBooter.vresearch1.bin、AVPSEPBooter.vresearch1.bin 五项完整摘要逐一与第八版更新前快照一致；不使用已经过时的最初 NVRAM 基线。审查者重新核对保存数值及关联，未只依赖 passed 标记。

## 验收范围

DSC 兼容性来自第八版正式 commit 的生产候选及发布后校验；独立读回脚本不重新检查 DSC，本审查也未执行 live 读回。完整磁盘和 Preboot 数据来自实施者保存的实际读回结果，审查者只解析证据并检查脚本。

本次证明容器修复与正式离线提交。由于 decoded payload 未改变，不能计为不同内核内容替换、不同 payload 启动或提交后 kernel-only 回退。整盘变化也不能被简单称为仅内核字节差异；未独立比较盘内全部 guest 文件。先前启动异常原因仍未查明，不能由本次 PAYP/description 恢复直接推定因果或启动修复成功。

后续应正式将 host 绑定已授权第四版并核对 kernel 来源仍第八版，随后取得指定 VM 实例的真实 guest shell/启动证据。该启动及后续清理不属于本次停机提交观察。公开提交后回退入口尚未实现，Task 8/T34 保持未完整验收。

## 审查输入摘要

| 文件 | SHA-256 |
| --- | --- |
| kernel-update-v8-resumed.json | `d709d7b19540ced8b51309020d901f893a4cb2c34a68581d1411767a7514c280` |
| committed-v8-journal.json | `0c82c842e7de04019f2f43d236db89a586e0e995ecd614c7c018e9df9777f82d` |
| committed-v8-installed-component-proof.json | `36ac7493c92e7634c004cdedb48519cb7e4132c9127efbac0e4b0c3244710d71` |
| committed-v8-component-receipts.json | `266ba0ad4589044c4f736ed2911267db03c22658c8f756fab453bb5e6b855cfb` |
| committed-v8-report.json | `94dc7a38765e98689456d5c3905b766f51dd6d4690044267cdd529fe50d65d29` |
| binding-after-update-v8.json | `b446aac61f105ccbd6b353dd2378f58c909dd685211529034d410f667b833da0` |
| core-candidate-v8-manifest.json | `111b42b62d059be485535428eec496a2e9a4de107a1a39aa91a406aa7f270634` |
| committed-readback-v8.py | `d4e15f1e38e67b4f640c89d823c3e91ad2c056aa35e81e7636d2bd87083db031` |
| committed-readback-v8.json | `e8bdb3bd9d04998909eca469bbc1f363f8f99c5c7224cebb4b8d90183a95272a` |
