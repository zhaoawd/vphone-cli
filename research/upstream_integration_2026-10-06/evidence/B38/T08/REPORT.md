# B38：T08 验收（2026-10-11）

T08 的固定 IcliKit 依赖合同已完成，实现提交为 `1c0a80cb`。本轮把固定现代 API 加入默认构建和 regular/dev/jb/exp CFW 安装，在实际 RootHide 研究副本完成两次冷启动、接口、服务生命周期、重复截图和更新确认验证。源 `vm-new` 与原健康监测已恢复 healthy；研究副本停机，磁盘句柄和本轮挂载均释放。主 checkout 保持 `codex/handoff-20261001`，开发位于独立 worktree 的 `codex/upstream-2d21d21-integration`。

## 实现与验收范围

默认组合保留 classic `/usr/bin/vphoned`、1337 控制、1338 相机及 256 字节相机头。现代 API 使用独立 `/usr/libexec/vphoned-api`、`com.vphone.vphoned-api`、1339 端口及 `/var/root/Library/Caches/vphoned-api`。其 launchd 环境设置 `VPHONE_DISABLE_CAMERA=1`，继续执行 RootHide 启动恢复；`VPHONE_API_ONLY=1` 的隔离研究模式仍关闭启动恢复和更新。API 健康响应公开角色、缓存路径和启动/相机状态，禁用相机时移除 camera 能力并拒绝 camera 方法。

构建脚本先构建原 classic 载荷，再构建固定 API，生成组合清单；Bundle 校验检查两套载荷的身份、签名、依赖和摘要。CFW 安装把独立 API 写入 System 卷并增加 launchd 项，原 classic 仍提供宿主自动更新载荷。less 路线不安装该 API。没有新增内核、DSC 或 Mach-O 指令替换。

B37 的完整现代环境迁移计划用于整体替换经典环境；T08 的固定依赖及接口合同可由上述并行服务组合完成。本轮没有执行 `/b`→`/vh` 或现代相机迁移，未将 T03/T16 的完整新组合计为验收。当前 API 的 `device.info.jailbreak` 检测字段为空；RootHide 启动恢复依据有效完成标记定位物理根，本轮服务夹具使用明确物理根路径。这些结果不证明该进程已获得完整 RootHide 路径转换环境。B30 的实际路径重写证据按其历史运行环境保留。

## 来源一致性

| 对象 | 结果与证据 |
| --- | --- |
| 固定依赖 | IcliKit 0.7.16 / `702990b59ca412ad975f9f0ea5dafe95c30fac21`；全部 7 项 pin 的锁文件、工程要求和实际 checkout 校验通过。 |
| JPEG overlay | `bc214662ea41c281c3baf3d35805c59fdebaa307ff6163bbce61a4fe6cb46c55`；依赖源码、构建标记和运行健康响应一致。 |
| API SHA256 | `6a95c0c0eed2028bf191cdd187adf6df9480187924e33d5f7be1f8037b96733b`；当前 worktree 构建、候选、默认 Bundle、写盘及两次运行读回一致。 |
| 宿主工件 | 133 项宿主源码摘要与 B35 相同，复用该签名宿主闭包、更新默认 guest 及脚本资源并重新签名。完整 Bundle 资源、7 个宿主 Mach-O、签名和 entitlement 校验通过；本轮没有重新编译宿主。 |
| 实际 VM 可执行文件 | 使用 B35 原冻结路径，SHA256 `a4f8a4155a95e3d0c9067f856bb09a165df22cc9e55fcf9356f01ab16b0d11f4`、CDHash `62026af109b33fdd468c2c2df2fcdb4211136bf0`。新默认 Bundle 内 VM 文件具有相同摘要。 |

新 worktree Bundle 路径的 VM `--help` 退出 -9，原冻结路径退出 0。本轮没有取得新的拒绝日志，未将该退出单独认定为已确认的 AMFI 原因。本机已有另一个 amfidont/debugserver 会话，本轮未附加、改变或终止它；运行可能依赖既有宿主安全环境。因此本次不证明新 Bundle 路径可独立启动，也不证明清除该会话后的宿主运行。见 `vm-help.json`、`frozen-vm-help.json`、`final-readback.json`。

候选与组合清单保留构建阶段的 `runtime_validated=false`；实际运行结论由独立 `acceptance.json` 和运行记录给出，不修改构建清单的原始含义。75 项 API/依赖输入摘要保存在 `default-artifact.json`，离线复核仍与当前源码一致。

## 真实研究副本与冷启动

