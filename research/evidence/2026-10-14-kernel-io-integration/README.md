# 分项计时和 1 MiB 读取源码合入

按用户本轮授权，将已验证独立工件的分项计时和 1 MiB 读取实现合入当前源码。没有合并 SHA、融合摘要与比较或跳过 metadata 重验。没有安装、热替换或启动新的 VM 产物，AMFI 未操作。原有未提交修改及 capstone 子模块状态保留，未提交 Git。

## 实现及来源

合入 17 个源码/测试/Package 文件。其中 16 个非 Package 文件逐字节匹配 `/private/tmp/vphone-kernel-io-optimization-20261014`；Package 使用已验证的完整生产依赖清单，只增加共享计时 target、测试 target 及 FirmwarePatcher/BundleStore 依赖，没有使用独立实验的 focused Package。来源、摘要及补丁见 [integration-source-manifest.json](integration-source-manifest.json)。

计时默认关闭，显式设置 `VPHONE_KERNEL_IO_TRACE` 后记录调用点、实际字节、单调 inclusive 耗时及父子关系。trace 在正常退出时独占创建，事件上限 100000；缺少完整 footer 或丢事件使测量无效。trace 不进入业务事务文件；原 fsync 返回值、errno、错误传播及同步顺序保持。

capture/validate 底层最多读取 1 MiB，内存仍逐 4096 字节判断。读取器处理短读、EINTR、提前 EOF 和溢出，检查三个流的文件长度及尾部增长。pending/interrupted reverse 比较使用最多三个零基块副本。capture 主扫描缓冲最多 2 MiB，validate 最多 3 MiB，pending 副本最多另用 12 KiB；这些上界不包含既有 offsets、trace、SHA/复制工作内存。差异偏移、持久块、发布和恢复游标保持。

用户文档见 [docs/kernel-io-performance.md](../../../docs/kernel-io-performance.md)。

## 实际回归

完整 Package 的 debug 构建成功。首轮命令耗时 310.130 秒，包含依赖获取与构建；不作为 helper 性能测量。相关实际结果如下，参数化场景数没有计为额外测试函数。

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 读取器、等价性、计时及内存 XCTest | 28 通过，3 跳过 | `swift-related-01.json/log` |
| generation、事务、更新/回退、来源、计划及 Store Swift Testing | 128 通过，2 实际 fixture 跳过 | `swift-related-01.json/log` |
| 封装保留、DSC、效果及实际读回关联 Swift Testing | 7 通过，2 实际 fixture 跳过 | `swift-envelope-dsc-effects.json/log` |
| 内存回归四个隔离子操作 | capture/validate/publish/reverse 均通过 | `swift-related-01.log` |
| 实际启用 trace | 1 XCTest + 3 Swift Testing 重复运行通过 | `swift-trace-enabled.json/log` |
| Python Bundle 协议 | 7 通过 | `python-bundle-protocol.json/log` |
| 冻结 trace 分析工具 | 10 通过 | `analyzer-regressions.json/log` |

三个 XCTest 跳过项为两个显式 opt-in benchmark 及一个仅由父测试启动的内存子入口。内存子入口实际在四个隔离进程执行通过。四个真实 fixture 入口未启用；没有把本轮合成回归写为新 VM 或真实固件验收。

计时开启后实际生成两份完整 trace、13962 个事件。冻结分析工具复核 footer、调用点、唯一 ID、父子同线程时间包含关系及计数通过。SHA、generation 原件验证、Store/签名、比较循环及 journal/fsync 的阶段均实际出现。消费闭包错误前的实际读取为 1048576 字节、1 次 read，错误保留。6 次成功 capture 内各 5 次 SHA、17 次成功 validate 内各 2 次 SHA，未减少。见 [trace-enabled-check.json](trace-enabled-check.json) 和 [trace-helper-sha-check.json](trace-helper-sha-check.json)。

独立审查见 [independent-review.md](independent-review.md) 和 [independent-review.json](independent-review.json)。本轮未重新测量性能；既有 release 隔离基准和限制见 [原性能结果](../2026-10-14-kernel-io-performance/performance-results.md)。不据本轮 debug 回归推算完整 CLI 加速比例或 52 次整盘 SHA 的耗时占比。

## 冻结及修改保留

[protection-after-tests.json](protection-after-tests.json) 的 1173 项检查通过：266 份旧性能/验收证据摘要、两目录 1181 个原条目的元数据、V9 归档/候选/安装工件及第四版 CLI/VM 摘要保持。原 V9 的 16 份源码逐字节另存于 `frozen-v9-source/`，匹配原 manifest。当前源码按本轮授权修改，原冻结工件和验收证据不重新生成。

863 个未纳入合入范围的既有源码/测试文件摘要保持；11 份被修改的既有文件在 `before-files/` 保存原字节，另有合入前 working tree diff/status，保留原有未提交修改。新测试二进制只在工作区构建目录，摘要见 [test-binary-manifest.json](test-binary-manifest.json)。`git diff --check` 通过。

旧 tmp 标记 ENOENT 和 amfid 停止问题的原证据保持，原因未查明；本轮合入不改变其结论。其他性能优化继续后置。
