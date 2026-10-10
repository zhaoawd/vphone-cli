exec(open('/private/tmp/vphone-b31-t08/client.py').read())
import base64,hashlib,plistlib
app='research.vphone.b31.rotation';data=json.loads((root/'fixture-v4-install.json').read_text())['reply']['result']['data_container'];out={'scope':'B30 current-policy candidate; no API library injection; v4 fixture reads own runtime policy','rows':[]};(root/'current-images').mkdir(exist_ok=True)
port=int(re.search(r'\[api\] proxy listening on http://127.0.0.1:(\d+)',(run/'console-redacted.log').read_text(errors='replace'))[1]);c=http.client.HTTPConnection('127.0.0.1',port,timeout=30);c.request('GET','/v1/health',headers={'Authorization':'Bearer '+token});r=c.getresponse();out['health']={'status':r.status,'body':json.loads(r.read())};c.close();assert out['health']['body']['binary_hash']=='177e8d9a7c103d9be206800bde2b118852bd9a64115ac6127f762035c122b59e'
for subject,mask in [(app,30),(app,2),(app,26),(app,30),('com.apple.Preferences',None),('com.apple.mobilesafari',None)]:
 phase=f'{len(out["rows"]):02d}-{subject.split(".")[-1]}-mask-{mask}'
 rpc('screen.unlock');opened=rpc('apps.launch',{'bundle_id':subject});assert opened['reply']['result']['frontmost_verified'];rpc('display.rotation_lock',{'locked':False})
 if mask:
  p=root/'current-policy.plist';p.write_bytes(plistlib.dumps({'mask':mask}));assert ctl('file_put',path=data+'/Documents/policy.plist',load=str(p),perm='644')['ok'];time.sleep(.5)
 for degrees in [0,90,270,180]:
  check();q={'phase':phase,'app':subject,'mask':mask,'requested':degrees,'before':rpc('display.rotation'),'change':rpc('display.rotation',{'orientation':str(degrees)})};time.sleep(1);q['readback']=rpc('display.rotation');q['foreground']=rpc('apps.foreground');shot=rpc('screen.screenshot');details=shot['reply'].get('result',{});encoded=details.pop('data',None)
  if encoded:
   b=base64.b64decode(encoded);name=f'current-images/{phase}-{degrees}.jpeg';(root/name).write_bytes(b);details.update(saved_file=name,sha256=hashlib.sha256(b).hexdigest())
  q['screenshot']=shot
  if mask:
   q['scene_get']=ctl('file_get',path=data+'/Documents/rotation.jsonl',save=str(root/'current-runtime-log.jsonl'));q['last_scene_samples']=[json.loads(x) for x in (root/'current-runtime-log.jsonl').read_text().splitlines()[-4:]]
  q['expected_success']=degrees==0 or (degrees in [90,270] and (mask in [26,30] or subject=='com.apple.mobilesafari'))
  q['passed']=q['change']['http_status']==(200 if q['expected_success'] else 400) and q['readback']['reply']['result']['degrees']==(degrees if q['expected_success'] else q['before']['reply']['result']['degrees']) and q['foreground']['reply']['result']['bundle_id']==subject and q['foreground']['reply']['result']['verified']
  out['rows'].append(q);save('current-matrix.json',out);print(subject,mask,degrees,q['change']['http_status'],q['readback']['reply']['result']['degrees'],'pass',q['passed'],flush=True);assert q['passed']
out['invalid45']=rpc('display.rotation',{'orientation':'45'});out['lock_true']=rpc('display.rotation_lock',{'locked':True});out['lock_true_read']=rpc('display.rotation');out['lock_false']=rpc('display.rotation_lock',{'locked':False});out['lock_false_read']=rpc('display.rotation');save('current-matrix.json',out)
