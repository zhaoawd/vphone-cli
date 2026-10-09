import hashlib,json,os,subprocess,time
from pathlib import Path
root=Path('/private/tmp/vphone-b27'); vm=Path('/Users/qcz3840/github/vphone-cli/vm-new')
prior=json.loads((root/'vm-exit.json').read_text());assert prior['pid']==81949
fifo=root/'serial-input';os.mkfifo(fifo,0o600);fd=os.open(fifo,os.O_RDWR)
args=json.loads((root/'vm-process.json').read_text())['arguments']
assert hashlib.sha256(Path(args[0]).read_bytes()).hexdigest()=='c8e8be423f47c2bc85a7bca5715c306a49cbacba1442a5882416493660a5f8ff'
start=time.monotonic()
with (root/'serial-boot.log').open('wb') as log:
 p=subprocess.Popen(args,stdin=fd,stdout=log,stderr=subprocess.STDOUT)
 (root/'serial-process.json').write_text(json.dumps({'pid':p.pid,'arguments':args,'stdin_fifo':str(fifo)},indent=2)+'\n')
 print('SERIAL_VM_STARTED pid='+str(p.pid),flush=True);rc=p.wait()
os.close(fd)
(root/'serial-exit.json').write_text(json.dumps({'pid':p.pid,'exit':rc,'seconds':time.monotonic()-start},indent=2)+'\n');print('SERIAL_VM_EXIT '+str(rc),flush=True)
