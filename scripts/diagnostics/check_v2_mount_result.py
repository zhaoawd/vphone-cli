#!/usr/bin/env python3
"""Assert saved results of the approved regular-v2 MAC mount comparison."""
import argparse
import json
from pathlib import Path


def read(path):
    return json.loads(Path(path).read_text())


def records(report, kernel):
    return [r for c in report['components'] for r in c['records']
            if (c['component'] == 'kernelcache') == kernel]


def libraries(value):
    return {r['name']: r for r in value['files']['libraries']}


def mappings(value):
    assert value['load']['source'] == 'environment.loaded'
    assert value['load']['complete'] is True
    return {r['name']: r for r in value['load']['libraries']}


def check(phase, current, previous):
    name = 'libvcamcaptured.dylib'
    if phase == 'firmware':
        vm = Path(current)
        assert vm.name == 'lp-v2-mount-accept-20261002'
        checkpoint = read(vm / '.create-checkpoint/checkpoint.json')
        options = checkpoint['effective_options']
        assert options['variant'] == 'regular' and options['guest_environment'] == 'v2'
        assert options['experimental_v2_root_remount'] is True
        stages = {r['stage']: r for r in checkpoint['stages']}
        assert all(stages[s]['status'] == 'succeeded' for s in
                   ('prepare', 'patch', 'restore', 'cfw', 'first_boot', 'verification'))
        archive = stages['patch']['evidence']['firmware_transaction_archives']
        assert ',' not in archive and '/' not in archive
        report = read(vm / '.firmware-history' / archive / 'report.json')
        baseline = read(previous)
        assert report['variant'] == 'regular' and report['gates']['experimentalV2RootRemount'] is True
        original, candidate = records(baseline, True), records(report, True)
        assert len(original) == 28 and candidate[:28] == original
        assert [r['patchID'] for r in candidate[28:]] == [
            'kernelcache_jb.mac_mount.flag_gate', 'kernelcache_jb.mac_mount.state_clear']
        assert records(report, False) == records(baseline, False)
    elif phase == 'offline':
        value = read(current)
        assert value['classification'] == 'already_current'
        assert value['bootstrap']['kind'] == 'v2'
        assert value['bootstrap']['v2_alias_present'] is True
        assert value['bootstrap']['launchd_custom_loads'] == ['/vh']
        assert value['disk']['unchanged'] is True
    elif phase == 'updated':
        value, before = read(current), read(previous)
        assert value['ok'] is True and value['outcome'] == 'updated'
        rows = libraries(value)
        assert [n for n, r in rows.items() if r['result'] == 'replaced'] == [name]
        assert all(r['verified'] is True for r in rows.values())
        assert value['activation']['executed'] == []
        old = set(mappings(before)[name]['current_pids'])
        assert old and old.issubset({r['pid'] for r in mappings(value)[name]['stale']})
    elif phase == 'restarted':
        value, before = read(current), read(previous)
        assert value['ok'] is True
        current_pids = set(mappings(value)[name]['current_pids'])
        old = set(mappings(before)[name]['current_pids'])
        assert current_pids and current_pids.isdisjoint(old)
        assert mappings(value)[name]['stale'] == []
    elif phase == 'rollback':
        value, before = read(current), read(previous)
        assert value['ok'] is True and value['outcome'] == 'restored'
        assert value['restored'] == [name]
        assert {n: r['guest'] for n, r in libraries(value).items()} == {
            n: r['guest'] for n, r in libraries(before).items()}
    else:
        raise ValueError(phase)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['firmware', 'offline', 'updated', 'restarted', 'rollback'])
    parser.add_argument('current')
    parser.add_argument('previous', nargs='?')
    args = parser.parse_args()
    check(args.phase, args.current, args.previous)
    print(f'{args.phase}: assertions passed')


if __name__ == '__main__':
    main()
