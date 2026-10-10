#!/usr/bin/env python3
"""T08 路径和冻结产物核对、迁移计划生成；不打开 Disk.img 或运行 VM。"""
import argparse
from dataclasses import asdict
import json
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from t08_workspace import digest, load_workspace, verify_entries


def source_inputs(paths):
    record = paths.code_root / 'research/upstream_integration_2026-10-06/evidence/B35/T08/source-snapshot.json'
    snapshot = json.loads(record.read_text())
    entries = [x for x in snapshot['sources'] if Path(x['path']).parts[0] in
               ('sources', 'scripts', 'dependencies') or x['path'] in ('Makefile', 'Package.swift', 'Package.resolved')]
    return {'current_code': verify_entries(paths.code_root, entries),
            'frozen_build_inputs': verify_entries(paths.artifact_root, entries),
            'record_sha256': digest(record)}


def migration_plan(paths, classification, environment, api, components):
    report = classification['report']
    if classification.get('exit_code') != 0 or report['classification'] != 'full_migration_required':
        raise ValueError('Expected successful full_migration_required classification')
    if Path(report['vm']).resolve() != paths.research_vm:
        raise ValueError('Saved classification belongs to another VM')
    if report['bootstrap']['launchd_custom_loads'] != ['/b']:
        raise ValueError('Expected the saved classic /b baseline')
    files = [{'source': str(paths.components / x['stage']), 'sha256': components['files_sha256'][x['stage']],
              'target': '/' + x['guest'], 'operation': 'install_in_staged_system', 'mode': '0755',
              'loaded_by': x['loaded_by']} for x in environment['libraries']]
    for name, target, mode in [('vphoned', '/usr/bin/vphoned', '0755'),
                               ('vphoned.plist', '/System/Library/LaunchDaemons/vphoned.plist', '0644')]:
        files.append({'source': str(paths.candidate / name), 'sha256': api['files_sha256'][name],
                      'target': target, 'operation': 'replace_in_staged_system', 'mode': mode})
    return {'schema': 'vphone.t08-offline-migration-plan/1', 'executed': False,
            'saved_classification_only': True, 'live_disk_rechecked': False,
            'vm': str(paths.research_vm), 'source_vm': str(paths.source_vm), 'files': files,
            'launchd': {'target': '/sbin/launchd', 'before': ['/b'], 'after': ['/vh'],
                        'alias': {'path': '/vh', 'target': environment['load_alias']['target']},
                        'preserve': ['original entitlements', 'required jetsam patches'],
                        'procedure': 'rebuild from verified original launchd.bak; patch semantic anchors; inject /vh; sign; verify load commands'},
            'camera': {'modern_header_bytes': components['camera_header_bytes'],
                       'compatible_with_classic_camera': components['compatible_with_classic_camera'],
                       'publisher': 'modern vphoned', 'port': 1338,
                       'required': 'disable classic camera publisher and legacy hook injection before activation'},
            'host_control': {'classic_port': 1337, 'modern_api_port': api['vsock_port'],
                             'compatibility_verified': False,
                             'required': 'adapt retained host controls or provide a camera-disabled classic companion; do not run two camera publishers'},
            'api': {'port': api['vsock_port'], 'pins': api['pins'], 'auto_update_required': 'select matching modern daemon and components together'},
            'launchd_cache': {'target': '/System/Library/xpc/launchd.plist',
                              'required': 'replace classic com.vphone.vphoned job; preserve unrelated jobs; remove stale classic hook jobs after inventory'},
            'deferred': ['live inventory of legacy /cores jobs and Preboot camera hooks',
                         'host 1337 classic control versus modern 1339 API compatibility; classic currently starts camera unconditionally',
                         'preserved original launchd verification and signed staged patch',
                         'modern default bundle/CFW selection implementation',
                         'full staged-disk transaction, validation and publication',
                         'cold-boot RootHide activation and loaded-source acceptance'],
            'rollback': 'retain B36 cold recovery copy; publish only after stopped-disk transaction succeeds; restore clone on failure; never use source vm-new as migration target',
            'scope': 'plan only; no disk mount, write, VM execution, source maintenance or AMFI'}


