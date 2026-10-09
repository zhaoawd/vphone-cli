from pathlib import Path
p=Path('/private/tmp/vphone-b22-common.py').read_text().replace("assert run['pid']==json.loads(Path('/private/tmp/vphone-b22-boot-boot-process.json').read_text())['pid']", "assert run['pid']==53680 and run['instanceID']=='822503AF-2684-43AC-8348-25248550D948'").replace('vphone-b22-boot-boot.log','vphone-b22-bound-boot.log').replace('vphone-b22-boot-token','vphone-b22-bound-token')
Path('/private/tmp/vphone-b22-bound-common.py').write_text(p)
exec(p)
candidate=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/.build/acceptance/B22/api-cache-fixed/vphoned')
sha=hashlib.sha256(candidate.read_bytes()).hexdigest()
assert sha=='83075a0c9de2ff5bbfd01b211ce204f59bd18cdf9eb0efb7bd0891a62f00bc07'
classic=ctl('file_get',path='/usr/bin/vphoned');assert hashlib.sha256(base64.b64decode(classic['data'])).hexdigest()=='306ed42ba743f6d5e71ebda142eeaa78f1f21fa14d3b37445dee8fc1401f9001'
assert not shell('ps -A -o comm= | grep vphone-b21-api/vphoned || true').strip()
assert ctl('file_put',path='/var/root/vphone-b21-api/vphoned',load=str(candidate),perm='755')['ok']
shell('VPHONE_API_ONLY=1 /var/root/vphone-b21-api/vphoned </dev/null >/var/root/vphone-b21-api/b22-bound.log 2>&1 &')
for _ in range(100):
 try:
  h=health()
  if h['binary_hash']==sha:break
 except Exception:pass
 time.sleep(.25)
else:raise RuntimeError('API not ready')
result={'target':target,'health':h,'classic_sha256':hashlib.sha256(base64.b64decode(classic['data'])).hexdigest(),'observations':rows}
s=json.dumps(result,indent=2);assert token not in s;Path('/private/tmp/vphone-b22-bound-setup.json').write_text(s+'\n')
for name in ['transfers','close-ws','memory']:
 src=Path('/private/tmp/vphone-b22-final-'+name+'.py').read_text().replace('vphone-b22-common.py','vphone-b22-bound-common.py').replace('vphone-b22-final-artifact.json','vphone-b22-cache-fixed-artifact.json').replace('vphone-b22-final-'+name+'.json','vphone-b22-bound-'+name+'.json')
 Path('/private/tmp/vphone-b22-bound-'+name+'.py').write_text(src)
print({'target':target,'health':h})
