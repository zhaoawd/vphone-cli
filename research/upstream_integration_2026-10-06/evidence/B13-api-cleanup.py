import base64,hashlib,json,re,shlex,socket,time
from pathlib import Path
rows=[];target={'vm':'vm-new','pid':92943,'instance_id':'068574F6-DEF3-4910-88AB-57F5330C7A02'}
def call(t,**kw):
 q={'t':t,'screen':False,'target':target,**kw}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(40);s.connect('/Users/qcz3840/github/vphone-cli/vm-new/vphone.sock');s.sendall(json.dumps(q).encode()+b'\n');data=b''
  while b'\n' not in data:
   part=s.recv(65536)
   if not part:raise RuntimeError('closed')
   data+=part
   if len(data)>8*1024*1024:raise RuntimeError('bound')
 r=json.loads(data.split(b'\n')[0]);rows.append({'request':q,'response':r});return r
call('rpc',method='agent.health',params={})
for path in ['/usr/bin/vphoned','/var/root/Library/Caches/vphoned']:
 r=call('file_get',path=path);assert r['ok'];data=base64.b64decode(r.pop('data'),validate=True);digest=hashlib.sha256(data).hexdigest();assert digest=='306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001';r['readback']={'bytes':len(data),'sha256':digest}
prefix='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; '
query='ps -A -o pid=,ppid=,lstart=,comm= | grep -E "vphone-b13-api/vphoned$"'
r=call('shell',cmd=prefix+query,timeout_ms=10000);assert r['ok'] and r['code']==0
lines=r['stdout'].strip().splitlines();assert len(lines)==2
expected={50710:1,50711:50710};checks=[]
for line in lines:
 cells=line.split();pid=int(cells[0]);parent=int(cells[1]);assert expected[pid]==parent;assert cells[-1] in ['/var/root/vphone-b13-api/vphoned','/private/var/root/vphone-b13-api/vphoned']
 actual=f'ps -A -o pid=,ppid=,lstart=,comm= | grep -E "^[[:space:]]*{pid}[[:space:]]" | sed "s/^[[:space:]]*//"'
 checks.append('test "$('+actual+')" = '+shlex.quote(line.strip()))
command=prefix+' && '.join(checks+['kill -TERM 50710 50711'])
r=call('shell',cmd=command,timeout_ms=10000);assert r['ok'] and r['code']==0
# No loaded launchd job was installed; the candidate files are retained for a
# subsequent explicitly authorized acceptance boot rather than deleted.
time.sleep(1)
r=call('shell',cmd=prefix+'ps -A -o pid=,ppid=,comm= | grep -E "vphoned|vphone-b13"; launchctl print system/com.vphone.acceptance.b13.api',timeout_ms=10000)
assert 'vphone-b13-api/vphoned' not in r.get('stdout','');assert '/usr/bin/vphoned' in r.get('stdout','');assert 'Could not find service' in r.get('stderr','') or 'Could not find service' in r.get('stdout','')
call('capabilities');call('environment_status')
result={'observations':rows,'temporary_API_proxy_and_worker_stopped':True,'classic_binary_and_cached_binary_preserved':True,'classic_guest_still_running':True,'VM_not_stopped':True,'temporary_files_retained':'/var/root/vphone-b13-api','temporary_launchd_job_absent':True}
p=Path('/private/tmp/vphone-b13-api-cleanup.json');assert not p.exists();text=json.dumps(result,indent=2)+'\n';token=Path('/private/tmp/vphone-b10-restart-token').read_text();assert token not in text;p.write_text(text);print({k:v for k,v in result.items() if k!='observations'})
