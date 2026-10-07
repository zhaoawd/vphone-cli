import json,subprocess,time
from pathlib import Path
vm=Path('/Users/qcz3840/github/vphone-cli/vm-new');rows=[];files=[str(p) for p in vm.rglob('*') if p.is_file() and not p.is_symlink()]
for i in range(20):
 ps=subprocess.run(['/bin/ps','-p','70577','-o','pid=,stat=,command='],capture_output=True,text=True);ls=subprocess.run(['/usr/sbin/lsof','-nP','-t','--',*files],capture_output=True,text=True,timeout=10);rows.append({'pid_returncode':ps.returncode,'pid_stdout':ps.stdout,'lsof_returncode':ls.returncode,'lsof_stdout':ls.stdout,'lsof_stderr':ls.stderr})
 if ps.returncode!=0 and ls.returncode==1 and not ls.stdout.strip():break
 time.sleep(.5)
log=Path('/private/tmp/vphone-b14-restart-boot.log').read_text(errors='replace');Path('/private/tmp/vphone-b14-stop-log-snapshot.log').write_text(log)
x={'method':'CUA menu Stop VM; no host signal sent by this watcher','observations':rows,'VM_process_exited':ps.returncode!=0,'disk_free':ls.returncode==1 and not ls.stdout.strip(),'guest_stopped_in_log':'[vphone] Guest stopped' in log,'guest_shutdown_results':[l for l in log.splitlines() if 'guest shutdown request:' in l],'force_timeout_in_log':'graceful shutdown timed out' in log};Path('/private/tmp/vphone-b14-stop-result.json').write_text(json.dumps(x,indent=2)+'\n');print({k:v for k,v in x.items() if k!='observations'});assert x['VM_process_exited'] and x['disk_free'] and x['guest_stopped_in_log']
