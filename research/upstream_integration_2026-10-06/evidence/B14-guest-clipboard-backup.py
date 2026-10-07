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
r=call('rpc',method='clipboard.get',params={})
assert r['ok']
path=Path('/private/tmp/vphone-b14-private-guest-clipboard.json')
fd=__import__('os').open(path,__import__('os').O_WRONLY|__import__('os').O_CREAT|__import__('os').O_EXCL,0o600)
with __import__('os').fdopen(fd,'w') as f:f.write(json.dumps(r)+'\n')
print({'guest_clipboard_field_names':sorted(r['result'].keys()),'types':r['result'].get('types'),'item_count':r['result'].get('item_count')})