仅修改已批准的 `vm-roothide-b33-20261010`。在停机、源监测暂停、源磁盘无句柄的条件下，通过原写盘事务克隆暂存磁盘，安装 API binary、其 plist 以及 launchd 字典新增项；字典从 685 项增加到 686 项，原项保持。没有执行新快照切换。安装前后 classic binary、classic plist、launchd 摘要及 `/b` 符号链接目标摘要一致；`/b` 摘要表示链接目标字符串，不代表所指 dylib 内容摘要。

原研究磁盘保存在 `/Users/kolar/github/vphone-cli/vm-roothide-b33-20261010/.cfw-history/20261011T014923Z-B38-oipbh50q/Disk.img`。`deployment.json` 中 `transaction_directory` 是发布前的暂存路径。两次未发布失败的暂存磁盘 `.cfw_disk.B38-unjetlgv` 和 `.cfw_disk.B38-i7ri6ze5` 保留用于复核，未保持挂载。第一次失败来自 hdiutil stdout/stderr 混合后的 XML 解析，第二次来自对 classic 布局检查不存在的现代 SystemHook 文件；均发生在记录的写盘差异为空时。最终改用独立 stdout 并核对实际 classic 对象。未用失败试验替代最终事务验证。

两次冷启动均由 System 安装载荷启动 API，API 缓存均不存在；classic 缓存 SHA256 两次均为 `03b0bd17289bd1e0820041ebda0a3ca70febede0f175456d5d992d36f18475d5`。Irisin 与 OpenSSH job 均自动加载，没有显式调用 helper 或 load/start 激活它们。Irisin 的 MachServices 和 sshd 的 inetd/Sockets 作业可以显示 PID 0；SSH 转发实际取得 `SSH-2.0-OpenSSH_9.2` banner，验证按需服务入口。没有进行 SSH 身份认证。classic `app_list` 往返同时通过。证据为 `automatic-bootstrap.json` 与 `second-cold-bootstrap.json`。

## 接口与重复调用

| 实验设置 | 结果 | 证据 |
| --- | --- | --- |
| 定位 | 合成坐标设置/读回、clear 通过；超范围和 NaN/Infinity 请求返回 400。原定位覆盖文件恢复至不存在状态。 | `runtime-matrix.json` |
| 序列化 | 非 UTF-8 字节精确 base64 往返，多语言 UTF-8 往返通过。非有限值的标准 JSON 输出由固定依赖实际源码离线测试覆盖；网络试验发送含 NaN/Infinity 的非法 JSON 常量并验证拒绝，两者分别记录。 | `regressions.txt`、`runtime-matrix.json` |
| 时区 | New York/Tokyo 设置、重复调用 changed=false、无效标识拒绝、automatic 切换通过；最终恢复 Asia/Hong_Kong、automatic=false。 | `runtime-matrix.json` |
| 旋转 | Safari 90°/270°/0° 返回 200，实际角度一致；180°返回 400，实际保持 0°。横屏 JPEG 为 2796×1290，竖屏为 1290×2796；90°、270°与0°已视觉核对。 | 四张 `safari-*.jpeg`、`runtime-matrix.json` |
| 并发与 worker | 40 次并发 SpringBoard service 查询通过；接口和截图试验中 worker PID/start_time、API instance 保持。 | `runtime-matrix.json` |
| 重复截图 | 额外连续 60 次，分 3 批各 20 次；worker FD 从 13 到 13。 | 同上、`fd_probe.c` |
| RootHide 服务 | 明确物理根路径的独立夹具：load、重复 load、start/status、signal TERM、restart、stop、remove/unload 通过，实际 PID 消失且最终 label unloaded。 | `roothide-service.json`、`signal_fixture.c` |
| 显式 API 更新 | 同摘要载荷上传、apply_update、proxy/worker 实际重启、监听后 pending→confirmed 通过；classic 缓存摘要不变且往返继续可用。 | `cache-update.json` |

截图前 footprint 为 5,439,968 字节，各批静置后为 5,407,200、19,907,040、5,423,584 字节，最终三次读回为 5,423,584、5,439,968、19,923,424 字节。相对基线最大增长 14,483,456 字节；观测未出现逐批持续累积的已知 JPEG 泄漏。burst 峰值为 63,455,712 字节。结果限定本次 60 次请求及后续短时读回，不证明任意负载或长期无泄漏。

