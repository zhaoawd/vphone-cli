import pathlib,json,subprocess,hashlib,datetime
repo=pathlib.Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');out=pathlib.Path('/private/tmp/vphone-b26-t24')
def run(args):
 p=subprocess.run(args,cwd=repo,text=True,capture_output=True,timeout=20)
 return {'argv':list(map(str,args)),'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
def sha(p):return hashlib.file_digest(open(p,'rb'),'sha256').hexdigest()
files={
 'vm':repo/'.build/vphone-cli.app/Contents/MacOS/vphone-vm',
 'embedded_vm':repo/'.build/vphone-launchpad.app/Contents/Helpers/vphone-cli.app/Contents/MacOS/vphone-vm',
 'debug_vm':repo/'.build/arm64-apple-macosx/debug/vphone-vm',
 'historical_v1_helper':repo/'.build/acceptance/B13/prior-helper-candidate/com.vphone.cli.helper'}
d={'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'Read-only artifact validation; no VM execution, GUI, service registration, signing, TCC or AMFI changes.','head':run(['git','rev-parse','HEAD']),'artifacts':{}}
for name,p in files.items():
 a={'path':str(p),'exists':p.exists()};d['artifacts'][name]=a
 if p.exists():
  a['sha256']=sha(p);a['checks']=[run(['codesign','-dvvv',str(p)]),run(['codesign','-d','--entitlements','-','--xml',str(p)]),run(['codesign','--verify','--strict',str(p)])]
 if name=='historical_v1_helper' and p.exists():a['configuration_check']=run([str(p),'--check-configuration'])
d['installed_helper_exists']=pathlib.Path('/Library/PrivilegedHelperTools/com.vphone.cli.helper').exists()
d['launchd_job']=run(['launchctl','print','system/com.vphone.cli.helper'])
d['csrutil_status']=run(['/usr/bin/csrutil','status'])
d['bootargs_sandbox_probe']=run(['/usr/sbin/sysctl','kern.bootargs'])
(out/'artifact-readback.json').write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
print('head',d['head']['stdout'].strip())
for name,a in d['artifacts'].items():
 print(name,a.get('sha256'));print(a['checks'][0]['stderr']);print(a['checks'][1]['stdout']);print('strict_verify',a['checks'][2]['exit_code'])
 if a.get('configuration_check'): print('configuration',a['configuration_check'])
print('job',d['launchd_job']);print('installed_helper',d['installed_helper_exists'])
