import concurrent.futures,json,shlex,time
from pathlib import Path
exec(Path('/private/tmp/vphone-b14-guest-start.py').read_text().split('try:\n cap=')[0])
call('key',name='power')
# Ensure locked: power toggles state; inspect before pausing API worker.
screen=call('rpc',method='device.screen',params={});assert screen['ok'] and screen['result']['locked']
health=call('rpc',method='agent.health',params={});assert health['ok'];instance=health['result']['instance_id']
r=call('shell',cmd=prefix+'ps -A -o pid=,ppid=,lstart=,comm= | grep -E "^[[:space:]]*1072[[:space:]]"',timeout_ms=10000);line=r['stdout'].strip();assert line.split()[:2]==['1072','1049'] and line.endswith('/private/var/root/vphone-b13-api/vphoned')
check='test "$(ps -A -o pid=,ppid=,lstart=,comm= | grep -E "^[[:space:]]*1072[[:space:]]" | sed "s/^[[:space:]]*//")" = '+shlex.quote(line)
command=prefix+check+' && (trap "kill -CONT 1072" EXIT HUP INT TERM; kill -STOP 1072; sleep 12; kill -CONT 1072; trap - EXIT HUP INT TERM)'
with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
 f=pool.submit(call,'shell',cmd=command,timeout_ms=20000)
 for _ in range(7):time.sleep(2);call('capabilities')
 paused=f.result();assert paused['ok'] and paused['code']==0
for _ in range(6):
 cap=call('capabilities')
 if cap.get('api_session',{}).get('state')=='ready':break
 time.sleep(2)
after=call('rpc',method='agent.health',params={});screen=call('rpc',method='device.screen',params={})
result={'observations':rows,'same_guest_instance':after.get('result',{}).get('instance_id')==instance,'reconnect_state_observed':any(x['response'].get('api_session',{}).get('state')=='reconnecting' for x in rows),'API_worker_resumed':True,'locked_after_reconnect':screen.get('result',{}).get('locked'),'new_host_source':'55fd8ef5'}
Path('/private/tmp/vphone-b14-same-instance-reconnect.json').write_text(json.dumps(result,indent=2)+'\n');print({k:v for k,v in result.items() if k!='observations'})
