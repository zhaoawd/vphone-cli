"""Wait for the existing native worker, then run independent readonly finalization."""
import hashlib
import json
from pathlib import Path
import time

import execute_t33_plist_lifetime_acceptance as current
import finalize_t33_plist_lifetime_acceptance as finalizer


def main():
    source = Path(__file__)
    own_sha = hashlib.sha256(source.read_bytes()).hexdigest()
    runner = current.runner
    current.configure()
    identity = finalizer.checks.read(current.WORK / 'native-root-identity.json')
    plan_sha = runner.base.evidence.digest(current.WORK / 'offline-plan.json')
    if plan_sha != '4376d79c942fe26e04a8014d1de6d88c8bc5a49e61c58b49127cfa98e0d14dd7':
        raise ValueError('Unexpected approved plan')
    runner.configure(plan_sha)
    runner.base.approved(plan_sha)
    runner.base.verify_execution_inputs()
    (current.WORK / 'readonly-finalizer.claim').mkdir(mode=0o700)
    runner.base.save(current.WORK / 'readonly-finalizer-identity.json',
        dict(nativeWorker=identity, planSHA256=plan_sha, watcherSHA256=own_sha,
             VMStarts=0, securityWindows=0, retriesAllowed=False))
    deadline = time.monotonic() + 172800
    print(json.dumps(dict(state='watching-existing-worker', nativeWorker=identity)), flush=True)
    while finalizer.checks.root_running(identity):
        if time.monotonic() >= deadline:
            raise ValueError('Readonly watcher timed out; worker was not interrupted')
        if hashlib.sha256(source.read_bytes()).hexdigest() != own_sha:
            raise ValueError('Watcher source changed; stop without affecting worker')
        time.sleep(30)
    if hashlib.sha256(source.read_bytes()).hexdigest() != own_sha:
        raise ValueError('Watcher source changed')
    print(json.dumps(finalizer.finalize()), flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        current.runner.base.save(current.WORK / 'readonly-finalizer-stopped.json',
            dict(state='stopped', error=str(error), nativeRetried=False))
        raise
