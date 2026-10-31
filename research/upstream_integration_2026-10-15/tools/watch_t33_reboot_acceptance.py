"""Wait for the exact approved root worker, then finalize and prepare for review.

This watcher never installs, registers, publishes, starts a VM, or starts a
helper. An interrupted worker without a result is recorded and never restarted.
"""
import json
import os
from pathlib import Path
import time

import execute_t33_reboot_acceptance as current
import finalize_t33_reboot_acceptance as finalizer
import prepare_t33_reboot_consumer_runtime as consumer

base = current.base


def finish_stopped(identity):
    if finalizer.previous.root_running(identity):
        raise ValueError('Exact root worker still running')
    if not (current.WORK / 'execution/result.json').exists():
        return dict(state='interrupted-without-result', rootIdentity=identity,
            automaticRetry=False, VMStarts=0, securityWindows=0)
    final = finalizer.finalize()
    result = dict(state='offline-finalized', finalization=final, VMStarts=0, securityWindows=0)
    if final['offlineAcceptancePassed']:
        result['consumerPreparation'] = consumer.prepare()
        result['state'] = 'runtime-plan-prepared-not-approved'
    return result


def main():
    plan = current.validate(current.read(current.WORK / 'offline-plan.json'))
    digest = base.evidence.digest(current.WORK / 'offline-plan.json'); current.configure(digest)
    base.approved(digest); base.verify_inputs(plan); base.verify_execution_inputs()
    identity = current.read(current.WORK / 'native-root-identity.json')
    launch = current.read(current.WORK / 'root-launch.json')
    if launch != dict(pid=identity['pid'], planSHA256=digest):
        raise ValueError('Root worker differs from this approved launch')
    (current.WORK / 'readonly-watch.claim').mkdir(mode=0o700)
    base.save(current.WORK / 'readonly-watch-start.json', dict(pid=os.getpid(), rootIdentity=identity,
        planSHA256=digest, sources={str(path): base.evidence.digest(path) for path in
            (Path(__file__), Path(finalizer.__file__), Path(consumer.__file__))}))
    print(json.dumps(dict(state='watching-exact-root', rootIdentity=identity, planSHA256=digest)), flush=True)
    deadline = time.monotonic() + 24 * 3600
    try:
        while finalizer.previous.root_running(identity):
            if time.monotonic() >= deadline:
                raise TimeoutError('Readonly watcher deadline; original worker was not signaled')
            time.sleep(10)
        base.verify_inputs(plan); base.verify_execution_inputs()
        result = finish_stopped(identity)
    except Exception as error:
        result = dict(state='readonly-watcher-stopped', error=str(error), rootIdentity=identity,
            automaticRetry=False, VMStarts=0, securityWindows=0)
    base.save(current.WORK / 'readonly-watch-result.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['state'] == 'runtime-plan-prepared-not-approved' else 1


if __name__ == '__main__':
    raise SystemExit(main())
