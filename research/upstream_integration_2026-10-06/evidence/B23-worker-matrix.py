from pathlib import Path
import plistlib
exec(Path('/private/tmp/vphone-b23-common.py').read_text())
w=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');base=w/'.build/acceptance/B22/api-cache-fixed/vphoned';alt=w/'.build/acceptance/B23/signature-variant/vphoned'
base_sha=hashlib.sha256(base.read_bytes()).hexdigest();alt_sha=hashlib.sha256(alt.read_bytes()).hexdigest()
label='com.vphone.B23.worker-matrix';job='/var/root/vphone-b23-api/worker-matrix.plist';binary='/var/root/vphone-b23-job/vphoned';initial='/var/root/vphone-b23-api/vphoned';cache='/var/root/Library/Caches/vphoned';backup=cache+'.B23-original';paths=[binary,cache];result={'target':target,'observations':rows,'base_sha256':base_sha,'alternate_sha256':alt_sha,'signature_variant_only':True,'complete':False};moved=False;loaded=False

def ps():
 return [x.split(None,2) for x in shell('ps -A -o pid=,ppid=,comm=').splitlines() if len(x.split(None,2))==3 and x.split(None,2)[2] in paths+['/private'+p for p in paths]]
def wait_health(expected,previous=None,timeout=25):
 start=time.monotonic()
 while time.monotonic()-start<timeout:
  try:
   h=health()
   if h['binary_hash']==expected and (previous is None or h['instance_id']!=previous):return {'health':h,'seconds':time.monotonic()-start,'processes':ps()}
  except Exception:pass
  time.sleep(.2)
 raise RuntimeError('Expected listening daemon did not appear: '+expected)
def wait_gone(timeout=8):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  a=ps()
  if not a:return
  time.sleep(.2)
 raise RuntimeError('Isolated job still running: '+repr(a))
def read_hash(path):
 r=ctl('file_get',path=path);assert r['ok'];return hashlib.sha256(base64.b64decode(r['data'])).hexdigest()
def signal_pid(row,signal):
 pid=int(row[0]);comm=row[2];assert comm in paths+['/private'+p for p in paths]
 shell('test "$(ps -p '+str(pid)+' -o comm= | tr -d " ")" = '+comm+' && kill -'+signal+' '+str(pid))
def apply(path,sha,previous):
 assert ctl('file_put',path=cache+'.next',load=str(path),perm='755')['ok']
 response=rpc_http('agent.apply_update',{'sha256':sha});assert response['restarting']
 transition=wait_health(sha,previous);transition['reply']=response
 assert read_hash(cache)==sha
 transition['confirmed']=bool(shell('test -f '+cache+'.api-v2 && test ! -e '+cache+'.api-v2.pending && echo yes').strip());assert transition['confirmed']
 return transition
