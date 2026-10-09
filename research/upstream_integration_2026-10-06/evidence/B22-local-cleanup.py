import fcntl,hashlib,json,os,shutil,subprocess
from pathlib import Path
assert os.geteuid()==0
vm=Path('/Users/qcz3840/github/vphone-cli/vm.backups/b21-restored-vm-new-20261009');base=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');record=json.loads(Path('/private/tmp/vphone-b22-bound-process.json').read_text());binding=vm/'launchpad.json'
assert hashlib.sha256(binding.read_bytes()).hexdigest()==record['binding_sha256']
assert json.loads(binding.read_text())=={'bundle':record['selected_version']}
stop=json.loads(Path('/private/tmp/vphone-b22-bound-stop.json').read_text());assert stop['stop']['returncode']==0
assert not Path('/Users/qcz3840/github/vphone-cli/vm.backups/b22-before-local-binding-20261009/launchpad.json').exists()
for pid in [stop['target']['pid'],record['wrapper_pid']]:assert subprocess.run(['/bin/ps','-p',str(pid)],capture_output=True).returncode!=0
fd=os.open(vm,os.O_RDONLY|os.O_DIRECTORY);fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
try:
 p=subprocess.run(['/usr/sbin/lsof','-t',str(vm/'Disk.img')],capture_output=True,text=True);assert p.returncode==1 and not p.stdout.strip(),p.stdout
 expected=json.loads(Path('/private/tmp/vphone-b22-bind-local-core.json').read_text())['critical_before'];actual={n:hashlib.sha256((vm/n).read_bytes()).hexdigest() for n in expected};assert expected==actual
 binding.unlink()
finally:os.close(fd)
store=Path('/Library/Application Support/vphone-launchpad/Bundles');assert not store.is_symlink() and store.stat().st_uid==0
assert sorted(x.name for x in store.iterdir())==['.store.lock',record['selected_version']]
version=store/record['selected_version'];assert not version.is_symlink() and version.stat().st_uid==0
cli=base/'.build/vphone-cli.app/Contents/MacOS/vphone-cli';p=subprocess.run([str(cli),'core-bundle','verify','--version',record['selected_version']],capture_output=True,text=True);assert p.returncode==0,p.stderr
receipt=json.loads(p.stdout);original=json.loads(Path('/private/tmp/vphone-b22-install-local-core.json').read_text());assert receipt==original['receipt']
sfd=os.open(store/'.store.lock',os.O_RDWR);fcntl.flock(sfd,fcntl.LOCK_EX|fcntl.LOCK_NB)
try:shutil.rmtree(version);assert sorted(x.name for x in store.iterdir())==['.store.lock'];(store/'.store.lock').unlink();store.rmdir()
finally:os.close(sfd)
result={'binding_restored_absent':not os.path.lexists(binding),'local_store_restored_absent':not os.path.lexists(store),'backup_retained':True,'critical_hashes':actual,'removed_version':record['selected_version'],'escalator_executed':False};out=Path('/private/tmp/vphone-b22-local-cleanup.json');out.write_text(json.dumps(result,indent=2)+'\n');os.chown(out,cli.stat().st_uid,-1);print(result)
