#!/usr/bin/env python3
"""Reproduce the first-pass disposition of the fixed October 20 Git range.

Uses only the standard library and existing local Git objects. No checkout,
fetch, implementation changes, VM operations, or root TODO.md content reads.
Disposition means routing for subsequent review, not semantic equivalence.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

BASE = '8a75092013eda87a4e30ed029b72028cb9279ac4'
TARGET = '2a0d3aca9fb79344d939365cc337b915ae9f2f97'

# Every non-merge commit has an explicit review group. Merge commits inherit
# the groups of commits reachable from each non-first parent but not parent 1.
GROUPS = {
    'tvos': ('T64', 'optional_scope_decision',
             'c1791809ed 2de95ba348 8137c121e5 af9a4e67da cc80a21644 055dcaa95a '
             '32dc319c08 14d0beeb1c 599ceb48d9 bb9b629a96 6b221e5684'),
    'gpu_index': ('T10/T17/T32', 'semantic_port_review_required', '9b1684af66 7f05de3878'),
    'icli': ('T08', 'dependency_adaptation_required', '821e4ab009'),
    'external_volume': ('T15/T52', 'local_alternative_requires_contract_review', 'd3a959dedb'),
    'settle': ('T49/T50', 'explicit_template_scope_required', '1ec349bb34'),
    'release_metadata': ('T28/T29', 'retain_local_versions_and_provenance',
                         'da92f2fa1a d062ea723e 560d8a1506'),
    'x1': ('T65', 'optional_scope_decision', 'd8fd479969'),
    'seal_selection': ('T09/T10/T65', 'metadata_and_selection_review_required',
                       'b1d32372c3 7a361e4727'),
    'host_video': ('T62', 'protocol_and_lifecycle_adaptation_required', 'cd624be5f2'),
    'pointer': ('T23', 'guest_host_group_adaptation_required',
                '427df2632a ea753f496e fa0eb5032c 289f816dfe'),
    'open_rom': ('T61', 'explicit_rom_scope_required',
                 '286574aff3 d9f2f1edbc 1fa74acce3 b537d3fc2f f9da24d45d '
                 '52bbf8059c 91a1a62620'),
    'xcode': ('T08/T29/T65', 'conditional_toolchain_review_required', '4b440aa293'),
    'amfid_adoption': ('T24', 'different_local_mechanism_review_required', 'd6b138dea3'),
    'guest_files': ('T63', 'bounded_transfer_and_security_adaptation_required', 'ca25861300'),
}


def git(repo, *args):
    return subprocess.check_output(
        ['git', '--no-pager', '-C', str(repo), '--no-replace-objects', *args])


def resolve(repo, revision):
    return git(repo, 'rev-parse', '--verify', revision + '^{commit}').decode().strip()


def build(repo, audit):
    summary = json.loads((audit / 'audit.json').read_text())
    assert summary['status'] == 'completed'
    assert (summary['base'], summary['target']) == (BASE, TARGET)
    assert git(repo, 'merge-base', BASE, TARGET).decode().strip() == BASE
    commits = json.loads((audit / 'git_commits.json').read_text())
    actual = set(git(repo, 'rev-list', BASE + '..' + TARGET).decode().split())
    assert {c['sha'] for c in commits} == actual
    assert len(commits) == len(actual) == summary['total_commits']
    assignments = {}
    for group, (tasks, disposition, prefixes) in GROUPS.items():
        for prefix in prefixes.split():
            sha = resolve(repo, prefix)
            assert sha in actual and sha not in assignments, prefix
            assignments[sha] = dict(group=group, tasks=tasks.split('/'), disposition=disposition)
    assert set(assignments) == {c['sha'] for c in commits if not c['is_merge']}
    records = []
    for c in commits:
        files = sorted({f['path'] for parent in c['files_by_parent'].values()
                        for f in parent if f['path'] != 'TODO.md'})
        row = dict(sha=c['sha'], subject=c['subject'], parents=c['parents'],
                   changed_paths=files, semantic_equivalence_verified=False,
                   implementation_applied=False)
        if c['is_merge']:
            introduced = set()
            for parent in c['parents'][1:]:
                introduced.update(git(repo, 'rev-list', parent, '^' + c['parents'][0])
                                  .decode().split())
            groups = sorted({assignments[s]['group'] for s in introduced if s in assignments})
            row.update(disposition='merge_parent_diffs_archived_semantic_review_pending',
                       groups=groups, introduced_range_commits=sorted(introduced & actual),
                       remerge_exit_code=c['remerge_review']['exit_code'],
                       remerge_bytes=(audit / 'merge_review' / (c['sha'] + '.remerge.diff')).stat().st_size)
            for index in range(1, len(c['parents']) + 1):
                assert (audit / 'merge_review' / (c['sha'] + '.parent' + str(index) + '.diff')).is_file()
        else:
            row.update(assignments[c['sha']])
        records.append(row)
    locks = {}
    lock_paths = git(repo, 'ls-tree', '-r', '--name-only', TARGET).decode().splitlines()
    for path in lock_paths:
        if path.endswith('Package.resolved'):
            data = git(repo, 'show', TARGET + ':' + path)
            obj = json.loads(data)
            pins = obj.get('pins', obj.get('object', {}).get('pins', []))
            locks[path] = dict(sha256=hashlib.sha256(data).hexdigest(),
                               pins={p.get('identity', p.get('package')): p['state'] for p in pins})
    roms = {}
    for name, pin, expected_size, expected_digest in [
        ('OpenAVB', '65a776e9ae00b2e1de22b18cbbad1359945d7277', 460057,
         'bbcabe73fd39fb92b96fbb4c661c1a15b0f9e5d9411468f7954c4f433911cb9c'),
        ('OpenSEP', '8b1633f7e6606f0bc9e1422c93e8d2e056154d2f', 147512,
         '92690b9c7e900ec0054271dbbc0444ee2d8567c8d41d3a2e491ba011e2b08b12'),
    ]:
        path = 'VPhoneExecutable/VPhoneVirtualization/Resources/' + name + '/' + name + '.bin'
        data = git(repo, 'show', TARGET + ':' + path)
        digest = hashlib.sha256(data).hexdigest()
        assert len(data) == expected_size and digest == expected_digest
        readme = git(repo, 'show', TARGET + ':' + str(Path(path).with_name('README.md'))).decode()
        assert pin in readme and digest in readme
        roms[name] = dict(source_pin=pin, bytes=len(data), sha256=digest,
                          binary_matches_recorded_digest=True, source_rebuild_verified=False)
    return dict(base=BASE, target=TARGET, total=len(records),
                merge_count=sum(c['is_merge'] for c in commits), commits=records,
                fixed_target_locks=locks, fixed_target_roms=roms,
                observed_attachment_set_match=None,
                limitations=['Original attachment enumeration unavailable; no independent attachment set comparison.',
                             'Merge parent diffs archived; empty remerge output does not prove semantic equivalence.',
                             'First-pass routing only. No functionality, ROM rebuild, firmware or VM acceptance.',
                             'Root TODO.md content excluded.'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True, type=Path)
    parser.add_argument('--audit', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--verify', action='store_true', help='Compare with existing output without writing it')
    args = parser.parse_args()
    report = build(args.repo, args.audit)
    if args.verify:
        if json.loads(args.out.read_text()) != report:
            raise ValueError('Existing disposition report differs from reconstructed evidence')
        print('Existing disposition report matches the fixed Git range and source records.')
        return
    # Avoid overwriting earlier evidence on subsequent runs.
    with args.out.open('x') as handle:
        json.dump(report, handle, ensure_ascii=True, indent=2)
        handle.write('\n')
    print(json.dumps(dict(total=report['total'], merges=report['merge_count'],
                          locks=len(report['fixed_target_locks']), roms=report['fixed_target_roms']), indent=2))


if __name__ == '__main__':
    main()