def default_status(classic, api, component_manifest):
    bundled = classic['files_sha256']['vphoned']
    candidate = api['files_sha256']['vphoned']
    return {'bundled_guest': 'classic' if bundled != candidate else 'matches_modern_candidate',
            'bundled_daemon_sha256': bundled, 'modern_candidate_sha256': candidate,
            'modern_daemon_packaged': bundled == candidate,
            'modern_camera_header_bytes': component_manifest['camera_header_bytes'],
            'runtime_validated': False, 'default_modern_acceptance': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path, default=Path(__file__).with_name('workspace.json'))
    args = parser.parse_args()
    paths = load_workspace(args.workspace)
    evidence = paths.evidence
    base = paths.code_root / 'research/upstream_integration_2026-10-06/evidence'
    start = time.time()
    minimum = paths.check_space()
    inputs = source_inputs(paths)
    (evidence / 'source-inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
    signed = json.loads((base / 'B35/T08/signed-artifacts.json').read_text())
    frozen = []
    for entry in signed['artifacts']:
        path = Path(entry['path'])
        if not path.resolve().is_relative_to(paths.artifact_root):
            raise ValueError('Signed artifact record belongs to another build root')
        if digest(path) != entry['sha256']:
            raise ValueError(f'Frozen artifact changed: {path.name}')
        frozen.append({'path': str(path), 'sha256': entry['sha256']})
    commands = [
        ('bundle-check', ['scripts/check_bundle.py', str(paths.bundle)]),
        ('api-check', ['scripts/check_daemon_api.py', '--checkouts', str(paths.packages / 'checkouts'),
                       '--candidate', str(paths.candidate)]),
        ('components-check', ['scripts/check_guest_components.py', '--stage', str(paths.components)]),
        ('boot-path-check', [str(evidence / 'boot.py'), '--workspace', str(args.workspace.resolve()), '--check']),
        ('client-path-check', [str(evidence / 'client.py'), '--workspace', str(args.workspace.resolve()), '--check']),
    ]
    checks = []
    for name, argv in commands:
        minimum = min(minimum, paths.check_space())
        command = [sys.executable, '-B', *argv]
        result = subprocess.run(command, cwd=paths.code_root, capture_output=True, text=True, timeout=90)
        (evidence / (name + '.txt')).write_text(result.stdout + result.stderr)
        checks.append({'name': name, 'command': command, 'exit': result.returncode})
        if result.returncode:
            (evidence / 'checks-failure.json').write_text(json.dumps(checks, indent=2) + '\n')
            raise RuntimeError(f'{name} failed: see saved output')
    classification_file = base / 'B36/T08/cfw-eligibility.json'
    classification_manifest = json.loads((base / 'B36/T08/manifest.json').read_text())
    entry = next(x for x in classification_manifest['files'] if x['path'] == classification_file.name)
    verify_entries(classification_file.parent, [entry])
    classification = json.loads(classification_file.read_text())
    api = json.loads((paths.candidate / 'manifest.json').read_text())
    components = json.loads((paths.components / 'manifest.json').read_text())
    classic = json.loads((paths.bundle / 'Contents/Resources/guest-resources/manifest.json').read_text())
    environment = json.loads((paths.code_root / 'scripts/guest_environment.json').read_text())
    plan = migration_plan(paths, classification, environment, api, components)
    plan['classification_sha256'] = digest(classification_file)
    (evidence / 'migration-plan.json').write_text(json.dumps(plan, indent=2) + '\n')
    status = default_status(classic, api, components)
    status['modern_component_matches_in_bundle'] = {x['name']: [str(f.relative_to(paths.bundle))
        for f in (paths.bundle / 'Contents/Resources').rglob(x['name'])
        if f.is_file() and not f.is_symlink() and digest(f) == components['files_sha256'][x['stage']]]
        for x in environment['libraries']}
    status['build_selection_evidence'] = {'scripts/build.sh': digest(paths.code_root / 'scripts/build.sh'),
                                        'scripts/build_guest_payloads.sh': digest(paths.code_root / 'scripts/build_guest_payloads.sh')}
    (evidence / 'default-artifacts.json').write_text(json.dumps(status, indent=2) + '\n')
    minimum = min(minimum, paths.check_space())
    summary = {'started_at': start, 'finished_at': time.time(),
               'roots': {k: str(v) for k, v in asdict(paths).items()}, 'frozen_artifacts': frozen,
               'source_input_files': len(inputs['current_code']), 'checks': checks,
               'minimum_free_bytes': minimum, 'runtime_validated': False,
               'default_modern_acceptance': False, 'disk_opened': False,
               'new_build_executed': False, 'scope': 'existing frozen builds verified against identical current production inputs'}
    (evidence / 'offline-result.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({'checks_passed': len(checks), 'source_input_files': len(inputs['current_code']),
                      'runtime_validated': False, 'default_modern_acceptance': False}))


if __name__ == '__main__':
    main()
