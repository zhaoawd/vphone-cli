import json,socket,sys,time
from pathlib import Path
root=Path('/private/tmp/vphone-b27');vm=Path('/Users/qcz3840/github/vphone-cli/vm-new')
name=sys.argv[1];q=json.loads((root/(name+'-request.json')).read_text());runtime=json.loads((vm/'.vphone-runtime.json').read_text());assert runtime['pid']==json.loads((root/'vm-process.json').read_text())['pid']
q.update(target={'vm':vm.name,'pid':runtime['pid'],'instance_id':runtime['instanceID']},screen=False)
start=time.monotonic()
try:
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(35);s.connect(str(vm/'vphone.sock'));s.sendall(json.dumps(q).encode()+b'\n');data=b''
  while b'\n' not in data:
   b=s.recv(65536)
   if not b:raise RuntimeError('closed')
   data+=b;assert len(data)<16*1024*1024
 response=json.loads(data.split(b'\n')[0]);result={'request':q,'response':response,'seconds':time.monotonic()-start}
except Exception as e:result={'request':q,'error':str(e),'seconds':time.monotonic()-start}
(root/(name+'.json')).write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
