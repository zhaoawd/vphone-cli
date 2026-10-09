#!/usr/bin/env python3
"""Read-only T02 evidence audit. Writes only its output directory; no network/build/VM.
Root TODO.md is never opened. Historical temporary paths resolve through retained archives.
"""
import argparse,collections,hashlib,json,pathlib,re,subprocess,tarfile
ap=argparse.ArgumentParser();ap.add_argument('--repo',default='/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');ap.add_argument('--out',default='/private/tmp/vphone-b28-t02');a=ap.parse_args()
repo=pathlib.Path(a.repo);out=pathlib.Path(a.out);out.mkdir(parents=True,exist_ok=True)
base=repo/'research/upstream_integration_2026-10-06';b24=base/'evidence/B24/T02'
checks=[];issues=[];notes=[]
def load(p):
 p=pathlib.Path(p)
 if p==repo/'TODO.md':raise ValueError('prohibited root TODO.md')
 return json.loads(p.read_text())
def sha(b):return hashlib.sha256(b).hexdigest()
def git(*args):return subprocess.check_output(['git','-C',str(repo),*args],stderr=subprocess.PIPE)
upstream_repo=pathlib.Path(load(base/'baseline.json')['object_repository'])
def upstream_git(*args):return subprocess.check_output(['git','-C',str(upstream_repo),*args],stderr=subprocess.PIPE)
def check(name,ok,detail=None):
 checks.append({'name':name,'passed':bool(ok),'detail':detail})
 if not ok:issues.append({'check':name,'detail':detail})
def keyed(xs,key='id'):return {x[key]:x for x in xs}
def counts(xs,key):return dict(collections.Counter(x.get(key) for x in xs))
def refcheck(ref,origin):
 """Only explicit retained evidence references, not prose entrypoints or planned paths."""
 ref=re.sub(r'^historical:\s*','',ref).split(';',1)[0]
 file,_,frag=ref.partition('#');file=file.split(': ',1)[0];file=re.sub(r':\d+(?::\d+)?$','',file)
 options=[base/file,repo/file,b24/file,base/'evidence'/file]
 if file.startswith('B24/') or file.startswith('B2'):options.insert(0,base/'evidence'/file)
 found=next((p for p in options if p.exists()),None)
 if found is None:return {'origin':origin,'reference':ref,'problem':'missing_file'}
 if frag and re.fullmatch('[0-9a-f]{40}',frag) and found.suffix=='.json':
  d=load(found); rows=d.get('entries',d.get('commits',[])) if isinstance(d,dict) else d
  if not any(x.get('sha')==frag for x in rows):return {'origin':origin,'reference':ref,'problem':'missing_sha_fragment'}
 return None
