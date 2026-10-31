"""Check the frozen VM parser without booting; require the expected exit 64."""
import datetime,hashlib,json,subprocess
from pathlib import Path
r=Path(__file__).resolve().parents[2]
p=r/'.build/t32-dsc-companions-final.app/Contents/MacOS/vphone-vm'
assert hashlib.sha256(p.read_bytes()).hexdigest()=='a25bfd3af55c5a2af4aab1a84541be8328a430b5d8bd267be2704ba72ca54125'
assert p.stat().st_ino==246999022
args=[str(p),'--config',str(r/'vm-t32-t33-dsc-20261018/config.plist'),'--vphone-acceptance-invalid-option']
a=subprocess.run(args,capture_output=True,timeout=20)
now=datetime.datetime.now(datetime.timezone.utc)
record=dict(recordedAt=now.isoformat(),argv=args,exitCode=a.returncode,sha256=hashlib.sha256(p.read_bytes()).hexdigest(),inode=p.stat().st_ino,scope='parameter parsing only; no VM boot',output=a.stdout.decode(errors='replace')+a.stderr.decode(errors='replace'),passed=a.returncode==64)
(Path(__file__).parent/('boot-readiness-'+now.strftime('%H%M%S%f')+'.json')).write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record,indent=2))
raise SystemExit(0 if record['passed'] else 1)
