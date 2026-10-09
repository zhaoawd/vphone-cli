import hashlib,json,os,signal,subprocess,threading,time,secrets
from pathlib import Path
root=Path('/private/tmp/vphone-b29-runtime');vm=Path('/Users/qcz3840/github/vphone-cli/vm-roothide-20261010')
binary=Path('/private/tmp/vphone-b26-runtime/vphone-cli.app/Contents/MacOS/vphone-vm')
def free():
 s=os.statvfs(vm);return s.f_bavail*s.f_frsize
assert free()>=5*1024**3
assert hashlib.sha256(binary.read_bytes()).hexdigest()=='c8e8be423f47c2bc85a7bca5715c306a49cbacba1442a5882416493660a5f8ff'
assert not (root/'process.json').exists()
stop=threading.Event();reason='requested';minimum=free();p=None
def interrupted(sig,frame):stop.set()
signal.signal(signal.SIGINT,interrupted);signal.signal(signal.SIGTERM,interrupted)
fifo=root/'serial-input';os.mkfifo(fifo,0o600);fd=os.open(fifo,os.O_RDWR)
def drain():
 with (root/'vm-console-redacted.log').open('wb') as log:
  for line in iter(p.stdout.readline,b''):
   if b'[location] got location:' in line:line=b'[location] got location: [coordinates omitted]\n'
   log.write(line);log.flush()
start=time.monotonic()
try:
 args=[str(binary),'--config',str(vm/'config.plist'),'--variant','exp','--headless','--vphoned-bin',str(vm/'.vphoned.signed'),'--no-vphoned-update','--api-listen','127.0.0.1:0']
 token_path=root/'token'
 if not token_path.exists():
  tf=os.open(token_path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
  os.write(tf,secrets.token_urlsafe(32).encode());os.close(tf)
 env=dict(os.environ,VPHONE_API_TOKEN=token_path.read_text(),NSUnbufferedIO='YES')
 p=subprocess.Popen(args,stdin=fd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=env)
 (root/'process.json').write_text(json.dumps({'monitor_pid':os.getpid(),'vm_pid':p.pid,'arguments':args,'start_time':time.time()},indent=2)+'\n')
 reader=threading.Thread(target=drain);reader.start()
 while p.poll() is None and not stop.is_set() and not (root/'release').exists():
  minimum=min(minimum,free())
  if minimum<5*1024**3:reason='disk_below_5_GiB';break
  if time.monotonic()-start>7200:reason='two_hour_limit';break
  stop.wait(1)
finally:
 if p is not None:
  if p.poll() is None:
   p.send_signal(signal.SIGINT)
   try:p.wait(timeout=45)
   except subprocess.TimeoutExpired:
    p.kill();p.wait();reason+=';forced_kill'
  reader.join(timeout=10)
  (root/'vm-exit.json').write_text(json.dumps({'exit':p.returncode,'reason':reason,'minimum_free_bytes':minimum,'final_free_bytes':free(),'seconds':time.monotonic()-start},indent=2)+'\n')
 os.close(fd)
