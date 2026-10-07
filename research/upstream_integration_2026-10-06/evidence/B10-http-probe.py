import http.client,json,re,time
from pathlib import Path
log=Path('/private/tmp/vphone-b10-boot.log');token=Path('/private/tmp/vphone-b10-token').read_text();deadline=time.monotonic()+30
while True:
 m=re.search(r'\[api\] proxy listening on http://127\.0\.0\.1:(\d+)',log.read_text(errors='replace'))
 if m:break
 if time.monotonic()>deadline:raise RuntimeError('proxy address not observed')
 time.sleep(1)
port=int(m[1]);results=[]
for case,auth in [('missing',None),('incorrect','b10-deliberately-incorrect-token'),('correct',token)]:
 conn=http.client.HTTPConnection('127.0.0.1',port,timeout=20)
 headers={'Host':f'127.0.0.1:{port}'}
 if auth:headers['Authorization']='Bearer '+auth
 started=time.monotonic()
 try:
  conn.request('GET','/v1/health',headers=headers);res=conn.getresponse();body=res.read(16384)
  results.append({'authentication':case,'status':res.status,'body':body.decode(errors='replace'),'elapsed_seconds':round(time.monotonic()-started,3)})
 except Exception as e:results.append({'authentication':case,'error':f'{type(e).__name__}: {e}'})
 finally:conn.close()
Path('/private/tmp/vphone-b10-http-probe.json').write_text(json.dumps({'port':port,'binding':'127.0.0.1','token_saved_to_evidence':False,'results':results},indent=2)+'\n');print(results)
