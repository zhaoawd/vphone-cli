# C3 验收失败：26.4 内核定位与 less 前置条件

日期：2026-09-09。范围：`kernelcache.research.vphone600`，cloudOS 26.4 / 23E5207q；对照 cloudOS 26.1 / 23B85。本轮只分析，不应用新二进制补丁，不改变 required 规则。

## 复现与来源

```sh
VPHONE_DIAG_KERNEL_IM4P="$PWD/research/artifacts/c3-kernel-2026-09-09/stock-264-ranged/kernelcache.research.vphone600" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/test-module-cache" \
SWIFT_MODULECACHE_PATH="$PWD/.build/test-module-cache" \
swift test -c release --disable-sandbox --cache-path .build/test-cache --filter KernelGateDiagnosisTests
```

结果：两项失败，总运行时间 8.034 秒。EXC_GUARD 输出 `thread_guard_violation not found via anchor chain`；vm_map_protect 输出 `vm_map_protect write-downgrade gate not found`。与前轮独立测试和单步骤 CLI 结果一致。

26.4 IM4P SHA-256：`c853504319f27bfb3283253d8a5f36c3d0166ea7f4b178fca26fe6352b4de951`；26.1：`b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac`。输入来源、构建号核实方法见 [C3 内核记录](patch_results_c3_kernel_2026-09-09.md)。

先查询 `research/kernel_info/kernel_symbols.db`，research JSON 指向缺失的 `/Users/qaq/Documents/GitHub/vphone-cli/research/kernel_info/json/kernelcache.research.vphone600.bin.symbols.json`。当前原始内核顶层与 fileset 的 LC_SYMTAB 扫描未解析到符号。本节函数名是根据字符串、调用关系、指令行为和 XNU 推定的候选名称，不是内核符号表解析结果。

XNU 参考提交：`f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`。参考 `osfmk/kern/ipc_tt.c` 的 `set_exception_behavior_violation`、`set_exception_behavior_allowed`，以及 `osfmk/kern/thread.c` 的 `thread_guard_violation`、`thread_ast_mach_exception`。本地参考源码不等同于原始内核的精确构建源码。

## EXC_GUARD：调用链变化

26.1 的 entitlement 字符串 `com.apple.security.only-one-exception-port` 在 VA `0xfffffe000704076d`，代码引用在 `0xfffffe0007b08068`。附近 BL 调用 `0xfffffe0007b08178`；该候选 `set_exception_behavior_violation` 内先检查全局字节的 bit 0，再准备当前线程、guard code、subcode、fatal 参数，并 BL 至 `0xfffffe0007b53fcc`。旧定位器能够识别这条路径。

26.4 字符串在 `0xfffffe000704416b`，代码引用在 `0xfffffe0008d0b5c0`。限制检查内联在当前函数内：

- `0xfffffe0008d0b6b8` 起加载全局字节，在 `0xfffffe0008d0b6c0` 执行 `tbnz w8, #0`。
- `0xfffffe0008d0b6dc` 设置 `w2 = 6`，随后 BL 至 `0xfffffe00094fcc30`。
- `0xfffffe00094fcc30` 候选 `mach_port_guard_exception` 将 reason 写入 guard code 的高位，设置 Mach-port guard type `0x2000000000000000`，准备线程、subcode 和 fatal 参数。
- 该包装函数在 `0xfffffe00094fccb0` 使用 **B 尾调用**至 `0xfffffe0008d595c8`，没有旧定位器要求的后续 BL。
- `0xfffffe0008d595c8` 与 26.1 的 `0xfffffe0007b53fcc` 均保存 code/subcode/fatal、写线程异常信息并设置 AST；结构偏移不同，行为与 XNU 的 `thread_guard_violation` 路径对应。

因此，失败原因是旧定位器固定的两层 BL 模式不覆盖内联检查与包装函数尾调用。目标行为仍存在；不能由本次 noMatch 推断补丁不适用。

后续修正应从 entitlement 引用恢复所属函数，按控制流识别 reason 6 的调用，验证包装函数构造 Mach-port guard code 和参数，再跟随唯一外部尾调用。必须验证目标函数保存异常信息并设置 AST 的语义。不能仅选择第一个 TBZ/TBNZ 后的 BL，也不能把以上地址写入补丁逻辑。26.1 保持原目标，26.4 增加路径；歧义必须失败。

## vm_map_protect：检查迁移到回调并改变指令形态

