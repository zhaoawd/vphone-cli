import base64,hashlib,json,socket,time
from pathlib import Path
vm=Path('/Users/qcz3840/github/vphone-cli/vm-new')
root=Path('/Users/qcz3840/github/vphone-cli/research/artifacts/b10-vm-new-restart-20261007')
root.mkdir(parents=True,exist_ok=False)
report={'vm':str(vm),'started_at':time.time(),'observations':[],'status':'running'}
def call(t,**kw):
 request={'t':t,'screen':False,**kw}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(20);s.connect(str(vm/'vphone.sock'));s.sendall(json.dumps(request).encode()+b'\n');b=b''
  while b'\n' not in b:
   c=s.recv(65536)
   if not c:raise RuntimeError('closed before LF')
   b+=c
   if len(b)>16*1024*1024:raise RuntimeError('response bound exceeded')
 r=json.loads(b.split(b'\n',1)[0]);image=r.pop('image',None)
 if image:
  data=base64.b64decode(image,validate=True);name=f'screen-{len(report["observations"]):02}.png'
  (root/name).write_bytes(data);r['saved_image']={'path':str(root/name),'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)}
 report['observations'].append({'request':request,'response':r});return r
try:
 deadline=time.monotonic()+150
 while True:
  try:
   r=call('capabilities')
   if r.get('guest_connected'):break
  except OSError as e:report['last_wait_error']=str(e)
  if time.monotonic()>deadline:raise RuntimeError('guest connect deadline')
  time.sleep(2)
 report['connected']=True
 call('screenshot',color=True)
 for t,kw in [('capabilities',{'target':{'instance_id':'b10-deliberate-stale-instance'}}),('app_foreground',{}),('app_list',{}),('shell',{'cmd':'PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; sw_vers; ps -A -o pid=,comm= | grep -E "SpringBoard|backboardd|Preferences|MobileSafari|Setup|vphoned"; shasum -a 256 /usr/bin/vphoned','timeout_ms':10000}),('camera_status',{}),('location_source_status',{}),('app_launch',{'transport':'api','bundle_id':'com.apple.Preferences'})]:
  call(t,**kw)
 report['status']='probed'
except BaseException as e:
 report.update(status='failed',error=f'{type(e).__name__}: {e}');raise
finally:
 report['ended_at']=time.time();Path('/private/tmp/vphone-b10-restart-runtime-probe.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
