import pathlib,subprocess,shutil,json,hashlib
out=pathlib.Path('/private/tmp/vphone-b26-t46-helper');app=out/'TransportHarness.app';svc=app/'Contents/XPCServices/com.vphone.acceptance.t46.service.xpc';cert='5620D69F097306848C7CCD69F0B796A3C588BF28';records=[]
for bundle,role in [(svc,'service'),(app,'client')]:
 (bundle/'Contents/MacOS').mkdir(parents=True,exist_ok=True);(bundle/'Contents/Frameworks').mkdir(parents=True,exist_ok=True)
 shutil.copy2(out/'TransportHarness',bundle/'Contents/MacOS/TransportHarness');shutil.copy2(out/f'Transport-{role}.proposed.plist',bundle/'Contents/Info.plist')
 shutil.copytree(out/'stable/debug/libarchive.framework',bundle/'Contents/Frameworks/libarchive.framework',symlinks=True)
def run(args):
 p=subprocess.run(args,text=True,capture_output=True,timeout=25);r={'argv':args,'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr};records.append(r);(out/'sign-readback.json').write_text(json.dumps(records,indent=2)+'\n');print(args[0:3],p.returncode,p.stderr[:500],flush=True)
 if p.returncode:raise SystemExit(p.returncode)
for bundle,ident in [(svc,'com.vphone.acceptance.t46.service'),(app,'com.vphone.acceptance.t46.client')]:
 run(['codesign','--force','--sign',cert,str(bundle/'Contents/Frameworks/libarchive.framework')])
 run(['codesign','--force','--sign',cert,'--identifier',ident,str(bundle)])
for bundle,ident in [(svc,'com.vphone.acceptance.t46.service'),(app,'com.vphone.acceptance.t46.client')]:
 req=f'anchor apple generic and identifier "{ident}" and certificate leaf[subject.OU] = "3AA3QL69MQ"'
 run(['codesign','--verify','--strict','--deep','-R='+req,str(bundle)])
 run(['codesign','-dvvv',str(bundle)])
 run(['codesign','-d','--entitlements','-','--xml',str(bundle)])
files=[]
for p in app.rglob('*'):
 if p.is_file():files.append({'path':str(p.relative_to(app)),'sha256':hashlib.file_digest(open(p,'rb'),'sha256').hexdigest(),'bytes':p.stat().st_size})
(out/'signed-harness-manifest.json').write_text(json.dumps(files,indent=2)+'\n')
