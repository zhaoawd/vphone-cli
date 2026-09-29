# P3 helper XPC 与管理员授权

参考固定上游 `2.0.8 / 9d218dedf58d4b19db5e51c8b584c1f14a96eee3` 的 helper protocol、Authorization、ListenerDelegate、Service 与 HelperClient。本批新增 `VPhoneHelperKit`、`vphone-helper` 和 CLI `helper` 命令，复用上一批 `VPhoneBundleStore`。

## 已接入的接口

| 命令 | 行为 |
| --- | --- |
| `helper status` | 校验客户端签名配置，查询 helper 协议版本 |
| `helper register` | 校验内嵌 helper 的签名及元数据，经管理员授权调用 SMJobBless；注册后核对实际版本、签名和完整二进制字节 |
| `helper install-bundle --version … --archive … --sha256 …` | 将已打开的归档描述符、版本、摘要和 AuthorizationExternalForm 送给 helper；安装前复核管理员权限，再进入共享安装存储 |
| `helper verify-bundle --version …` | 只读复核已安装 bundle、收据和 cdhash |

服务标识采用 `com.vphone.cli.helper`，避免用仅实现安装/验证的本地服务替换上游 `com.vphone.launchpad.helper`。Core Bundle 存储路径和收据字段仍与上游一致。后续本地 Launchpad 适配需使用本地 helper 标识；不能假设完整上游 helper 协议已经可用。

## 信任和执行边界

- Team ID 限定为 10 个大写 ASCII 字母/数字。helper 元数据中的允许客户端必须精确匹配同团队的 `com.vphone.cli` 和 `com.vphone.launchpad`；客户端必须固定同团队的 helper 标识。拒绝空团队、自由拼接 requirement、仅 identifier 的弱要求。
- 客户端先检查自身 bundle 的完整签名及团队，再创建 XPC 连接。连接两端均设置 code signing requirement。helper 启动前检查自身内嵌配置、签名和 root UID，全部通过后才写授权规则和开始监听。
- 授权规则要求 admin、认证用户、非共享凭据、最多 300 秒缓存，不使用 allow-root；每次安装复核规则和外部授权表单。被弱化的规则直接拒绝，请求路径不自动改写授权数据库。
- helper 全部安装/验证请求共用一个串行队列，并保留跨进程 store flock。客户端请求具有超时和一次完成保护；连接失效或超时不自动重发。安装可能已经开始时，错误要求先查询验证结果，不能把客户端退出记为安装已取消。
- 没有任意 command/shell/executable、AMFI、删除或 CFW XPC 操作。当前本地 CFW 依赖用户 Python 和外部工具，不满足 helper 只执行受控 root 存储代码的边界。原生 CFW 入口及 VM 描述符重新校验完成后再加入 CFW verb；既有显式 sudo 路径保持现状。
- 本批同步客户端供 CLI 或 UI 后台 worker 调用；UI 不应在主 actor 上等待这些阻塞操作。

## 候选构建

`make helper_candidate` 将 Info.plist 和 launchd.plist 嵌入 helper Mach-O。默认使用 ad hoc 签名，只产生未配置候选，注册不可用。构建本身不调用 SMJobBless、不启动 launchd 服务、不修改 AMFI。

提供本机已有签名身份后，可通过 `VPHONE_HELPER_SIGNING_TEAM` 和 `VPHONE_HELPER_SIGNING_IDENTITY` 构建独立 `.build/helper-candidate/vphone-cli.app`。脚本要求两项同时配置，实际验证 helper 签名团队；给副本加入内嵌 helper 和双方 requirements 后重新签名。既有候选 app 不覆盖，普通 `.build/vphone-cli.app` 不修改。

