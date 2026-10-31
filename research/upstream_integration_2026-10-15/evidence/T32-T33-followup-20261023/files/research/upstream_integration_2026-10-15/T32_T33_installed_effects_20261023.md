# T32/T33 当前目标、撤销资格和来源核验（2026-10-23）

下一阶段需要批准新的具名运行诊断计划：`.build/t32-t33-followup-20261023/runtime-plan.json`。计划只在完整持久状态备份后启动一次既有T32 GUI VM，记录AA.gl摘要及系统设置显示帧；新的单哈希900秒/一次附加窗口尚未开启。不会执行CFW安装、撤销或重应用。当前停机测试VM和其他VM保持。

## 本轮结果

新增正式入口 `cfw verify-effects`，在目录锁、无持有者和无待恢复事务条件下，使用私有挂载目录独立只读挂载当前盘，按已认证发布记录逐一核对实际文件内容、类型、链接和mode/uid/gid。前后重新核验完整发布、generation原件关联、blob及镜像稳定性；正常卸载后返回结果。该报告不修改历史Receipt，也不授予Undo、受信来源或运行效果资格。

正式执行命令：

```sh
.build/debug/vphone-cli cfw verify-effects vm-t32-t33-dsc-20261018 \
  --library-root /Users/kolar/github/vphone-cli \
  --work-parent /Users/kolar/github/vphone-cli/.build/t32-t33-followup-20261023 \
  --report /Users/kolar/github/vphone-cli/.build/t32-t33-followup-20261023/actual-audit-final.json \
  --root-popup
```

| 对象 | 结果 |
| --- | --- |
| 当前盘4681个发布目标 | 4680匹配，1不匹配；进程退出1，整体验证失败保持 |
| 唯一差异 | hardware:/AA.gl，仅内容SHA-256不同，mode0600/UID0/GID0相同 |
| AA.gl发布摘要 | 64aa8198123ce272ac14bd7eece4786758d48f48321ea7a91e2ec55ca560462d |
| AA.gl当前摘要 | f92c991d3a177eda4cb8b43618ccbb4ae5a244e289cf8c7db824a6f8c092ae71 |
| 当前DSC .42 | 完整摘要匹配，6885个CodeDirectory代码页通过 |
| 指令语义 | 复用原符号派生的只读诊断，generation原件w3=0x548，匹配当前完整摘要的effect blob为w3=0x560；未新增匹配或补丁算法 |
| 保留发布镜像 | 独立只读检查4681项全部匹配，包括AA.gl；退出0 |
| generation原件关联 | 既有认证原件树、DSC复制链和签名页核验通过；guest受信Core Bundle来源仍未授予 |
| 撤销资格 | dyld-boot-iomfb_swapend拥有合格DSC后缀前像；Mach-O、安装树等仍明确not_revertible |
| 收尾 | 两组挂载正常卸载/detach；当前盘及配置/SEP/NVRAM/来源记录保持，未启动VM或开启新窗口 |

发布镜像SHA-256为 `bc794249dcb21b0e2648e7933435ec7487ac932b04c6d1f69f86b7e5d0191c88`；当前盘为 `c7bb43708c40cb9f48b86f7b8413904e4a0135d73aa3cfe1db3d0e8eb4ad5c59`，与此前运行后记录一致。事务仍为 `20261020T145635Z-QBLOIoqy`，generation为 `6ebc5f6705cf0bffb32da62bf3006cc7ece5027edee4306abc8031aee9f4bb42`。

## 原因和验证限制

三项待验证假设为：客户机运行期间更新AA.gl；发布记录与保留镜像不同；挂载卷或目标选择不同。独立发布镜像全量核验支持其内容与记录相同。两次读取均检查输入镜像、PhysicalStores、volume device及只读挂载，未发现挂载关联异常。由此确认AA.gl在保留发布状态与当前状态之间发生变化；具体时间、写入者和原因未查明。不得将变化归因于某一次启动或直接据此认定系统正常写入。

