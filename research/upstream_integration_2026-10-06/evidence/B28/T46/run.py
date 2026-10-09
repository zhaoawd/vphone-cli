import hashlib,json,os,re,signal,socket,subprocess,sys,threading,time
from pathlib import Path
root=Path('/private/tmp/vphone-b28-t46-ui/run2');root.mkdir(exist_ok=True);vm=Path('/Users/qcz3840/github/vphone-cli/vm-new');binary=Path('/private/tmp/vphone-b26-runtime/vphone-cli.app/Contents/MacOS/vphone-vm');assert hashlib.sha256(binary.read_bytes()).hexdigest()=='c8e8be423f47c2bc85a7bca5715c306a49cbacba1442a5882416493660a5f8ff'
assert not (root/'process.json').exists();before={n:hashlib.sha256((vm/n).read_bytes()).hexdigest() for n in ['config.plist','.vphoned.signed','restore-info.json']};(root/'vm-before.json').write_text(json.dumps(before,indent=2)+'\n')
stop=threading.Event();p=None;reader=None;start=time.monotonic();rows=[]
def interrupted(sig,frame):
 stop.set();(root/'interrupt.json').write_text(json.dumps({'signal':sig,'time':time.time(),'elapsed':time.monotonic()-start})+'\n')
 if p is not None and p.poll() is None:p.send_signal(signal.SIGINT)
signal.signal(signal.SIGINT,interrupted);signal.signal(signal.SIGTERM,interrupted)
def control(q):
 runtime=json.loads((vm/'.vphone-runtime.json').read_text());assert runtime['pid']==p.pid;q=dict(q,target={'vm':vm.name,'pid':p.pid,'instance_id':runtime['instanceID']},screen=False)
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(20);s.connect(str(vm/'vphone.sock'));s.sendall(json.dumps(q).encode()+b'\n');data=b''
  while b'\n' not in data:
   b=s.recv(65536)
   if not b:raise RuntimeError('closed')
   data+=b;assert len(data)<4*1024*1024
 return json.loads(data.split(b'\n')[0])
def drain():
 with (root/'vm-console-redacted.log').open('wb') as log:
  for line in iter(p.stdout.readline,b''):
   if b'[location] got location:' in line:line=b'[location] got location: [coordinates omitted]\n'
   log.write(line);log.flush()
