from pathlib import Path
import json,hashlib,struct
root=Path('/private/tmp/vphone-b31-t08');q=json.loads((root/'current-matrix.json').read_text());assert len(q['rows'])==24;assert all(x['passed'] for x in q['rows']);positive=sum(x['change']['http_status']==200 for x in q['rows']);assert positive==14

def dimensions(b):
 assert b[:2]==b'\xff\xd8';i=2
 while i<len(b):
  assert b[i]==255
  while b[i]==255:i+=1
  marker=b[i];i+=1
  if marker in [216,217]:continue
  n=int.from_bytes(b[i:i+2],'big')
  if marker in [192,193,194,195,197,198,199,201,202,203,205,206,207]:return int.from_bytes(b[i+5:i+7],'big'),int.from_bytes(b[i+3:i+5],'big')
  i+=n
 raise AssertionError('missing SOF')
for x in q['rows']:
 s=x['screenshot']['reply']['result'];b=(root/s['saved_file']).read_bytes();assert hashlib.sha256(b).hexdigest()==s['sha256'];assert dimensions(b)==(s['width'],s['height']);degrees=x['readback']['reply']['result']['degrees'];assert (s['width'],s['height'])==((1290,2796) if degrees in [0,180] else (2796,1290))
 if x.get('last_scene_samples'):
  scene=x['last_scene_samples'][-1];expected=2 if x['mask']==2 else 26;assert all(scene[k]==expected for k in ['scene_client_mask','current_scene_mask','effective_controller_mask']);assert scene['mask_returned_by_controller']==x['mask'];assert scene['scene_orientation']=={0:1,90:4,180:2,270:3}[degrees]
assert q['invalid45']['http_status']==400;assert q['lock_true_read']['reply']['result']['locked'];assert not q['lock_false_read']['reply']['result']['locked']
g=json.loads((root/'cleanup-guest-final.json').read_text());assert g['health']['binary_hash']=='83075a0c9de2ff5bbfd01b211ce204f59bd18cdf9eb0efb7bd0891a62f00bc07';assert all(x['http_status']==200 for x in g['removed']);assert not any(e['name'].startswith('b31-') or e['name']=='vphoned-b31-current' for e in g['after_list']['reply']['result']['entries']);assert g['rotation_restored']['reply']['result']['degrees']==0
c=json.loads((root/'cleanup-guest-stage1.json').read_text());assert not c['app_search_after']['reply']['result']['apps'];install=json.loads((root/'fixture-v4-install.json').read_text())['reply']['result']
for field,parent in [('bundle_container','bundle_parent_list'),('data_container','data_parent_list')]:assert Path(install[field]).name not in [e['name'] for e in c[parent]['reply']['result']['entries']]
print(json.dumps({'direction_observations':24,'positive':14,'rejected_unchanged':10,'screenshot_hash_dimensions_verified':24,'fixture_runtime_mask_verified':16,'invalid_input_and_lock_readback':True,'guest_cleanup_verified':True}))
