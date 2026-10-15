from pathlib import Path
import subprocess,json,time,signal,os
root=Path('/Users/qcz3840/github/vphone-cli/research/evidence/2026-10-13-task8/acceptance')
vm=Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
cmd=['/Library/Application Support/vphone-launchpad/Bundles/2.6.20261015-local/VPhone.bundle/Contents/MacOS/vphone-cli','vm','update-kernel','task8-copy','--library-root',str(vm.parent)]
result={'command':cmd,'injected':False};start=time.time()
with (root/'kernel-interruption.log').open('w') as log:
 p=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT);result['child_pid']=p.pid
 while p.poll() is None:
  try:
   d=json.loads((vm/'.firmware-transaction/journal.json').read_text());k=d.get('kernelDisk')
   if d.get('phase')=='publishing' and k and k.get('cursor',0)>=1:
    result['observed_journal']=d;result['signal']='SIGTERM';p.send_signal(signal.SIGTERM);result['injected']=True;break
  except (FileNotFoundError,json.JSONDecodeError):pass
  time.sleep(.05)
 result['exit_code']=p.wait();result['elapsed_seconds']=time.time()-start
 try:result['journal_after_exit']=json.loads((vm/'.firmware-transaction/journal.json').read_text())
 except FileNotFoundError:pass
(root/'kernel-interruption.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k not in ('observed_journal','journal_after_exit')}));print((root/'kernel-interruption.log').read_text()[-2500:])
raise SystemExit(0 if result['injected'] else 1)