既有启动日志原文记录 `init_data_protection: Gigalocker file (/private/xarts/AA.gl) exists`，用于限定下一阶段的客户机读取路径；该日志不证明写入行为。本轮没有读取或保存单独的当前gigalocker原始内容，独立报告只保存摘要和元数据。

`undoEligibility`仅描述历史前像和完整声明选择，不授予写入资格。当前AA.gl保留效果不一致，仍会阻止现有严格最终核验；没有把该目标排除、改为可变文件或用当前字节覆盖旧基线。Mach-O/Preboot及任意中间操作重打、受信guest来源推进仍未实现。图形路径、业务运行效果和补丁因果效果本轮未验证，T32/T33整体accepted=false。

## 修改及验证

- 新增 `scripts/cfw_verify_effects.py` 和 `scripts/patchers/installed_effects.py`，注册正式Swift命令并补Bundle资源检查。
- 对每个声明给出qualified_dsc_suffix、requires_later_declarations、not_revertible或no_recorded_change；任一不支持效果不能被同声明的一个合格DSC效果掩盖。
- 保存当前目标差异、签名页错误、来源/发布变化、未知卷/路径穿越/重复目标、挂载只读状态、已有附件保留、卸载失败保留、新报告排他发布及失败退出码回归。
- 首批新增6项通过；挂载夹具初次错误引用已归档目录，保持断言后修正，13项通过。实际管理员模式失败会将完整stdout合入AppleScript错误，因此增加独立排他报告及原调用者归属；最终16项通过，失败仍退出1，拒绝退出2。
- 相关Python100项、Swift命令3项通过。最终完整 `make test_python`：1030项，跳过4项，286.076秒，退出0。前轮完整1027项也通过，其后增加3项报告回归。Swift沙箱内首次构建因模块缓存EPERM失败，沙箱外编译及命令测试通过；原日志保持。
- 下一阶段准备资产2项回归通过，覆盖空白/相同显示帧拒绝及计划/批准/工具/备份篡改拒绝。该结果不替代真实启动。

## 下一阶段具名计划

原历史程序路径 `.build/t32-dsc-companions-final.app` 已不存在。现存 `.build/t32-cryptex-symlink-final.app/Contents/MacOS/vphone-vm` 完整SHA-256 `a25bfd3af55c5a2af4aab1a84541be8328a430b5d8bd267be2704ba72ca54125` 与旧冻结执行记录一致，CDHash `89b70a253cad2adea133b3e875519afaf72c5d17`，严格签名检查通过。只运行帮助参数退出-9，未启动VM；本轮未独立读取其系统拒绝原因日志。

准备结果：

- 原盘完整CoW备份及12个根级持久文件逐一完整摘要核对通过，清单 `.build/t32-t33-followup-20261023/runtime-backup.json`。generation原件及全部CFW历史保持原路径，备份不自动授予恢复资格。
- 一次GUI启动，不更新daemon、不安装探针；仅计算 `/private/xarts/AA.gl` 摘要，不另存原始文件；正常启动系统设置并记录两个显示帧和前台应用，再正常关机。失败时不强停VM。
- 新窗口仅对上述CDHash，最长900秒、一次附加、无持久允许名单，由独立进程监督，就绪或失败即停止。若同一amfid被本次附加暂停，仅在helper退出、debugserver不存在且PID/UID/启动时间/程序均相同后发送SIGCONT并核实；不操作替换PID或重新附加。
- 57个执行输入摘要冻结；计划SHA-256为 `7e6686ac5232991e13d575e3682258d40d73593f2b839f799517857518bde9a7`。批准前不运行启动器或辅助程序。

本轮没有新增固件、内核或DSC指令补丁，没有提交或推送。证据另存 `evidence/T32-T33-followup-20261023/manifest.json`，旧on/off/on及四次正常启停证据保持。
