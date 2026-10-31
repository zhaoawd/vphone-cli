"""One approved recovered Undo, using only installed candidate modules.

The old writer is never invoked. Failure preserves the new private transaction;
finish is called only after publication succeeds. No automatic recovery runs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
from types import SimpleNamespace


def require_root():
    if os.geteuid() != 0:
        raise ValueError('Native root recovery required')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    args = parser.parse_args()
    raw = args.plan.read_bytes()
    if hashlib.sha256(raw).hexdigest() != args.sha256:
        raise ValueError('Approved recovery plan changed')
    plan = json.loads(raw)
    if json.loads((args.plan.parent / 'approval.json').read_bytes()) != dict(approved=True, planSHA256=args.sha256):
        raise ValueError('Explicit recovery approval required')
    candidate = plan['candidate']
    cli = Path(plan['installedCLI'])
    if hashlib.sha256(cli.read_bytes()).hexdigest() != candidate['cliSHA256']:
        raise ValueError('Installed recovery executable differs')
    scripts = cli.parent.parent / 'Resources/scripts'
    sys.path.insert(0, str(scripts))
    import cfw_disk_txn as txn
    import cfw_guest_evidence as evidence
    from patchers import final_guest, guest_recovery, plan_gate as gate, undo_provenance
    vm = Path(plan['targets'][0]['vm']); txn.require_lock(vm)
    require_root()
    # Authenticate the installed dependency closure against the frozen package.
    for relative, digest in plan['installedModuleSHA256'].items():
        if evidence.digest(scripts / relative) != digest:
            raise ValueError('Installed recovery module differs: ' + relative)
    recovery = plan['recovery']; source = Path(recovery['preservedSource'])
    work = Path(recovery['newWork'])
    if work.exists() or (vm / '.cfw-history' / recovery['transactionID']).exists():
        raise ValueError('Preserve existing recovery transaction; no replay')
    if sorted(str(p) for p in vm.glob('.cfw_disk.*')):
        raise ValueError('Another unfinished transaction exists')
    context = json.loads(evidence.read(source / evidence.CONTEXT))
    context.update(verifierPath=str(cli), verifierSHA256=candidate['cliSHA256'])
    binding = evidence.read(vm / 'launchpad.json')
    if json.loads(binding) != plan['boundBeforeRecovery']:
        raise ValueError('Recovery binding differs from the approved transition')
    os.environ.update(VPHONE_FROZEN_PLAN=str(vm / '.firmware-desired-plan.json'),
        VPHONE_FROZEN_PLAN_SHA256=recovery['desiredSHA256'],
        VPHONE_FROZEN_CONTEXT=json.dumps(context),
        VPHONE_EXPECTED_BINDING_SHA256=hashlib.sha256(binding).hexdigest(),
        VPHONE_EXPECTED_CORE_BUNDLE=candidate['version'],
        VPHONE_GUEST_EVIDENCE=str(work / evidence.OPERATIONS))
    # A valid frozen Swift/Python plan is required before creating a transaction.
    gate.from_environment()
    work.mkdir(mode=0o700)
    fd = os.open(vm / 'Disk.img', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    txargs = SimpleNamespace(vm=vm, work=work, fd=fd, owner_pid=os.getpid(),
        exit_code=0, retain_staged=True, transaction_id=recovery['transactionID'])
    started = time.monotonic(); timings = {}
    try:
        expected = dict(recordSHA256=recovery['recordSHA256'], imageSHA256=recovery['imageSHA256'],
            parentImageSHA256=recovery['parentImageSHA256'], approvedPlanSHA256=args.sha256)
        guest_recovery.prepare_recovered(txargs, source, expected)
        timings['prepareSeconds'] = time.monotonic() - started
        mount = txn.make_mount_directory(Path('/private/tmp'))
        os.environ['CFW_HOST_MNT'] = str(mount); txn.bind_mount(txargs)
        base = None
        try:
            info = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'attach', '-readonly',
                '-nomount', '-plist', '-imagekey', 'diskimage-class=CRawDiskImage', str(work / 'Disk.img')]))
            bases = [r['dev-entry'] for r in info.get('system-entities', [])
                     if r.get('content-hint') == 'GUID_partition_scheme']
            if len(bases) != 1:
                raise ValueError('Recovery readonly image has no unique physical disk')
            base = bases[0]
            t = time.monotonic(); final = final_guest.run(gate.from_environment())
            evidence.write_final(work / evidence.FINAL, gate.canonical(final))
            undo_provenance.seal(work, final)
            timings['finalReadSeconds'] = time.monotonic() - t
        finally:
            # Only this invocation's exact mounted roots are normally detached.
            for name, suffix in reversed(list(final_guest.VOLUMES.values())):
                root = mount / name
                if root.exists() and os.path.ismount(root):
                    subprocess.run(['/sbin/umount', str(root)], check=True)
            if base is not None:
                subprocess.run(['/usr/bin/hdiutil', 'detach', base], check=True)
        for name, operation in (('seal', txn.seal), ('publish', txn.publish), ('finish', txn.finish)):
            t = time.monotonic(); operation(txargs); timings[name + 'Seconds'] = time.monotonic() - t
        evidence.write_new(args.plan.parent / 'execution/recovered-undo-result.json',
            gate.canonical(dict(state='published', transactionID=recovery['transactionID'],
                sourceTransactionID=recovery['sourceTransactionID'], repeatedUndoWrites=0,
                timings=timings, VMStarts=0, runtimeValidated=False)))
    finally:
        os.close(fd)


if __name__ == '__main__':
    main()
