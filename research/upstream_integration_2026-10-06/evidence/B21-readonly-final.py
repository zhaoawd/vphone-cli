from pathlib import Path
exec(Path('/private/tmp/vphone-b21-runtime.py').read_text().split("result={'target':target,'observations':rows}")[0])
result={'observations':rows,'methods':{}}
for method,params in [('display.rotation',{}),('services.status',{'label':'com.apple.SpringBoard'}),('device.snapshot',{}),('files.read',{'path':'/var/root/vphone-b21-transfer/8191'}),('location.current',{})]:
 c=http.client.HTTPConnection('127.0.0.1',port,timeout=12)
 try:
  c.request('POST','/v1/rpc',body=json.dumps({'method':method,'params':params,'id':'b21-readonly'}),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'});r=c.getresponse();b=r.read();v=json.loads(b)
  result['methods'][method]={'status':r.status,'response_bytes':len(b),'response_sha256':hashlib.sha256(b).hexdigest()}
  if method in ['display.rotation','services.status']:result['methods'][method]['value']=v
 except Exception as e:result['methods'][method]={'error':type(e).__name__+': '+str(e)}
 finally:c.close()
result['health_after']=health();text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b21-readonly-final.json').write_text(text);print(result['methods'])
