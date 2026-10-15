"""Read saved synthetic traces only; never invoke a business command."""
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import re

E = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('analysis', E / 'analyze-trace.py')
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)
root_check = json.loads((E / 'stage1-production-probe-check.json').read_text())
report = {'passed': False, 'traces': {}, 'smoke': {}, 'production': {}, 'scope': 'saved synthetic production helpers only'}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def load(label):
    run = json.loads((E / (label + '.json')).read_text())
    assert run['exit_code'] == 0
    log = Path(run['log']).read_text()
    assert '[kernel-io-trace]' not in log, 'Logger failure invalidates measurement'
    prefix = Path(run['environment_overrides']['VPHONE_KERNEL_IO_TRACE'])
    assert prefix.parent == E / 'traces' and prefix.name == label
    files = sorted(prefix.parent.glob(prefix.name + '.*.jsonl'))
    assert files
    result = []
    for path in files:
        before = digest(path)
        raw = path.read_text()
        parsed = analysis.analyze(raw)
        rows = [analysis.decode(line) for line in raw.splitlines() if line.strip()]
        footer, events = rows[-1], rows[:-1]
        pid = int(path.name.removeprefix(label + '.').removesuffix('.jsonl'))
        assert parsed['pid'] == footer['pid'] == pid
        assert all(event['pid'] == pid for event in events)
        assert digest(path) == before
        report['traces'][path.name] = {'sha256': before, 'pid': pid, 'events': len(events), 'complete': True,
                                     'prefix_matches_run': True, 'logger_error_absent': True,
                                     'parent_intervals_verified': True}
        result.append((path, events))
    return log, result

for operation in ('capture', 'validate'):
    label = 'stage1-smoke-' + operation
    log, traces = load(label)
    assert len(traces) == 1
    path, events = traces[0]
    logger = [json.loads(line.removeprefix('kernel-io-benchmark ')) for line in log.splitlines()
              if line.startswith('kernel-io-benchmark ')]
    assert len(logger) == 2
    start, finish = logger
    assert start['event'] == 'measurement-start' and finish['event'] == 'measurement-end'
    assert start['label'] == finish['label'] == label
    assert start['operation'] == finish['operation'] == operation
    assert start['pid'] == finish['pid'] == report['traces'][path.name]['pid']
    assert finish['result'] == 'passed' and finish['offsets_match'] is True
    helpers = [event for event in events if event['phase'] == 'kernelDisk.' + operation]
    assert len(helpers) == 1
    helper = helpers[0]
    assert finish['monotonic_start_ns'] <= helper['started_ns']
    assert helper['started_ns'] + helper['elapsed_ns'] <= finish['monotonic_end_ns']
    ids = {event['id']: event for event in events}
    def within(event):
        token = event.get('parent_id')
        while token is not None:
            if token == helper['id']: return True
            token = ids[token].get('parent_id')
        return False
    children = [event for event in events if within(event)]
    hashes = [event for event in children if event['phase'] == 'generation.fileSHA256']
    comparisons = [event for event in children if event['phase'] == 'kernelDisk.' + operation + '.compare']
    assert len(comparisons) == 1
    expected = root_check['checks'][operation]
    assert len(hashes) == expected['sha_calls_within_helper']
    assert sum(event['counts']['bytes'] for event in hashes) == expected['sha_bytes_within_helper']
    assert comparisons[0]['counts'] == expected['comparison']
    assert finish['bytes'] == 1048579
    assert comparisons[0]['counts']['logical_bytes'] == 1048579
    assert helper['elapsed_ns'] == expected['full_helper_ns']
    assert comparisons[0]['elapsed_ns'] == expected['comparison_ns']
    fsyncs = [event for event in children if event['phase'] == 'kernelDisk.fsync']
    assert len(fsyncs) == (3 if operation == 'capture' else 0)
    outside_hashes = [event for event in events if event['phase'] == 'generation.fileSHA256' and not within(event)]
    assert len(outside_hashes) == (0 if operation == 'capture' else 2)
    report['smoke'][operation] = {'bytes': finish['bytes'], 'sha_calls_within_helper': len(hashes),
        'sha_bytes_within_helper': sum(event['counts']['bytes'] for event in hashes),
        'setup_hashes_outside_helper': len(outside_hashes), 'comparison': comparisons[0]['counts'],
        'fsyncs_within_helper': len(fsyncs), 'logger_helper_ns': finish['elapsed_ns'],
        'root_span_ns': helper['elapsed_ns'], 'same_pid_and_monotonic_window': True}

log, traces = load('stage1-production-probes')
assert len(traces) == 2
phases = Counter(event['phase'] for _, events in traces for event in events)
assert dict(phases) == root_check['checks']['production_probe']['phase_event_counts']
partial = [(path, event) for path, events in traces for event in events
           if event['phase'] == 'generation.readFile' and event['outcome'] == 'error'
           and 'testPartialConsumerFailure' in event['caller_function']]
assert len(partial) == 1
path, event = partial[0]
assert event['counts']['bytes'] == 1048576 and event['counts']['read_calls'] == 1
assert 'testPartialConsumerFailurePreservesErrorAndActualReadBytes' in log and 'passed' in log
report['production'] = {'events': sum(phases.values()), 'phase_event_counts': dict(phases),
                        'partial_error_pid': report['traces'][path.name]['pid'],
                        'partial_error_bytes': event['counts']['bytes'],
                        'partial_error_read_calls': event['counts']['read_calls'],
                        'external_child_pid_not_in_runner_record': True}
report['passed'] = True
out = E / 'stage1-independent-production-probe-check.json'
with out.open('x') as output:
    json.dump(report, output, indent=2); output.write('\n')
print(json.dumps({'passed': True, 'smoke': report['smoke'], 'production_events': report['production']['events'],
                  'traces': report['traces']}, indent=2))
