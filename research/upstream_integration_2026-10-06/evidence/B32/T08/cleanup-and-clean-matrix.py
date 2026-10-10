exec(open('/private/tmp/vphone-b32-t08/client.py').read())
import hashlib,base64
q={};install=json.loads((root/'fixture-install.json').read_text())['reply']['result'];q['fixture_log']=ctl('file_get',path=install['data_container']+'/Documents/rotation.jsonl',save=str(root/'fixture-final.jsonl'));q['terminate']=rpc('apps.terminate',{'bundle_id':install['bundle_id']});q['uninstall']=rpc('apps.uninstall',{'bundle_id':install['bundle_id'],'force':True});q['app_search']=rpc('apps.search',{'query':install['bundle_id']});q['bundle_parent']=rpc('files.list',{'path':'/private/var/containers/Bundle/Application'});q['data_parent']=rpc('files.list',{'path':'/private/var/mobile/Containers/Data/Application'});save('guest-cleanup.json',q)
p=rpc('processes.list')['reply']['result']['processes'];ids=[x['pid'] for x in p if x.get('executable')=='/private/var/root/vphone-b32/usr/sbin/frida-server'];assert ids==[600];q['frida_pid']=ids;serial('kill -TERM 600; echo B32_FRIDA_STOP_REQUESTED')
for attempt in range(30):
 p=rpc('processes.list')['reply']['result']['processes']
 if not any(x['pid']==600 for x in p):break
 time.sleep(.25)
assert not any(x['pid']==600 for x in p);q['frida_process_absent']=True;q['frida_log']=ctl('file_get',path='/var/root/vphone-b29-api/b32-frida-server.log',save=str(root/'frida-server.log'))
q['remove']=[]
for path in ['/var/root/vphone-b32','/var/root/vphone-b29-api/b32-frida-server','/var/root/vphone-b29-api/b32-frida-agent.dylib','/var/root/vphone-b29-api/b32-frida-server.log','/var/root/vphone-b29-api/b32-frida-server.pid','/var/root/vphone-b29-api/b32-fixture.ipa']:
 q['remove'].append(rpc('files.remove',{'path':path,'force':True}))
q['root_parent']=rpc('files.list',{'path':'/var/root'});q['api_parent']=rpc('files.list',{'path':'/var/root/vphone-b29-api'});save('guest-cleanup.json',q)
output={'scope':'original API, Frida stopped and removed, no diagnostic app; post-diagnostic clean repetition','rows':[]};(root/'clean-images').mkdir(exist_ok=True)
for bundle in ['com.apple.Preferences','com.apple.mobilesafari']:
 rpc('screen.unlock');rpc('apps.launch',{'bundle_id':bundle})
 for attempt in range(30):
  f=rpc('apps.foreground')['reply'].get('result',{})
  if f.get('verified') and f.get('bundle_id')==bundle:break
  time.sleep(.2)
 assert f.get('verified') and f.get('bundle_id')==bundle
 for degree in [0,90,270,180]:
  row={'bundle':bundle,'requested':degree,'change':rpc('display.rotation',{'orientation':str(degree)})};time.sleep(.6);row['api']=rpc('display.rotation');row['front']=rpc('apps.foreground');shot=rpc('screen.screenshot');r=shot['reply'].get('result',{});encoded=r.pop('data',None)
  if encoded:
   b=base64.b64decode(encoded);name=f'clean-images/{bundle}-{degree}.jpeg';(root/name).write_bytes(b);r.update(saved_file=name,sha256=hashlib.sha256(b).hexdigest())
  row['screenshot']=shot;output['rows'].append(row);save('clean-matrix.json',output);print(bundle,degree,row['change']['http_status'],row['api']['reply'],flush=True)
q['restore_rotation']=rpc('display.rotation',{'orientation':'0'});q['restore_lock']=rpc('display.rotation_lock',{'locked':False});q['home']=ctl('key',name='home')
for name,path,expected in [('system-classic','/usr/bin/vphoned','306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001'),('cache-classic','/var/root/Library/Caches/vphoned','306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001'),('original-api','/var/root/vphone-b29-api/vphoned','83075a0c9de2ff5bbfd01b211ce204f59bd18cdf9eb0efb7bd0891a62f00bc07')]:
 p=root/(name+'.readback');assert ctl('file_get',path=path,save=str(p))['ok'];h=hashlib.sha256(p.read_bytes()).hexdigest();q[name]={'sha256':h,'bytes':p.stat().st_size};assert h==expected
save('guest-cleanup.json',q);print('B32 guest cleanup and clean matrix finished',flush=True)
