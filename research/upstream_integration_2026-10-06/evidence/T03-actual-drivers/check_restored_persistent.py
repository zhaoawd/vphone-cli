"""T03 controlled acceptance: known marker readback and two system apps."""
import argparse,base64,hashlib,json,socket,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('vm',type=Path);p.add_argument('report',type=Path);a=p.parse_args()
report={'vm':str(a.vm),'started_at':time.time(),'status':'running','app_launches':[]}
def call(t,**args):
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(20);s.connect(str(a.vm/'vphone.sock'));s.sendall(json.dumps({'t':t,'screen':False,**args}).encode()+b'\n');b=b''
  while b'\n' not in b:
   c=s.recv(65536)
   if not c:raise RuntimeError('closed before LF')
   b+=c
   if len(b)>16*1024*1024:raise RuntimeError('response limit')
  r=json.loads(b.split(b'\n',1)[0])
  if not r.get('ok'):raise RuntimeError(str(r))
  return r
try:
 deadline=time.monotonic()+180
 while True:
  try:
   r=call('capabilities')
   if r.get('guest_connected'):
    report['capabilities']=r;break
  except (OSError,RuntimeError) as e:report['last_wait_error']=str(e)
  if time.monotonic()>deadline:raise RuntimeError('guest connection timeout')
  time.sleep(2)
 print('guest_connected',flush=True)
 r=call('file_get',path='/private/var/mobile/Library/vphone-t03-persistence-20261007.txt')
 b=base64.b64decode(r['data'],validate=True);h=hashlib.sha256(b).hexdigest()
 assert h=='15aefbeaf947f76ad669d0708ce18323ea5c98459f5bbe6929a3e8a2a1605f87','marker hash mismatch'
 report['marker']={'sha256':h,'size':len(b),'matched':True};print('marker_matched',flush=True)
 for bid in ('com.apple.Preferences','com.apple.mobilesafari'):
  launch=call('app_launch',bundle_id=bid);pid=launch.get('pid')
  assert isinstance(pid,int) and pid>0,launch
  shell=call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; kill -0 '+str(pid)+' && ps -p '+str(pid)+' -o comm=',timeout_ms=10000)
  assert shell.get('code')==0 and shell.get('stdout','').strip(),shell
  report['app_launches'].append({'bundle_id':bid,'pid':pid,'process_check':shell,'foreground_observation':call('app_foreground')})
  print('app_launch_verified '+bid,flush=True)
 probe=call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; sha256sum /private/var/tmp/vphone-t03-persistence-20261007.txt /private/var/mobile/Library/vphone-t03-persistence-20261007.txt',timeout_ms=10000)
 report['two_volume_probe_after_boot']=probe
 report['status']='passed'
except BaseException as e:
 report.update(status='failed',error=f'{type(e).__name__}: {e}');raise
finally:
 report['ended_at']=time.time();a.report.write_text(json.dumps(report,indent=2)+'\n')
