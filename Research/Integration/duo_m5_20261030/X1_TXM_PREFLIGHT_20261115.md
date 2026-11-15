# X1 声明与 TXM 同步预检（2026-11-15）

本轮完成 TASKS.md 前两项的代码、声明、依赖评估及可执行预检。基础提交 `4fb8afe2`，上游固定为 `1316940501398ea279f960ee7d838f93885730d4`。本轮只新增测试与研究资产，未移植生产补丁、修改预设或写入固件；未启动 VM、改变宿主准入、推送或发布。

证据目录为 `.build/x1-txm-preflight-20261115/`。正式保存入口运行结果位于 `saved-run.NrAzph31/`；早期命令、编译失败及修正记录保留在父目录。沙箱内 Xcode 服务连接失败，随后在正常构建环境运行成功；suite 条件宏的两次编译错误属于本轮测试代码，不计为产品失败。

## #924 的差异与迁移要求

固定来源为 #924 合并 `9eb9a478`，包含 `693e42f7` 的独立声明与最终审计修正 `a08b5b10`。上游继续使用 #844 的 HomePop 单项声明和 #895（`f2a4e071`）的可选独立镜像安装器，并扩展其目标清单。本地已有 `72b83eb2` 的聚合 AX 处理，不能逐文件原样套用该 diff。

| 对象 | 当前 Duo | 固定上游 | 影响 |
| --- | --- | --- | --- |
| AX 声明 | `system-accessibilitybundles-cfw-arm64e_x1`，目标为整个 AccessibilityBundles 目录，限 iOS 27.1 | 新增 35 项独立声明，HomePop 保留既有单项声明 | 新 35 项路径全部位于当前聚合目录内；这是路径范围重叠，不能据此声称实际镜像均已完成转换 |
| 适用性 | 枚举 Info.plist；识别薄 Mach-O X1 或已有 `.bak` 的可执行文件 | 按可选镜像实际字节判断；缺失或无需转换时保持原文件 | 需验证普通 arm64e、通用二进制和缺失镜像，不可只更换声明清单 |
| 转换完整性 | `lowerAndReattest` 报告 unvisited candidates，当前 CLI 不要求为 0 | 可选镜像使用 `lowerCompletelyAndReattest`，未完整转换时拒绝发布字节 | #895 的完整转换路径是 #924 安装实现的前置依赖 |
| 备份与签名 | 通用 `patchMachO` 在运行转换前备份，随后签名并替换；聚合步骤重新封签 bundle | 可选安装器先在内存完成转换／签名，无改动时不创建备份；签名失败时恢复旧状态 | 需要迁移现有 `.bak`、旧收据和共享 bundle seal，不能让两个安装步骤写同一文件 |
| 审计 | 当前没有 `cfw audit-arm64e-x1` | 内容发现、生产规划器内存分析、签名覆盖检查；最终修正排除非 X1 通用文件并要求卷根目录 | 审计移植需保留本地目录声明的覆盖含义，不能仅按精确文件路径匹配后报告全部无声明 |

执行的目录预检读取真实本地 manifest 和固定上游 35 项清单：35 个 ID、路径均唯一；本地无这 35 个精确路径声明，但它们全部处于聚合目录范围。当前标准计划仅在 iOS 27.1 启用该聚合补丁。未读取这些 35 个真实 guest 原始镜像，因此不能将清单比较计为实机转换或应用启动验收。

选择迁移负例通过生产 `VPhonePatchPlan.resolve` 复现：

- 保留聚合声明并直接增加 35 项时，旧选择关闭聚合项，35 个独立项仍全部启用。
- 删除聚合声明后，携带旧 ID 的选择因 `unknownPatch` 被拒绝。

方案为先实现旧选择／收据迁移，再启用独立声明。旧聚合禁用选择必须映射到全部替代目标，已有单项目标选择需有明确优先级。每个文件只保留一个写入与撤销步骤；需要显式处理 HomePop 及聚合枚举曾覆盖、但不在 35 项表内的文件。退役旧收据前必须完成备份归属核对，恢复失败时不得写入“已迁移”的收据。Duo `31933ff2` 的共享缓存撤销归属保持独立，本轮未修改该代码；11 项 undo words 测试通过。

## #919／#923 的依赖与策略

来源链为 #831（`0aafb0f1`／`af560830`）的 native classification，`176bb80a` 的缺失 profile 修正，#919（`eefe49e9`／`22703e39`）的可选 precheck，以及 #923（`615d96c2`／`8a4d35cf`）的优先级。当前分支保留旧 precheck 实现，但没有 `TXMExecutableRemap.swift`、`TXMMissingProfile.swift` 和对应声明，因此仅套用 #919／#923 不足以完成同步。

