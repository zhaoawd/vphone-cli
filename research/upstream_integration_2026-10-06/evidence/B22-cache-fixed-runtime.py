from pathlib import Path
import plistlib
exec(Path('/private/tmp/vphone-b22-common.py').read_text())
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');candidate=r/'.build/acceptance/B22/api-cache-fixed/vphoned';sha=hashlib.sha256(candidate.read_bytes()).hexdigest();cache='/var/root/Library/Caches/vphoned';backup=cache+'.B22-original';job='/var/root/vphone-b21-api/b22-cache-acceptance.plist';label='com.vphone.B22.cache-acceptance';result={'artifact_sha256':sha,'observations':rows,'cache_restored':False};moved=False;job_started=False

def wait_health(expected,timeout=25):
 start=time.monotonic()
 while time.monotonic()-start<timeout:
  try:
   h=health()
   if h['binary_hash']==expected:return h
  except Exception:pass
  time.sleep(.25)
 raise RuntimeError('Expected daemon hash did not listen: '+expected)
def stop_isolated():
 lines=shell('ps -A -o pid=,ppid=,comm= | grep -E "vphone-b21-api/vphoned$" || true').splitlines()
 for x in lines:
  if x.split()[1]=='1':shell('test "$(ps -p '+x.split()[0]+' -o comm= | tr -d " ")" = /var/root/vphone-b21-api/vphoned && kill -TERM '+x.split()[0])
 for _ in range(30):
  if not shell('ps -A -o comm= | grep -E "vphone-b21-api/vphoned$" || true').strip():return
  time.sleep(.1)
 raise RuntimeError('Isolated API did not stop')
try:
 assert ctl('file_put',path='/var/root/vphone-b21-api/vphoned',load=str(candidate),perm='755')['ok']
 assert not shell('test -e '+backup+' && echo exists || true').strip()
 assert not shell('for p in '+cache+'.next '+cache+'.api-v2 '+cache+'.api-v2.pending; do test ! -e "$p" || echo exists; done').strip()
 original=ctl('file_get',path=cache);assert original['ok'];original_data=base64.b64decode(original['data']);original_sha=hashlib.sha256(original_data).hexdigest();result['cache_original_sha256']=original_sha;result['cache_original_metadata']=shell('stat -c "%u %g %a %s" '+cache)
 stop_isolated();shell('mv '+cache+' '+backup);moved=True
 pl={'Label':label,'ProgramArguments':['/var/root/vphone-b21-api/vphoned'],'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':1,'ProcessType':'Interactive','StandardOutPath':'/var/root/vphone-b21-api/b22-cache.log','StandardErrorPath':'/var/root/vphone-b21-api/b22-cache.log'}
 host=Path('/private/tmp/vphone-b22-cache-acceptance.plist');host.write_bytes(plistlib.dumps(pl));assert ctl('file_put',path=job,load=str(host),perm='600')['ok']
 shell('/var/root/vphone-b21-api/vphoned </dev/null >/var/root/vphone-b21-api/b22-cache-manual.log 2>&1 &');job_started=True
 result['bundled_health']=wait_health(sha)
 assert ctl('file_put',path=cache+'.next',load=str(candidate),perm='755')['ok']
 result['update_reply']=rpc_http('agent.apply_update',{'sha256':sha});assert result['update_reply']['restarting'] is True
 time.sleep(2);result['processes_after_update_exit']=shell('ps -A -o pid=,ppid=,comm= | grep -E "(vphone-b21-api/vphoned|Library/Caches/vphoned)$" || true');assert not result['processes_after_update_exit'].strip();shell('/var/root/vphone-b21-api/vphoned </dev/null >>/var/root/vphone-b21-api/b22-cache-manual.log 2>&1 &');result['cached_health']=wait_health(sha)
 result['markers_after_listen']=shell('for p in '+cache+'.api-v2 '+cache+'.api-v2.pending; do test ! -e "$p" || ls -l "$p"; done')
 result['processes_after_listen']=shell('ps -A -o pid=,ppid=,comm= | grep -E "(vphone-b21-api/vphoned|Library/Caches/vphoned)$" || true')
 result['confirm_passed']=bool(shell('test -f '+cache+'.api-v2 && test ! -e '+cache+'.api-v2.pending && echo yes').strip())
 assert result['confirm_passed'],'Cached worker listened without confirming pending marker'
 result['complete']=True
except Exception as e:
 result['error']=repr(e);raise
finally:
 if job_started:
  
  lines=shell('ps -A -o pid=,ppid=,comm= | grep -E "(vphone-b21-api/vphoned|Library/Caches/vphoned)$" || true').splitlines()
  for x in lines:
   if x.split()[1]=='1':shell('kill -TERM '+x.split()[0])
  time.sleep(.5)
 if moved:
  remain=shell('ps -A -o pid=,ppid=,comm= | grep -E "(vphone-b21-api/vphoned|Library/Caches/vphoned)$" || true');result['processes_after_bootout']=remain;assert not remain.strip(),remain
  b=ctl('file_get',path=backup);assert b['ok'] and hashlib.sha256(base64.b64decode(b['data'])).hexdigest()==original_sha
  shell('rm -f '+cache+' '+cache+'.next '+cache+'.api-v2 '+cache+'.api-v2.pending; mv '+backup+' '+cache)
  v=ctl('file_get',path=cache);assert v['ok'] and hashlib.sha256(base64.b64decode(v['data'])).hexdigest()==original_sha
  result['cache_restored']=shell('stat -c "%u %g %a %s" '+cache)==result['cache_original_metadata'];assert result['cache_restored']
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b22-cache-fixed-runtime.json').write_text(text)
print({k:v for k,v in result.items() if k!='observations'})
