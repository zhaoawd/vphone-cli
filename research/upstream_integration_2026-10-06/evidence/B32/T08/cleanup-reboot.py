from pathlib import Path
import time,json,os,signal
root=Path('/private/tmp/vphone-b32-t08');run2=root/'runs/20261010-101205-297aa07d'
for attempt in range(240):
 assert not (run2/'exit.json').exists(), 'cleanup VM exited before ready'
 if (run2/'ready.json').exists():break
 time.sleep(.5)
assert (run2/'ready.json').exists(), 'cleanup readiness timeout'
source=(root/'client.py').read_text().replace('20261010-093633-f57791e5','20261010-101205-297aa07d');exec(source)
q={'remove':rpc('files.remove',{'path':'/var/root/vphone-b32','recursive':True,'force':True}),'root_parent':rpc('files.list',{'path':'/var/root'}),'api_parent':rpc('files.list',{'path':'/var/root/vphone-b29-api'}),'apps':rpc('apps.search',{'query':'research.vphone.b31.rotation'}),'processes':rpc('processes.list'),'rotation':rpc('display.rotation'),'home':ctl('key',name='home')}
save('guest-cleanup-final.json',q);assert q['remove']['http_status']==200 and q['remove']['reply']['result']['removed'];assert not any(e['name']=='vphone-b32' for e in q['root_parent']['reply']['result']['entries']);assert not any(e['name'].startswith('b32-') for e in q['api_parent']['reply']['result']['entries']);assert not q['apps']['reply']['result']['apps'];assert not any('vphone-b32' in e.get('executable','') or 'VPhoneB31Rotation' in e.get('executable','') for e in q['processes']['reply']['result']['processes']);assert q['rotation']['reply']['result']['degrees']==0 and q['rotation']['reply']['result']['locked']==False
os.kill(json.loads((run2/'process.json').read_text())['monitor_pid'],signal.SIGINT);print('recursive cleanup independently verified; normal shutdown requested',flush=True)
