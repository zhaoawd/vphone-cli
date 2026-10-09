from pathlib import Path
import sys, subprocess, json, hashlib, plistlib, tempfile, shutil
repo=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
base=Path('/private/tmp/vphone-b25-t46')
source=repo/'.build/vphone-launchpad.app'
mode=sys.argv[1]
assert mode in ('normal','escaped')
dest=base/f'T46-{mode}.app';evidence=base/f'ui-final-{mode}'
assert not dest.exists() and not evidence.exists()
evidence.mkdir()
script=(base/'prepare-ui-fixture.py').read_text()
script=script.replace('getenv("T46_UI_EVIDENCE")',json.dumps(str(evidence)))
script=script.replace('getenv("T46_UI_MODE")',json.dumps(mode))
script=script.replace('i < 3000','i < 12000')
custom=base/f'prepare-final-{mode}.py';custom.write_text(script)
subprocess.run([sys.executable,str(custom),str(source),str(dest)],check=True)
p=dest/'Contents/Info.plist'
info=plistlib.loads(p.read_bytes());info['CFBundleIdentifier']=f'com.vphone.cli.launchpad.b25.{mode}';p.write_bytes(plistlib.dumps(info))
subprocess.run(['/usr/bin/codesign','--force','--sign','-','--identifier',info['CFBundleIdentifier'],str(dest)],check=True)
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(dest)],check=True)
a=source/'Contents/MacOS/vphone-launchpad';b=dest/'Contents/MacOS/vphone-launchpad'
with tempfile.TemporaryDirectory(prefix='vphone-b25-ui-code-') as scratch:
 copies=[]
 for i,original in enumerate((a,b)):
  copy=Path(scratch)/f'main-{i}';shutil.copyfile(original,copy)
  subprocess.run(['/usr/bin/codesign','--remove-signature',str(copy)],check=True)
  copies.append(copy.read_bytes())
 assert copies[0]==copies[1], 'UI executable code differs after signature removal'
 unsigned_sha=hashlib.sha256(copies[0]).hexdigest()
record={'mode':mode,'app':str(dest),'source_app':str(source),'source_head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),'main_sha256':hashlib.sha256(b.read_bytes()).hexdigest(),'source_main_sha256':hashlib.sha256(a.read_bytes()).hexdigest(),'unsigned_main_sha256':unsigned_sha,'main_identical_after_signature_removal':True,'controlled_cli':True,'evidence_directory':str(evidence),'self_release_seconds':120,'VM_started':False}
(evidence/'artifact.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record))
