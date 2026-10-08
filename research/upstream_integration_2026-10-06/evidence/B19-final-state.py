import hashlib,json,os,stat,subprocess
from pathlib import Path
root=Path('/Users/qcz3840/github/vphone-cli');vm=root/'vm-new';wt=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
old=json.loads((wt/'research/upstream_integration_2026-10-06/evidence/B18-final-state.json').read_text())
hashes={n:hashlib.sha256((vm/n).read_bytes()).hexdigest() for n in old['critical_hashes']};assert hashes==old['critical_hashes']
def run(*a):
 p=subprocess.run(a,text=True,capture_output=True);return {'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
ps=run('/bin/ps','-axo','pid=,ppid=,comm=');lines=[x for x in ps['stdout'].splitlines() if any(y in x for y in ['vphone-vm','vphone-helper','debugserver','amfid','vphone-b19'])]
lsof=run('/usr/sbin/lsof','-t','--',str(vm/'Disk.img'),str(vm/'SEPStorage'),str(vm/'nvram.bin'));assert lsof['exit']==1 and not lsof['stdout']
assert not any('vphone-vm' in x or 'debugserver' in x for x in lines)
paths=['/Library/PrivilegedHelperTools/com.vphone.cli.helper','/Library/LaunchDaemons/com.vphone.cli.helper.plist','/Library/Application Support/vphone-launchpad/Bundles']
absence={x:not os.path.lexists(x) for x in paths};assert all(absence.values())
service=run('/bin/launchctl','print','system/com.vphone.cli.helper');assert service['exit']!=0
amfid=run('/bin/launchctl','print','system/com.apple.MobileFileIntegrity');assert amfid['exit']==0 and 'state = running' in amfid['stdout']
backup=Path('/private/tmp/vphone-b19-private-pasteboard.plist');assert stat.S_IMODE(backup.stat().st_mode)==0o600
status=run('/usr/bin/git','-C',str(root),'status','--short')
report={'VM_new_stopped':True,'VM_exit':0,'VM_exit_evidence':'tools.write_stdin session87334 completion printed VM_EXIT=0; transcript observation, not boot logfile content','disk_released':True,'disk_lsof':lsof,'critical_hashes':hashes,'system_paths_original_absent':absence,'helper_service_absent':True,'helper_registration_rejected_no_retry':True,'temporary_token_absent':not Path('/private/tmp/vphone-b19-restart-token').exists(),'private_Mac_backup_0600_retained':True,'Mac_original_items_types_data_restored':True,'Mac_changeCount_not_restorable':True,'binding_original_absent':not (vm/'launchpad.json').exists(),'process_readback':lines,'AMFI_service_readback':amfid,'driver_exit_error_preserved':True,'full_disk_rollback_performed':False,'restoration_checkpoint_retained':(root/'vm.backups/b18-vm-new-fixed-binding-20261008').is_dir(),'VM_2607_operated':False,'free_bytes':os.statvfs(vm).f_bavail*os.statvfs(vm).f_frsize,'main_status':status['stdout']}
Path('/private/tmp/vphone-b19-final-state.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:report[k] for k in ['VM_new_stopped','disk_released','critical_hashes','process_readback','free_bytes','main_status']},indent=2))
