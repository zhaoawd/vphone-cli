"""Replay real historical identity under an in-memory, read-only device binding.

No recovery registration, CFW writer, checkpoint, publication or VM is created.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'scripts'))
import cfw_disk_txn as transaction
import cfw_guest_evidence as evidence
import cfw_reboot_identity as identity
import vm_lock

BASE=ROOT/'.build/t32-t33-completion-20261023'
VM=ROOT/'.build/t33t-20261025'
OUT=BASE/'reboot-real-identity-preflight-20261026'
ARCHIVE=VM/'.cfw-history/20261025T132920Z-adMN63qO'
PENDING=VM/'.cfw_disk.W7aZSh3x'
HELPER=Path('/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper')
BINARY=BASE/'reboot-preflight-final-frozen-binary-20261026/FirmwarePatcherTests'


def main():
    if os.geteuid()!=0:raise ValueError('Read-only private evidence requires administrator authentication')
    OUT.mkdir()
    if (VM/identity.REGISTRATION).exists():raise ValueError('Preserve existing registration; this probe cannot activate one')
    fd=os.open(VM,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    previous=os.environ.get(vm_lock.FD_ENV)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);os.set_inheritable(fd,True)
        os.environ[vm_lock.FD_ENV]=str(fd);vm_lock.check_inherited(VM)
        transaction.require_unheld(VM/'Disk.img',os.getpid(),'readonly historical identity probe')
        record=transaction.load_record(ARCHIVE)
        checkpoint=json.loads(evidence.read(ARCHIVE/evidence.CHECKPOINT))
        final=json.loads(evidence.read(PENDING/evidence.FINAL))
        old_plan=json.loads(evidence.read(BASE/'exp-plist-lifetime-acceptance-20261025/offline-plan.json'))
        observed=json.loads(evidence.read(BASE/'f430-interruption-readback-20261026.json'))
        rows=[]
        specs=[(VM/'Disk.img',checkpoint['imageIdentity'],checkpoint['imageSHA256']),
            (ARCHIVE/'Disk.img',record['original'],old_plan['sourceBootFiles']['Disk.img']['sha256']),
            (ARCHIVE/evidence.POSTIMAGE,checkpoint['postimageIdentity'],checkpoint['imageSHA256']),
            (PENDING/'Disk.img',final['stagedIdentity'],observed['staged']['sha256'])]
        for path,old,digest in specs:
            rows.append(dict(paths=[str(path.relative_to(VM))],recorded={k:old[k] for k in identity.FIELDS},
                current=identity.identity(path.stat()),sha256=digest))
        volume=identity._volume_uuid(VM)
        binding=identity.RequalifiedIdentity(VM,volume,rows)
        started=time.monotonic();binding.verify_files(volume)
        print(json.dumps(dict(step='four-complete-disk-readbacks-passed',seconds=time.monotonic()-started)),flush=True)
        protected={str(path):evidence.digest(path) for path in (
            ARCHIVE/'transaction.json',ARCHIVE/evidence.CHECKPOINT,PENDING/'transaction.json',BINARY,Path(__file__))}
        assert transaction.committed_guest_evidence(VM) is None
        with patch.object(identity,'binding_for',return_value=binding):
            committed=transaction.committed_guest_evidence(VM)
            if committed is None or committed[1]['id']!=record['id']:
                raise ValueError('Complete historical publication did not replay')
        assert transaction.committed_guest_evidence(VM) is None
        print(json.dumps(dict(step='python-complete-publication-replay-passed',transactionID=record['id'])),flush=True)
        desired=json.loads(evidence.read(VM/'.firmware-desired-plan.json'))
        replay=OUT/'swift-replay.json'
        replay.write_text(json.dumps(dict(vmDirectory=str(VM),generationID=desired['generationID'],
            identity=desired['identity'],members=rows),indent=2)+'\n')
        env=dict(os.environ,DYLD_FRAMEWORK_PATH='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks',
            DYLD_LIBRARY_PATH='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib',
            VPHONE_REBOOT_IDENTITY_REPLAY=str(replay))
        with (OUT/'swift-replay.log').open('xb') as log:
            result=subprocess.run([str(HELPER),'--test-bundle-path',str(BINARY),'--testing-library','swift-testing',
                '--filter','FirmwareRebootIdentityTests.actualRecordedIdentityReplayUsesOnlyAnInMemoryBinding'],
                env=env,stdout=log,stderr=subprocess.STDOUT,pass_fds=(fd,),timeout=1200)
        swift=(OUT/'swift-replay.log').read_text(errors='replace')
        if result.returncode or 'Test run with 1 test' not in swift or 'failed' in swift:
            raise ValueError('Actual Swift identity replay did not pass; inspect its retained log')
        for name,digest in protected.items():
            if evidence.digest(Path(name))!=digest:raise ValueError('Protected historical evidence or executable changed')
        result=dict(passed=True,historicalTransactionID=record['id'],completeImagesRead=4,
            pythonPublicationReplayPassed=True,swiftIdentityReplayPassed=True,
            ordinaryUnregisteredLookupStillRefuses=True,registrationInstalled=False,
            published=False,transactionWrites=0,VMStarts=0,runtimeValidated=False,accepted=False,
            scope='real historical proof replay under an explicit in-memory binding; no operational recovery authority')
        (OUT/'result.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result),flush=True)
    finally:
        if previous is None:os.environ.pop(vm_lock.FD_ENV,None)
        else:os.environ[vm_lock.FD_ENV]=previous
        os.close(fd)


if __name__=='__main__':
    try:main()
    except Exception as error:
        if OUT.is_dir():(OUT/'stopped.json').write_text(json.dumps(dict(error=str(error),transactionWrites=0,VMStarts=0),indent=2)+'\n')
        raise
