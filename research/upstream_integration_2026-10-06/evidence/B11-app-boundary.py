import base64,hashlib,json,socket
from pathlib import Path
rows=[]
target={'vm':'vm-new','pid':92943,'instance_id':'068574F6-DEF3-4910-88AB-57F5330C7A02'}
def call(t,**kw):
 q={'t':t,'screen':False,'target':target,**kw}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(30);s.connect('/Users/qcz3840/github/vphone-cli/vm-new/vphone.sock');s.sendall(json.dumps(q).encode()+b'\n');b=b''
  while b'\n' not in b:
   c=s.recv(65536)
   if not c:raise RuntimeError('closed')
   b+=c
   if len(b)>4*1024*1024:raise RuntimeError('reply bound')
 r=json.loads(b.split(b'\n')[0]);rows.append({'request':q,'response':r});return r
def shot(name):
 r=call('screenshot',color=True)
 if 'image' in r:
  b=base64.b64decode(r.pop('image'),validate=True);path=Path('/private/tmp/vphone-b11-'+name+'.jpg');path.write_bytes(b);r['saved_image']={'path':str(path),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
try:
 r=call('app_list');r['apps']=[a for a in r.get('apps',[]) if a.get('bundle_id') in ['com.apple.Preferences','com.apple.mobilesafari']]
 call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; uiopen --help; ls -l /var/jb/usr/bin/uiopen /Applications/Preferences.app/Preferences /Applications/MobileSafari.app/MobileSafari; ls -l /var/log; launchctl list | grep -E "frontboard|runningboard|SpringBoard|vphoned"',timeout_ms=10000)
 shot('before-tap')
 call('tap',x=798,y=1956,screen=True,delay=2000)
 # Preserve screen bytes separately, with their original digest.
 r=rows[-1]['response']
 if 'image' in r:
  b=base64.b64decode(r.pop('image'),validate=True);path=Path('/private/tmp/vphone-b11-tap-response.jpg');path.write_bytes(b);r['saved_image']={'path':str(path),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
 call('app_foreground')
 call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; ps -A -o pid=,comm= | grep -E "Preferences.app/Preferences|MobileSafari.app/MobileSafari"',timeout_ms=10000)
 shot('after-tap')
finally:Path('/private/tmp/vphone-b11-app-boundary.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