ledger=load(base/'commit_ledger.json');commits=ledger['commits'];review=load(base/'T02_commit_semantic_reviews.json');entries=review['entries'];pending=load(b24/'pending-index.json')
tasks=load(base/'tasks.json');ts=tasks['tasks'];caps=load(base/'capability_ledger.json');recon=load(base/'T02_capability_reconciliation.json');maps=load(base/'local_path_map.json')
frozen=load(b24/'evidence-objects/local/research/upstream_integration_2026-10-06/commit_ledger.json')['commits'];old=keyed(frozen,'sha');curr=keyed(commits,'sha');rs=keyed(entries,'sha')
head=git('rev-parse','HEAD').decode().strip();source=git('rev-parse','b4e80c57').decode().strip();target=ledger['target'];start=ledger['start']
check('fixed_head',head=='3eea98a9e6b13efc4b9e477334bbcb6041ac978a',head)
changed=git('diff','--name-only',source,head,'--','sources','scripts','tests','Package.swift','Makefile','requirements.txt').decode().splitlines()
check('source_b4e80c57_unchanged_at_HEAD',not changed,changed)
actual=set(upstream_git('rev-list',f'{start}..{target}').decode().splitlines())
check('342_unique_exact_git_coverage',len(commits)==len(curr)==len(actual)==342 and set(curr)==actual)
check('frozen_original_342_set_preserved',set(old)==set(curr))
original_pending={x['sha'] for x in frozen if x['disposition']=='pending_semantic_review'}
check('202_original_pending_exact_review_and_index_coverage',len(entries)==len(rs)==len(pending)==len(original_pending)==202 and set(rs)==original_pending=={x['sha'] for x in pending})
check('202_unique_indices_1_to_202',{x['index'] for x in entries}==set(range(1,203)))
check('202_original_review_flags_true',all(all(x.get(k) is True for k in ['full_diff_read','final_state_compared','semantic_review_complete','review_complete']) for x in entries))
check('202_recommendations_applied',all(curr[x['sha']]['disposition']==x['recommended_disposition']==x['disposition'] and curr[x['sha']].get('original_disposition')=='pending_semantic_review' for x in entries))
check('202_dispositions_counts',counts(entries,'recommended_disposition')=={'adaptation_planned':175,'already_equivalent':11,'intentionally_not_adopted':10,'superseded':6},counts(entries,'recommended_disposition'))
check('342_no_pending_semantic_review',not any(x['disposition']=='pending_semantic_review' for x in commits))
old140=[x for x in frozen if x['sha'] not in original_pending]
historical_changes=[{'sha':x['sha'],'field':k} for x in old140 for k in ['disposition','reason'] if curr[x['sha']].get(k)!=x.get(k)]
check('140_historical_disposition_reason_preserved',len(old140)==140 and not historical_changes,historical_changes)
check('140_historical_scope_not_new_full_review',all(curr[x['sha']].get('review_scope')=='prior_140_disposition_preserved_not_new_B24_full_diff_review' for x in old140))
merge_actual=set(upstream_git('rev-list','--merges',f'{start}..{target}').decode().splitlines());mergeaudit=load(base/'evidence/B22-merge-audit.json')['merges'];resolutions=load(base/'T02_merge_resolution_reviews.json')['reviews'];nonempty=[x for x in mergeaudit if x['additional_resolution']]
check('62_merge_coverage',len(merge_actual)==62 and merge_actual=={x['sha'] for x in mergeaudit}=={x['sha'] for x in commits if x['merge']})
check('54_empty_8_nonempty_merge_resolution',len(nonempty)==8 and len(mergeaudit)-len(nonempty)==54 and {x['sha'] for x in nonempty}=={x['sha'] for x in resolutions})
mergebad=[]
for x in resolutions:
 p=base/x['evidence'];m=next(m for m in nonempty if m['sha']==x['sha'])
 if not p.exists() or sha(p.read_bytes())!=m['remerge_sha256']:mergebad.append(x['sha'])
check('8_resolution_diff_hashes_match',not mergebad,mergebad)
expected={f'T{i:02}' for i in range(47)}
check('47_all_ledgers_unique_contract_coverage',all(len(x)==47 and set(keyed(x))==expected for x in [ts,caps,recon,maps]))
T,C,R,M=map(keyed,[ts,caps,recon,maps]);mapbad=[];depbad=[];localbad=[];refbad=[]
for id in sorted(expected):
 t,c,r,m=T[id],C[id],R[id],M[id]
 if not (t['dependencies']==c['dependencies']==r['dependencies']==m['dependencies']):depbad.append(id)
 if not set(t['dependencies'])<=expected:depbad.append(id+':dangling')
 if not (t['interface_contract']==r['interface_contract']==m['interface_contract'] and c['source_reconciliation']['interface_contract']==t['interface_contract'] and c.get('review_complete') and r.get('semantic_review_complete') and m.get('review_complete') and m['paths'] and m.get('verification_entrypoints')):mapbad.append(id)
 for p in m['paths']:
  if p.get('exists') and not (repo/p['path']).exists():localbad.append({'id':id,'path':p['path']})
  if not p.get('module_owner'):localbad.append({'id':id,'path':p['path'],'problem':'module_owner_missing'})
  if p.get('frozen_evidence'):
   e=refcheck(p['frozen_evidence'],id+':frozen_evidence')
   if e:refbad.append(e)
 for ref in t.get('verification_evidence',[]):
  e=refcheck(ref,id+':verification_evidence')
  if e:refbad.append(e)
