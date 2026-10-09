import hashlib,json,os,signal,subprocess,time
from pathlib import Path
root=Path('/private/tmp/vphone-b29-runtime')
lib=Path('/Users/qcz3840/github/vphone-cli');src=lib/'vm-new';dst=lib/'vm-roothide-20261010'
cli=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/.build/vphone-cli.app/Contents/MacOS/vphone-cli')
def free():
 s=os.statvfs(lib);return s.f_bavail*s.f_frsize
assert free()>=5*1024**3
assert not dst.exists()
assert hashlib.sha256(cli.read_bytes()).hexdigest()=='8d18f0e6a65dcd963c41a2c81c43f56922f425f708b0dba086778c7bbf458714'
before={n:hashlib.sha256((src/n).read_bytes()).hexdigest() for n in ['config.plist','.vphoned.signed','restore-info.json','nvram.bin']}
disk=src/'Disk.img';st=disk.stat();before['disk_stat']={'size':st.st_size,'mtime_ns':st.st_mtime_ns,'blocks':st.st_blocks,'inode':st.st_ino}
(root/'source-before.json').write_text(json.dumps(before,indent=2)+'\n')
start=time.time();minimum=free();stopped=False
with (root/'clone.log').open('wb') as out:
 p=subprocess.Popen([str(cli),'vm','clone','--library-root',str(lib),src.name,dst.name],stdout=out,stderr=subprocess.STDOUT)
 while p.poll() is None:
  minimum=min(minimum,free())
  if minimum<5*1024**3:
   stopped=True;p.send_signal(signal.SIGINT);break
  time.sleep(.25)
 if stopped:
  try:p.wait(timeout=30)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=10)
 code=p.wait()
result={'exit':code,'elapsed':time.time()-start,'minimum_free_bytes':minimum,'final_free_bytes':free(),'stopped_for_disk':stopped,'destination':str(dst)}
(root/'clone-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
assert code==0 and not stopped
assert {n:hashlib.sha256((src/n).read_bytes()).hexdigest() for n in before if n!='disk_stat'}=={n:v for n,v in before.items() if n!='disk_stat'}
assert disk.stat().st_mtime_ns==st.st_mtime_ns
assert not (dst/'.vphone-runtime.json').exists() and not (dst/'vphone.sock').exists()
