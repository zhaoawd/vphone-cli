"""Read-only journal observations; never take locks or change the update."""
from pathlib import Path
import datetime
import json
import time

E = Path(__file__).resolve().parent
VM = Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
out = E / 'kernel-update-v8-resumed-observations.jsonl'
assert not out.exists()
started = time.monotonic()
previous = None
last = 0
with out.open('x') as stream:
    while True:
        value = {'phase': 'before-transaction'}
        journal = VM / '.firmware-transaction/journal.json'
        if journal.exists():
            data = json.loads(journal.read_text())
            disk = data.get('kernelDisk') or {}
            value = {'transaction_id': data['id'], 'phase': data['phase'],
                     'cursor': disk.get('cursor'), 'blocks': len(disk.get('offsets', [])),
                     'pending': disk.get('pending'), 'direction': disk.get('direction')}
        finished = (E / 'kernel-update-v8-resumed.json').exists()
        if value != previous or time.monotonic() - last >= 60 or finished:
            record = {**value, 'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      'observer_elapsed_seconds': round(time.monotonic() - started, 1),
                      'wrapper_finished': finished}
            stream.write(json.dumps(record) + '\n')
            stream.flush()
            print(json.dumps(record), flush=True)
            previous, last = value, time.monotonic()
        if finished:
            break
        time.sleep(5)
