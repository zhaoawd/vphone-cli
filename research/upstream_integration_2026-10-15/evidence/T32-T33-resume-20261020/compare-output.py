"""Control the output consumer while retaining the real host driver and journal."""
import json,os,subprocess,sys,time
from pathlib import Path
sys.path.insert(0,str(Path.cwd()))
from tests.test_cfw_host_isolation import HostDriverFixture
results=[]
for output,producer_exit in [('closed-pipe',0),('regular-file',0),('regular-file',37)]:
 case=HostDriverFixture();case.setUp()
 try:
  vm=case.root/'vm';vm.mkdir();(vm/'Disk.img').touch()
  installer=case.root/'scripts/cfw_install.sh'
  installer.write_text(installer.read_text().replace('exit ${INSTALL_EXIT:-0}','print completed-producer\nexit ${INSTALL_EXIT:-0}'))
  env=dict(case.env,TEST_MOUNTS=str(vm/'mount-table'),INSTALL_SLEEP='0.3',INSTALL_EXIT=str(producer_exit))
  with (case.root/'durable-output.log').open('wb') as log:
   proc=subprocess.Popen(['/bin/zsh',str(case.driver),'--variant','regular',str(vm)],env=env,stdout=subprocess.PIPE if output=='closed-pipe' else log,stderr=log,start_new_session=True)
   deadline=time.monotonic()+15
   while not (vm/'ready').exists() and proc.poll() is None and time.monotonic()<deadline:time.sleep(.01)
   assert (vm/'ready').exists(),'installer failed before controlled boundary'
   if proc.stdout:proc.stdout.close()
   code=proc.wait(timeout=20)
  records=[json.loads(p.read_text()) for p in (vm/'.cfw-history').glob('*/transaction.json')]
  assert len(records)==1
  row=dict(output=output,producerExit=producer_exit,exitCode=code,journalStatus=records[0]['status'],journalExit=records[0]['exit_code'],originalUnchanged=records[0]['original_check']['unchanged'],stagingRemains=bool(list(vm.glob('.cfw_disk.*'))))
  results.append(row)
  expected=141 if output=='closed-pipe' else producer_exit
  assert code==expected and row['journalExit']==expected,row
  assert row['journalStatus']==('published' if expected==0 else 'failed'),row
  assert row['originalUnchanged'] is True and row['stagingRemains'] is False,row
 finally:case.doCleanups()
print(json.dumps({'state':'passed','scope':'disposable host-driver output consumer control; not real VM acceptance','cases':results},indent=2))
