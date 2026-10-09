from pathlib import Path
exec(Path('/private/tmp/vphone-b22-common.py').read_text())
result={'observations':rows,'downloads':[]}
try:
 assert not shell('ps -A -o comm= | grep -E "vphone-b21-api/vphoned$" || true').strip()
 time.sleep(.5)
 assert 'vsock-probe' not in shell('ps -A -o comm= | grep vsock-probe || true')
 r=ctl('file_put',path='/var/root/vphone-b21-api/vsock-probe',load='/private/tmp/vphone-b22-vsock-corrected',perm='755');assert r['ok']
 for trial,mode in enumerate([3,3,3,1,1,1,4,4,4]):
  assert not shell('ps -A -o comm= | grep -E "vphone-b21-api/(vphoned|vsock-probe)$" || true').strip()
  shell('/var/root/vphone-b21-api/vsock-probe '+str(mode)+' </dev/null >/var/root/vphone-b21-api/b22-vsock-v2-'+str(trial)+'.log 2>&1 &')
  time.sleep(.3)
  c=http.client.HTTPConnection('127.0.0.1',port,timeout=8);raw=bytearray();x={'mode':mode,'trial':trial}
  try:
   c.request('GET','/v1/files/content?path=synthetic',headers={'Authorization':'Bearer '+token});r=c.getresponse();x['status']=r.status
   while True:
    b=r.read(16384)
    if not b:break
    raw.extend(b)
  except Exception as e:x['error']=type(e).__name__+': '+str(e)
  finally:c.close()
  x.update(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest());result['downloads'].append(x)
  for _ in range(60):
   if not shell('ps -A -o comm= | grep -E "vphone-b21-api/vsock-probe$" || true').strip():break
   time.sleep(.3)
  x['trace']=shell('cat /var/root/vphone-b21-api/b22-vsock-v2-'+str(trial)+'.log')
finally:
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b22-native-transfer-corrected-retry.json').write_text(text)
print({k:[{a:b for a,b in x.items() if a!='trace'} for x in v] for k,v in result.items() if k=='downloads'})
