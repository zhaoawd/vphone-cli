from pathlib import Path
exec(Path('/private/tmp/vphone-b21-runtime.py').read_text().split("result={'target':target,'observations':rows}")[0])
def rpc(method,params={}):
 c=http.client.HTTPConnection('127.0.0.1',port,timeout=30)
 try:
  c.request('POST','/v1/rpc',body=json.dumps({'method':method,'params':params,'id':'b21-pool'}),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
  r=c.getresponse();raw=r.read();reply=json.loads(raw);assert r.status==200,(r.status,reply)
  assert 'result' in reply,reply
  value=reply['result']
  rows.append({'method':method,'response_bytes':len(raw),'response_sha256':hashlib.sha256(raw).hexdigest()})
  return value
 finally:c.close()

result={'observations':rows}
try:
 samples=[]
 for _ in range(2):rpc('screen.screenshot')
 def sample():
  p=rpc('processes.list',{'filter':'vphoned'})['processes'];worker=next(x for x in p if x['pid']==6504)
  count=int(shell('test "$(ps -p 6504 -o comm= | tr -d " ")" = /private/var/root/vphone-b21-api/vphoned && /var/root/vphone-b21-api/fd-probe 6504'))
  return {'resident_bytes':worker['resident_bytes'],'footprint_bytes':worker['footprint_bytes'],'fd_count':count}
 baseline=sample()
 for batch in range(4):
  for _ in range(5):rpc('screen.screenshot')
  time.sleep(.2);samples.append(sample())
 result.update(warmup=2,screenshots=20,baseline=baseline,samples=samples)
 tail=[x['resident_bytes'] for x in samples[1:]];result['last_three_resident_spread_bytes']=max(tail)-min(tail)
 assert result['last_three_resident_spread_bytes']<=16*1024*1024
 assert all(x['fd_count']==baseline['fd_count'] for x in samples)
 result['completed']=True
finally:
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b21-screenshot-pool-http.json').write_text(text)
print({k:v for k,v in result.items() if k!='observations'})
