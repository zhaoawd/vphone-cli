import base64,hashlib,http.client,json,re,socket,time
from pathlib import Path
rows=[];marker='/private/var/mobile/Library/vphone-b10-acceptance-20261007.txt';expected='8c9377cc74e3e190b6934b8b0e6767daf488a79ec9f2e9ce60ccbb00313a5beb'
def call(t,**kw):
 q={'t':t,'screen':False,**kw}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(30);s.connect('/Users/qcz3840/github/vphone-cli/vm-new/vphone.sock');s.sendall(json.dumps(q).encode()+b'\n');buf=b''
  while b'\n' not in buf:
   c=s.recv(65536)
   if not c:raise RuntimeError('closed')
   buf+=c
 r=json.loads(buf.split(b'\n')[0]);rows.append({'request':q,'response':r});return r
try:
 r=call('capabilities');assert r['guest_connected']
 assert r['target']['instance_id']!='5F7970EC-0380-448B-ADDF-A0F11FD0F543'
 old=call('capabilities',target={'vm':'vm-new','instance_id':'5F7970EC-0380-448B-ADDF-A0F11FD0F543','pid':87653});assert old['code']=='target_mismatch' and old['operation_may_continue'] is False
 new=call('capabilities',target=r['target']);assert new['ok']
 r=call('file_get',path=marker);assert r['ok'];blob=base64.b64decode(r['data'],validate=True);r['sha256']=hashlib.sha256(blob).hexdigest();assert r['sha256']==expected
 r=call('file_get',path='/usr/bin/vphoned');assert r['ok'];blob=base64.b64decode(r.pop('data'),validate=True);r['readback']={'bytes':len(blob),'sha256':hashlib.sha256(blob).hexdigest()};assert r['readback']['sha256']=='306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001'
 r=call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; rm '+marker,timeout_ms=10000);assert r['ok'] and r['code']==0
 r=call('shell',cmd='test ! -e '+marker,timeout_ms=10000);assert r['ok'] and r['code']==0
 log=Path('/private/tmp/vphone-b10-restart-boot.log').read_text(errors='replace');m=re.search(r'\[api\] proxy listening on http://127\.0\.0\.1:(\d+)',log);assert m
 port=int(m[1]);results=[]
 for label,file in [('previous_boot_token','/private/tmp/vphone-b10-token'),('current_boot_token','/private/tmp/vphone-b10-restart-token')]:
  token=Path(file).read_text();conn=http.client.HTTPConnection('127.0.0.1',port,timeout=15)
  try:
   conn.request('GET','/v1/health',headers={'Host':f'127.0.0.1:{port}','Authorization':'Bearer '+token});reply=conn.getresponse();body=reply.read(16384);results.append({'authentication':label,'status':reply.status,'body':body.decode(errors='replace')})
  finally:conn.close()
 assert results[0]['status']==401
 rows.append({'http_auth_after_restart':results,'token_saved_to_evidence':False})
finally:Path('/private/tmp/vphone-b10-restart-check.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
