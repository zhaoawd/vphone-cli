"""Check the preserved task definitions and dependency graph for this change."""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[4]
relative = 'research/upstream_integration_2026-10-15/tasks.json'
current = json.loads((root / relative).read_text())
original = json.loads(subprocess.check_output(['git', 'show', 'HEAD:' + relative], cwd=root))
rows = current['tasks']
assert [row['id'] for row in rows] == ['T%02d' % number for number in range(61)]
assert current['task_counts'] == original['task_counts']
for old, new in zip(original['tasks'], rows):
    assert {k: v for k, v in old.items() if k != 'target_review'} == {k: v for k, v in new.items() if k != 'target_review'}, old['id']
by_id = {row['id']: row for row in rows}
visited = set()
def visit(identifier, active):
    assert identifier in by_id, identifier
    assert identifier not in active, identifier
    if identifier in visited:
        return
    for dependency in by_id[identifier]['dependencies']:
        visit(dependency, active | {identifier})
    visited.add(identifier)
for identifier in by_id:
    visit(identifier, set())
for identifier in ('T32', 'T33'):
    assert by_id[identifier]['target_review']['execution_2026_10_15']['accepted'] is False
    for evidence in by_id[identifier]['target_review']['execution_2026_10_15']['evidence']:
        assert (root / Path(relative).parent / evidence).is_file(), evidence
print(json.dumps({'tasks': 61, 'ids_and_dependencies': 'passed', 'historical_fields_and_counts_preserved': True, 'new_target_acceptance_not_promoted': True, 'evidence_links': 'passed'}, indent=2))
