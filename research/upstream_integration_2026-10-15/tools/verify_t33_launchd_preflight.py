#!/usr/bin/env python3
"""Replay preserved EXP bytes through guarded injection, patch, sign and readback.

The plan/mounts are isolated test fixtures. Binary input, injector, patcher,
signer, operation evidence and final effect validation use their real paths.
Never attach or modify a VM, install a Bundle, or copy the signing key.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT), str(ROOT / 'scripts')]
from patchers import component_signatures as signatures
from tests.test_classic_launchd_signing import ClassicLaunchdSigningTests


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history', type=Path, required=True)
    parser.add_argument('--certificate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    started = time.monotonic()
    rows = [json.loads(line) for line in (args.history / 'guest-changes.jsonl').read_text().splitlines()]
    injection = next(row for row in rows if row['declarationID'] == 'system-launchd-jb-hook')
    jetsam = next(row for row in rows if row['declarationID'] == 'system-launchd-boot-jetsam_panic_guard_bypass'
                  and row['target'] == 'system:/sbin/launchd' and row['effect']['operation'] == 'change')
    paths = [args.history / 'effect-blobs' / row[field] for row, field in
             [(injection, 'beforeSHA256'), (jetsam, 'afterSHA256')]]
    for path in paths:
        assert hashlib.sha256(path.read_bytes()).hexdigest() == path.name
    original, failed_input = paths
    certificate = args.certificate.resolve()
    cert_digest = hashlib.sha256(certificate.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix='t33-launchd-preflight-') as temporary:
        temporary = Path(temporary)
        entitlements = temporary / 'entitlements.plist'
        entitlements.write_bytes(subprocess.check_output(['ldid', '-e', str(original)]))
        def sign(argv):
            subprocess.run(['ldid', '-S' + str(entitlements), '-M', '-K' + str(certificate), argv[-1]],
                           check=True, capture_output=True)
        bad = temporary / 'unreserved'
        shutil.copyfile(failed_input, bad)
        sign(['ldid', str(bad)])
        try:
            signatures.verify_signing(failed_input, bad)
        except ValueError as error:
            assert str(error) == 'signature load command overwrote non-padding bytes'
            rejection = str(error)
        else:
            raise AssertionError('Original failure did not reproduce')
        fixture = ClassicLaunchdSigningTests()
        fixture.setUp()
        try:
            output, produced, final = fixture.run_chain(original.read_bytes(), 0, signer=sign, jetsam=True)
            signatures.verify_artifact(output, require_cms=True)
            assert signatures.entitlements(output) == signatures.entitlements(original)
            result = dict(state='passed', scope='real captured bytes; isolated plan and directory mounts',
                originalRejection=rejection, inputSHA256=original.name, failedInputSHA256=failed_input.name,
                signedOutputSHA256=hashlib.sha256(output.read_bytes()).hexdigest(),
                finalTargets=[row['target'] for row in final], guardedOperations=len(produced),
                cmsIntegrityPassed=True, allCodePagesPassed=True, entitlementsPreserved=True,
                VMStarts=0, securityWindows=0, nativeCFWExecuted=False,
                elapsedSeconds=time.monotonic()-started)
        finally:
            fixture.doCleanups()
    assert hashlib.sha256(certificate.read_bytes()).hexdigest() == cert_digest
    for path in paths:
        assert hashlib.sha256(path.read_bytes()).hexdigest() == path.name
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as stream:
        stream.write(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
