import json,socket,sys
from pathlib import Path
vm=Path('/Users/qcz3840/github/vphone-cli/vm-new');r=json.loads((vm/'.vphone-runtime.json').read_text());p=json.loads(Path('/private/tmp/vphone-b16-restart-boot-process.json').read_text());assert r['pid']==p['pid']
q={'target':{'vm':'vm-new','pid':r['pid'],'instance_id':r['instanceID']},'screen':False,**json.loads(sys.argv[1])}
with socket.socket(socket.AF_UNIX) as s:
 s.settimeout(40);s.connect(str(vm/'vphone.sock'));s.sendall(json.dumps(q).encode()+b'\n');data=b''
 while b'\n' not in data:
  c=s.recv(65536)
  if not c:raise RuntimeError('closed')
  data+=c
  assert len(data)<32*1024*1024
response=json.loads(data.split(b'\n')[0]);p=Path(sys.argv[2]);assert not p.exists();p.write_text(json.dumps({'request':q,'response':response},indent=2)+'\n');print(response)
