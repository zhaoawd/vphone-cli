from pathlib import Path
exec(Path('/private/tmp/vphone-b22-common.py').read_text())
result={'observations':rows,'rotations':[],'health_before':health()};baseline=rpc_http('display.rotation');result['baseline']=baseline
try:
 for degrees in [0,90,180,270]:
  r=rpc_http('display.rotation',{'orientation':str(degrees)});s=rpc_http('screen.screenshot');data=base64.b64decode(s['data']);saved={k:v for k,v in s.items() if k!='data'};saved['sha256']=hashlib.sha256(data).hexdigest();saved['jpeg_magic']=data[:3].hex();result['rotations'].append({'requested':degrees,'rotation':r,'screenshot':saved});assert r['degrees']==degrees;assert data[:3]==b'\xff\xd8\xff';assert (s['width']>s['height'])==(degrees in [90,270])
 result['complete']=True
finally:
 result['restore_rotation']=rpc_http('display.rotation',{'orientation':str(baseline['degrees'])});result['restore_lock']=rpc_http('display.rotation_lock',{'locked':baseline['locked']})
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b22-rotation-probe.json').write_text(text)
print({k:v for k,v in result.items() if k!='observations'})
