import subprocess,json,hashlib,shutil,fcntl,os,stat
from pathlib import Path
assert os.geteuid()==0
root=Path('/Library/Application Support/vphone-launchpad/Bundles');cli=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/.build/acceptance/B18/binding-cli.app/Contents/MacOS/vphone-cli')
assert not Path('/Users/qcz3840/github/vphone-cli/vm-new/launchpad.json').exists()
expected={'2.6.0':'ea389bba953eeff6d75f54c42d100dde6ffa6907adac84a40d56a35d08e78761','2.6.1':'651224d58064c59159e47b4a5fb066ca6dc758bdd221a346d43465cd34df5420'}
rows=[]
for version,digest in expected.items():
 x=subprocess.run([str(cli),'core-bundle','verify','--version',version],capture_output=True,text=True,timeout=20);assert x.returncode==0,x.stderr;receipt=json.loads(x.stdout);assert receipt['sha256']==digest and receipt['version']==version
 rows.append({'version':version,'receipt':receipt,'entries':{str(p.relative_to(root/version)):{'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'uid':p.stat().st_uid,'mode':oct(stat.S_IMODE(p.stat().st_mode))} for p in (root/version).rglob('*') if p.is_file()}})
with (root/'.store.lock').open('rb') as lock:
 fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 assert set(p.name for p in root.iterdir())==set(expected)|{'.store.lock'}
 for version in expected:shutil.rmtree(root/version)
 assert list(p.name for p in root.iterdir())==['.store.lock'];(root/'.store.lock').unlink();root.rmdir();root.parent.rmdir()
result={'verified_removed_versions':rows,'original_absent_store_parent_restored':not root.parent.exists(),'vm_binding_original_missing':True,'downloaded_official_archives_retained_for_reproducibility':True}
Path('/private/tmp/vphone-b18-store-cleanup.json').write_text(json.dumps(result,indent=2)+'\n');print({'removed_versions':list(expected),'original_absent_store_parent_restored':result['original_absent_store_parent_restored']})
