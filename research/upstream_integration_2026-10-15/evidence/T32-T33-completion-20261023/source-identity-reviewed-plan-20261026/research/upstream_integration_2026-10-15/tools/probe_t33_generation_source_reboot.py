"""Readonly source-observation replay; normalization is diagnostic and in memory.

No registration, transaction record, clone, seal, publication or VM is created.
The installed 73b verifier is unchanged. This is not operational acceptance.
"""
import fcntl
import json
import os
from pathlib import Path
import sys
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / '.build/t32-t33-completion-20261023'
VM = ROOT / '.build/t33t-20261025'
OUT = BASE / 'generation-source-reboot-probe-20261026'
SCRIPTS = Path('/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.73b536cbb70c/VPhone.bundle/Contents/Resources/scripts')
sys.path.insert(0, str(SCRIPTS))
import cfw_disk_txn as txn
import cfw_guest_evidence as evidence
import vm_lock
from patchers import guest_undo, undo_provenance as undo, file_originals


def main():
    if os.geteuid() != 0: raise ValueError('Private generation sources require readonly administrator access')
    OUT.mkdir()
    fd = os.open(VM, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    previous = os.environ.get(vm_lock.FD_ENV)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); os.environ[vm_lock.FD_ENV] = str(fd)
        vm_lock.check_inherited(VM)
        pending = list(VM.glob('.cfw_disk.*'))
        if pending != [VM / '.cfw_disk.reboot20261026'] or list(pending[0].iterdir()):
            raise ValueError('Expected only the retained empty failed work directory')
        txn.require_unheld(VM / 'Disk.img', os.getpid(), 'readonly failed-source diagnosis')
        first = VM / '.cfw-history/20261025T132920Z-adMN63qO'
        source = VM / '.cfw-recovery-sources/20261025T144138Z-W7aZSh3x'
        protected = {str(p): evidence.digest(p) for p in (Path(__file__), SCRIPTS / 'patchers/undo_provenance.py',
            SCRIPTS / 'patchers/file_originals.py', first / 'transaction.json', first / evidence.CHECKPOINT,
            source / 'transaction.json', VM / '.cfw-reboot-identity.json', VM / 'launchpad.json')}
        parent = txn.committed_guest_evidence(VM)
        if parent is None or parent[1]['id'] != first.name:
            raise ValueError('Preserved first-on parent did not qualify')
        if parent[2].get('currentImageSHA256', parent[2]['imageSHA256']) != '104c89afb70841172e6eb8bd0991c4d1b7b72fde763731af4c8258b5ba301358':
            raise ValueError('Current complete image differs from preserved first-on')
        plan = guest_undo.saved_plan(first, parent[2]['generationID'])
        catalog = json.loads(evidence.read(first / file_originals.FILENAME))
        expected = {row['source']: row['generationSource'] for row in catalog['sources']}
        observations = []
        for name, recorded in expected.items():
            actual = undo.qualify_source(plan, name)
            outer = {k: v for k, v in actual.items() if k != 'source'}
            old_outer = {k: v for k, v in recorded.items() if k != 'source'}
            changed = [k for k in actual['source'] if actual['source'][k] != recorded['source'][k]]
            observations.append(dict(path=name, recorded=recorded, actual=actual,
                changedSourceFields=changed, manifestAndTreeUnchanged=outer == old_outer))
        (OUT / 'source-observations.json').write_text(json.dumps(observations, indent=2) + '\n')
        print(json.dumps(dict(step='actual-generation-source-readbacks', observations=observations)), flush=True)
        if not observations or any(row['changedSourceFields'] != ['device'] or not row['manifestAndTreeUnchanged']
                                   for row in observations):
            raise ValueError('Source difference is not exclusively the observed device-number change')
        declarations = ['system-systemversion-cfw-build_version']
        try: guest_undo.preview(VM, plan.context['generationID'], declarations, _committed=parent)
        except ValueError as error:
            if str(error) != 'Undo source no longer matches original observation': raise
            original_error = str(error)
        else: raise ValueError('Original source rejection did not reproduce')
        qualify = undo.qualify_source
        def diagnostic_qualify(live_plan, path):
            actual = qualify(live_plan, path); recorded = expected[str(path)]
            normalized = dict(actual, source=dict(actual['source'], device=recorded['source']['device']))
            if normalized != recorded: raise ValueError('Diagnostic source has another unqualified difference')
            return normalized
        with patch.object(undo, 'qualify_source', side_effect=diagnostic_qualify):
            preview = guest_undo.preview(VM, plan.context['generationID'], declarations, _committed=parent)
        if {row['target'] for row in preview['entries']} != {
            'system:/System/Library/CoreServices/SystemVersion.plist',
            'system:/System/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist'}:
            raise ValueError('Diagnostic preview has a different target selection')
        for name, digest in protected.items():
            if evidence.digest(Path(name)) != digest: raise ValueError('Protected source or historical evidence changed')
        result = dict(passed=True, originalFailureReproduced=original_error,
            changedFields=['generationSource.source.device'], actualSourceFiles=len(observations),
            completeManifestTreesAndSourceHashesVerified=True, modeledCompleteUndoPreviewPassed=True,
            modeledOriginalIndexRebuildByteIdentical=True, preview=preview,
            installedVerifierUnmodified=True, historicalRecordsUnmodified=True,
            newRegistrationInstalled=False, transactionWrites=0, VMStarts=0, accepted=False,
            limitation='in-memory diagnostic normalization only; no source requalification authority or operational recovery acceptance')
        (OUT / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result), flush=True)
    finally:
        if previous is None: os.environ.pop(vm_lock.FD_ENV, None)
        else: os.environ[vm_lock.FD_ENV] = previous
        os.close(fd)


if __name__ == '__main__':
    try: main()
    except Exception as error:
        if OUT.exists(): (OUT / 'stopped.json').write_text(json.dumps(dict(error=str(error), transactionWrites=0, VMStarts=0), indent=2) + '\n')
        raise
