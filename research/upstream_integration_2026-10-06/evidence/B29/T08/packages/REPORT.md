# RootHide vphone 软件包静态核对

核对时间：2026-10-10（Asia/Shanghai）。只读检查与静态下载。没有操作VM、UI、宿主机配置，没有执行下载内容、maintainer脚本或构建。目录预算256MiB；每次写入前检查可用空间，网络下载时每0.2秒监测5GiB下限。本目录实际占用另见 SHA256SUMS.local 与静态摘要。

## 固定来源

- vphone 上游固定 target 2d21d21 的 Documents/README_zh.md 明确：Apps > Install Bootstrap…，layout=roothide；随后在 Irisin 的 OwnGoal Packages 中选择 owngoal-bootstrap-vphone，执行 Bootstrap Install。
- Irisin release v4.5.26，published_at=2026-10-08T17:37:53Z；tag映射 commit b6d8f9e005d5a0d08fafbb2971a7860e5d32e602；API报告 immutable=false，因此固定tag仍需同时固定SHA256。原始快照 irisin-release.json、irisin-tag.json、对应headers；源码包 irisin-v4.5.26.tar.gz；仅选取相关源码到irisin-source。
- https://github.com/Lakr233/Irisin/releases/download/v4.5.26/wiki.qaq.irisin_4.5.26_iphoneos-arm64e.deb：5,710,984 bytes，SHA256 0ced7ab0e678aca92c2f684d7a311c32f5fa4540166b2d14a7d8079bcc1b12bf。下载后同时与GitHub资产digest和SHA256SUMS核对。
- OwnGoal官方源 https://apt.owngoal.dev/；原始 owngoal-Release（Date Fri, 09 Oct 2026 15:22:58 +0000）和owngoal-Packages已保存。Packages大小178357，SHA256 713859841beb07fae4f660d321af517718b191cb2079557bd931eb07abba4046，与Release一致。
- owngoal-bootstrap-vphone 1.0.1 iphoneos-arm64e：1148 bytes，SHA256 41b4ef88f7b59a1d2dfc57794c94a7ddbf7139f93c559e477c5de18b1ebf1c4d。APT URL和固定源码提交 ef579aeebc7fe0ca1ba1165a1749665237c3a258 的raw.githubusercontent.com副本逐字节摘要一致。debian-binary/control.tar.xz/data.tar.xz；数据归档没有普通文件；没有maintainer脚本。
- 固定元包原始副本：https://raw.githubusercontent.com/owngoal-dev/owngoal-packages/ef579aeebc7fe0ca1ba1165a1749665237c3a258/debs/owngoal-bootstrap-vphone_1.0.1_iphoneos-arm64e.deb
- 补充官方依赖源：https://roothide.github.io/ 与 deb https://roothide.github.io/procursus iphoneos-arm64e/1900 main。Irisin Resources/Environments/default-list-iphoneos-arm64e.plist提供依据。
- procursus-Packages.xz：194296 bytes，SHA256 4a7725d7cc3ac0c890ca9f8fb02aec7107bc467a8b43b224c46e378c4a5bcc74，与procursus-Release一致。

## 签名证据与限制

OwnGoal官方README示例是 deb [trusted=yes] https://apt.owngoal.dev/ ./。InRelease与Release.gpg端点本次均HTTP404，响应与headers已保存；这两个文件是404 HTML，不是签名。本次不具备OwnGoal索引的GPG认证证据。89包ar成员均为debian-binary、control归档、data归档，没有deb级_gpg签名成员。SHA256证明下载文件与固定元数据一致；不能把HTTPS/资产digest/本地摘要描述为独立签名。未验证包中Mach-O签名或VM执行能力。

## 候选依赖与空间

closure-inventory.json含89包固定版本、URL、hash、Depends、Pre-Depends、Provides等原始字段。downloads.json含89包实测文件路径、大小、摘要与ok=true。此闭包由静态元数据求得，不是Irisin SAT resolver输出；假定vphoned已写入正确firmware虚拟包。其Alternative选择可能不同于VM解析结果，不能直接作为已验证的安装事务。

89包总下载93,982,570 bytes（约89.6MiB）。Installed-Size声明合计343,968KiB（335.9MiB）；两个元包无Installed-Size且payload为空。static-deb-inspection.json实测普通文件载荷331,497,295 bytes（316.1MiB）、11836个tar条目，17包带maintainer脚本。数据只在内存静态读取，没有将全部payload写入磁盘。客体操作会同时涉及缓存、prepared树、helper捕获、目标payload、备份和数据库；预留1.5GiB属于保守运行预算，不是实测峰值。主机可用空间必须始终>=5GiB。

## Bootstrap Install执行语义

