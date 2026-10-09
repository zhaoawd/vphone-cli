import http.client,json,os,re,time
from pathlib import Path
r=Path('/private/tmp/vphone-b29-runtime');vm=Path('/Users/qcz3840/github/vphone-cli/vm-roothide-20261010')
state=json.loads((vm/'.vphone-runtime.json').read_text());assert state['pid']==json.loads((r/'process.json').read_text())['vm_pid']
s=os.statvfs(vm);assert s.f_bavail*s.f_frsize>=5*1024**3
port=int(re.search(r'\[api\] proxy listening on http://127\.0\.0\.1:(\d+)',(r/'vm-console-redacted.log').read_text(errors='replace'))[1]);token=(r/'token').read_text()
fd=os.open(r/'serial-input',os.O_WRONLY|os.O_NONBLOCK)
cmd='/private/var/containers/Bundle/Application/.jbroot-000114514191980C/bin/sh -c "PATH=/usr/bin:/bin:/usr/sbin:/sbin; launchctl kickstart -k user/501/wiki.qaq.irisind" >/var/root/vphone-b29-control/kickstart-observed.log 2>&1; echo B29_OBSERVED_KICKSTART:$?\n'
os.write(fd,cmd.encode());os.close(fd)
rows=[];start=time.monotonic()
while time.monotonic()-start<7:
 c=http.client.HTTPConnection('127.0.0.1',port,timeout=3)
 try:
  c.request('POST','/v1/rpc',body=json.dumps({'method':'processes.list','params':{'filter':'irisind'},'id':'observe'}),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
  response=c.getresponse();j=json.loads(response.read());assert response.status==200,j
  rows.append({'elapsed':time.monotonic()-start,'processes':j['result']['processes']})
 finally:c.close()
 time.sleep(.1)
(r/'irisin-process-observation.json').write_text(json.dumps(rows,indent=2)+'\n')
active=[x for row in rows for x in row['processes']]
print({'samples':len(rows),'observed_pids':sorted({x['pid'] for x in active}),'uids':sorted({x['uid'] for x in active}),'executables':sorted({x['executable'] for x in active}),'final_count':len(rows[-1]['processes'])})
assert active,'irisind never observed'
