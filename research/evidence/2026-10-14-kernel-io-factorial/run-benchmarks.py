"""Isolated four-variant comparisons with exact helper/counter evidence."""
import argparse
import collections
import fcntl
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import signal
import statistics
import subprocess
import sys

sys.dont_write_bytecode = True
E = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('trace_analysis', E.parent / '2026-10-14-kernel-io-performance/analyze-trace.py')
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


def require(value, message):
    if not value:
        raise RuntimeError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_variants(manifest):
    variants = manifest['variants']
    require([v['name'] for v in variants] == ['baseline', 'second', 'third', 'combined'], 'Variant names differ')
    tests, capture_tests, packages, binaries = set(), set(), set(), set()
    inputs_by_name = {}
    for v, flags in zip(variants, [(False, False), (True, False), (False, True), (True, True)]):
        require((v['second'], v['third']) == flags, 'Variant factors differ')
        root = Path(v['root'])
        require(root.parent == Path('/private/tmp') and root.name.startswith('vphone-kernel-io-factorial-'), 'Not isolated')
        require(digest(Path(v['bundle']) / 'Contents/MacOS/vphone-cliPackageTests') == v['binary_sha256'], 'Binary changed')
        require(digest(root / 'Package.swift') == v['package_sha256'], 'Package changed')
        require(digest(root / 'tests/FirmwarePatcherTests/FirmwareKernelIOFactorialBenchmarkTests.swift')
                == v['benchmark_test_sha256'], 'Publication benchmark changed')
        require(digest(root / 'tests/FirmwarePatcherTests/FirmwareKernelIOBenchmarkTests.swift')
                == v['capture_test_sha256'], 'Capture benchmark changed')
        require(digest(Path(v['source_manifest'])) == v['source_manifest_sha256'], 'Source manifest changed')
        inputs = json.loads(Path(v['source_manifest']).read_text())
        inputs_by_name[v['name']] = inputs
        for folder in ['sources/', 'tests/', 'scripts/']:
            require(all(digest(root / name) == value for name, value in inputs.items() if name.startswith(folder)),
                    'Frozen source changed')
        require(digest(Path(v['build_record'])) == v['build_record_sha256'], 'Build record changed')
        record = json.loads(Path(v['build_record']).read_text())
        require(record['exit_code'] == 0 and record['command'] == [
            'swift', 'test', '--package-path', v['compiled_source_root'], '--scratch-path', v['compiled_source_root'] + '/.build',
            '--cache-path', v['compiled_source_root'] + '/.swiftpm-cache', '--disable-automatic-resolution',
            '--disable-sandbox', '-c', 'release', '--filter', 'FirmwareKernelIOFactorialBenchmarkTests|FirmwareKernelIOBenchmarkTests'], 'Build flags differ')
        tests.add(v['benchmark_test_sha256']); capture_tests.add(v['capture_test_sha256'])
        packages.add(v['package_sha256']); binaries.add(v['binary_sha256'])
    require(len(tests) == len(capture_tests) == len(packages) == 1 and len(binaries) == 4, 'Common inputs/distinct binaries differ')
    allowed = {'sources/FirmwarePatcher/Pipeline/FirmwareKernelDisk.swift',
               'sources/FirmwarePatcher/Pipeline/FirmwareKernelMount.swift',
               'sources/FirmwarePatcher/Pipeline/FirmwareKernelUpdate.swift'}
    baseline = inputs_by_name['baseline']
    require(all(set(inputs) == set(baseline) for inputs in inputs_by_name.values()), 'Source file set differs')
    require(all(value == baseline[name] for inputs in inputs_by_name.values()
                for name, value in inputs.items() if name not in allowed), 'Unrelated source differs')
    for name in allowed:
        if name.endswith('FirmwareKernelDisk.swift'):
            require(baseline[name] == inputs_by_name['second'][name]
                    and inputs_by_name['third'][name] == inputs_by_name['combined'][name]
                    and baseline[name] != inputs_by_name['third'][name], 'Third factor differs')
        else:
            require(baseline[name] == inputs_by_name['third'][name]
                    and inputs_by_name['second'][name] == inputs_by_name['combined'][name]
                    and baseline[name] != inputs_by_name['second'][name], 'Second factor differs')
    require(digest(Path(manifest['xctest'])) == manifest['xctest_sha256'], 'XCTest changed')
    return variants


