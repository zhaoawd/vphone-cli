import base64,hashlib,http.client,json,re,socket,time
from pathlib import Path
main=Path('/Users/qcz3840/github/vphone-cli');rows=[];target={'vm':'vm-new','pid':92943,'instance_id':'068574F6-DEF3-4910-88AB-57F5330C7A02'}
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
prefix='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; '
r=call('shell',cmd=prefix+'VPHONE_API_ONLY=1 /var/root/vphone-b13-api/vphoned </dev/null >/var/root/vphone-b13-api/direct.log 2>&1 & echo $!',timeout_ms=10000)
port=int(re.search(r'\[api\] proxy listening on http://127\.0\.0\.1:(\d+)',Path('/private/tmp/vphone-b10-restart-boot.log').read_text(errors='replace'))[1]);token=Path('/private/tmp/vphone-b10-restart-token').read_text();probes=[]
for i in range(8):
 time.sleep(2);conn=http.client.HTTPConnection('127.0.0.1',port,timeout=10)
 try:
  conn.request('GET','/v1/health',headers={'Authorization':'Bearer '+token});resp=conn.getresponse();body=resp.read();item={'status':resp.status,'body':body.decode('utf-8',errors='replace')};probes.append(item)
  if resp.status==200:break
 except Exception as e:probes.append({'error':str(e)})
 finally:conn.close()
call('environment_status')
call('shell',cmd=prefix+'tail -n 30 /var/root/vphone-b13-api/direct.log; ps -A -o pid=,ppid=,comm= | grep -E "vphoned|vphone-b13"',timeout_ms=10000)
x={'probes':probes,'observations':rows,'classic_host_still_frozen':True};serialized=json.dumps(x,indent=2)+'\n';assert token not in serialized
output=Path('/private/tmp/vphone-b13-api-direct.json');assert not output.exists();output.write_text(serialized)
print(x)
