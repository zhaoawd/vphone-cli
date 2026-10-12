#!/usr/bin/env python3
"""Install the v2 profile only on a mounted T15 staged System volume."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile

import cfw_env_update as environment
from patchers.cfw_daemons import inject_daemon
from daemon_api_overlays import declarations, validate_marker

SCHEMA = 'vphone.guest-environment-install/1'
SCRIPT_DIR = Path(__file__).resolve().parent


def run_command(args):
    return subprocess.run(args, capture_output=True, check=True)


def command(runner, args):
    result = runner([str(arg) for arg in args])
    if result.returncode:
        raise OSError(f'{args[0]} exited {result.returncode}: {result.stderr.decode("utf-8", "replace")}')
    return result.stdout


def target_path(root, relative):
    path = root / relative.lstrip('/')
    if root not in path.parent.resolve().parents and path.parent.resolve() != root:
        raise environment.Refused(f'target parent escapes System volume: {relative}')
    return path


def atomic_write(target, data, mode, owner):
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f'.{target.name}.vphone-env-', dir=target.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(), mode)
            os.fchown(stream.fileno(), *owner)
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def daemon_candidate(directory, profile):
    directory = Path(directory)
    record = directory / 'manifest.json'
    if directory.is_symlink() or not directory.is_dir() or record.is_symlink() or not record.is_file():
        raise environment.Refused('API daemon candidate has no regular manifest.json')
    manifest = json.loads(record.read_text())
    if manifest.get('schema_version') != 1:
        raise environment.Refused('unsupported API daemon candidate manifest')
    pins = json.loads((SCRIPT_DIR.parent / 'dependencies/daemon-api-pins.json').read_text())['pins']
    if manifest.get('pins') != pins:
        raise environment.Refused('API daemon candidate pins differ from the fixed dependency graph')
    overlays = declarations()
    if manifest.get('source_overlays') != overlays:
        raise environment.Refused('API daemon candidate source overlays differ from the fixed declarations')
    for name in ('vphoned', 'vphoned-api.plist', 'vphoned.entitlements.plist'):
        path = directory / name
        if path.is_symlink() or not path.is_file() or manifest.get('files_sha256', {}).get(name) != environment.sha256_path(path):
            raise environment.Refused(f'API daemon candidate differs from manifest: {name}')
    if not environment.has_code_signature(directory / 'vphoned'):
        raise environment.Refused('API daemon candidate has no code signature')
    validate_marker((directory / 'vphoned').read_bytes(), overlays)
    plist = plistlib.loads((directory / 'vphoned-api.plist').read_bytes())
    if (plist.get('Label') != profile['label'] or plist.get('ProgramArguments') != [profile['program']]
            or plist.get('EnvironmentVariables', {}).get('VPHONED_VCAM') != profile['vcam']
            or plist.get('StandardOutPath') != profile['log'] or plist.get('StandardErrorPath') != profile['log']):
        raise environment.Refused('API daemon candidate launchd identity differs from profile')
    return plist


def install_mounted(root, vm, components, daemon, report_path, *, variant='regular',
                    owner=(0, 0), runner=run_command, transaction_id=None, frozen_plan=None):
    root, vm, components, daemon, report_path = map(Path, (root, vm, components, daemon, report_path))
    root = root.resolve()
    record = {'schema': SCHEMA, 'profile': 'v2', 'variant': variant, 'result': 'failed',
              'started_at': environment.now(), 'files': [], 'transaction_id': transaction_id}
    manifest = environment.load_manifest()
    profile = manifest['profiles']['v2']
    try:
        if variant not in profile['variants']:
            raise environment.Refused(f'guest environment v2 does not support variant {variant}')
        if (components / 'manifest.json').is_symlink():
            raise environment.Refused('components manifest must be a regular file')
        expected = environment.candidates(components, manifest)
        daemon_candidate(daemon, profile['api_daemon'])
        for relative in [entry['guest'] for entry in manifest['libraries']] + [manifest['launchd'],
                         manifest['launchd'] + '.bak', manifest['install_marker'],
                         'System/Library/xpc/launchd.plist', profile['api_daemon']['program'],
                         profile['api_daemon']['plist'], manifest['load_alias']['path']]:
            path = target_path(root, relative)
            if path.is_symlink() and relative != manifest['load_alias']['path']:
                raise environment.Refused(f'profile file must not be a symlink: {relative}')
        record.update(manifest_sha256=environment.sha256_path(environment.MANIFEST),
                      components_manifest_sha256=environment.sha256_path(components / 'manifest.json'),
                      daemon_manifest_sha256=environment.sha256_path(daemon / 'manifest.json'))
        marker = root / manifest['install_marker']
        if marker.is_symlink() or not marker.is_file():
            raise environment.Refused('System volume has no completed CFW install marker')
        before = environment.assess(root, vm, components, manifest)
        record['assessment_before'] = before
        local_rows = [row for row in before['libraries'] if row['scope'] == 'local']
        fresh = (before['classification'] == 'full_migration_required' and before['bootstrap']['kind'] == 'none'
                 and not before['bootstrap']['v2_alias_present']
                 and all(row['state'] == 'missing' for row in local_rows))
        reinstall = (before['classification'] == 'already_current' and before['bootstrap']['kind'] == 'v2'
                     and 'v2' in before['guest_environment_records'].values())
        if not fresh and not reinstall:
            raise environment.Refused('v2 install requires a clean classic System volume or a recorded, current v2 profile')
        backup = root / (manifest['launchd'] + '.bak')
        if os.path.lexists(backup) and (backup.is_symlink() or not backup.is_file()):
            raise environment.Refused('launchd backup must be a regular file')
        launchd = root / manifest['launchd']
        if launchd.is_symlink() or not launchd.is_file():
            raise environment.Refused('launchd must be a regular file')
        certificate = vm / 'cfw_input/signcert.p12'
        if certificate.is_symlink() or not certificate.is_file():
            raise environment.Refused('missing regular cfw_input/signcert.p12')
        target_plist = root / 'System/Library/xpc/launchd.plist'
        if target_plist.is_symlink() or not target_plist.is_file():
            raise environment.Refused('launchd.plist must be a regular file')
        document = plistlib.loads(target_plist.read_bytes())
        if not isinstance(document.get('LaunchDaemons', {}), dict):
            raise environment.Refused('launchd.plist LaunchDaemons must be a dictionary')
    except (environment.Refused, OSError, ValueError, struct.error, TypeError, AttributeError) as error:
        record.update(result='refused', error=str(error))
        environment.save(report_path, record)
        return 3

    def write(relative, data, mode, source):
        path = target_path(root, relative)
        previous = environment.sha256_path(path) if path.is_file() and not path.is_symlink() else None
        if frozen_plan is not None:
            from patchers import plan_gate as gate
            target = 'system:/' + relative.lstrip('/')
            gate.authorize(frozen_plan, 'system-launchdaemons-boot-environment', target)
            from patchers import component_effects as effects
            store=Path(os.environ['VPHONE_GUEST_EVIDENCE']).parent/'effect-blobs'
            actual_before = gate.snapshot(path)
            effect_before=effects.capture_input(path,store)
            source_state=effects.capture_input(source,store)
            if source_state.get('sha256')!=hashlib.sha256(data).hexdigest():
                raise environment.Refused('v2 write data differs from source')
        atomic_write(path, data, mode, owner)
        if frozen_plan is not None:
            effect=effects.capture_copy(source_state,path,store,before=effect_before)
            effect.update(command='cp',sourcePath=str(source))
            gate.append_evidence(frozen_plan, 'system-launchdaemons-boot-environment', target, path, actual_before, gate.snapshot(path),effect=effect)
        record['files'].append({'path': '/' + relative.lstrip('/'), 'before': previous,
                                'after_sha256': environment.sha256_path(path), 'mode': f'{mode:04o}',
                                'owner': f'{owner[0]}:{owner[1]}'})

    (vm / '.cfw_temp').mkdir(mode=0o700, exist_ok=True)
    try:
        for entry in manifest['libraries']:
            write(entry['guest'], Path(expected[entry['name']]['source']).read_bytes(), 0o755, Path(expected[entry['name']]['source']))
        alias = root / manifest['load_alias']['path']
        if not os.path.lexists(alias):
            if frozen_plan is not None:
                from patchers import plan_gate as gate
                target = 'system:/' + manifest['load_alias']['path'].lstrip('/')
                gate.authorize(frozen_plan, 'system-launchdaemons-boot-environment', target)
                from patchers import component_effects as effects
                store=Path(os.environ['VPHONE_GUEST_EVIDENCE']).parent/'effect-blobs'
                actual_before = gate.snapshot(alias)
                effect_before=effects.capture_input(alias,store)
            os.symlink(manifest['load_alias']['target'], alias)
            os.lchown(alias, *owner)
            if frozen_plan is not None:
                gate.append_evidence(frozen_plan, 'system-launchdaemons-boot-environment', target, alias, actual_before, gate.snapshot(alias),effect=effects.capture_change(effect_before,alias,store))
        before_loads = environment.dylib_loads(launchd)
        launchd_before = environment.sha256_path(launchd)
        entitlements = command(runner, ['ldid', '-e', launchd])
        entitlements_object = plistlib.loads(entitlements)
        entitlements_digest = hashlib.sha256(plistlib.dumps(entitlements_object, sort_keys=True)).hexdigest()
        if '/vh' not in before_loads:
            backup = root / (manifest['launchd'] + '.bak')
            if not os.path.lexists(backup):
                write(manifest['launchd'] + '.bak', launchd.read_bytes(), 0o755, launchd)
            from patchers import guest_write
            directory=guest_write.signing_directory(frozen_plan) if frozen_plan is not None else tempfile.TemporaryDirectory(prefix='.vphone-launchd-', dir=vm / '.cfw_temp')
            with directory as temp:
                patched = Path(temp) / 'launchd'
                if frozen_plan is None: patched.write_bytes(launchd.read_bytes())
                else: guest_write.run(frozen_plan,['cp',str(launchd),str(patched)])
                patched.chmod(0o755)
                ents = Path(temp) / 'entitlements.plist'
                ents.write_bytes(entitlements)
                command(runner, [sys.executable, SCRIPT_DIR / 'patchers/cfw.py', 'inject-dylib', patched, '/vh'])
                signing_args=['ldid', '-S' + str(ents), '-M', '-K' + str(certificate), str(patched)]
                if frozen_plan is not None:
                    guest_write.sign(frozen_plan,signing_args,execute=lambda args: command(runner,args))
                else: command(runner,signing_args)
                after_entitlements = plistlib.loads(command(runner, ['ldid', '-e', patched]))
                if after_entitlements != entitlements_object:
                    raise environment.Refused('launchd entitlements changed during signing')
                if '/vh' not in environment.dylib_loads(patched) or not environment.has_code_signature(patched):
                    raise environment.Refused('signed launchd has no /vh load command or code signature')
                write(manifest['launchd'], patched.read_bytes(), 0o755, patched)
        record['launchd'] = {'before_sha256': launchd_before, 'after_sha256': environment.sha256_path(launchd),
                             'load_commands_before': before_loads, 'load_commands_after': environment.dylib_loads(launchd),
                             'entitlements_sha256_before': entitlements_digest,
                             'entitlements_sha256_after': entitlements_digest,
                             'result': 'unchanged' if '/vh' in before_loads else 'injected'}
        api = profile['api_daemon']
        write(api['program'], (daemon / 'vphoned').read_bytes(), 0o755, daemon / 'vphoned')
        write(api['plist'], (daemon / 'vphoned-api.plist').read_bytes(), 0o644, daemon / 'vphoned-api.plist')
        plist_before = environment.sha256_path(target_plist)
        with tempfile.TemporaryDirectory(prefix='.vphone-daemon-', dir=vm / '.cfw_temp') as temp:
            injected = Path(temp) / 'launchd.plist'
            if frozen_plan is None: injected.write_bytes(target_plist.read_bytes())
            else:
                from patchers import guest_write, component_effects as effects, plan_gate as gate
                guest_write.run(frozen_plan,['cp',str(target_plist),str(injected)])
                gate.authorize(frozen_plan,'system-launchdaemons-boot-environment','system:/System/Library/xpc/launchd.plist')
                store=Path(os.environ['VPHONE_GUEST_EVIDENCE']).parent/'effect-blobs'
                plist_snapshot=gate.snapshot(injected);plist_input=effects.capture_input(injected,store)
            inject_daemon(injected, daemon / 'vphoned-api.plist', api['launchd_key'])
            if frozen_plan is not None:
                gate.append_evidence(frozen_plan,'system-launchdaemons-boot-environment','system:/System/Library/xpc/launchd.plist',
                    injected,plist_snapshot,gate.snapshot(injected),effect=effects.capture_change(plist_input,injected,store))
            write('System/Library/xpc/launchd.plist', injected.read_bytes(), 0o644, injected)
        record['launchd_plist'] = {'key': api['launchd_key'], 'before_sha256': plist_before,
                                   'after_sha256': environment.sha256_path(target_plist)}
        after = environment.assess(root, vm, components, manifest)
        record['assessment_after'] = after
        if after['classification'] != 'already_current' or not after['daemon']['launchd_key_present']:
            raise environment.Refused(f'installed volume is {after["classification"]}: {after["reasons"]}')
        if after['daemon']['sha256'] != environment.sha256_path(daemon / 'vphoned'):
            raise environment.Refused('installed API daemon differs from candidate')
        record['reserved'] = [dict(entry, state='reserved_absent' if not os.path.lexists(root / entry['guest'])
                                   else 'reserved_present_preserved') for entry in profile['reserved']]
        record.update(result='installed', finished_at=environment.now())
        environment.save(report_path, record)
        return 0
    except (environment.Refused, OSError, ValueError, subprocess.SubprocessError) as error:
        record['error'] = str(error)
        environment.save(report_path, record)
        return 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['install'])
    parser.add_argument('vm')
    parser.add_argument('--device', required=True)
    parser.add_argument('--mount', required=True)
    parser.add_argument('--components', required=True)
    parser.add_argument('--daemon', required=True)
    parser.add_argument('--report', required=True)
    parser.add_argument('--variant', default='regular')
    parser.add_argument('--transaction-id')
    args = parser.parse_args(argv)
    from patchers import plan_gate as gate
    plan = gate.from_environment()
    gate.validate_entry(plan, 'cfw_install_host.sh')
    if plan.context['guestEnvironment'] != 'v2' or args.variant != plan.context['variant']:
        raise environment.Refused('v2 install mode/profile differs from frozen plan')
    gate.require_write_context(plan)
    vm = Path(args.vm).resolve(strict=True)
    mountpoint = Path(args.mount)
    if vm not in mountpoint.resolve().parents:
        raise environment.Refused(f'mountpoint {mountpoint} must be inside {vm}')
    if str(vm) != plan.context['vmDirectory']: raise environment.Refused('v2 install VM differs from frozen plan')
    mountpoint.mkdir(mode=0o700, exist_ok=True)
    environment.mount_volume(args.device, mountpoint, readonly=False)
    try:
        return install_mounted(mountpoint, vm, args.components, args.daemon, args.report,
                               variant=args.variant, transaction_id=args.transaction_id, frozen_plan=plan)
    finally:
        try:
            environment.unmount(mountpoint)
        except (environment.DiskAccess, OSError) as error:
            record = json.loads(Path(args.report).read_text()) if Path(args.report).is_file() else {'schema': SCHEMA}
            record.update(result='failed', error=f'unmount: {error}')
            environment.save(args.report, record)
            raise


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (environment.Refused, environment.DiskAccess, OSError, ValueError) as error:
        print(f'[-] v2 install refused: {error}', file=sys.stderr)
        sys.exit(3)
