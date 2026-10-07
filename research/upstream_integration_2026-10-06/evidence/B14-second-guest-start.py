import base64,hashlib,http.client,json,re,socket,time
from pathlib import Path
vm=Path('/Users/qcz3840/github/vphone-cli/vm-new');runtime=json.loads((vm/'.vphone-runtime.json').read_text());target={'vm':'vm-new','pid':84587,'instance_id':runtime['instanceID']};assert runtime['pid']==84587
rows=[]
def call(t,**kw):
 q={'t':t,'screen':False,'target':target,**kw}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(30);s.connect(str(vm/'vphone.sock'));s.sendall(json.dumps(q).encode()+b'\n');data=b''
  while b'\n' not in data:
   c=s.recv(65536)
   if not c:raise RuntimeError('closed')
   data+=c
   if len(data)>16*1024*1024:raise RuntimeError('bound')
 r=json.loads(data.split(b'\n')[0]);rows.append({'request':q,'response':r});return r
prefix='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; '
try:
 cap=call('capabilities');assert cap['ok'] and cap['guest_connected']
 for path,digest in [('/usr/bin/vphoned','306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001'),('/var/root/Library/Caches/vphoned', '306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001'),('/var/root/vphone-b13-api/vphoned','152dc35bd219ebccffb71623cb9e732a8e88d9f257b87f42ac0e38258f7e1749')]:
  r=call('file_get',path=path);assert r['ok'];data=base64.b64decode(r.pop('data'),validate=True);assert hashlib.sha256(data).hexdigest()==digest;r['readback']={'bytes':len(data),'sha256':digest}
 r=call('shell',cmd=prefix+'test -z "$(ps -A -o comm= | grep -E \"vphone-b13-api/vphoned$\")" && VPHONE_API_ONLY=1 /var/root/vphone-b13-api/vphoned </dev/null >/var/root/vphone-b13-api/b14-second-direct.log 2>&1 &',timeout_ms=10000);assert r['ok'] and r['code']==0
 port=int(re.search(r'\[api\] proxy listening on http://127\.0\.0\.1:(\d+)',Path('/private/tmp/vphone-b14-second-boot.log').read_text(errors='replace'))[1]);token=Path('/private/tmp/vphone-b14-second-token').read_text();probes=[]
 for i in range(15):
  time.sleep(2);conn=http.client.HTTPConnection('127.0.0.1',port,timeout=8)
  try:
   conn.request('GET','/v1/health',headers={'Authorization':'Bearer '+token});res=conn.getresponse();body=res.read();entry={'status':res.status,'body':json.loads(body)};probes.append(entry)
   if res.status==200:break
  except Exception as e:probes.append({'error':str(e)})
  finally:conn.close()
 assert probes[-1].get('status')==200
 # Wait for the new host's startup worker; do not call screen.unlock ourselves.
 time.sleep(3)
 screen=call('rpc',method='device.screen',params={});assert screen['ok']
 call('capabilities');call('environment_status');call('shell',cmd=prefix+'ps -A -o pid=,ppid=,lstart=,comm= | grep -E "vphoned|vphone-b13"; tail -n 30 /var/root/vphone-b13-api/b14-second-direct.log',timeout_ms=10000)
 result={'target':target,'observations':rows,'health_probes':probes,'new_host_startup_unlock_observation':screen,'manual_unlock_called':False}
finally:
 result=locals().get('result',{'target':target,'observations':rows,'failed_before_completion':True});serialized=json.dumps(result,indent=2)+'\n';assert Path('/private/tmp/vphone-b14-second-token').read_text() not in serialized;Path('/private/tmp/vphone-b14-second-guest-start.json').write_text(serialized)
print({'target':target,'screen':screen})