Irisin PackageInstaller原生实施事务，不启动apt或dpkg。它创建标准dpkg数据库目录并锁定，比较整个status文件的SHA256，核对原始deb与prepared manifest/blob摘要，验证final package relationships。bootstrapInstall=true只允许新增包，无remove，非recovery；允许配置早前失败留下的未配置包。它先校验全部payload文件归属/Replaces，再seed所有payload，之后照常执行stages、preinst/postinst等maintainer脚本、数据库与trigger处理。它不跳过脚本失败；ignoreScriptFailures=false。安装dpkg/apt之前不需要它们已经存在，但依赖闭包必须提供脚本所需解释器和工具。

普通roothide/Bootstrap仓库是iOS15.0-17.0设备Bootstrap.tipa/TrollStore应用；它与本任务vphone的Irisin+OwnGoal元包安装链范围不同。不得以该设备应用代替vphone流程，也不得把普通宿主目录或只解压payload视为完整客户机环境。

## 无GUI helper入口

IrisinInstall/main.swift支持：在真实客户机root shell中，从已安装的真实路径执行 ${jbroot}/usr/libexec/irisin-install < job.json，stdout是每行InstallerEvent JSON，最后exit事件对应进程退出码。helper从自身路径推导安装根目录。没有发现resolve/download/prepare等CLI子命令；不接受仅.deb路径的事务。

daemon为Mach XPC wiki.qaq.irisin.service，v=3，op=2(run)，job是InstallerJob JSON data；回复fd/jobid。PeerAuthenticator限制为真实Irisin App路径、root-owned不可group/world写的可执行文件，以及wiki.qaq.irisin.client/platform-application/com.apple.private.security.no-sandbox entitlement。普通shell不能直接使用daemon XPC。root直接helper的实际客户机执行尚未验证。

InstallerJob JSON：{"transaction":{"_0":{"install":[{"identity":"<package>","path":"/absolute/package.deb","sha256":"<64 lowercase hex>","preparedPath":"/absolute/prepared-directory","preparedSHA256":"<manifest SHA256>"}],"remove":[],"dryRun":true,"stages":[{"unpack":{"_0":["<package>"]}},{"configure":{"_0":["<package>"]}}],"configureExisting":[],"autoInstalled":[],"statusDigest":"<actual entire status SHA256>","allowSystemRemoval":false,"ignoreScriptFailures":false,"recoveryMode":false,"bootstrapInstall":true}}}

全部非optional字段必须写出。最多512包，job<=256KiB。vphoned已写firmware记录，status通常不为空，不得使用空文件SHA256代替实测摘要。dryRun仍创建锁目录、捕获prepared树并写日志，但不seed、不执行maintainer脚本；它验证final state和摘要，不能证明真实每步Pre-Depends/脚本成功。

## PreparedPackage完整结构

prepared-manifest-template.json给出所有字段与四种entry类型。仅是带占位符的结构模板，不能直接执行。manifest.json含 formatVersion=1、control（原始control文本）、controlFiles（任意control归档普通文件名到PreparedFile）、entries（按data归档条目）。PreparedFile含name=blob-N、sha256、md5、size。PreparedEntry含path、kind(file/directory/symbolicLink/hardLink)、可选file、可选linkTarget、mode（0..0o7777）、uid/gid（UInt32）、modificationTime（Int64）。目录和链接不含file；file必含PreparedFile；链接必含非空linkTarget。optional可省略或null。每个blob必须真实普通文件，大小/两种摘要匹配；manifest.json本身的字节SHA256用于preparedSHA256。编码无需复现Swift whitespace，但必须按最终字节计算摘要。

路径规范来自PreparedPackage.relativePath与ArchiveStream+Preparation：拒绝absolute路径、NUL、换行LF、任何..分量；丢弃空分量和.分量，按UTF-8字节分割斜杠；data条目规范后非空且唯一，tar根条目跳过。hardLink target也规范为相对包根路径，helper最终解析为普通文件目标；symbolicLink target保留tar原始非空文字（包括相对/绝对目标），由安装文件系统另外校验安全性。control成员必须是普通文件且单层basename；禁止重复control/data成员或同归档重复规范路径；要求debian-binary严格为2.0\n，control/data均存在，control文本非空。tar特殊设备/FIFO类型拒绝。

所有者与权限：ArchiveStream优先将已知uname/gname通过客户机getpwnam/getgrnam映射，再使用tar数字；root=0、wheel=0、mobile=501必须按客户机实际数据库核对，未知名字保留合法UInt32数字。不能使用主机开发者UID覆盖tar root名字。保留tar permission bits与mtime；保存内容为flat blob，不把tar路径直接用作输出路径。native arm64e无需rootless适配；如果引入foreign架构包，必须另复现PackageAdapters，不能仅改Architecture字段。

## Pre-Depends图与分阶段策略

