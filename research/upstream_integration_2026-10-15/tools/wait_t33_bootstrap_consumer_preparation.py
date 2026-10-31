"""Wait for offline finalization and prepare a new plan; never execute runtime."""
import hashlib
import json
from pathlib import Path
import time

import prepare_t33_consumer_runtime as preparation


def main():
    current = preparation.current
    current.configure()
    paths = [Path(__file__).resolve(), Path(preparation.__file__).resolve()]
    pinned = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    marker = preparation.runner.BASE / 'consumer-preparation-wait-bootstrap-20261025.json'
    preparation.base.save(marker, dict(state='waiting-offline-finalization', frozenSources=pinned,
                                      VMStarts=0, securityWindows=0))
    deadline = time.monotonic() + 172800
    final = current.WORK / 'finalization.json'
    while not final.is_file():
        if (current.WORK / 'readonly-finalizer-stopped.json').exists():
            raise ValueError('Independent offline finalization stopped; no runtime preparation')
        if time.monotonic() >= deadline:
            raise ValueError('Preparation wait expired; no runtime started')
        if any(hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest for path, digest in pinned.items()):
            raise ValueError('Preparation source changed while waiting')
        time.sleep(30)
    if any(hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest for path, digest in pinned.items()):
        raise ValueError('Preparation source changed while waiting')
    result = preparation.prepare()
    preparation.base.save(preparation.runner.BASE / 'consumer-preparation-result-bootstrap-20261025.json', result)
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        preparation.base.save(preparation.runner.BASE / 'consumer-preparation-stopped-bootstrap-20261025.json',
                              dict(state='stopped', error=str(error), VMStarts=0, securityWindows=0))
        raise
