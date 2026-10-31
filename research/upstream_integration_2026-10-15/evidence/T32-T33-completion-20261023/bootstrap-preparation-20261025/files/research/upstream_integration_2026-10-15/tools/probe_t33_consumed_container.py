"""Replay transport chronology from retained evidence; never mount or modify a VM.

Only image-binding context is reconstructed from the already verified native
export. This diagnoses the pre-final-read error, not deployment authority or
the final bytes of the retained disk.
"""
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
from patchers import component_transport as transport


def main():
    work = ROOT / '.build/t32-t33-completion-20261023/exp-staged-dsc-acceptance-20261025'
    history = ROOT / '.build/t33t-20261025/.cfw-history/20261025T100633Z-Bvlz2q7C'
    out = ROOT / '.build/t32-t33-completion-20261023/consumed-container-replay-20261025.json'
    if out.exists():
        raise ValueError('Preserve existing diagnostic output')
    native = json.loads((work / 'execution/exp/verify-plan.log').read_bytes())['record']
    rows = [json.loads(line) for line in (history / 'guest-changes.jsonl').read_text().splitlines()]
    plan = SimpleNamespace(context=dict(vmDirectory=str(history.parents[1]), generationID=native['generationID']),
                           record=dict(planSHA256=native['planSHA256']))
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        roots = {name: root / name for name in ('system', 'data', 'preboot', 'hardware', 'dsc')}
        for path in roots.values():
            path.mkdir()
        try:
            transport.verify(rows, roots, history / 'effect-blobs', plan)
        except ValueError as error:
            trace = error.__traceback__
            scope = None
            while trace:
                if trace.tb_frame.f_code is transport.verify.__code__:
                    scope = trace.tb_frame.f_locals
                trace = trace.tb_next
            if scope is None:
                raise
            path = scope['path']
            live = [dict(path=other, target=node.get('target'), state=node['after'])
                    for other, node in scope['nodes'].items()
                    if Path(path) in Path(other).parents and node['after']['kind'] != 'missing']
            result = dict(error=str(error), exactOriginalError=str(error) == 'consumed container still has required members',
                index=scope['index'], path=path, target=scope['target'], declarationID=scope['row']['declarationID'],
                command=scope['proof'].get('command'), operation=scope['proof'].get('operation'),
                originalEffect=scope['original']['effect'], liveDescendants=len(live), examples=live[:8],
                totalRows=len(rows), finalDiskReadPerformed=False, VMStarts=0, CFWWrites=0)
            with out.open('x') as stream:
                json.dump(result, stream, indent=2); stream.write('\n')
            print(json.dumps({key:value for key,value in result.items() if key not in ('originalEffect', 'examples')}))
            return 0 if result['exactOriginalError'] else 1
    raise ValueError('Expected retained chronology rejection did not reproduce')


if __name__ == '__main__':
    raise SystemExit(main())