check('47_dependency_consistency_and_no_dangling',not depbad,depbad)
check('47_contract_review_and_entrypoint_mappings',not mapbad,mapbad)
check('47_local_existing_paths_and_module_owners',not localbad,localbad)
check('unknown_T30_T31_preserved',{x['id'] for x in caps if x['disposition']=='unknown'}=={'T30','T31'})
accepted={x['id'] for x in ts if x['status']=='accepted'};capaccepted={x['id'] for x in caps if x.get('accepted')};mapaccepted={x['id'] for x in maps if x.get('accepted')};reconaccepted={x['id'] for x in recon if x.get('accepted')}
check('8_accepted_states_consistent_T00_to_T07',accepted==capaccepted==mapaccepted==reconaccepted=={f'T{i:02}' for i in range(8)},{'tasks':sorted(accepted),'caps':sorted(capaccepted),'maps':sorted(mapaccepted),'reconciliation':sorted(reconaccepted)})
check('38_required_remaining',sum(t['required_for_release'] and t['status']!='accepted' for t in ts)==38)
check('175_planned_never_promoted_to_accepted',all(curr[x['sha']]['disposition']=='adaptation_planned' and not curr[x['sha']].get('accepted',False) for x in entries if x['recommended_disposition']=='adaptation_planned'))
for x in commits:
 for k in ['evidence','semantic_review_evidence']:
  refs=x.get(k,[]);refs=[refs] if isinstance(refs,str) else refs
  for ref in refs:
   e=refcheck(ref,x['sha']+':'+k)
   if e:refbad.append(e)
 for id in x.get('candidate_tasks',[]):
  if id not in expected:refbad.append({'origin':x['sha'],'reference':id,'problem':'unknown_task'})
check('ledger_task_and_evidence_references_no_dangling',not refbad,refbad)
# Read retained tar members directly; do not extract or depend on historical /private/tmp paths.
archive_manifest=load(b24/'source-evidence-manifest.json');tarpath=b24/archive_manifest['archive'];archivebad=[];manifestbad=[];diffbad=[]
check('source_tar_sha256_and_size',sha(tarpath.read_bytes())==archive_manifest['sha256'] and tarpath.stat().st_size==archive_manifest['bytes'])
with tarfile.open(tarpath,'r:gz') as tf:
 members={m.name:m for m in tf.getmembers() if m.isfile()}
 for m in archive_manifest['files']:
  if pathlib.PurePosixPath(m['path']).name=='TODO.md':continue
  matches=[n for n in members if n==m['path'] or n.endswith('/'+m['path'])]
  if len(matches)!=1:archivebad.append({'path':m['path'],'matches':matches});continue
  b=tf.extractfile(members[matches[0]]).read()
  if sha(b)!=m['sha256'] or len(b)!=m['bytes']:archivebad.append({'path':m['path'],'problem':'hash_or_size'})
 for e in entries:
  name=pathlib.Path(e['diff_path']).name;matches=[n for n in members if n==name or n.endswith('/'+name)]
  if len(matches)!=1:diffbad.append({'sha':e['sha'],'problem':'missing_diff_archive'});continue
  b=tf.extractfile(members[matches[0]]).read()
  if sha(b)!=e['diff_evidence']['sha256'] or len(b.splitlines())!=e['diff_evidence'].get('line_count',e['diff_lines']):diffbad.append({'sha':e['sha'],'problem':'diff_hash_or_lines'})
check('source_tar_manifest_members_hashes',not archivebad,archivebad)
check('202_retained_full_diffs_sha256_and_lines',not diffbad,diffbad)
objects=load(b24/'evidence-objects-manifest.json');objectbad=[];deleted=0;present=0
for o in objects:
 if pathlib.PurePosixPath(o['path']).name=='TODO.md':continue
 spec=f"{o['revision']}:{o['path']}"
 if o['exists_at_revision']:
  present+=1;p=b24/o['archive_path']
  if not p.exists():objectbad.append({'path':o['path'],'problem':'missing_retained_object'});continue
  b=p.read_bytes()
  if sha(b)!=o['sha256'] or len(b)!=o['bytes']:objectbad.append({'path':o['path'],'problem':'object_hash_or_size'})
  try:
   reader=upstream_git if o['kind']=='upstream' else git
   actual_object=reader('ls-tree','-r',spec) if o['object_type']=='tree' else reader('show',spec)
   if actual_object!=b:objectbad.append({'path':o['path'],'problem':'git_object_mismatch'})
  except subprocess.CalledProcessError:objectbad.append({'path':o['path'],'problem':'git_object_unavailable'})
 else:
  deleted+=1
  try:(upstream_git if o['kind']=='upstream' else git)('cat-file','-e',spec);objectbad.append({'path':o['path'],'problem':'declared_deleted_object_exists'})
  except subprocess.CalledProcessError:pass
check('739_fixed_git_objects_719_present_20_absent',len(objects)==739 and present==719 and deleted==20 and not objectbad,{'present':present,'explicit_absent':deleted,'errors':objectbad})
delivery=load(b24/'delivery-manifest.json')
for f in delivery['files']:
 p=b24/f['path']
 if not p.exists() or sha(p.read_bytes())!=f['sha256'] or p.stat().st_size!=f['bytes']:manifestbad.append(f['path'])
