from pathlib import Path
import os,sys,json,hashlib,subprocess,time,re
mode=sys.argv[1];assert mode in ('normal','escaped')
e=Path('/private/tmp/vphone-b25-t46')/f'ui-final-{mode}'
a=json.loads((e/'artifact.json').read_text())
ready=(e/'ready').read_text();pid=int(re.search(r'pid=(\d+)',ready).group(1))
expected=(''.join(f'ordinary:{i}\n' for i in range(10000))+'ordinary ready\nkernel panic: ordinary final tail\n').encode()
candidates=[]
for p in (Path.home()/'Library/Logs/vphone-cli-launchpad').glob('command-*.log'):
 if p.stat().st_mtime >= (e/'artifact.json').stat().st_mtime:
  b=p.read_bytes()
  if b.startswith(b'ordinary:0\n'):candidates.append((p,b))
assert len(candidates)==1,[(str(p),len(b)) for p,b in candidates]
p,b=candidates[0]
raw=subprocess.check_output(['/bin/ps','-axo','pid,ppid,pgid,command'],text=True)
owned=[s.strip() for s in raw.splitlines() if f'T46-{mode}.app/Contents/' in s and '/bin/ps' not in s]
writer=[s for s in owned if s.split()[0]==str(pid)]
r={'time':time.time(),'log':str(p),'bytes':len(b),'lines':len(b.splitlines()),'sha256':hashlib.sha256(b).hexdigest(),'exact_expected':b==expected,'writer_pid':pid,'writer_alive':bool(writer),'matching_processes':owned,'artifact':a}
(e/'result.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r,indent=2))
assert b==expected and not owned
