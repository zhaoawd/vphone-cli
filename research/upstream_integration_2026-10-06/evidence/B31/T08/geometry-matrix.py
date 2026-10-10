exec(open('/private/tmp/vphone-b31-t08/client.py').read())
import base64,hashlib,plistlib
app='research.vphone.b31.rotation';data=json.loads((root/'fixture-v2-install.json').read_text())['reply']['result']['data_container'];out={'scope':'fixture public UIWindowScene.requestGeometryUpdate, no API injection','rows':[]};(root/'geometry-images').mkdir(exist_ok=True)
for i,(mask,degrees,requestmask) in enumerate([(30,0,2),(30,90,16),(30,270,8),(30,180,4),(2,90,16),(26,180,4),(30,180,4)]):
 p=root/'geometry-policy.plist';p.write_bytes(plistlib.dumps({'mask':mask,'request_id':f'geometry-{i}','geometry_mask':requestmask}));q={'mask':mask,'requested_degrees':degrees,'requested_mask':requestmask,'put':ctl('file_put',path=data+'/Documents/policy.plist',load=str(p),perm=420)};time.sleep(1.5);q['api_readback']=rpc('display.rotation');q['foreground']=rpc('apps.foreground');name=f'geometry-{i}.jsonl';q['scene_get']=ctl('file_get',path=data+'/Documents/rotation.jsonl',save=str(root/name));q['scene_samples_last_4']=[json.loads(x) for x in (root/name).read_text().splitlines()[-4:]]
 shot=rpc('screen.screenshot');r=shot['reply'].get('result',{});encoded=r.pop('data',None)
 if encoded:
  b=base64.b64decode(encoded);name=f'geometry-images/{i}-mask{mask}-{degrees}.jpeg';(root/name).write_bytes(b);r.update(saved_file=name,sha256=hashlib.sha256(b).hexdigest())
 q['screenshot']=shot;out['rows'].append(q);save('geometry-matrix.json',out);print(mask,degrees,q['api_readback']['reply'],q['scene_samples_last_4'][-1],flush=True)
