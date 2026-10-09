from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess

repo = Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
research = repo / 'research/upstream_integration_2026-10-06'
scratch = Path('/private/tmp/vphone-b26')
archive = scratch / 'archive'
head = (scratch / 'source-head.txt').read_text().strip()
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip() == head

def read(path):
    return json.loads(Path(path).read_text())

validation = {name: read(scratch / (name + '-result.json'))
              for name in ['swift-standard', 'signed-build', 'installed-snapshot']}
assert all(r['exit'] == 0 for r in validation.values())
swift_log = (scratch / 'swift-standard.log').read_text()
assert 'Test run with 1294 tests in 205 suites passed' in swift_log
assert 'Test run with 9 tests in 8 suites passed' in swift_log
assert 'Executed 254 tests, with 3 tests skipped and 0 failures' in swift_log
rom_review = read('/private/tmp/vphone-b26-rom-review.json')
helper_review = read('/private/tmp/vphone-b26-helper-review.json')
assert not rom_review['findings']
assert not helper_review['findings']
rom_summary = read('/private/tmp/vphone-b26-t40-rom/summary.json')
for row in rom_summary['source_files']:
    assert hashlib.sha256((repo / row['path']).read_bytes()).hexdigest() == row['sha256']

shutil.copytree('/private/tmp/vphone-b26-t40-rom', archive / 'T40-ROM', dirs_exist_ok=True)
shutil.copytree('/private/tmp/vphone-b26-t46-helper/evidence', archive / 'T46-helper', dirs_exist_ok=True)
for name in ['swift-standard.log', 'swift-standard-result.json', 'signed-build.log',
             'signed-build-result.json', 'installed-snapshot.log', 'installed-snapshot-result.json',
             'installed-snapshot.json', 'installed-rom-readback.json', 'current-vm-help.json',
             'current-vm-amfi.ndjson', 'current-vm-amfi.stderr', 'current-vm-amfi-result.json',
             'final-readback-before-authorization.json', 'stage-evidence.py', 'finalize-docs.py']:
    shutil.copy2(scratch / name, archive / name)
for source, target in [('/private/tmp/vphone-b26-rom-review.json', 'rom-review.json'),
                       ('/private/tmp/vphone-b26-helper-review.json', 'helper-review.json')]:
    shutil.copy2(source, archive / target)
(archive / 'runtime-prepared').mkdir(exist_ok=True)
for name in ['artifact.json', 'scope.json', 'config-check.json', 'scoped.py']:
    shutil.copy2(Path('/private/tmp/vphone-b26-runtime') / name, archive / 'runtime-prepared' / name)
fixture = Path('/private/tmp/vphone-b25-t46/prepare-ui-fixture.py')
shutil.copy2(fixture, archive / 'T46-UI' / fixture.name)

results = {
    'T08': {
        'status': 'fixed_overlay_memory_rotation_verified_actual_RootHide_service_pending',
        'result': 'B26按用户指定只读检查vm-new。System初始化脚本与Preboot的jb-vphone/procursus及两个安装标记提供既有rootless布局证据；Data/User加密锁定，不能排除后来另装RootHide，实际RootHide前提仍未确认。只读挂载均清理，8个文件元数据及7个小文件摘要保持；没有全量Disk.img摘要或客户机运行验收。',
        'remaining': ['实际RootHide客户机状态及服务验收；vm-new当前只有rootless布局证据，需活客户机核对或已知RootHide样本',
                      'services.start状态144及部分旋转未生效，原因未查明']},
    'T24': {
        'status': 'host_native_dependency_closure_verified_TCC_and_historical_helper_runtime_pending',
        'result': 'B26精确时间窗/路径的AMFI日志确认B25最终VM的ad hoc与restricted entitlements组合被-424拒绝；新b4e80c57冻结VM subprocess返回-9并有同类精确日志，尚未执行临时AMFI。历史v1实物仍未配置、未注册；有正常签名历史重建方案但未实施，不替代历史实物验收。',
        'remaining': ['完整TCC负责应用链实际验收，包括直接CLI与Launchpad→launcher→可信store路线；当前VM被AMFI拒绝，新工件临时范围待明确回复',
                      '历史v1 helper实物缺配置及签名团队；实际历史服务与最终客户端XPC拒绝矩阵未完成',
                      'Python framework、包、PATH工具和现场编译不属于宿主Mach-O封装闭包']},
    'T40': {
        'status': 'attempt_resources_and_ROM_snapshot_verified_external_toolchain_and_origin_matrix_pending',
        'result': 'B26两份Virtualization ROM纳入每attempt副本、预算、manifest、fingerprint和resume身份；生产new及prepare refresh共用副本，普通vm new保持原逻辑。29 issues行为RED后定向27项/2套件通过，标准Swift及签名构建/Bundle检查通过。最终安装副本238条目、161819103字节；两ROM共503624字节与系统源摘要匹配，签名有效；显式已有项目Python依赖锁探针通过。另生产53580180 CLI的41条只读命令、10组拒绝及6组0GiB传输通过，opaque历史receipt仅验证字节保全。',
        'remaining': ['Python interpreter/framework/包、PATH工具、宿主SDK/JB现场编译、既有cfw_input及可变缓存仍未形成不可变闭包',
                      '新机可信store binding/receipt发布及带可信既有binding/receipt的实际VM传输验收',
                      'kernel-only及环境升级/回退、混合版本四层来源矩阵；依赖T12/T17/T32/T34生产能力',
                      '完整64GiB VM归档往返空间仍不足；vm-new当前分配约21.02GiB，尚未执行完整往返；同卷APFS副本不证明物理独立备份']},
    'T46': {
        'status': 'ordinary_UI_quit_escaped_writer_and_cross_process_transport_faults_verified_full_runtime_pending',
        'result': 'B26解锁后完成53580180最终签名Launchpad隔离副本两组实际UI退出：普通writer立即退出；setsid后代持管道时取消退出，释放后退出。每组10002行/138939字节精确匹配，包含ANSI/CRLF和无换行panic尾部；应用/writer均退出。另正常签名的两进程临时XPCService直接复用生产service/output/receiver/writer，通过正常ACK、默认30秒无ACK、连接失效及真实只读FD的EBADF写失败。未覆盖固定privileged Mach入口、生产Client.request或真实Store；临时harness签名/actor隔离失败保留，修复仅在harness。',
        'remaining': ['完整panic/取消/轮换、UI响应及实际VM吞吐矩阵',
                      '系统特权helper与生产客户端的异步ACK缺失/30秒超时/XPC断线/写入失败完整组合；transport断线行仅证明客户端观察到失效，未直接观察服务器worker退出']}}
