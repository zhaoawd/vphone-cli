"""Inspect the unpublished target and old EXP states without changing a VM."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
import cfw_disk_txn as txn
import cfw_guest_evidence as evidence
import cfw_verify_effects as audit
from patchers import component_effects as effects

BASE = ROOT / '.build/t32-t33-completion-20261023'
VM = ROOT / '.build/t33t-20261025'
OUT = BASE / 'dev-overlay-reuse-preparation-20261025'
OLD = BASE / 'exp-signing-acceptance-20261025-r2'
RETIRED = [ROOT / '.build/t33q-20261024', ROOT / '.build/t33q-20261024-binding-backup',
           ROOT / '.build/t33s-20261025', BASE / 't33s-first-binding-20261025']


def identity(path):
    value = path.lstat()
    return {key: getattr(value, key) for key in ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')}


def snapshot(path):
    before = identity(path); info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError('Reuse input is linked or special: ' + str(path))
    value = dict(sha256=evidence.digest(path), bytes=info.st_size, dev=info.st_dev, ino=info.st_ino,
        mtime_ns=info.st_mtime_ns, mode=stat.S_IMODE(info.st_mode), uid=info.st_uid, gid=info.st_gid)
    if identity(path) != before:
        raise ValueError('Reuse input changed during read')
    return value


def main():
    if os.geteuid() != 0 or sys.argv[1:] != ['--readonly']:
        raise ValueError('Native authentication required for named readonly inspection')
    owner = (VM / 'config.plist').stat()
    result = dict(passed=False, VMStarts=0, securityWindows=0, CFWWrites=0, deletionPerformed=False)
    before = identity(VM / 'Disk.img')
    try:
        old = json.loads(evidence.read(OLD / 'offline-plan.json'))
        final = json.loads(evidence.read(OLD / 'finalization.json'))
        if final['nativeState'] != 'failed' or final['preservation']['targetAttachments'] != []:
            raise ValueError('Previous execution is not safely finalized')
        with audit.locked_vm(VM):
            txn.require_unheld(VM / 'Disk.img', os.getpid(), 'readonly reuse inspection')
            names = sorted(set(old['sourceBootFiles']) | {'launchpad.json', '.firmware-desired-plan.json'})
            files = {name: snapshot(VM / name) for name in names}
            if files['Disk.img']['sha256'] != old['sourceBootFiles']['Disk.img']['sha256']:
                raise ValueError('Unpublished target differs from its complete source disk')
            desired = json.loads(evidence.read(VM / '.firmware-desired-plan.json'))
            if desired['plan']['variant'] != 'exp' or desired['generationID'] != 'e45c2fedee57f70b05bf7e4fe8fc6946b21b0aded7dadf4f66760f0304274308':
                raise ValueError('Reuse generation or variant differs')
            journals = [json.loads(evidence.read(p / 'transaction.json')) for p in (VM / '.cfw-history').iterdir()
                        if p.is_dir() and (p / 'transaction.json').is_file()]
            if not journals or any(row['status'] != 'failed' for row in journals):
                raise ValueError('Target has pending or published history; this reuse profile does not apply')
            if txn.committed_guest_evidence(VM) is not None:
                raise ValueError('Reuse profile requires an unpublished guest')
            cli = old['targets'][0]['installCommand'][0]
            with (OUT / 'verify-plan.log').open('xb') as stream:
                subprocess.run([cli, 'cfw', 'verify-plan', str(VM), '--expected-sha256',
                    files['.firmware-desired-plan.json']['sha256']], stdout=stream,
                    stderr=subprocess.STDOUT, check=True)
            scratch = {}
            for name in ('cfw_input', 'cfw_jb_input', '.cfw_temp'):
                path = VM / name
                if path.exists():
                    scratch[name] = effects.state(path)
            result.update(currentBootFiles=files, expectedBinding=json.loads(evidence.read(VM / 'launchpad.json')),
                generationID=desired['generationID'], expectedDesiredSHA256=files['.firmware-desired-plan.json']['sha256'],
                scratchTrees=scratch, priorFailedTransactions=[row['id'] for row in journals],
                fullDiskMatchesOriginalSource=True, readonlyPlanVerificationPassed=True)
        sizes = []
        for path in RETIRED:
            value = subprocess.check_output(['/usr/bin/du', '-sk', str(path)], text=True)
            sizes.append(dict(path=str(path), allocatedBytes=int(value.split()[0]) * 1024))
        result['retirementCandidates'] = sizes
        result['passed'] = True
    except Exception as error:
        result['error'] = str(error)
    finally:
        result['diskIdentityPreserved'] = identity(VM / 'Disk.img') == before
        result['passed'] &= result['diskIdentityPreserved']
        info = os.statvfs(ROOT); result['availableBytes'] = info.f_bavail * info.f_frsize
        (OUT / 'readonly-inspection.json').write_text(json.dumps(result, indent=2) + '\n')
        for path in OUT.iterdir():
            if path.is_file():
                os.chown(path, owner.st_uid, owner.st_gid)
    print(json.dumps({key: value for key, value in result.items() if key not in ('scratchTrees', 'currentBootFiles')}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
