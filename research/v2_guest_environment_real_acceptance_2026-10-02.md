# v2 环境真实验收：2026-10-02

## 授权与对象

用户确认 B5 交付后提出的范围：在 `/private/tmp/vphone-v2-build-20261002` 独立构建签名产物，新建 `/Users/kolar/vphone-v2-accept-20261002/VMs/lp-v2-accept-20261002`，运行 R1–R4（认证、TSS 联网、VM 启停和诊断）。R4 若符合 D6，停止后续验收。R5–R9 未获本次授权。不操作 `vm-2607`、`vm-new`，不在主仓库运行 `make build`。

## 准备进度

- 独立分支 `codex/v2-accept-20261002`，起点 `88acf46`。工作树与 `.build` 独立，vendor、SwiftPM 二进制依赖和资源从本地已有内容复制。首轮缺 vendor 的构建失败；补齐后 `make build` 已成功，bundle 签名与资源校验通过。
- `make guest_components_build` 首次失败：`LocationFix/libvlocation.m` 不符合输入清单的上游摘要。
- 已查明原因：提交 `5d1bdaf`（T20）允许 `verticalAccuracy == -1`，清单未记录该本地修改。保留 upstream_sha256，新增 local_sha256 和修改来源；不改源码、不绕过校验。新增仓库源码校验回归，修改前失败、修改后 4 项通过。日志 `/tmp/vphone-v2-pins-{red,green}.log`。
- 候选构建与宿主 preflight 正在执行。`pgrep -fl amfidont` 无进程；交接要求由用户运行启动脚本。真实 VM 尚未创建。

## 验证证据与限制

构建日志 `/tmp/vphone-v2-sign-build.log`；候选日志 `/tmp/vphone-v2-candidates.log`；宿主检查 `/tmp/vphone-v2-preflight.log`。当前构建和合成测试不建立 R1–R4 成功结论。
