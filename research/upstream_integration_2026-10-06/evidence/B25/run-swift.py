from pathlib import Path
import subprocess,time,json,threading
base=Path('/private/tmp/vphone-b25');repo=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');started=time.monotonic();sampled=False;sampler=None
p=subprocess.Popen(['make','test_swift'],cwd=repo,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
def sample_owned():
 try:
  raw=subprocess.check_output(['ps','-axo','pid,ppid,command'],text=True)
  rows=[]
  for line in raw.splitlines()[1:]:
   cells=line.strip().split(None,2)
   if len(cells)==3:rows.append((int(cells[0]),int(cells[1]),cells[2]))
  owned={p.pid}
  for _ in range(12):
   old=len(owned);owned.update(pid for pid,ppid,_ in rows if ppid in owned)
   if old==len(owned):break
  matches=[row for row in rows if row[0] in owned and '.xctest/Contents/MacOS/' in row[2]]
  (base/'swift-failure-processes.json').write_text(json.dumps({'make_pid':p.pid,'owned_test_runners':matches},indent=2)+'\n')
  for pid,_,_ in matches:
   out=base/f'swift-failure-sample-{pid}.txt'
   r=subprocess.run(['/usr/bin/sample',str(pid),'2','-file',str(out)],capture_output=True,text=True,timeout=10)
   (base/f'swift-failure-sample-{pid}.json').write_text(json.dumps({'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr},indent=2)+'\n')
 except Exception as e:(base/'swift-failure-sampling-error.txt').write_text(repr(e)+'\n')
with (base/'swift-final.log').open('w') as log:
 for line in p.stdout:
  log.write(line);log.flush()
  if not sampled and ('recorded an issue' in line or 'Test Case ' in line and ' failed ' in line):
   sampled=True;sampler=threading.Thread(target=sample_owned);sampler.start()
code=p.wait()
if sampler:sampler.join(timeout=15)
row={'entrypoint':'make test_swift','exit':code,'seconds':time.monotonic()-started,'log':'B25/swift-final.log','failure_sampling_triggered':sampled}
(base/'swift-result.json').write_text(json.dumps(row,indent=2)+'\n');print(json.dumps(row),flush=True)
raise SystemExit(code)
