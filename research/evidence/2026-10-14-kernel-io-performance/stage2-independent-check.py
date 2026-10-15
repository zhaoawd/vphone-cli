"""Read frozen sources and saved logs/traces only; never execute a helper."""
from collections import Counter
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import re

E = Path(__file__).resolve().parent
O = Path('/private/tmp/vphone-kernel-io-optimization-20261014')
T = Path('/private/tmp/vphone-kernel-io-timed-20261014')
R = E.parents[2]
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
report = {'reviewed_at': datetime.now(timezone.utc).isoformat(), 'passed': False,
          'scope': 'Read-only frozen sources and saved evidence; no build, benchmark, VM, Store, AMFI or guest request.'}
m = json.loads((O / 'kernel-io-stage2/manifest.json').read_text())
report['frozen_files'] = {}
for path, expected in m['files'].items():
    actual = digest(O / path)
    assert actual == expected, path
    report['frozen_files'][path] = actual
report['manifest_sha256'] = digest(O / 'kernel-io-stage2/manifest.json')
assert digest(E / 'stage2-artifact-manifest.json') == report['manifest_sha256']
for name in ['implementation.md', 'stage2.patch', 'frontend-parse.log']:
    assert digest(E / ('stage2-artifact-' + name)) == digest(O / 'kernel-io-stage2' / name)
source_path = Path('sources/FirmwarePatcher/Pipeline/FirmwareKernelDisk.swift')
source = (O / source_path).read_text()
old = (T / source_path).read_text()
marker = '    /// A short pwrite changes a contiguous prefix; unknown torn sectors refuse.'
assert source.split(marker, 1)[1].split('\n/// Only owns bounded read buffers.', 1)[0] == old.split(marker, 1)[1]
report['protected_tail_byte_identical'] = True
positions = [source.index('FirmwareKernelDiskBatchReader.read(' + name + ', offset: size, count: 1')
             for name in ['old', 'new', 'disk']]
assert positions == sorted(positions)
report['validate_eof_order'] = ['original', 'candidate', 'live']
v9 = json.loads((R / 'research/evidence/2026-10-13-task8/acceptance/kernel-rollback/manifest.json').read_text())
assert len(v9['sourceFiles']) == 16
for entry in v9['sourceFiles']:
    assert digest(R / entry['path']) == entry['sha256'], entry['path']
report['shared_v9_source16_unchanged'] = True

run = json.loads((E / 'stage2-green-regressions-02.json').read_text())
log = (E / 'stage2-green-regressions-02.log').read_text()
assert run['exit_code'] == 0 and not run['timed_out'] and run['interrupted'] is None
passed = [s for s in re.findall(r'^✔ Test (.+) passed after ', log, re.M) if not s.startswith('run with ')]
skipped = re.findall(r'^➜ Test (.+) skipped\.$', log, re.M)
assert len(passed) == 18
assert skipped == ['actualPublicForceExcGuardPlansProduceDifferentPayloads()', 'actualCandidateRegionUsesSourceFlow()']
for count in [7, 10, 9]:
    assert f'Executed {count} tests, with 0 failures' in log
assert 'Executed 28 tests, with 1 test skipped and 0 failures' in log
assert "testArchiveGrowthAtPartialTailIsRejected]' passed" in log
memory = []
for match in re.findall(r'kernel-disk-memory operation=(\w+) bytes=(\d+) rss_before=(\d+) rss_after=(\d+) growth=(\d+)', log):
    row = dict(zip(['operation', 'bytes', 'rss_before', 'rss_after', 'growth'], match))
    for key in ['bytes', 'rss_before', 'rss_after', 'growth']:
        row[key] = int(row[key])
    assert row['growth'] == row['rss_after'] - row['rss_before']
    assert row['growth'] < (16 if row['operation'] in ['publish', 'reverse'] else 64) * 1024 * 1024
    memory.append(row)
