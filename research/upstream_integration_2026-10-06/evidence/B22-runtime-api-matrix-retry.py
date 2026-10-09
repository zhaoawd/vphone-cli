from pathlib import Path
exec(Path('/private/tmp/vphone-b22-common.py').read_text())
a=json.loads(Path('/private/tmp/vphone-b22-final-artifact.json').read_text());assert health()['binary_hash']==a['sha256'];result={'artifact_sha256':a['sha256'],'observations':rows,'checks':[]}
def request(method,path,params=None):
 c=http.client.HTTPConnection('127.0.0.1',port,timeout=15)
 try:
  c.request(method,path,body=json.dumps(params) if params is not None else None,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
  r=c.getresponse();raw=r.read();reply=json.loads(raw);x={'http_method':method,'path':path,'status':r.status,'body':reply};result['checks'].append(x);return r.status,(reply.get('result',reply) if path=='/v1/timezone' else reply)
 finally:c.close()
def rpc_raw(method,params):return request('POST','/v1/rpc',{'id':'b22-matrix','method':method,'params':params})
baseline=None;location_set=False
try:
 status,b=request('GET','/v1/timezone');result['timezone_baseline']=b
 if status==200 and isinstance(b.get('automatic'),bool) and isinstance(b.get('identifier'),str):
  baseline=b
  for zone in ['America/New_York','Asia/Tokyo']:
   status,v=request('PUT','/v1/timezone',{'identifier':zone});assert status==200 and v['identifier']==zone and v['automatic'] is False
   status,v=request('PUT','/v1/timezone',{'identifier':zone});assert status==200 and v['changed'] is False
  for zone in ['../etc/passwd','Mars/Olympus']:
   status,v=request('PUT','/v1/timezone',{'identifier':zone});assert status==400
  status,v=request('PUT','/v1/timezone',{'automatic':True});assert status==200 and v['automatic'] is True
 else:result['timezone_set_unverified']='Baseline timezone or automatic setting unavailable; did not mutate'
 loc='/var/mobile/Library/Caches/vphone-location.json';exists=shell('test -e '+loc+' && echo exists || true').strip();result['location_initial_file_exists']=bool(exists)
 if not exists:
  location_set=True
  status,v=rpc_raw('location.set',{'latitude':31.2304,'longitude':121.4737});assert status==200
  status,v=rpc_raw('location.current',{});assert status==200 and v['result']['latitude']==31.2304 and v['result']['simulated'] is True
  status,v=rpc_raw('location.set',{'latitude':91,'longitude':0});assert status==400
  status,v=rpc_raw('location.set',{'latitude':float('nan'),'longitude':0});assert status==400
 p=Path('/private/tmp/vphone-b22-nonutf8');p.write_bytes(b'\xff\xfe\x00\x80abc')
 assert ctl('file_put',path='/var/root/vphone-b21-transfer/b22-nonutf8',load=str(p),perm='600')['ok']
 status,v=rpc_raw('files.read',{'path':'/var/root/vphone-b21-transfer/b22-nonutf8'});assert status==200 and base64.b64decode(v['result']['content'])==p.read_bytes()
 status,v=rpc_raw('services.status',{'label':'com.apple.SpringBoard'});assert status==200
 status,v=rpc_raw('bootstrap.status',{});result['bootstrap_query_status']=status
 result['cache_baseline']=shell('ls -ld /var/root/Library/Caches; for n in vphoned vphoned.next vphoned.api-v2 vphoned.api-v2.pending; do test ! -e /var/root/Library/Caches/$n || ls -ld /var/root/Library/Caches/$n; done')
 result['completed_checks']=True
except Exception as e:
 result['error']=repr(e);raise
finally:
 if location_set:
  status,v=rpc_raw('location.clear',{});result['location_restore_status']=status;result['location_file_absent_after']=not shell('test -e /var/mobile/Library/Caches/vphone-location.json && echo exists || true').strip();assert status==200 and result['location_file_absent_after']
 if baseline:
  status,v=request('PUT','/v1/timezone',{'identifier':baseline['identifier']});assert status==200
  status,v=request('PUT','/v1/timezone',{'automatic':baseline['automatic']});assert status==200
  status,v=request('GET','/v1/timezone');result['timezone_restored']=status==200 and v['identifier']==baseline['identifier'] and v['automatic']==baseline['automatic'];assert result['timezone_restored']
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b22-runtime-api-matrix-retry.json').write_text(text)
print({k:v for k,v in result.items() if k not in ['observations','checks']})
