# 三组基准控制工具最终独立审查

结果：修订后的三个工具无剩余执行阻断，可由 root 按冻结合同执行独立合成基准。此次结论只覆盖工具源码、来源资格形状和测试边界，没有验收正式 24 次运行或性能收益。初次 blocked 审查、误接收复现测试副本及原日志保留。

23 个独立测试通过，AST 解析通过。实际日志为 `benchmark-controller-review-final-tests.log`，测试源码为 `test-benchmark-controller-review.py`，审查工具/测试/实际 variants manifest 摘要见同名 JSON。真实 `subprocess.run`、`Popen` 和 `killpg` 在测试中默认禁止；涉及超时、信号、ps/hdiutil 观察和 Task8 锁的路径均使用 mock。Package 测试只操作新建的普通临时目录和小型合成文件，没有访问实际隔离工件或 VM。

初次 8 项测试已改为有效 control 与拒绝回归。NaN、负数或不符纳秒的秒数、空 offsets、helper 外 compare、错误 SHA 角色、不完整 stderr/footer 均被拒绝。compare 必须是当前 helper 的后代；SHA 保持 capture 5 次、validate 2 次，并核对实际 consume 字节和角色。比较流逻辑字节及 4096 块数保持。样本与直接 XCTest 子 PID、声明读粒度、fresh trace prefix、完整 footer 和测量窗口联合关联。

新增模拟测试确认：仅对本次 `Popen(start_new_session=True)` 的进程组执行 TERM，等待 5 秒后才可能 KILL，再有界 reap；最后 reap 超时记录 `cleanup_complete=false` 和错误类型。已经结束的子进程不接收信号。wrapper 165 秒超时后先给 recorded wrapper 15 秒执行其子进程清理，必要时 KILL 并再等 5 秒；即使随后退出 0，超时仍判失败。原中断对象在清理后重抛。recorded timeout 形成失败 JSON，双目录锁在 finally 释放。Task8 `/tmp` 别名在创建子进程前被拒绝。

variants 合同现在要求三组目录和二进制摘要各异、相同实际 Benchmark 源码摘要、固定 false/true/true trace 和 4096/4096/1048576 声明粒度、实际 Package tools6/macOS15、成功构建记录，以及精确 13 项 `swift test` argv。额外 `-Xswiftc -Onone`、错误平台、不同测试源码、错误 trace/readsize、相同 binary 或构建失败均由独立纯测试拒绝。严格 argv 保留完整编译参数形状，避免只抽取 release 字段而漏掉其他编译 flags。

已读取 `benchmark-variants.json`，独立核对三组小型 Benchmark 源码、Package、KernelDisk 源码及实际构建记录的完整摘要，并按当前函数验证实际资格形状。三组测试源码均为 `dd17c66d…334a`。本审查未读取大型 XCTest bundle 二进制或系统 XCTest 工具来重复计算摘要；这两个 digest seam 在资格形状测试中使用冻结 manifest 值。root 已报告实际完整资格校验通过，正式控制器仍必须执行实际完整摘要检查，本文件不将模拟摘要作为独立二进制验证。

控制器在运行期间持有三个隔离 artifact root 的排他目录锁，每轮 recorded wrapper 另持有 Task8 目录锁并检查两种 pending、VM 文本身份及所有 Task8 镜像附件。prepare 工具取得隔离目录锁，使用 `O_NOFOLLOW`、普通文件/nlink1、fd/路径身份与内容复验；备份和 metadata 独占创建完成后才修改 Package。符号链接、硬链接和已有 metadata 的普通文件测试均在改写前拒绝，原文件保持。

一次 warmup 对每组/操作各执行一次，不进入汇总；前三个 measured round 采用 Latin 轮转，共 6 个 warmup 和 18 个 measured 样本。helper 时间直接来自单调时钟外部样本；compare/SHA inclusive 时间独立列出，没有求和声称 CLI 总耗时。FileHandle API 尝试数与 native pread 尝试数仍为不同口径，不据二者比例推算完整操作速度或物理磁盘 I/O。RSS 是进程历史峰值。正式性能结论仍需原始 24 次结果、实际完整工件核验、错误与清理状态全部满足冻结合同。
