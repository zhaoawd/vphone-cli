import json,socket,sys
from pathlib import Path
q={'target':{'vm':'vm-new','pid':70577,'instance_id':'E7F7D876-BA0B-4E08-BD53-B1F48E877AD4'},'screen':False,**json.loads(sys.argv[1])}
with socket.socket(socket.AF_UNIX) as s:
 s.settimeout(40);s.connect('/Users/qcz3840/github/vphone-cli/vm-new/vphone.sock');s.sendall(json.dumps(q).encode()+b'\n');data=b''
 while b'\n' not in data:
  c=s.recv(65536)
  if not c:raise RuntimeError('closed')
  data+=c
  if len(data)>32*1024*1024:raise RuntimeError('bound')
response=json.loads(data.split(b'\n')[0]);p=Path(sys.argv[2]);assert not p.exists();p.write_text(json.dumps({'request':q,'response':response},indent=2)+'\n');print(response)