try:
 args=[str(binary),'--config',str(vm/'config.plist'),'--variant','exp','--headless','--vphoned-bin',str(vm/'.vphoned.signed'),'--no-vphoned-update']
 p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (root/'process.json').write_text(json.dumps({'bridge_pid':os.getpid(),'vm_pid':p.pid,'arguments':args,'start_time':time.time()},indent=2)+'\n')
 reader=threading.Thread(target=drain);reader.start()
 deadline=time.monotonic()+120;caps=None
 while not stop.is_set() and p.poll() is None and time.monotonic()<deadline:
  try:
   caps=control({'t':'capabilities'})
   if caps.get('guest_connected'):break
  except Exception:pass
  stop.wait(0.5)
 assert caps and caps.get('guest_connected') and not stop.is_set(),'classic not ready'
 (root/'capabilities.json').write_text(json.dumps(caps,indent=2)+'\n')
 expected=b'';raw=b''
 for count in (256,10000):
  cmd=r"""i=0; while [ "$i" -lt %d ]; do printf '\033[32mvm-ui:%d:%%05d\033[0m\r\n' "$i"; i=$((i+1)); done"""%(count,count)
  if count==10000:cmd+=r"""; printf '\033[31mkernel panic: B28 controlled guest tail\033[0m'"""
  tick=time.monotonic();response=control({'t':'shell','cmd':cmd,'timeout_ms':15000});elapsed=time.monotonic()-tick;data=response.pop('stdout','').encode();assert response.get('code')==0 and not response.get('truncated') and not response.get('timed_out'),response
  expected+=b''.join(('vm-ui:%d:%05d\n'%(count,i)).encode() for i in range(count))
  raw+=data;(root/('guest-%d.stdout'%count)).write_bytes(data)
  sys.stdout.buffer.write(data);sys.stdout.buffer.flush()
  rows.append({'lines':count,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'classic_seconds':elapsed,'response':response,'forwarded_at':time.time()})
 expected+=b'kernel panic: B28 controlled guest tail\n'
 (root/'expected-ui.log').write_bytes(expected);(root/'raw-forwarded.stdout').write_bytes(raw);(root/'measurements.json').write_text(json.dumps(rows,indent=2)+'\n');(root/'ready.json').write_text(json.dumps({'time':time.time(),'pid':os.getpid(),'vm_pid':p.pid,'expected_bytes':len(expected),'expected_sha256':hashlib.sha256(expected).hexdigest(),'tail_from_guest':True,'tail_is_controlled_text_not_actual_panic':True},indent=2)+'\n')
 # Continue actual guest output while the UI performs termination.
 # The prefetched actual guest fragment is flushed after SIGINT to verify EOF draining.
 tail_response=control({'t':'shell','cmd':r"printf '\033[31mkernel panic: B28 controlled EOF tail\033[0m'",'timeout_ms':15000})
 assert tail_response.get('code')==0 and not tail_response.get('truncated') and not tail_response.get('timed_out')
 tail=tail_response['stdout'].encode(); (root/'eof-tail.stdout').write_bytes(tail)
 (root/'active.json').write_text(json.dumps({'time':time.time(),'bridge_pid':os.getpid(),'vm_pid':p.pid})+'\n')
 deadline=time.monotonic()+240; iteration=0
 while not stop.is_set() and not (root/'release').exists() and time.monotonic()<deadline:
  cmd=r"""i=0; while [ "$i" -lt 1000 ]; do printf '\033[32mvm-active:%d:%%05d\033[0m\r\n' "$i"; i=$((i+1)); done"""%iteration
  tick=time.monotonic()
  try: response=control({'t':'shell','cmd':cmd,'timeout_ms':15000})
  except Exception:
   if stop.is_set():break
   raise
  data=response.get('stdout','').encode()
  if response.get('code')==0 and not response.get('truncated') and not response.get('timed_out'):
   sys.stdout.buffer.write(data);sys.stdout.buffer.flush();raw+=data
   if iteration==0: expected=expected[:-1] # initial unterminated guest tail joins the next line
   expected+=b''.join(('vm-active:%d:%05d\n'%(iteration,i)).encode() for i in range(1000))
   rows.append({'active_iteration':iteration,'bytes':len(data),'classic_seconds':time.monotonic()-tick,'forwarded_at':time.time()})
   (root/'active-progress.json').write_text(json.dumps({'iterations':iteration+1,'forwarded_at':time.time(),'bytes':len(raw)})+'\n')
   iteration+=1
  stop.wait(0.05)
 sys.stdout.buffer.write(tail);sys.stdout.buffer.flush();raw+=tail
 expected+=b'kernel panic: B28 controlled EOF tail\n'
 (root/'expected-ui.log').write_bytes(expected);(root/'raw-forwarded.stdout').write_bytes(raw);(root/'measurements.json').write_text(json.dumps(rows,indent=2)+'\n')
 (root/'bridge-output-complete.json').write_text(json.dumps({'time':time.time(),'interrupted':stop.is_set(),'iterations':iteration})+'\n')
 if not stop.is_set() and p.poll() is None:p.send_signal(signal.SIGINT)
except Exception as error:
 (root/'error.json').write_text(json.dumps({'error':str(error),'type':type(error).__name__})+'\n')
finally:
 if p is not None:
  if p.poll() is None:
   if not stop.is_set():p.send_signal(signal.SIGINT)
   try:p.wait(timeout=45)
   except subprocess.TimeoutExpired:p.kill();p.wait();(root/'forced-kill.json').write_text('{"VM_force_killed":true}\n')
  if reader is not None:reader.join(timeout=10)
  (root/'vm-exit.json').write_text(json.dumps({'exit':p.returncode,'seconds':time.monotonic()-start,'reader_alive':reader.is_alive() if reader else None},indent=2)+'\n')
 after={n:hashlib.sha256((vm/n).read_bytes()).hexdigest() for n in before};(root/'vm-after.json').write_text(json.dumps({'hashes':after,'preserved':before==after},indent=2)+'\n')
sys.exit(130 if stop.is_set() else (1 if (root/'error.json').exists() else 0))