| 对象 | 当前 Duo | 固定上游 |
| --- | --- | --- |
| precheck | `txm-boot-precheck_admission`，bootEssential，iOS 27 标准计划启用 | `txm-exp-precheck_admission`，非 bootEssential，限 iOS 27，standard 禁用 |
| remap | 没有实现或声明 | `txm-cfw-executable_remap`，standard 选择，保持 native classification 并增加特定兼容出口 |
| 同时选择 | 当前无 remap，不能覆盖此组合 | precheck 优先，执行 base trust-cache bypass，不生成 remap 记录 |
| AMFI trust-cache bypass | 当前 iOS 27.1 标准计划启用 `kernel-boot-amfi_trustcache` | remap 路径在该开关启用时要求缺失 profile 兼容出口 |

直接把旧 precheck ID 改名会使旧选择因 `unknownPatch` 被拒绝，已用生产解析器复现。现有机器的 boot-chain 收据也必须核对；改名、变更标准选择和实际部署不能视为同一操作。

## 参考 TXM 的内存验证

唯一参考为已有隔离副本内的原始 `FirmwareOriginals/.../txm.iphoneos.research.im4p`。容器 SHA-256 为 `eda4261548a786998b35f0165d51c05b262727ef4160e7eb1bc4e3c3b9900192`，解包 payload 为 `819861b6b534b6dc53287b010e822b9d93633d07a29b6e5b968c076929ebfbc1`。本轮只读原容器，转换结果仅保存在内存；解包参考副本和 JSON 证据留在 `.build`。

本地标准计划生成 16 条 TXM 记录，其中 precheck 4 条；显式关闭 precheck 后为 12 条，其余记录 ID 顺序不变。全部修改范围与记录一致，原文件字节保持不变。将参考副本中 3 个 `mov x17, #0x7e51` 后的 `blraa` 改为 `ARM64.nop` 后，precheck 方法不再生成记录。

将固定上游的四个生产 TXM 源文件直接编译为独立预检程序，使用当前 VPhonePatchKit，运行以下 8 个组合。表中仅列 precheck／remap 子记录，其他共同记录不在这两列中。

| AMFI trust-cache bypass | 选择 | precheck 记录 | remap 记录 |
| --- | --- | ---: | ---: |
| 关闭 | remap | 0 | 4 |
| 关闭 | precheck | 4 | 0 |
| 关闭 | 两者 | 4 | 0 |
| 关闭 | 均不选择 | 0 | 0 |
| 启用 | remap | 0 | 5 |
| 启用 | precheck | 4 | 0 |
| 启用 | 两者 | 4 | 0 |
| 启用 | 均不选择 | 0 | 0 |

两个 AMFI 组合下，“同时选择”的完整输出均与“只选 precheck”相同；上游显式 precheck 的完整输出均与当前 Duo 标准策略输出逐字节相同。该结果证明此参考镜像上的静态记录与输出关系，不证明 native remap 的实际启动、应用注入或热重载行为。

建议实际移植先引入完整 native remap／profile 实现和选择迁移，再准备“保持旧 precheck 输出”与“native remap”两份明确候选。两者分别完成启动、ad-hoc dylib 注入、应用可执行页 remap 和回滚验收后，再决定 Duo 标准策略。当前不改变预设，不将实验 precheck 自动加入新的默认选择。

## 可回归入口与结果

```zsh
zsh Research/Integration/duo_m5_20261030/Regression/x1-txm-preflight.zsh \
  "$PWD/.build/duo-runtime-84e3ce54/machines/duo-rpc-foundation-20261115/FirmwareOriginals/iPhone19,4_27.1_24A94425_Restore/Firmware/txm.iphoneos.research.im4p"
```

入口固定上游版本和参考摘要，在 `.build/x1-txm-preflight-20261115/saved-run.*` 保存独立结果。4 个 suite 共 65 项测试通过：X1 lowering、undo words、补丁目录，以及新增 4 项同步预检。8 个上游 TXM 策略组合通过。新增 suite 需要 runner 设置环境，普通测试运行不自动读取私有固件。

主要证据为 `catalogue-preflight.json`、`selection-migration-negative.json`、`txm-current-records.json`、`txm-anchor-negative.json`、`txm-upstream-policies.json`、`current-tests.log`、`upstream-probe-build.log` 和 `upstream-policy-run.log`。新增测试最后一次空记录保护调整另以 `preflight-final.log` 复核，4 项通过；上游程序整理格式并增加 remap 记录数断言后，`upstream-probe-final-build.log`／`upstream-policy-final.log` 再确认 8 个组合通过。未修改生产代码，因此未重建完整 Bundle；既有 Bundle 的签名和运行验收不代表未来移植候选已经验收。

## 后续实现顺序

1. X1：引入完整转换／可选安装器，补旧聚合选择、备份、收据和 HomePop 迁移，再启用独立声明与只读审计。用真实镜像副本验证转换、签名、重复应用和撤销；保留共享缓存其他补丁。
2. TXM：引入 #831 与 profile 依赖、兼容旧 ID 和收据，然后接入 #919／#923 的可选策略与优先级回归。完成两份候选的静态比较，再准备独立 VM 验收。

这些生产移植和实际 VM 验收尚未完成。本轮没有修改任何已有 VM 的启动策略或状态文件。
