import frida,json,time
from pathlib import Path
root=Path('/private/tmp/vphone-b32-t08');exec((root/'client.py').read_text());e=json.loads((root/'frida-endpoint.json').read_text());d=frida.get_device_manager().add_remote_device(f"{e['ip']}:{e['port']}",token=(root/'frida-private-token').read_text())
for bundle in ['com.apple.Preferences','com.apple.mobilesafari']:
 rpc('screen.unlock');rpc('apps.launch',{'bundle_id':bundle})
 for attempt in range(30):
  front=rpc('apps.foreground')['reply'].get('result',{})
  if front.get('verified') and front.get('bundle_id')==bundle:break
  time.sleep(.2)
 assert front.get('verified') and front.get('bundle_id')==bundle
 session=d.attach(front['pid']);script=session.create_script((root/'policy.js').read_text());script.on('message',lambda m,d:print(m,flush=True));session.on('detached',lambda reason,*a:print('DETACHED',reason,flush=True));script.load()
 try:
  out={'front':front,'condition':script.exports_sync.arm(),'policy':script.exports_sync.policy()};out['observations']=script.exports_sync.observations();save(bundle+'-filter-condition.json',out);print(bundle,{k:v for k,v in out['condition'].items() if k!='method'},flush=True)
 finally:
  try:script.unload()
  finally:session.detach()
