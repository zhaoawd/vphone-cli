"""Assert complete generation-verification counts using the existing I/O trace.

Run the measuredReadRevalidatesOriginalsForEveryRequest Swift test with a new
absolute VPHONE_KERNEL_IO_TRACE prefix, then pass that prefix here. Counts are
limited to the measured Store.read calls, excluding fixture preparation.
"""
import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('prefix', type=Path)
    parser.add_argument('--generation-loads', type=int, default=1)
    args = parser.parse_args()
    reads = []
    for path in sorted(args.prefix.parent.glob(args.prefix.name + '.*.jsonl')):
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        roots = [row for row in rows if row.get('phase') == 'regression.desired-plan.read']
        if not roots:
            continue
        footer = rows[-1]
        assert footer.get('type') == 'measurement_end' and footer.get('complete') is True, 'incomplete trace'
        assert footer.get('dropped') == 0 and footer.get('open_spans') == 0 and footer.get('io_error') is None
        events = [row for row in rows if row.get('type') == 'span']
        assert footer['events'] == len(events), 'trace event count differs'
        for root in roots:
            descendants = {root['id']}
            while True:
                selected = {row['id'] for row in events if row.get('parent_id') in descendants}
                if selected <= descendants:
                    break
                descendants |= selected
            children = [row for row in events if row['id'] in descendants]
            loads = [row for row in children if row['phase'] == 'generation.loadVerified']
            reads.append(dict(trace=path.name, generationLoads=len(loads),
                              elapsedNS=root['elapsed_ns'],
                              verifiedOriginals=sum(row['phase'] == 'generation.verifyOriginals' for row in children)))
    print(json.dumps(dict(reads=reads, expectedGenerationLoads=args.generation_loads), indent=2))
    assert len(reads) == 2, 'expected two independent measured reads'
    assert all(row['generationLoads'] == args.generation_loads for row in reads), 'repeated or missing complete generation verification'
    assert all(row['verifiedOriginals'] == args.generation_loads for row in reads), 'missing complete original verification'


if __name__ == '__main__':
    main()
