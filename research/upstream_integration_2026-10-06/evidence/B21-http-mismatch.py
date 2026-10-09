from pathlib import Path
exec(Path('/private/tmp/vphone-b21-runtime.py').read_text().split("result={'target':target,'observations':rows}")[0])
c=http.client.HTTPConnection('127.0.0.1',port,timeout=3);data=bytearray();result={}
try:
 c.request('GET','/v1/files/content?path='+urllib.parse.quote('/var/root/vphone-b21-transfer/1048576',safe=''),headers={'Authorization':'Bearer '+token});r=c.getresponse();result['headers']=dict(r.getheaders())
 while True:
  b=r.read(1024)
  if not b:break
  data.extend(b)
except Exception as e:result['error']=str(e)
finally:
 c.close();result['bytes']=len(data);result['sha256']=hashlib.sha256(data).hexdigest();result['first_mismatches']=[{'offset':i,'actual':v,'expected':i%251} for i,v in enumerate(data) if v!=i%251][:10];result['blocks']=[{'offset':i,'first16_hex':data[i:i+16].hex()} for i in range(0,len(data),65536)];Path('/private/tmp/vphone-b21-http-mismatch.json').write_text(json.dumps(result,indent=2)+'\n');Path('/private/tmp/vphone-b21-synthetic-download.bin').write_bytes(data)
print(result)
