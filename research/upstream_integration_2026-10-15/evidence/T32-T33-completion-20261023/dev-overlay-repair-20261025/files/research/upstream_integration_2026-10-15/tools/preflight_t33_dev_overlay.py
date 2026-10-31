#!/usr/bin/env python3
"""Replay the exact EXP overlay shell function with actual packaged resources."""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT), str(ROOT / 'scripts')]
from patchers.guest_write import archive_targets
from patchers import guest_write, component_effects
from tests.test_patch_plan_gate import FrozenGateTests


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resources', type=Path, required=True)
    parser.add_argument('--installer', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--verify-extraction', action='store_true')
    args = parser.parse_args()
    result = dict(passed=False, scope='actual shell overlay and archive target gate; private copies',
                  VMStarts=0, CFWWrites=0, securityWindows=0)
    with contextlib.ExitStack() as stack:
        fixture = FrozenGateTests(); fixture.setUp(); stack.callback(fixture.doCleanups)
        fixture.plan['variant'] = 'exp'; fixture.plan['gates']['variant'] = 'exp'
        fixture.context['variant'] = 'exp'; fixture.publish()
        os.environ.update(VPHONE_CFW_VARIANT='exp', VPHONE_FROZEN_PLAN_SHA256=fixture.digest,
                          VPHONE_FROZEN_CONTEXT=json.dumps(fixture.context))
        vm = fixture.vm
        archive = vm / 'cfw_input/jb/iosbinpack64.tar'
        archive.parent.mkdir(parents=True)
        with archive.open('xb') as stream:
            subprocess.run(['/usr/bin/tar', '-xOf', str(args.resources / 'resources/cfw_input.tar.zst'),
                            'cfw_input/jb/iosbinpack64.tar'], stdout=stream, check=True)
        archive_targets(archive, vm / 'guest')
        before = {member.name: member.size for member in tarfile.open(archive)}
        text = args.installer.read_text()
        start = text.index('apply_dev_overlay() {')
        function = text[start:text.index('\n}\n', start) + 3]
        setup = '''set -euo pipefail
cfw_guest_write() { "$@"; }
die() { print -u2 -- "$*"; exit 1; }
'''
        body = 'apply_dev_overlay'
        gtar = '/opt/homebrew/bin/gtar'
        if args.verify_extraction:
            base_text = (args.resources / 'cfw_install.sh').read_text()
            base_start = base_text.index('cfw_guest_write cp -R "$INPUT_DIR/jb/iosbinpack64.tar"')
            base_end = base_text.index('cfw_guest_write /bin/rm -f $MNT1/iosbinpack64.tar', base_start)
            base_end = base_text.index('\n', base_end)
            base_stage = base_text[base_start:base_end]
            start = text.index('echo "[JB-2]')
            jb_stage = text[start:text.index('# ═══════════ JB-3 ', start)]
            early = text.index('\napply_dev_overlay\n') < text.index('zsh "$SCRIPT_DIR/cfw_install.sh"')
            body = ('apply_dev_overlay\n' if early else '') + base_stage + '\n' + jb_stage
            result['overlayBeforeBase'] = early
            setup = 'set -euo pipefail\nsource "$SCRIPT_DIR/lib/cfw_common.sh"\n'
        run = subprocess.run(['/bin/zsh', '-c', setup + function + '\n' + body],
            env=dict(os.environ, VM_DIR=str(vm), CFW_INPUT='cfw_input', SCRIPT_DIR=str(args.resources.resolve()),
                     PYTHON3=sys.executable, TAR=gtar, MNT1=str(fixture.mount / 'mnt1'),
                     INPUT_DIR=str(vm / 'cfw_input')),
            pass_fds=(fixture.lock_fd,), capture_output=True, text=True)
        result.update(shellExitCode=run.returncode, stdout=run.stdout, stderr=run.stderr,
                      originalMembers=len(before))
        if run.returncode:
            result['error'] = 'overlay shell failed'
        else:
            with tarfile.open(archive) as stream:
                after = {member.name: member.size for member in stream}
            result.update(extraMembers=sorted(after.keys() - before.keys()), missingMembers=sorted(before.keys() - after.keys()))
            try:
                archive_targets(archive, vm / 'guest')
                if args.verify_extraction:
                    rows = [json.loads(line) for line in fixture.evidence.read_text().splitlines()]
                    outputs = component_effects.verify_rows(fixture.load(), rows,
                        {'system': fixture.mount / 'mnt1'}, fixture.evidence.parent / 'effect-blobs')
                    target = fixture.mount / 'mnt1/iosbinpack64/usr/local/bin/rpcserver_ios'
                    payload = args.resources / 'resources/cfw_dev/rpcserver_ios'
                    if target.read_bytes() != payload.read_bytes():
                        raise ValueError('Installed dev payload differs from packaged source')
                    result.update(baseAndJBExtractionPassed=True, finalEffectOutputs=len(outputs))
                result['passed'] = True
            except ValueError as error:
                result['error'] = str(error)
    with args.output.open('x') as stream:
        stream.write(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
