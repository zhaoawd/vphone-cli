# 独立内核 I/O 性能验证（2026-10-14）

用户指定先分项计时，再验证 capture/validate 的约 1 MiB 读取。源码副本为 `/private/tmp/vphone-kernel-io-optimization-20261014`。原工作区现有修改、冻结 V9 和 Task 8 验收保持；本工件不安装到 Store、不启动 VM、不操作 AMFI、不读取或修改验收磁盘。

## 执行顺序

1. 在副本增加 opt-in 分项计时，验证次数、实际流字节、单调时间、错误结果和父子包含关系；所有原校验与同步顺序保留。
2. 冻结仅计时版本，编译并运行相关合成恢复回归，留存源码与可执行文件摘要。
3. 在该版本上仅改 capture/validate 底层读取；持久块大小仍为 4096，仍记录相同块偏移。建立差分及拒绝矩阵，覆盖 1 MiB 边界、空输入、末尾不足块、长度变化、forward/reverse pending 前缀、未知外部修改、原件/候选篡改、身份替换及内存上界。若用 pread，显式覆盖 EINTR、短读、提前 EOF 和其他错误。
4. 在独立合成数据上比较未计时基线、仅计时和计时加 1 MiB 版本。交替顺序、多次运行，保留原始数据、配置与中位数；分别报告比较阶段与完整 helper 时间。实际收益以结果为准，不将读取调用数下降换算为整条更新加速。

嵌套 span 的 inclusive 时间不能相加计算总时间；generation/Store 内部读取只报告实际可观测的流字节，Security、clone 和 hdiutil 的内部 I/O 不推算。日志失败须检测并使该测量无效，不能改变事务业务结果或 errno。

## 验收问题分别跟踪

Task 8：A/B 不同 payload 更新和第四版启动通过；提交后公开回退 A 的读回与启动通过。旧 tmp 标记回退后 ENOENT，数据保留尚未通过，原因未查明。新 Documents 标记同实例 sync/读回通过，停机后落盘与跨回退验证待完成。

amfid：B 临时驱动 detach 后同一进程仍停止，SIGCONT 后恢复；原因未查明。回退 A 后外部核验已运行，未发送信号。此问题不合并归因于内核发布耗时。

## 后置范围

单次 verifyOrigin 内 SHA 合并、capture 摘要与比较融合、metadata 循环重验跳过、generation/Store 跨阶段复用及 fsync 批量化均不在本轮算法优化范围。须单独设计内容稳定性与恢复矩阵并审查。


离线标记诊断补充：`kernel-v9-rollback-a-marker-images-01-environment-limitation.json` 记录归档原盘 Data 的 Encryption=true、FileVault=true、Locked=true。工具按约定拒绝读取，无标记内容观察，未继续候选和当前 UserData，未尝试解锁。原盘检查前后完整 SHA/身份保持，最终无附件或 pending。旧标记缺失原因仍未查明；新 Documents 标记只证明同实例 sync/读回，停机落盘与跨回退保持尚未验证。

## 本轮结果

分项计时及 1 MiB 读取验证已完成，详见 [performance-results.md](performance-results.md)。三版本 24 次隔离调用全部通过；排除 6 次预热后，完整 capture/validate 相对未计时基线的中位耗时分别减少 12.9%/47.3%。结果限定为 512 MiB+3 字节暖缓存合成 helper，不推算完整 CLI 加速或 52 次整盘 SHA 的全程占比。回归、内存、实际 trace 与独立审查证据均保留。共享源码、冻结 V9、Task 8 验收与 AMFI 范围保持。