tasks = read(research / 'tasks.json')
assert 'B26_execution_state' not in tasks, 'B26 documentation must be appended only once'
for task in tasks['tasks']:
    if task['id'] not in results:
        continue
    row = results[task['id']]
    task['status'] = row['status']
    task['current_result'] += ' ' + row['result']
    task['remaining_work'] = row['remaining']
    task['B26_implementation_head'] = head
    task.setdefault('verification_evidence', []).extend([
        'evidence/B26-summary.json', 'evidence/B26-source-review.json', 'evidence/B26-evidence-manifest.json'])
    if task['id'] == 'T40':
        task.setdefault('implementation_commits', []).append(head)
        task['local_mapping']['batch_source_manifest'] = 'evidence/B26-source-review.json'
tasks['latest_implementation_head'] = head
tasks['latest_validation_limitation'] = 'B26实际UI退出、ROM快照、标准Swift及签名Bundle检查通过；两进程transport故障矩阵边界见证据。RootHide/TCC/四层升级回退/实际VM吞吐仍未验；新VM AMFI精确范围待回复，未执行。'
tasks['B26_execution_state'] = {'implementation_head': head, 'newly_accepted': [], 'accepted_total': 8,
                              'required_remaining': 38, 'optional_deferred': 1,
                              'selected_remaining': ['T08', 'T24', 'T40', 'T46'],
                              'AMFI_scope_status': 'prepared_pending_explicit_reply'}
(research / 'tasks.json').write_text(json.dumps(tasks, ensure_ascii=False, indent=2) + '\n')
ledger = read(research / 'capability_ledger.json')
for capability in ledger:
    if capability['id'] not in results:
        continue
    row = results[capability['id']]
    capability['accepted'] = False
    capability['acceptance_status'] = row['status']
    capability['current_result'] = next(t['current_result'] for t in tasks['tasks'] if t['id'] == capability['id'])
    capability['remaining_work'] = row['remaining']
    capability['B26_implementation_head'] = head
    capability.setdefault('evidence', []).extend([
        'evidence/B26-summary.json', 'evidence/B26-source-review.json', 'evidence/B26-evidence-manifest.json'])
assert len(ledger) == 47 and sum(c.get('accepted', False) for c in ledger) == 8
(research / 'capability_ledger.json').write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n')

target = research / 'evidence/B26'
assert not target.exists()
shutil.copytree(archive, target)
manifest = [{'path': str(f.relative_to(target)), 'bytes': f.stat().st_size,
             'sha256': hashlib.sha256(f.read_bytes()).hexdigest()}
            for f in sorted(target.rglob('*')) if f.is_file()]
summary = {'batch': 'B26', 'date': '2026-10-09', 'base_head': '6e88b101984eef28cb162aa02fd54ac4cbd5de8e',
           'implementation_head': head, 'source_commits': [head], 'selected_tasks': list(results),
           'newly_accepted': [], 'all_tasks': {'accepted': 8, 'required_remaining': 38, 'optional': 1},
           'results': results, 'validation': validation,
           'UI_source_build_head': '53580180f09819ec539ba656c15fab7a23fdc1c3',
           'ROM_source_build_head': head, 'AMFI_changed': False, 'TCC_changed': False, 'VM_booted': False,
           'runtime_scope': 'B26/runtime-prepared/scope.json', 'AMFI_scope_status': 'prepared_pending_explicit_reply',
           'evidence_files': len(manifest), 'evidence_bytes': sum(f['bytes'] for f in manifest),
           'helper_transport_review': 'B26/helper-review.json', 'ROM_review': 'B26/rom-review.json'}
