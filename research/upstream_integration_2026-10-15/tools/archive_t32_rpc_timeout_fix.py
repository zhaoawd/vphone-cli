#!/usr/bin/env python3
"""Archive the offline RPC deadline fix without upgrading runtime evidence."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / '.build/t32-t33-completion-20261023'
RESEARCH = ROOT / 'research/upstream_integration_2026-10-15'
DEST = RESEARCH / 'evidence/T32-T33-completion-20261023/rpc-timeout-fix'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if DEST.exists():
        raise ValueError('Preserve existing evidence')
    prior = []
    for path in sorted(DEST.parent.glob('*/manifest.json')):
        record = json.loads(path.read_text())
        for row in record['files']:
            member = path.parent / row['path']
            if sha(member) != row['sha256'] or member.stat().st_size != row['bytes']:
                raise ValueError('Preserved evidence changed: ' + str(member))
        prior.append(dict(path=str(path.relative_to(ROOT)), sha256=sha(path), files=len(record['files'])))
    sources = [ROOT / name for name in [
        'sources/VPhoneAPIKit/VPhoneAPIClient.swift',
        'sources/VPhoneAPIKit/VPhoneAPIHTTPExchange.swift',
        'sources/VPhoneAPIKit/VPhoneAPIWebSocket.swift',
        'sources/VPhoneAPIKit/VPhoneStartupUnlock.swift',
        'sources/vphone-cli/VPhoneAppDelegate.swift',
        'sources/VPhoneDaemon/Daemon/GuestScreenUnlock.swift',
        'sources/VPhoneDaemon/Daemon/GuestAPI+SetupAssistant.swift',
        'tests/VPhoneAPIKitTests/APIRPCTimeoutTests.swift',
        'tests/fixtures/host_api/server.py',
        'research/0_binary_patch_comparison.md', 'TASKS.md']]
    sources.extend(RESEARCH / name for name in ['T32_T33_completion_20261023.md',
        'progress.md', 'tasks.json', 'local_reconciliation.json', 'local_reconciliation.md',
        'tools/archive_t32_rpc_timeout_fix.py'])
    sources.extend(BASE / name for name in ['rpc-timeout-red.log', 'rpc-timeout-green.log', 'rpc-deadline-analysis.json'])
    DEST.mkdir(parents=True)
    rows = []
    for source in sorted(set(sources)):
        if not source.is_file() or source.is_symlink():
            raise ValueError('Invalid evidence input')
        target = DEST / 'files' / source.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        data = source.read_bytes()
        shutil.copy2(source, target)
        if data != target.read_bytes():
            raise ValueError('Archive copy differs')
        rows.append(dict(path=str(target.relative_to(DEST)), origin=str(source.relative_to(ROOT)),
                         sha256=hashlib.sha256(data).hexdigest(), bytes=len(data)))
    manifest = dict(schemaVersion=1, scope='Offline separate health/RPC deadlines; no candidate deployment',
        accepted=False, runtimeValidated=False, patchCausalityValidated=False,
        actualRuntimeResultChanged=False, redBehavioralFailures=2, newRegressionTests=5,
        XCTestPassed=37, SwiftTestingPassed=41, VMStarts=0, securityWindows=0,
        priorArchivesVerified=prior, files=rows, count=len(rows))
    path = DEST / 'manifest.json'
    path.write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(dict(manifest=str(path), sha256=sha(path), files=len(rows),
                          priorArchives=len(prior), allDigestsVerified=True)))


if __name__ == '__main__':
    main()
