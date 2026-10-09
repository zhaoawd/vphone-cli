from pathlib import Path
import json,hashlib
out=Path('/private/tmp/vphone-b26-t46-helper');dest=out/'evidence';p=dest/'manifest.json';d=json.loads(p.read_text());files={f['path']:f for f in d['files']};observed={str(q.relative_to(dest)) for q in dest.rglob('*') if q.is_file() and q!=p};assert observed==set(files)
for name,row in files.items():
 q=dest/name;assert q.stat().st_size==row['size'];assert hashlib.file_digest(open(q,'rb'),'sha256').hexdigest()==row['sha256']
result={'status':'verified','files':len(files),'total_bytes':sum(f['size'] for f in files.values()),'manifest_sha256':hashlib.file_digest(open(p,'rb'),'sha256').hexdigest(),'excluded_binaries':True,'exact_directory_membership':True}
(out/'evidence-manifest-verification.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
