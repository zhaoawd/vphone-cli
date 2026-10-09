#!/usr/bin/env python3
"""Read-only T24 validation of final built apps; writes evidence outside bundles.

Run only after the parent confirms that the final make launchpad build passed.
No SwiftPM, signing mutation, helper registration, TCC, AMFI, CLI/VM execution,
GUI launch, or whole-app copying is performed.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys

BASE = Path('/private/tmp/vphone-b25-t24')
DEFAULT_ROOT = Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
HOST_ROOTS = (
    'Contents/MacOS/vphone-cli', 'Contents/MacOS/vphone-vm', 'Contents/MacOS/ldid',
    'Contents/Resources/.tools/bin/trustcache', 'Contents/Resources/.tools/bin/insert_dylib',
)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-root', type=Path, default=DEFAULT_ROOT)
    parser.add_argument('--output', type=Path, default=BASE / 'final-proof')
    args = parser.parse_args()
    root = args.project_root.resolve()
    out = args.output.resolve()
    require(out.is_relative_to(BASE), 'Evidence output must remain under /private/tmp/vphone-b25-t24')
    require(not out.exists(), f'Evidence output already exists; select a fresh --output: {out}')
    out.mkdir(parents=True)
    policy = BASE / 'homebrew-denied.sb'
    toolchain = root / '.build/vphone-cli.app'
    launchpad = root / '.build/vphone-launchpad.app'
    embedded = launchpad / 'Contents/Helpers/vphone-cli.app'
    report = {
        'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'status': 'running',
        'scope': 'Final signed host Mach-O closure and offline ldid/trustcache operations. '
                 'No CLI/VM execution or whole-app copy. No TCC/helper/AMFI/VM changes. '
                 'Python/PATH portability and actual TCC responsibility are not established.',
        'project_root': str(root), 'commands': [], 'artifacts': {}, 'failures': [],
    }

    def run(argv, label, expected=0, timeout=60):
        argv = [str(arg) for arg in argv]
        result = subprocess.run(argv, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=timeout)
        record = {'label': label, 'argv': argv, 'exit_code': result.returncode,
                  'stdout': result.stdout.decode('utf-8', errors='replace'),
                  'stderr': result.stderr.decode('utf-8', errors='replace')}
        report['commands'].append(record)
        (out / f'{len(report["commands"]):03d}-{label}.stdout').write_bytes(result.stdout)
        (out / f'{len(report["commands"]):03d}-{label}.stderr').write_bytes(result.stderr)
        if expected is None:
            require(result.returncode != 0, f'Expected refusal: {label}')
        else:
            require(result.returncode == expected,
                    f'{label} returned {result.returncode}, expected {expected}; see evidence logs')
        return result

    try:
        require(policy.is_file(), f'Missing existing sandbox policy: {policy}')
        report['sandbox_policy'] = {'path': str(policy), 'sha256': digest(policy),
                                    'text': policy.read_text()}
        report['head'] = run(['git', 'rev-parse', 'HEAD'], 'head').stdout.decode().strip()
        for app in (toolchain, launchpad, embedded):
            require(app.is_dir(), f'Missing final app: {app}')
            require(not app.is_symlink(), f'App must not be a symlink: {app}')
        sandbox = ['/usr/bin/sandbox-exec', '-f', str(policy)]
        for name, library in (
            ('libcrypto', Path('/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib')),
            ('libplist', Path('/opt/homebrew/opt/libplist/lib/libplist-2.0.4.dylib')),
        ):
            require(library.is_file(), f'Original library missing; refusal control is unavailable: {library}')
            result = run([*sandbox, '/usr/bin/head', '-c', '1', library],
                         f'original-{name}-read-denied', expected=None)
            require(not result.stdout, f'Original library unexpectedly readable: {library}')
        expected_entitlements = plistlib.loads((root / 'sources/vphone.entitlements').read_bytes())
        for label, app in (('toolchain', toolchain), ('embedded', embedded)):
            run(['codesign', '--verify', '--strict', '--deep', app], f'{label}-bundle-signature')
            run([sys.executable, '-B', root / 'scripts/build_native_dependencies.py', app, '--check'],
                f'{label}-native-closure')
            paths = [app / name for name in HOST_ROOTS]
            frameworks = app / 'Contents/Frameworks'
            require(frameworks.is_dir(), f'Missing bundled native libraries: {frameworks}')
            paths.extend(sorted(frameworks.glob('*.dylib')))
            entries = {}
            for index, path in enumerate(paths):
                require(path.is_file(), f'Missing host native image: {path}')
                require(path.resolve().is_relative_to(app.resolve()), f'Native image escapes bundle: {path}')
                prefix = f'{label}-image-{index:02d}'
                run(['codesign', '--verify', '--strict', path], f'{prefix}-verify')
                run(['codesign', '-dvvv', path], f'{prefix}-signature')
                run(['otool', '-L', path], f'{prefix}-loads')
                run(['otool', '-D', path], f'{prefix}-id')
                run(['otool', '-l', path], f'{prefix}-load-commands')
                entries[str(path.relative_to(app))] = {'sha256': digest(path)}
            signed = run(['codesign', '-d', '--entitlements', '-', '--xml',
                          app / 'Contents/MacOS/vphone-vm'], f'{label}-vm-entitlements')
            actual = plistlib.loads(signed.stdout)
            for key, value in expected_entitlements.items():
                require(actual.get(key) == value, f'{label} VM entitlement differs: {key}')
            for relative in ('Contents/Info.plist', 'Contents/Resources/build-dependencies.json'):
                entries[relative] = {'sha256': digest(app / relative)}
            metadata = json.loads((app / 'Contents/Resources/build-dependencies.json').read_text())
            require(bool(metadata.get('host_native_libraries')), f'{label}: missing native closure metadata')
            guests = []
            for name in ('vphoned', 'vphoned-less'):
                guest = app / 'Contents/Resources/guest-resources' / name
                require(guest.is_file(), f'Missing signed guest payload: {guest}')
                extracted = run([*sandbox, app / 'Contents/MacOS/ldid', '-e', guest],
                                f'{label}-ldid-{name}-homebrew-denied')
                require(isinstance(plistlib.loads(extracted.stdout), dict),
                        f'{label}: ldid did not return an entitlement dictionary for {name}')
                entries[str(guest.relative_to(app))] = {'sha256': digest(guest)}
                guests.append(guest)
            trustcache = out / f'{label}-v1.trustcache'
            run([*sandbox, app / 'Contents/Resources/.tools/bin/trustcache',
                 'create', '-v', '1', trustcache, *guests], f'{label}-trustcache-create-homebrew-denied')
            run([*sandbox, app / 'Contents/Resources/.tools/bin/trustcache', 'info', trustcache],
                f'{label}-trustcache-info-homebrew-denied')
            report['artifacts'][label] = {'path': str(app), 'files': entries,
                                          'trustcache_sha256': digest(trustcache)}
        require(report['artifacts']['toolchain']['files'] == report['artifacts']['embedded']['files'],
                'Final standalone and embedded native/payload/configuration digests differ')
        run(['codesign', '--verify', '--strict', '--deep', launchpad], 'launchpad-bundle-signature')
        run([sys.executable, '-B', root / 'scripts/build_native_dependencies.py', launchpad, '--check'],
            'launchpad-native-closure')
        report['status'] = 'passed'
    except Exception as error:
        report['status'] = 'failed'
        report['failures'].append(f'{type(error).__name__}: {error}')
    finally:
        report['finished_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        (out / 'report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    print(f'T24 final proof: {report["status"]}; evidence {out / "report.json"}')
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
