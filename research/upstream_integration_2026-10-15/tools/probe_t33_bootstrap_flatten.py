"""Exercise complete real bootstrap extraction, EXP flattening and final proofs."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT), str(ROOT/'scripts')]
from tests import test_patch_plan_gate as fixtures
from tests.test_exp_bootstrap_flatten import EXPBootstrapFlattenTests
from patchers import component_effects as effects, guest_write


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    output = ROOT/'.build/t32-t33-completion-20261023/bootstrap-flatten-real-resource-20261025'
    if output.exists():
        raise ValueError('Preserve existing real-resource evidence')
    output.mkdir()
    outer = ROOT/'.build/t32-t33-completion-20261023/exp-staged-dsc-package-20261025/VPhone.bundle/Contents/Resources/scripts/resources/cfw_jb_input.tar.zst'
    before = sha(outer)
    case = fixtures.FrozenGateTests(); case.setUp()
    result = dict(passed=False, VMStarts=0, CFWWrites=0, realBootstrap=True,
                  syntheticPlanAndGuestRoots=True, packageResourceSHA256=before)
    try:
        table, digest = guest_write.target_table()
        case.entries.append(dict(id='preboot-jb-bootstrap-install', disposition='guestUncovered', recordRules=[
            dict(literal='guest-target-map-v1:'+digest+':preboot-jb-bootstrap-install',hexadecimalOffsetSuffix=False)]))
        case.plan['variant'] = case.plan['gates']['variant'] = case.context['variant'] = 'exp'
        case.publish()
        os.environ.update(VPHONE_CFW_VARIANT='exp',VPHONE_FROZEN_PLAN_SHA256=case.digest,
                          VPHONE_FROZEN_CONTEXT=json.dumps(case.context))
        plan = case.load()
        compressed = case.stage/'bootstrap.tar.zst'
        tar = shutil.which('gtar')
        if not tar:
            raise ValueError('GNU tar required')
        with compressed.open('xb') as stream:
            subprocess.run([tar,'--zstd','-xOf',str(outer),'cfw_jb_input/jb/bootstrap-iphoneos-arm64.tar.zst'],
                           check=True,stdout=stream)
        archive = case.stage/'bootstrap-iphoneos-arm64.tar'
        with archive.open('xb') as stream:
            subprocess.run(['zstd','-d','-c',str(compressed)],check=True,stdout=stream)
        boot = case.mount/'mnt5'/('A'*96); boot.mkdir(parents=True)
        target = boot/'jb-vphone'; target.mkdir()
        installed_archive = boot/archive.name
        print('[preflight] guarded copy and exact real archive extraction',flush=True)
        guest_write.run(plan,['cp',str(archive),str(installed_archive)])
        guest_write.run(plan,[tar,'--preserve-permissions','-xf',str(installed_archive),'-C',str(target)])
        guest_write.run(plan,['mv',str(target/'var'),str(target/'procursus')])
        print('[preflight] actual EXP shell flatten including hidden members',flush=True)
        completed = EXPBootstrapFlattenTests.flatten(case)
        if completed.returncode:
            raise ValueError(completed.stdout+completed.stderr)
        guest_write.run(plan,['rm','-rf',str(target/'procursus/jb')])
        guest_write.run(plan,['rm','-f',str(installed_archive)])
        rows = [json.loads(line) for line in case.evidence.read_text().splitlines()]
        store = case.evidence.parent/'effect-blobs'
        print('[preflight] complete final transported-member proof',flush=True)
        final = effects.verify_rows(plan,rows,{'preboot':case.mount/'mnt5'},store)
        marker = target/'procursus/.procursus_strapped'
        if marker.read_bytes() != b'':
            raise ValueError('Bootstrap marker differs')
        marker.write_bytes(b'unrecorded drift')
        try:
            effects.verify_rows(plan,rows,{'preboot':case.mount/'mnt5'},store)
        except ValueError:
            result['unrecordedMarkerMutationRejected'] = True
        else:
            raise ValueError('Unrecorded marker drift accepted')
        result.update(passed=True,rows=len(rows),finalTargets=len(final),
                      exactArchiveMembers=len(table['archives']['bootstrap-iphoneos-arm64.tar']))
        (output/'guest-changes.jsonl').write_bytes(case.evidence.read_bytes())
        (output/'final-effects.json').write_text(json.dumps(final,indent=2)+'\n')
    except BaseException as error:
        result['error'] = repr(error)
        raise
    finally:
        result['packageResourcePreserved'] = sha(outer) == before
        (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
        case.doCleanups()
    print(json.dumps(result),flush=True)


if __name__ == '__main__':
    main()
