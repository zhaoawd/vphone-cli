"""Validate complete opt-in traces and summarize inclusive measurements.

No business input is opened. Counts are emitted as recorded, never inferred from
file sizes. Inclusive phases overlap and must not be summed as wall time.
"""
import argparse
from collections import defaultdict
import json
from pathlib import Path


def require(value, message):
    if not value:
        raise ValueError(message)


def decode(line):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate JSON key: ' + key)
            result[key] = value
        return result
    def invalid(value):
        raise ValueError('non-finite JSON: ' + value)
    return json.loads(line, object_pairs_hook=pairs, parse_constant=invalid)


def analyze(raw):
    records = [decode(line) for line in raw.splitlines() if line.strip()]
    require(records and records[-1].get('type') == 'measurement_end', 'missing terminal footer')
    footer, spans = records[-1], records[:-1]
    require(type(footer.get('schema_version')) is int and footer['schema_version'] == 1
            and type(footer.get('pid')) is int and footer['pid'] > 0, 'invalid footer protocol/process')
    require(footer.get('complete') is True and type(footer.get('dropped')) is int and footer['dropped'] == 0
            and type(footer.get('open_spans')) is int and footer['open_spans'] == 0
            and footer.get('io_error') is None, 'incomplete measurement')
    require(type(footer.get('events')) is int and footer['events'] == len(spans), 'event count differs')
    ids = {}
    for event in spans:
        require(event.get('type') == 'span' and type(event.get('schema_version')) is int and event['schema_version'] == 1
                and type(event.get('pid')) is int and event['pid'] == footer['pid'], 'wrong event protocol/process')
        token = event.get('id')
        require(type(token) in (int, str) and token not in ids, 'duplicate/invalid span ID')
        ids[token] = event
        require(type(event.get('thread_id')) is int and event['thread_id'] > 0, 'invalid thread ID')
        require(event.get('parent_id') is None or type(event['parent_id']) in (int, str), 'invalid parent ID')
        require(type(event.get('caller_line')) is int and event['caller_line'] > 0
                and all(isinstance(event.get(key), str) and event[key] for key in ('caller_file', 'caller_function')),
                'missing callsite')
        for key in ('started_ns', 'elapsed_ns'):
            require(type(event.get(key)) is int and event[key] >= 0, 'invalid monotonic interval')
        require(event.get('inclusive') is True and event.get('outcome') in ('success', 'error')
                and isinstance(event.get('phase'), str), 'invalid span outcome/phase')
        require(isinstance(event.get('counts'), dict) and isinstance(event.get('labels'), dict), 'missing counts/labels')
        for value in event['counts'].values():
            require(type(value) is int and value >= 0, 'counts must be nonnegative integers')
    for event in spans:
        parent_id = event.get('parent_id')
        if parent_id is None:
            continue
        require(parent_id in ids, 'missing parent')
        parent = ids[parent_id]
        require(parent_id != event['id'] and parent.get('thread_id') == event.get('thread_id')
                and parent['started_ns'] <= event['started_ns']
                and event['started_ns'] + event['elapsed_ns'] <= parent['started_ns'] + parent['elapsed_ns'],
                'invalid parent interval/thread')
        seen = {event['id']}
        while parent_id is not None:
            require(parent_id not in seen, 'parent cycle')
            seen.add(parent_id)
            parent_id = ids[parent_id].get('parent_id')
            require(parent_id is None or parent_id in ids, 'missing ancestor')
    groups = {}
    for event in spans:
        key = (event['phase'], event.get('caller_file'), event.get('caller_line'),
               event.get('caller_function'), event['labels'].get('role'), event['labels'].get('byte_semantics'))
        if key not in groups:
            groups[key] = dict(phase=key[0], caller_file=key[1], caller_line=key[2], caller_function=key[3],
                               role=key[4], byte_semantics=key[5], calls=0, success=0, error=0,
                               cumulative_inclusive_ns=0, counts=defaultdict(int), intervals_by_thread=defaultdict(list))
        group = groups[key]
        group['calls'] += 1
        group[event['outcome']] += 1
        group['cumulative_inclusive_ns'] += event['elapsed_ns']
        group['intervals_by_thread'][event['thread_id']].append((event['started_ns'], event['started_ns'] + event['elapsed_ns']))
        for name, value in event['counts'].items():
            group['counts'][name] += value
    for group in groups.values():
        unions, overlap = {}, False
        for thread, intervals in group.pop('intervals_by_thread').items():
            total, end = 0, None
            for start, stop in sorted(intervals):
                if end is None or start >= end:
                    total += stop - start
                else:
                    overlap = True
                    total += max(0, stop - end)
                end = max(end if end is not None else stop, stop)
            unions[str(thread)] = total
        group['overlapping_spans_same_thread'] = overlap
        group['interval_union_ns_by_thread'] = unions
    return dict(passed=True, pid=footer['pid'], events=len(spans),
                limitations=['Inclusive measurements overlap; do not sum across phases.',
                             'Consumer and child stream bytes may describe the same reads.',
                             'Logical bytes are returned user-space bytes, not physical disk I/O.',
                             'Aggregate child counters are summaries, not additional independent work.'],
                roots=[event['id'] for event in spans if event.get('parent_id') is None],
                groups=sorted(groups.values(), key=lambda group: (group['phase'], str(group['caller_file']),
                                                                  str(group['caller_line']), str(group['role']))))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = analyze(args.trace.read_text())
    result['trace'] = str(args.trace.resolve())
    text = json.dumps(result, indent=2) + '\n'
    if args.output:
        with args.output.open('x') as output:
            output.write(text)
    else:
        print(text, end='')


if __name__ == '__main__':
    main()
