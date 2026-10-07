import base64,hashlib,json,socket,time
from pathlib import Path
vm=Path('/Users/qcz3840/github/vphone-cli/vm-new');root=Path('/Users/qcz3840/github/vphone-cli/research/artifacts/b09-vm-new-20261007')
records=[]
def call(t,**kw):
 req={'t':t,'screen':False,**kw}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(30);s.connect(str(vm/'vphone.sock'));s.sendall(json.dumps(req).encode()+b'\n');b=b''
  while b'\n' not in b:
   c=s.recv(65536)
   if not c:raise RuntimeError('closed before LF')
   b+=c
   if len(b)>16*1024**2:raise RuntimeError('response too large')
 r=json.loads(b.split(b'\n')[0])
 if t=='file_get' and r.get('data'):
  blob=base64.b64decode(r.pop('data'),validate=True)
  r['readback']={'bytes':len(blob),'sha256':hashlib.sha256(blob).hexdigest()}
  (root/'vphoned-readback').write_bytes(blob)
 records.append({'request':req,'response':r});return r
try:
 call('file_get',path='/usr/bin/vphoned')
 call('camera_status',generation='b09-read-only-status')
 call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; launchctl list | grep -E "vphoned|sshd"; ps -A -o pid=,comm= | grep -E "vphoned|Setup.app/Setup|SpringBoard"',timeout_ms=10000)
 call('swipe',x1=645.0,y1=2792.0,x2=645.0,y2=1400.0,ms=600)
 time.sleep(2)
 call('screenshot',path=str(root/'after-swipe.png'))
 for bid in ['com.apple.Preferences','com.apple.mobilesafari']:
  call('app_launch',bundle_id=bid)
  call('app_foreground')
 call('screenshot',path=str(root/'after-app-launches.png'))
 call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; ps -A -o pid=,comm= | grep -E "Preferences.app/Preferences|MobileSafari.app/MobileSafari|Setup.app/Setup"',timeout_ms=10000)
finally:
 for row in records:
  row['response'].pop('image',None)
 Path('/private/tmp/vphone-b09-followup.json').write_text(json.dumps(records,ensure_ascii=False,indent=2)+'\n')
