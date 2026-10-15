# 内核磁盘读取与分项计时

`FirmwareKernelDisk.capture/validate` 使用最多 1 MiB 的底层读取，在内存中逐 4096 字节比较。持久块偏移、发布游标、pending 写入前缀及恢复语义仍以 4096 字节为单位。最后不足块按实际长度处理。读取器处理正数短读、EINTR、提前 EOF、文件增长和整数溢出。

capture 在同步后以同一双流扫描计算两份备份的 SHA 和块差异，保留源文件初始摘要、扫描后的 live disk 摘要及备份文件状态检查。成功路径仍计算 5 次完整 SHA，显式逻辑读取由 7 倍镜像长度降至 5 倍，不含复制内部 I/O。validate 的两份备份 SHA 与三流比较保持。

kernelUpdate 将候选摘要比较与 kernelMount 挂载前 SHA 局部合并。published 单次整盘 SHA 为 4 次，candidate 回调为 2 次；挂载后、事务入口与尾部、来源、计划、report、binding 和 metadata 循环重验保留。尚未实现 published 5→2，也未跳过 metadata 重验。

扫描主缓冲容量为 capture 最多 2 MiB、validate 最多 3 MiB。pending 比较最多另用 12 KiB 的零基块副本。该上界不包含既有 offsets 数组、SHA/复制工作内存及可选 trace 事件。

## 启用计时

计时默认关闭。新构建程序显式设置 `VPHONE_KERNEL_IO_TRACE=/absolute/output-prefix` 后启用。以下命令只运行合成文件回归；父目录须已存在，prefix 每轮应不同：

```sh
VPHONE_KERNEL_IO_TRACE=/private/tmp/kernel-io-example \
  swift test --skip-build --filter FirmwareKernelIOTimingTests
```

完整进程正常退出时独占创建 `<prefix>.<pid>.jsonl`，模式为 0600，不覆盖已有文件。业务操作期间只记录内存事件；trace 不进入事务 journal、receipt、proof、desired 或 binding，也不增加业务 fsync。输出错误不改变业务结果。异常退出可能没有文件或完整 footer。

每个同步 span 包含调用点、父 span、单调起止时间、inclusive 耗时、结果、计数和标签。覆盖 generation 原件验证、文件 SHA、Store/签名资格检查、capture/validate 比较及原有 fsync/journal 同步。发布和恢复的逐块子操作累计到父 span，避免逐块输出事件。

事件上限为 100000。有效测量须有唯一末尾 `measurement_end`，且 `complete=true`、`dropped=0`、`open_spans=0`、`io_error=null`，事件数一致。缺少 footer 或超限的测量无效。冻结的分析工具可检查协议及调用关联：

```sh
.venv/bin/python -B \
  research/evidence/2026-10-14-kernel-io-performance/analyze-trace.py \
  /private/tmp/kernel-io-example.PID.jsonl
```

嵌套及并发的 inclusive 耗时会重叠，不能相加或直接换算完整 CLI 占比。SHA 消费者与其 readFile 子 span 的字节可能描述同一次读取，不能重复累计。比较循环的 `read_calls` 表示 native pread 尝试，包含 EINTR、EOF 和错误；`bytes` 为有效正数返回字节，失败前已读字节仍保留。逻辑读取量不等于物理磁盘 I/O。

## 验证范围

读取器、差异结果、双向 pending 前缀、恢复、外部修改拒绝、内存和计时回归使用独立合成普通文件。基准测试仅在 `VPHONE_KERNEL_IO_BENCHMARK=1` 时运行，正常回归跳过。既有独立 release 基准为 512 MiB+3 字节暖缓存场景，不能外推为完整 64 GiB 发布或真实 VM 的加速比例。

[独立性能结果](../research/evidence/2026-10-14-kernel-io-performance/performance-results.md)与[源码合入记录](../research/evidence/2026-10-14-kernel-io-integration/README.md)分别保存。源码合入不替换冻结 V9 或已安装产物，原 Task 8 验收记录保持。

## 第二、三项对照基准

四版隔离 release 基准使用 512 MiB+3 字节、暖缓存合成输入；40 次调用中排除 8 次预热，每个测量单元计入 4 次。第 2 项的 6 次 published 校验累计中位数 8.002→6.482 秒（减少 19.0%），2 次 candidate 累计 1.625→1.103 秒（减少 32.1%）；第 3 项的完整 capture 为 1.683→1.439 秒（减少 14.5%）。第 3 项一次 1.832 秒测量保留，原因未查明。

组合版合成 publish helper 为 14.504→12.576 秒（减少 13.3%），中位数略高于仅第二项版本。各比例对应不同范围，不能相加。模拟卷工具仅读取首个 4 KiB；prepare、文件生成和独立最终读回不计入 helper。结果不表示完整更新或真实 VM 的加速比例。范围、最小值/最大值、全部原始数据及冻结工件保持核对见[第二、三项性能结果](../research/evidence/2026-10-14-kernel-io-factorial/performance-results.md)。
