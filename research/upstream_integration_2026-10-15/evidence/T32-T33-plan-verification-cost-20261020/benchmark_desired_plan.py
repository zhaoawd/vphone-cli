"""Compare two real CLI verifiers on a locked, isolated 64MiB CFW fixture.

Create the fixture with CFWFrozenPlanTests.prepareIsolatedPlanCostFixture, then
run through scripts/vm_lock.py VM fw-receipts -- PYTHON THIS_SCRIPT ... .
The benchmark checks identical outputs, complete traces and unchanged files.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
import cfw_disk_txn


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            value.update(block)
    return value.hexdigest()


def snapshot(vm):
    return {str(p.relative_to(vm)): digest(p) for p in sorted(vm.rglob('*')) if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vm', type=Path, required=True)
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--after', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    vm = args.vm.resolve(strict=True)
    assert vm.is_relative_to(ROOT / '.build') and 0 < (vm / 'Disk.img').stat().st_size <= 64 << 20, 'isolated small fixture required'
    postimages = list((vm / '.cfw-history').glob('*/guest-postimage.img'))
    assert sum(p.stat().st_size == 64 << 20 for p in postimages) == 2, 'two 64MiB publication images required'
    cfw_disk_txn.require_lock(vm)
    out = args.out.resolve()
    out.mkdir(exist_ok=False)
    original = snapshot(vm)
    expected = digest(vm / '.firmware-desired-plan.json')
    binaries = {'before': args.before.resolve(strict=True), 'after': args.after.resolve(strict=True)}
    binary_hashes = {key: digest(value) for key, value in binaries.items()}
    trials = []
    stdout = None
    for index in range(4):
        for label in (['before', 'after'] if index % 2 == 0 else ['after', 'before']):
            prefix = out / (label + '-' + str(index))
            env = dict(os.environ, VPHONE_KERNEL_IO_TRACE=str(prefix))
            command = [str(binaries[label]), 'cfw', 'verify-plan', str(vm), '--expected-sha256', expected]
            start = time.monotonic()
            result = subprocess.run(command, env=env, capture_output=True, timeout=120)
            elapsed = time.monotonic() - start
            assert result.returncode == 0, result.stderr.decode(errors='replace')
            if stdout is None:
                stdout = result.stdout
                (out / 'verified-export.json').write_bytes(stdout)
            assert result.stdout == stdout, 'before/after verified exports differ'
            traces = list(out.glob(prefix.name + '.*.jsonl'))
            assert len(traces) == 1, 'missing or ambiguous trace'
            events = [json.loads(line) for line in traces[0].read_text().splitlines()]
            footer = events[-1]
            assert footer.get('complete') is True and footer.get('dropped') == 0 and footer.get('open_spans') == 0
            spans = [row for row in events if row.get('type') == 'span']
            assert footer.get('type') == 'measurement_end' and footer['events'] == len(spans)
            loads = sum(row.get('phase') == 'generation.loadVerified' for row in spans)
            assert loads == (2 if label == 'before' else 1), 'unexpected generation verification count'
            trials.append(dict(label=label, warmup=index == 0, elapsedSeconds=elapsed, generationLoads=loads,
                               hashedFileBytes=sum(row.get('counts', {}).get('bytes', 0) for row in spans if row.get('phase') == 'generation.fileSHA256')))
    assert snapshot(vm) == original, 'fixture bytes changed during measurement'
    assert {key: digest(value) for key, value in binaries.items()} == binary_hashes, 'verifier changed during measurement'
    medians = {label: statistics.median(row['elapsedSeconds'] for row in trials if row['label'] == label and not row['warmup']) for label in binaries}
    record = dict(state='passed', scope='isolated fixture with two 64MiB CFW postimages and a synthetic Undo image; not real VM installation elapsed time',
                  cliSHA256=binary_hashes, trials=trials, medianSeconds=medians,
                  speedup=medians['before'] / medians['after'], identicalVerifiedExports=True, unchangedFixture=True)
    (out / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
