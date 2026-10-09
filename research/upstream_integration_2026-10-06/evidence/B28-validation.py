from pathlib import Path
import json,hashlib,gzip,subprocess,ast
R=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');D=R/'research/upstream_integration_2026-10-06';E=D/'evidence/B28';base='3eea98a9e6b13efc4b9e477334bbcb6041ac978a';selected={'T02','T08','T24','T40','T46'};checks=[]
def load(p):return json.loads(p.read_text())
def check(n,v,detail=None):checks.append({'name':n,'passed':bool(v),'detail':detail})
def git(*args):return subprocess.check_output(['git','-C',str(R),*args])
def sha(b):return hashlib.sha256(b).hexdigest()
t=load(D/'tasks.json');c=load(D/'capability_ledger.json');m=load(D/'local_path_map.json');r=load(D/'T02_capability_reconciliation.json');cl=load(D/'commit_ledger.json')
for n,items in [('tasks',t['tasks']),('capabilities',c),('map',m),('reconciliation',r)]:
 check(n+'_47_unique',len(items)==47 and len({x['id'] for x in items})==47)
 accepted=[x['id'] for x in items if (x.get('status')=='accepted' if n=='tasks' else x.get('accepted'))]
 check(n+'_accepted_exact_8',set(accepted)=={'T%02d'%i for i in range(8)},accepted)
 old=json.loads(git('show',base+':'+str((D/({'tasks':'tasks.json','capabilities':'capability_ledger.json','map':'local_path_map.json','reconciliation':'T02_capability_reconciliation.json'}[n])).relative_to(R))))
 if n=='tasks':old=old['tasks']
 check(n+'_unselected_42_unchanged',all(x==next(y for y in old if y['id']==x['id']) for x in items if x['id'] not in selected))
check('38_required_one_optional',sum(x['status']!='accepted' and x['required_for_release'] for x in t['tasks'])==38 and sum(x['status']!='accepted' and not x['required_for_release'] for x in t['tasks'])==1)
check('capability_dispositions_preserved',all(x['disposition']==next(y for y in json.loads(git('show',base+':'+str((D/'capability_ledger.json').relative_to(R)))) if y['id']==x['id'])['disposition'] for x in c))
check('task_capability_status_match',all(x['status']==next(y for y in c if y['id']==x['id'])['acceptance_status'] for x in t['tasks']))
oldcl=json.loads(git('show',base+':'+str((D/'commit_ledger.json').relative_to(R))))
check('commit_dispositions_reasons_preserved',len(cl['commits'])==342 and all((x['disposition'],x['reason'])==(y['disposition'],y['reason']) for x,y in zip(cl['commits'],oldcl['commits'])))
map_=load(E/'archive-map.json');bad=[]
for x in map_['files']:
 p=D/x['archive_path'];b=p.read_bytes();raw=gzip.decompress(b) if x['encoding']=='gzip' else b
 if sha(b)!=x['archive_sha256'] or len(b)!=x['archive_bytes'] or sha(raw)!=x['source_sha256'] or len(raw)!=x['source_bytes']:bad.append(x['archive_path'])
check('archive_content_hashes',not bad,{'files':len(map_['files']),'bad':bad})
jsonbad=[];pybad=[];binaries=[]
for p in E.rglob('*'):
 if not p.is_file():continue
 b=p.read_bytes()
 if b[:4] in (b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\x7fELF') or b[:8]==b'!<arch>\n':binaries.append(str(p.relative_to(D)))
 if p.suffix=='.json':
  try:load(p)
  except Exception as error:jsonbad.append([str(p),str(error)])
 if p.suffix=='.py':
  try:ast.parse(p.read_text())
  except Exception as error:pybad.append([str(p),str(error)])
check('archived_JSON_valid',not jsonbad,jsonbad);check('archived_python_AST',not pybad,pybad);check('no_runtime_binaries',not binaries,binaries)
a=load(E/'T24/actual-six-row-matrix.json');check('T24_six_actual_protocol_refusals',len(a)==6 and {(x['verb'],x['log_case']) for x in a}=={(v,l) for v in ('verify-bundle','install-bundle') for l in ('none','new','existing')} and all(x['exit']==1 and x['protocol_refused'] and x['log_preserved'] for x in a))
check('T24_independent_cleanup',load(E/'T24/independent-final-readback.json')['independent_cleanup_verified'])
v=load(E/'T46/run2/verification.json');actual=gzip.decompress((E/'T46/run2/actual-ui.log.gz').read_bytes());expected=gzip.decompress((E/'T46/run2/expected-ui.log.gz').read_bytes());raw=gzip.decompress((E/'T46/run2/raw-forwarded.stdout.gz').read_bytes())
import re
norm=re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]',b'',raw).replace(b'\r\n',b'\n');norm+=b'' if norm.endswith(b'\n') else b'\n'
check('T46_UI_raw_expected_exact',actual==expected==norm and sha(actual)==v['actual_sha256'] and len(actual)==4734173 and len(actual.splitlines())==243257)
check('T46_interrupt_tail_VM_stop',v['interrupt']['signal']==2 and v['bridge_output_complete']['interrupted'] and v['bridge_output_complete']['time']>=v['interrupt']['time'] and v['vm_exit']['exit']==0 and not v['vm_exit']['reader_alive'] and v['vm_preservation']['preserved'])
check('T02_targeted_corrections',load(E/'T02/remediation-verification.json')['all_passed'])
check('T40_current_limited_copy_verification',not load(E/'T40/verification.json')['mismatches'] and load(E/'T40/verification.json')['runtime_regular_bytes']==282620062)
source_diff=git('diff','--name-only','b4e80c575950d768737234f9fcefc7fb7aff6081','--','sources','scripts','tests','Package.swift','Package.resolved','Makefile').decode().splitlines();check('product_source_unchanged',not source_diff,source_diff)
diff=git('diff','--check').decode();check('git_diff_check',not diff,diff)
manifest=load(D/'evidence/B28-evidence-manifest.json');bad=[]
for f in manifest['files']:
 p=D/f['path'];b=p.read_bytes()
 if sha(b)!=f['sha256'] or len(b)!=f['bytes']:bad.append(f['path'])
check('evidence_manifest_hashes',not bad,{'files':len(manifest['files']),'bad':bad})
result={'scope':'B28 final structural and evidence validation; not full source or semantic reacceptance','base_head':base,'checks':checks,'all_passed':all(x['passed'] for x in checks),'tests_not_rerun_reason':'No product source, tests or build inputs changed in B28; runtime and evidence checks cover this batch.'}
(D/'evidence/B28-validation.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print(json.dumps({'all_passed':result['all_passed'],'checks':len(checks),'failures':[x for x in checks if not x['passed']]},ensure_ascii=False,indent=2));assert result['all_passed']
