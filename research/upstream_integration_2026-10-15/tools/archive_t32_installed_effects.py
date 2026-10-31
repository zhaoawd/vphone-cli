#!/usr/bin/env python3
"""Preserve this read-only batch and prepared runtime plan without old rewrites."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t32-t33-followup-20261023'
DEST=ROOT/'research/upstream_integration_2026-10-15/evidence/T32-T33-followup-20261023'


def main():
    if DEST.exists():raise ValueError('Preserve prior immutable evidence')
    if (WORK/'boot-window/authorization-window.json').exists():raise ValueError('Use a separate archive after approved runtime work')
    inputs=[p for p in WORK.iterdir() if p.is_file()]
    inputs.append(WORK/'boot-window/scoped-amfidont.py')
    names=['TASKS.md','research/0_binary_patch_comparison.md','scripts/cfw_verify_effects.py',
           'scripts/patchers/installed_effects.py','scripts/check_bundle.py',
           'sources/vphone-cli/VPhoneCFWUndoCLI.swift','sources/vphone-cli/VPhoneRestoreCLI.swift',
           'tests/test_installed_guest_effects.py','tests/VPhoneCLITests/CFWUndoCLITests.swift']
    names+=['research/upstream_integration_2026-10-15/'+name for name in
            ['T32_T33_installed_effects_20261023.md','progress.md','tasks.json','local_reconciliation.json']]
    names+=['research/upstream_integration_2026-10-15/tools/'+name for name in
            ['verify_t32_publication_targets.py','prepare_t32_runtime_backup.py','observe_t32_runtime.py',
             'start_t32_observation_window.py','test_t32_runtime_observation.py','archive_t32_installed_effects.py']]
    inputs += [ROOT/name for name in names]
    records=[];DEST.mkdir(parents=True)
    for source in sorted(set(inputs)):
        if source.is_symlink():raise ValueError('Linked evidence input')
        relative=source.relative_to(ROOT);target=DEST/'files'/relative
        target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
        digest=hashlib.sha256(source.read_bytes()).hexdigest()
        if hashlib.sha256(target.read_bytes()).hexdigest()!=digest:raise ValueError('Evidence copy differs')
        records.append(dict(origin=str(relative),path=str(target.relative_to(DEST)),bytes=source.stat().st_size,sha256=digest))
    observed=json.loads((WORK/'actual-audit-final.json').read_text())
    manifest=dict(schemaVersion=1,scope='Current targets, retained postimage and separately prepared runtime plan',
                  accepted=False,currentTargetsMatched=False,DSCInstalledBytesAndCodePagesPassed=True,
                  publicationTargetsMatched=True,VMStarted=False,securityWindowStarted=False,
                  runtimePlanApproval='pending',rawDiskBackupCopiedIntoArchive=False,
                  backupManifest=str((WORK/'runtime-backup.json').relative_to(ROOT)),
                  count=len(records),files=records)
    (DEST/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    for row in records:
        p=DEST/row['path']
        if p.stat().st_size!=row['bytes'] or hashlib.sha256(p.read_bytes()).hexdigest()!=row['sha256']:
            raise ValueError('Archived digest differs')
    print(json.dumps(dict(count=len(records),allDigestsVerified=True,manifest=str(DEST/'manifest.json'))))


if __name__=='__main__':main()