evidence = research / 'evidence'
(evidence / 'B26-summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
(evidence / 'B26-evidence-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
(evidence / 'B26-source-review.json').write_text(json.dumps({
    'base_head': summary['base_head'], 'implementation_head': head, 'source_commits': [head],
    'files': rom_summary['source_files'], 'review': 'B26/rom-review.json', 'validation': validation,
    'scope': '仅T40两ROM冻结源码增量；T08/T24为只读诊断，T46为既有生产代码实际UI/transport验证。'},
    ensure_ascii=False, indent=2) + '\n')
readme = research / 'README.md'
text = readme.read_text().replace('当前验收结果见末尾 B25 记录', '当前验收结果见末尾 B26 记录')
text += '''\n\n## B26 结果（2026-10-09）

继续T08/T24/T40/T46，未新增整项验收。47项保持8项已验收、38项必选未完成、1项可选延期。

| 任务 | 本轮结果 | 未完成范围 |
| --- | --- | --- |
| T08 | 用户指定vm-new已只读检查；System脚本和Preboot标记提供rootless布局证据 | Data/User加密锁定，不能排除后来另装RootHide；实际服务、状态144及部分旋转仍待验 |
| T24 | B25与当前冻结VM均取得精确AMFI -424拒绝证据；当前subprocess返回-9 | 完整TCC责任链、历史v1实际XPC矩阵；新AMFI范围已准备并询问，尚未执行 |
| T40 | 两ROM纳入attempt快照与摘要，新建/prepare refresh共用副本；标准Swift、签名构建和安装布局smoke通过 | Python/SDK/JB/既有CFW输入闭包、可信binding/receipt和四层升级回退矩阵、完整64GiB往返 |
| T46 | 解锁后普通/escaped两组实际UI退出通过；两进程生产输出链正常ACK/30秒无ACK/断线/真实写失败通过 | 系统特权Mach服务与生产Client组合、完整UI/实际VM吞吐矩阵 |

T40源码提交为`b4e80c57`。行为RED为27项/2套件、29 issues，定向GREEN为27项/2套件（实际签名smoke当时跳过）。标准入口XCTest254项/3skip，Swift Testing常规1294项/205套件、计时9项/8套件通过；独立审查无发现。签名重建、Bundle与Launchpad校验通过。之后显式运行最终安装副本smoke：238条目、161819103字节，两ROM共503624字节与系统源摘要一致，Bundle签名有效，已有项目Python锁检查通过。原VM与副本VM的--help均被终止，smoke通过只证明副本结果一致，不证明VM可运行。

T46实际UI使用53580180最终签名Launchpad的隔离副本及受控签名CLI，保留生产AppDelegate、CommandLine、reader/writer链。两组各10002行/138939字节，SHA256为`f972c4a3f4ffda6f317183c1cb66bc06522e5f6f454d6bf19c545c8ae69eedad`。普通writer活动时退出；setsid后代持管道时取消退出，释放后退出。B25锁屏失败记录保留，本轮补齐最终退出操作。

临时跨进程harness使用Apple Development同团队签名、双方identifier/Team要求及生产audit-token校验，直接复用生产service/output/receiver/writer；正常ACK、生产默认30秒无ACK、客户端连接失效及O_RDONLY描述符的真实EBADF错误均有明确结果。它未经过固定privileged Mach入口、生产Client.request和真实Store。初次框架副本签名失败及临时回调隔离SIGTRAP均保留；修复只在harness，显式@Sendable回调后重跑四行，没有关闭actor运行期检查。断线行不证明服务器worker已退出。

vm-new只读挂载已清理，磁盘无打开句柄；8个所记录文件元数据与7个小文件摘要保持，Disk.img未做全量64GiB摘要。没有启动VM、修改AMFI/TCC或注册系统helper。当前冻结VM CDHash为`62a1f395413f6878c4de0042f6e77962aa2b1219`，SHA256为`c8e8be423f47c2bc85a7bca5715c306a49cbacba1442a5882416493660a5f8ff`。临时单哈希AMFI范围已生成并单独询问；此前范围只覆盖旧哈希，当前未执行。具体限制与证据见[evidence/B26-summary.json](evidence/B26-summary.json)。
'''
readme.write_text(text)
for row in manifest:
    f = target / row['path']
    assert f.stat().st_size == row['bytes'] and hashlib.sha256(f.read_bytes()).hexdigest() == row['sha256']
print(json.dumps({'source_head': head, 'files': len(manifest), 'bytes': summary['evidence_bytes']}))
