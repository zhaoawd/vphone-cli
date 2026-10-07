import hashlib,json,os,re,subprocess
from pathlib import Path
p=subprocess.run(['/usr/bin/security','find-identity','-v','-p','codesigning'],capture_output=True,text=True)
rows=re.findall(r'\d+\) ([0-9A-Fa-f]{40}) "([^"\n]+)"',p.stdout)
result={'valid_identity_count':len(rows),'apple_team_id_available':False}
if len(rows)==1:
 fingerprint,name=rows[0]
 cert=subprocess.run(['/usr/bin/security','find-certificate','-c',name,'-p'],capture_output=True)
 subject=subprocess.run(['/usr/bin/openssl','x509','-noout','-subject','-nameopt','RFC2253'],input=cert.stdout,capture_output=True).stdout.decode()
 m=re.search(r'(?:^|,)OU=([A-Z0-9]{10})(?:,|$)',subject)
 result['certificate_sha1']=fingerprint.lower()
 result['apple_team_id_available']=m is not None
 if m:
  result['team']=m[1]
  path=Path('/private/tmp/vphone-b13-signing-selection.json')
  fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
  with os.fdopen(fd,'w') as f:json.dump({'identity':fingerprint,'team':m[1]},f)
output=Path('/private/tmp/vphone-b13-signing-metadata.json');assert not output.exists();output.write_text(json.dumps(result,indent=2)+'\n');print(result)
