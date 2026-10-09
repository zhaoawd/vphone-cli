import base64,hashlib,http.client,json,re,socket,struct,time,urllib.parse,os
from pathlib import Path
vm=Path('/Users/qcz3840/github/vphone-cli/vm.backups/b21-restored-vm-new-20261009');run=json.loads((vm/'.vphone-runtime.json').read_text());target={'vm':vm.name,'pid':run['pid'],'instance_id':run['instanceID']};assert run['pid']==53680 and run['instanceID']=='822503AF-2684-43AC-8348-25248550D948'
port=int(re.search(r'\[api\] proxy listening on http://127\.0\.0\.1:(\d+)',Path('/private/tmp/vphone-b22-bound-boot.log').read_text(errors='replace'))[1]);token=Path('/private/tmp/vphone-b22-bound-token').read_text();rows=[]
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

def rpc_http(method,params={}):
 c=http.client.HTTPConnection('127.0.0.1',port,timeout=30)
 try:
  c.request('POST','/v1/rpc',body=json.dumps({'method':method,'params':params,'id':'b22'}),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
  r=c.getresponse();raw=r.read();reply=json.loads(raw)
  rows.append({'method':method,'status':r.status,'response_bytes':len(raw),'response_sha256':hashlib.sha256(raw).hexdigest()})
  assert r.status==200 and 'result' in reply,(r.status,reply)
  return reply['result']
 finally:c.close()
