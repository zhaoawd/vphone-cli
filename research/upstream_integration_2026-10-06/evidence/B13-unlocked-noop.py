import base64,hashlib,json,socket
from pathlib import Path
rows=[];target={'vm':'vm-new','pid':92943,'instance_id':'068574F6-DEF3-4910-88AB-57F5330C7A02'}
for q0 in [{'t':'rpc','method':'screen.unlock','params':{'timeout':10}},{'t':'rpc','method':'screen.unlock','params':{'timeout':10}},{'t':'rpc','method':'device.screen','params':{}},{'t':'screenshot','color':True},{'t':'rpc','method':'agent.health','params':{}}]:
 q={'screen':False,'target':target,**q0}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(30);s.connect('/Users/qcz3840/github/vphone-cli/vm-new/vphone.sock');s.sendall(json.dumps(q).encode()+b'\n');buf=b''
  while b'\n' not in buf:
   chunk=s.recv(65536)
   if not chunk:raise RuntimeError('closed')
   buf+=chunk
   if len(buf)>8*1024*1024:raise RuntimeError('bound')
 reply=json.loads(buf.split(b'\n')[0])
 if 'image' in reply:
  b=base64.b64decode(reply.pop('image'),validate=True);p=Path('/private/tmp/vphone-b13-unlocked-screen.jpg');assert not p.exists();p.write_bytes(b);reply['saved_image']={'path':str(p),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
 rows.append({'request':q,'response':reply})
p=Path('/private/tmp/vphone-b13-unlocked-noop.json');assert not p.exists();p.write_text(json.dumps({'observations':rows,'password_supplied':False,'automatic_host_worker_activated':False},indent=2)+'\n');print([r['response'] for r in rows if r['request']['t']=='rpc'])
