# T08 方向复现脚本

`rotation_probe.py` 有离线回放和实际 VM 两种入口。脚本尚未在实际 VM 上运行；已运行的离线检查只验证证据判定。

## 已执行检查

```sh
.venv/bin/python -m unittest discover -s tests -p test_t08_rotation_probe.py -v
.venv/bin/python research/upstream_integration_2026-10-06/evidence/B33/T08/rotation_probe.py replay research/upstream_integration_2026-10-06/evidence/B32/T08/B-home-button-true.jsonl --request-id B-home-button-true
```

8 项测试通过。原始 B32 日志回放退出 2，原因 `observation_window_too_short`；5 个匹配样本覆盖 1.001129 秒，无错误且未看到目标方向。退出 2 说明复现条件或证据不足，不能据此判断系统请求机制。

## 实际运行前置条件

- 源 VM 正常停机，自动恢复已按批准临时暂停；研究副本与源不得同时运行。
- 研究副本已经完成 RootHide 安装、89 包事务与冷启动验收；`bootstrap.inspect` 的 layout 必须为 `roothide`。
- 0.7.16 研究 API 和 classic 文件通道可用，方向锁已关闭。
- 当前 `fixture-v4.ipa` 实际安装成功，保存真实 `apps.install` 返回为 `.build/research-b33/fixture-install.json`。脚本从返回中读取实际容器路径，核对本机 IPA 的固定摘要。
- 临时 Frida 17.17.0 server/agent 已正确部署；私有 endpoint 文件含 `ip`、`port`、`token_file`，令牌文件只保存在本轮 `.build` 私有目录。宿主同版本客户端已准备。

```sh
.venv/bin/python research/upstream_integration_2026-10-06/evidence/B33/T08/rotation_probe.py live \
  --install-result .build/research-b33/fixture-install.json \
  --endpoint .build/research-b33/frida-endpoint.private.json
```

脚本只向已安装的受控应用写入 policy.plist，不自动转换 bootstrap、安装应用或部署 Frida。策略覆盖限定 `VPhoneB31Rotation` 进程，继续复用 B32 原 Frida 脚本。当前方法锚点不匹配时停止，不能自动沿用历史地址。

## 实验设置与判定

同一 PID 和同一场景：A 0°基线→A 180°→B 90°→B 0°→B 180°→恢复 A 0°→恢复 A 180°。每个请求 ID 唯一，每阶段至少连续采样 10 秒。应用原日志以 0.25 秒周期记录；脚本要求相邻样本间隔不超过 1 秒、PID 保持、前台活跃、锁 false、控制器/场景/客户端集合等于实际预期值。

每阶段保存原始 JSONL、前后场景策略、条件调用记录、API 方向及独立截图摘要。UIKit `effectiveGeometry.interfaceOrientation` 为主要断言；截图与 API 是附加观测。相同竖屏尺寸不能区分 0°和180°。

- 退出 0：阳性和拒绝对照通过，B 180°实际目标方向在最后 1 秒保持。
- 退出 1：对照通过，B 180°连续窗口内无错误且始终未出现目标方向。该结果捕获原问题，原因仍需后续请求边界证据。
- 退出 2：条件、证据或恢复失败；临时出现目标后恢复也单独记录，不能当作稳定旋转。

脚本 finally 尝试恢复原 Home 键返回值、请求0°、卸载 Frida 脚本并 detach。恢复失败保留具体结果。应用卸载、临时 server 停止和研究 VM 正常停机由本轮后续清理步骤完成；仅限用户已经批准的研究副本范围。

最终实际输出保存在 `.build/research-b33/rotation-<id>`。保全到研究证据目录前检查令牌缺失，并单独标明运行来源、输入摘要、失败和验证限制。
