import hashlib,json,pathlib,shutil,subprocess
P=pathlib.Path; OUT=P('/private/tmp/vphone-b28-t40'); ROOT=OUT/'runtime-v1'
source=P('/opt/homebrew/lib/libusb-1.0.dylib').resolve(); target=ROOT/'lib/libusb-1.0.dylib'
assert not target.exists()
otool=subprocess.run(['/usr/bin/otool','-L',str(source)],capture_output=True,text=True,check=True)
(OUT/'lazy-usb-otool.stdout').write_text(otool.stdout)
with source.open('rb') as f: digest=hashlib.file_digest(f,'sha256').hexdigest()
info={'source':str(source),'target':str(target),'bytes':source.stat().st_size,'sha256':digest,'native_links':otool.stdout}
shutil.copy2(source,target)
with target.open('rb') as f: assert hashlib.file_digest(f,'sha256').hexdigest()==digest
report={'added_dylib':info,'commands':[]}
for label,argv in [('sandbox-launcher-lazy-usb-copied',['/usr/bin/sandbox-exec','-f',str(OUT/'deny-original.sb'),str(ROOT/'python-runtime'),str(ROOT/'lazy_usb_probe.py')]),('copy-libusb-signature',['/usr/bin/codesign','--verify','--strict','--verbose=2',str(target)])]:
 r=subprocess.run(argv,cwd=OUT,env={'PATH':'/usr/bin:/bin','HOME':str(ROOT),'TMPDIR':str(OUT),'PYTHONDONTWRITEBYTECODE':'1'},capture_output=True,timeout=120)
 (OUT/(label+'.stdout')).write_bytes(r.stdout); (OUT/(label+'.stderr')).write_bytes(r.stderr)
 entry={'label':label,'argv':argv,'returncode':r.returncode,'stdout':label+'.stdout','stderr':label+'.stderr'};report['commands'].append(entry)
 print(json.dumps(entry)); print(r.stdout.decode(errors='replace')[:300]); print(r.stderr.decode(errors='replace')[:500])
(OUT/'lazy-native-copy-trial.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(info))
