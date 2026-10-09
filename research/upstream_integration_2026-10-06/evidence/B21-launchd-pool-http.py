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
 for batch in range(4):
  for i in range(10):rpc('services.status',{'label':'com.apple.SpringBoard'})
  time.sleep(.2)
  count=shell('test "$(ps -p 6504 -o comm= | tr -d " ")" = /private/var/root/vphone-b21-api/vphoned && /var/root/vphone-b21-api/fd-probe 6504')
  samples.append(int(count))
 result['launchd_call_count']=40;result['fd_samples_after_each_10']=samples;result['baseline_fd_count']=int(shell('/var/root/vphone-b21-api/fd-probe 6504'))
 result['no_cumulative_fd_growth']=max(samples)-min(samples)<=1
 assert result['no_cumulative_fd_growth']
 result['health_after']=health();result['completed']=True
finally:
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b21-launchd-pool-http.json').write_text(text)
print(result['fd_samples_after_each_10'])
