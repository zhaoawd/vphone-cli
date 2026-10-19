"""Test-only substitutions for the Swift plan verifier and final APFS reader.

The production journal, sparse disk hashing, checkpoint and swap remain active.
The disposable raw image's known marker stands in for one installed guest file.
"""
import hashlib
import json
import os
from pathlib import Path
import sys
import tarfile
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import cfw_guest_evidence as evidence
from patchers import undo_provenance


def plan_for(work):
    context = {'vmDirectory': str(work.parent), 'generationID': 'a' * 64,
               'variant': os.environ.get('VPHONE_CFW_VARIANT', 'regular')}
    record = {'schemaVersion': 1, 'generationID': context['generationID'],
              'planSHA256': hashlib.sha256(context['variant'].encode()).hexdigest(),
              'plan': {'variant': context['variant']}}
    context['planSHA256'] = record['planSHA256']
    raw = evidence.canonical(record)
    return SimpleNamespace(context=context, record=record, raw_sha256=hashlib.sha256(raw).hexdigest(),
                           record_json=raw, context_json=evidence.canonical(context))


def readback(work):
    marker = work / '.fixture-readbacks'
    count = int(marker.read_text()) + 1 if marker.exists() else 1
    marker.write_text(str(count))
    if count == 2 and os.environ.get('FAIL_POST_SNAPSHOT_EFFECT'):
        raise ValueError('post-snapshot effect readback failed')
    plan = plan_for(work)
    record = json.loads((work / 'transaction.json').read_bytes())
    image = work / 'Disk.img'
    target = 'system:/fixture'
    if os.environ.get('TEST_ENV_HARNESS'):
        # Environment-driver tests use a tar-backed System volume instead of
        # the raw marker image. Read its actual loader without altering the tar.
        def loader(path):
            with tarfile.open(path) as archive:
                member = archive.getmember('sbin/launchd')
                if not member.isfile(): raise ValueError('tar fixture loader is not regular')
                with archive.extractfile(member) as stream: return stream.read()
        actual, before = loader(image), loader(work.parent / 'Disk.img')
        target = 'system:/sbin/launchd'
    else:
        with image.open('rb') as stream:
            stream.seek(512); actual = stream.read(11)
        if actual != b'CFW-PATCHED': raise ValueError('fixture guest marker differs')
        before = b'prior-state'
    store = work / evidence.STORE
    store.mkdir(exist_ok=True)
    operation_file = work / evidence.OPERATIONS
    if not operation_file.exists():
        def state(data):
            key = hashlib.sha256(data).hexdigest()
            if not (store / key).exists(): evidence.write_new(store / key, data)
            elif (store / key).read_bytes() != data: raise ValueError('fixture blob differs')
            return dict(kind='file', sha256=key, mode=0o644, uid=os.getuid(), gid=os.getgid())
        proof = dict(schemaVersion=1, operation='change', before=state(before), after=state(actual),
            projection={'kind': 'bytes', 'ranges': [{'offset': 0, 'count': len(actual)}] if before != actual else []})
        row = dict(schemaVersion=1, generationID=plan.context['generationID'], planDigest=plan.record['planSHA256'],
            desiredSHA256=plan.raw_sha256, declarationID='fixture-marker', target=target, path='/fixture', effect=proof)
        evidence.write_new(operation_file, evidence.canonical(row) + b'\n')
    raw = operation_file.read_bytes()
    final = dict(schemaVersion=1, transactionID=record['id'], generationID=plan.context['generationID'],
        planDigest=plan.record['planSHA256'], desiredSHA256=plan.raw_sha256,
        operationsSHA256=hashlib.sha256(raw).hexdigest(), stagedImage=str(image),
        stagedIdentity=evidence.image_identity(image.stat()), outputs=[{'target': target}])
    rows = [json.loads(line) for line in raw.splitlines()]
    final['undoProvenanceSHA256'] = undo_provenance.persist(plan, rows, final['outputs'], work)
    evidence.write_final(work / evidence.FINAL, evidence.canonical(final))
    undo_provenance.seal(work, final)


if __name__ == '__main__': readback(Path(os.environ['VPHONE_GUEST_EVIDENCE']).parent)
