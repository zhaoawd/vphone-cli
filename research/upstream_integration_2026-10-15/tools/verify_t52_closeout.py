#!/usr/bin/env python3
"""Recheck archived T52 evidence without executing a VM or changing old records."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
EVIDENCE = ROOT / 'research/upstream_integration_2026-10-15/evidence'
BATCHES = (
    'T52-20261021',
    'T52-entrypoints-20261021',
    'T52-real-20261021',
    'T52-GUI-shutdown-20261022',
    'T52-APIProxy-stop-race-20261022',
    'T52-APIProxy-deployment-20261022',
    'T52-signature-camera-20261022',
    'T52-provider-fix-20261023/prepared',
    'T52-provider-fix-20261023/runtime',
    'T51-runtime-20261021/authorized-boots',
)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify_batch(name):
    base = EVIDENCE / name
    manifest = base / 'manifest.json'
    data = json.loads(manifest.read_text())
    rows = data.get('files', data.get('archived'))
    if isinstance(rows, dict):
        rows = [dict(path=path, **value) for path, value in rows.items()]
    if not isinstance(rows, list) or not rows:
        raise ValueError(f'{manifest}: missing evidence records')
    seen = set()
    for row in rows:
        relative = Path(row['path'])
        if relative.is_absolute() or '..' in relative.parts or str(relative) in seen:
            raise ValueError(f'{manifest}: invalid or repeated path {relative}')
        seen.add(str(relative))
        path = base / relative
        if path.resolve(strict=True) != path or not path.is_file():
            raise ValueError(f'{path}: not a regular evidence file without symlinks')
        if path.stat().st_size != row['bytes'] or digest(path) != row['sha256']:
            raise ValueError(f'{path}: evidence size or SHA-256 mismatch')
    return dict(manifest=str(manifest.relative_to(ROOT)), sha256=digest(manifest),
                filesVerified=len(rows))


def archived(batch, relative):
    return json.loads((EVIDENCE / batch / relative).read_text())


def verify_results():
    environment = archived('T52-real-20261021', 'runtime/environment-acceptance.json')
    if environment['state'] != 'passed' or not environment['checks']:
        raise ValueError('Environment acceptance is incomplete')
    if not all(row['passed'] is True for row in environment['checks']):
        raise ValueError('Environment acceptance has failed checks')
    shutdown = archived('T52-GUI-shutdown-20261022',
                        'runtime/gui-shutdown-fix/default-shutdown-result.json')
    required = ('defaultGUI', 'directVSOCKRequestAccepted', 'guestStopped',
                'diskReleased', 'directoryLockFree', 'metadataPreserved')
    if shutdown['state'] != 'passed' or any(shutdown[k] is not True for k in required):
        raise ValueError('Default GUI shutdown acceptance is incomplete')
    if shutdown['forcedFrameworkStop'] is not False or shutdown['hostHTTPListenerEnabled'] is not False \
            or shutdown['launcherExitCode'] != 0:
        raise ValueError('Default GUI shutdown conditions differ from the accepted scope')
    prefix = 'files/.build/t52-provider-fix-20261023/'
    batch = 'T52-provider-fix-20261023/runtime'
    consumption = archived(batch, prefix + 'consumption-result.json')
    if consumption['consumersPassed'] is not True:
        raise ValueError('Application consumers did not pass')
    for key in ('probeDeploymentExitCode', 'locationExitCode', 'cameraExitCode',
                'probeRestoreExitCode', 'runtimeVerificationExitCode'):
        if consumption[key] != 0:
            raise ValueError(f'Application acceptance failed at {key}')
    if any(value != 0 for value in consumption['formalDiagnosticFlags'].values()):
        raise ValueError('Application probe used diagnostic flags')
    runtime = archived(batch, prefix + 'runtime-final/result.json')
    if runtime['state'] != 'passed' or runtime['runtime']['instanceID'] != consumption['instanceID']:
        raise ValueError('Final runtime and consumption observations differ')
    boot = archived('T51-runtime-20261021/authorized-boots', 'boot-execution.json')
    if boot['state'] != 'passed' or boot['cycles'] != 2 or boot['exitCode'] != 0:
        raise ValueError('Related real-VM two-boot evidence is incomplete')
    return dict(environmentChecks=len(environment['checks']),
                defaultGUIShutdown=True, applicationConsumers=True,
                restoredFormalProbe=True, relatedRebaseBootCycles=boot['cycles'],
                historicalEvidenceOnly=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = dict(schemaVersion=1, state='verified',
                  scope='archived evidence integrity and selected recorded outcomes',
                  batches={name: verify_batch(name) for name in BATCHES},
                  outcomes=verify_results(),
                  accepted=False, humanReviewAccepted=False,
                  externalPhysicalVolume='deferred_by_user',
                  businessApplications='not_tested',
                  currentCodeRegression='reported separately')
    with args.output.open('x') as stream:
        stream.write(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(dict(state=result['state'], batches=len(result['batches']),
                         filesVerified=sum(b['filesVerified'] for b in result['batches'].values()))))


if __name__ == '__main__':
    main()
