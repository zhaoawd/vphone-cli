from pathlib import Path
import hashlib,json,plistlib,shutil,subprocess
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');stage=r/'.build/acceptance/B22/local-core';assert not stage.exists();stage.mkdir();bundle=stage/'VPhone.bundle';shutil.copytree(r/'.build/vphone-cli.app',bundle,symlinks=True)
vm=r/'.build/acceptance/B21/relay-diagnostic.app/Contents/MacOS/vphone-vm';assert hashlib.sha256(vm.read_bytes()).hexdigest()=='1d21a984f4621fcc291ebc6d48bc572ec1c316752183dbcf40469a7778a4eb80';shutil.copy2(vm,bundle/'Contents/MacOS/vphone-vm')
escalator=r/'.build/acceptance/B22/escalator-build/vphone-escalator';shutil.copy2(escalator,bundle/'Contents/MacOS/vphone-escalator')
up=Path('/private/tmp/vphone-upstream-source-20261006/VPhoneExecutable/VPhoneEscalator/VPhoneEscalator');shutil.copy2(up/'LICENSE',bundle/'Contents/Resources/scripts/licenses/vphone-escalator-MIT.txt')
source={'schema':'vphone.integration.local-core-candidate','upstream_target':'2d21d21fbdd4f51f013616273ceda9b35a3e0789','host_source_base':'f6ebd1799b632ee4b84f869ed70b0508e9f0ddb7','host_candidate_evidence':'B21-final-artifacts.json','host_integration_complete':False,'release_validation_complete':False,'VM_SHA256':hashlib.sha256(vm.read_bytes()).hexdigest(),'VM_CDHash':'4cea360ca924a4c651a12aae7755545b492a59b6','VM_instrumentation':'SO_TYPE and relay byte counters only; authorized frozen artifact','escalator_source_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in up.iterdir() if p.is_file()},'escalator_executed':False,'automatic_guest_update_authorized':False,'external_runtime_libraries':'B22-runtime-closure.json; current Mac only; not a portable distribution'}
version='2.6.1-local.'+hashlib.sha256(json.dumps(source,sort_keys=True).encode()).hexdigest()[:16];source['store_version']=version
p=bundle/'Contents/Info.plist';info=plistlib.loads(p.read_bytes());info['CFBundleShortVersionString']='2.6.1';info['CFBundleVersion']='B22-integration-candidate';p.write_bytes(plistlib.dumps(info));(bundle/'Contents/Resources/integration-provenance.json').write_text(json.dumps(source,indent=2)+'\n')
rows=[]
def call(*args):
 p=subprocess.run(args,capture_output=True,text=True);rows.append({'command':list(args),'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr});assert p.returncode==0,rows[-1];return p.stdout
call('/usr/bin/codesign','--force','--sign','-',str(bundle/'Contents/MacOS/vphone-escalator'))
call('/usr/bin/codesign','--force','--sign','-',str(bundle));call('/usr/bin/codesign','--verify','--strict','--deep',str(bundle))
for name in ['vphone-cli','vphone-vm','vphone-escalator']:
 call('/usr/bin/codesign','--verify','--strict',str(bundle/'Contents/MacOS'/name));call('/usr/bin/lipo','-archs',str(bundle/'Contents/MacOS'/name))
assert hashlib.sha256((bundle/'Contents/MacOS/vphone-vm').read_bytes()).hexdigest()==source['VM_SHA256']
archive=stage/'VPhone.zip';call('/usr/bin/ditto','-c','-k','--keepParent','--norsrc',str(bundle),str(archive))
report={'version':version,'bundle':str(bundle),'archive':str(archive),'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'provenance':source,'observations':rows,'packaging_verified':True,'installed':False,'escalator_executed':False}
Path('/private/tmp/vphone-b22-local-core-bundle.json').write_text(json.dumps(report,indent=2)+'\n');print({k:v for k,v in report.items() if k in ['version','archive','archive_sha256','packaging_verified']})
