import json,os,signal,subprocess,time
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=49027;actual=subprocess.check_output(['/bin/ps','-p',str(p),'-o','ppid=,command='],text=True).strip();assert actual.startswith('48648 ') and '--no-parallel' in actual and '--skip FirmwareIntegrationTests' in actual
children=subprocess.check_output(['/bin/ps','-A','-o','pid=,ppid=,command='],text=True);assert not any(x.split()[1]==str(p) for x in children.splitlines() if len(x.split())>1)
os.kill(p,signal.SIGTERM)
Path('/private/tmp/vphone-b13-final-serial-stop.json').write_text(json.dumps({'pid':p,'parent':48648,'verified_command':actual,'signal':'SIGTERM','reason':'APIHTTPFixture.stop waiting in Foundation waitUntilExit while no direct OS child remains; cause not established; final normal complete run not passed'},indent=2)+'\n')
e=os.environ.copy()
for k in list(e):
 if k.startswith(('VPHONE_TEST_','VPHONE_LESS_','VPHONE_C4_')):del e[k]
rows=[]
for n,c in [('final-swift-other',['swift','test','--disable-sandbox','--no-parallel','--cache-path','.build/test-cache','--skip','FirmwareIntegrationTests|APIHTTPTests']),('final-swift-api-isolated',['swift','test','--disable-sandbox','--skip-build','--filter','APIHTTPTests|APIWebSocketTests|OutputXPCTests'])]:
 log=Path('/private/tmp/vphone-b13-'+n+'.log');assert not log.exists();started=time.time()
 with log.open('w') as f:
  f.write('COMMAND '+json.dumps(c)+'\n');f.flush();x=subprocess.run(c,cwd=r,env=e,stdout=f,stderr=subprocess.STDOUT)
 rows.append({'name':n,'command':c,'returncode':x.returncode,'seconds':time.time()-started,'log':str(log)})
Path('/private/tmp/vphone-b13-final-partition-results.json').write_text(json.dumps(rows,indent=2)+'\n');print(rows)
