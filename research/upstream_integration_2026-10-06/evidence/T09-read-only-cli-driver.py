import json, subprocess
from pathlib import Path
root=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
binary=root/'.build/debug/vphone-cli'
rows=[]
def run(label,args,check=None,rejected=False):
 p=subprocess.run([str(binary),'fw']+args,text=True,capture_output=True,timeout=30)
 if rejected:
  assert p.returncode!=0,(label,p.stdout,p.stderr)
  assert not p.stdout.strip(),(label,'unexpected output',p.stdout)
 else:
  assert p.returncode==0,(label,p.stdout,p.stderr)
  data=json.loads(p.stdout);check(data)
 rows.append({'case':label,'arguments':args,'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
for mode in ['regular','dev','jb','exp','less']:
 def check(d,mode=mode):
  assert d['variant']==mode
  assert d['bundledPreset']=='experimental'
  assert d['selection']['selected']==['ibss-cfw-serial_label']
  assert d['selection']['blocked']==['kernel-cfw-paravirt_user_clients']
  assert d['selection']['notDeclaredLocally']==['kernel-cfw-paravirt_user_clients']
 run('mode-'+mode,['selection-preview','--variant',mode,'--bundled-preset','extended','--select','ibss.serial_label','--block','kernel-exp-paravirt_user_clients'],check)
old=json.loads((root/'research/t09_patch_id_mapping_2026-10-01.json').read_text())['patches']
def all_check(d):
 assert d['selection']['selected']==sorted(p['id'] for p in old)
 assert len(d['selection']['renames'])==117
 assert d['selection']['blocked']==[]
run('all-117-old-ids',['selection-preview','--select']+[p['old_id'] for p in old],all_check)
run('empty-no-default-enable',['selection-preview'],lambda d: d['selection']['selected']==[] or (_ for _ in ()).throw(AssertionError()))
for label,args in [
 ('unknown',['selection-preview','--select','unknown-id']),
 ('duplicate',['selection-preview','--block','ibss.serial_label','ibss.serial_label']),
 ('alias-collision',['selection-preview','--select','ibss.serial_label','ibss-cfw-serial_label']),
 ('conflicting-alias',['selection-preview','--select','ibss.serial_label','--block','ibss-cfw-serial_label']),
 ('mode-as-preset',['selection-preview','--bundled-preset','exp']),
 ('plan-duplicate',['plan','--select','ibss-cfw-serial_label','ibss-cfw-serial_label','--json'])]:
 run(label,args,rejected=True)
Path('/private/tmp/vphone-t09-cli-check-20261007.json').write_text(json.dumps({'cases':rows,'count':len(rows),'passed':True},ensure_ascii=False,indent=2)+'\n')
print(f'{len(rows)} read-only CLI cases passed; 117 legacy IDs, five modes, six refusals')