26.1 panic 字符串恢复的候选主函数范围为 `0xfffffe0007bc405c` 至 `0xfffffe0007bc46e4`。旧 Shape A 位于主函数内部：`mov #6`、`bics`、`b.ne`、`tbnz #22`。跳过分支 VA `0xfffffe0007bc424c` 指向 `0xfffffe0007bc4274`；被跳过块的 `and w20, w20, #0xfffffffb` 清除的是 **VM_PROT_EXECUTE（4）**。

26.4 主函数范围为 `0xfffffe0008dca0a8` 至 `0xfffffe0008dca7e8`，其内部没有旧 Shape A。该函数在 `0xfffffe0008dca298` / `0xfffffe0008dca29c` 通过 ADRP+ADD 构造代码指针 `0xfffffe0008dcae2c`，进行指针认证并存入栈中回调结构，随后调用范围遍历代码。回调内包含对应检查：

```text
0xfffffe0008dcae8c  and  w8, w8, #0x400000
0xfffffe0008dcae90  mov  w9, #6
0xfffffe0008dcae94  bic  w9, w9, w20
0xfffffe0008dcae98  cmp  w9, #0
0xfffffe0008dcae9c  ccmp w8, #0, #0, eq
0xfffffe0008dcaea0  b.ne 0xfffffe0008dcaed0
...
0xfffffe0008dcaec4  and  w20, w20, #0xfffffffb
0xfffffe0008dcaec8  str  w20, [x22, #0x18]
```

即检查 WRITE|EXECUTE（6）与 entry bit 22，再在受限制路径清除 EXECUTE。失败同时涉及两点：旧定位器只扫描主函数；旧 matcher 要求连续 `BICS → B.NE → TBNZ`，不识别回调内 `BIC → CMP → CCMP → B.NE`。

这与提交 `81b0cd8` 停用的 Shape B 不同。Shape B 的 `mov #5` 属于后续 COW 写权限剥离，修改它会保留 WRITE；本次发现的分支控制的是执行权限剥离。26.4 主函数中的 `mov w27, #5`（`0xfffffe0008dca30c`）必须保留。参考 XNU `vm_map.c` 中 W+X 限制块与后面的 `prot &= ~VM_PROT_WRITE`，二者不可混用。

后续修正应从 panic 字符串恢复主函数，再通过解码的函数指针构造、认证和存储关系发现回调；在回调中验证掩码 6、entry bit 22、条件分支和目标块中的 EXECUTE 清除与回写。仅改唯一分支 gate，不恢复 Shape B。需新增真实输入与歧义负例测试，并验证 26.1 目标不变、26.4 只增加预期分支写入，以及组合内核与调试器运行行为。

## less：输入存在，完整镜像验收仍缺前置工具

只读检查 `vm-2607/iPhone17,3_26.1_23B85_Restore/iPhone-BuildManifest.plist`，版本为 26.1；首个 BuildIdentity 引用的三份输入都存在：

| 组件 | 文件 | 字节数 |
| --- | --- | ---: |
| OS | `043-53486-120.dmg.aea` | 7851737088 |
| Cryptex1,AppOS | `043-54062-129.dmg` | 14680064 |
| Cryptex1,SystemOS | `043-54303-126.dmg.aea` | 1912602624 |

`aa`、`mtree`、`aea`、`ipsw`、`ldid`、`cryptexctl` 均可执行，`scripts/resources/cfw_input.tar.zst` 存在。但 `.tools` 与默认用户工具缓存 `~/.vphone/tools` 均未找到 `apfs_sealvolume_26.1`；宿主系统路径也没有可执行的 apfs_sealvolume。`identifyApfsSealvolume()` 要求版本对应的可执行文件；脚本 `fw_prepare.sh:download_apfs_sealvolume` 从相同版本 macOS 恢复 ramdisk 提取并签名该工具。

工作卷检查时可用空间约 41 GiB。仅凭压缩输入大小不能推算解密、可写镜像、重封装和加密产物的峰值空间；不能据此声明空间足够或不足。

本轮未挂载或修改现有 VM 镜像，未执行完整合并。下一步应先准备版本对应的 seal 工具，再把源输入克隆到独立验收目录，执行 Filesystem → Manifest，核对输出引用、哈希、trustcache、mtree/digest/root hash 与重新解密后的镜像内容。现有三份文件的存在检查不能替代镜像完整性和原始性校验。

## 状态

两项内核失败的定位机制原因已查明；修正与运行验收尚未执行。less 已明确一个缺失前置工具，完整流程仍未验收。C3 继续保持未完成。

本轮反汇编、临时只读分析脚本与复现日志归档在 Git 忽略目录 `research/artifacts/c3-kernel-2026-09-09/diagnosis-followup/`。脚本中的地址用于研究展示，不能用作补丁运行依赖。
