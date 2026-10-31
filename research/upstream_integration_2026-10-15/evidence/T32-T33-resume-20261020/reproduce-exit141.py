import json,os,subprocess,sys,tempfile,time
from pathlib import Path
sys.path.insert(0,str(Path.cwd()))
from tests.test_cfw_host_isolation import HostDriverFixture
case=HostDriverFixture();case.setUp()
try:
    # Keep real host-driver/transaction code and disposable command doubles.
    installer=case.root/'scripts/cfw_install.sh'
    installer.write_text(installer.read_text().replace('exit ${INSTALL_EXIT:-0}','print completed-producer\nexit ${INSTALL_EXIT:-0}'))
    vm,p=case.start(variant='regular',INSTALL_SLEEP='0.5')
    deadline=time.monotonic()+15
    while not (vm/'ready').exists() and p.poll() is None and time.monotonic()<deadline:time.sleep(.01)
    if not (vm/'ready').exists():
        out,err=p.communicate(timeout=5)
        raise RuntimeError('installer did not reach write stage: '+repr((p.returncode,out,err)))
    # Consumer closes stdout after successful producer writes; stderr still drains.
    p.stdout.close();p.stdout=None
    stderr=p.communicate(timeout=20)[1].decode()
    histories=list((vm/'.cfw-history').glob('*/transaction.json'))
    pending=list(vm.glob('.cfw_disk.*'))
    records=[json.loads(x.read_text()) for x in histories]
    result=dict(returncode=p.returncode,records=records,pending=[x.name for x in pending],stderr=stderr)
    print(json.dumps(result,indent=2))
    assert p.returncode==141,'did not reproduce SIGPIPE-derived shell status'
finally:case.doCleanups()
