# Documents 持久性证据工具

`verify-documents-persistence.py` 仅连接本目录已保存的普通证据文件，不运行 CLI，不读取 VM 镜像，不操作 Store、AMFI 或进程。范围固定为原 Documents 创建、同 A 停机重启、随后公开 schema4 回退到历史 B 的单次实验。

工具检查原 create/intent/source boot、显式 sync、实际 file_get 全字节、三次不同且递增的 VM 实例、正式 rollback 参数和目标、已提交 journal/proof/receipt/report 摘要链、实际 kernel 读回、双 CAS、正式 host 重绑与 owner 修复、第四版实际 argv/系统查询、正式 stop 和清理。旧 tmp 文件的原始 SHA 及 passed=false 必须保留；本工具不运行、改写或使旧 V2 联合验收通过。缺失后续证据返回 pending/2，错误或不稳定证据返回 refused/1，只有完整链通过返回 0。

最终全部真实步骤完成后，使用项目运行时及新标签执行：

```sh
PYTHONDONTWRITEBYTECODE=1 .venv/bin/python research/evidence/2026-10-13-task8/acceptance/verify-documents-persistence.py --label task8-final
```

输出独占创建 `task8-final-documents-persistence.json`。任何失败均保留，重试使用新标签。

`freeze-documents-rollback-b-boot.py` 仅在实际 R_B 读回和正式 host4 重绑/owner 修复后生成启动预期。它复用上述显式校验函数，核对正式命令、版本、metadata 前后保持、owner 的 label/UID/GID/mode/inode、已提交原始 receipt/proof 和当前三个 metadata 字节。主入口持有 VM 目录锁，拒绝 pending，使用既有严格文件读取、写入前再次核对 live 字节，并独占写入及 fsync。所有门使用显式异常，Python 优化模式不会移除。

回归：原 verifier 18 项纯测试通过；freeze helper 8 项纯测试在普通和 `-O` 模式均通过。未来 R_B 成功记录只存在于 RAM fixture，不写为真实证据。测试禁止实际 subprocess 和进程信号；独立复审额外禁止 helper 的主入口、os.open 和 flock。测试不证明尚未发生的跨回退验收。

前版 helper 缺少完整正式重绑/owner 合同且使用 assert，已在执行前修正。原审查保留，v2 独立复审通过。见 `documents-persistence-independent-review-v2.md/json`；工具主入口尚未实际运行。DSC 和全盘内容摘要由正式生产校验与独立实际读回提供，本工具不重复执行这些操作。
