import json,socket,time
from pathlib import Path
root=Path('/Users/qcz3840/github/vphone-cli/research/artifacts/b09-vm-new-20261007');rows=[]
def call(t,**kw):
 q={'t':t,'screen':False,**kw}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(30);s.connect('/Users/qcz3840/github/vphone-cli/vm-new/vphone.sock');s.sendall(json.dumps(q).encode()+b'\n');data=b''
  while b'\n' not in data:
   c=s.recv(65536)
   if not c:raise RuntimeError('closed')
   data+=c
 r=json.loads(data.split(b'\n')[0]);r.pop('image',None);rows.append({'request':q,'response':r});return r
try:
 call('tap',x=790.0,y=1938.0)
 time.sleep(3)
 call('screenshot',path=str(root/'settings-manual.png'))
 call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; ps -A -o pid=,comm= | grep -E "Preferences.app/Preferences|MobileSafari.app/MobileSafari"; uiopen --help 2>&1',timeout_ms=10000)
 call('app_foreground')
 call('key',name='home')
 time.sleep(1)
 call('screenshot',path=str(root/'home-after-settings.png'))
finally:Path('/private/tmp/vphone-b09-manual-apps.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
