# v2 环境真实验收：2026-10-02

## 授权与对象

用户确认 B5 交付后提出的范围：在 `/private/tmp/vphone-v2-build-20261002` 独立构建签名产物，新建 `/Users/kolar/vphone-v2-accept-20261002/VMs/lp-v2-accept-20261002`，运行 R1–R4（认证、TSS 联网、VM 启停和诊断）。R4 若符合 D6，停止后续验收。R5–R9 未获本次授权。不操作 `vm-2607`、`vm-new`，不在主仓库运行 `make build`。

## 准备进度

- 独立分支 `codex/v2-accept-20261002`，起点 `88acf46`。工作树与 `.build` 独立，vendor、SwiftPM 二进制依赖和资源从本地已有内容复制。首轮缺 vendor 的构建失败；补齐后 `make build` 已成功，bundle 签名与资源校验通过。
- `make guest_components_build` 首次失败：`LocationFix/libvlocation.m` 不符合输入清单的上游摘要。
- 已查明原因：提交 `5d1bdaf`（T20）允许 `verticalAccuracy == -1`，清单未记录该本地修改。保留 upstream_sha256，新增 local_sha256 和修改来源；不改源码、不绕过校验。新增仓库源码校验回归，修改前失败、修改后 4 项通过。日志 `/tmp/vphone-v2-pins-{red,green}.log`。
- 修复提交主分支 `b8d2f72`，独立分支对应 `6e93d18`；修复后再次 `make build` 成功，guest/API candidate 构建成功。候选仍标 activated:false、runtime_validated:false。
- 宿主 preflight：签名 VM 执行文件 `--help` 退出 137，脚本报告 not launchable；`pgrep -fl amfidont` 无进程。无法执行 R1，实际宿主策略原因未进一步确认。
- 已请求用户按交接约定运行 `AMFIDONT=/Users/kolar/Library/Python/3.9/bin/amfidont zsh /private/tmp/vphone-v2-build-20261002/scripts/start_amfidont_for_vphone.sh`。等待用户操作后重跑 preflight。
- R1 脚本准备于 `research/artifacts/v2-accept-20261002/run_r1.zsh`（Git 忽略），通过 `zsh -n`；使用现有本地 26.1 IPSW 只读输入，缓存根指向获批测试目录，不认领或修改原缓存。
- R1–R4 尚未执行，测试 VM 未创建；R5–R9 仍需单独批准。

## 验证证据与限制

构建日志 `/tmp/vphone-v2-sign-build.log`；候选日志 `/tmp/vphone-v2-candidates.log`；宿主检查 `/tmp/vphone-v2-preflight.log`。当前构建和合成测试不建立 R1–R4 成功结论。

## R1 执行进度

用户告知已启动 amfidont。进程检查确认路径与 CDHash 限定到独立工作树；重新 preflight 退出 0，签名 VM --help 可执行。执行 `run_r1.zsh`，日志 `/tmp/vphone-v2-r1.log`。iPhone 26.1 IPSW 10,778,507,403 字节，SHA-256 `8b72a4f0394ef49d63346eaf37a442751f70c5ec49ae0db7843c5e3b843cd85b`；cloudOS 935,422,803 字节，SHA-256 `399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349`。独立缓存已写完成标记，prepare 正在解包。

R1：prepare、patch、restore 的检查点状态均 succeeded；CFW 状态 running，bundle lock 未持有。已提示用户完成 macOS 认证对话框，等待驱动执行。first_boot、verification 仍 pending，R2–R4 未执行。

## R1–R4 结果

| 步骤 | 结果 | 证据 |
| --- | --- | --- |
| R1 | 通过 | 检查点 overall succeeded；prepare、patch、restore、cfw、first_boot、verification 均 succeeded；CFW 报告 installed / already_current |
| R2 | 通过 | classification already_current；bootstrap.kind v2；/vh 别名存在，launchd_custom_loads 仅 /vh；disk.attach read-only、disk.unchanged true |
| R3 | 通过 | API session ready；device.info 成功；经典 capabilities 无 shell |
| R4 | 未通过，进入 D6 决定 | environment.loaded 扫描 282 个进程，complete true、uninspected 空；launchdhook current_pids [1]；SystemHook、libcamfix、libvcamcaptured、libvlocation 均 not_mapped |

CFW 事务 `20261002T061526Z-JlMmgfn5`，report SHA-256 `bb798348a0d7288ddb15f014e85a490b8e5d47caebc39a080f25b65d388dec08`。磁盘大小 68,719,476,736 字节；R2 不变证据包含 inode、mtime、66 处采样摘要，未作全盘 SHA-256 比较。R3 API 使用随机 token，只监听 127.0.0.1 随机端口；未保存 token。

R4 processes.list 中 cameracaptured PID 70、SpringBoard PID 34 均运行。SystemHook 在所扫描进程中无映射。未启动一个指定目标 App，App 单项插入未独立验收；此限制不改变 cameracaptured 单项不满足 R4 的结果。5 个库的客户机字节均符合候选。`application.state: not_verified` 保留，未执行定位/相机功能验收。

经典 file_get 读取 `/var/mobile/Library/Caches/vphone-launchdhook-injection.log` 成功，264 字节：三组 cache-key 和 bootstrap-unavailable；没有 inserted 记录。读取 `vphone-systemhook.log`、`vphone-launchdhook-spawn.log` 返回 open failed: No such file or directory。只读证据不能确定注入失败原因；regular 内核补丁不足仍为待验证假设。不得从 pid 1 成功映射 launchdhook 推导 SystemHook 插入成功。

按 D6 闸门未执行 R5–R9、B6/B7、T16/T17 成功路径。已对本次测试 VM 执行 vm stop，保留测试盘、T15 旧盘与所有事务记录。D6 设计选项仍由用户决定：(a) 为 v2 增加 opt-in 内核补丁并逐项验收；(b) 改为 jb 路线（需重审 /b 与 /vh 约束）；(c) 暂停 v2。原因未查明时，新增补丁不能被声明为必要或已验证修复。

原始证据位于 `research/artifacts/v2-accept-20261002/`（Git 忽略），包括检查点、安装报告、事务 JSON、R2 JSON、R3 capabilities/device.info、R4 environment/processes 与日志；summary.json 记录文件摘要。临时日志仍在 `/tmp/vphone-v2-*`。

## 后续诊断限定（2026-10-02）

用户同意先诊断后，重启只读扫描发现 App 扩展已加载 SystemHook、libcamfix、libvlocation，cameracaptured 仍未映射。原 R4 的 282 进程无映射是早期快照，不代表持续禁止 App 注入。已确认两项本地用户态缺口并构建候选，真实替换未执行；详见 `v2_injection_diagnosis_2026-10-02.md`。D6 的 regular 内核不足假设尚未确认。

## R4 修正后的复核

用户另行批准 T16 单库替换及重启。launchdhook 修正 `e344aa2` 通过事务 `20261002T064301Z-rFaRcKXJ` 发布；重启后原反馈脚本两次通过，pid 1、cameracaptured 与 App 的加载判定通过。T16 的七项身份摘要在更新前后、重启前一致；旧盘保留。故 R4 当前结果为通过（加载范围），此前失败记录保留。没有新增内核补丁。相机/定位功能、R5–R9 剩余要求及 T17 在线更新仍未验证。详见 `v2_injection_diagnosis_2026-10-02.md` 的获批真实验证结果。
