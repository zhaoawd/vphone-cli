import base64,hashlib,http.client,json,plistlib,re,socket,time
from pathlib import Path
main=Path('/Users/qcz3840/github/vphone-cli');root=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
rows=[];target={'vm':'vm-new','pid':92943,'instance_id':'068574F6-DEF3-4910-88AB-57F5330C7A02'}
def call(t,**kw):
 q={'t':t,'screen':False,'target':target,**kw}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(90);s.connect(str(main/'vm-new/vphone.sock'));s.sendall(json.dumps(q).encode()+b'\n');b=b''
  while b'\n' not in b:
   c=s.recv(65536)
   if not c:raise RuntimeError('closed')
   b+=c
   if len(b)>8*1024*1024:raise RuntimeError('reply bound')
 r=json.loads(b.split(b'\n')[0]);rows.append({'request':q,'response':r});return r
prefix='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; '
r=call('shell',cmd=prefix+'test ! -e /var/root/vphone-b13-api && mkdir -m 700 /var/root/vphone-b13-api',timeout_ms=10000);assert r['ok'] and r['code']==0
binary=root/'.build/daemon-api-v2/candidate/vphoned';digest=hashlib.sha256(binary.read_bytes()).hexdigest()
r=call('file_put',path='/var/root/vphone-b13-api/vphoned',load=str(binary),perm='755');assert r['ok']
readback=Path('/private/tmp/vphone-b13-api-readback');assert not readback.exists()
r=call('file_get',path='/var/root/vphone-b13-api/vphoned',save=str(readback));assert r['ok'];assert hashlib.sha256(readback.read_bytes()).hexdigest()==digest
job={'Label':'com.vphone.acceptance.b13.api','ProgramArguments':['/var/root/vphone-b13-api/vphoned'],'EnvironmentVariables':{'VPHONE_API_ONLY':'1'},'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':2,'ProcessType':'Interactive','StandardOutPath':'/var/root/vphone-b13-api/stdout.log','StandardErrorPath':'/var/root/vphone-b13-api/stderr.log'}
plist=Path('/private/tmp/vphone-b13-api-job.plist');assert not plist.exists();plist.write_bytes(plistlib.dumps(job))
r=call('file_put',path='/var/root/vphone-b13-api/job.plist',load=str(plist),perm='600');assert r['ok']
r=call('shell',cmd=prefix+'launchctl bootstrap system /var/root/vphone-b13-api/job.plist',timeout_ms=10000);assert r['ok'] and r['code']==0
port=int(re.search(r'\[api\] proxy listening on http://127\.0\.0\.1:(\d+)',Path('/private/tmp/vphone-b10-restart-boot.log').read_text(errors='replace'))[1]);token=Path('/private/tmp/vphone-b10-restart-token').read_text()
probes=[]
for i in range(8):
 time.sleep(2)
 conn=http.client.HTTPConnection('127.0.0.1',port,timeout=10)
 try:
  conn.request('GET','/v1/health',headers={'Authorization':'Bearer '+token});resp=conn.getresponse();body=resp.read();item={'status':resp.status,'body':json.loads(body)};probes.append(item)
  if resp.status==200:break
 except Exception as e:probes.append({'error':str(e)})
 finally:conn.close()
call('environment_status')
call('shell',cmd=prefix+'launchctl print system/com.vphone.acceptance.b13.api; tail -n 20 /var/root/vphone-b13-api/stderr.log; ps -A -o pid=,comm= | grep -E "vphoned|vphone-b13"',timeout_ms=10000)
r=call('file_get',path='/usr/bin/vphoned');assert r['ok'];raw=base64.b64decode(r.pop('data'),validate=True);r['sha256']=hashlib.sha256(raw).hexdigest();assert r['sha256']=='306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001'
result={'candidate_sha256':digest,'candidate_readback_verified':True,'classic_daemon_unchanged':True,'observations':rows,'health_probes':probes,'host_new_source_activated':False,'camera_shared_memory_activated':False}
output=Path('/private/tmp/vphone-b13-api-activation.json');assert not output.exists();serialized=json.dumps(result,indent=2)+'\n';assert token not in serialized;output.write_text(serialized)
print({'candidate_bytes':binary.stat().st_size,'health_probes':probes,'classic_daemon_unchanged':True})
