from pathlib import Path
import json,hashlib
from PIL import Image
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_LITTLE_ENDIAN
root=Path(__file__).resolve().parent
def read(name):return json.loads((root/name).read_text())
for bundle,mask in [('com.apple.Preferences',2),('com.apple.mobilesafari',26)]:
 d=read(bundle+'-filter-condition.json');assert d['front']['verified'] and d['front']['bundle_id']==bundle
 assert any(x['kind']=='native_idiom' and x['value']==0 for x in d['observations']);assert any(x['kind']=='has_home_button' and x['value']==0 for x in d['observations'])
 assert d['condition']['receiver_symbol'].endswith('OBJC_CLASS_$_UIDevice')
 assert d['policy']['scenes'][0]['current_scene_mask']==mask and d['policy']['scenes'][0]['client_mask']==mask
 w=d['policy']['scenes'][0]['windows'][0];assert w['provided_mask']==30 and w['resolved_mask']==mask and w['private_application_mask']==mask and w['application_mask']==mask
 m=d['condition']['method'];decoded=list(Cs(CS_ARCH_ARM64,CS_MODE_LITTLE_ENDIAN).disasm(bytes(m['bytes']),int(m['address'],16)));assert len(decoded)==len(m['instructions'])
 for i,(x,y) in enumerate(zip(decoded,m['instructions'])):assert x.address==int(y['address'],16) and x.mnemonic==y['mnemonic'],(i,x.mnemonic,y)
 names=[x.mnemonic for x in decoded];k=next(i for i,x in enumerate(decoded) if x.mnemonic=='mov' and x.op_str=='w8, #0x1a');assert names[k:k+4]==['mov','and','cmp','csel'];assert decoded[k+1].op_str=='x8, x21, x8' and decoded[k+3].op_str.endswith(', ne')
d=read('fixture-aba.json');assert len(d['rows'])==3;pid=d['front']['pid']
for row,mask,error in zip(d['rows'],[26,30,26],[101,None,101]):
 p=row['policy_after'];assert p['pid']==pid and p['bundle_id']=='research.vphone.b31.rotation';s=p['scenes'][0];assert s['current_scene_mask']==mask and s['client_mask']==mask
 w=s['windows'][0];assert w['provided_mask']==30 and w['application_mask']==30 and w['private_application_mask']==mask and w['resolved_mask']==mask
 g=row['samples_last_4'][-1]['geometry_request'];assert g['requested_mask']==4
 if error is None:assert g['error'] is None
 else:assert g['error']['domain']=='UISceneErrorDomain' and g['error']['code']==error
 assert s['orientation']==1 # no phase establishes actual 180-degree scene rotation
rows=read('clean-matrix.json')['rows'];assert len(rows)==8
expected=[(200,0),(400,0),(400,0),(400,0),(200,0),(200,90),(200,270),(400,270)]
for row,(status,degree) in zip(rows,expected):
 assert row['change']['http_status']==status and row['api']['reply']['result']['degrees']==degree
 f=row['front']['reply']['result'];assert f['verified'] and f['bundle_id']==row['bundle']
 shot=row['screenshot']['reply']['result'];p=root/shot['saved_file'];assert hashlib.sha256(p.read_bytes()).hexdigest()==shot['sha256']
 with Image.open(p) as im:
  assert (im.width>im.height)==(degree in [90,270]),(p,im.size)
q=read('guest-cleanup.json');assert not q['app_search']['reply']['result']['apps'];install=read('fixture-install.json')['reply']['result']
for field,pathfield in [('bundle_parent','bundle_container'),('data_parent','data_container')]:assert not any(e['name']==Path(install[pathfield]).name for e in q[field]['reply']['result']['entries'])
for name,sha in [('original-api','83075a0c9de2ff5bbfd01b211ce204f59bd18cdf9eb0efb7bd0891a62f00bc07'),('system-classic','306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001'),('cache-classic','306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001')]:assert q[name]['sha256']==sha
q=read('guest-cleanup-final.json');assert not any(e['name']=='vphone-b32' for e in q['root_parent']['reply']['result']['entries']);assert not any(e['name'].startswith('b32-') for e in q['api_parent']['reply']['result']['entries']);assert not q['apps']['reply']['result']['apps'];assert not any('vphone-b32' in e.get('executable','') or 'VPhoneB31Rotation' in e.get('executable','') for e in q['processes']['reply']['result']['processes']);assert q['rotation']['reply']['result']['degrees']==0 and q['rotation']['reply']['result']['locked']==False
for name in ['20261010-093633-f57791e5','20261010-101205-297aa07d']:
 d=read('runs/'+name+'/exit.json');assert d['normal_guest_shutdown'] and d['vm_exit']==0 and all(d['disk_handles_released'].values()) and d['minimum_free_bytes']>=5*1024**3
assert 'state = running' in (root/'amfid-after-recovery.log').read_text();assert 'Sending disconnect packet failed' in (root/'host-scoped-driver.log').read_text();assert 'JETSAM_REASON_MEMORY_IDLE_EXIT' in (root/'amfid-final-service.log').read_text()
q=read('host-final.json');assert q['final_free_bytes']>=5*1024**3 and any(x.strip().startswith('35668 ') for x in q['relevant_processes']);assert not any('debugserver' in x or 'scoped.py' in x or 'vm-roothide-20261010' in x for x in q['relevant_processes'])
print('B32 PASS: two system policies, decoded filter condition, fixture ABA, eight clean rotations/JPEGs, guest cleanup, two normal shutdowns and independent host recovery snapshots; actual 180-degree success not established.')
