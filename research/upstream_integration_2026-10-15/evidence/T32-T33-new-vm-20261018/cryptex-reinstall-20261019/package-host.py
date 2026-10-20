from pathlib import Path
import hashlib,json,shutil,subprocess
r=Path.cwd();source=r/'.build/t32-undo-mount-final.app';app=r/'.build/t32-cryptex-reinstall-final.app';boot=r/'.build/t32-dsc-companions-final.app/Contents/MacOS/vphone-vm'
def sha(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
before=boot.stat();boot_sha=sha(boot);assert boot_sha=='a25bfd3af55c5a2af4aab1a84541be8328a430b5d8bd267be2704ba72ca54125'
assert not app.exists();shutil.copytree(source,app,symlinks=True)
shutil.copy2(r/'.build/release/vphone-cli',app/'Contents/MacOS/vphone-cli')
for name in ['cfw_install.sh','cfw_install_host.sh']:shutil.copy2(r/'scripts'/name,app/'Contents/Resources/scripts'/name)
subprocess.run([str(r/'.venv/bin/python3'),str(r/'scripts/build_native_dependencies.py'),str(app)],check=True)
vm=app/'Contents/MacOS/vphone-vm'
if sha(vm)!=boot_sha:shutil.copy2(boot,vm)
subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(app)],check=True)
subprocess.run([str(r/'.venv/bin/python3'),str(r/'scripts/record_build_dependencies.py'),str(app)],check=True)
subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(app)],check=True)
subprocess.run([str(r/'.venv/bin/python3'),str(r/'scripts/check_bundle.py'),str(app)],check=True)
after=boot.stat();assert sha(boot)==boot_sha and all(getattr(before,k)==getattr(after,k) for k in ['st_dev','st_ino','st_size','st_mtime_ns'])
assert sha(vm)==boot_sha
cli=app/'Contents/MacOS/vphone-cli';help_text=subprocess.check_output([str(cli),'cfw','install','--help'],text=True)
assert '--reinstall-cryptex' in help_text
parity=dict(hostCLI=str(cli),hostSHA256=sha(cli),bootExecutable=str(boot),bootSHA256=boot_sha,bootInode=before.st_ino,bootDevice=before.st_dev,bootBytesAndIdentityUnchanged=True,nestedVMBytesMatchOriginal=True,approvedCDHash='89b70a253cad2adea133b3e875519afaf72c5d17',scripts={name:sha(r/'scripts'/name) for name in ['cfw_install.sh','cfw_install_host.sh']},bundleValidationPassed=True)
(r/'.build/t32-rebaseline-debug/reinstall-bundle-parity.json').write_text(json.dumps(parity,indent=2)+'\n');print(json.dumps(parity))
