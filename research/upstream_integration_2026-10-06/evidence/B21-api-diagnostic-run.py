from pathlib import Path
exec(Path('/private/tmp/vphone-b21-runtime.py').read_text().split("result={'target':target,'observations':rows}")[0])
result={'observations':rows}
try:
 shell('test ! -e /var/root/vphone-b21-api && mkdir /var/root/vphone-b21-api')
 for name,source in [('vphoned','/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/.build/acceptance/B21/vphoned-instrumented'),('fd-probe','/private/tmp/vphone-b21-fd-probe')]:
  r=ctl('file_put',path='/var/root/vphone-b21-api/'+name,load=source,perm='755');assert r['ok']
 result['original_api_workers_before']=shell('ps -p 663,667 -o pid=,ppid=,comm=')
 # Recheck both exact process paths before signalling only the owned proxy.
 shell('test "$(ps -p 663 -o comm= | tr -d " ")" = /var/root/vphone-b13-api/vphoned && test "$(ps -p 667 -o comm= | tr -d " ")" = /private/var/root/vphone-b13-api/vphoned && kill -KILL 663; sleep 1; test -z "$(ps -p 663,667 -o comm=)"')
 result['proxy_death_reaped_worker']=True
 r=ctl('shell',cmd=prefix+'VPHONE_API_ONLY=1 /var/root/vphone-b21-api/vphoned </dev/null >/var/root/vphone-b21-api/diagnostic.log 2>&1 &',timeout_ms=10000);assert r['ok'] and r['code']==0
 for _ in range(15):
  time.sleep(1)
  try:
   h=health()
   if h['binary_hash']!= '152dc35bd219ebccffb71623cb9e732a8e88d9f257b87f42ac0e38258f7e1749':break
  except Exception:pass
 result['diagnostic_health']=h
 result['processes']=shell('ps -A -o pid=,ppid=,comm= | grep -E "vphone-b21-api/vphoned|vphone-b13-api/vphoned"')
 c=http.client.HTTPConnection('127.0.0.1',port,timeout=8);raw=bytearray();download={}
 try:
  c.request('GET','/v1/files/content?path='+urllib.parse.quote('/var/root/vphone-b21-transfer/1048576',safe=''),headers={'Authorization':'Bearer '+token});r=c.getresponse();download.update(status=r.status,headers=dict(r.getheaders()))
  while True:
   b=r.read(1024)
   if not b:break
   raw.extend(b)
 except Exception as e:download['error']=type(e).__name__+': '+str(e)
 finally:c.close();download.update(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest());result['download']=download
 result['trace']=shell('cat /var/root/vphone-b21-api/diagnostic.log')
 result['completed']=True
finally:
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b21-api-diagnostic-run.json').write_text(text)
print({k:v for k,v in result.items() if k!='observations'})
