import hashlib,json,plistlib,shutil,subprocess,tempfile
from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');exe=r/'.build/acceptance/B13/candidate.app/Contents/MacOS/vphone-cli';d=Path(tempfile.mkdtemp(prefix='vphone-b13-binding-',dir='/private/tmp'));vm=d/'sample';vm.mkdir()
config=Path('/Users/qcz3840/github/vphone-cli/vm-new/config.plist').read_bytes();(vm/'config.plist').write_bytes(config);(vm/'Disk.img').write_bytes(b'test-only disk; never boot')
version='2.6.1-local.55fd8ef5';binding=json.dumps({'bundle':version}).encode();rows=[]
def run(name,args):
 x=subprocess.run([str(exe),*args],capture_output=True,text=True,timeout=30);rows.append({'case':name,'arguments':args,'returncode':x.returncode,'stdout':x.stdout,'stderr':x.stderr});assert x.returncode!=0
 assert (vm/'config.plist').read_bytes()==config
try:
 (vm/'launchpad.json').write_bytes(binding)
 run('missing-installed-bundle',['vm','launch','sample','--library-root',str(d)])
 run('bound-project-root-refused',['vm','launch','sample','--library-root',str(d),'--project-root','/private/tmp'])
 (vm/'launchpad.json').write_bytes(b'{broken')
 run('corrupt-binding-refused',['vm','launch','sample','--library-root',str(d)])
 (vm/'launchpad.json').unlink()
 run('target-below-minimum-refused',['vm','bind-core-bundle','sample','--library-root',str(d),'--version','2.5.9','--backup',str(d/'backup')])
 run('missing-bundle-refused-before-migration',['vm','bind-core-bundle','sample','--library-root',str(d),'--version',version,'--backup',str(d/'backup')])
 assert not (d/'backup').exists() and not (vm/'launchpad.json').exists()
 result={'source_head':'55fd8ef57a6731e42cba0727f477bc9b25f0c9ca','rows':rows,'config_unchanged':True,'backup_not_created':True,'binding_not_published':True,'real_VM_not_touched':True,'VM_boot_was_not_required':True}
 p=Path('/private/tmp/vphone-b13-binding-cli-acceptance.json');assert not p.exists();p.write_text(json.dumps(result,indent=2)+'\n');print({'cases':[(x['case'],x['returncode']) for x in rows],'config_unchanged':True})
finally:shutil.rmtree(d)
