from pathlib import Path
import json,subprocess,hashlib
repo=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
r=repo/'research/upstream_integration_2026-10-06';e=r/'evidence';tmp=Path('/private/tmp/vphone-b25')
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip()
source_commits=subprocess.check_output(['git','rev-list','--reverse','2b6c28f7..'+head],cwd=repo,text=True).splitlines()
v=json.loads((tmp/'validation.json').read_text());assert v['python']['exit']==0 and v['swift']['exit']==0 and v['build']['exit']==0
assert json.loads((tmp/'code-review-final.json').read_text())
results={
'T08':('fixed_overlay_memory_rotation_verified_actual_RootHide_service_pending','B25只读核对固定IcliKit的domain选择和状态144说明；未新增VM验收。实际RootHide路径待回复，状态144与部分旋转未生效的原因未查明。',[
'实际RootHide客户机服务验收；用户测试路径待回复','services.start状态144及未生效rotation范围，原因未查明']),
'T24':('host_native_dependency_closure_verified_TCC_and_historical_helper_runtime_pending','B25递归封装宿主Mach-O依赖至Contents/Frameworks，重写相对引用并按嵌套代码后主可执行文件顺序签名。真实副本7个宿主映像逐个及整体签名通过；沙箱确认原Homebrew库读取被拒绝，同策略ldid提取和trustcache创建/读取退出0。历史v1未配置helper实物已定位，SHA256及内嵌版本保全，只读配置检查退出78；没有安装或启动该历史服务。TCC静态链已记录，实际责任归属未验收。',[
'完整TCC负责应用链实际验收，包括直接CLI与Launchpad→launcher→可信store路线','历史v1 helper未配置签名团队；仍缺历史服务与最终客户端的实际XPC拒绝矩阵','Python framework、包、PATH工具和现场编译不属于本轮宿主Mach-O封装范围；部分旧证书候选当前签名信任检查失败，记录保留，未新安装']),
'T40':('attempt_resource_snapshot_verified_external_toolchain_and_origin_matrix_pending','B25每attempt使用CLI/VM及所选资源的私有副本和聚合摘要；executor/verifier/prober及内部TaskLocal解析共用副本。resume变更未经确认拒绝，确认后整体换用新副本，保留此前阶段来源。副本最多8份、合计2GiB、64MiB余量；成功或未接受attempt释放，失败已接受attempt保留。审查发现并修复debs.list遗漏、Disk.img链接别名绕过、复制增长超预算3项。开发副本只读CLI/VM探针通过；最终签名App资源副本235个entry、161310727字节，CLI resources与静态签名检查退出0；原VM及副本VM --help均退出9，原因未查明，外部Python探针不可用。',[
'Python interpreter/framework/包、PATH工具、宿主SDK/JB现场编译、Virtualization ROM、既有cfw_input及可变缓存未形成不可变闭包','新机可信store binding/receipt发布及带可信既有binding/receipt的实际VM传输验收','kernel-only及环境升级/回退、混合版本四层来源矩阵；依赖T12/T17/T32/T34生产能力','完整64GiB VM归档往返空间仍不足；同卷APFS副本不证明物理独立备份']),
'T46':('ordinary_UI_quit_and_escaped_writer_verified_full_runtime_matrix_pending','B25普通命令登记活动状态；退出时同步关闭新命令入口，异步等待child、pipe EOF、日志finish及history，5秒未排空则取消退出并保留reader/writer。实际签名隔离UI两组受控CLI验收：普通writer退出、setsid后代持有管道导致退出取消；释放后退出。两组各10002行/138939字节与预期精确一致，SHA256 f972c4a3f4ffda6f317183c1cb66bc06522e5f6f454d6bf19c545c8ae69eedad；包含ANSI/CRLF规范化和无换行panic尾部。本轮应用及writer均退出。该UI使用最终签名Launchpad的隔离副本和受控签名CLI，不代表实际VM吞吐。',[
'完整panic/取消/轮换、UI响应及实际VM吞吐矩阵','helper异步ACK缺失/30秒超时/XPC断线/写入失败组合的完整实际验收'])}
if v['UI'].get('final_state') != 'passed':
 old=results['T46']
 results['T46']=('ordinary_command_drain_implemented_final_UI_blocked_by_host_lock_full_runtime_pending', 'B25普通命令同步关闭入口并有界等待child、pipe EOF、日志finish和history；定向及标准Swift通过。早期普通/escaped隔离UI两组日志精确匹配，但属于同步门控修改前快照。最终release隔离副本已启动doctor并观察writer存活，随后CUA报告Mac锁定；尚未执行退出操作。writer自释放后日志10002行/138939字节及panic尾部精确匹配；应用仍打开，最终退出两组待解锁复验。', ['最终签名release普通/escaped两组退出复验；Mac锁屏待用户解锁，当前普通writer已自释放需重跑']+old[2])
