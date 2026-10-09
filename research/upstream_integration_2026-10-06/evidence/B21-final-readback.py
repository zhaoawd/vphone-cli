import hashlib,json,os,subprocess
from pathlib import Path
root=Path('/Users/qcz3840/github/vphone-cli');vm=root/'vm-new';wt=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');restore=root/'vm.backups/b21-restored-vm-new-20261009'
def run(*a):
 p=subprocess.run(a,capture_output=True,text=True);return {'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
old=json.loads((wt/'research/upstream_integration_2026-10-06/evidence/B18-final-state.json').read_text());hashes={n:hashlib.sha256((vm/n).read_bytes()).hexdigest() for n in old['critical_hashes']};assert hashes==old['critical_hashes']
files=[str(p/n) for p in [vm,restore] for n in ['Disk.img','SEPStorage','nvram.bin']];lsof=run('/usr/sbin/lsof','-t','--',*files);assert lsof['exit']==1 and not lsof['stdout']
ps=run('/bin/ps','-axo','pid=,ppid=,comm=');remaining=[l for l in ps['stdout'].splitlines() if any(x in l for x in ['vphone-vm','debugserver'])];assert not remaining
scope=run('/bin/ps','-axo','pid=,ppid=,command=');scoped=[l for l in scope['stdout'].splitlines() if ' -B /private/tmp/vphone-b21-amfid-candidate/scoped.py' in l];assert not scoped
system_paths=['/Library/PrivilegedHelperTools/com.vphone.cli.helper','/Library/LaunchDaemons/com.vphone.cli.helper.plist','/Library/Application Support/vphone-launchpad/Bundles'];absence={p:not os.path.lexists(p) for p in system_paths};assert all(absence.values())
helper=run('/bin/launchctl','print','system/com.vphone.cli.helper');assert helper['exit']!=0
amfi=run('/bin/launchctl','print','system/com.apple.MobileFileIntegrity');assert amfi['exit']==0
right=run('/usr/bin/sudo','-n','/usr/bin/security','authorizationdb','read','com.vphone.cli.helper.privileged');assert right['exit']!=0
# Delete only this run's private API token after the owning VM exited.
token=Path('/private/tmp/vphone-b21-restart-token');token.unlink(missing_ok=True)
report={'VM_exit':0,'VM_exit_source':'write_stdin session87990 returned VM_EXIT=0','stop_classification':'classicAccepted','guest_stopped_log_observed':True,'original_and_restored_disks_released':True,'disk_lsof':lsof,'original_critical_hashes':hashes,'original_binding_absent':not (vm/'launchpad.json').exists(),'restored_original_classic_hash':hashlib.sha256((restore/'.vphoned.signed').read_bytes()).hexdigest(),'temporary_AMFI_driver_absent':True,'debugserver_absent':True,'AMFI_cleanup_initial_assertion_failed':True,'AMFI_independent_readback':amfi,'system_paths_absent':absence,'helper_absent':helper,'authorization_right_name':'com.vphone.cli.helper.privileged','authorization_right_absent':right,'temporary_token_absent':not token.exists(),'free_bytes':os.statvfs(root).f_bavail*os.statvfs(root).f_frsize,'source_checkpoint_retained':(root/'vm.backups/b18-vm-new-fixed-binding-20261008').is_dir(),'restored_sample_retained':restore.is_dir(),'VM_2607_operated':False,'full_disk_rollback_performed':False}
Path('/private/tmp/vphone-b21-final-readback.json').write_text(json.dumps(report,indent=2)+'\n');print({k:v for k,v in report.items() if k not in ['AMFI_independent_readback','disk_lsof']})
