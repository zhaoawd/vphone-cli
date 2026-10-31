"""Preserve and read back the new one-shot preparation, without executing it."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / '.build/t32-t33-completion-20261023'
WORK = BASE / 'exp-plist-lifetime-acceptance-20261025'
OUT = ROOT / 'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023/plist-lifetime-preparation-20261025'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    if OUT.exists():
        raise ValueError('Preserve the prior evidence archive')
    plan_sha = digest(WORK / 'offline-plan.json')
    if plan_sha != '4376d79c942fe26e04a8014d1de6d88c8bc5a49e61c58b49127cfa98e0d14dd7':
        raise ValueError('Unexpected prepared plan')
    plan = json.loads((WORK / 'offline-plan.json').read_bytes())
    executor = json.loads((WORK / 'executor-inputs.json').read_bytes())
    for name in ('native-launch.claim','native-execution.claim','execution','approval.json'):
        if (WORK / name).exists():
            raise ValueError('Archive the unapproved preparation before native execution')
    paths = {ROOT / 'scripts/cfw_install_exp.sh', ROOT / 'tests/test_exp_plist_staging_lifetime.py',
             ROOT / 'research/upstream_integration_2026-10-15/T32_T33_plist_lifetime_execution_review_20261025.md',
             BASE / 'candidate-exp-plist-lifetime-20261025.json',
             WORK / 'offline-plan.json', WORK / 'executor-inputs.json',
             ROOT / '.build/t33t-20261025/.cfw-history/20261025T114952Z-zhZ5OOCf/guest-changes.jsonl',
             BASE / 'exp-bootstrap-acceptance-20261025/finalization.json'}
    paths |= {p for p in BASE.glob('exp-plist-lifetime-*.log')}
    paths |= {BASE / (name + '-20261025.' + suffix) for name in (
        'transport-input-replay','transport-continuity-scan','transport-chronology-analysis','recorded-effect-chains')
        for suffix in ('json','log') if (BASE / (name + '-20261025.' + suffix)).is_file()}
    paths |= {Path(__file__).with_name(name) for name in (
        'build_t33_plist_lifetime_candidate.py','prepare_t33_plist_lifetime_acceptance.py',
        'execute_t33_plist_lifetime_acceptance.py','launch_t33_plist_lifetime_acceptance.py',
        'finalize_t33_plist_lifetime_acceptance.py','test_t33_plist_lifetime_acceptance.py',
        'watch_t33_plist_lifetime_acceptance.py','wait_t33_plist_lifetime_consumer_preparation.py',
        'prepare_t33_consumer_runtime.py','test_t33_consumer_preparation.py',
        'probe_t33_transport_input.py','analyze_t33_transport_chronology.py',
        'verify_t33_recorded_effect_chains.py','archive_t33_plist_lifetime_preparation.py')}
    OUT.mkdir()
    for path in sorted(paths):
        expected = digest(path)
        target = OUT / 'files' / path.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        if digest(target) != expected or digest(path) != expected:
            raise ValueError('Evidence copy differs: ' + str(path))
    summary = dict(state='prepared-not-approved', candidate=plan['candidate']['version'],
        planSHA256=plan_sha, frozenInputs=len(plan['frozenInputs']), executionInputs=len(executor['files']),
        priorPlanConsumed=True, sourceDiskFullReadbackMatches=True, retainedFailedTransactions=4,
        historicalRows=33482, modeledFinalTargets=24292, recordedByteSignatureChains=119,
        modelIsDiskReadback=False, pythonTests=1139, pythonSkipped=4, combinedGateTests=26,
        accepted=False, runtimeValidated=False, VMStarts=0, securityWindows=0)
    (OUT / 'preparation.json').write_text(json.dumps(summary, indent=2) + '\n')
    rows = [dict(path=str(p.relative_to(OUT)), bytes=p.stat().st_size, sha256=digest(p))
            for p in sorted(OUT.rglob('*')) if p.is_file()]
    (OUT / 'manifest.json').write_text(json.dumps(dict(schemaVersion=1, files=rows,
        accepted=False, runtimeValidated=False), indent=2) + '\n')
    for row in rows:
        if digest(OUT / row['path']) != row['sha256']:
            raise ValueError('Archive readback differs')
    print(json.dumps(dict(files=len(rows), manifestSHA256=digest(OUT / 'manifest.json'), **summary)))


if __name__ == '__main__':
    main()
