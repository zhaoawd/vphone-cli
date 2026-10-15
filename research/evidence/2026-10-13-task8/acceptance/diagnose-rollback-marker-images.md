# Task8 离线标记诊断工具

工具为 `diagnose-rollback-marker-images.py`。本轮只完成源码、AST 检查和普通文件/模拟测试，未运行工具入口，未调用实际 VM、客户机、进程检查、hdiutil 或挂载。旧 tmp 标记在 R_A 客户机读回 ENOENT 的原因未查明。

root 需在正式停止 task8-copy VM、完成清理后单独运行。工具以非阻塞排他 flock 持有 task8-copy 目录，并要求没有对应 vphone-vm 进程、没有 `.firmware-transaction` / `.firmware-desired-pending.json`、没有 Task8 根目录内镜像附件。工具不读取源 VM。输出使用 `O_EXCL` 创建；失败后必须使用新 label，旧证据不会覆盖。

默认检查固定 schema4 R_A 事务 `58597f0a-e94c-4f69-86af-b0fdfa9fd3f3` 的归档。工具核对 E 冻结 committed 四 JSON 与实际归档逐字节相同，核对 journal/proof/receipt/report 摘要链、正式实际 readback、source-before 和 Disk 身份。它依次检查 `kernel-disk-original.img` 和 `kernel-disk-candidate.img`，完整 SHA256 必须分别等于 journal 的 `e8763d11…` 与 `fd8c34e1…`，大小均为 68719476736 字节。

每个镜像使用 `hdiutil attach -readonly -nomount -nobrowse`。工具要求唯一 GUID backing device、唯一且精确匹配 backing device 的 `PhysicalStores=[diskNs1]` APFS container，以及唯一名称为 `Data` 的卷。工具仅以 `mount_apfs -o rdonly` 挂载所选卷，记录实际 Roles、UUID、物理存储、挂载目录身份及前后 `WritableVolume=false`。工具只检查 `tmp/task8-kernel-rollback-682d8cbe-429b-4c4a-95fb-e6dfa945aa35`，对照 B-resumed 已通过 create/intent 与实际 file_get 的 742 字节和完整 SHA256 `2f30a9af…`。

归档内缺失标记记录 `exists=false`，允许诊断完成。存在的文件必须为非符号链接、单硬链接的普通文件，完整字节必须等于 intent；不符会保留实际字节和摘要并判失败。路径逐级使用 `openat` / `O_NOFOLLOW`。PermissionError、卷不可读、加密或锁定、物理存储关联不符和清理失败均判失败；工具不提供解密、强制 detach 或其他绕过。

每个镜像在检查前及 detach 后再次计算完整 SHA256，并比较 device/inode/size/mtime/ctime/mode/nlink。所有检查路径都进入 finally 清理。只有本工具已经尝试 attach 且可确认精确 image/backing device 的附件可以 detach；已有附件不会自动 detach。结束时必须没有 Task8 附件和两种 pending。detach 未成功时，不删除挂载目录内路径。

可选 `--marker-evidence-path` 仅接受 E 内合法 `*-marker-v2-create.json`。工具独立核对 `task8.guest-marker.v2`、canonical v4 UUID、固定 `/private/var/mobile/Documents/task8-kernel-rollback-UUID`、实际 create/sync/file_get 请求和响应、source boot 与当前 metadata。该可选检查只读当前 `Disk.img` 的唯一 `UserData` 卷，检查相对 `Documents/task8-kernel-rollback-UUID`。当前标记必须存在且完整字节相同，才能证明该停机时点确有标记落盘。当前 Disk 的前后完整摘要必须相同，身份必须保持；工具不要求启动后的当前 Disk 全盘摘要等于旧 R_A receipt。

仅诊断归档的运行示例（须先由 root 确认正式停机）：

```sh
sudo -n /Users/qcz3840/github/vphone-cli/.venv/bin/python3 -B \
  /Users/qcz3840/github/vphone-cli/research/evidence/2026-10-13-task8/acceptance/diagnose-rollback-marker-images.py \
  --label kernel-v9-rollback-a-marker-images-01
```

如需同时验证当前 Documents 标记落盘，在新的 label 下追加实际已通过的 v2 create 文件绝对路径：

```text
--marker-evidence-path /Users/qcz3840/github/vphone-cli/research/evidence/2026-10-13-task8/acceptance/<actual-label>-marker-v2-create.json
```

输出为 `<label>-marker-images-diagnosis.json`。退出 0 / `passed=true` 表示该次诊断检查与清理完成；默认归档标记仍可能是 `exists=false`。此结果不解释旧标记缺失的原因，也不替代不同 payload 发布、启动或标记跨回退保持的最终验收。

普通文件/模拟测试覆盖真实旧标记证据、v2 sync 与 file_get 字节核对、输出独占、符号链接/硬链接拒绝、错误 PhysicalStore、缺失与内容不符、部分 attach 失败、预存附件、加密/可写拒绝、detach 失败和完整摘要变化。测试中禁用真实 `subprocess.run`；模拟 mount 只创建普通临时目录和文件。最终测试日志及源码摘要保存在同名 manifest。
