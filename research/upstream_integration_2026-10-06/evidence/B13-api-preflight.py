import base64,hashlib,json,socket,subprocess
from pathlib import Path
main=Path('/Users/qcz3840/github/vphone-cli');root=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
rows=[]
target={'vm':'vm-new','pid':92943,'instance_id':'068574F6-DEF3-4910-88AB-57F5330C7A02'}
def call(t,**kw):
 q={'t':t,'screen':False,'target':target,**kw}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(45);s.connect(str(main/'vm-new/vphone.sock'));s.sendall(json.dumps(q).encode()+b'\n');b=b''
  while b'\n' not in b:
   c=s.recv(65536)
   if not c:raise RuntimeError('closed')
   b+=c
   if len(b)>8*1024*1024:raise RuntimeError('reply bound')
 r=json.loads(b.split(b'\n')[0]);rows.append({'request':q,'response':r});return r
call('capabilities')
call('environment_status')
call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; id; command -v launchctl; command -v mkdir; ls -ld /var/root/vphone-b13-api; ps -A -o pid=,comm= | grep -E "vphoned|vphone-b13"; ls -l /var/root/Library/Caches/vphoned*',timeout_ms=10000)
r=call('file_get',path='/usr/bin/vphoned');assert r['ok'];b=base64.b64decode(r.pop('data'),validate=True);r['readback']={'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()};assert r['readback']['sha256']=='306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001'
path=Path('/private/tmp/vphone-b13-api-preflight.json');assert not path.exists();path.write_text(json.dumps({'observations':rows,'frozen_host':target,'candidate_sha256':hashlib.sha256((root/'.build/daemon-api-v2/candidate/vphoned').read_bytes()).hexdigest()},indent=2)+'\n')
print(rows[-2]['response'])
