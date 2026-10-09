from pathlib import Path
exec(Path('/private/tmp/vphone-b21-runtime.py').read_text().split("result={'target':target,'observations':rows}")[0])
records=[]
for n in [1048576]:
 c=http.client.HTTPConnection('127.0.0.1',port,timeout=5);rec={'expected_bytes':n};raw=bytearray()
 try:
  c.request('GET','/v1/files/content?path='+urllib.parse.quote('/var/root/vphone-b21-transfer/'+str(n),safe=''),headers={'Authorization':'Bearer '+token});r=c.getresponse();rec.update(status=r.status,headers=dict(r.getheaders()))
  while True:
   b=r.read(1024)
   if not b:break
   raw.extend(b)
 except Exception as e:rec['error']=type(e).__name__+': '+str(e)
 finally:
  c.close();rec.update(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest(),prefix_equal=bytes(raw)==bytes(i%251 for i in range(len(raw))));records.append(rec)
Path('/private/tmp/vphone-b21-http-count.json').write_text(json.dumps(records,indent=2)+'\n');print(records)
