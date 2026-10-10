import frida,json,sys,time
from pathlib import Path
root=Path('/private/tmp/vphone-b32-t08');exec((root/'client.py').read_text());e=json.loads((root/'frida-endpoint.json').read_text());d=frida.get_device_manager().add_remote_device(f"{e['ip']}:{e['port']}",token=(root/'frida-private-token').read_text())
for bundle in ['com.apple.Preferences','com.apple.mobilesafari']:
 out={'unlock':rpc('screen.unlock'),'launch':rpc('apps.launch',{'bundle_id':bundle}),'samples':[]};out['front']=rpc('apps.foreground');pid=out['front']['reply']['result']['pid'];assert out['front']['reply']['result']['bundle_id']==bundle and out['front']['reply']['result']['verified'];session=None;script=None
 try:
  session=d.attach(pid);script=session.create_script((root/'policy.js').read_text());script.on('message',lambda m,data: (save('frida-script-error.json',m),print(m,flush=True)) if m.get('type')=='error' else None);script.load();out['initial_policy']=script.exports_sync.policy();out['method']=script.exports_sync.code('UIViewController','__supportedInterfaceOrientations');save(bundle+'-policy-initial.json',out)
  for degree in [0,90,270,180]:
   check();row={'request':degree,'change':rpc('display.rotation',{'orientation':str(degree)})};time.sleep(.6);row['api']=rpc('display.rotation');row['policy']=script.exports_sync.policy();out['samples'].append(row);save(bundle+'-policy.json',out);print(bundle,degree,row['api']['reply'].get('result'),[(s['current_scene_mask'],s['client_mask'],s['orientation']) for s in row['policy']['scenes']],flush=True)
 finally:
  if script:script.unload()
  if session:session.detach()
