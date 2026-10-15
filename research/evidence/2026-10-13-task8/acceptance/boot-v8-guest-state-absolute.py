from pathlib import Path
import json,subprocess
E=Path(__file__).resolve().parent
out=E/'boot-v8-guest-state-absolute.json'
assert not out.exists()
discovery=json.loads((E/'boot-v8-guest-command-discovery-retry.json').read_text())
msg=json.loads(discovery['command'][-1])
target=msg['target']
msg.update(cmd='/var/jb/usr/bin/uname -a; /var/jb/usr/sbin/sysctl kern.osrelease hw.machine')
cmd=discovery['command'][:-1]+[json.dumps(msg)]
p=subprocess.run(cmd,capture_output=True,text=True,timeout=20)
r={'command':cmd,'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'target':target,'discovery_process':discovery['process']}
try:
    response=json.loads(p.stdout)
    r['response']=response
    r['passed']=(p.returncode==0 and response.get('ok') is True and type(response.get('code')) is int and response['code']==0 and response.get('timed_out') is False and response.get('truncated') is False and isinstance(response.get('stdout'),str) and all(t in response['stdout'] for t in ('Darwin','kern.osrelease:','hw.machine:')))
finally:
    out.write_text(json.dumps(r,indent=2)+'\n')
    print(json.dumps(r))
assert r['passed']