pathmap={
'T24':['scripts/build_native_dependencies.py','scripts/build.sh','scripts/build_launchpad.sh','scripts/check_bundle.py','scripts/check_launchpad_bundle.py','scripts/record_build_dependencies.py','tests/test_bundle_native_dependencies.py'],
'T40':['sources/VPhoneCore/VPhoneCreateResourceSnapshot.swift','sources/VPhoneCore/VPhoneResources.swift','sources/VPhoneCore/VPhoneCreateRunner.swift','sources/vphone-cli/VPhoneCreateOrchestrator.swift','sources/vphone-cli/VPhoneCreateLiveStages.swift','tests/VPhoneCoreTests/CreateResourceSnapshotTests.swift','tests/VPhoneCLITests/CreateResourceFreezeTests.swift'],
'T46':['sources/VPhoneLaunchpad/VPhoneLaunchpadApp.swift','sources/VPhoneLaunchpadKit/VPhoneLaunchpadCommandLine.swift','sources/VPhoneLaunchpadKit/VPhoneLaunchpadCreation.swift','tests/VPhoneLaunchpadKitTests/CommandTerminationTests.swift','tests/VPhoneLaunchpadKitTests/StopRefusalTests.swift','tests/VPhoneLaunchpadKitTests/LaunchTests.swift']}
tasks=json.loads((r/'tasks.json').read_text())
for t in tasks['tasks']:
 if t['id'] in results:
  status,result,remaining=results[t['id']];t['status']=status;t['current_result']+=' '+result;t['remaining_work']=remaining;t['B25_implementation_head']=head
  t.setdefault('verification_evidence',[]).extend(['evidence/B25-summary.json','evidence/B25-source-review.json','evidence/B25-evidence-manifest.json'])
  if t['id'] in pathmap:
   t.setdefault('implementation_commits',[]).extend(commit for commit in source_commits if commit not in t.get('implementation_commits',[]))
   paths=t.setdefault('local_mapping',{}).setdefault('paths',[])
   paths.extend(p for p in pathmap[t['id']] if p not in paths)
   t['local_mapping']['batch_source_manifest']='evidence/B25-source-review.json'
tasks['latest_implementation_head']=head
tasks['B25_execution_state']={'accepted_total':8,'required_remaining':38,'optional_deferred':1,'selected_count':10,'selected_accepted':6,'selected_remaining':['T08','T24','T40','T46'],'implementation_head':head,'newly_accepted':[]}
tasks['latest_validation_limitation']='B25标准Python/Swift、签名构建与Bundle检查结果见B25-summary；早期UI使用受控CLI；最终release UI退出复验因Mac锁屏中断。TCC/RootHide/完整四层来源/实际VM吞吐未验。旧签名App VM --help被终止，原因未查明。'
(r/'tasks.json').write_text(json.dumps(tasks,ensure_ascii=False,indent=2)+'\n')
caps=json.loads((r/'capability_ledger.json').read_text())
for c in caps:
 if c['id'] in results:
  status,result,remaining=results[c['id']];c['acceptance_status']=status;c['current_result']=next(t['current_result'] for t in tasks['tasks'] if t['id']==c['id']);c['remaining_work']=remaining;c['B25_implementation_head']=head;c['accepted']=False
  c.setdefault('evidence',[]).extend(['evidence/B25-summary.json','evidence/B25-source-review.json','evidence/B25-evidence-manifest.json'])
  paths=c.setdefault('paths',[]);paths.extend(p for p in pathmap.get(c['id'],[]) if p not in paths)
