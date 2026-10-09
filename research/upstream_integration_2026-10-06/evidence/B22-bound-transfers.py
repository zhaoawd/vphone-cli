from pathlib import Path
exec(Path('/private/tmp/vphone-b22-bound-common.py').read_text())
a=json.loads(Path('/private/tmp/vphone-b22-cache-fixed-artifact.json').read_text());assert health()['binary_hash']==a['sha256']
result={'artifact_sha256':a['sha256'],'downloads':[],'observations':rows}
try:
 for size in [8191,8192,8193,16383,16384,16385,1048576,4194304,8388608]:
  raw=bytes(i%251 for i in range(size));p=Path('/private/tmp/vphone-b22-transfer-'+str(size));p.write_bytes(raw)
  assert ctl('file_put',path='/var/root/vphone-b21-transfer/'+str(size),load=str(p),perm='600')['ok']
 for size,slow in [(n,False) for n in [8191,8192,8193,16383,16384,16385]]+[(1048576,False)]*5+[(1048576,True),(4194304,False),(4194304,True),(8388608,False),(8388608,True)]:
  expected=bytes(i%251 for i in range(size));c=http.client.HTTPConnection('127.0.0.1',port,timeout=12);data=bytearray();row={'size':size,'slow':slow};start=time.monotonic()
  try:
   c.request('GET','/v1/files/content?path='+urllib.parse.quote('/var/root/vphone-b21-transfer/'+str(size),safe=''),headers={'Authorization':'Bearer '+token});reply=c.getresponse();row['status']=reply.status
   while True:
    b=reply.read(1024 if slow else 16384)
    if not b:break
    data.extend(b)
    if slow:time.sleep(.002)
  except Exception as e:row['error']=type(e).__name__+': '+str(e)
  finally:c.close()
  row.update(bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),elapsed=time.monotonic()-start,passed=data==expected);result['downloads'].append(row);print(row,flush=True)
 result['complete']=all(row['passed'] and row['status']==200 for row in result['downloads'])
finally:
 text=json.dumps(result,indent=2)+'\n';assert token not in text;Path('/private/tmp/vphone-b22-bound-transfers.json').write_text(text)
assert result['complete']
