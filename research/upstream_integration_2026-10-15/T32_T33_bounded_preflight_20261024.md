# T32/T33 有界预检与成本测量（2026-10-24）

当前不执行待审的74985b1c…部署计划。已完成Preboot路径定位：`Cryptexes/OS`是目录，`Cryptexes/OS/System`不存在；有界扫描67项没有找到其他SystemVersion.plist，正常卸载、磁盘身份保持。上游另处理System卷`System/Cryptexes/OS/.../SystemVersion.plist`，本地安装步骤原先遗漏此路径。不能仅凭原件blob存在和算法通过认定Preboot路径已部署。

## 已完成的检查

- 保留SystemOS缓存只读挂载，candidate16f1cc296c84中的真实dry-run：hv_vmm定位20处字符串，2.171秒；camera解析6个实际符号并核对指令，0.831秒；SwapEnd定位0x548→0x560，0.372秒；Cryptex plist读取，0.087秒。检查前后2931条目的树摘要及缓存完整字节保持，正常卸载。
- EXP“变换→实际cp→效果核验”的原有合成回归补入硬链接源布局，实际复制后两个目标均为单链接。保留来源篡改及效果丢失拒绝。两条流程用例加9项读取器回归，共11项通过，1.090秒。只有挂载表和只读标志为夹具，不构成原生APFS或完整CFW通过。
- 用真实捕获的文件内容创建新副本：两份plist仅改目标键、幂等、不重写、完整字节恢复及再次生成相同字节通过；launchd实际weak dylib注入、jetsam补丁、签名及entitlements保持通过，139代码页；watchdogd两处修改及46代码页通过，未重新签CMS；debugserver复制品签名、effective entitlements和137代码页通过。launchd/debugserver的CMS完整性通过，未验证远程发布者身份，未执行这些客户机程序。原生Undo仍未执行。
- 本次iOS26.0不执行27限定的maxSlide、lsd、xpc、lockdown、diskimagesiod和Campo修改。没有将这些分支计为本次真实通过。

## 实测成本

| 调用 | 用时 | 观察 |
| --- | ---: | --- |
| Python生产digest，单个真实64GiB postimage | 27.435秒 | 完整摘要匹配密封发布；其中hash.update19.833秒，read7.579秒；包含cProfile开销 |
| regular实际verify-plan | 222.811秒 | 1503次fileSHA256；readFile累计284.577GiB；postimage摘要4次、共256GiB、200.603秒 |
| 新EXP实际verify-plan | 7.803秒 | readFile累计10.468GiB，无历史postimage摘要 |

两次原生调用均退出0，无超时或进程信号，trace有complete终止记录。fileSHA256包含readFile，treeDigest递归包含子调用，不能将这些嵌套用时或字节相加。上述数字是单次测量，不是整轮总耗时分解，也不能直接推算下一轮耗时。当前regular的4次postimage摘要占该次命令约90%的用时。plan_gate每个独立调用会重新运行Swift verify-plan，因此历史深度与调用次数是后续成本审查重点。本轮没有减少完整性检查或实施摘要缓存。

## 真实文件存在性与当前阻塞

第一次原生只读检查挂载EXP的system/preboot卷，取得system plist、launchd、watchdogd、debugserver、diskimagesiod的真实副本；Preboot的`Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist`返回missing-or-linked。两磁盘身份保持，目标无附件，正常卸载。该结果区分了“stock Cryptex原件blob”和“当前VM实际目标文件”。

Preboot路径定位已在用户完成第二次系统认证后结束，session64090退出0。此次只读元数据检查6.468秒，未重复verify-plan。结果保存在`.build/t32-t33-completion-20261023/exp-bounded-preflight-20261024/preboot-layout.json`。本次阶段VMStarts=0、CFWWrites=0、securityWindows=0。没有待处理的系统认证。

2026-10-25补充：已用实际复制及补丁入口复现暂存Preboot文件被错误记录为System根目标；复制记录和挂载路径识别均正确，错误位于补丁入口的默认目标选择。局部修复及System/Cryptex路径补齐正在完成回归，详见`T32_T33_target_binding_20261025.md`。目标表摘要已改变，旧待审计划及候选不能覆盖新修复，不能重跑。当前Preboot缺失保留为真实限制，不创建替代文件。

证据：`evidence/T32-T33-completion-20261023/bounded-preflight-20261024/manifest.json`。此归档只包含已完成检查，后续布局结果须另记。