assert [r['operation'] for r in memory] == ['capture', 'validate', 'publish', 'reverse']
assert (E / 'stage2-tail-growth-red-02.log').read_text().count('XCTAssertThrowsError failed: did not throw an error') == 2
assert 'ModuleCache: Operation not permitted' in (E / 'stage2-green-regressions-01.log').read_text()
report['regressions'] = {'wrapper_elapsed_seconds': run['elapsed_seconds'],
    'xctest_parent_selected': 28, 'xctest_parent_passed': 27, 'xctest_parent_skipped': 1,
    'reader_passed': 10, 'equivalence_passed': 7, 'recorder_passed': 9,
    'memory_parent_passed': 1, 'memory_child_passed': 4,
    'swift_testing_selected': 20, 'swift_testing_passed': 18, 'swift_testing_skipped': skipped,
    'swift_testing_passed_names': passed, 'memory_children': memory,
    'memory_metric': 'Darwin ru_maxrss after-minus-before in isolated children; not exact live allocation or complete CLI memory.'}

spec = importlib.util.spec_from_file_location('trace_analysis', E / 'analyze-trace.py')
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)
report['smoke'] = {}
for operation in ['capture', 'validate']:
    label = 'stage2-smoke-' + operation
    run = json.loads((E / (label + '.json')).read_text())
    log = Path(run['log']).read_text()
    assert run['exit_code'] == 0 and not run['timed_out'] and run['interrupted'] is None
    assert run['cleanup_complete'] is True and run['cleanup_error'] is None
    assert '[kernel-io-trace]' not in log
    prefix = Path(run['environment_overrides']['VPHONE_KERNEL_IO_TRACE'])
    assert prefix == E / 'traces' / label
    files = list(prefix.parent.glob(prefix.name + '.*.jsonl'))
    assert len(files) == 1
    trace = files[0]
    raw = trace.read_text()
    checked = analysis.analyze(raw)
    rows = [analysis.decode(line) for line in raw.splitlines() if line.strip()]
    footer, events = rows[-1], rows[:-1]
    pid = int(trace.name.removeprefix(label + '.').removesuffix('.jsonl'))
    assert pid == run['child_pid'] == footer['pid'] == checked['pid']
    assert all(event['pid'] == pid for event in events)
    samples = [json.loads(line.removeprefix('kernel-io-benchmark ')) for line in log.splitlines()
               if line.startswith('kernel-io-benchmark ')]
    assert len(samples) == 2
    start, finish = samples
    assert start['event'] == 'measurement-start' and finish['event'] == 'measurement-end'
    assert start['pid'] == finish['pid'] == pid and start['label'] == finish['label'] == label
    assert start['operation'] == finish['operation'] == operation
    assert finish['result'] == 'passed' and finish['offsets_match'] is True
    assert finish['bytes'] == finish['observed_size'] == 1048579
    assert finish['offsets'] == finish['expected_offsets'] == [0, 524288, 1044480, 1048576]
    helper, = [event for event in events if event['phase'] == 'kernelDisk.' + operation]
    assert finish['monotonic_start_ns'] <= helper['started_ns']
    assert helper['started_ns'] + helper['elapsed_ns'] <= finish['monotonic_end_ns']
    assert finish['monotonic_end_ns'] - finish['monotonic_start_ns'] == finish['elapsed_ns']
    ids = {event['id']: event for event in events}
    def within(event):
        parent = event.get('parent_id')
        while parent is not None:
            if parent == helper['id']:
                return True
            parent = ids[parent].get('parent_id')
        return False
    children = [event for event in events if within(event)]
    compare, = [event for event in children if event['phase'] == 'kernelDisk.' + operation + '.compare']
    expected = {'blocks': 257, 'logical_bytes': 1048579, 'old_bytes': 1048579,
                'new_bytes': 1048579, 'old_read_calls': 3, 'new_read_calls': 3}
    if operation == 'capture':
        expected['changed_blocks'] = 4
    else:
        expected.update(disk_bytes=1048579, disk_read_calls=3)
    assert compare['counts'] == expected
    assert compare['labels'] == {'byte_semantics': 'native_pread_positive_return_bytes',
        'read_call_semantics': 'native_pread_attempts_including_EINTR_EOF_errors',
        'scan_batch_bytes': '1048576', 'persistent_block_bytes': '4096'}
    hashes = [event for event in children if event['phase'] == 'generation.fileSHA256']
    roles = Counter(event['labels']['role'] for event in hashes)
    assert roles == ({'live_disk': 2, 'candidate_image': 1, 'original_disk_snapshot': 1,
                      'candidate_disk_snapshot': 1} if operation == 'capture'
                     else {'original_disk_snapshot': 1, 'candidate_disk_snapshot': 1})
    assert all(event['counts']['bytes'] == 1048579 for event in hashes)
    fsyncs = [event for event in children if event['phase'] == 'kernelDisk.fsync']
    assert len(fsyncs) == (3 if operation == 'capture' else 0)
    outside = [event for event in events if event['phase'] == 'generation.fileSHA256' and not within(event)]
    assert len(outside) == (0 if operation == 'capture' else 2)
    rootcheck = json.loads((E / (label + '-check.json')).read_text())
    assert rootcheck['passed'] and rootcheck['detail']['trace_sha256'] == digest(trace)
    assert rootcheck['detail']['compare_counts'] == expected
    report['smoke'][operation] = {'pid': pid, 'trace_sha256': digest(trace), 'complete': True,
        'logger_error_absent': True, 'filename_footer_events_child_stdout_pid_match': True,
        'helper_contained_in_stdout_monotonic_window': True, 'compare_counts': expected,
        'helper_sha_calls': len(hashes), 'helper_sha_bytes': len(hashes) * 1048579,
        'sha_role_counts': dict(roles), 'setup_sha_outside_helper': len(outside),
        'fsyncs': len(fsyncs), 'external_helper_ns': finish['elapsed_ns'],
        'helper_span_ns': helper['elapsed_ns'], 'compare_ns': compare['elapsed_ns']}

