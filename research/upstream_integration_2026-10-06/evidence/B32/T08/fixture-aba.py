import frida,json,time,plistlib,base64,hashlib
from pathlib import Path
root=Path('/private/tmp/vphone-b32-t08');exec((root/'client.py').read_text());e=json.loads((root/'frida-endpoint.json').read_text());d=frida.get_device_manager().add_remote_device(f"{e['ip']}:{e['port']}",token=(root/'frida-private-token').read_text());bundle='research.vphone.b31.rotation';data=json.loads((root/'fixture-install.json').read_text())['reply']['result']['data_container']
rpc('screen.unlock');rpc('apps.launch',{'bundle_id':bundle})
for attempt in range(30):
 front=rpc('apps.foreground')['reply'].get('result',{})
 if front.get('verified') and front.get('bundle_id')==bundle:break
 time.sleep(.2)
assert front.get('verified') and front.get('bundle_id')==bundle
session=d.attach(front['pid']);script=session.create_script((root/'fixture-policy.js').read_text());script.load();out={'front':front,'fixture_sha256':hashlib.sha256(Path('/private/tmp/vphone-b31-t08/fixture-v4.ipa').read_bytes()).hexdigest(),'condition':script.exports_sync.arm(),'rows':[]}
try:
 for phase,value in [('A-native',None),('B-home-button-true',1),('A-restored',None)]:
  row={'phase':phase,'override':script.exports_sync.sethome(value)};script.exports_sync.invalidate();time.sleep(.6);row['policy_before']=script.exports_sync.policy();p=root/'fixture-geometry-policy.plist';p.write_bytes(plistlib.dumps({'mask':30,'request_id':phase,'geometry_mask':4}));row['put']=ctl('file_put',path=data+'/Documents/policy.plist',load=str(p),perm='644');assert row['put']['ok'];time.sleep(1);row['policy_after']=script.exports_sync.policy();row['api']=rpc('display.rotation');row['get_log']=ctl('file_get',path=data+'/Documents/rotation.jsonl',save=str(root/(phase+'.jsonl')));row['samples_last_4']=[json.loads(x) for x in (root/(phase+'.jsonl')).read_text().splitlines()[-4:]];row['observations']=script.exports_sync.observations();out['rows'].append(row);save('fixture-aba.json',out);print(phase,[(s['current_scene_mask'],s['client_mask'],s['orientation'],s['windows']) for s in row['policy_after']['scenes']],row['samples_last_4'][-1]['geometry_request'],flush=True)
finally:
 script.exports_sync.sethome(None);script.exports_sync.invalidate();script.unload();session.detach()
