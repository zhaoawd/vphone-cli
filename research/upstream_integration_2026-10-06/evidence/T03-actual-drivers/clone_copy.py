"""T03 APFS clone control: stopped source, fresh destination, no fallback."""
import ctypes,fcntl,json,os,subprocess,sys,time
from pathlib import Path
from controlled_copy import inventory,sha,free_bytes
source,destination,report_path,guard=map(Path,sys.argv[1:]);source=source.resolve(strict=True)
assert source not in destination.parents and source!=destination
assert not destination.exists(), 'fresh destination only'
destination.parent.mkdir(parents=True,exist_ok=True)
assert source.stat().st_dev==destination.parent.stat().st_dev,'same APFS volume required; no fallback'
stage=destination.with_name(destination.name+'.staging');fd=os.open(source,os.O_RDONLY|os.O_DIRECTORY)
r={'source':str(source),'destination':str(destination),'method':'APFS clonefile; copy-on-write; no physical independence; no dense fallback','status':'preparing','started_at':time.time()}
lib=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True);lib.clonefile.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_int];lib.clonefile.restype=ctypes.c_int
try:
 fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);before=inventory(source)
 handles=subprocess.run(['/usr/sbin/lsof','-t','--',*[str(source/n) for n,m in before.items() if m['kind']=='file']],capture_output=True,text=True)
 assert handles.returncode==1 and not handles.stdout.strip(),'source has open handles'
 stage.mkdir(mode=0o700)
 for n,m in before.items():
  assert free_bytes(guard)>=12*1024**3,'space guard before clone'
  if m['kind']=='directory':(stage/n).mkdir(mode=0o700)
  else:
   if lib.clonefile(os.fsencode(source/n),os.fsencode(stage/n),0)!=0:
    raise OSError(ctypes.get_errno(),'clonefile failed; no fallback',n)
 for n,m in reversed(list(before.items())):
  os.chmod(stage/n,m['mode']);os.utime(stage/n,ns=(m['mtime_ns'],m['mtime_ns']))
 records={}
 for n,m in before.items():
  if m['kind']=='file':
   s,t=sha(source/n),sha(stage/n);assert s==t,'SHA mismatch: '+n
   assert (source/n).stat().st_ino!=(stage/n).stat().st_ino,'inode must differ'
   records[n]={'sha256':s,'size':m['size']};print('verified '+n,flush=True)
 assert inventory(source)==before,'source metadata changed'
 after=inventory(stage);assert set(after)==set(before),'path set mismatch'
 for n,m in before.items():
  keys=('kind','size','mode','mtime_ns') if m['kind']=='file' else ('kind','mode','mtime_ns')
  assert all(after[n][k]==m[k] for k in keys),'metadata mismatch: '+n
 os.rename(stage,destination);r.update(status='verified',files=records)
except BaseException as e:
 r.update(status='failed',error=f'{type(e).__name__}: {e}');raise
finally:
 r['ended_at']=time.time();report_path.write_text(json.dumps(r,indent=2)+'\n');os.close(fd)
