"""固定目标的文件映射与提交审查入口；字节比较不构成语义验收。"""
from pathlib import Path
import collections
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
UPSTREAM = Path('/private/tmp/vphone-upstream-source-20261006')
OBJECTS = '/private/tmp/vphone-upstream-proxy-20261006'
TARGET = '2d21d21fbdd4f51f013616273ceda9b35a3e0789'
START = '9d218dedf58d4b19db5e51c8b584c1f14a96eee3'
PREVIOUS = 'a969cd5d9206932dc1a2797348027fbc7d0ee347'


def git(*args):
    return subprocess.check_output(['git', '--git-dir', OBJECTS, *args], text=True)


def save(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def family(path):
    parts = Path(path).parts
    if parts[0] == 'VPhoneDaemon':
        return 'sources/VPhoneDaemon'
    if parts[0] == 'VPhoneGuestComponents':
        return 'sources/VPhoneGuestComponents'
    if parts[0] == 'VPhoneKit' and len(parts) > 1:
        return 'sources/' + {'VPhoneCoreKit': 'VPhoneCore'}.get(parts[1], parts[1])
    if parts[0] == 'VPhoneExecutable':
        if 'FirmwarePatcher' in parts:
            return 'sources/FirmwarePatcher'
        if 'VPhoneSign' in parts:
            return 'sources/VPhoneSign'
        return 'sources/vphone-cli'
    if parts[0] == 'VPhoneLaunchpad':
        if len(parts) > 1 and parts[1] == 'VPhoneLaunchpadHelper':
            return 'sources/VPhoneHelperKit'
        return 'sources/VPhoneLaunchpad'
    if parts[0] == 'Research':
        return 'research'
    if parts[0] == 'Documents':
        return 'docs'
    return None


def main():
    plan = json.loads((OUT / 'tasks.json').read_text())
    tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    local = [p for p in tracked if p and p != 'TODO.md' and not p.startswith('research/upstream_integration_2026-10-06/')]
    names = collections.defaultdict(list)
    for p in local:
        names[Path(p).name].append(p)
    rows = []
    capabilities = []
    for task in plan['tasks']:
        entries = []
        for reference in task['upstream_paths']:
            path = UPSTREAM / reference
            refs = [p.relative_to(UPSTREAM).as_posix() for p in path.rglob('*') if p.is_file()] if path.is_dir() else [reference]
            for upstream in refs:
                if upstream == 'TODO.md':
                    continue
                candidates = names[Path(upstream).name]
                prefix = family(upstream)
                module_candidates = [p for p in candidates if prefix and p.startswith(prefix)]
                chosen = module_candidates or candidates
                entry = {'task': task['id'], 'upstream': upstream, 'upstream_exists': (UPSTREAM / upstream).is_file(),
                         'candidates': [], 'semantic_state': 'not_audited'}
                for candidate in chosen:
                    entry['candidates'].append({'path': candidate, 'sha256': digest(ROOT / candidate),
                        'identical_bytes': entry['upstream_exists'] and digest(ROOT / candidate) == digest(UPSTREAM / upstream)})
                rows.append(entry)
                entries.append(entry)
        capabilities.append({'id': task['id'], 'title': task['title'], 'dependencies': task['dependencies'],
            'disposition': 'deferred' if task['id'] == 'T45' else 'unknown',
            'reason': '原方案默认延后' if task['id'] == 'T45' else '路径候选和字节摘要已采集；语义差异按任务复核',
            'paths': sorted({c['path'] for e in entries for c in e['candidates']}),
            'unmapped_upstream_paths': [e['upstream'] for e in entries if not e['candidates']]})
    save('source_path_candidates.json', {'target': TARGET, 'evidence_strength': 'filename/module/bytes only', 'files': rows})
    save('capability_ledger.json', capabilities)
    log = git('log', '--reverse', '--format=%H%x09%P%x09%s', START + '..' + TARGET)
    commits = []
    scopes = {task['id']: task['upstream_paths'] for task in plan['tasks']}
    for line in log.splitlines():
        sha, parents, subject = line.split('\t', 2)
        parent_list = parents.split()
        # First-parent tree difference supplies a path inventory for merges.
        paths = git('diff', '--name-only', parent_list[0], sha, '--', '.', ':(exclude)TODO.md').splitlines()
        assigned = sorted(task for task, roots in scopes.items()
                          if any(any(p == r or p.startswith(r.rstrip('/') + '/') for r in roots) for p in paths))
        docs_only = bool(paths) and all(p.endswith('.md') or p.startswith(('Documents/', 'Research/')) for p in paths)
        merge = len(parent_list) > 1
        row = {'sha': sha, 'parents': parent_list, 'subject': subject,
            'range': '2.2.3-to-target' if subprocess.run(['git', '--git-dir', OBJECTS, 'merge-base', '--is-ancestor', sha, PREVIOUS], capture_output=True).returncode else '2.0.8-to-2.2.3',
            'paths': paths, 'candidate_tasks': assigned or ['T02'], 'merge': merge,
            'disposition': 'documentation_review_T28' if docs_only else 'pending_semantic_review',
            'reason': '仅文档路径；按固定目标维护相关文档并保留来源' if docs_only else '需结合最终状态和本地定制审查，不能按提交标题判定已覆盖'}
        if merge and len(parent_list) == 2:
            proc = subprocess.run(['git', '--git-dir', OBJECTS, 'show', '--format=', '--remerge-diff', sha,
                                   '--', '.', ':(exclude)TODO.md'], capture_output=True)
            row['remerge_diff_exit_code'] = proc.returncode
            row['remerge_diff_bytes'] = len(proc.stdout)
            row['remerge_diff_sha256'] = hashlib.sha256(proc.stdout).hexdigest()
            row['resolution_review'] = 'remerge_diff_nonempty' if proc.stdout else 'no_diff_with_this_git_version'
            if proc.stderr:
                row['remerge_stderr'] = proc.stderr.decode(errors='replace')
        commits.append(row)
    assert len(commits) == 342
    assert sum(not c['merge'] for c in commits) == 280
    assert sum(c['range'] == '2.2.3-to-target' and not c['merge'] for c in commits) == 158
    save('commit_ledger.json', {'target': TARGET, 'start': START, 'git_version': git('--version').strip(),
         'classification_scope': 'path triage; pending rows are not approved for transplant', 'commits': commits})
    print(json.dumps({'tasks': len(capabilities), 'path_rows': len(rows), 'commits': len(commits),
        'merge_commits': sum(c['merge'] for c in commits),
        'merge_diffs_nonempty': sum(c.get('remerge_diff_bytes', 0) > 0 for c in commits),
        'docs_only_commits': sum(c['disposition'] == 'documentation_review_T28' for c in commits)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
