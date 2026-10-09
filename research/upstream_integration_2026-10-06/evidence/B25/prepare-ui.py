from pathlib import Path
import shutil,subprocess,plistlib,json,hashlib
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
base=Path('/private/tmp/vphone-b25-t46')
source=base/'source-current-launchpad.app'
assert not source.exists()
shutil.copytree(r/'.build/vphone-launchpad.app',source)
shutil.copy2(r/'.build/debug/vphone-launchpad',source/'Contents/MacOS/vphone-launchpad')
subprocess.run(['codesign','--force','--sign','-',str(source)],check=True)
original=(base/'prepare-ui-fixture.py').read_text()
for mode in ('normal','escaped'):
 evidence=base/('ui-'+mode);evidence.mkdir()
 app=base/('T46-'+mode+'.app')
 script=base/('prepare-'+mode+'.py')
 text=original.replace('const char *root = getenv("T46_UI_EVIDENCE");','const char *root = "'+str(evidence)+'";').replace('const char *mode = getenv("T46_UI_MODE");','const char *mode = "'+mode+'";').replace('i < 3000','i < 12000')
 script.write_text(text)
 subprocess.run(['python3',str(script),str(source),str(app)],check=True)
 info=app/'Contents/Info.plist';d=plistlib.loads(info.read_bytes());d['CFBundleIdentifier']='com.vphone.cli.launchpad.b25.'+mode;d['CFBundleName']='T46 '+mode;info.write_bytes(plistlib.dumps(d))
 subprocess.run(['codesign','--force','--sign','-','--identifier',d['CFBundleIdentifier'],str(app)],check=True)
 subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
 meta={'mode':mode,'app':str(app),'main_sha256':hashlib.sha256((app/'Contents/MacOS/vphone-launchpad').read_bytes()).hexdigest(),'controlled_cli':True,'self_release_seconds':120,'VM_started':False}
 (evidence/'artifact.json').write_text(json.dumps(meta,indent=2)+'\n')
print('prepared both isolated signed fixtures')
