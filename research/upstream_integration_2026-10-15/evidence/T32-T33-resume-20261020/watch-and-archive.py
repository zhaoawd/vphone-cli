"""Observe existing acceptance; archive a passed result only. No VM or Git writes."""
import datetime,hashlib,json,os,subprocess,time
from pathlib import Path
r=Path(__file__).resolve().parents[2];d=Path(__file__).parent
tracked=[d/'archive-acceptance.py',r/'.build/t32-cryptex-symlink-debug/archive-after-pass.py']
frozen={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
statefile=d/'finalization-state.json'
report=dict(state='watching',pid=os.getpid(),archiveContractsSHA256=frozen)
def save():
 report['recordedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat();statefile.write_text(json.dumps(report,indent=2)+'\n')
def emit(value):print(json.dumps(value),flush=True)
save();last=None;deadline=time.monotonic()+43200
try:
 while time.monotonic()<deadline:
  state=json.loads((d/'acceptance-state.json').read_text())
  observation=subprocess.run([str(r/'.venv/bin/python3'),str(d/'observe-acceptance.py')],cwd=r,capture_output=True,text=True,timeout=20)
  if observation.returncode:raise RuntimeError('observer failed: '+observation.stderr[-500:])
  current=json.loads(observation.stdout)
  operation=[p['command'] for p in current['processes'] if 'plan_gate.py ' in p['command'] or 'cfw_disk_txn.py ' in p['command'] or 'verify_legacy_vm_boot.py' in p['command'] or 'verify_post_boot_cfw.py' in p['command']]
  readiness=json.loads((d/'boot-readiness-live.json').read_text()) if (d/'boot-readiness-live.json').exists() else {}
  key=(state['state'],tuple(operation),readiness.get('state'))
  if key!=last:
   report.update(acceptanceState=state['state'],operation=operation,bootReadiness=readiness.get('state'));save();emit(report);last=key
  if state['state']=='failed':raise RuntimeError('acceptance failed: '+state.get('error','unknown'))
  if state['state']=='passed':
   for name,value in frozen.items():
    if hashlib.sha256(Path(name).read_bytes()).hexdigest()!=value:raise RuntimeError('archive contract changed during acceptance')
   report.update(state='archiving');save()
   with (d/'archive-final.log').open('xb') as log:
    result=subprocess.run([str(r/'.venv/bin/python3'),str(d/'archive-acceptance.py')],cwd=r,stdout=log,stderr=subprocess.STDOUT,timeout=300)
   if result.returncode:raise RuntimeError('archive failed; inspect archive-final.log')
   report.update(state='passed',archive='research/upstream_integration_2026-10-15/evidence/T32-T33-new-vm-20261018/dsc-on-off-on-20261020-resume/manifest.json');save();emit(report);break
  if not current['runnerAlive']:raise RuntimeError('existing acceptance runner disappeared')
  time.sleep(30)
 else:raise RuntimeError('bounded12h wait expired')
except BaseException as error:
 report.update(state='failed',error=str(error));save();emit(report);raise
