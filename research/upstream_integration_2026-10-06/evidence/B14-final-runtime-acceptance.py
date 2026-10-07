import base64,http.client,json,re,socket,time
from pathlib import Path
exec(Path('/private/tmp/vphone-b14-second-guest-start.py').read_text().split('try:\n cap=')[0])
call('capabilities')
health=call('rpc',method='agent.health',params={});assert health['ok'] and health['result']['setup_pending'] is False
for path in ['/usr/bin/vphoned','/var/root/Library/Caches/vphoned']:
 r=call('file_get',path=path);assert r['ok'];data=base64.b64decode(r.pop('data'),validate=True);digest=__import__('hashlib').sha256(data).hexdigest();assert digest=='306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001';r['readback']={'bytes':len(data),'sha256':digest}
call('rpc',method='system.shutdown',params={'force':False})
# No actual guest clipboard change was observed in Cmd V test; verify empty.
clip=call('rpc',method='clipboard.get',params={});assert clip['ok'] and clip['result']['items']==0 and clip['result']['types']==[]
port=int(re.search(r'\[api\] proxy listening on http://127\.0\.0\.1:(\d+)',Path('/private/tmp/vphone-b14-second-boot.log').read_text(errors='replace'))[1]);current=Path('/private/tmp/vphone-b14-second-token').read_text();old=Path('/private/tmp/vphone-b14-restart-token').read_text();probes=[]
for name,token in [('missing',None),('incorrect','b14-incorrect'),('prior_boot',old),('current',current)]:
 c=http.client.HTTPConnection('127.0.0.1',port,timeout=10);headers={} if token is None else {'Authorization':'Bearer '+token};c.request('GET','/v1/health',headers=headers);rsp=c.getresponse();body=json.loads(rsp.read());c.close();probes.append({'case':name,'status':rsp.status,'body':body})
assert [p['status'] for p in probes]==[401,401,401,200]
result={'observations':rows,'HTTP_authentication':probes,'second_VM_instance':'09F69011-7199-40F7-BDF6-1894709D42D9','API_instance':health['result']['instance_id'],'classic_daemon_and_cache_preserved':True,'original_guest_clipboard_still_empty':True,'password_supplied':False};data=json.dumps(result,indent=2)+'\n';assert current not in data and old not in data;Path('/private/tmp/vphone-b14-final-runtime-acceptance.json').write_text(data);print({'HTTP_statuses':[p['status'] for p in probes],'classic_hash_preserved':True,'API_instance':result['API_instance']})
