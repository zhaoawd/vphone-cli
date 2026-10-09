import pathlib,json,hashlib,datetime
out=pathlib.Path('/private/tmp/vphone-b26-t24');repo=pathlib.Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
r=repo/'research/upstream_integration_2026-10-06';meta=json.loads((out/'artifact-readback.json').read_text());final=json.loads((r/'evidence/B25/final-app-snapshot.json').read_text());proof=json.loads((r/'evidence/B25/t24/final-proof/report.json').read_text())
events=[]
for l in (out/'b25-final-exact-amfi.ndjson').read_text().splitlines():
 try:d=json.loads(l)
 except:continue
 if d.get('eventMessage'):events.append({k:d.get(k) for k in ['timestamp','processID','processImagePath','eventMessage']})
(out/'final-amfi-events.json').write_text(json.dumps(events,ensure_ascii=False,indent=2)+'\n')
crashes=[]
for root in [pathlib.Path.home()/'Library/Logs/DiagnosticReports',pathlib.Path('/Library/Logs/DiagnosticReports')]:
 for p in root.glob('**/*'):
  if p.is_file() and ('vphone-vm' in p.name.lower() or 'vphone-cli' in p.name.lower()):crashes.append({'path':str(p),'mtime':datetime.datetime.fromtimestamp(p.stat().st_mtime).isoformat(),'content_read':False})
(out/'crash-inventory.json').write_text(json.dumps({'matching_reports':crashes,'B25_VM_report_found':False,'scope':'Filename/stat inventory only; unrelated crash report contents were not read.'},ensure_ascii=False,indent=2)+'\n')
vmsha=meta['artifacts']['vm']['sha256'];snapshotVM=next(e for e in final['entries'] if e['path'].endswith('/vphone-vm'))['sha256'];proofVM=proof['artifacts']['toolchain']['files']['Contents/MacOS/vphone-vm']['sha256']
summary={
 'task':'B26 T24 read-only diagnosis','head':meta['head']['stdout'].strip(),'source_head':'53580180f09819ec539ba656c15fab7a23fdc1c3',
 'scope':meta['scope'],'status':'diagnosis_completed_runtime_acceptance_pending',
 'final_vm':{'sha256':vmsha,'cdhash':'77b509d8ce341c832d54c827f0a48b724791342e','strict_signature_exit':0,'ad_hoc':True,'restricted_entitlements_present':True,'manifest_match':vmsha==snapshotVM==proofVM==meta['artifacts']['embedded_vm']['sha256']},
 'observations':[
  'B25最终原VM及snapshot VM的--help记录均为9；原记录未保全terminationReason，不能仅由数值9判定信号。',
  '2026-10-09 18:04:44.836770+0800原VM、18:04:44.854027+0800最终snapshot VM均被amfid记录AppleMobileFileIntegrityError -424：The file is adhoc signed but contains restricted entitlements。',
  '精确日志与最终manifest/current SHA256一致，确认失败涉及AMFI对ad hoc及restricted entitlements组合的拒绝；具体哪项entitlement触发拒绝未进行单变量实验，原因未查明。',
  '同期CLI有-423日志但CLI resources退出0；-423日志不能单独证明CLI无法执行。',
  '当前debug VM仅有get-task-allow，最终VM含7项entitlement；debug --help通过不能替代最终运行验收。',
  'DiagnosticReports没有与B25最终VM对应的crash；没有读取无关报告内容。',
  '历史v1 helper SHA256保持bbc0917c2d5551de48b2eff7db8396c1c1d9a7d62f48eecdacf66a82da48b3c4；ad hoc、Team为空，配置检查78；系统job不存在113、安装路径不存在。'
 ],
 'matrix':[
  {'item':'最终签名、entitlements、manifest、精确AMFI日志','result':'已完成，只读'},
  {'item':'历史v1 helper只读配置拒绝','result':'已完成，78；不能替代XPC矩阵'},
  {'item':'最终VM --help独立复验','result':'未执行；先由父任务确认最终哈希的AMFI运行前提，再记录returncode/terminationReason及精确日志；不需要启动VM'},
  {'item':'直接CLI的TCC请求/允许/拒绝/责任归属','result':'未执行；需要可执行的最终VM、正常启动的受控副本、GUI解锁和明确的权限动作授权'},
  {'item':'Launchpad→launcher→可信store的TCC责任链','result':'未执行；除上一项前提外，需实际绑定/receipt有效及launcher身份、owner/path门槛通过；不能由直接CLI推断'},
  {'item':'历史v1 helper与最终客户端verify/install×无日志/新日志/已有日志六行矩阵','result':'当前不可执行；未配置历史helper不能注册。需要可验证签名团队及客户身份的历史实物；重签或修改metadata将改变实物身份并须单独记录'},
  {'item':'受控protocol-v1服务矩阵','result':'B24已有六行拒绝证据；本轮禁止注册服务且该fixture不能替代历史实物，因此未重复'}
 ],
 'next_steps':[
  '父任务先处理最终CDHash 77b509d8ce341c832d54c827f0a48b724791342e的受控运行前提；本子任务不执行AMFI变更。已有授权若仅覆盖旧哈希，不能推定覆盖当前哈希。',
  '运行前提满足后，仅执行最终原VM --help并保全负returncode或Foundation terminationReason，再对snapshot复验；此步骤不会创建VM。',
  'VM可执行后由父任务按既有tcc-acceptance.md用停机副本、--no-vphoned-update、坐标过滤器执行两条路线；不从现有允许状态推断首次提示或拒绝。',
  '历史helper继续保持未注册，先取得符合签名/配置前提的真实v1实物，再执行六行矩阵。'
 ],
 'mutations':{'AMFI':False,'TCC':False,'services':False,'signed_apps':False,'VM_boot':False,'UI':False,'SwiftPM':False,'research':False,'git_commit':False},
 'log_access':{'sandbox_attempt':'Cannot run while sandboxed','read_only_escalation':'approved and completed','raw_logs':'精确进程、精确路径与窄时间窗；无坐标或无关日志'},
 'evidence':['artifact-readback.json','b25-final-exact-amfi.ndjson','b25-final-exact-amfi.stderr','final-amfi-events.json','b25-exact-amfi.ndjson','crash-inventory.json']}
