"""Sequential, isolated three-artifact benchmarks; raw observations preserved."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import statistics
import signal
import subprocess
import sys
import time

E = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('trace_analysis', E / 'analyze-trace.py')
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


def require(value, message):
    if not value: raise RuntimeError(message)


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def helper_trace(path, sample):
    raw = path.read_text(); analysis.analyze(raw)
    rows = [json.loads(line) for line in raw.splitlines()]
    require(rows[-1]['pid'] == sample['pid'], 'Trace/sample PID differs')
    events = rows[:-1]; ids = {event['id']: event for event in events}
    root = [event for event in events if event['phase'] == 'kernelDisk.' + sample['operation']]
    require(len(root) == 1, 'Expected one helper span'); root = root[0]
    require(root['outcome'] == 'success' and sample['monotonic_start_ns'] <= root['started_ns']
            and root['started_ns'] + root['elapsed_ns'] <= sample['monotonic_end_ns'], 'Helper outside measured window')
    def descendant(event):
        while event.get('parent_id'):
            if event['parent_id'] == root['id']: return True
            event = ids[event['parent_id']]
        return False
    sha = [event for event in events if event['phase'] == 'generation.fileSHA256' and descendant(event)]
    expected_sha_count = 5 if sample['operation'] == 'capture' else 2
    require(len(sha) == expected_sha_count and all(event['outcome'] == 'success'
            and event['counts']['bytes'] == sample['bytes'] for event in sha), 'SHA count/bytes changed')
    compare = [event for event in events if event['phase'] == 'kernelDisk.' + sample['operation'] + '.compare' and descendant(event)]
    require(len(compare) == 1 and compare[0]['outcome'] == 'success', 'Comparison missing/failed')
    compare = compare[0]; counts = compare['counts']; size = sample['bytes']
    expected_roles = {'live_disk': 2, 'candidate_image': 1, 'original_disk_snapshot': 1, 'candidate_disk_snapshot': 1} if sample['operation'] == 'capture' else {'original_disk_snapshot': 1, 'candidate_disk_snapshot': 1}
    roles = {}
    for event in sha:
        role = event['labels'].get('role'); roles[role] = roles.get(role, 0) + 1
    require(roles == expected_roles, 'SHA object roles differ')
    require(counts['blocks'] == (size + 4095) // 4096 and counts['logical_bytes'] == size
            and counts['old_bytes'] == counts['new_bytes'] == size, 'Comparison omitted bytes/blocks')
    if sample['operation'] == 'validate': require(counts['disk_bytes'] == size, 'Live stream omitted bytes')
    return dict(trace=str(path), trace_sha256=digest(path), helper_span_ns=root['elapsed_ns'],
                compare_ns=compare['elapsed_ns'], compare_counts=counts, compare_labels=compare['labels'],
                sha_calls=expected_sha_count, sha_bytes=sum(event['counts']['bytes'] for event in sha),
                sha_cumulative_inclusive_ns=sum(event['elapsed_ns'] for event in sha),
                sha_callsites=[dict(file=event['caller_file'], line=event['caller_line'],
                                   function=event['caller_function'], elapsed_ns=event['elapsed_ns'],
                                   bytes=event['counts']['bytes'], role=event['labels'].get('role')) for event in sha])


def sample_from_log(path, label, operation, size):
    raw = path.read_text()
    require('[kernel-io-trace] measurement incomplete' not in raw, 'Logger reported incomplete output')
    samples = [analysis.decode(line[len('kernel-io-benchmark '):]) for line in raw.splitlines()
               if line.startswith('kernel-io-benchmark ')]
    require(len(samples) == 2 and samples[0]['event'] == 'measurement-start'
            and samples[1]['event'] == 'measurement-end', 'Expected one start/end sample')
    start, end = samples
    for key in ('monotonic_start_ns', 'monotonic_end_ns', 'elapsed_ns'):
        require(type(end.get(key)) is int and end[key] > 0, 'Invalid monotonic integer')
    seconds = end.get('elapsed_seconds')
    require(type(seconds) in (int, float) and math.isfinite(seconds) and seconds > 0
            and math.isclose(seconds, end['elapsed_ns'] / 1e9, rel_tol=1e-12, abs_tol=1e-12), 'Seconds/nanoseconds differ')
    require(end['label'] == start['label'] == label and end['operation'] == start['operation'] == operation
            and type(end['pid']) is int and end['pid'] == start['pid'] and end['pid'] > 0
            and start['monotonic_ns'] <= end['monotonic_start_ns'] <= end['monotonic_end_ns']
            and end['elapsed_ns'] == end['monotonic_end_ns'] - end['monotonic_start_ns'], 'Sample identity/clock differs')
    expected_offsets = sorted(set([0, (1 << 20) - 4096, 1 << 20, size // 2 // 4096 * 4096, (size - 1) // 4096 * 4096]))
    require(type(end.get('bytes')) is int and type(end.get('observed_size')) is int
            and end['bytes'] == end['observed_size'] == size and end['result'] == 'passed'
            and end['error'] is None and end['offsets_match'] is True
            and end['offsets'] == end['expected_offsets'] == expected_offsets
            and all(type(offset) is int for offset in end['offsets']), 'Helper result differs')
    for key in ('original_sha256', 'candidate_sha256'):
        require(re.fullmatch('[0-9a-f]{64}', end[key]), 'Missing actual input digest')
    return end


def validate_variants(manifest):
    variants = manifest['variants']
    require([variant['name'] for variant in variants] == ['baseline', 'timed4k', 'buffered1m'], 'Expected ordered three variants')
    roots, binaries, tests, flags = set(), set(), set(), set()
    expected = [(False, 4096), (True, 4096), (True, 1048576)]
    for variant, (trace, read_bytes) in zip(variants, expected):
        root, bundle = Path(variant['root']).resolve(), Path(variant['bundle']).resolve()
        require(root.parent == Path('/private/tmp') and root.name.startswith('vphone-kernel-io-')
                and bundle == root / '.build/arm64-apple-macosx/release/vphone-cliPackageTests.xctest', 'Artifact is not an isolated copy')
        require(variant['trace'] is trace and type(variant['read_bytes']) is int and variant['read_bytes'] == read_bytes, 'Variant contract differs')
        binary = bundle / 'Contents/MacOS/vphone-cliPackageTests'
        require(digest(binary) == variant['binary_sha256'], 'Artifact changed')
        source = root / 'tests/FirmwarePatcherTests/FirmwareKernelIOBenchmarkTests.swift'
        require(digest(source) == variant['benchmark_test_sha256'], 'Benchmark source changed')
        require(digest(root / 'Package.swift') == variant['package_sha256']
                and digest(root / 'sources/FirmwarePatcher/Pipeline/FirmwareKernelDisk.swift') == variant['kernel_disk_source_sha256'], 'Build source changed')
        record_path = Path(variant['build_record'])
        require(digest(record_path) == variant['build_record_sha256'], 'Build evidence changed')
        record = json.loads(record_path.read_text()); command = record['command']
        compiled_root = variant['compiled_source_root']
        require(isinstance(command, list) and len(command) == 13
                and isinstance(command[-1], str) and bool(command[-1])
                and command == ['swift', 'test', '--package-path', compiled_root,
                                '--scratch-path', compiled_root + '/.build',
                                '--cache-path', compiled_root + '/.swiftpm-cache',
                                '--disable-automatic-resolution', '-c', 'release',
                                '--filter', command[-1]], 'Unexpected build arguments')
        package = (root / 'Package.swift').read_text()
        require(package.startswith('// swift-tools-version:6.0\n')
                and 'platforms: [.macOS(.v15)]' in package, 'Package language/platform differs')
        require(record['exit_code'] == 0 and record.get('timed_out', False) is False
                and command[:2] == ['swift', 'test'] and command[command.index('--package-path') + 1] == compiled_root
                and command[command.index('-c') + 1] == 'release' and '--disable-automatic-resolution' in command
                and command[command.index('--scratch-path') + 1] == compiled_root + '/.build', 'Build contract differs')
        actual_flags = {'configuration': command[command.index('-c') + 1], 'language': 'swift-tools-version:6.0',
                        'platform': 'macOS15', 'automatic_resolution': False}
        require(variant['build_flags'] == actual_flags, 'Declared flags differ')
        roots.add(str(root)); binaries.add(variant['binary_sha256']); tests.add(variant['benchmark_test_sha256'])
        flags.add(json.dumps(actual_flags, sort_keys=True))
    require(len(roots) == len(binaries) == 3 and len(tests) == len(flags) == 1, 'Three artifacts/test source/build flags are not distinct/equal as required')
    tool = Path(manifest['xctest'])
    require(tool == Path('/Applications/Xcode.app/Contents/Developer/usr/bin/xctest')
            and digest(tool) == manifest['xctest_sha256'], 'XCTest tool differs')
    return variants


def bounded_wrapper(command):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=165)
        return process.returncode, stdout, stderr
    except subprocess.TimeoutExpired:
        # TERM asks the recorded wrapper to clean its independently owned child.
        try: os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        try: stdout, stderr = process.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            stdout, stderr = process.communicate(timeout=5)
        raise RuntimeError('Benchmark wrapper timeout after bounded cleanup: ' + stdout + stderr)
    except BaseException:
        if process.poll() is None:
            try: os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            try: process.communicate(timeout=15)
            except subprocess.TimeoutExpired:
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                process.communicate(timeout=5)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--variants', type=Path, required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--warmups', type=int, default=1)
    parser.add_argument('--bytes', type=int, default=536870915)
    args = parser.parse_args()
    require(re.fullmatch('[a-z0-9]+(?:-[a-z0-9]+)*', args.run_id) and len(args.run_id) <= 40, 'Invalid run label')
    require(3 <= args.rounds <= 6 and args.warmups == 1, 'Use 3–6 rounds plus one warm-up')
    require((1 << 20) < args.bytes <= (1 << 30) and args.bytes % 4096 != 0, 'Invalid input size')
    manifest_raw = args.variants.read_bytes(); manifest = json.loads(manifest_raw)
    variants = validate_variants(manifest); names = [variant['name'] for variant in variants]
    artifact_locks = []
    for variant in variants:
        fd = os.open(variant['root'], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        artifact_locks.append(fd); fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    validate_variants(manifest)
    observation_path = E / (args.run_id + '-observations.jsonl')
    result_path = E / (args.run_id + '-results.json')
    require(not result_path.exists(), 'Result already exists')
    observations, input_digests = [], None
    with observation_path.open('x') as output:
        # Latin rotation puts each variant in each position in the first 3 rounds.
        orders = [(True, 0, variants)] + [(False, index + 1, variants[index % 3:] + variants[:index % 3])
                                         for index in range(args.rounds)]
        for warmup, round_number, order in orders:
            for variant in order:
                for operation in ('capture', 'validate'):
                    label = args.run_id + '-' + ('warm' if warmup else 'r' + str(round_number)) + '-' + variant['name'] + '-' + operation
                    prefix = E / 'traces' / label
                    require(not list(prefix.parent.glob(prefix.name + '.*.jsonl')), 'Trace prefix already exists')
                    binary = Path(variant['bundle']) / 'Contents/MacOS/vphone-cliPackageTests'
                    require(digest(binary) == variant['binary_sha256'], 'Artifact changed before invocation')
                    command = [sys.executable, str(E / 'run-recorded.py'), '--guard-task8', '--timeout', '120']
                    values = dict(VPHONE_KERNEL_IO_BENCHMARK='1', VPHONE_KERNEL_IO_BENCHMARK_OPERATION=operation,
                                  VPHONE_KERNEL_IO_BENCHMARK_LABEL=label, VPHONE_KERNEL_IO_BENCHMARK_BYTES=str(args.bytes),
                                  VPHONE_KERNEL_IO_BENCHMARK_READ_BYTES=str(variant['read_bytes']))
                    if variant['trace']: values['VPHONE_KERNEL_IO_TRACE'] = str(prefix)
                    for key, value in values.items(): command += ['--set', key + '=' + value]
                    target_command = [manifest['xctest'], '-XCTest', 'FirmwarePatcherTests.FirmwareKernelIOBenchmarkTests/test' + operation.title(), variant['bundle']]
                    command += [label, '--'] + target_command
                    code, stdout, stderr = bounded_wrapper(command)
                    require(code == 0, 'Benchmark failed: ' + label + '\n' + stdout + stderr)
                    record = json.loads((E / (label + '.json')).read_text())
                    require(record['exit_code'] == 0 and record['command'] == target_command
                            and record['environment_overrides'] == values and record['acceptance_directory_lock_held'] is True
                            and record['timed_out'] is False and record['interrupted'] is None
                            and record['cleanup_complete'] is True and record['cleanup_error'] is None
                            and record['cleanup_signals_to_owned_child_group'] == [] and record['child_start_new_session'] is True, 'Command evidence differs')
                    sample = sample_from_log(E / (label + '.log'), label, operation, args.bytes)
                    require(record['child_pid'] == sample['pid'] and sample['readsize'] == variant['read_bytes'], 'Direct XCTest child/sample differs')
                    pair = (sample['original_sha256'], sample['candidate_sha256'])
                    if input_digests is None: input_digests = pair
                    require(pair == input_digests, 'Input data differs across variants/rounds')
                    traces = list(prefix.parent.glob(prefix.name + '.*.jsonl'))
                    detail = None
                    if variant['trace']:
                        require(len(traces) == 1 and traces[0].name == prefix.name + '.' + str(sample['pid']) + '.jsonl', 'Trace PID/prefix differs')
                        detail = helper_trace(traces[0], sample)
                        labels = detail['compare_labels']
                        if variant['name'] == 'timed4k': require(labels.get('byte_semantics') == 'comparison_stream_actual', 'Expected FileHandle comparison')
                        else: require(labels.get('scan_batch_bytes') == '1048576' and labels.get('persistent_block_bytes') == '4096'
                                      and labels.get('read_call_semantics') == 'native_pread_attempts_including_EINTR_EOF_errors', 'Expected native pread comparison')
                    else: require(not traces, 'Untimed baseline emitted trace')
                    row = dict(label=label, variant=variant['name'], operation=operation, warmup=warmup,
                               round=round_number, sample=sample, detail=detail)
                    observations.append(row); output.write(json.dumps(row) + '\n'); output.flush()
                    print(json.dumps(dict(label=label, helper_seconds=sample['elapsed_seconds'],
                                          compare_seconds=None if detail is None else detail['compare_ns'] / 1e9)), flush=True)
    summary = []
    for name in names:
        for operation in ('capture', 'validate'):
            rows = [row for row in observations if not row['warmup'] and row['variant'] == name and row['operation'] == operation]
            times = [row['sample']['elapsed_seconds'] for row in rows]
            compares = [row['detail']['compare_ns'] / 1e9 for row in rows if row['detail'] is not None]
            summary.append(dict(variant=name, operation=operation, samples=len(rows),
                                helper_median_seconds=statistics.median(times), helper_min_seconds=min(times), helper_max_seconds=max(times),
                                compare_median_seconds=statistics.median(compares) if compares else None,
                                rss_peak_after_bytes=[row['sample']['rss_peak_after_bytes'] for row in rows]))
    result = dict(passed=True, variants_manifest=str(args.variants), variants_manifest_sha256=hashlib.sha256(manifest_raw).hexdigest(),
                  rounds=args.rounds, bytes=args.bytes, warmups_excluded=True, input_digests=input_digests,
                  cache_policy='warm, no eviction; each process prepares identical materialized files',
                  observations=str(observation_path), summary=summary,
                  limitations=['Scope is synthetic helper calls, not 64 GiB or complete CLI.',
                               'First trace initialization can be inside capture but outside validate preparation.',
                               'FileHandle API attempt counts are not measured baseline kernel syscall counts.',
                               'RSS is process historical peak; independent memory regressions establish bounds.',
                               'System load, frequency and physical I/O are not controlled or attributed.'])
    validate_variants(manifest)
    with result_path.open('x') as output: json.dump(result, output, indent=2); output.write('\n')
    for fd in artifact_locks: os.close(fd)
    print(json.dumps(dict(result=str(result_path), passed=True)), flush=True)


if __name__ == '__main__':
    started = time.monotonic()
    def stop(_signal, _frame): raise InterruptedError('Benchmark controller interrupted')
    signal.signal(signal.SIGTERM, stop)
    try: main()
    except BaseException as error:
        if '--run-id' in sys.argv:
            label = sys.argv[sys.argv.index('--run-id') + 1]
            if re.fullmatch('[a-z0-9]+(?:-[a-z0-9]+)*', label):
                try:
                    with (E / (label + '-failure.json')).open('x') as output:
                        json.dump(dict(passed=False, error_type=type(error).__name__, error=str(error),
                                       elapsed_seconds=time.monotonic() - started), output, indent=2)
                        output.write('\n')
                except FileExistsError: pass
        raise
