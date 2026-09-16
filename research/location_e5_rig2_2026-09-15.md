# E5：rig2 单实例运行验收

日期：2026-09-15。代码提交：`bc7f075b383369dfa274d89ea5e564be34c0377a`。本轮仅使用用户指定的 `vm-2607-rig2`；没有操作 `vm-2607` 或 C3 实例。

## 输入与占用

- 实例：EXP，iPhone/cloudOS 26.1（23B85），8 CPU、8 GiB RAM，原有独立磁盘和机器标识。
- 全程持有 autophone 的 `vm-2607-rig2` 排他任务锁；启动前检查目录锁、控制 socket 和待恢复事务。每次宿主启动由生产 VM 锁保护；离线状态写入另持目录锁。
- 使用 `.build/offline-next/source/.build/vphone-cli.app` 独立签名宿主，未覆盖共享默认应用。可执行文件 SHA-256：`b59745de4fd5b453dbd328b7c76157c8a30e6dd02fa36c9531dc79819a0d09b5`。
- 新客户机 SHA-256：`193f56a731747f287d1b7611f3865cb9850abaf2a26c30668f1a6b7dd223ec0b`。初始客户机只声明旧版定位能力；通过自动更新连接新版后确认 `location_owned`。
- 备份初始宿主客户机缓存、客户机内缓存、配置及恢复信息。初始定位为 off，`system-location.json` 不存在。原客户机缓存 SHA-256：`2b90b8e555c86e794733e661e9bdee4dae510e7f5fcc0ef0e9396f673a168cf4`。

## 真实接口结果

固定位置、客户端关闭连接后的持续交付、owner 冲突和显式替换、旧 generation 拒绝、连续序列、相同请求幂等、同序号不同内容拒绝、暂停与恢复、停止、超时 hold/stop 均通过。所有请求均经该实例真实控制 socket。

修复版重新完成以下真实场景：

| 场景 | 结果 |
| --- | --- |
| 固定位置跨宿主进程重启 | 恢复 31.2/121.5，状态 running；generation 从 `loc-24dc57a6-3f78-40cb-bd88-9e29a2b308af` 更新为 `loc-18bd21ee-bd94-4dfe-ac4c-9722cdaa6152` |
| 流替换持久固定位置 | 持久文件被清除；重启后 off、generation 为 null；没有恢复流或旧固定位置 |
| 截断 JSON 启动 | 文件隔离为 `.corrupt-*`；状态 off、generation 为 null，并保留 `location_persistence_corrupt` |
| 清理 | 原客户机缓存逐字节恢复；宿主缓存、配置未改变；隔离文件归档后移出实例；定位文件和 socket 均不存在 |

最终独立签名宿主 SHA-256：`6f5806cb1b0add78ee44d6f5d28de68a6ccffa4716dc39dfe2c4c8cddb8aeb26`；该次构建客户机 SHA-256：`32fce6ef51555f9faedcff4648912e24b034b570db8d15f7115ee72e76b4a9be`。修复版输入摘要见 `fixed-inputs.json`，生产修改基于上述提交的工作区；不要将最初构建摘要用于最终结果。

本轮创建的所有宿主进程均退出 0，未使用 SIGKILL；最终任务锁和目录锁均可重新取得。未将宿主退出码单独当作客户机正常关机证明。原 `vm-2607` 的宿主 PID 33731 仍存在；本轮没有向其控制入口发送请求。共享默认宿主和客户机产物哈希均未改变。

## 验收脚本修正

首次重启脚本在客户机宣布连接后立即要求定位状态为 running，实际观察到 applying，因此断言失败。后续同 generation 查询已为 running，坐标为 31.2/121.5，交付序列为 44。客户机连接完成与定位重新交付完成是不同条件；脚本增加有期限的状态等待后重跑。保留初版脚本和失败日志，未修改生产定位代码。

## 损坏文件启动问题与修复

初次损坏文件实验已经生成 `.corrupt-*` 隔离文件，但客户机连接后状态响应不再包含 `location_persistence_corrupt`。原因已确认：没有活动源时，provider 未阻止 headless 自动选择宿主定位；`startForwarding()` 经 `beginGUIControl()` 调用 `relinquishForGUI()`，清除了恢复错误。

新增 provider 启动回归测试，复现自动转发启动和错误丢失的两项失败。控制器新增 `requiresExplicitSourceSelection`，provider 在恢复出活动源或错误时均保留外部控制状态，防止自动转发隐藏错误。显式选择源仍可清除错误。修复后的定位专项共 78 项通过，0 失败。源码修改仅涉及定位启动策略，未修改固件补丁或客户机代码。

测试证据：`startup-before.log`、`startup-after.log`；失败的真实实验保留于 `remaining-before-fix.log`。本段生产修复发生在上段脚本等待条件修正之后。

## 证据与范围

本地原始证据位于 `research/artifacts/e5-location-2026-09-15/`：`offline-inputs.json`、`location-tests.log`、`session.jsonl`、`requests.jsonl`、`cases.jsonl`、各轮启动日志，以及 `remaining-initial.py`、`remaining-initial.log`、`remaining.py` 和 `remaining.log`。

修复前定位专项为 70 项通过；修复后扩大选择范围并加入启动回归，共 78 项通过、0 失败。实际接口 ACK 和宿主状态不能代替应用内 CoreLocation 读数。本轮未验证应用读数或双 VM 定位隔离，E5/F2 均不关闭。

最终运行与清理证据：`final-run.log`、`remaining-results.jsonl`、`cleanup.json`、`shared-artifacts-check.json`。独立 `make build` 与签名资源检查通过，见 `fixed-build.log`。

## 2026-09-16 提交前回归

通过 `make setup_venv` 重建项目锁定依赖，运行 Python 113 项通过；Swift 沙箱外无固件回归通过：XCTest 139 项、3 项跳过、0 失败，Swift Testing 333 项、53 个 suite 通过。首次沙箱内 Swift 运行报告 9 个问题；同一源码沙箱外复跑通过。该回归不新增定位运行验收范围。
