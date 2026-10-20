"""Bounded continuation for the already-authorized independent DSC acceptance."""
import datetime,json,os,subprocess,time
from pathlib import Path
r=Path.cwd();out=r/'.build/t32-rebaseline-debug';state=dict(state='waiting-install',installerPID=13075)
def save():
 state['recordedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat()
 (out/'continuation.json').write_text(json.dumps(state,indent=2)+'\n')
def run(label,command,env=None):
 state.update(state=label,argv=command);save()
 with (out/(label+'.log')).open('wb') as log:
  child=subprocess.Popen(command,cwd=r,env=env,stdout=log,stderr=subprocess.STDOUT)
  state['childPID']=child.pid;save();code=child.wait()
 state['exitCode']=code;save()
 if code:raise RuntimeError(label+' exited '+str(code))
try:
 save();deadline=time.monotonic()+10800
 while True:
  if (out/'stop-continuation').exists():raise RuntimeError('continuation explicitly stopped')
  observed=subprocess.run(['ps','-p','13075','-o','command='],capture_output=True,text=True)
  if observed.returncode!=0:break
  if 'vphone-cli cfw install vm-t32-t33-dsc-20261018 ' not in observed.stdout:raise RuntimeError('installer pid identity changed')
  if time.monotonic()>deadline:raise RuntimeError('bounded installer wait expired')
  time.sleep(5)
 log=(r/'.build/t32-undo-mount-debug/rebaseline-cfw.log').read_text(errors='replace')
 if '[+] host-mode CFW install complete.' not in log:raise RuntimeError('installation did not report complete publication')
 vm=r/'vm-t32-t33-dsc-20261018';python=r/'.venv/bin/python3';proof=r/'.build/t32-dsc-v4-rebaseline'
 env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1',VPHONE_PYTHON=str(python))
 run('installed-proof',[str(python),str(r/'scripts/vm_lock.py'),str(vm),'fw-receipts','--',str(python),str(r/'research/upstream_integration_2026-10-15/tools/verify_dsc_publication.py'),'--vm',str(vm),'--phase','installed','--source-diagnostic',str(r/'.build/t32-dsc-readonly-source/result.json'),'--out',str(proof)],env)
 result=json.loads((proof/'result.json').read_text())
 if result['state']!='passed' or result['transactionID']=='20261019T065441Z-XzJThk9M':raise RuntimeError('missing new installed publication proof')
 state['installedTransactionID']=result['transactionID'];save()
 env.update(VPHONE_ROOT=str(r/'.build/t32-t33-runtime-20261018'),PATH=str(r/'.tools/bin')+':'+str(r/'.venv/bin')+':'+env['PATH'])
 run('undo-preboot',[str(r/'.build/t32-undo-mount-final.app/Contents/MacOS/vphone-cli'),'cfw','undo',vm.name,'--library-root',str(r),'--generation',result['generationID'],'--declaration','dyld-boot-iomfb_swapend','--root-popup'],env)
 state['state']='undo-published';save()
except Exception as error:
 state.update(state='failed',error=str(error));save();raise
