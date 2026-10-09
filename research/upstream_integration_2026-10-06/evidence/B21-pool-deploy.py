from pathlib import Path
exec(Path('/private/tmp/vphone-b21-runtime.py').read_text().split("result={'target':target,'observations':rows}")[0])
artifact=json.loads(Path('/private/tmp/vphone-b21-pool-artifact.json').read_text());result={'observations':rows,'artifact':artifact}
try:
 result['old_health']=health();assert result['old_health']['binary_hash']=='9a94d7acb2bfc7e3e615fe84882b8b3c731d83c94be5b177aa7fe8c0f0f0bd05'
 shell('test "$(ps -p 2860 -o comm= | tr -d " ")" = /var/root/vphone-b21-api/vphoned && test "$(ps -p 4156 -o comm= | tr -d " ")" = /private/var/root/vphone-b21-api/vphoned && kill -KILL 2860; sleep 1; test -z "$(ps -p 2860,4156 -o comm=)"')
 r=ctl('file_put',path='/var/root/vphone-b21-api/vphoned',load=artifact['path'],perm='755');assert r['ok']
 r=ctl('shell',cmd=prefix+'VPHONE_API_ONLY=1 /var/root/vphone-b21-api/vphoned </dev/null >/var/root/vphone-b21-api/pool.log 2>&1 &',timeout_ms=10000);assert r['ok'] and r['code']==0
 for _ in range(20):
  time.sleep(1)
  try:
   h=health()
   if h['binary_hash']==artifact['sha256']:break
  except Exception:pass
 assert h['binary_hash']==artifact['sha256'];result['health']=h
 result['processes']=shell('ps -A -o pid=,ppid=,comm= | grep -E "vphone-b21-api/vphoned|vphone-b13-api/vphoned"');result['completed']=True
finally:
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b21-pool-deploy.json').write_text(text)
print({k:v for k,v in result.items() if k!='observations'})
