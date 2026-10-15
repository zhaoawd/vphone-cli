# Task 8 Documents 标记验收工具 v2

本工具仅新增验收证据流程，使用固定第四版 CLI 的 `guest send`。未改旧 `guest-rollback-marker.py`、旧失败记录、F99 driver、amfid 清理 helper、V9 源码或签名工件；本子任务没有发送真实 guest 请求，没有启动、停止或查询真实 VM/进程，没有操作 AMFI。

旧 B-resumed 标记在 `/private/var/tmp/task8-kernel-rollback-682d8cbe-429b-4c4a-95fb-e6dfa945aa35` 创建并由原实例实际返回742字节；R_A 新实例读取报 ENOENT，原 `kernel-v9-rollback-a-marker-read.json` 保留。标记消失的原因未查明。不能将缺失归因于内核回退，也不能认定改用 Documents 或调用 sync 已解决旧标记消失问题。原始/候选镜像的只读调查由根任务执行。

v2 明确区分 `--boot-label`（已通过的 `<boot-label>-boot-watch.json`）与 `--label`（新输出证据前缀）。create 只生成唯一 `/private/var/mobile/Documents/task8-kernel-rollback-<canonical UUIDv4>`，不接受任意 guest 路径、不创建目录、不删除或覆盖文件。shell 使用 `set -C` 和经 shlex.quote 编码的固定格式 printf；输出证据与 intent 均独占创建。

创建前通过同实例 shell 检查 `/bin/sync`，否则检查 `/var/jb/usr/bin/sync`。两者均不可执行则拒绝，且不写标记。写入成功后必须另发 `exec <探测到的绝对sync路径>` 请求，并检查 CLI退出0、ok=true、shell code0、timed_out=false、truncated=false。然后同一实例 file_get，比较实际解码字节、SHA-256与size；前后 capabilities 均要求精确target、normal、guest_connected、shell/file_get能力。所有请求前及完成后核对当前 binding、receipt、current desired 与该 boot evidence 的原始摘要，并拒绝 pending。配置的 machineIdentifier摘要、配置摘要、同generation及固定VM目录形成本工具的sameVM比较数据；不对运行中的Disk.img计算摘要。

read 只接受 `--previous-create-label` 对应的合法 v2成功create证据，拒绝旧工具记录。它核对原boot证据、规范UUID/Documents路径、完整canonical内容、SHA/size、实际创建/发现sync/执行sync/file_get/前后capabilities的六条CLI请求与原始响应，要求此前sync成功。当前实例必须为相同VM身份且instance UUID不同、start time更晚。当前receipt可指向不同已提交目标；live desired单独核验，不要求目标plan等于live desired。read只发送capabilities/file_get，不写guest标记或运行sync。

根任务审查后可执行，例如：

```sh
PYTHONDONTWRITEBYTECODE=1 .venv/bin/python research/evidence/2026-10-13-task8/acceptance/guest-rollback-marker-v2.py create --boot-label kernel-v9-rollback-a --label kernel-v9-rollback-a-documents
```

下一次不同实例启动通过后，使用它自己的boot label与新证据label读取：

```sh
PYTHONDONTWRITEBYTECODE=1 .venv/bin/python research/evidence/2026-10-13-task8/acceptance/guest-rollback-marker-v2.py read --boot-label <新boot-label> --label <新read证据label> --previous-create-label kernel-v9-rollback-a-documents
```

输出为 `<label>-marker-v2-create.json` 或 `<label>-marker-v2-read.json`；create另存 `<label>-marker-v2-intent.json`。异常记录passed=false，退出1；已有输出文件拒绝覆盖且不发请求。部分创建或sync失败的文件和intent保留，不以相同UUID覆盖重试。sync返回0和当前实例字节读回只证明这些已观察结果，不能代替下一次启动后实际read，也不单独证明掉电持久性或全部guest文件系统保持。

纯测试命令：

```sh
PYTHONDONTWRITEBYTECODE=1 .venv/bin/python research/evidence/2026-10-13-task8/acceptance/guest-rollback-marker-v2-mock.py -v
```

11个测试函数通过，覆盖两个sync路径、sync缺失/code/timeout/truncation、禁止覆盖、实际字节/size/base64拒绝、实例/capabilities/currentdesired竞态、pending、伪造/旧/不完整previous记录、不同VM/同实例、独占证据输出以及固定CLI适配。guest请求均为pure mocks；Native CLI adapter的subprocess完全mock，只对临时普通证据文件进行真实读写。

另在自动删除的临时目录中构造controlled mutant：移除实际sync请求，改为自报成功。相同纯测试11项中6项失败，退出1，见 `guest-rollback-marker-v2-mutant-red.log`；原工具未修改。最终未变异工具11项通过，见 `guest-rollback-marker-v2-mock-final.log`。该RED证明测试能检测遗漏sync请求，不证明旧标记缺失的原因。工具/测试/日志摘要见 `guest-rollback-marker-v2-manifest.json`。真实v2创建、跨不同payload回退与新实例读取仍待根任务执行。
