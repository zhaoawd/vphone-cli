import base64,hashlib,http.client,json,re,socket,struct,time,urllib.parse,os
from pathlib import Path
vm=Path('/Users/qcz3840/github/vphone-cli/vm.backups/b21-restored-vm-new-20261009');run=json.loads((vm/'.vphone-runtime.json').read_text());target={'vm':vm.name,'pid':run['pid'],'instance_id':run['instanceID']};assert run['pid']==json.loads(Path('/private/tmp/vphone-b21-restart-boot-process.json').read_text())['pid']
port=int(re.search(r'\[api\] proxy listening on http://127\.0\.0\.1:(\d+)',Path('/private/tmp/vphone-b21-restart-boot.log').read_text(errors='replace'))[1]);token=Path('/private/tmp/vphone-b21-restart-token').read_text();rows=[]
prefix='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; '
def ctl(t,**kw):
 q={'t':t,'screen':False,'target':target,**kw}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(45);s.connect(str(vm/'vphone.sock'));s.sendall(json.dumps(q).encode()+b'\n');data=b''
  while b'\n' not in data:
   b=s.recv(65536)
   if not b:raise RuntimeError('EOF')
   data+=b;assert len(data)<32*1024*1024
 r=json.loads(data.split(b'\n')[0]);saved=json.loads(json.dumps(r))
 if t=='file_get' and 'data' in saved:
  raw=base64.b64decode(saved.pop('data'),validate=True);saved['readback']={'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
 if t=='rpc' and kw.get('method')=='screen.screenshot' and isinstance(saved.get('result'),dict):
  for key,value in list(saved['result'].items()):
   if isinstance(value,str) and len(value)>1024:
    raw=base64.b64decode(value);saved['result'][key]={'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
 if t=='file_put':q={**q,'data_b64':'omitted exact synthetic bytes'}
 rows.append({'request':q,'response':saved});return r

def shell(cmd):
 r=ctl('shell',cmd=prefix+cmd,timeout_ms=10000);assert r['ok'] and r['code']==0,r;return r['stdout']
def rpc(method,params={}):
 r=ctl('rpc',method=method,params=params);assert r['ok'],r;return r['result']
def health():
 c=http.client.HTTPConnection('127.0.0.1',port,timeout=15)
 try:
  c.request('GET','/v1/health',headers={'Authorization':'Bearer '+token});r=c.getresponse();data=r.read();assert r.status==200
  return json.loads(data)
 finally:c.close()
result={'target':target,'observations':rows}
try:
 h=health();assert h['binary_hash']=='152dc35bd219ebccffb71623cb9e732a8e88d9f257b87f42ac0e38258f7e1749';result['health_before']=h
 rpc('screen.unlock',{'timeout':10})
 app=rpc('apps.launch',{'bundle_id':'com.apple.Preferences'});assert app['pid']>0 and app['frontmost_verified'];result['restored_settings_launch']=app
 foreground=rpc('apps.foreground');result['restored_foreground']=foreground
 version=ctl('file_get',path='/System/Library/CoreServices/SystemVersion.plist');assert version['ok'];assert hashlib.sha256(base64.b64decode(version['data'])).hexdigest()=='2a2a4b045059edc470dffc0363071bd65a1a81aca81cbcfb9d4ac9f91a00aeb4'
 result['key_system_data_equal']=True
 paths=shell('test ! -e /var/root/vphone-b21-transfer && mkdir /var/root/vphone-b21-transfer; command -v lsof || true; ps -A -o pid=,ppid=,comm= | grep vphone-b13-api/vphoned')
 result['owned_api_processes']=paths
 downloads=[]
 for n in [8191,8192,8193,16383,16384,16385,1048576,8388608]:
  path='/var/root/vphone-b21-transfer/'+str(n)
  if n<=1048576:
   payload=bytes((i%251 for i in range(n)));r=ctl('file_put',path=path,data_b64=base64.b64encode(payload).decode(),transport='classic');assert r['ok'],r
   expected=hashlib.sha256(payload).hexdigest()
  else:
   shell('dd if=/dev/zero of='+path+' bs=1048576 count=8 2>/dev/null');expected=hashlib.sha256(bytes(n)).hexdigest()
  c=http.client.HTTPConnection('127.0.0.1',port,timeout=30)
  start=time.monotonic();count=0;digest=hashlib.sha256()
  try:
   c.request('GET','/v1/files/content?path='+urllib.parse.quote(path,safe=''),headers={'Authorization':'Bearer '+token})
   r=c.getresponse();assert r.status==200,r.status;headers=dict(r.getheaders())
   while True:
    chunk=r.read(1024 if n<1048576 else 16384)
    if not chunk:break
    count+=len(chunk);digest.update(chunk)
    if n==8388608:time.sleep(.001)
   assert count==n and digest.hexdigest()==expected
   downloads.append({'bytes':count,'sha256':digest.hexdigest(),'seconds':time.monotonic()-start,'headers':headers,'slow_read':n==8388608})
  finally:c.close()
 result['downloads']=downloads
 for _ in range(20):
  c=http.client.HTTPConnection('127.0.0.1',port,timeout=10)
  c.request('GET','/v1/files/content?path='+urllib.parse.quote('/var/root/vphone-b21-transfer/8388608',safe=''),headers={'Authorization':'Bearer '+token});r=c.getresponse();assert r.status==200;r.read(64);c.close()
 result['early_close_connections']=20
 time.sleep(1);assert health()['instance_id']==h['instance_id'];result['same_instance_after_transfers']=True
 for i in range(5):rpc('screen.screenshot')
 for i in range(5):rpc('services.status',{'label':'com.apple.SpringBoard'});rpc('processes.list',{'filter':'Preferences'})
 rpc('display.rotation');rpc('location.current')
 result['repeat_screenshot_count']=5;result['repeat_launchd_and_process_queries']=5
 r=ctl('file_put',path='/var/root/vphone-b21-transfer/nonutf8',data_b64=base64.b64encode(b'\xff\xfe\x00').decode(),transport='classic');assert r['ok']
 result['non_utf8_file_read']=rpc('files.read',{'path':'/var/root/vphone-b21-transfer/nonutf8'})
 result['health_after']=health();result['completed']=True
finally:
 text=json.dumps(result,ensure_ascii=False,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b21-runtime.json').write_text(text)
print({k:v for k,v in result.items() if k not in ['observations','downloads']})
