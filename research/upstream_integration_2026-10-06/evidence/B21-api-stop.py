from pathlib import Path
exec(Path('/private/tmp/vphone-b21-runtime.py').read_text().split("result={'target':target,'observations':rows}")[0])
result={'observations':rows}
result['before']=shell('test "$(ps -p 6503 -o comm= | tr -d " ")" = /var/root/vphone-b21-api/vphoned && test "$(ps -p 6504 -o comm= | tr -d " ")" = /private/var/root/vphone-b21-api/vphoned && ps -p 6503,6504 -o pid=,ppid=,comm=')
shell('kill -TERM 6503; sleep 1')
left=shell('ps -p 6503,6504 -o pid=,ppid=,comm= || true');result['after_term']=left
if left.strip():
 shell('test "$(ps -p 6503 -o comm= | tr -d " ")" = /var/root/vphone-b21-api/vphoned && kill -KILL 6503; sleep 1')
result['after']=shell('ps -p 6503,6504 -o pid=,ppid=,comm= || true');assert not result['after'].strip()
result['capabilities']=ctl('capabilities');text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b21-api-stop.json').write_text(text);print({'owned_API_processes_absent':True})
