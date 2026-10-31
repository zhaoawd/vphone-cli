#!/usr/bin/env python3
"""Read the failed EXP disk readonly; exercise DT/plist edits on copies only."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
import cfw_verify_effects as audit
import cfw_disk_txn as txn
from patchers.cfw_patch_post_restore_dt import patch_devicetree_file
from patchers.cfw_patch_build_version import patch_plist

VM = ROOT / '.build/t33s-20261025'
OUT = ROOT / '.build/t32-t33-completion-20261023/signing-followup-20261025/guest-tail-readonly'


def identity(path):
    info = path.stat()
    return {name: getattr(info, name) for name in ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if sys.argv[1:] != ['--execute-readonly'] or os.geteuid() != 0:
        raise ValueError('Native authentication required; readonly named disk only')
    OUT.mkdir(mode=0o700)
    before = identity(VM / 'Disk.img')
    owner = (VM / 'config.plist').stat()
    result = dict(passed=False, VMStarts=0, securityWindows=0, CFWWrites=0, checks={})
    try:
        with audit.locked_vm(VM):
            txn.require_unheld(VM / 'Disk.img', os.getpid(), 'readonly EXP tail preflight')
            with audit.readonly_roots(VM / 'Disk.img', {'system', 'preboot'}, Path('/private/tmp')) as (roots, recheck):
                for volume, relative in [('system', 'System/Library/CoreServices/SystemVersion.plist'),
                        ('system', 'System/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist'),
                        ('preboot', 'Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist')]:
                    source = roots[volume] / relative
                    key = volume + ':/' + relative
                    if not source.exists():
                        result['checks'][key] = dict(state='absent', deploymentPassed=False)
                        continue
                    assert not source.is_symlink() and source.is_file()
                    observed = identity(source); raw = source.read_bytes()
                    target = OUT / (volume + '-' + relative.replace('/', '_'))
                    target.write_bytes(raw)
                    assert patch_plist(target, '23Z999999')
                    first = target.read_bytes()
                    assert plistlib.loads(first) == dict(plistlib.loads(raw), ProductBuildVersion='23Z999999')
                    assert not patch_plist(target, '23Z999999')
                    target.write_bytes(raw)
                    assert patch_plist(target, '23Z999999') and target.read_bytes() == first
                    assert identity(source) == observed and source.read_bytes() == raw
                    result['checks'][key] = dict(state='copy-patch-restore-reapply-passed', sourceSHA256=hashlib.sha256(raw).hexdigest())
                candidates = [p / 'usr/standalone/firmware/devicetree.img4' for p in roots['preboot'].iterdir()
                              if re.fullmatch('[0-9A-Fa-f]{96}', p.name)]
                candidates = [p for p in candidates if p.is_file() and not p.is_symlink()]
                if len(candidates) != 1:
                    raise ValueError('Expected exactly one restored DeviceTree')
                source = candidates[0]; observed = identity(source); original_hash = sha(source)
                target = OUT / 'devicetree.img4'; shutil.copyfile(source, target)
                changed = patch_devicetree_file(str(target))
                first = target.read_bytes()
                assert patch_devicetree_file(str(target)) == 0 and target.read_bytes() == first
                assert identity(source) == observed and sha(source) == original_hash
                result['checks']['devicetree'] = dict(passed=True, changedProperties=changed, sourceSHA256=original_hash,
                    localOutputSHA256=sha(target), scope='actual restored IMG4 copy; native writeback pending')
                recheck()
        result['guestMountsNormallyReleased'] = True
        result['passed'] = True
    except Exception as error:
        result['error'] = str(error)
    finally:
        result['diskIdentityPreserved'] = identity(VM / 'Disk.img') == before
        listing = plistlib.loads(audit.run_tool(['/usr/bin/hdiutil', 'info', '-plist']))
        result['targetAttachments'] = [row['image-path'] for row in listing.get('images', [])
            if row.get('image-path') and VM in Path(row['image-path']).parents]
        result['passed'] &= result['diskIdentityPreserved'] and not result['targetAttachments']
        (OUT / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        for path in OUT.iterdir():
            os.chown(path, owner.st_uid, owner.st_gid)
        os.chown(OUT, owner.st_uid, owner.st_gid)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