check('delivery_manifest_hashes_current_retained_files',not manifestbad,manifestbad)
# Validate every archived local/final source citation, preserving explicit final deletion.
citationbad=[];unarchived_aux=[];citationcount=0
for e in entries:
 for field in ['local_evidence','final_evidence']:
  for o in e.get(field,[]):
   citationcount+=1
   if o.get('exists_at_revision') is False:continue
   if not o.get('archive_path'):
    p=pathlib.Path(o['path'])
    unarchived_aux.append({'sha':e['sha'],'index':e['index'],'field':field,'path':str(p),'exists_now':p.exists(),'sha256_now':sha(p.read_bytes()) if p.is_file() else None,'problem':'existing_auxiliary_reference_not_retained_in_B24_archive'})
    if not p.exists():citationbad.append({'sha':e['sha'],'field':field,'problem':'missing_auxiliary_reference'})
    continue
   p=base/o['archive_path']
   if not p.exists() or (o.get('sha256') and sha(p.read_bytes())!=o['sha256']):citationbad.append({'sha':e['sha'],'path':o['archive_path'],'problem':'citation_missing_or_hash'})
check('202_local_final_citations_resolve_archive_or_existing_auxiliary_path',not citationbad,{'checked':citationcount,'errors':citationbad})
check('all_202_source_citations_retained_without_temporary_path_dependency',not unarchived_aux,unarchived_aux)
b24_machine=load(b24/'machine-validation.json')
b24_reason=C['T02']['B24_acceptance_decision']['reason']
reported=int(re.search(r'(\d+)项机器校验',b24_reason).group(1))
check('B24_acceptance_reason_machine_check_count_matches_artifact',reported==len(b24_machine['checks']),{'reason_reported_count':reported,'artifact_actual_count':len(b24_machine['checks']),'artifact_all_true':all(b24_machine['checks'].values()),'affected_files':['capability_ledger.json','T02_capability_reconciliation.json','local_path_map.json']})
notes.append('B24审查源码基线为11064b07；本次HEAD为3eea98a9，当前源码提交为b4e80c57。历史审查与当前源码范围分别记录。')
notes.append('B24 source_reconciliation.acceptance_status_preserved等字段保留审查前状态；当前T02 accepted由B24_acceptance_decision和外层状态表示。')
notes.append('independent-validation.json检查的是较早草稿，其inputs摘要不作为最终交付摘要；最终交付使用delivery-manifest.json与source-evidence-manifest.json。')
notes.append('B24_acceptance_decision.reason写21项机器校验；保留machine-validation.json实际包含22项且均为true。此计数表述差异不改变检查结果。')
notes.append('2条辅助引用当前文件存在，但未纳入B24保留归档；其可复验性依赖临时目录。此项不改变T02历史accepted状态。')
notes.append('复核验证结构、覆盖、保留对象和摘要；不重新宣称202项语义结论已独立审查，不新增功能或运行验收。')
result={'scope':'B28 T02 read-only ledger/evidence consistency audit','repo':str(repo),'head':head,'source_head':source,'upstream_target':target,'upstream_object_repository':str(upstream_repo),'all_checks_passed':all(x['passed'] for x in checks),'checks':checks,'issues':issues,'counts':{'checks':len(checks),'commits':len(commits),'original_pending_reviewed':len(entries),'historical_preserved':len(old140),'capabilities':len(caps),'accepted':len(accepted),'required_remaining':38,'citations_checked':citationcount},'dispositions':counts(entries,'recommended_disposition'),'notes':notes,'limits':['No repository writes, root TODO.md reads, network, SwiftPM, VM, UI or system services.','Source existence and declaration flags do not independently establish semantic correctness or runtime behavior.']}
(out/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
report='T02只读复核\n\n'+'结果：'+('通过' if result['all_checks_passed'] else '存在未通过检查')+f"；{len(checks)}项检查，{len(issues)}项问题。\n\n"+'\n'.join(notes)+'\n\n'+json.dumps({'counts':result['counts'],'dispositions':result['dispositions'],'issues':issues},ensure_ascii=False,indent=2)+'\n'
(out/'report.txt').write_text(report)
print(json.dumps({'all_checks_passed':result['all_checks_passed'],'counts':result['counts'],'issues':issues},ensure_ascii=False,indent=2))
