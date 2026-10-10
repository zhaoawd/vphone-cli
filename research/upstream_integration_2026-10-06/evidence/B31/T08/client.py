import http.client,json,os,re,socket,time
from pathlib import Path
root=Path('/private/tmp/vphone-b31-t08');run=root/'runs/20261010-081434-8fc66e87';vm=Path('/Users/qcz3840/github/vphone-cli/vm-roothide-20261010')
token=(run/'private-token').read_text();rows=[]
def check():
 assert not (run/'exit.json').exists()
 st=os.statvfs(vm);assert st.f_bavail*st.f_frsize>=5*1024**3
 runtime=json.loads((vm/'.vphone-runtime.json').read_text());assert runtime['pid']==json.loads((run/'process.json').read_text())['vm_pid'];return runtime
def ctl(t,**kw):
 rt=check();q=dict(t=t,screen=False,target={'vm':vm.name,'pid':rt['pid'],'instance_id':rt['instanceID']},**kw)
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(45);s.connect(str(vm/'vphone.sock'));s.sendall(json.dumps(q).encode()+b'\n');b=b''
  while b'\n' not in b:
   v=s.recv(65536)
   if not v:raise RuntimeError('closed')
   b+=v;assert len(b)<16*1024*1024
 return json.loads(b.split(b'\n')[0])
def rpc(method,params=None):
 check();port=int(re.search(r'\[api\] proxy listening on http://127.0.0.1:(\d+)',(run/'console-redacted.log').read_text(errors='replace'))[1]);c=http.client.HTTPConnection('127.0.0.1',port,timeout=30);start=time.monotonic()
 try:
  c.request('POST','/v1/rpc',json.dumps({'method':method,'params':params or {},'id':'B30'}),{'Authorization':'Bearer '+token,'Content-Type':'application/json'});r=c.getresponse();q={'method':method,'params':params or {},'http_status':r.status,'reply':json.loads(r.read()),'seconds':time.monotonic()-start};assert token not in json.dumps(q);rows.append(q);return q
 finally:c.close()
def serial(command):
 check();assert len(command.encode())<4000
 fd=os.open(run/'serial-input',os.O_WRONLY|os.O_NONBLOCK)
 try:os.write(fd,(command+'\n').encode())
 finally:os.close(fd)
def save(name,data):
 text=json.dumps(data,indent=2)+'\n';assert token not in text;(root/name).write_text(text)
