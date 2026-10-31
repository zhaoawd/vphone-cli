#!/usr/bin/env python3
"""Preserve completed preparation evidence independently of pending native work."""
import json
from pathlib import Path
import shutil
import sys

ROOT=Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT/'scripts'))
import cfw_guest_evidence as evidence
WORK=ROOT/'.build/t32-t33-completion-20261023'
DEST=ROOT/'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023/prepared'


def main():
    if DEST.exists():raise ValueError('Preserve prior evidence batch')
    paths=[p for p in WORK.iterdir() if p.is_file() and p.suffix in ('.log','.json')
           and not p.name.startswith(('offline-root','offline-auth'))]
    paths+=[WORK/'file-original-source/source.json']
    sources=['TASKS.md','research/0_binary_patch_comparison.md',
        'research/upstream_integration_2026-10-15/T32_T33_completion_20261023.md',
        'research/upstream_integration_2026-10-15/progress.md',
        'research/upstream_integration_2026-10-15/tasks.json','research/upstream_integration_2026-10-15/local_reconciliation.json',
        'sources/vphone-cli/VPhoneCFWUndoCLI.swift','scripts/cfw_disk_txn.py','scripts/cfw_guest_evidence.py',
        'scripts/cfw_install_host.sh','scripts/cfw_verify_effects.py','scripts/lib/cfw_common.sh','scripts/check_bundle.py']
    paths.extend(ROOT/name for name in sources)
    paths.extend((ROOT/'scripts/patchers').glob('*.py'))
    paths.extend(ROOT/'tests'/name for name in ('test_guest_component_receipts.py','test_guest_file_originals.py',
        'test_guest_file_undo.py','test_guest_file_prepare.py','test_guest_file_transaction.py'))
    paths.extend(Path(__file__).parent/name for name in ('prepare_t32_file_original_source.py','inspect_t32_file_originals.py',
        'build_t32_completion_candidate.py','prepare_t32_completion_backup.py','prepare_t32_file_acceptance_plan.py',
        'execute_t32_file_acceptance.py','test_t32_file_acceptance.py','archive_t32_completion_prepared.py'))
    records=[]
    for source in sorted(set(paths)):
        digest=evidence.digest(source);relative=source.relative_to(ROOT);target=DEST/'files'/relative
        target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
        if evidence.digest(target)!=digest:raise ValueError('Archive copy differs')
        records.append(dict(origin=str(relative),path=str(target.relative_to(DEST)),sha256=digest,bytes=target.stat().st_size))
    manifest=dict(schemaVersion=1,scope='T32/T33 receipts and file Undo implementation, original comparison, regression and approved offline preparation',
        accepted=False,runtimeValidated=False,guestOriginQualified=False,
        offlineAcceptance='approved and execution started; actual phase results are a separate batch',
        excludes=['full VM disk backups','candidate archive bytes','decoded source images'],count=len(records),files=records)
    evidence.write_new(DEST/'manifest.json',json.dumps(manifest,indent=2).encode()+b'\n')
    for row in records:
        if evidence.digest(DEST/row['path'])!=row['sha256']:raise ValueError('Final evidence verification differs')
    print(json.dumps(dict(manifest=str(DEST/'manifest.json'),files=len(records),allDigestsVerified=True)))


if __name__=='__main__':main()
