#!/usr/bin/env python3
"""Archive source-only progress without changing historical acceptance results."""
import json
from pathlib import Path
import shutil
import sys

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'scripts'))
import cfw_guest_evidence as evidence
WORK=ROOT/'.build/t32-t33-completion-20261023'
BASE=ROOT/'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023'
DEST=BASE/'producer-implementation-20261024'


def main():
    if DEST.exists():raise ValueError('Preserve prior archive')
    prior={}
    for manifest in sorted(BASE.glob('*/manifest.json')):
        folder=manifest.parent;value=json.loads(evidence.read(manifest));rows=value['files']
        if isinstance(rows,dict):rows=[dict(path=name,**row) for name,row in rows.items()]
        for row in rows:
            path=folder/row['path'];path.resolve(strict=True).relative_to(folder.resolve(strict=True))
            if path.is_symlink() or path.stat().st_size!=row['bytes'] or evidence.digest(path)!=row['sha256']:
                raise ValueError('Historical archive differs: '+str(path))
        prior[folder.name]=dict(files=len(rows),manifestSHA256=evidence.digest(manifest))
    plan_path=WORK/'producer-acceptance-20261024/offline-plan.json'
    plan=json.loads(evidence.read(plan_path))
    for name,digest in plan['frozenInputs'].items():
        if evidence.digest(Path(name))!=digest:raise ValueError('Prepared input differs: '+name)
    log=(WORK/'producer-full-python-r3.log').read_text()
    if 'Ran 1084 tests' not in log or 'OK (skipped=4)' not in log or '\nFAILED ' in log:
        raise ValueError('Final full Python run is not passing')
    summary=dict(schemaVersion=1,accepted=False,realVMValidated=False,additionalVMStarts=0,additionalSecurityWindows=0,
        python=dict(count=1084,skipped=4,seconds=312.420,exitCode=0),priorArchives=prior,
        candidate=plan['candidate']['version'],candidateArchiveSHA256=plan['candidate']['archiveSHA256'],
        offlinePlanSHA256=evidence.digest(plan_path),planApproved=False,preparedInputsVerified=len(plan['frozenInputs']),
        capacity=dict(requiredInitialGiB=75,observedGiB=44.25),
        scope='Source implementation, isolated tests, signed candidate and unapproved offline plan only',
        remaining=['capacity','new scope approval','real qualified source and strict reapplication','real EXP Preboot Undo','GUI and AA.gl'])
    paths=[plan_path,WORK/'candidate-producer-package-final-20261024.json',WORK/'signature-artifact-cms-existing.json']
    for pattern in ('signature-reuse*.log','guest-origin*.log','guest-source*.log','attestation-size*.log',
                    'combined-acceptance*.log','producer*.log'):
        paths.extend(WORK.glob(pattern))
    relatives=['TASKS.md','research/0_binary_patch_comparison.md',
        'sources/VPhoneCore/VPhoneResources.swift','sources/VPhoneCore/VPhoneProcessRunner.swift',
        'sources/VPhoneBundleStore/VPhoneCoreBundleStore.swift','sources/vphone-cli/VPhoneCFWTrustedProducer.swift',
        'sources/vphone-cli/VPhoneCFWRecoverOriginCLI.swift','sources/vphone-cli/VPhoneRestoreCLI.swift',
        'sources/vphone-cli/VPhoneCFWUndoCLI.swift','sources/vphone-cli/VPhoneAppDelegate.swift',
        'sources/VPhoneAPIKit/VPhoneAPIClient.swift','scripts/cfw_disk_txn.py','scripts/cfw_guest_evidence.py',
        'scripts/cfw_install_host.sh','scripts/check_bundle.py','scripts/patchers/guest_origin.py',
        'scripts/patchers/signature_reuse.py','scripts/patchers/guest_write.py','scripts/patchers/guest_undo.py',
        'scripts/patchers/component_signatures.py','scripts/patchers/guest_receipts.py',
        'tests/test_guest_signature_reuse.py','tests/test_guest_origin_publication.py','tests/test_guest_file_transaction.py',
        'tests/test_guest_file_undo.py','tests/test_cfw_host_isolation.py','tests/test_cfw_guest_undo_driver.py',
        'tests/test_cfw_guest_publication.py','tests/test_patch_plan_gate.py','tests/cfw_fixture_capacity.py',
        'tests/VPhoneCLITests/CFWTrustedProducerTests.swift','tests/VPhoneCLITests/CFWFrozenPlanTests.swift',
        'tests/VPhoneCoreTests/ResourcesTests.swift','tests/VPhoneBundleStoreTests/CoreBundleStoreTests.swift',
        'tests/VPhoneAPIKitTests/APIRPCTimeoutTests.swift']
    paths.extend(ROOT/name for name in relatives)
    reports=ROOT/'research/upstream_integration_2026-10-15'
    paths.extend(reports/name for name in ('tasks.json','local_reconciliation.json','local_reconciliation.md',
                                         'progress.md','T32_T33_completion_20261023.md'))
    paths.extend(Path(__file__).parent/name for name in ('build_t32_producer_candidate.py',
        'prepare_t32_producer_acceptance.py','archive_t32_producer_implementation.py'))
    rows=[]
    for source in sorted(set(paths)):
        sha=evidence.digest(source);target=DEST/'files'/source.relative_to(ROOT)
        target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
        if evidence.digest(target)!=sha or evidence.digest(source)!=sha:raise ValueError('Archive copy differs')
        rows.append(dict(path=str(target.relative_to(DEST)),origin=str(source.relative_to(ROOT)),
                         bytes=target.stat().st_size,sha256=sha))
    evidence.write_new(DEST/'summary.json',json.dumps(summary,indent=2).encode()+b'\n')
    rows.append(dict(path='summary.json',bytes=(DEST/'summary.json').stat().st_size,sha256=evidence.digest(DEST/'summary.json')))
    evidence.write_new(DEST/'manifest.json',json.dumps(dict(schemaVersion=1,accepted=False,
        additionalVMStarts=0,additionalSecurityWindows=0,files=rows),indent=2).encode()+b'\n')
    for row in rows:
        if evidence.digest(DEST/row['path'])!=row['sha256']:raise ValueError('Final archive readback differs')
    print(json.dumps(dict(manifest=str(DEST/'manifest.json'),sha256=evidence.digest(DEST/'manifest.json'),
                         files=len(rows),priorArchivesVerified=len(prior),preparedInputsVerified=len(plan['frozenInputs']))))


if __name__=='__main__':main()
