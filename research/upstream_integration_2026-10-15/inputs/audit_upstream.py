#!/usr/bin/env python3
"""Read-only Git range audit. Python 3.9+ and Git; no network, checkout or VM writes.

Example:
  python3 audit_upstream.py --repo /path/to/vphone-cli --out /tmp/vphone-audit-20261014

The output directory must not exist and must be outside the repository. The fixed
upstream commits must already be present in a non-shallow repository. The bundled
web ledger is reconciled against the actual Git graph when present.
"""
from __future__ import annotations
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Any

BASE = '2d21d21fbdd4f51f013616273ceda9b35a3e0789'
TARGET = '8a75092013eda87a4e30ed029b72028cb9279ac4'

class AuditError(RuntimeError):
    pass


def inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--repo', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    ap.add_argument('--base', default=BASE)
    ap.add_argument('--target', default=TARGET)
    ap.add_argument('--ledger', type=Path, default=Path(__file__).with_name('commits.json'))
    args = ap.parse_args()
    repo = args.repo.expanduser().resolve(strict=True)
    out = args.out.expanduser().resolve()
    if out.exists():
        raise AuditError(f'Output already exists; choose a new directory: {out}')
    if inside(out, repo):
        raise AuditError('Keep audit outputs outside the input repository.')
    env = dict(os.environ, GIT_OPTIONAL_LOCKS='0', GIT_NO_REPLACE_OBJECTS='1',
               GIT_NO_LAZY_FETCH='1', LC_ALL='C')

    def command(*words: str, check: bool = True) -> subprocess.CompletedProcess[bytes]:
        p = subprocess.run(['git', '--no-pager', '-C', str(repo), *words],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, check=False)
        if check and p.returncode:
            raise AuditError(f'git {" ".join(words)} failed ({p.returncode}):\n' +
                             p.stderr.decode('utf-8', errors='replace'))
        return p

    def text(*words: str) -> str:
        return command(*words).stdout.decode('utf-8', errors='surrogateescape').strip()

    if text('rev-parse', '--is-shallow-repository') != 'false':
        raise AuditError('A shallow repository cannot establish the complete range; obtain full history first.')
    git_dir = Path(text('rev-parse', '--absolute-git-dir')).resolve()
    if inside(out, git_dir):
        raise AuditError('Output must not be inside the Git metadata directory.')
    # Resolve user-supplied revisions before any output is created. No implicit fetch.
    base = text('rev-parse', '--verify', f'{args.base}^{{commit}}')
    target = text('rev-parse', '--verify', f'{args.target}^{{commit}}')
    if command('merge-base', '--is-ancestor', base, target, check=False).returncode:
        raise AuditError('Base is not an ancestor of target, or its ancestry could not be read.')
    span = f'{base}..{target}'
    ids = text('rev-list', '--reverse', '--topo-order', span).splitlines()
    first_parent_ids = text('rev-list', '--reverse', '--first-parent', span).splitlines()
    out.mkdir(parents=True, exist_ok=False)

    def write_json(name: str, obj: Any) -> None:
        # ASCII escaping preserves unusual Git filenames and arbitrary message bytes.
        (out / name).write_text(json.dumps(obj, ensure_ascii=True, indent=2) + '\n', encoding='utf-8')

    diff_flags = ['--no-ext-diff', '--no-textconv', '--find-renames=50%']
    def changes(a: str, b: str) -> list[dict[str, str]]:
        tokens = command('diff', *diff_flags, '--name-status', '-z', a, b, '--').stdout.split(b'\0')
        result: list[dict[str, str]] = []
        i = 0
        while i < len(tokens) and tokens[i]:
            status = tokens[i].decode('ascii'); i += 1
            old = tokens[i].decode('utf-8', 'surrogateescape'); i += 1
            if status.startswith(('R', 'C')):
                new = tokens[i].decode('utf-8', 'surrogateescape'); i += 1
                result.append({'status': status, 'old_path': old, 'path': new})
            else:
                result.append({'status': status, 'path': old})
        return result

    endpoints = changes(base, target)
    write_json('endpoint_files.json', endpoints)
    for name, flags in [('endpoint.stat.txt', ['--stat']),
                        ('endpoint.numstat.z', ['--numstat', '-z']),
                        ('endpoint.name-status.z', ['--name-status', '-z']),
                        ('endpoint.diff', ['--binary', '--full-index'])]:
        # Stream a potentially large binary patch to disk rather than holding it in RAM.
        with (out / name).open('wb') as handle:
            p = subprocess.run(['git', '--no-pager', '-C', str(repo), 'diff', *diff_flags,
                                *flags, base, target, '--'], stdout=handle, stderr=subprocess.PIPE,
                               env=env, check=False)
        if p.returncode:
            raise AuditError(f'{name}: {p.stderr.decode("utf-8", "replace")}')
    (out / 'history.graph.txt').write_bytes(command('log', '--graph', '--oneline', '--decorate=no', span).stdout)
    (out / 'first-parent.txt').write_text('\n'.join(first_parent_ids) + '\n', encoding='utf-8')

    merge_dir = out / 'merge_review'; merge_dir.mkdir()
    commits: list[dict[str, Any]] = []
    for index, sha in enumerate(ids, 1):
        raw = command('show', '-s', '--format=%H%x00%P%x00%aI%x00%cI%x00%s%x00%B', sha).stdout
        fields = raw.decode('utf-8', 'surrogateescape').rstrip('\n').split('\0', 5)
        if len(fields) != 6:
            raise AuditError(f'Unexpected commit metadata: {sha}')
        full, parents_text, authored, committed, subject, message = fields
        parents = parents_text.split()
        item: dict[str, Any] = dict(index=index, sha=full, parents=parents,
            authored_at=authored, committed_at=committed, subject=subject, message=message,
            is_merge=len(parents) > 1, files_by_parent={p: changes(p, sha) for p in parents})
        if len(parents) > 1:
            for parent_index, parent in enumerate(parents, 1):
                (merge_dir / f'{sha}.parent{parent_index}.diff').write_bytes(
                    command('diff', *diff_flags, '--binary', '--full-index', parent, sha, '--').stdout)
            p = command('show', '--format=', '--remerge-diff', '--no-ext-diff', '--no-textconv', sha, check=False)
            item['remerge_review'] = {'exit_code': p.returncode,
                'stderr': p.stderr.decode('utf-8', 'replace'),
                'meaning': 'Diagnostic only; empty output is not proof of no independent merge resolution.'}
            (merge_dir / f'{sha}.remerge.diff').write_bytes(p.stdout)
        commits.append(item)
    write_json('git_commits.json', commits)

    reconciliation: dict[str, Any] = {'ledger_available': args.ledger.exists(), 'git_graph_verified': True}
    if args.ledger.exists():
        obj = json.loads(args.ledger.read_text(encoding='utf-8'))
        observed = obj.get('commits', obj) if isinstance(obj, dict) else obj
        resolved: set[str] = set()
        errors: list[dict[str, str]] = []
        for row in observed:
            short = row.get('sha') or row.get('short_sha')
            try:
                resolved.add(text('rev-parse', '--verify', f'{short}^{{commit}}'))
            except AuditError as exc:
                errors.append({'short_sha': str(short), 'error': str(exc)})
        reconciliation.update(observed_count=len(observed), unresolved=errors,
            missing_from_web_ledger=sorted(set(ids) - resolved),
            outside_requested_range=sorted(resolved - set(ids)),
            exact_set_match=not errors and set(ids) == resolved)
    write_json('observed_ledger_reconciliation.json', reconciliation)
    summary = dict(status='completed', source='local Git objects, not web enumeration',
        utc_time=dt.datetime.now(dt.timezone.utc).isoformat(), git_version=text('--version'),
        repository=str(repo), base=base, target=target, ancestor_verified=True,
        total_commits=len(commits), merge_commits=sum(c['is_merge'] for c in commits),
        non_merge_commits=sum(not c['is_merge'] for c in commits),
        first_parent_commits=len(first_parent_ids), endpoint_changed_paths=len(endpoints),
        endpoint_status_counts={s: sum(x['status'][0] == s for x in endpoints) for s in 'AMDRCTUXB'},
        important='No checkout/fetch/merge/cherry-pick/VM operation. Merge resolutions require human review.')
    write_json('audit.json', summary)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (AuditError, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f'Audit failed: {exc}', file=sys.stderr)
        raise SystemExit(2)
