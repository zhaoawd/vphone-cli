exec(open('/private/tmp/vphone-b31-t08/client.py').read())
import base64,hashlib,plistlib
app='research.vphone.b31.rotation';data=json.loads((root/'fixture-install.json').read_text())['reply']['result']['data_container'];out={'scope':'controlled UIKit fixture, original API, no diagnostic injection','rows':[]};(root/'fixture-images').mkdir(exist_ok=True)
for mask in [30,2,26,30]:
 phase=f'clean-{len(out["rows"]):02d}-mask-{mask}';p=root/'policy.plist';p.write_bytes(plistlib.dumps({'mask':mask}));assert ctl('file_put',path=data+'/Documents/policy.plist',load=str(p),perm=420)['ok'];time.sleep(.75)
 for degrees in [0,90,270,180]:
  check();rpc('screen.unlock');rpc('apps.launch',{'bundle_id':app});q={'phase':phase,'mask':mask,'requested':degrees,'frontmost_before':rpc('apps.foreground'),'change':rpc('display.rotation',{'orientation':str(degrees)})};time.sleep(1.0);q['readback']=rpc('display.rotation');q['frontmost_after']=rpc('apps.foreground')
  shot=rpc('screen.screenshot');r=shot['reply'].get('result',{});encoded=r.pop('data',None)
  if encoded:
   b=base64.b64decode(encoded);name=f'fixture-images/{phase}-{degrees}.jpeg';(root/name).write_bytes(b);r.update(saved_file=name,sha256=hashlib.sha256(b).hexdigest())
  q['screenshot']=shot;name=f'fixture-{phase}-{degrees}.jsonl';q['scene_log_get']=ctl('file_get',path=data+'/Documents/rotation.jsonl',save=str(root/name));lines=(root/name).read_text().splitlines();q['scene_samples_last_4']=[json.loads(x) for x in lines[-4:]]
  save('fixture-row-pending.json',q)
  assert q['frontmost_after']['reply']['result'].get('bundle_id')==app
  assert q['frontmost_after']['reply']['result'].get('verified')
  out['rows'].append(q);save('fixture-matrix.json',out);print(mask,degrees,q['change']['http_status'],q['readback']['reply'],q['scene_samples_last_4'][-1],flush=True)
save('fixture-matrix.json',out)
