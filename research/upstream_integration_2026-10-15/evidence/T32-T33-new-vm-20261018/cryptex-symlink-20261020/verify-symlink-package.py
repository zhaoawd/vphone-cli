from pathlib import Path
import hashlib,json,struct,subprocess
r=Path.cwd();source=r/'.build/t32-cryptex-reinstall-final.app';app=r/'.build/t32-cryptex-symlink-final.app';boot=r/'.build/t32-dsc-companions-final.app/Contents/MacOS/vphone-vm'
def sha(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def executable_content(p):
 data=p.read_bytes();assert struct.unpack_from('<I',data)[0]==0xfeedfacf
 offset=32;signature=None
 for _ in range(struct.unpack_from('<I',data,16)[0]):
  cmd,size=struct.unpack_from('<II',data,offset)
  if cmd==0x1d:
   assert signature is None;signature=(offset,struct.unpack_from('<II',data,offset+8)[0])
  offset+=size
 assert signature is not None
 command,end=signature
 return hashlib.sha256(data[:command+8]+data[command+16:end]).hexdigest()
subprocess.run([str(r/'.venv/bin/python3'),str(r/'scripts/check_bundle.py'),str(app)],check=True)
assert executable_content(app/'Contents/MacOS/vphone-cli')==executable_content(source/'Contents/MacOS/vphone-cli')
assert sha(boot)==sha(app/'Contents/MacOS/vphone-vm')=='a25bfd3af55c5a2af4aab1a84541be8328a430b5d8bd267be2704ba72ca54125'
assert boot.stat().st_ino==246999022 and boot.stat().st_dev==16777231
names=['cfw_install.sh','cfw_install_dev.sh','patchers/guest_write.py','patchers/component_transport.py']
resources=app/'Contents/Resources/scripts'
assert all(sha(r/'scripts'/name)==sha(resources/name) for name in names)
result=dict(hostCLI=str(app/'Contents/MacOS/vphone-cli'),hostSHA256=sha(app/'Contents/MacOS/vphone-cli'),hostExecutableContentUnchanged=True,hostSignatureRefreshed=True,hostContentSHA256=executable_content(app/'Contents/MacOS/vphone-cli'),bootExecutable=str(boot),bootSHA256=sha(boot),bootInode=boot.stat().st_ino,bootDevice=boot.stat().st_dev,bootBytesAndIdentityUnchanged=True,nestedVMBytesMatchOriginal=True,approvedCDHash='89b70a253cad2adea133b3e875519afaf72c5d17',scripts={name:sha(resources/name) for name in names},bundleValidationPassed=True)
(r/'.build/t32-cryptex-reinstall-debug/symlink-bundle-parity.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
