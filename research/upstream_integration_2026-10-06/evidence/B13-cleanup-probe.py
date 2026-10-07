import base64,hashlib,json,re,shlex,socket,time
from pathlib import Path
rows=[];target={'vm':'vm-new','pid':92943,'instance_id':'068574F6-DEF3-4910-88AB-57F5330C7A02'}
def call(t,**kw):
 q={'t':t,'screen':False,'target':target,**kw}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(40);s.connect('/Users/qcz3840/github/vphone-cli/vm-new/vphone.sock');s.sendall(json.dumps(q).encode()+b'\n');data=b''
  while b'\n' not in data:
   part=s.recv(65536)
   if not part:raise RuntimeError('closed')
   data+=part
   if len(data)>8*1024*1024:raise RuntimeError('bound')
 r=json.loads(data.split(b'\n')[0]);rows.append({'request':q,'response':r});return r
r=call('shell',cmd='PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin; export PATH; ps -A -o pid=,ppid=,lstart=,comm= | grep -E \"vphoned|vphone-b13\"; launchctl print system/com.vphone.acceptance.b13.api',timeout_ms=10000)
call('capabilities')
Path('/private/tmp/vphone-b13-cleanup-probe.json').write_text(json.dumps(rows,indent=2)+'\n')
print(r)