(r/'capability_ledger.json').write_text(json.dumps(caps,ensure_ascii=False,indent=2)+'\n')
summary={'batch':'B25','date':'2026-10-09','base_head':'2b6c28f7','implementation_head':head,'source_commits':source_commits,'selected_tasks':['T02','T03','T04','T05','T06','T07','T08','T24','T40','T46'],'selected_accepted':6,'selected_remaining':['T08','T24','T40','T46'],'newly_accepted':[],'all_tasks':{'accepted':8,'required_remaining':38,'optional':1},'results':{k:{'status':a,'result':b,'remaining':c} for k,(a,b,c) in results.items()},'validation':v,'review':{'initial_T40_important':3,'T24_followup_findings':3,'T46_fixture_cleanup_findings':1,'remaining_important':0,'final':'B25/code-review-final.json'},'UI':'B25/ui-acceptance.json','VM':'B25/vm-readback.json','source_freeze_note':'T02的11064b07历史语义审查基线保持；本批新增生产改动独立记录，不改写旧结论。'}
(e/'B25-summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
files=subprocess.check_output(['git','diff','--name-only','2b6c28f7',head,'--',':!TODO.md'],cwd=repo,text=True).splitlines()
manifest=[]
for f in files:
 p=repo/f
 if p.is_file():manifest.append({'path':f,'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
(e/'B25-source-review.json').write_text(json.dumps({'base_head':'2b6c28f7','implementation_head':head,'source_commits':source_commits,'files':manifest,'review_initial':'B25/code-review.json','review_final':'B25/code-review-final.json','scope':'B25增量；不是对47项或202提交重新验收','validation':v},ensure_ascii=False,indent=2)+'\n')
readme=r/'README.md';text=readme.read_text().replace('当前验收结果见末尾 B24 记录','当前验收结果见末尾 B25 记录')
text+='''\n\n## B25 结果（2026-10-09）\n\n本轮继续 T02–T08、T24、T40、T46 共10项。已验收6项（T02–T07）；T08/T24/T40/T46仍未完成，没有新增整项验收。47项仍为8项accepted、38项必选尚未完成、1项可选延期。\n\n| 任务 | 本轮结果 | 未完成范围 |\n| --- | --- | --- |\n| T08 | 只读核对固定IcliKit的domain顺序和144状态说明，未更改权限或添加fallback | 缺实际RootHide路径；服务144和部分旋转未生效，原因未查明 |\n| T24 | 宿主Mach-O依赖递归封装、相对引用、嵌套签名顺序和Bundle验证；禁止读取Homebrew时ldid/trustcache实际运行通过 | 完整TCC责任链、历史helper实际XPC拒绝；Python/PATH不在本轮闭包内 |\n| T40 | 每attempt私有CLI/VM与资源副本、聚合摘要、resume整体接受/拒绝；最多8份/2GiB并预留64MiB；失败副本保留 | Python/SDK/JB现场编译/既有cfw_input/可信新机binding未闭包；完整四层升级回退矩阵及64GiB往返仍未验 |\n| T46 | 实际签名UI普通writer立即退出、setsid后代持管道退出取消、释放后退出；两组日志精确一致 | helper ACK/超时/断线/写失败组合及实际VM吞吐仍待验收 |\n\nT40独立审查发现3项Important：开发debs.list遗漏、Disk.img链接别名绕过、复制期间来源增长可超过容量预检。三项均建立行为RED，修复后定向与相关测试通过，静态复审无新增Critical/Important。创建取消替身曾因来源revision变化提前拒绝，独立运行也复现。fs_usage确认QzhddrSrv在清单检查与复制之间对fixture requirements.txt执行setxattr，ctime变化而其余所记录revision字段相同。夹具预读及有界稳定等待未解决问题，已撤销。经复审，ctime/ACL/扩展属性/所有者未进入manifest；去掉ctime-only额外拒绝，保留inode、mode、size、mtime、逐文件SHA及全来源二次清单检查。确定性测试覆盖两个元数据变更时点、恢复mtime的内容改写与链接替换；原失败和诊断保留。\n\n本轮标准Swift曾失败两次。首轮在新增终止门控测试中观察到quick命令执行成功，日志没有确定终止任务启动、超时和quick执行的准确先后；同步begin关闭入口后再异步wait已通过定向检查。第二轮在旧StopRefusal/ParentExit测试中记录5个issues；两个受控实验分别用50ms子进程存活时间和暂停周期输出复现相应断言失败。最终fixture改为停止拒绝后的存活回执、父进程退出后UUID请求与原日志回执，并保留存活、session、PPID、隔离和尾部断言。Suite截止与既有10秒条件等待不增加；未修改生产停止信号、标准测试分组或性能截止。受控实验不证明第二轮实际失败的完整原因，原原因仍未查明。原失败、采样和定向检查保留在B25及t46/legacy-fixtures中。

实际UI使用最终签名Launchpad的隔离副本、隔离Bundle标识和受控签名CLI，保留生产AppDelegate→HostSetup→CommandLine→reader→LogWriter路径。两组各10002行、138939字节，SHA256为`f972c4a3f4ffda6f317183c1cb66bc06522e5f6f454d6bf19c545c8ae69eedad`，包含无换行panic尾部。后代持管道时界面显示退出取消，日志保持活动；释放后完整落盘并退出。AX观察曾重新打开已退出应用，已再次用CUA退出并核对本轮应用/写入者均不存在。早期UI界面选择调用分别耗时约2564秒和865秒，该时间不计为应用性能结果。早期UI属于同步门控修复前快照，最终复验结果独立保存。\n\n首次最终构建中，CLI Bundle检查通过，Launchpad新校验器拒绝内部`@loader_path`；进一步核查发现外层两个宿主程序保留Xcode绝对rpath。校验器修复对loader/executable相对路径解析后进行Bundle包含检查，未知token、相对穿越、符号链接越界和非系统绝对路径仍拒绝；Launchpad在最终封存前对外层宿主程序执行native staging。独立复审要求补齐裸token实际依赖解析、拒绝修改Helpers嵌入Bundle，以及拒绝同一来源库在不同宿主程序上下文解析出不同依赖的行为测试。该修复未修改Swift源码，最终标准Python及签名构建结果另行记录，保留首次构建失败。

历史v1 helper实物SHA256为`bbc0917c2d5551de48b2eff7db8396c1c1d9a7d62f48eecdacf66a82da48b3c4`，内嵌版本1、签名团队空。只读配置检查退出78，未安装或启动服务。该结果不替代历史helper与最终客户端的XPC矩阵。TCC目前只有静态责任链和不记录坐标的验收步骤。\n\n开发资源副本CLI resources与VM --help只读探针通过。旧签名App原VM和副本VM --help均被终止，原因未查明；静态签名通过不代表VM可执行。本轮未启动VM、未修改AMFI或TCC，保留客户机载荷摘要。\n\n'''
text+=f"本批源码提交为{'、'.join('`'+c[:8]+'`' for c in source_commits)}，最终构建基线为`{head[:8]}`。标准Python {v['python']['tests']}项（{v['python']['skipped']}跳过）、标准Swift及签名构建/Bundle检查结果见[B25-summary.json](evidence/B25-summary.json)。测试原始输出、独立审查、实际UI记录和失败诊断保存在[evidence manifest](evidence/B25-evidence-manifest.json)。原始日志按`* -text`保全，最终测试结果不能替代未执行的实际VM接受条件。\n"
if v['UI'].get('final_state') != 'passed':
 text=text.replace('| T46 | 实际签名UI普通writer立即退出、setsid后代持管道退出取消、释放后退出；两组日志精确一致 | helper ACK/超时/断线/写失败组合及实际VM吞吐仍待验收 |', '| T46 | 普通命令同步终止入口及有界排空实现、相关与标准测试通过；最终release实际日志精确匹配，UI退出操作被锁屏中断 | 解锁后重跑最终普通/escaped两组退出；helper组合及实际VM吞吐仍待验收 |')
 start=text.index('实际UI使用最终签名Launchpad的隔离副本')
 end=text.index('\n\n',start)
 text=text[:start]+'早期隔离UI的普通和escaped两组退出验收通过，各10002行/138939字节，属于同步门控修改前快照，不能替代最终release复验。最终53580180的签名隔离副本与生产主程序在移除签名后字节一致，已启动doctor并记录writer PID51919存活；随后CUA报告Mac已锁定且自动解锁失败，未执行退出操作。writer自释放后10002行/138939字节与预期精确一致，SHA256为`f972c4a3f4ffda6f317183c1cb66bc06522e5f6f454d6bf19c545c8ae69eedad`，包含panic尾部。隔离应用PID51581仍打开，待手动解锁后退出并重跑两组最终UI；未通过shell操作该UI。早期界面选择调用分别耗时约2564秒和865秒，未计为应用性能。最终UI的当前限制见`B25/ui-acceptance.json`。'+text[end:]
 text=text.replace('开发资源副本CLI resources与VM --help只读探针通过。旧签名App原VM和副本VM --help均被终止，原因未查明；静态签名通过不代表VM可执行。', '开发资源副本CLI resources与VM --help只读探针通过。最终安装布局副本235个entry、161310727字节；CLI resources及静态签名通过，原VM及副本VM --help均退出9，原因未查明；外部Python探针不可用。签名通过不代表VM可执行。')
readme.write_text(text)
print(json.dumps({'head':head,'selected_accepted':6,'remaining':['T08','T24','T40','T46'],'files':len(manifest)}))
