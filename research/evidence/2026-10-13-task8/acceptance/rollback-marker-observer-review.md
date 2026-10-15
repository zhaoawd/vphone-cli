# 回退验收 guest marker 工具独立审查

日期：2026-10-14。审查者：acceptance_audit。只读审查 guest-rollback-marker.py 和 host file_get 响应源码。未执行脚本或 guest 写入/读取，未操作 VM、挂载或 AMFI。

最新结论：noclobber、证据独占创建及创建内容上限均已修正，最终版本未发现阻断问题，可用于本次已授权 B 创建、回退后新实例读取 marker 的验收。主体范围和结果限制保持。

## 已核对的范围

- create/read 模式及 label 受限，固定第四版 CLI 和唯一 task8-copy。先要求对应 label 的公共 boot watch passed，再验证当前精确 binding/receipt 和无 pending。
- 前后 capabilities 与每个 shell/file_get 请求都携带同一 target；要求正常 guest、shell 和 file_get 能力。host 的 file_get 成功字段确为 size 整数及 data base64，与脚本一致。
- create 生成随机 UUID 路径 `/private/var/tmp/task8-kernel-rollback-UUID`；content 记录创建实例、冻结 installed expectations，先保存 intent，再用 printf 固定格式和 shlex.quote 写入唯一小文件。不调用 file_put，不修改持久 PATH 或系统配置。
- 创建后立即 file_get 实际字节；size 严格 int、base64 validate=True、实际字节及 SHA 与 intent 同时相等，不把 shell 返回 0 单独当作写入证据。
- read 仅允许固定证据目录下已成功的 create 记录；路径限定专用前缀，要求相同 VM 名称及不同 instance ID。只 file_get，不写 guest；校验实际内容、SHA、长度与原创建一致。
- 最终再次检查 capabilities target、连接及精确 binding/receipt。marker 仅证明该文件的启动后写入保留，不能证明整个 guest 文件系统不变或不同 payload 回退成功。

## 执行前最小修正

1. `(set -C; printf ... > path)` 在 set -C 失败时仍执行写入，无法严格保证预期的 noclobber 条件。改为 `(set -C && printf ... > path)` 或等价失败即退出形式。
2. intent/out 当前是 exists 后 write_text，建议使用独占创建，避免同 label 并发或中途同名文件生成后覆盖证据。intent 必须在 guest 首次写入前成功保存。
3. create/read 均显式限制 content 为小文本（建议不超过 16 KiB）；当前冻结 expectations 通常很小，但工具尚未编码该范围。

后续联合验收必须将 create 记录对应正式 B 实例、read 记录对应回退后新实例，并关联目标事务、计划和实测不同 payload。源 create 记录和原失败记录保持；不能通过重写原 JSON 修复失败。

首版审查 SHA：`ff9f5aca141f554f15bc56d55b0db04a32643b0648fa65f14c6ab255ec80c8a8`。审查仅静态检查，尚不证明 marker 实际创建或保留。

## 最终版本复核

最终脚本在任何 guest 操作前 out.open('x') 预留结果文件，intent 也通过 open('x') 独占创建并关闭后才首次写 guest。写入命令改为 `(set -C && printf ...)`，set -C 失败不会继续写文件。create 内容限制为 16,384 字节以内；read 消费本工具已成功创建的 intent 并验证原尺寸/摘要。结果 finally 只使用已取得的输出 handle，不覆盖同名历史记录。

最终 SHA：`8b7a83d20221c8d358dc2cdca4faa163aff8d8113b8e752d15a474b0a9203322`，与根任务冻结值一致。未执行脚本或 guest 写入。联合验收仍需将 B 创建实例、回退后不同实例、离线目标 A payload 及新回退事务关联；仅此 marker 保留不提升为全部 guest 数据保留。
