import frida,json
from pathlib import Path
root=Path('/private/tmp/vphone-b32-t08');exec((root/'client.py').read_text());e=json.loads((root/'frida-endpoint.json').read_text());d=frida.get_device_manager().add_remote_device(f"{e['ip']}:{e['port']}",token=(root/'frida-private-token').read_text())
import time
rpc('screen.unlock');launch=rpc('apps.launch',{'bundle_id':'com.apple.mobilesafari'})
for attempt in range(20):
 front=rpc('apps.foreground')['reply'].get('result',{})
 if front.get('verified') and front.get('bundle_id')=='com.apple.mobilesafari':break
 time.sleep(.25)
save('trace-foreground.json',{'launch':launch,'front':front});assert front.get('verified') and front.get('bundle_id')=='com.apple.mobilesafari'
session=d.attach(front['pid']);script=session.create_script((root/'policy.js').read_text());script.load()
try:
 out={'policy':script.exports_sync.policy(),'methods':[script.exports_sync.code('UIApplication',s) for s in ['_supportedInterfaceOrientationsForWindow:','supportedInterfaceOrientationsForWindow:']]};save('application-orientation-methods.json',out)
 for m in out['methods']:
  print(m['selector'])
  for i in m.get('instructions',[]):print(i)
finally:script.unload();session.detach()
