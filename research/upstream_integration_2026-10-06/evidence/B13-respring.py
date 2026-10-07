import hashlib,json,socket,time
from pathlib import Path
main=Path('/Users/qcz3840/github/vphone-cli');rows=[];target={'vm':'vm-new','pid':92943,'instance_id':'068574F6-DEF3-4910-88AB-57F5330C7A02'}
def call(t,**kw):
 q={'t':t,'screen':False,'target':target,**kw}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(90);s.connect(str(main/'vm-new/vphone.sock'));s.sendall(json.dumps(q).encode()+b'\n');b=b''
  while b'\n' not in b:
   c=s.recv(65536)
   if not c:raise RuntimeError('closed')
   b+=c
   if len(b)>8*1024*1024:raise RuntimeError('reply bound')
 r=json.loads(b.split(b'\n')[0]);rows.append({'request':q,'response':r});return r
call('rpc',method='agent.health',params={})
call('rpc',method='system.respring',params={'force':True})
time.sleep(5)
call('rpc',method='agent.health',params={})
call('rpc',method='device.screen',params={})
call('rpc',method='screen.unlock',params={'timeout':10})
call('rpc',method='device.screen',params={})
call('key',name='home')
time.sleep(1)
call('rpc',method='apps.foreground',params={})
output=Path('/private/tmp/vphone-b13-respring.json');assert not output.exists();output.write_text(json.dumps({'observations':rows,'new_host_source_activated':False,'passcode_supplied':False},indent=2)+'\n');print(rows)