variants = json.loads((E / 'benchmark-variants.json').read_text())
report['variant_artifact_checks'] = []
assert [v['name'] for v in variants['variants']] == ['baseline', 'timed4k', 'buffered1m']
for v in variants['variants']:
    root = Path(v['root'])
    binary = Path(v['bundle']) / 'Contents/MacOS/vphone-cliPackageTests'
    assert digest(binary) == v['binary_sha256']
    assert digest(root / 'tests/FirmwarePatcherTests/FirmwareKernelIOBenchmarkTests.swift') == v['benchmark_test_sha256']
    assert digest(root / 'Package.swift') == v['package_sha256']
    assert digest(root / source_path) == v['kernel_disk_source_sha256']
    assert digest(Path(v['build_record'])) == v['build_record_sha256']
    assert json.loads(Path(v['build_record']).read_text())['exit_code'] == 0
    report['variant_artifact_checks'].append({'name': v['name'], 'binary_sha256': v['binary_sha256']})
assert len({v['binary_sha256'] for v in variants['variants']}) == 3
assert len({v['benchmark_test_sha256'] for v in variants['variants']}) == 1
assert all(v['build_flags'] == variants['variants'][0]['build_flags'] for v in variants['variants'])
assert digest(Path(variants['xctest'])) == variants['xctest_sha256']
report['evidence_sha256'] = {p.name: digest(p) for p in E.iterdir()
    if p.is_file() and (p.name.startswith('stage2-') or p.name == 'benchmark-variants.json')
    and p.suffix in ['.log', '.json'] and p.name != 'stage2-independent-review.json'}
report['passed'] = True
with (E / 'stage2-independent-review.json').open('x') as output:
    json.dump(report, output, indent=2)
    output.write('\n')
print(json.dumps({'passed': True, 'source_files': len(report['frozen_files']),
                  'swift_testing_actual_passed': len(passed), 'smoke': report['smoke']}, indent=2))
