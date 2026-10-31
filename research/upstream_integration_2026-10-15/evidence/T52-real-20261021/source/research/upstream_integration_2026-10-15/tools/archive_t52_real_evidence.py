#!/usr/bin/env python3
"""Archive small T52 acceptance artifacts; VM disks and firmware stay in place."""
import gzip
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t52-real-20261021'
OUT = ROOT / 'research/upstream_integration_2026-10-15/evidence/T52-real-20261021'
SOURCE_PATHS = [
    'scripts/build.sh', 'scripts/check_bundle.py',
    'scripts/patchers/component_signatures.py', 'scripts/patchers/guest_write.py',
    'scripts/lib/cfw_common.sh', 'scripts/patchers/cfw.py', 'scripts/patchers/cfw_daemons.py',
    'tests/test_guest_api_cohort.py',
    'tests/test_component_signatures.py', 'tests/test_patch_plan_gate.py',
    'research/upstream_integration_2026-10-15/tools/verify_t52_launchd_signing.py',
    'research/upstream_integration_2026-10-15/tools/monitor_t52_real.py',
    'sources/vphone-cli/VPhoneCFWEnvironmentCLI.swift',
    'sources/vphone-cli/VPhoneAppDelegate.swift',
    'sources/vphone-cli/VPhoneVMLaunchCLI.swift',
    'sources/vphone-cli/VPhoneVirtualMachine.swift',
    'sources/vphone-cli/VPhoneAPIProxyOptions.swift',
    'tests/VPhoneCLITests/EnvironmentBindingTests.swift',
    'tests/test_bundle_validation.py',
    'research/upstream_integration_2026-10-15/tools/archive_t52_real_evidence.py',
    'research/upstream_integration_2026-10-15/tools/verify_t52_environment_acceptance.py',
    'research/upstream_integration_2026-10-15/tools/capture_t52_vm_metadata.py',
    'research/upstream_integration_2026-10-15/tools/read_t52_environment.py',
    'research/upstream_integration_2026-10-15/tools/apply_t52_binding_ui.cua.mjs',
    'research/upstream_integration_2026-10-15/tools/build_t52_launchpad_env_fix.py',
    'research/upstream_integration_2026-10-15/tools/retry_t52_environment_ui.cua.mjs',
    'research/upstream_integration_2026-10-15/tools/verify_t52_running_guest.py',
    'research/upstream_integration_2026-10-15/tools/verify_t52_stopped.py',
    'research/upstream_integration_2026-10-15/tools/verify_t52_runtime_evidence.py',
    'research/upstream_integration_2026-10-15/tools/accept_t52_runtime_ui.cua.mjs',
    'sources/VPhoneLaunchpadKit/VPhoneLaunchpadChildProcess.swift',
    'tests/VPhoneLaunchpadKitTests/ChildEnvironmentTests.swift',
]

def copy(source, relative):
    destination = OUT / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    data = source.read_bytes()
    if source.suffix in ('.log', '.txt'):
        destination = destination.with_name(destination.name + '.gz')
        destination.write_bytes(gzip.compress(data, mtime=0))
    else:
        destination.write_bytes(data)

OUT.mkdir(parents=True, exist_ok=True)
for base in (WORK, WORK / 'retry-1', WORK / 'cfw-fix', WORK / 'cfw-profile-fix', WORK / 'boot-window', WORK / 'post-update-boot', WORK / 'post-update-stop-failure', WORK / 'api-boot', WORK / 'signing-repro-verified', WORK / 'ui'):
    if not base.exists():
        continue
    for source in sorted(base.iterdir()):
        if source.is_file() and source.suffix in ('.json', '.jsonl', '.log', '.txt', '.py', '.zsh', '.sh', '.png'):
            copy(source, Path('runtime') / source.relative_to(WORK))
for name in SOURCE_PATHS:
    source = ROOT / name
    if source.exists():
        copy(source, Path('source') / name)
vm = ROOT / '.build/t51rt/lib/t52-v2'
for name in ('.create-checkpoint/checkpoint.json', '.firmware-desired-plan.json',
             '.firmware-component-receipts.json', 'restore-info.json', 'config.plist',
             'launchpad.json', 'udid-prediction.txt'):
    source = vm / name
    if source.is_file():
        copy(source, Path('vm') / name)
history = vm / '.cfw-history'
if history.exists():
    for transaction in sorted(history.iterdir()):
        if not transaction.is_dir():
            continue
        for name in ('transaction.json', 'guest-changes.jsonl', 'environment-update.json',
                     'guest-environment-install.json'):
            source = transaction / name
            if source.is_file():
                copy(source, Path('vm/.cfw-history') / transaction.name / name)
report = ROOT / 'research/upstream_integration_2026-10-15/T52_real_bundle_environment_20261021.md'
if report.exists():
    copy(report, Path(report.name))
entries = []
for source in sorted(OUT.rglob('*')):
    if source.is_file() and source != OUT / 'manifest.json':
        data = source.read_bytes()
        entries.append(dict(path=str(source.relative_to(OUT)), bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
(OUT / 'manifest.json').write_text(json.dumps(dict(schemaVersion=1,
    scope='T52 real Core Bundle and environment replacement; consult report for current completion and limitations',
    accepted=False, files=entries), ensure_ascii=False, indent=2) + '\n')
print(json.dumps(dict(files=len(entries), manifest=str(OUT / 'manifest.json'))))
