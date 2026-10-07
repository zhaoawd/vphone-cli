import base64,hashlib,json,socket
from pathlib import Path
main=Path('/Users/qcz3840/github/vphone-cli');target={'vm':'vm-new','pid':92943,'instance_id':'068574F6-DEF3-4910-88AB-57F5330C7A02'};rows=[]
for q0 in [{'t':'rpc','method':'device.screen','params':{}},{'t':'screenshot','color':True}]:
 q={'screen':False,'target':target,**q0}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(30);s.connect(str(main/'vm-new/vphone.sock'));s.sendall(json.dumps(q).encode()+b'\n');data=b''
  while b'\n' not in data:
   chunk=s.recv(65536)
   if not chunk:raise RuntimeError('closed')
   data+=chunk
   if len(data)>8*1024*1024:raise RuntimeError('bound')
 reply=json.loads(data.split(b'\n')[0])
 if 'image' in reply:
  image=base64.b64decode(reply.pop('image'),validate=True);ext='png' if image.startswith(b'\x89PNG') else 'jpg';p=Path('/private/tmp/vphone-b13-screen.'+ext);assert not p.exists();p.write_bytes(image)
  reply['saved_image']={'path':str(p),'bytes':len(image),'sha256':hashlib.sha256(image).hexdigest()}
 rows.append({'request':q,'response':reply})
p=Path('/private/tmp/vphone-b13-screen-observation.json');assert not p.exists();p.write_text(json.dumps(rows,indent=2)+'\n');print(rows)
