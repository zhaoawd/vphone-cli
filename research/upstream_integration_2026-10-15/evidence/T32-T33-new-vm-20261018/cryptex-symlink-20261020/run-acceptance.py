"""Run the authorized independent DSC reinstall, Undo and reapplication acceptance.

Does not change production guards, boot binaries, AMFI or repository history.
Every stage must pass before the next stage starts. Native elevation remains
interactive. Run as the same ordinary user as the earlier boot acceptance.
"""
import datetime,json,os,subprocess
from pathlib import Path
r=Path.cwd();debug=r/'.build/t32-cryptex-symlink-debug';vm=r/'vm-t32-t33-dsc-20261018'
python=r/'.venv/bin/python3';cli=r/'.build/t32-cryptex-symlink-final.app/Contents/MacOS/vphone-cli'
boot=r/'.build/t32-dsc-companions-final.app/Contents/MacOS/vphone-vm';tools=r/'research/upstream_integration_2026-10-15/tools'
state=dict(state='preparing-install',vm=str(vm),runtimeEffectsValidated=False,graphicsValidated=False)
env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1',VPHONE_PYTHON=str(python),VPHONE_ROOT=str(r/'.build/t32-t33-runtime-20261018'))
env['PATH']=str(r/'.tools/bin')+':'+str(r/'.venv/bin')+':'+env['PATH']
def save():
 state['recordedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat()
 (debug/'acceptance-state.json').write_text(json.dumps(state,indent=2)+'\n')
def run(label,command):
 if (debug/'stop-after-undo').exists():raise RuntimeError('continuation explicitly stopped')
 state.update(state=label,argv=command);save()
 with (debug/(label+'.log')).open('wb') as log:
  child=subprocess.Popen(command,cwd=r,env=env,stdout=log,stderr=subprocess.STDOUT)
  state['childPID']=child.pid;save();code=child.wait(timeout=43200)
 state.setdefault('stages',[]).append(dict(stage=label,exitCode=code));save()
 if code:raise RuntimeError(label+' exited '+str(code))
def proof(label,phase,out,installed=None):
 command=[str(python),str(r/'scripts/vm_lock.py'),str(vm),'fw-receipts','--',str(python),str(tools/'verify_dsc_publication.py'),'--vm',str(vm),'--phase',phase,'--source-diagnostic',str(r/'.build/t32-dsc-readonly-source/result.json'),'--out',str(out)]
 if installed:command+=['--installed-proof',str(installed)]
 run(label,command)
 result=json.loads((out/'result.json').read_text())
 if result['state']!='passed':raise RuntimeError(label+' proof did not pass')
 return result
def boots(label,out):
 run(label,[str(python),str(tools/'verify_legacy_vm_boot.py'),'--api','--vm',str(vm),'--vm-executable',str(boot),'--cli',str(cli),'--out',str(out)])
 result=json.loads((out/'runtime-result.json').read_text())
 if result['state']!='passed':raise RuntimeError(label+' did not pass')
 return result
def postboot(label,out,bootout):
 run(label,[str(python),str(tools/'verify_post_boot_cfw.py'),'--vm',str(vm),'--cli',str(cli),'--out',str(out),'--boot-evidence',str(bootout/'runtime-result.json')])
 result=json.loads((out/'result.json').read_text())
 if result['state']!='passed':raise RuntimeError(label+' did not pass')
 return result
try:
 save()
 import hashlib
 assert hashlib.sha256(boot.read_bytes()).hexdigest()=='a25bfd3af55c5a2af4aab1a84541be8328a430b5d8bd267be2704ba72ca54125'
 assert boot.stat().st_ino==246999022 and boot.stat().st_dev==16777231
 run('install-cfw',[str(cli),'cfw','install',vm.name,'--library-root',str(r),'--variant','regular','--guest-environment','classic','--keep-artifacts','--reinstall-cryptex','--root-popup'])
 installed=proof('installed-proof','installed',r/'.build/t32-dsc-v4-symlink-installed')
 if installed['transactionID'] in {'20261019T065441Z-XzJThk9M','20261019T090232Z-27r0QIUW','20261019T124601Z-vZh3Hh4C'}:raise RuntimeError('installed proof references an earlier transaction')
 run('undo-preboot',[str(cli),'cfw','undo',vm.name,'--library-root',str(r),'--generation',installed['generationID'],'--declaration','dyld-boot-iomfb_swapend','--root-popup'])
 installed=json.loads((r/'.build/t32-dsc-v4-symlink-installed/result.json').read_text())
 restored=proof('restored-proof','restored',r/'.build/t32-dsc-v4-symlink-restored',r/'.build/t32-dsc-v4-symlink-installed/result.json')
 restored_boots=boots('restored-api',r/'.build/t32-dsc-v4-symlink-api-restored')
 restored_post=postboot('restored-postboot',r/'.build/t32-dsc-v4-symlink-postboot-restored',r/'.build/t32-dsc-v4-symlink-api-restored')
 run('reapply-cfw',[str(cli),'cfw','install',vm.name,'--library-root',str(r),'--variant','regular','--guest-environment','classic','--keep-artifacts','--reinstall-cryptex','--root-popup'])
 reapplied=proof('reapplied-proof','installed',r/'.build/t32-dsc-v4-symlink-reapplied')
 reapplied_boots=boots('reapplied-api',r/'.build/t32-dsc-v4-symlink-api-reapplied')
 reapplied_post=postboot('reapplied-postboot',r/'.build/t32-dsc-v4-symlink-postboot-reapplied',r/'.build/t32-dsc-v4-symlink-api-reapplied')
 if len({installed['transactionID'],restored['transactionID'],reapplied['transactionID']})!=3:raise RuntimeError('transition journals are not distinct')
 if len({installed['generationID'],restored['generationID'],reapplied['generationID']})!=1:raise RuntimeError('transition generation differs')
 if installed['originalSHA256']!=restored['originalSHA256'] or installed['originalSHA256']!=reapplied['originalSHA256'] or installed['installedSHA256']!=reapplied['installedSHA256']:raise RuntimeError('DSC original/reapplication bytes differ')
 result=dict(state='passed',scope='DSC preboot Undo andsame-generation explicit reapplication',generationID=installed['generationID'],transactions=dict(installed=installed['transactionID'],restored=restored['transactionID'],reapplied=reapplied['transactionID']),originalSHA256=installed['originalSHA256'],installedSHA256=installed['installedSHA256'],verifiedCodePages=restored['verifiedRestoredCodePages'],restoredAPICycles=len(restored_boots['cycles']),reappliedAPICycles=len(reapplied_boots['cycles']),restoredPostBoot=restored_post['state'],reappliedPostBoot=reapplied_post['state'],runtimeEffectsValidated=False,graphicsValidated=False,broaderT32T33Accepted=False)
 (debug/'on-off-on-result.json').write_text(json.dumps(result,indent=2)+'\n');state.update(state='passed',result=result);save()
except Exception as error:
 state.update(state='failed',error=str(error));save();raise
