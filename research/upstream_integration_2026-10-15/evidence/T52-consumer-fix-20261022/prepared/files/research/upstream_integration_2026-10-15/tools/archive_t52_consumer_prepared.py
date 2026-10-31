#!/usr/bin/env python3
"""Archive prepared candidate/failed prechecks without rewriting older evidence."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t52-consumer-fix-20261022'
DEST = ROOT / 'research/upstream_integration_2026-10-15/evidence/T52-consumer-fix-20261022/prepared'


def main():
    DEST.mkdir(parents=True, exist_ok=False)
    files = [p for p in WORK.iterdir() if p.is_file() and p.suffix in ('.json', '.log', '.plist', '.py')]
    names = ['t52_consumer_maintenance.py', 't52_system_consumer_maintenance.py', 'deploy_t52_consumer_root.py',
             'deploy_t52_system_consumer_root.py', 'deploy_t52_consumer_publisher.py',
             'build_t52_consumer_candidate.py', 'archive_t52_consumer_prepared.py', 't52_helper_supervisor.py']
    files += [Path(__file__).with_name(name) for name in names]
    files += [ROOT / 'dependencies/guest-components-pins.json',
              ROOT / 'sources/VPhoneDaemon/Daemon/GuestLocationSimulation.swift',
              ROOT / 'scripts/vphoned/vphoned_location.m', ROOT / 'scripts/vphoned/vphoned_location_bridge.inc',
              ROOT / 'scripts/patchers/cfw_daemons.py', WORK / 'boot-window/scoped-amfidont.py']
    pins = json.loads((ROOT / 'dependencies/guest-components-pins.json').read_text())
    files += [ROOT / row['local'] for row in pins['files']]
    for pattern in ['test_guest_location_bridge.py', 'test_guest_simulation_access.py', 'test_guest_camera_source_provider.py',
                    'test_guest_api_location.py', 'test_t52_consumer_maintenance.py', 'test_t52_system_consumer_maintenance.py',
                    'test_t52_publisher_transition.py', 'test_launchhook_spawn.py', 'test_guest_api_cohort.py']:
        files.append(ROOT / 'tests' / pattern)
    files += [ROOT / 'tests/fixtures' / name for name in ['guest_location_bridge.m', 'guest_simulation_access.c',
                                                         'guest_camera_source_provider.m']]
    for attempt in ['capture-source-readonly-r2', 'capture-source-readonly-r3']:
        files += list((ROOT / '.build/t52-camera-diagnostics-20261022' / attempt).rglob('*.json'))
    for name in ['guest-resources/cohort.json', 'consumer-interface-provenance.json',
                 'build-dependencies.json', '.build/guest-components-v2/stage/manifest.json']:
        files.append(WORK / 'package-r2/VPhone.bundle/Contents/Resources' / name)
    records = []
    for source in sorted(set(files)):
        relative = source.relative_to(ROOT)
        destination = DEST / 'files' / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        expected = hashlib.sha256(source.read_bytes()).hexdigest()
        if hashlib.sha256(destination.read_bytes()).hexdigest() != expected:
            raise ValueError('Archive mismatch: ' + str(relative))
        records.append(dict(source=str(relative), archive=str(destination.relative_to(DEST)), sha256=expected,
                            bytes=destination.stat().st_size))
    (DEST / 'manifest.json').write_text(json.dumps(dict(schema=1, phase='prepared_and_failed_offline_precheck',
        candidate='2.6.2-local.cc05d88f441f', consumerAccepted=False, records=records), indent=2) + '\n')
    print(json.dumps(dict(state='verified', records=len(records), manifest=str(DEST / 'manifest.json'))))


if __name__ == '__main__': main()