dependency-graphs.json保留89个节点，preDepends、depends、原始关系与selected witnesses。含Pre-Depends的只有：
- apt -> dpkg >=1.14.25-8, system-cmds >=854.40.2-2
- dpkg -> tar >=1.23, libintl8 >=0.20
- bash -> dash >=0.5.11.3-1, libreadline8 >=8.2, profile.d >=0-5, debianutils >=4.11.2
- zsh -> debianutils >=4.11.2
- dash -> debianutils >=4.11.2
- profile.d -> system-cmds >=805.220.1

当前候选关系的非单节点SCC是libncursesw6/ncurses-term与libpam-modules/libpam2；当前openssh三包中未识别闭环。上游文档仍明确要求一次Bootstrap Install；不得把文档所述openssh循环直接当作当前索引的已确认图结构。

TransactionPlanner.swift模拟present/configured集合：先安全移除；按Depends+Pre-Depends图的SCC依赖优先顺序遍历待unpack；只有Pre-Depends已configured且无Conflicts时才unpack一个包，处理Breaks产生的deconfigure。随后对已present未configured集合建图：每个OR关系优先已有configured witness，否则选第一个pending witness。对SCC，在configured union component能满足所有Depends/Pre-Depends且无Breaks时发出一个configure(component.sorted()) stage。无进展先取消一次依赖等待优先限制（ordered=false），仍无进展则noInstallOrder，绝不放松Pre-Depends。SCC采用迭代Kosaraju；组件内按pool index排序。Pool顺序和OR witness由resolver定义，按包名字自排并不保证逐字节复现官方stages。

PackageTransaction.unpack仍要求Pre-Depends的数据库witness是installed/triggers-pending，或有Config-Version的unpacked/half-configured/triggers-awaited。seed只写文件，不创建已配置记录，因此简单全部unpack再全部configure可能失败。helper的configure按阶段内包序运行脚本；源码不在configure处重新检查Depends，final-state预检与planner负责此约束。应复现TransactionPlanner并对固定候选集校验version/Provides/Conflicts/Breaks，再真实helper dryRun；dryRun通过仍不等于真实阶段/脚本已通过。

## 可执行操作顺序（由主代理在隔离VM实施）

1. 从本目录读取downloads.json与SHA256SUMS.local，重新校验输入；保持VM磁盘和主机余量约束。
2. 使用vphone已有Install Bootstrap from File能力安装已固定Irisin arm64e包，layout=roothide；vphoned原生安装不执行Irisin maintainer脚本，写firmware虚拟包并加载daemon。
3. 官方受支持路径：在Irisin选择OwnGoal元包、使用Bootstrap Install一次安装；记录最终解析队列与版本，固定输入摘要。
4. 无GUI替代：以客户机真实status和固定候选集复现resolver/planner，主机Python静态生成标准prepared blobs+manifest，传入客户机真实绝对路径；先真实helper dryRun，检查最后exit=0及记录；再在隔离VM把同一job的dryRun改false并按当时status重新核对。此替代路径目前只有源码证据，尚未完成VM验收，不应报告已安装。
5. 验收需客户机确认apt/dpkg可执行、dpkg状态全部configured、关键shell/SSH命令、App注册与启动；宿主静态解包或目录模拟不构成完整环境。

## 准备脚本（仅写入，未执行）

prepare.py 是主机Python静态准备脚本；本代理仅用ast.parse检查语法，没有执行该脚本、解包全部载荷或创建VM。它核对89包digest/size，要求真实guest status、/etc/passwd与/etc/group快照，拒绝existing output、foreign架构、已有待安装记录、未配置initial status。根据固定89候选集验证Depends/Pre-Depends/Provides与版本、Conflicts/Breaks，并移植官方TransactionPlanner的fresh-install状态机与迭代Kosaraju。它没有移植libsolv SAT选包；候选集如不满足final relationships或无安装顺序会拒绝。关系语法遇到不支持的扩展会拒绝。

输出在单独的新目录（建议/private/tmp/vphone-b29-prepared），不计入本下载目录256MiB预算；仍强制保留5GiB可用空间并逐blob分块检查。它生成prepared blobs/manifest、stages.json、job.dry-run.json与transfer-manifest.json；不上传、不调用helper、不生成自动执行安装动作。需要运行环境tarfile支持zstd，本会话用于静态检查的python3已支持全部包压缩格式。

调用：
```
python3 /private/tmp/vphone-b29-packages/prepare.py --status-file /path/to/guest-status --guest-passwd /path/to/guest-passwd --guest-group /path/to/guest-group --output /private/tmp/vphone-b29-prepared --guest-base /var/root/vphone-b29
```

身份快照很重要：当前89包中数据owner共有(root,wheel,0,0)10715项、(root,root,0,0)1119项、(admin,空,501,501)2项。脚本按客户机名字解析表覆盖数字，否则保留tar数字；不能用宿主机账户表替代。真实helper dryRun尚未执行；dryRun预检不验证实际脚本与每步Pre-Depends运行结果。
