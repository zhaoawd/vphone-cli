import base64,hashlib,http.client,json,re,socket,time
from pathlib import Path
vm=Path('/Users/qcz3840/github/vphone-cli/vm-new');runtime=json.loads((vm/'.vphone-runtime.json').read_text());target={'vm':'vm-new','pid':70577,'instance_id':runtime['instanceID']};assert runtime['pid']==70577
rows=[]
def call(t,**kw):
 q={'t':t,'screen':False,'target':target,**kw}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(30);s.connect(str(vm/'vphone.sock'));s.sendall(json.dumps(q).encode()+b'\n');data=b''
  while b'\n' not in data:
   c=s.recv(65536)
   if not c:raise RuntimeError('closed')
   data+=c
   if len(data)>16*1024*1024:raise RuntimeError('bound')
 r=json.loads(data.split(b'\n')[0]);rows.append({'request':q,'response':r});return r
prefix='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; '
call('rpc',method='screen.unlock',params={'timeout':10})
call('rpc',method='input.tap',params={'x':200,'y':882})
Path('/private/tmp/vphone-b14-search-wake-tap.json').write_text(json.dumps(rows,indent=2)+'\n')
