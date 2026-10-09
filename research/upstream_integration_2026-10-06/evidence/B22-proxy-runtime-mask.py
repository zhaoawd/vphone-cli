from pathlib import Path
exec(Path('/private/tmp/vphone-b22-common.py').read_text())
root=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');candidate=root/'.build/daemon-api-v2/candidate/vphoned'
sha=hashlib.sha256(candidate.read_bytes()).hexdigest();result={'candidate_sha256':sha,'observations':rows,'stops':[]}
try:
 assert not shell('ps -A -o comm= | grep -E "vphone-b21-api/vphoned$" || true').strip()
 assert ctl('file_put',path='/var/root/vphone-b21-api/vphoned',load=str(candidate),perm='755')['ok']
 for trial in range(3):
  shell('VPHONE_API_ONLY=1 /var/root/vphone-b21-api/vphoned </dev/null >/var/root/vphone-b21-api/b22-proxy-'+str(trial)+'.log 2>&1 &')
  for _ in range(20):
   try:
    h=health()
    if h['binary_hash']==sha:break
   except Exception:pass
   time.sleep(.2)
  assert h['binary_hash']==sha
  p=shell('ps -A -o pid=,ppid=,comm= | grep vphone-b21-api/vphoned').splitlines();pid=next(int(x.split()[0]) for x in p if x.split()[1]=='1');worker=next(int(x.split()[0]) for x in p if x.split()[1]==str(pid))
  start=time.monotonic();shell('test "$(ps -p '+str(pid)+' -o comm= | tr -d " ")" = /var/root/vphone-b21-api/vphoned && kill -TERM '+str(pid))
  for _ in range(25):
   left=shell('ps -A -o pid=,comm= | grep -E "vphone-b21-api/vphoned$" || true').strip()
   if not left:break
   time.sleep(.1)
  result['stops'].append({'proxy':pid,'worker':worker,'remaining':left,'elapsed':time.monotonic()-start,'sha256':sha})
  assert not left,'SIGTERM left owned processes'
 result['complete']=True
finally:
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b22-proxy-runtime-mask.json').write_text(text)
print(result['stops'])
