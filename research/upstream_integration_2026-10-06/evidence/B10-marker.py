import base64,hashlib,json,socket
from pathlib import Path
path='/private/var/mobile/Library/vphone-b10-acceptance-20261007.txt'
blob=b'vphone B10 acceptance\nsource 2387af2015f3e86dbddca43d9ba1a9b06344c4b0\n';rows=[]
def call(t,**kw):
 q={'t':t,'screen':False,**kw}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(30);s.connect('/Users/qcz3840/github/vphone-cli/vm-new/vphone.sock');s.sendall(json.dumps(q).encode()+b'\n');buf=b''
  while b'\n' not in buf:
   c=s.recv(65536)
   if not c:raise RuntimeError('closed')
   buf+=c
 r=json.loads(buf.split(b'\n')[0]);rows.append({'request':q,'response':r});assert r['ok'],r;return r
try:
 r=call('shell',cmd='test ! -e '+path,timeout_ms=10000);assert r['code']==0,'marker already exists'
 call('file_put',path=path,data_b64=base64.b64encode(blob).decode())
 r=call('file_get',path=path);read=base64.b64decode(r['data'],validate=True);assert read==blob
 r['sha256']=hashlib.sha256(read).hexdigest()
finally:Path('/private/tmp/vphone-b10-marker-before.json').write_text(json.dumps(rows,indent=2)+'\n')
