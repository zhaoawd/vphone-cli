"""Re-read raw invocation/trace files and recompute the reported statistics."""
import collections
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics
import sys

sys.dont_write_bytecode = True
E = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('controller', E / 'run-benchmarks.py')
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)


def main():
    manifest = json.loads((E / 'variants.json').read_text())
    variants = {v['name']: v for v in controller.validate_variants(manifest)}
    raw_rows = [json.loads(line) for line in (E / 'balanced-512m-observations.jsonl').read_text().splitlines()]
    result = json.loads((E / 'balanced-512m-results.json').read_text())
    assert result['calls'] == len(raw_rows) == 40 and result['warmups'] == 8 and result['rounds'] == 4
    sequences = {0: ['baseline', 'second', 'third', 'combined'],
                 1: ['baseline', 'second', 'combined', 'third'],
                 2: ['second', 'third', 'baseline', 'combined'],
                 3: ['third', 'combined', 'second', 'baseline'],
                 4: ['combined', 'baseline', 'third', 'second']}
    expected = [(number == 0, number, name, operation) for number, names in sequences.items()
                for name in names for operation in ['capture', 'publication']]
    assert [(row['warmup'], row['round'], row['variant'], row['operation']) for row in raw_rows] == expected
    pairs = collections.defaultdict(set)
    for row in raw_rows:
        record = json.loads((E / (row['label'] + '.json')).read_text())
        assert record['exit_code'] == 0 and record['cleanup_complete'] and record['cleanup_error'] is None
        assert not record['timed_out'] and record['interrupted'] is None
        assert record['cleanup_signals_to_owned_child_group'] == [] and record['acceptance_directory_lock_held']
        sample = controller.parse_sample((E / (row['label'] + '.log')).read_text(), row['label'], row['operation'], result['bytes'])
        assert sample == row['sample'] and sample['pid'] == record['child_pid']
        detail = controller.trace_details(Path(row['detail']['trace']), sample, variants[row['variant']])
        assert detail == row['detail']
        pairs[row['operation']].add((sample['original_sha256'], sample['candidate_sha256']))
    assert all(len(values) == 1 for values in pairs.values())
    for summary in result['summaries']:
        selected = [row for row in raw_rows if not row['warmup'] and row['variant'] == summary['variant']
                    and row['operation'] == summary['operation']]
        assert len(selected) == summary['samples'] == 4
        for metric, recorded in summary['metrics'].items():
            if metric == 'helper_seconds': values = [row['sample']['elapsed_seconds'] for row in selected]
            else: values = [row['detail'][metric.replace('_seconds', '_ns')] / 1e9 for row in selected]
            assert recorded == dict(median=statistics.median(values), minimum=min(values), maximum=max(values), values=values)
    summaries = {(s['variant'], s['operation']): s for s in result['summaries']}
    comparisons = {}
    for name, operation, metric, optimized in [
        ('second_published', 'publication', 'published_seconds', 'second'),
        ('second_candidate', 'publication', 'candidate_seconds', 'second'),
        ('third_capture', 'capture', 'helper_seconds', 'third'),
        ('combined_publication', 'publication', 'helper_seconds', 'combined')]:
        baseline = summaries['baseline', operation]['metrics'][metric]['median']
        value = summaries[optimized, operation]['metrics'][metric]['median']
        comparisons[name] = dict(baseline_seconds=baseline, optimized_seconds=value,
                                 reduction_seconds=baseline - value, reduction_percent=100 * (baseline - value) / baseline)
    output = dict(passed=True, calls=40, measured=32, excluded_warmups=8,
                  summaries_recomputed=True, raw_logs_and_traces_rechecked=True, comparisons=comparisons,
                  observations_sha256=hashlib.sha256((E / 'balanced-512m-observations.jsonl').read_bytes()).hexdigest())
    (E / 'audit-results.json').write_text(json.dumps(output, indent=2) + '\n')
    print(json.dumps(output, indent=2))


if __name__ == '__main__':
    main()
