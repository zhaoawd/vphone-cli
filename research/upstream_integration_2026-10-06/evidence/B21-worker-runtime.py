from pathlib import Path
exec(Path('/private/tmp/vphone-b21-runtime.py').read_text().split("result={'target':target,'observations':rows}")[0])
result={'observations':rows}
try:
 before=health();start=time.monotonic()
 shell('test "$(ps -p 2860 -o comm= | tr -d " ")" = /var/root/vphone-b21-api/vphoned && test "$(ps -p 2861 -o comm= | tr -d " ")" = /private/var/root/vphone-b21-api/vphoned && kill -KILL 2861')
 probes=[]
 for _ in range(30):
  time.sleep(.1)
  try:
   h=health();probes.append({'seconds':time.monotonic()-start,'instance_id':h['instance_id']})
   if h['instance_id']!=before['instance_id']:break
  except Exception as e:probes.append({'seconds':time.monotonic()-start,'error':type(e).__name__})
 assert h['instance_id']!=before['instance_id'] and h['binary_hash']==before['binary_hash']
 result.update(health_before=before,health_after=h,probes=probes,seconds=time.monotonic()-start)
 result['processes_after']=shell('ps -A -o pid=,ppid=,comm= | grep -E "vphone-b21-api/vphoned|vphone-b13-api/vphoned"; tail -n 5 /var/root/vphone-b21-api/diagnostic.log')
 result['completed']=True
finally:
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b21-worker-runtime.json').write_text(text)
print({k:v for k,v in result.items() if k!='observations'})