实际更新后新 proxy/worker 执行独立 API 缓存，API SHA 不变、instance 改变；原缓存及 marker 基线均为空，本轮文件已清理。第二次冷启动重新从 System 安装载荷启动。classic 源码、宿主资源选择和 classic 更新代码自 B35 未变化；新 Icli 依赖没有进入 classic 构建或更新资源。VM 运行使用 `--no-vphoned-update`，没有重新执行不带该标志的旧 guest 完整自动更新流程，也没有主动更新源 VM。原有 T06/T07 连接/升级证据保留，新增实际独立缓存更新验证补足本次组合隔离。

## 失败记录与诊断限制

两次早期 FD 夹具试验以 guest wall clock 对比 host wall clock 判断新鲜度，因时钟差异失败；最终删除旧输出后启动夹具并读取新文件，不依赖跨时钟排序。失败记录与最终记录均保留。

初始 RootHide `/usr/bin/sleep` 夹具在 launchd TERM 和直接 TERM 返回后仍运行，launchd KILL 后进程消失。最小受控程序观测到继承的 `SIGTERM=SIG_IGN` 且未屏蔽；显式设置 SIG_DFL 后相同服务调用可结束进程。该差异支持夹具信号处置影响退出的解释，未支持“XPC 丢失信号”解释；没有直接测量原 sleep 内部最终处置。服务返回 accepted 仅证明请求被接收，最终回归另外断言实际进程退出。修正夹具后的首次快速 restart 还受 launchd 默认节流影响；最终采用明确 ThrottleInterval=1 与有界轮询。未改写生产服务逻辑或弱化实际退出断言。

运行矩阵恢复前台时 `apps.launch(com.apple.springboard)` 返回 app not found，随后用 `input.button(home)` 成功返回主屏幕；最终读回保存在 `first-run-final-readback.json`。非有限请求输入在公开 JSON 中用 `nonfinite_number` 对象编码，原始记录单独保存在 `runtime-matrix.original-json.txt.gz`。第二次冷启动证据脚本曾因循环变量覆盖而写到错误文件名；原输出保存在 `second-cold-output-name-trial.json`，修正输出参数后另行核对并保存最终记录。

受控应用180°无错误但不转动的原因沿用 B34 的实际因果证据：请求 mask4 到达 SpringBoard，但该场景的 `_isAllowedToHavePortraitUpsideDown` 为 0，将支持集合30清理为26；仅改变该场景条件后实际旋转，再恢复后回到原方向。本轮未修改持久方向策略。该结论限定受控样本，不能扩展到全部应用、设备或系统版本。

## 验证与恢复

执行入口均已保存：`build_guard.py guest`、`pack_default.py`、`deploy_api.py`、`boot.py`、`cold_verify.py`、`runtime_matrix.py`、`signal_probe.py`、`roothide_service.py`、`cache_update.py` 和 `restore-source.py`。重新运行写盘和 VM 步骤前须核对其固定对象、运行身份及维护条件；不能在源运行时直接重放。公开日志压缩归档，未包含 token、私有恢复日志、SSH 私钥或磁盘映像。全部公开证据已核对两个实际 token 均未出现，随后删除本轮两份 token 和串口 FIFO，记录在 `cleanup.json`。`freeze_evidence.py` 保存本次归档操作；凭据清理后不重放该归档脚本。

离线回归命令为 `python3 -B .../run_regressions.py`：106 项，无失败、错误或跳过。组件命令为 `make -C sources/VPhoneGuestComponents test-loader-links test-vcam-dataplane`：loader links 通过，VCam 124 检查、0 失败。候选、固定 checkout、组合和完整 Bundle 在结束时再次校验通过；Python AST、zsh 语法与 git diff whitespace 校验通过。`verify_acceptance.py` 独立复核已保存证据与当前输入摘要，通过。

两次 `system.shutdown(force=true)` 接收后 guest 正常停机，宿主退出 0；第一轮 972.0 秒、第二轮 290.6 秒。最低运行磁盘余量为 282,088,140,800 字节，约262.7 GiB，5 GiB 阈值未触发。监控按0.5秒采样；该结果不是实际填满磁盘后的停止测试。

源按原 argv 恢复，连续3次 classic guest 往返通过后向同一监测 PID92285 发送 SIGCONT，新快照为 healthy。最终再次核对 PID、启动时间、命令、健康快照、研究磁盘无句柄及无研究镜像挂载。见 `source-restoration.json`、`final-readback.json`、`first-exit.json`、`second-exit.json`。完整现代环境/相机迁移、新 Bundle 执行路径及其他应用/版本旋转均保留为验证范围之外；没有将这些内容写成已验证。
