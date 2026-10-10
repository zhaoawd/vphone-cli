# B37：T08 离线准备结果（2026-10-11）

本轮仅完成用户指定的事项 1、2 离线和 4 离线部分。代码、测试和证据均位于独立 worktree `/Users/kolar/.codex/worktrees/t08-roothide/vphone-cli`。未执行 VM、客户机磁盘挂载/读写、服务激活、源 VM 维护或 AMFI 操作。

## 结果

路径配置由 workspace.json 显式区分 code_root、artifact_root、vm_root、work_root。输出和测试缓存限定于代码 worktree，输入不由当前代码根推导。boot.py/client.py 仅提供 --check 预检；--run 返回范围限制错误。B33–B36 历史执行脚本保持原样，本轮通过新的预检入口核对运行路径；后续实际运行脚本适配仍需在获准运行时完成。

已核对 B36 保存分类与其证据摘要，生成 migration-plan.json 和 MIGRATION.md：覆盖五项环境库、LaunchHook 加载路径、daemon/作业配置、相机组合、宿主兼容性、默认资源和自动更新，以及暂存磁盘事务和恢复条件。使用已有分类，未重新打开 Disk.img。计划并非已实现迁移器。现有环境更新器拒绝 classic 完整迁移的回归仍通过。

完整默认 Bundle 的资源、原生依赖、签名和 entitlement 校验通过。现代 API 的七项固定依赖、0.7.16 IcliKit/JPEG overlay、候选 manifest、动态依赖和签名检查通过。六项现代组件的固定源码、arm64e/IOS 元数据、签名和清单通过。663 项当前生产输入、冻结源快照和 B35 构建记录摘要一致；本轮未修改产品生产源码，因此复核现有冻结产物，未重新构建。

默认 Bundle 的 daemon SHA256 为 7ced6f3a43f3a0327c18f99ac9e30d1d788267b145e5cf8a110df0ba8a76c0a1，现代候选为 36005e2af21d8e72e0b944e5f38c0bdfa373b86e3bb67b889ec4245c3165dd1a。默认打包仍 classic，Bundle 内未找到摘要匹配的五项现代库。现代候选静态合格不能证明默认现代打包或实际运行来源一致。

## 验证命令和结果

在独立 worktree 执行：

```sh
/Users/kolar/github/vphone-cli/.venv/bin/python3 -B research/upstream_integration_2026-10-06/evidence/B37/T08/offline.py
/Users/kolar/github/vphone-cli/.venv/bin/python3 -B research/upstream_integration_2026-10-06/evidence/B37/T08/run_regressions.py
```

第一条保存 5 项静态/路径检查，全部退出 0。第二条使用项目 unittest 加载定向套件：68 项通过，0 failures、0 errors、0 skips；固定依赖通过明确只读路径提供。CFW 测试只使用临时目录构造的系统卷和伪造 Mach-O，不使用实际 VM 磁盘。随后运行现有 Makefile 的 test-loader-links 与 test-vcam-dataplane，两项均通过，后者 124 checks、0 failures。入口精简后重跑受影响的 10 项路径/范围测试，通过。

回归监管每 0.5 秒检查磁盘余量，低于 5 GiB 时只结束本轮测试进程组；5 分钟时限控制本轮测试。低磁盘拒绝路径在夹具中验证，未实际填满磁盘。记录最低余量 288190423040 字节（约 268.40 GiB），阈值未触发。输出见 offline-result.json、regression-result.json、regression-commands.json 和对应 txt。

## 未验证与待实现

- classic 宿主控制使用 1337，现代 API 使用 1339。classic 无条件启动相机发布端；现代 64 字节共享头与 classic 256 字节头不兼容。宿主控制适配或无相机 classic 兼容进程尚未实现；当前迁移计划不能直接执行。
- 默认现代打包、适用 CFW/变体选择和自动更新组合尚未实现。本轮只核对已有默认与候选产物。
- 实际 launchd 原始备份、签名后的 /vh 改动、旧服务清单、迁移事务和恢复流程尚未在真实副本验证。
- RootHide 冷启动自动激活、实际 daemon/库来源和 T08 整体验收未执行。T08 accepted 保持 false。B34 受控场景 180° 原因不在本轮重复调查范围。
