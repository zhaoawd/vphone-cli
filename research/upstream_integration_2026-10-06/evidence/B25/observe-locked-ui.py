from pathlib import Path
import subprocess,time,json,hashlib,re
base=Path('/private/tmp/vphone-b25');e=Path('/private/tmp/vphone-b25-t46/ui-final-normal');a=json.loads((e/'artifact.json').read_text());pid=int(re.search(r'pid=(\d+)',(e/'ready').read_text())[1]);expected=(''.join(f'ordinary:{i}\n' for i in range(10000))+'ordinary ready\nkernel panic: ordinary final tail\n').encode()
raw=subprocess.check_output(['/bin/ps','-axo','pid,ppid,pgid,command'],text=True);owned=[s.strip() for s in raw.splitlines() if 'T46-normal.app/Contents/' in s and '/bin/ps' not in s]
logs=[]
for p in (Path.home()/'Library/Logs/vphone-cli-launchpad').glob('command-*.log'):
 if p.stat().st_mtime >= (e/'artifact.json').stat().st_mtime:
  b=p.read_bytes()
  if b.startswith(b'ordinary:0\n'):logs.append({'log':str(p),'bytes':len(b),'lines':len(b.splitlines()),'sha256':hashlib.sha256(b).hexdigest(),'exact_expected':b==expected})
r={'time':time.time(),'acceptance':'blocked_by_host_lock','quit_performed':False,'writer_pid':pid,'writer_alive':any(x.split()[0]==str(pid) for x in owned),'matching_processes':owned,'artifact':a,'logs':logs,'scope':'Final release app command logging observed. No quit acceptance; fixture may self-release after 120s.'}
(e/'locked-observation.json').write_text(json.dumps(r,indent=2)+'\n')
if len(logs)==1:r.update(logs[0]);(e/'result.json').write_text(json.dumps(r,indent=2)+'\n')
u={'final_state':'blocked_by_Mac_locked_before_quit','final_observation':r,'historical_pre_gate_ui':'ui-first-acceptance.json','historical_note':'Earlier ordinary and escaped UI checks passed before synchronous gate revision; not final release quit acceptance.','unlock_requested':True}
(base/'ui-acceptance.json').write_text(json.dumps(u,indent=2)+'\n');print(json.dumps(r,indent=2))
