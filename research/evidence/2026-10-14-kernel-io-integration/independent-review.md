# 分项计时与 1 MiB 读取优化合入独立审查

结论：源码合入与相关回归通过。未发现阻断项。本审查核对源码增量、摘要、真实回归日志和 trace；审查者未构建或运行 VM、CLI、Store、AMFI，也未读取 VM 磁盘。

## 源码与作用域

17 项源码/测试/Package 文件与合入 manifest 一致。16 项非 Package 文件逐字节匹配已验证的独立优化工件。Package 保留完整原依赖和目标，只增加计时模块及所需依赖。11 份集成前文件与原摘要一致，863 项未纳入集成的既有源码/测试保持。未发现覆盖既有 WIP 的增量。

计时默认关闭。启用后只在内存记录事件，正常退出独占创建 trace，事件上限 100000。满额、输出错误和未结束 span 不接受为完整测量。fsync 保持原调用、返回值及 errno；业务错误原对象重新抛出，原写入、同步和游标持久化顺序保留。generation 原件校验、Store/签名检查、SHA 调用与 metadata 循环磁盘重验没有删除、合并或跳过。逐文件静态调用点计数一致；该检查不等于完整 CLI 的运行次数测量。

capture/validate 每批最多读取 1 MiB，在内存逐 4096 字节比较。偏移、尾块、pending 前缀、interrupted reverse 和写入前外部修改拒绝仍按持久块处理。pread 正数短读填满剩余区间，EINTR 在同一偏移重试，提前 EOF、增长、非法返回和范围/计数溢出拒绝。读取器不改变 fd 位置或所有权。主扫描缓冲逻辑容量为 capture 2 MiB、validate 3 MiB，pending 块副本最多另用 12 KiB；不包含 offsets、trace 或原有 SHA/复制内存。

## 实际回归证据

- `swift-related-01` exit 0：XCTest 汇总 31 项，跳过 3 项，28 项执行通过；Swift Testing 汇总 130 项，日志保留 2 个真实 fixture 入口跳过。读取器、跨批差异、双向全部 4097 种完整块前缀、尾块、恢复、外部修改拒绝及计时测试通过。四个独立内存子操作均实际通过。
- `swift-envelope-dsc-effects` exit 0：Swift Testing 汇总 9 项，日志保留 2 个真实 fixture 入口跳过。
- Python Bundle 协议 7 项与 trace 分析器 10 项通过。
- 合入后的 debug 测试二进制启用计时：XCTest 1 项、Swift Testing 3 项通过。独立解析两份实际 trace 共 13962 个事件：末尾 footer 完整、无丢失/未结束 span，全部 ID/PID/调用点及父子同线程时间包含关系通过。6 次成功 capture 各保留 5 次 SHA，17 次成功 validate 各保留 2 次 SHA。

## 保留与限制

独立复核 266 份旧证据摘要、原证据树 1181 项元数据、冻结 V9 的 16 份源码存档均保持。根最终保护记录 1173 项通过，包含冻结与安装工件；审查者未重新读取安装二进制。旧数据标记失败和 amfid 停止证据未改写。

本结论限定源码合入与相关回归。没有新增 VM 启动或完整 64 GiB 发布验证，没有新增 release 性能结果，也没有据合成 trace 推断整盘 SHA 的总耗时占比。其余优化继续后置。
