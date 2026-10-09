import pathlib,subprocess,json,hashlib,plistlib
repo=pathlib.Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');out=pathlib.Path('/private/tmp/vphone-b26-t46-helper');rev='dd3c800277605589ae1cb2466a2b33fa33e549d1';team='3AA3QL69MQ'
def req(i):return f'anchor apple generic and identifier "{i}" and certificate leaf[subject.OU] = "{team}"'
def digest(b):return hashlib.sha256(b).hexdigest()
paths=subprocess.check_output(['git','ls-tree','-r','--name-only',rev,'sources/VPhoneHelperKit','sources/VPhoneHelperEntry'],cwd=repo,text=True).splitlines()+['scripts/build_helper_candidate.sh','Package.swift','Package.resolved']
manifest=[]
for name in paths:
 p=subprocess.run(['git','show',f'{rev}:{name}'],cwd=repo,capture_output=True)
 if p.returncode:continue
 target=out/'legacy-v1-source'/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(p.stdout)
 manifest.append({'path':name,'sha256':digest(p.stdout),'git_blob':subprocess.check_output(['git','rev-parse',f'{rev}:{name}'],cwd=repo,text=True).strip()})
(out/'legacy-v1-source-manifest.json').write_text(json.dumps({'source_revision':rev,'note':'Historical source candidate; no claim that this commit built the original B13 adhoc binary. No build performed.','files':manifest},indent=2)+'\n')
info={'CFBundleIdentifier':'com.vphone.cli.helper','CFBundleVersion':'1','CFBundleShortVersionString':'2.0.8','VPhoneHelperSigningTeam':team,'SMAuthorizedClients':[req(i) for i in ['com.vphone.cli','com.vphone.cli.launchpad']]}
(out/'Legacy-Helper-Info.proposed.plist').write_bytes(plistlib.dumps(info))
(out/'Legacy-Helper-Launchd.proposed.plist').write_bytes(plistlib.dumps({'Label':'com.vphone.cli.helper','MachServices':{'com.vphone.cli.helper':True}}))
for role,ident in [('client','com.vphone.acceptance.t46.client'),('service','com.vphone.acceptance.t46.service')]:
 info={'CFBundleIdentifier':ident,'CFBundleExecutable':'TransportHarness','CFBundleVersion':'1','CFBundlePackageType':'XPC!' if role=='service' else 'APPL','B26HarnessRole':role}
 if role=='service':info['XPCService']={'ServiceType':'Application','RunLoopType':'dispatch_main'}
 (out/f'Transport-{role}.proposed.plist').write_bytes(plistlib.dumps(info))
sources=['sources/VPhoneHelperKit/VPhoneHelperOutput.swift','sources/VPhoneHelperKit/VPhoneHelperClient.swift','sources/VPhoneHelperKit/VPhoneHelperService.swift','sources/VPhoneCore/VPhoneLogWriter.swift','tests/VPhoneHelperKitTests/OutputXPCTests.swift','tests/VPhoneHelperKitTests/OutputAcknowledgementTests.swift']
(out/'current-source-manifest.json').write_text(json.dumps({'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),'files':[{'path':n,'sha256':digest((repo/n).read_bytes())} for n in sources]},indent=2)+'\n')
print('legacy source files',len(manifest),'harness prepared; no build/sign/run')
