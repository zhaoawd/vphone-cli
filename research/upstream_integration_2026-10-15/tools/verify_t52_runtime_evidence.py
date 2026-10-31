#!/usr/bin/env python3
"""Verify captured API-mode runtime evidence while retaining the default-mode failure."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[3]
work = root / '.build/t52-real-20261021'
read = lambda name: json.loads((work / name).read_text())
guest = read('post-update-guest-result.json')
environment = read('post-update-environment-status.json')
stop = read('post-update-stop-result.json')
launch = read('api-boot/launch-result.json')
cleanup = read('post-update-boot/cleanup.json')
comparison = read('component-comparison.json')
failure = read('post-update-stop-failure/failure.json')
checks = []


def check(name, value):
    checks.append(dict(name=name, passed=bool(value)))


check('guest_connected_and_readback_passed', guest['state'] == 'passed' and guest['guestConnected'])
check('system_version', guest['systemVersion']['ProductVersion'] == '26.1' and guest['systemVersion']['ProductBuildVersion'] == '23B85')
check('normal_guest_shutdown', stop['state'] == 'passed' and stop['guestStopped'] and not stop['forcedFrameworkStop'])
check('launch_wrapper_exit_zero', launch['exitCode'] == 0)
check('observed_instance_stopped', guest['runtime']['instanceID'] == stop['instanceID'] and guest['runtime']['pid'] == stop['pid'])
check('disk_and_directory_released', stop['diskReleased'] and stop['directoryLockFree'])
check('configuration_binding_identity_preserved', all(stop['preserved'].values()))
check('environment_current', environment['ok'] and environment['assessment']['state'] == 'already_current')
load = environment['load']
check('mapping_scan_complete', load['complete'] and load['uninspected'] == [])
check('five_mapping_records', {row['name'] for row in load['libraries']} == set(comparison['libraries']))
for name, expected in comparison['libraries'].items():
    check(name + '_guest_hash', guest['libraries'][name]['sha256'] == expected['targetSHA256'])
    row = next(row for row in load['libraries'] if row['name'] == name)
    check(name + '_mapped_current', row['state'] == 'current' and bool(row['current_pids']) and row['stale'] == [])
helper = cleanup['state']
check('single_attachment_within_bound', helper['attempt'] == helper['maxAttachments'] == 1 and helper['maxSeconds'] == 600)
check('helper_stopped_before_deadline', helper['state'] == 'stopped' and helper['stoppedAt'] < helper['deadline'] and cleanup['independentlyConfirmedAbsent'])
check('no_persistent_allowlist_change', cleanup['persistentAllowlistChanged'] is False)
check('default_gui_shutdown_failure_retained', failure['normalShutdownPassed'] is False)
result = dict(state='passed' if all(row['passed'] for row in checks) else 'failed', checks=checks,
    scope='API-enabled bound runtime: installed files, mapped copies and normal shutdown',
    defaultGUIWithoutAPIGracefulShutdown='failed; framework request timed out; original evidence retained',
    applicationBehavior='not verified: camera and location behavior need separate acceptance')
(work / 'post-update-runtime-acceptance.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(dict(state=result['state'], checks=len(checks), failed=[row['name'] for row in checks if not row['passed']]), indent=2))
raise SystemExit(0 if result['state'] == 'passed' else 1)