首次沙箱内 `security find-identity -v -p codesigning` 返回 `0 valid identities found`；宿主权限下复核发现 1 张有效 Apple Development 证书，公开证书 OU 为 Team ID `3AA3QL69MQ`，SHA-1 指纹为 `5620D69F097306848C7CCD69F0B796A3C588BF28`。不能用首次查询推导本机缺少证书。本批将使用已有证书构建候选，不导出私钥，不以 ad hoc 标识匹配替代同团队要求。真实注册与调用结果以下续记为准。

## 验证

专项 28 项通过，覆盖配置注入/弱 requirement 拒绝、授权规则弱化、错误表单、授权失败不得安装、描述符和收据传递、只读验证、超时及迟到回复。匿名 NSXPCListener 使用真实签名 requirement，测试确认无匹配签名身份的客户端不能调用 `helperVersion`。成功安装的服务顺序测试使用注入授权器；不能把它记为真实管理员认证成功。

后续验证：Python 391 项通过；显式串行 Swift Testing 738 项 / 105 suites 通过，XCTest 178 项完成（3 项跳过、0 失败），归档内存检查与客体 124 项检查通过。最终授权规则要求 `allow-root` 明确为 false，修改后 14 项 helper 专项复跑通过。

默认调度的全量回归仍有未解决的时间相关失败。第一轮 Python CFW 测试超过 30 秒；该组 15 项单独复跑通过，后一轮 Python 全套通过。后一轮 Swift 全量报告 6 个 issue，涉及 process runner、VM runtime、HTTP deadline、native restore worker 和 helper XPC；相关 48 项组合复跑通过。随后显式 `--no-parallel` 全套通过。没有放宽断言或生产超时；调度竞争与宿主负载仍是待验证假设，原因未查明。不能将串行通过写成默认 `make test` 全部通过。

`make build` 及最终 app 资源、签名、entitlements 校验通过。已有 Apple Development 身份构建的隔离候选、helper 配置与 app 完整签名检查通过。系统中未安装该 helper，候选 `helper status` 返回连接失效，未取得协议响应。

实际注册被自动审批拒绝，理由是用户尚未明确授权持久安装特权 helper、注册系统服务及修改授权边界。已向用户列出安装路径、服务与授权规则影响并请求授权。未执行注册，未创建生产 Core Bundle 存储，未修改 AMFI。真实管理员认证、生产 XPC 安装和验证仍待完成。

固定上游发布资产 `VPhone-2.0.8.zip` 已下载，大小 13,742,266 字节，SHA-256 `5edc2d6b68dccd05d5ee7652556c92b9e512555f7f4d89ae461d3c3106fb84a9` 与 GitHub 发布资产摘要一致。40 个 ZIP 成员声明解压量为 78,778,646 字节；研究目录解压后的 `VPhone.bundle` 通过 `codesign --verify --strict --deep`。该包是上游 ad hoc 签名资源 bundle，未安装、未执行，不代表本地整合产物。来源：[固定 2.0.8 发布](https://github.com/Lakr233/vphone-cli/releases/tag/2.0.8)。

日志保存于 `research/artifacts/upstream-remaining-2026-09-29/helper-*.log`；发布元数据保存为该目录的 `upstream-release-asset.json`。

## P1c 空间复核

本轮可用空间为 57,344,000,000 字节，约 53.41 GiB。旧导出包仍在 `research/artifacts/p1c-import-2026-09-26/resume/source.tzst`，大小 17,696,985,686 字节（约 16.48 GiB）。完整 SHA-256 复核为 `6fc5aa3ef5fc918303386e9d3fd015b7034b4b594a27f97d87dcd3cbd4086b72`，与原记录一致。

此前跳过的是实际导入及导入后启动；导出已经完成。根据 64 GiB 逻辑磁盘、受限卷失败和宿主最低余量，仍采用至少约 80 GiB 可用空间的验收预算，当前差约 26.59 GiB。没有重试真实导入，没有重新导出，没有修改 `vm-2607` 或删除原归档。证据为 `p1c-space-recheck.json`。空间结论属于该采样时刻，执行前必须复查目标卷。
