#!/usr/bin/env python3
"""Read CFW evidence after the create runner records two successful boots.

This does not install, boot, stop, or grant Undo authority. It captures the
production receipt reader and generation verifier against the current disk.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vm', type=Path, required=True)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--boot-evidence', type=Path, help='current API two-boot proof for a standalone restored VM')
    args = parser.parse_args()
    vm, cli, out = args.vm.resolve(strict=True), args.cli.resolve(strict=True), args.out.resolve()
    if vm.parent != ROOT or not vm.name.startswith('vm-t32-t33-'):
        raise ValueError('this acceptance tool requires an independent T32/T33 VM in this repository')
    out.mkdir(parents=True, exist_ok=False)
    result = dict(schemaVersion=1, vm=str(vm), scope='post-create journal readability',
                  runtimeEffectsValidated=False, state='running', commands=[])

    def save():
        (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')

    try:
        if args.boot_evidence:
            raw = args.boot_evidence.resolve(strict=True).read_bytes()
            (out / 'api-boot-evidence.json').write_bytes(raw)
            proof = json.loads(raw)
            cycles = proof.get('cycles', [])
            if (proof.get('state') != 'passed' or proof.get('scope') != 'api-two-boot-baseline' or proof.get('vm') != str(vm)
                    or len(cycles) != 2 or any(not row.get('guestStopped') or row.get('forcedFrameworkStop')
                                              or not row.get('diskReleased') for row in cycles)
                    or cycles[0]['bootSessionUUID'] == cycles[1]['bootSessionUUID']
                    or cycles[0]['bootSeconds'] == cycles[1]['bootSeconds']):
                raise ValueError('standalone VM requires actual two-boot API/normal shutdown evidence')
            result['scope'] = 'post-API-two-boot journal readability'
        else:
            raw = (vm / '.create-checkpoint/checkpoint.json').read_bytes()
            (out / 'create-checkpoint.json').write_bytes(raw)
            checkpoint = json.loads(raw)
            stages = {stage['stage']: stage for stage in checkpoint['stages']}
            for name in ('cfw', 'first_boot', 'verification'):
                if stages[name]['status'] != 'succeeded':
                    raise ValueError(f'{name} has not succeeded; post-boot scenario is not established')
            if stages['first_boot']['evidence'].get('prompt') != 'matched':
                raise ValueError('first boot has no detected shell prompt')
        current = (vm / 'Disk.img').lstat()
        result['imageIdentity'] = {name: getattr(current, 'st_' + name)
                                   for name in ('dev', 'ino', 'size', 'mtime_ns')}
        archives = []
        for archive in (vm / '.cfw-history').iterdir():
            record = json.loads((archive / 'transaction.json').read_bytes())
            staged = record.get('staged', {})
            if (staged.get('dev'), staged.get('ino')) == (current.st_dev, current.st_ino):
                archives.append((archive, record))
        if len(archives) != 1 or archives[0][1].get('status') != 'published':
            raise ValueError('current disk has no unique published journal')
        archive, record = archives[0]
        result['transactionID'] = record['id']
        for name in ('transaction.json', 'guest-publication.json', 'guest-effects-final.json'):
            (out / name).write_bytes((archive / name).read_bytes())
        publication = json.loads((out / 'guest-publication.json').read_bytes())
        result['publicationIdentity'] = publication['imageIdentity']
        result['identityChangedSincePublication'] = result['imageIdentity'] != publication['imageIdentity']
        desired = (vm / '.firmware-desired-plan.json').read_bytes()
        env = dict(os.environ, VPHONE_PYTHON=str(ROOT / '.venv/bin/python3'))
        commands = [
            ('receipts', [str(cli), 'cfw', 'receipts', vm.name, '--library-root', str(vm.parent), '--json']),
            ('verify-plan', [str(cli), 'cfw', 'verify-plan', str(vm), '--expected-sha256',
                             hashlib.sha256(desired).hexdigest()]),
        ]
        for name, command in commands:
            child = subprocess.run(command, capture_output=True, text=True, env=env, timeout=600)
            (out / (name + '.stdout')).write_text(child.stdout)
            (out / (name + '.stderr')).write_text(child.stderr)
            result['commands'].append(dict(name=name, argv=command, exitCode=child.returncode))
            save()
        result['state'] = 'passed' if all(row['exitCode'] == 0 for row in result['commands']) else 'failed'
        if result['state'] == 'passed':
            receipt = json.loads((out / 'receipts.stdout').read_bytes())
            expected_state = ('committed-publication' if receipt.get('runtimeImageChanged') else 'committed-effects')
            if (receipt.get('state') != expected_state
                    or receipt.get('runtimeValidated') is not False
                    or receipt.get('imageSHA256') != publication['imageSHA256']
                    or receipt.get('transactionID') != record['id']
                    or receipt.get('generationID') != json.loads(desired)['generationID']):
                raise ValueError('production Receipt reader did not return this committed publication')
            if record['version'] == 4:
                current_sha = receipt.get('currentImageSHA256')
                if (not isinstance(current_sha, str) or len(current_sha) != 64
                        or receipt.get('runtimeImageChanged') != (current_sha != publication['imageSHA256'])):
                    raise ValueError('runtime image/publication distinction differs')
                result['runtimeImageChanged'] = receipt['runtimeImageChanged']
                result['currentImageSHA256'] = current_sha
            after = (vm / 'Disk.img').lstat()
            if any(getattr(current, 'st_' + key) != getattr(after, 'st_' + key) for key in ('dev', 'ino', 'size', 'mtime_ns')):
                raise ValueError('current disk changed during acceptance')
    except Exception as error:
        result.update(state='failed', error=f'{type(error).__name__}: {error}')
        raise
    finally:
        save()
    print(json.dumps(result))
    return 0 if result['state'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