def bounded_wrapper(command, env):
    process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=240)
        return process.returncode, stdout, stderr
    except BaseException:
        # The wrapper handles TERM by cleaning its separately owned child group.
        if process.poll() is None:
            try: os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            try: process.communicate(timeout=15)
            except subprocess.TimeoutExpired:
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                process.communicate(timeout=5)
        raise


def parse_sample(log, label, operation, size):
    prefix = 'kernel-io-benchmark ' if operation == 'capture' else 'kernel-io-factorial '
    samples = [analysis.decode(line[len(prefix):]) for line in log.splitlines() if line.startswith(prefix)]
    require(len(samples) == 2, 'Expected start/end sample')
    start, sample = samples
    require(start['event'] == 'measurement-start' and sample['event'] == 'measurement-end'
            and start['pid'] == sample['pid'] and sample['pid'] > 0
            and start['label'] == sample['label'] == label and sample['operation'] == operation, 'Sample identity differs')
    require(sample['bytes'] == sample['observed_size'] == size and sample['result'] == 'passed', 'Helper result differs')
    require(type(sample['elapsed_ns']) is int and sample['elapsed_ns'] > 0
            and start['monotonic_ns'] <= sample['monotonic_start_ns'] < sample['monotonic_end_ns']
            and sample['elapsed_ns'] == sample['monotonic_end_ns'] - sample['monotonic_start_ns']
            and math.isclose(sample['elapsed_seconds'], sample['elapsed_ns'] / 1e9, rel_tol=1e-12), 'Sample clock differs')
    for field in ['original_sha256', 'candidate_sha256']:
        require(re.fullmatch('[0-9a-f]{64}', sample[field]) is not None, 'Missing digest')
    if operation == 'capture':
        offsets = sorted(set([0, (1 << 20) - 4096, 1 << 20, size // 2 // 4096 * 4096, (size - 1) // 4096 * 4096]))
        require(sample['offsets_match'] is True and sample['offsets'] == sample['expected_offsets'] == offsets
                and sample['error'] is None, 'Capture offsets differ')
    else:
        require(sample['metadata_count'] == 2 and sample['offsets'] == [0], 'Publication metadata/offsets differ')
    return sample


def trace_details(path, sample, variant):
    raw = path.read_text(); analysis.analyze(raw)
    rows = [analysis.decode(line) for line in raw.splitlines()]
    footer = rows.pop()
    require(footer['pid'] == sample['pid'] and footer['complete'] and footer['dropped'] == 0
            and footer['open_spans'] == 0 and footer['io_error'] is None, 'Trace footer differs')
    require(all(row['outcome'] == 'success' for row in rows), 'Trace contains failure')
    ids = {row['id']: row for row in rows}

    def descendants(root):
        result = []
        for row in rows:
            current = row
            while current.get('parent_id'):
                if current['parent_id'] == root['id']:
                    result.append(row); break
                current = ids[current['parent_id']]
        return result

    phase = 'kernelDisk.capture' if sample['operation'] == 'capture' else 'kernelUpdate.publishQualified'
    roots = [row for row in rows if row['phase'] == phase]
    require(len(roots) == 1, 'Expected one measured helper')
    root = roots[0]
    require(sample['monotonic_start_ns'] <= root['started_ns']
            and root['started_ns'] + root['elapsed_ns'] <= sample['monotonic_end_ns'], 'Helper outside measurement')
    children = descendants(root)
    size = sample['bytes']
    result = dict(trace=str(path), trace_sha256=digest(path), helper_ns=root['elapsed_ns'])

    def capture_details(capture):
        inside = descendants(capture)
        sha = [row for row in inside if row['phase'] == 'generation.fileSHA256']
        compare, = [row for row in inside if row['phase'] == 'kernelDisk.capture.compare']
        c = compare['counts']; fused = variant['third']
        require(len(sha) == (3 if fused else 5) and all(row['counts']['bytes'] == size for row in sha), 'Capture SHA count/bytes differ')
        expected_roles = {'live_disk': 2, 'candidate_image': 1}
        if not fused: expected_roles.update(original_disk_snapshot=1, candidate_disk_snapshot=1)
        require(collections.Counter(row['labels']['role'] for row in sha) == expected_roles, 'Capture SHA roles differ')
        require(c['old_bytes'] == c['new_bytes'] == c['logical_bytes'] == size
                and c['blocks'] == (size + 4095) // 4096, 'Capture byte/block coverage differs')
        calls = (size + (1 << 20) - 1) // (1 << 20) + 1
        require(c['old_read_calls'] == c['new_read_calls'] == calls, 'Capture read attempts differ')
        if fused:
            require(c['old_sha_bytes'] == c['new_sha_bytes'] == size and c['fused_sha_finalizations'] == 2, 'Fused SHA differs')
        syncs = [row for row in inside if row['phase'] == 'kernelDisk.fsync']
        require(len(syncs) == 3, 'Capture sync count differs')
        require(all((row['started_ns'] + row['elapsed_ns'] <= compare['started_ns']) if fused
                    else (compare['started_ns'] + compare['elapsed_ns'] <= row['started_ns']) for row in syncs), 'Capture sync order differs')
        return dict(helper_ns=capture['elapsed_ns'], compare_ns=compare['elapsed_ns'], compare_counts=c,
                    standalone_sha=len(sha), fused_sha=2 if fused else 0,
                    explicit_read_bytes=sum(row['counts']['bytes'] for row in sha) + c['old_bytes'] + c['new_bytes'],
                    standalone_sha_ns=sum(row['elapsed_ns'] for row in sha))

    if sample['operation'] == 'capture':
        result.update(capture_details(root))
        require(result['compare_counts']['changed_blocks'] == len(sample['offsets']), 'Changed blocks differ')
    else:
        origins = [row for row in children if row['phase'] == 'transaction.verifyOrigin']
        require(collections.Counter(row['labels']['point'] for row in origins) == {'candidate': 2, 'published': 6}, 'Origin calls differ')
        ordered = sorted(origins, key=lambda row: row['started_ns'])
        require(all(a['started_ns'] + a['elapsed_ns'] <= b['started_ns'] for a, b in zip(ordered, ordered[1:])), 'Origin spans overlap')
        observations = []
        for origin in origins:
            image_sha = [row for row in descendants(origin) if row['phase'] == 'generation.fileSHA256'
                         and row['labels'].get('role') in ('live_disk', 'candidate_image')]
            point = origin['labels']['point']; expected = (2 if variant['second'] else 3) + (2 if point == 'published' else 0)
            require(len(image_sha) == expected and all(row['counts']['bytes'] == size for row in image_sha), 'Origin SHA count/bytes differ')
            observations.append(dict(point=point, elapsed_ns=origin['elapsed_ns'], image_sha_calls=len(image_sha),
                                     image_sha_ns=sum(row['elapsed_ns'] for row in image_sha)))
        result['origins'] = observations
        result['published_ns'] = sum(row['elapsed_ns'] for row in observations if row['point'] == 'published')
        result['candidate_ns'] = sum(row['elapsed_ns'] for row in observations if row['point'] == 'candidate')
        capture, = [row for row in children if row['phase'] == 'kernelDisk.capture']
        result['capture'] = capture_details(capture)
        require(result['capture']['compare_counts']['changed_blocks'] == 1, 'Publication capture blocks differ')
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--smoke', action='store_true')
    args = parser.parse_args()
    manifest = json.loads((E / 'variants.json').read_text()); variants = validate_variants(manifest)
    size = (2 if args.smoke else 512) * 1024 * 1024 + 3
    run_id = 'smoke' if args.smoke else 'balanced-512m'
    locks = []
    for v in variants:
        fd = os.open(v['root'], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); locks.append(fd)
    (E / 'traces').mkdir(exist_ok=True)
    sequence = [(True, 0, [0, 1, 2, 3])] if args.smoke else [
        (True, 0, [0, 1, 2, 3]), (False, 1, [0, 1, 3, 2]),
        (False, 2, [1, 2, 0, 3]), (False, 3, [2, 3, 1, 0]), (False, 4, [3, 0, 2, 1])]
    observations = []; input_pairs = {}
    with (E / (run_id + '-observations.jsonl')).open('x') as output:
        for warmup, round_number, order in sequence:
            for index in order:
                v = variants[index]
                for operation in ['capture', 'publication']:
                    label = run_id + '-' + ('warm' if warmup else 'r' + str(round_number)) + '-' + v['name'] + '-' + operation
                    prefix = E / 'traces' / label
                    require(not list(prefix.parent.glob(prefix.name + '.*.jsonl')), 'Trace prefix exists')
                    require(digest(Path(v['bundle']) / 'Contents/MacOS/vphone-cliPackageTests') == v['binary_sha256'], 'Binary changed before run')
                    overrides = dict(VPHONE_KERNEL_IO_TRACE=str(prefix), VPHONE_KERNEL_IO_BENCHMARK_BYTES=str(size),
                                     VPHONE_KERNEL_IO_BENCHMARK_LABEL=label)
                    if operation == 'capture':
                        overrides.update(VPHONE_KERNEL_IO_BENCHMARK='1', VPHONE_KERNEL_IO_BENCHMARK_OPERATION='capture',
                                         VPHONE_KERNEL_IO_BENCHMARK_READ_BYTES=str(1 << 20))
                        selected = 'FirmwarePatcherTests.FirmwareKernelIOBenchmarkTests/testCapture'
                    else:
                        overrides['VPHONE_KERNEL_IO_FACTORIAL'] = '1'
                        selected = 'FirmwarePatcherTests.FirmwareKernelIOFactorialBenchmarkTests/testPublication'
                    target = [manifest['xctest'], '-XCTest', selected, v['bundle']]
                    command = [sys.executable, str(E / 'run-recorded.py'), '--guard-task8', '--timeout', '180']
                    for key, value in overrides.items(): command += ['--set', key + '=' + value]
                    command += [label, '--'] + target
                    env = {key: value for key, value in os.environ.items()
                           if not key.startswith(('VPHONE_TEST_', 'VPHONE_LESS_', 'VPHONE_C4_', 'VPHONE_KERNEL_', 'VPHONE_MOUNT_', 'VPHONE_DSC_'))}
                    code, stdout, stderr = bounded_wrapper(command, env)
                    require(code == 0, 'Recorded invocation failed: ' + label + '\n' + stdout + stderr)
                    record = json.loads((E / (label + '.json')).read_text())
                    require(record['command'] == target and record['environment_overrides'] == overrides
                            and record['exit_code'] == 0 and not record['timed_out'] and record['interrupted'] is None
                            and record['cleanup_complete'] and record['cleanup_error'] is None
                            and record['cleanup_signals_to_owned_child_group'] == []
                            and record['acceptance_directory_lock_held'] and record['child_start_new_session'], 'Recorded contract differs')
                    sample = parse_sample((E / (label + '.log')).read_text(), label, operation, size)
                    require(sample['pid'] == record['child_pid'], 'Child PID differs')
                    pair = (sample['original_sha256'], sample['candidate_sha256'])
                    require(pair == input_pairs.setdefault(operation, pair), 'Input/output differ across runs')
                    paths = list(prefix.parent.glob(prefix.name + '.*.jsonl'))
                    require(len(paths) == 1 and paths[0].name == prefix.name + '.' + str(sample['pid']) + '.jsonl', 'Trace PID/prefix differs')
                    detail = trace_details(paths[0], sample, v)
                    row = dict(label=label, variant=v['name'], operation=operation, warmup=warmup,
                               round=round_number, sample=sample, detail=detail, host_load=os.getloadavg())
                    observations.append(row); output.write(json.dumps(row) + '\n'); output.flush()
                    print(json.dumps(dict(label=label, helper_seconds=sample['elapsed_seconds'],
                        published_seconds=detail.get('published_ns', 0) / 1e9)), flush=True)
    validate_variants(manifest)
    summaries = []
    for v in variants:
        for operation in ['capture', 'publication']:
            rows = [row for row in observations if row['variant'] == v['name'] and row['operation'] == operation and not row['warmup']]
            if not rows: continue
            metrics = {'helper_seconds': [row['sample']['elapsed_seconds'] for row in rows]}
            if operation == 'publication':
                metrics.update(published_seconds=[row['detail']['published_ns'] / 1e9 for row in rows],
                               candidate_seconds=[row['detail']['candidate_ns'] / 1e9 for row in rows])
            summaries.append(dict(variant=v['name'], operation=operation, samples=len(rows),
                metrics={key: dict(median=statistics.median(values), minimum=min(values), maximum=max(values), values=values)
                         for key, values in metrics.items()}))
    (E / (run_id + '-results.json')).write_text(json.dumps(dict(
        scope='Synthetic helper comparisons only; not VM acceptance or full-update speedup',
        bytes=size, calls=len(observations), warmups=sum(row['warmup'] for row in observations),
        rounds=0 if args.smoke else 4, summaries=summaries), indent=2) + '\n')
    for fd in locks: os.close(fd)


if __name__ == '__main__':
    main()
