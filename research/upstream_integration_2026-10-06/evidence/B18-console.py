import hashlib,json,re,socket,sys
from pathlib import Path
vm=Path('/Users/qcz3840/github/vphone-cli/vm-new');pid=61914
print('VM_CONTROL_READY',flush=True)
for line in sys.stdin:
 try:
  v=json.loads(line);name=v.pop('evidence');assert re.fullmatch('[a-z0-9-]+',name)
  p=Path('/private/tmp/vphone-b18-'+name+'.json');assert not p.exists()
  runtime=json.loads((vm/'.vphone-runtime.json').read_text());assert runtime['pid']==pid
  q={'target':{'vm':'vm-new','pid':pid,'instance_id':runtime['instanceID']},'screen':False,**v};assert q['t'] in ['rpc','type','key','shell','capabilities','environment_status','file_get']
  with socket.socket(socket.AF_UNIX) as s:
   s.settimeout(40);s.connect(str(vm/'vphone.sock'));s.sendall(json.dumps(q).encode()+b'\n');data=b''
   while b'\n' not in data:
    b=s.recv(65536)
    if not b:raise RuntimeError('closed')
    data+=b;assert len(data)<32*1024*1024
  response=json.loads(data.split(b'\n')[0])
  if q['t']=='file_get' and 'data' in response:
   import base64
   raw=base64.b64decode(response.pop('data'),validate=True);response['bytes']=len(raw);response['sha256']=hashlib.sha256(raw).hexdigest()
  saved=json.dumps({'request':q,'response':response},indent=2)+'\n';assert Path('/private/tmp/vphone-b18-restart-token').read_text() not in saved;p.write_text(saved);print(response,flush=True)
 except Exception as e:print({'error':str(e)},flush=True)
