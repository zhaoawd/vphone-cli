import json,socket,sys
from pathlib import Path
vm=Path(sys.argv[1]);request=json.loads(sys.argv[2])
with socket.socket(socket.AF_UNIX) as s:
 s.settimeout(30);s.connect(str(vm/'vphone.sock'));s.sendall(json.dumps(request).encode()+b'\n');b=b''
 while b'\n' not in b:
  c=s.recv(65536)
  if not c:raise RuntimeError('closed before LF')
  b+=c
 r=json.loads(b.split(b'\n')[0]);r.pop('image',None);print(json.dumps(r,ensure_ascii=False))
 if not r.get('ok'):raise SystemExit(1)