try:
 result['classic_before']=read_hash('/usr/bin/vphoned');assert result['classic_before']=='306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001'
 assert not rpc_http('services.status',{'label':label})['loaded']
 assert not shell('test -e '+backup+' && echo exists || true').strip()
 assert not shell('for p in '+cache+'.next '+cache+'.api-v2 '+cache+'.api-v2.pending; do test ! -e "$p" || echo exists; done').strip()
 result['original_cache_sha256']=read_hash(cache);result['original_cache_metadata']=shell('stat -c "%u %g %a %s" '+cache)
 shell('mv '+cache+' '+backup+'; mkdir -p /var/root/vphone-b23-job; chmod 700 /var/root/vphone-b23-job');moved=True
 assert ctl('file_put',path=binary,load=str(base),perm='755')['ok']
 body={'Label':label,'ProgramArguments':[binary],'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':1,'ProcessType':'Interactive','StandardOutPath':'/var/root/vphone-b23-api/worker-matrix.log','StandardErrorPath':'/var/root/vphone-b23-api/worker-matrix.log'}
 host=Path('/private/tmp/vphone-b23-worker-matrix.plist');host.write_bytes(plistlib.dumps(body));assert ctl('file_put',path=job,load=str(host),perm='644')['ok']
 result['load']=rpc_http('services.load',{'paths':[job]});loaded=True
 for x in shell('ps -A -o pid=,ppid=,comm=').splitlines():
  f=x.split(None,2)
  if len(f)==3 and f[1]=='1' and f[2]==initial:shell('kill -TERM '+f[0])
 result['initial_job']=wait_health(base_sha);result['service_loaded']=rpc_http('services.status',{'label':label});assert result['service_loaded']['loaded'] and result['service_loaded']['running']
 current=result['initial_job']['health']
 for name,signal,kind in [('worker_kill','KILL','worker'),('worker_term','TERM','worker'),('proxy_kill','KILL','proxy')]:
  before=ps();row=next(x for x in before if (x[1]=='1')==(kind=='proxy'));signal_pid(row,signal)
  transition=wait_health(base_sha,current['instance_id']);result[name]={'before':before,'signalled':row,**transition};current=transition['health']
  assert len(transition['processes'])==2
 result['explicit_update']=apply(alt,alt_sha,current['instance_id']);current=result['explicit_update']['health']
 result['explicit_rollback']=apply(base,base_sha,current['instance_id']);current=result['explicit_rollback']['health']
 # Unconfirmed worker failure: pending prevents retries of the cache; launchd falls back.
 shell('mv '+cache+'.api-v2 '+cache+'.api-v2.pending')
 before=ps();row=next(x for x in before if x[1]!='1');signal_pid(row,'KILL')
 result['unconfirmed_worker_failure']=wait_health(base_sha,current['instance_id']);current=result['unconfirmed_worker_failure']['health']
 assert all(x[2] in [binary,'/private'+binary] for x in result['unconfirmed_worker_failure']['processes'])
 assert not shell('test -e '+cache+'.api-v2 && echo exists || true').strip()
 shell('rm -f '+cache+'.api-v2.pending')
 # Invalid executable is intentionally submitted with its correct SHA to test exec fallback.
 bad=Path('/private/tmp/vphone-b23-invalid-executable');bad.write_bytes(b'B23 deliberately invalid executable\n');bad_sha=hashlib.sha256(bad.read_bytes()).hexdigest()
 assert ctl('file_put',path=cache+'.next',load=str(bad),perm='755')['ok']
 result['invalid_exec_reply']=rpc_http('agent.apply_update',{'sha256':bad_sha});assert result['invalid_exec_reply']['restarting']
 result['invalid_exec_fallback']=wait_health(base_sha,current['instance_id']);current=result['invalid_exec_fallback']['health'];assert len(result['invalid_exec_fallback']['processes'])==2
 time.sleep(3)
 result['fallback_stable']=health();assert result['fallback_stable']['instance_id']==current['instance_id']
 result['invalid_exec_log']=shell('tail -n 30 /var/root/vphone-b23-api/worker-matrix.log')
 result['classic_after']=read_hash('/usr/bin/vphoned');assert result['classic_before']==result['classic_after']
 result['complete']=True
except Exception as ex:result['error']=repr(ex);raise
finally:
 if loaded:
  try:result['unload_reply']=rpc_http('services.unload',{'paths':[job],'force':True})
  except Exception as ex:result['unload_reply_unknown']=repr(ex)
  wait_gone();result['job_processes_gone']=True
 if moved:
  assert read_hash(backup)==result['original_cache_sha256']
  shell('rm -f '+cache+' '+cache+'.next '+cache+'.api-v2 '+cache+'.api-v2.pending; mv '+backup+' '+cache)
  result['cache_restored']=read_hash(cache)==result['original_cache_sha256'] and shell('stat -c "%u %g %a %s" '+cache)==result['original_cache_metadata'];assert result['cache_restored']
 if loaded:
  shell('VPHONE_API_ONLY=1 '+initial+' </dev/null >>/var/root/vphone-b23-api/b23-api.log 2>&1 &')
  result['initial_control_restored']=wait_health(base_sha)
  result['job_after_unload']=rpc_http('services.status',{'label':label});assert not result['job_after_unload']['loaded']
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b23-worker-matrix.json').write_text(text)
print({k:v for k,v in result.items() if k!='observations'})
