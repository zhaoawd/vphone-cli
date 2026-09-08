# A2 SystemOS AEA 与缓存验证记录

日期：2026-09-08。对应[迭代清单 A2](../research/project_iteration_checklist_2026-09-08.md)。

## 实现结果

实现和验证已完成，本记录随 A2 独立提交。Regular、DEV、EXP 的 SystemOS 缓存路径统一调用 [cache_systemos.py](../scripts/cache_systemos.py)。JB 继续通过调用 Regular 继承此逻辑。

处理顺序：

1. 已有缓存通过镜像校验时直接复用，不重新复制或解密。EXP 已修改的有效镜像也保留原内容。
2. 缓存缺失或校验失败时，检查源文件前 4 字节。只有 `AEA1` 才调用 `ipsw fw aea --key` 和 `aea decrypt`。
3. 已解密输入通过 `cp` 写入目标目录下的独立临时目录，临时文件扩展名为 `.dmg`。
4. 对解密或复制的输出运行 `hdiutil imageinfo -plist`。要求识别到 APFS/HFS 文件系统、分区范围不超出声明的镜像容量，并且镜像未加密。
5. 校验成功后通过 `os.replace` 在同一文件系统中原子替换正式缓存。失败时清理本次临时目录，不发布新缓存，也不覆盖原缓存。

已有无效缓存遇到重建失败时保留原样；下次仍会重新校验并尝试重建。缓存为符号链接或目录时明确拒绝。正常失败及 SIGTERM 中断均验证了临时目录清理；SIGKILL 或掉电后的临时目录清理不在本次保证范围内。

实际修改入口：[Regular](../scripts/cfw_install.sh)、[DEV](../scripts/cfw_install_dev.sh)、[EXP](../scripts/cfw_install_exp.sh)。未调整 AppOS 缓存、挂载目录、补丁内容或触控代码。本次没有新增二进制补丁。

## 已确认的行为

| 对象 | 现象与证据 | 处理 |
| --- | --- | --- |
| 新增非 AEA 分支 | 本次为已解密输入增加复制路径 | 复制到临时文件并验证后才发布 |
| 原有缓存判断 | 只检查正式缓存文件是否存在 | 复用前校验镜像；已覆盖的无效缓存样本重建 |
| 原有 SystemOS 输出路径 | `aea` 直接写正式缓存 | 独立临时目录与原子替换 |
| `hdiutil imageinfo` | 本机工具会成功识别任意按扇区对齐的数据为 `CRawDiskImage` | 不只检查退出码，同时检查文件系统识别和分区范围 |
| 已解密 `.aea` 输入 | 相同 APFS 内容使用 `.dmg` 扩展名时识别成功，保留 `.aea` 时失败 | 先复制到临时 `.dmg` 再校验 |
| AEA 密钥输出 | 原有 Regular、DEV 路径会打印密钥 | 共享函数不打印密钥，也不输出包含密钥参数的异常命令 |

## 自动化回归

[test_systemos_cache.py](../tests/test_systemos_cache.py) 新增 9 个 unittest，包含多组输入和入口子用例：

- AEA 输入只解密一次，重复运行使用缓存。
- 已解密但保留 `.aea` 文件名的输入只复制一次。
- 输入缺失、空文件、截断文件、无效扇区数据、仅声明分区类型而未识别文件系统的输入被拒绝。
- 密钥查询失败、解密失败、复制失败、命令成功但输出无效时，不发布新缓存；再次运行可以成功。
- 已覆盖的无效缓存样本重建，EXP 修改过的有效缓存保留。
- 复制尚未结束时正式缓存不存在；SIGTERM 后不发布缓存并清理临时目录。
- 缓存符号链接被拒绝，链接目标保持不变。
- 执行原样复制的 Regular、DEV、JB、EXP 安装脚本，每个入口分别使用 AEA 和已解密输入，共 8 组入口验证。

入口测试使用隔离目录和命令替身。在到达 `hdiutil attach` 时返回失败，阻止后续真实挂载与补丁操作。该测试证明缓存逻辑已接入各入口，不证明完整 CFW 安装成功。

运行方式：

```sh
make test
# 仅运行 A2 回归：
.venv/bin/python3 -B -m unittest discover -s tests -p test_systemos_cache.py -v
```

## 原生 APFS 与 AEA 验证

[systemos_cache_native.py](../tests/systemos_cache_native.py) 为显式运行的 macOS 检查，不加入默认 unittest 发现流程。它需要能够访问 DiskImages 系统服务：

```sh
.venv/bin/python3 tests/systemos_cache_native.py
```

该脚本创建专用的 32 MiB APFS 镜像，提取 APFS 分区副本，保留 `.aea` 文件名进行缓存验证。随后使用系统 `aea encrypt` 生成 `AEA1` 输入，并由生产缓存函数调用真实 `aea decrypt` 解密。

已通过的检查：

- 已解密 `.aea` 输入可以缓存，输出 SHA-256 与源数据一致。
- 重复运行保持缓存修改时间不变。
- 当时使用的不完整缓存样本可以重新生成正确输出。
- 原生 AEA 解密输出 SHA-256 与原始 APFS 数据一致。
- 截断 APFS、无效扇区对齐数据、空文件和截断 AEA 被拒绝，未发布缓存。
- 源数据保持不变，临时目录清理完成。

只有 `ipsw` 密钥查询由本地测试密钥替代。此结果未验证 Apple 固件 FCS 密钥获取，也未验证实际 iPhone SystemOS 固件或完整 CFW 安装。测试环境同 [A1 基线](../research/test_baseline_2026-09-08.md)，没有使用既有 VM 磁盘。

## 最终验证与限制

| 命令 | 本次结果 |
| --- | --- |
| `make test` | 退出 0；Swift Testing 180、XCTest 20、Python 31，共 231 项通过 |
| 原生 APFS/AEA 检查脚本 | 退出 0，上述全部检查通过 |
| 四个安装脚本的 `zsh -n` | 退出 0 |
| `make build` | 退出 0 |
| `.app` 内主程序的 `codesign --verify --strict` | 退出 0 |
| `git diff --check` | 退出 0 |

本地日志：[完整测试](../research/artifacts/a2-2026-09-08/test.log)、[原生验证](../research/artifacts/a2-2026-09-08/native.log)、[构建](../research/artifacts/a2-2026-09-08/build.log)。这些日志位于 Git 已忽略的 `research/artifacts`。

镜像校验确认本机工具识别的文件系统和容量范围，不等同于完整文件系统一致性检查或每个文件的内容校验。缓存也尚未与源固件哈希绑定。跨进程排他保护、挂载隔离和流程恢复继续由 B1、B2/B4、D4 处理。

下一项建议执行 B1。A1 已提交为 `b7d0382`，A2 与本记录一并提交。

后续评审修正见[修复记录](review_fixes_2026-09-08.md)：无法识别的缓存现在保留并报错；真实已解密 SystemOS 已验证，Apple 密钥获取仍未验证。
