"""Read-only installed-byte comparison and declaration-level Undo eligibility.

The caller owns publication authentication, the VM lock and readonly mounts.
These observations grant neither runtime-behaviour nor origin/write authority.
"""
from pathlib import Path, PurePosixPath

from . import component_effects as effects
from . import component_transport as transport
from . import plan_gate as gate


def target_path(target, roots):
    if not isinstance(target, str) or '\0' in target or ':' not in target:
        raise ValueError('invalid installed target')
    volume, relative = target.split(':', 1)
    if (volume not in ('system', 'hardware', 'preboot', 'dsc') or volume not in roots
            or not relative.startswith('/') or relative.startswith('//')
            or '..' in PurePosixPath(relative).parts
            or str(PurePosixPath(relative)) != relative):
        raise ValueError('installed target has no exact qualified root')
    root = Path(roots[volume])
    if not root.is_absolute(): raise ValueError('installed root must be absolute')
    path = root / relative.lstrip('/')
    current = path.parent if path != root else root
    while True:
        if current.is_symlink(): raise ValueError('linked installed target parent')
        if current == root: break
        if current == current.parent: raise ValueError('installed target escaped its root')
        current = current.parent
    return path


def verify_targets(outputs, roots):
    if not outputs or len({row['target'] for row in outputs}) != len(outputs):
        raise ValueError('installed outputs are empty or duplicated')
    # Validate addressing before any file read; recorded temporary paths are
    # never consulted. Parent-link refusal is reported as a target failure.
    for row in outputs:
        target = row['target']; volume, _, relative = target.partition(':')
        if (volume not in ('system', 'hardware', 'preboot', 'dsc') or volume not in roots
                or not relative.startswith('/') or relative.startswith('//') or '\0' in target
                or '..' in PurePosixPath(relative).parts or str(PurePosixPath(relative)) != relative):
            raise ValueError('installed target has no exact qualified root')
    cache = {}; results = []
    for row in outputs:
        expected = row['state']; error = None; actual = None
        try:
            path = target_path(row['target'], roots)
            key = (path, 'children' in expected)
            if key not in cache:
                cache[key] = effects.state(path, recursive='children' in expected)
            actual = cache[key]
        except (OSError, ValueError) as failure:
            error = str(failure)
        fields = (sorted(k for k in set(expected) | set(actual) if expected.get(k) != actual.get(k))
                  if actual is not None else ['unreadable'])
        result = dict(target=row['target'], matches=actual == expected, expected=expected,
                      observed=actual, differentFields=fields)
        if error is not None: result['error'] = error
        results.append(result)
    return dict(scope='installed-target-bytes-and-metadata', passed=all(row['matches'] for row in results),
                runtimeValidated=False, originQualified=False, writeAuthorized=False, targets=results)


def undo_eligibility(rows, index):
    """Describe complete declaration selections, including suffix dependencies."""
    covered = {(operation['rowSHA256'], entry['target'])
               for entry in index['entries'] for operation in entry['operations']}
    def normalized(target):
        from .undo_provenance import DSC_TARGET
        return 'dsc:/' + target.removeprefix(DSC_TARGET) if target.startswith(DSC_TARGET) else target
    covered = {(digest, normalized(target)) for digest, target in covered}
    changes = {row['declarationID']: [] for row in rows}
    for row in rows:
        digest = gate.sha(gate.canonical(row))
        for member in transport.expanded(row):
            if member['effect']['before'] != member['effect']['after']:
                changes[row['declarationID']].append((digest, normalized(member['target'])))
    result = []
    for declaration, members in sorted(changes.items()):
        required = {declaration}
        while True:
            before = set(required)
            for entry in index['entries']:
                positions = [i for i, operation in enumerate(entry['operations'])
                             if operation['declarationID'] in required]
                if positions:
                    required.update(op['declarationID'] for op in entry['operations'][min(positions):])
            if required == before: break
        unsupported = sorted({target for name in required for digest, target in changes.get(name, [])
                              if (digest, target) not in covered})
        state = ('no_recorded_change' if not members else 'not_revertible' if unsupported else
                 'qualified_dsc_suffix' if required == {declaration} else 'requires_later_declarations')
        result.append(dict(declarationID=declaration, state=state, requiredDeclarations=sorted(required),
                           unsupportedTargets=unsupported, writeAuthorized=False))
    return result
