# 内核 I/O 第二、三项优化结果（2026-10-14）

第二项完成局部合并：published 校验从 5 次整盘 SHA 降至 4 次，candidate 回调从 3 次降至 2 次。第三项完成备份摘要与比较融合：capture 仍计算 5 次完整 SHA，显式逻辑读取从 7 倍镜像长度降至 5 倍，不计复制内部 I/O。修改已进入工作区源码，尚未提交或安装。

## 实现范围

`FirmwareKernelMount.withVolumes` 接收预期摘要，在本次实际挂载前 SHA 中比较，并保留 detach 后完整 SHA。预期摘要不能用于 writable 挂载。`FirmwareTransaction.verifyOrigin` 的入口和尾部 SHA、计划、report、binding 与 metadata 循环检查保持，新增的计时 span 用于逐次核对调用。

没有实现 published 5→2。其余读取之间包含来源、挂载和元数据校验，不能据已有结果证明摘要可跨越这些操作复用。合并后的挂载前 SHA 位于 operations.volumes 工厂之后；测试覆盖错误内容持续存在的拒绝，未证明所有并发修改后恢复的时间窗口与旧实现等价。

capture 按 old→new→root 同步后扫描两份 backup，以相同字节计算 SHA 和 4096 字节块差异。仍保留源文件初始 SHA、扫描后的 live disk SHA，并核对打开的 backup 与路径的关联、普通文件类型、单链接、长度、mtime 和 ctime。短读、EINTR 和三流原有 EOF 处理保持。发布、反向恢复、写块及 sync 实现保持；比较扫描的执行时机移至同步后。

## 实际验证

最终定向回归退出 0：XCTest 选择 36 项，35 项实际通过、1 项内存子进程入口跳过；父测试实际执行 4 个内存子操作，全部通过。Swift Testing 选择 30 项，28 项实际通过、2 项真实固件 fixture 入口跳过。覆盖差异、读取、更新、回退、编排和计时器，记录为 `final-focused.log` 与 `final-focused-result.json`。

补充事务、来源、generation 和 receipt 回归退出 0：7 项新增 XCTest 和 63 项 Swift Testing 实际通过，见 `boundary.log` 与 `boundary-result.json`。该轮完成于最终计数器字段修正之前；字段修正后的最终定向回归再次通过全部 7 项新增测试。

新增测试覆盖两份 backup 在同步后被修改、增长、截断、路径替换、符号链接、硬链接和同内容重写；短读、EINTR、提前 EOF、错误返回；挂载前、attach、inspect、body、detach 留下的镜像变更及 detach 失败。尾部专项测试在 detach 后的来源复核回调内修改 live disk，实际得到 `Installed target changed during qualification`；恢复拒绝覆盖该未知字节。

最终内存子进程的 RSS 峰值增量分别为 capture 5144576、validate 2211840、publish/reverse 各 2375680 字节，均低于既有回归阈值。主扫描缓冲仍为两个最多 1 MiB 的 Data；两个 SHA 状态不保存整盘内容。RSS 结果不能证明任意输入的精确分配上限。

## 动态计数

`verify-traces.py` 复用已有 trace 完整性检查，并核对本轮父子关联、SHA 对象、实际字节、同步顺序和块数；结果为 `trace-check.json`，通过。

- 16 MiB+3 字节 capture 探针：3 次独立 SHA、2 次融合 SHA；两份备份各读取 16777219 字节、18 次 native pread 尝试（含 EOF）；4097 个块、5 个变化偏移。三次 sync 均在融合扫描前完成。显式逻辑读取合计 83886095 字节，即 5 倍输入长度。
- 两次更新和一次回退的合成公开流程：6 次 candidate 校验各执行 2 次镜像 SHA；18 次 published 校验各执行 4 次；每次读取 12288 字节。原有校验调用次数保持。

探针仅用于计数，使用 debug 构建，未进行本轮对照性能基准。不报告耗时改善比例，不外推完整 64 GiB 发布的加速比例或 SHA 时间占比。任意并发修改时序下的完全观察等价仍未证明。

## 工件保持

按既有 protected-inputs 清单核对，266 个冻结证据文件和 3 个已安装可执行文件摘要全部保持，见 `protected-inputs-check.json`。本轮未运行真实 VM、真实挂载、AMFI 操作或安装。固件 fixture 测试的跳过不作为真实行为通过证据。

初始源码见 `before/` 和 `before-manifest.json`。新增测试的两次编译错误记录保留为 `focused-compile-failure*.log`，不作为功能回归失败或通过证据。最终源码、测试、可执行测试产物及本轮证据摘要见 `final-manifest.json`。
