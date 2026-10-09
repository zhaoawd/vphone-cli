# T46 B24 验收入口

生产源码和签名冻结产物保持。`lifecycle_harness.py` 的 `cli-case` 使用生产 CLI；输入为本地不完整下载 fixture。这一结果不代表真实 UI 或真实 VM 验收。

## 真实签名 UI 的 create 取消

1. 在父代理确认宿主恢复后，启动专属服务器：

   ```sh
   .venv/bin/python /private/tmp/vphone-b24-t46/lifecycle_harness.py serve --case ui-stop-http --seconds 1200
   ```

   服务器只监听 `127.0.0.1`。`server-ready.json` 给出两个源 URL。全部连接合计最多传输 4 MiB，不会提供完整 IPSW。父代理要求服务器至少保持 15 分钟，当前启动参数为 20 分钟。该时限只限制 fixture 存活时间，不更改产品时限。

2. 直接启动实际签名 app 的 `Contents/MacOS/vphone-launchpad`，传入以下环境。不得启动冻结 VM 的其它副本。

   ```text
   VPHONE_ROOT=/private/tmp/vphone-b24-t46/ui-stop-http/data
   VPHONE_LIBRARY_ROOT=/private/tmp/vphone-b24-t46/ui-stop-http/library
   VPHONE_PYTHON=/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/.venv/bin/python
   NO_PROXY=127.0.0.1,localhost
   no_proxy=127.0.0.1,localhost
   ```

   启动环境移除 `http_proxy`、`https_proxy`、`all_proxy` 及对应大写名称。使用实际签名 app，不替换 embedded CLI 或改写 manifest。保存 app SHA、embedded CLI SHA、启动输出及 PID。Launchpad 日志位置由生产代码固定为用户 `Library/Logs/vphone-cli-launchpad`；只使用唯一机器名称，禁止覆盖旧日志。

3. UI 打开 New Machine，名称用 `b24-t46-stop-<唯一后缀>`，变体 regular，磁盘 8 GB，prepare backend script。两个源字段填入 `server-ready.json` 的 URL。点击 Create。UI 字段与实际执行 argv 必须存证。

4. 等待 `http-events.json` 出现 request，且 Creation Log 出现活动下载输出。记录生产 `vm create` PID 和后代快照。若请求尚未到达，不计慢下载验收通过。不要继续到 patch/restore。

5. 在父代理控制下启动观察器，随后通过真实 UI 点击 Stop Creating…，再点击 Stop Creating：

   ```sh
   .venv/bin/python /private/tmp/vphone-b24-t46/lifecycle_harness.py observe \
     --case ui-stop-observation --pid <create-pid> --seconds 30 \
     --scope 'real UI' --log '<生产create日志绝对路径>'
   ```

6. 在原有 30 秒范围内记录退出和 UI Result。生产 `vm create-status <name> --library-root <专属库> --json` 应显示 `overall_status=interrupted`、`next_stage=prepare`、两个 live lock 均 false。检查点 prepare 保持 running，并记有 SIGINT；不显示 succeeded。记录停止前已观察后代 PID+command，在退出后逐项核实其消失，包括独立 PGID 的 worker。日志应有最终 `interrupted by SIGINT during stage prepare`，且不出现 patch、restore、CFW 或 VM 启动。

## 活动 create 后立即退出真实 UI

新建另一专属 server/library/cache case，重复上述生产路径。父代理在活动日志追加后立即通过真实 UI 发出 Quit；保存 Quit 确认对话框和点击 Quit 的时间。`applicationShouldTerminate` 会对 UI 自启 create 发送 SIGINT 后返回 terminateNow。观察器须在点击前已启动并同时观察 app PID、create PID、已知后代和原始 create 日志。app 消失后，日志是否继续追加与最终尾部、create exit、checkpoint、worker 消失分别记录。UI 退出不作为输出完成确认。若要验 Cancel 按钮，先在 Quit 对话框选 Cancel 并确认 app 与 create 仍活动，再执行最终 Quit。

## 真实 VM console 与吞吐

父代理统一启动已授权恢复 VM 副本，并由真实 Launchpad 展示其 Console。记录 10 秒区间的原始日志字节增量和行数增量、观察区间、app PID、VM PID、当前 app/VM hash。对相同区间保存 UI Console 的 AX 内容或截图及每次读取耗时。仅报告本地观测吞吐和 UI 操作耗时；未建立相同输入的旧版本基线时不报告性能收益。人工写入日志 fixture 的速率必须另列，不能作为真实 VM 吞吐。

## 普通 command writer 立即退出

普通 `VPhoneLaunchpadCommandLine.run` 的日志由异步 `VPhoneLogWriter` 写入，运行结束后调用 finish。app 级退出路径未等待普通 command writer。应在真实 UI 可触发的生产命令活动时测量最终文件内容和完成状态；仅根据此代码结构不能判定日志丢失。若无法获得持续活动的真实普通命令，该项保持未验证，不使用 detached VM 原始日志结果替代。

## 当前失败和边界

- `cli-cancel-01`：sandbox 拒绝 localhost bind，未启动 create。
- `cli-cancel-02`：harness 重复 dictionary key 失败；独立 ps 检查时无活动测试 create。其 aria2 继承代理产生 503，未到本地服务器。
- `cli-cancel-03`：保持 30 秒 readiness 时限，在 `ipsw_cache_entry.py check` 时取消；生产 CLI 130 退出，检查点 interrupted，不能证明 HTTP 下载取消。
- `cli-cancel-04`：进入受控 HTTP 后停止，初版 harness 报 passed；初版后代检查没有保留独立 PGID 后代身份，不能据其断言完整生命周期。已修正观察器，待宿主恢复后用新 case 重跑。旧证据保留。
- `cli-cancel-05`：严格已观察后代检查通过；服务器未正确响应 Range，aria2 出现范围错误，不作为正常慢下载证据。
- `cli-cancel-06`：修正服务器的 HTTP 206/Content-Range，实际传输 65536 字节后 SIGINT，0.043277 秒后生产 CLI 130 退出。已观察 fw_prepare 和 aria2 独立 PGID 后代均消失，锁均 false，检查点 interrupted，最终尾部存在。完整结果见 `strict-cli-summary.json`。未执行 UI 或 VM。

上述实验没有启动 VM、修改系统安全状态、完成固件下载或进入 patch/restore。独立 case 的稀疏 Disk.img 逻辑大小 8 GiB；使用文件 allocated_bytes 统计实际空间，不能用逻辑大小推断磁盘占用。
