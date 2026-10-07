"""Hold original directory lock while a same-identity restored VM runs."""
import fcntl,json,os,stat,subprocess,sys
from pathlib import Path
source,target,log=map(Path,sys.argv[1:])
assert source.resolve()!=target.resolve()
fd=os.open(source,os.O_RDONLY|os.O_DIRECTORY)
try:
 fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
 files=[str(p) for p in source.rglob('*') if stat.S_ISREG(p.lstat().st_mode)]
 r=subprocess.run(['/usr/sbin/lsof','-t','--',*files],capture_output=True,text=True)
 assert r.returncode==1 and not r.stdout.strip(),'original has open regular files'
 assert (source/'config.plist').read_bytes()==(target/'config.plist').read_bytes(),'config identity differs'
 v=os.statvfs(source);free=v.f_bavail*v.f_frsize
 assert free>=12*1024**3,'require 10 GiB reserve plus 2 GiB boot headroom'
 print(json.dumps({'source_lock_held':True,'source_no_open_regular_files':True,'free_before_boot':free,'config_bytes_equal':True}),flush=True)
 candidate='/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/.build/vphone-cli.app/Contents/MacOS/vphone-vm'
 args=[candidate,'--config',str(target/'config.plist'),'--headless','--variant','exp','--vphoned-bin',str(target/'.vphoned.signed')]
 with log.open('xb') as out:
  p=subprocess.Popen(args,cwd=target,stdout=out,stderr=subprocess.STDOUT)
  print('restored_pid='+str(p.pid),flush=True)
  code=p.wait()
 print('restored_exit='+str(code),flush=True)
 raise SystemExit(code)
finally:
 os.close(fd)
