"""运行本轮命令并按0.5秒检查磁盘；低于5 GiB终止自己的进程组。"""
import json,os,signal,subprocess,sys,time
from pathlib import Path
from datetime import datetime,timezone
here=Path(__file__).resolve().parent;code=here.parents[4]
label,*args=sys.argv[1:];assert label.replace('-','').isalnum() and args
work=code/'.build/research-b39';work.mkdir(exist_ok=True)
def free():
 s=os.statvfs(code);return s.f_bavail*s.f_frsize
minimum=free();assert minimum>=5*1024**3
start=time.monotonic();started_at=datetime.now(timezone.utc).isoformat();reason='completed'
env=dict(os.environ,CLANG_MODULE_CACHE_PATH=str(work/'module-cache'),SWIFT_MODULECACHE_PATH=str(work/'module-cache'),PYTHONDONTWRITEBYTECODE='1')
with (work/(label+'.log')).open('wb') as out:
 p=subprocess.Popen(args,cwd=code,env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
 while p.poll() is None:
  minimum=min(minimum,free())
  if minimum<5*1024**3:
   reason='disk_below_5_GiB';os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
   break
  time.sleep(.5)
if reason=='completed' and p.returncode<0:reason='signal_'+str(-p.returncode)
r={'command':args,'pid':p.pid,'pgid':p.pid,'started_at_utc':started_at,'ended_at_utc':datetime.now(timezone.utc).isoformat(),'exit':p.returncode,'reason':reason,'seconds':time.monotonic()-start,'minimum_free_bytes':minimum,'final_free_bytes':free()}
(here/(label+'-result.json')).write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r));sys.exit(75 if reason=='disk_below_5_GiB' else p.returncode)