(out/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
(out/'summary.md').write_text('''# B26 T24 只读诊断结果

B25最终VM的执行失败已取得精确AMFI证据。2026-10-09 18:04:44.836770原VM和18:04:44.854027资源副本VM均被amfid记录 `AppleMobileFileIntegrityError -424: The file is adhoc signed but contains restricted entitlements`。原VM、Launchpad内嵌VM和B25最终snapshot的SHA256均为 `0dfa9ca618e10ce81fdbed8bbf428c78af1fc9457cb281bf361f2dc5a71d0034`，CDHash为 `77b509d8ce341c832d54c827f0a48b724791342e`。严格静态签名检查退出0。

该证据确认AMFI拒绝了ad hoc签名与restricted entitlements的组合。没有逐项删除entitlement进行实验，具体哪项触发拒绝的原因未查明。B25只记录数值9，未记录terminationReason，不能只由数值9判定SIGKILL。debug VM只有get-task-allow，不能用debug的--help通过替代最终VM验收。同期CLI -423日志伴随resources退出0，不能表述为CLI无法执行。

历史v1 helper摘要保持 `bbc0917c2d5551de48b2eff7db8396c1c1d9a7d62f48eecdacf66a82da48b3c4`；Team为空、ad hoc、配置检查退出78。系统job查询113且安装路径不存在。该实物当前不能注册，真实XPC六行拒绝矩阵仍未验收。B24受控protocol-v1服务结果不能替代历史实物。

最小下一步是由父任务处理当前CDHash的受控运行前提，再仅复验最终VM --help并保全terminationReason及精确日志。真实TCC两条路线还需要VM正常启动、GUI解锁、可信绑定及实际权限动作授权。继续使用不记录坐标的既有验收步骤；已有允许状态不能证明首次提示或拒绝行为。

本子任务只写 `/private/tmp/vphone-b26-t24/`。没有启动VM、使用UI、运行SwiftPM、注册服务、重签app或修改AMFI/TCC。完整矩阵和证据索引见summary.json。
''')
manifest=[]
for p in sorted(out.glob('*')):
 if p.is_file() and p.name!='evidence-manifest.json':manifest.append({'name':p.name,'bytes':p.stat().st_size,'sha256':hashlib.file_digest(open(p,'rb'),'sha256').hexdigest()})
(out/'evidence-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('manifest_match',summary['final_vm']['manifest_match'],'events',len(events),'files',len(manifest));print('summary',out/'summary.json')
