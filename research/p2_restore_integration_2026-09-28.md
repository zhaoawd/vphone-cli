# P2 第四批：原生 Restore 库与离线检查

日期：2026-09-28。上游固定为 `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3`。本批迁入原生恢复库并接入 SwiftPM，提供离线检查入口。实际恢复继续使用原有 Python 后端及 DFU 会话归属检查。本批代码、测试与记录按用户要求纳入本次 Restore 整合提交。

## 接入范围

| 对象 | 结果 |
| --- | --- |
| MobileRecoveryCore | 迁入上游 libirecovery、IOKit 后端和 PCC 设备表；固定上游文件内容，不能仅按 config.h 的 1.3.1 字符串认定为官方同版本源码 |
| MobileRestoreCore | 迁入上游 idevicerestore、Bridge 与 ZIP stub，按 `IDEVICERESTORE_NOMAIN` 构建；输入为解包后的恢复目录 |
| VPhoneRestore | ECID/UDID 解析、目录选择、probe、票据、选项映射、事件与错误映射、同步恢复服务 |
| `restore-inspect DIRECTORY` | 检查唯一真实 `iPhone*_Restore` 子目录，可显式指定 `--ticket`、`--ecid`、`--udid`、`--json`；不访问 USB/TSS，不写 VM 文件 |
| 现有 `restore` | 命令解析、Python 后端和 DFU owner 检查保留；未接入原生执行服务 |

例如：

```sh
vphone-cli restore-inspect /path/to/vm --ticket /path/to/ticket.shsh --ecid 0x123 --json
```

ECID 参数只进行十六进制解析，UDID 只进行标准化；两者不证明设备存在或与票据匹配。票据检查只证明 plist 字典结构，不验证 Apple 签名、TSS 响应完整性、设备关联或固件兼容性。目录存在不代表固件完整或可恢复。

## 本地适配

- 目录选择拒绝符号链接。票据文件通过 `O_NOFOLLOW` 打开并用 `fstat` 确认普通文件，拒绝 FIFO 等特殊文件。
- Swift 和 C 票据路径均限制编码及解码数据为 32 MiB。gzip 必须完整结束且没有尾随数据；拒绝截断流、拼接流和超限数据。Swift 解压超限与格式错误均返回解压错误。
- SHSH 缓存目录使用 `0700`。生成票据必须唯一匹配请求 ECID；ECID 未指定时仍要求唯一有效文件名。不存在匹配时不再回退到首个文件。
- probe 拒绝未知 USB mode，并核对显式请求的 ECID。超时在两次 libirecovery 调用之间检查；不承诺中断正在阻塞的 USB 调用。
- C 返回码映射可独立测试。调用 C runner 的测试只传入会在设备访问前被拒绝的目录或票据。

原生服务保留上游同步调用及进程级 stdout 重定向行为；没有完成取消、DFU owner 或 VM 生命周期接线。这些是 P3 的前置工作。ZIP stub、实体设备恢复及不同固件兼容性均未经本批验证。

## 依赖与来源

AppleMobileDeviceLibrary 固定 `553a0bf1b55812b1a08c727b1a3084e88871343b`，openssl-spm 固定 `9f3b525d960fe71e534482310e96cd9c4f2faa17`。6 个 XCFramework ZIP 的地址和 SHA-256 取自固定 Package.swift，见 [来源清单](p2_restore_sources_2026-09-28.json)。SwiftPM 验证下载校验和。

AppleMobileDeviceLibrary 构建脚本未固定各 libimobiledevice 组件的源码提交，因此本记录仅确认 package revision、二进制校验和和随附头文件，不声称已确认每个二进制对应的精确组件源码。后续发布审查仍需补足这一来源信息。

保留两个 C 模块的 COPYING 及逐文件声明。`scripts/licenses/` 增加 wrapper MIT、LGPL-2.1、LGPL-3.0、其引用的 GPL-3.0、OpenSSL Apache-2.0 正文和二进制头文件声明；bundle 检查要求这些资源存在。先前批次来源清单仍保留历史快照。

## 验证

| 检查 | 结果与范围 |
| --- | --- |
| 上游 Restore 测试 | 67 项、6 个 suite 通过 |
| 完整 Python | `make test` 中 369 项通过 |
| 完整 Swift | 修正测试路径比较后，`make test_swift` 退出 0；Swift Testing 655 项、88 suites 通过；XCTest 145 项，3 项跳过，0 失败 |
| 新增覆盖 | 相较上一批增加 76 项，覆盖参数/事件/选项、C 失败路径、票据唯一选择、文件类型和大小、gzip 边界、模式选择、错误映射及 CLI 注册 |
| 归档传输内存回归 | 两条 1 GiB 路径通过；file/producer 峰值 RSS 为 8,716,288 / 8,896,512 字节 |
| CLI 临时夹具 | 7 次调用符合预期：普通/gzip 字典、截断 gzip、非法 ECID、票据符号链接、多恢复目录及原恢复命令 help；读取前后票据 SHA-256 不变 |
| 签名构建 | `make build` 退出 0；Release 编译、宿主/guest 签名、bundle 资源与 entitlements 检查通过 |
| 来源与动态依赖 | 69 个上游文件及本地接线文件 SHA-256 核对通过；debug/release 无 Homebrew 或新增库的外部动态依赖 |

首轮新增测试因 Foundation 目录 URL 尾部斜杠和 macOS `/var` → `/private/var` 解析差异失败。目录 URL 类型统一后，仍有一项路径比较失败；最终改为比较解析后的路径，完整 Swift 重跑通过。该修正只涉及测试夹具断言。未重跑 Python，因为最后修正未改变 Python 或生产代码。

签名 app 的实际 VM 执行准入未重新验证，CLI 验收使用 debug 可执行文件。

日志及临时夹具 CLI 输出位于 `research/artifacts/p2-restore-2026-09-28/`（Git 忽略）。本批未删除、导入或启动真实 VM，未执行 USB 探测、TSS 请求、恢复或真实固件比较。P1c 真实导入及导入后启动继续按用户要求跳过；P2 保持部分完成，daemon/guest、新 bundle 布局及原生固件准备仍待迁入。
