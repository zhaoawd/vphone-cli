import hashlib,json,os,stat,subprocess,time
from pathlib import Path
client=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/.build/acceptance/B15/helper-client.app/Contents/MacOS/vphone-cli')
archive='/private/tmp/vphone-b18-VPhone-2.6.1.zip';log=Path('/private/tmp/vphone-b21-helper-install-retry-output.log');result=Path('/private/tmp/vphone-b21-helper-install-retry.json');assert not log.exists() and not result.exists()
a=[str(client),'helper','install-bundle','--version','2.6.1','--archive',archive,'--sha256','651224d58064c59159e47b4a5fb066ca6dc758bdd221a346d43465cd34df5420','--log-file',str(log)]
t=time.monotonic()
try:
 p=subprocess.run(a,capture_output=True,text=True,timeout=900);j={'command':a,'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'seconds':time.monotonic()-t}
except subprocess.TimeoutExpired as e:
 j={'command':a,'timed_out':True,'seconds':time.monotonic()-t,'stdout':str(e.stdout),'stderr':str(e.stderr)}
if log.exists():
 data=log.read_bytes();s=log.stat();holders=subprocess.run(['/usr/sbin/lsof','-t','--',str(log)],capture_output=True,text=True)
 j.update(log_bytes=len(data),log_sha256=hashlib.sha256(data).hexdigest(),mode=oct(stat.S_IMODE(s.st_mode)),owner=s.st_uid,log_text=data.decode(),lsof_exit=holders.returncode,closed_after_return=holders.returncode==1 and not holders.stdout)
result.write_text(json.dumps(j,indent=2)+'\n');print(json.dumps(j,indent=2))
