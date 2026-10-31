"""Real readonly Cryptex copy and DSC producers under a synthetic frozen plan.

Only the plan verifier and generation are fixtures. Image attachment, guarded
copy, all three patch algorithms, signatures and final effects are real.
Temporary experiment payloads are scoped to unittest's temporary directory.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT), str(ROOT / 'scripts')]
from tests import test_patch_plan_gate as fixtures
from patchers import cfw, component_effects as effects, component_signatures as signatures
from patchers import cryptex_source, guest_write


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def identity(path):
    info = path.lstat()
    return {key: getattr(info, key) for key in
            ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns', 'st_mode', 'st_nlink')}


def probe(source, output):
    if output.exists():
        raise ValueError('Preserve existing probe output')
    output.mkdir()
    case = fixtures.FrozenGateTests()
    case.setUp()
    before = identity(source)
    digest = sha(source)
    result = dict(passed=False, realResources=True, syntheticPlanAndGeneration=True,
                  VMStarts=0, CFWWrites=0, sourceSHA256=digest)
    attached = False
    mount = case.mount / 'mnt_sysos'
    try:
        table_digest = guest_write.target_table()[1]
        for declaration in ('system-cryptex-boot-install', 'dyld-exp-hv_vmm',
                            'dyld-cfw-camera', 'dyld-boot-iomfb_swapend'):
            case.entries.append(dict(id=declaration, disposition='guestUncovered', recordRules=[
                dict(literal='guest-target-map-v1:' + table_digest + ':' + declaration,
                     hexadecimalOffsetSuffix=False)]))
        case.plan['variant'] = case.plan['gates']['variant'] = case.context['variant'] = 'exp'
        case.publish()
        os.environ.update(VPHONE_CFW_VARIANT='exp', VPHONE_FROZEN_PLAN_SHA256=case.digest,
                          VPHONE_FROZEN_CONTEXT=json.dumps(case.context))
        plan = case.load()
        image = case.stage / 'CryptexSystemOS.dmg'
        original = case.vm / '.firmware-generations' / case.context['generationID'] / 'originals/SystemOS.dmg'
        original.parent.mkdir(parents=True)
        for target in (image, original):
            subprocess.run(['/bin/cp', '-c', '-p', str(source), str(target)], check=True)
        cryptex_source.marker(image).write_bytes(effects.canonical(dict(schemaVersion=1,
            generationID=case.context['generationID'], planDigest=plan.record['planSHA256'],
            source=str(original), sourceSHA256=digest, cacheSHA256=digest)))
        mount.mkdir()
        subprocess.run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-owners', 'off',
                        '-mountpoint', str(mount), str(image)], check=True)
        attached = True
        if not os.statvfs(mount).f_flag & os.ST_RDONLY:
            raise ValueError('Source image is not readonly')
        target = case.mount / 'mnt1/System/Cryptexes/OS'
        target.mkdir(parents=True)
        print('[preflight] guarded readonly Cryptex copy', flush=True)
        guest_write.run(plan, ['cp', '-R', str(mount) + '/.', str(target)])
        subprocess.run(['/usr/bin/hdiutil', 'detach', str(mount)], check=True)
        attached = False
        directory = target / 'System/Library/Caches/com.apple.dyld'
        header = directory / 'dyld_shared_cache_arm64e'
        inputs = {p.name: sha(p) for p in directory.iterdir() if p.is_file()}
        for command, extra in (('patch-hv-vmm-dsc', []), ('patch-camera-dsc', [str(header)]),
                               ('patch-iomfb-swapend', ['--target-size', '0x560'])):
            print('[preflight] ' + command, flush=True)
            with patch.object(sys, 'argv', ['cfw.py', command, str(directory), *extra]):
                try:
                    cfw.main()
                except SystemExit as exit_code:
                    if exit_code.code != 0:
                        raise
        rows = [json.loads(line) for line in case.evidence.read_text().splitlines()]
        store = case.evidence.parent / 'effect-blobs'
        print('[preflight] final composed effects', flush=True)
        final = effects.verify_rows(plan, rows, {'system': case.mount / 'mnt1', 'dsc': directory}, store)
        changed = []
        for path in sorted(directory.iterdir()):
            if path.is_file() and inputs[path.name] != sha(path):
                cds = signatures.directories(path)
                signatures.verify_slots(path, [dict(identity=cd['identity'], slot=cd['slot'],
                    pages=range(cd['count'])) for cd in cds])
                changed.append(dict(name=path.name, beforeSHA256=inputs[path.name], afterSHA256=sha(path),
                                    verifiedCodePages=sum(cd['count'] for cd in cds)))
        if not changed:
            raise ValueError('Real DSC producers changed no files')
        result.update(passed=True, changed=changed, effects=len(rows), finalTargets=len(final),
                      normallyDetached=True, sourceClonePreserved=sha(image) == digest)
        (output / 'guest-changes.jsonl').write_bytes(case.evidence.read_bytes())
        (output / 'final-effects.json').write_text(json.dumps(final, indent=2) + '\n')
    except BaseException as error:
        result['error'] = repr(error)
        raise
    finally:
        if attached:
            # A busy mount is retained; never force-detach or remove its tree.
            subprocess.run(['/usr/bin/hdiutil', 'detach', str(mount)], check=True)
        result['sourceIdentityPreserved'] = identity(source) == before
        result['sourceSHA256Preserved'] = sha(source) == digest
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        case.doCleanups()
    if not all(result[k] for k in ('sourceIdentityPreserved', 'sourceSHA256Preserved', 'sourceClonePreserved')):
        raise ValueError('Readonly source preservation failed')
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    probe(args.source.resolve(strict=True), args.output)
