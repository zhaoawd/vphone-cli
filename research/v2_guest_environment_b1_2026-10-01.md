# v2 环境 B1：记录与判定

日期：2026-10-01。分支 `codex/handoff-20261001`。依据 `v2_guest_environment_design_2026-10-01.md` 第 2.2、6、7.1、8 节；实施只涉及宿主记录、只读判定和声明。

## 修改

- `guest_environment.json` 保持 schema 1，新增 `profiles.v2`：regular、API 独立身份与缓存、关闭相机监听、T18 预留文件。
- T16 从检查点 `effective_options` 读取 variant 与 guest_environment；从恢复记录读取顶层字段。v2 记录与 v2 磁盘不再生成 classic 原因；v2 记录与其他 bootstrap 不一致时报告原因。不同来源显式记录不一致时拒绝。
- API 守护进程路径、二进制 SHA-256、launchd.plist 键作为 `daemon` 证据；缺失只加入 `notes`，不改变库分类。
- 检查点新增可选 profile，classic 默认不编码；环境变化影响最早 `cfw` 阶段。v2 只接受 regular。
- `restore-info.json` 新增可选 `guest_environment`；重写 variant 时保留环境记录。
- environment 声明增加 `guestEnvironmentV2` opt-in 与 regular 范围；resolver 单独接收 opt-in，固件步骤集合不变。CLI 入口留给 B5。

## 修改前证据

| 测试 | 结果 |
| --- | --- |
| `AssessTests.test_less_variant_is_not_applicable`，夹具改为真实检查点层级 | checkpoint less 被判为 offline_update，失败 |
| `test_v2_record_matches_v2_disk_without_classic_variant_reason` | full_migration_required 与 already_current 不符，失败 |
| `test_checkpoint_v2_record_without_bootstrap_reports_mismatch` | 缺少明确记录不一致原因，失败 |
| `test_api_daemon_evidence_does_not_change_environment_classification` | profiles 不存在，错误 |
| `GuestEnvironmentCheckpointTests` 首项 | profile 字段和初始化参数不存在，编译失败 |
| `v2IsAcceptedOnlyForRegular` | dev/jb/exp/less 四项未抛异常，失败 |
| `variantRecordingPreservesGuestEnvironment` | 重写 variant 丢失字段，失败 |
| `guestEnvironmentDeclarationRequiresOptInAndKeepsFirmwareSteps` | opt-in 枚举及 resolver 参数不存在，编译失败 |

## 验证

- 判定相关 `AssessTests`：18 项通过。
- 记录与检查点相关 Swift 测试：15 项通过。
- 历史摘要比较采用原有六字段对象和 Foundation 的 prettyPrinted/sortedKeys 格式。最初新增固定摘要误用了紧凑 JSON；全量测试识别该测试错误后改为直接按历史编码规则计算，未修改产品摘要逻辑。
- `.build/debug/vphone-cli fw plan --variant regular --json`：environment 声明列在 excludedByOptIn，条件为 guest environment v2；opt-in resolver 测试核对固件 enabledSteps 不变。
- `make test_python`：562 项通过（170.246 秒）。
- `make test_swift`：退出 0，全部测试套件无失败；guest 组件 124 项检查通过。
- `git diff --check`：通过。

## 验证限制

未安装库、修改 launchd、写入客户机磁盘或运行真实 VM。API 守护进程这里只记录身份，B2 实施对应源码和候选构建。B3 实施离线安装器；声明目前仍为 guestStep，不能据此认定安装或启动通过。
