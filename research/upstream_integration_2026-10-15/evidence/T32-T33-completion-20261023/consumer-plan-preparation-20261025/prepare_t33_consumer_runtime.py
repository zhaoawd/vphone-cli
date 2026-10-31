"""Prepare a backed-up EXP consumer plan only after complete offline acceptance.

This entrypoint never starts a VM, a helper, or an authentication request.
The private desired plan remains covered by offline evidence and is not a
runtime-write input. All ten boot inputs and the current binding are backed up.
"""
import ast
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys

import execute_t33_staged_dsc_acceptance as current
from t32_runtime_preflight import validate_control_socket

runner = current.runner
base = runner.base
TOOLS = Path(__file__).parent
WORK = runner.BASE / 't33t-consumer-runtime-20261025'
TEMPLATE = runner.BASE / 'short-runtime'


def completed(final, phase, offline):
    if (final.get('state') != 'finalized' or final.get('offlineAcceptancePassed') is not True
            or final.get('nativeState') != 'offline-qualified-on-off-on-passed'
            or final.get('planSHA256') != base.evidence.digest(current.WORK / 'offline-plan.json')
            or any(final.get(k) != 0 for k in ('VMStarts', 'securityWindows'))
            or final.get('error') is not None or final.get('runtimeValidated') is not False):
        raise ValueError('Complete independently finalized offline acceptance required')
    transactions = final.get('phaseTransactions', {})
    audit = phase.get('independentAudit', {})
    if (set(transactions) != {'on', 'off', 'reapplied'} or len(set(transactions.values())) != 3
            or phase.get('transactionID') != transactions['reapplied']
            or phase.get('generationID') != runner.GENERATION or audit.get('passed') is not True
            or audit.get('originQualified') is not True or audit.get('runtimeValidated') is not False
            or audit.get('generationID') != runner.GENERATION
            or audit.get('transactionID') != phase.get('transactionID')
            or phase.get('binding') != dict(bundle=current.VERSION, guestEnvironment=current.VERSION)
            or offline['targets'][0]['vm'] != str(runner.VM)):
        raise ValueError('Complete EXP publication and origin evidence required')
    digest = audit.get('currentImageSHA256', '')
    if re.fullmatch('[0-9a-f]{64}', digest) is None:
        raise ValueError('Complete published disk digest required')
    return digest


def scoped_helper(source, prior, window, binary, vm_sha, cdhash):
    """Replace only four explicit identity constants; preserve window limits."""
    limits = prior.get('window', {})
    if (limits.get('maxSeconds') != 900 or limits.get('maxAttachments') != 1
            or limits.get('persistentAllowlist') is not False
            or limits.get('independentSupervisor') is not True):
        raise ValueError('Previously reviewed single-window limits required')
    assignments = {}
    for node in ast.parse(source).body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            name = node.targets[0].id
            if name in assignments:
                raise ValueError('Ambiguous helper constant: ' + name)
            assignments[name] = node
    expected = dict(WORK=str(TEMPLATE / 'boot-window'), VM=prior['vmExecutable'],
                    VM_SHA256=prior['vmSHA256'], CDHASH=prior['CDHash'],
                    MAX_SECONDS=900, MAX_ATTACHMENTS=1)
    for name, value in expected.items():
        node = assignments[name]
        expression = node.value
        if name in ('WORK', 'VM'):
            if (not isinstance(expression, ast.Call) or not isinstance(expression.func, ast.Name)
                    or expression.func.id != 'Path' or len(expression.args) != 1 or expression.keywords):
                raise ValueError('Unexpected helper path expression')
            expression = expression.args[0]
        if ast.literal_eval(expression) != value:
            raise ValueError('Unexpected helper identity or window limit: ' + name)
    if re.fullmatch('[0-9a-f]{64}', vm_sha) is None or re.fullmatch('[0-9a-f]{40}', cdhash) is None:
        raise ValueError('Explicit VM SHA-256 and CDHash required')
    replacements = dict(WORK=f'Path({str(window)!r})', VM=f'Path({str(binary)!r})',
                        VM_SHA256=repr(vm_sha), CDHASH=repr(cdhash))
    lines = source.splitlines(keepends=True)
    for name in sorted(replacements, key=lambda key: assignments[key].lineno, reverse=True):
        node = assignments[name]
        lines[node.lineno-1:node.end_lineno] = [name + ' = ' + replacements[name] + '\n']
    result = ''.join(lines)
    ast.parse(result)
    return result


def backup_member(source, target, expected_disk=None):
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError('Runtime backup input is linked or special')
        digest = base.evidence.digest(source)
        if expected_disk is not None and digest != expected_disk:
            raise ValueError('Publication changed before runtime backup')
        base.txn.clone_file(fd, target)
        shutil.copystat(source, target)
        copied = target.stat()
        metadata = ('st_size', 'st_mode', 'st_uid', 'st_gid', 'st_mtime_ns')
        if (base.evidence.digest(target) != digest or copied.st_ino == info.st_ino
                or any(getattr(copied, key) != getattr(info, key) for key in metadata)):
            raise ValueError('Complete independent runtime backup differs')
        base.evidence.unchanged(source, fd, info)
        return dict(sha256=digest, bytes=info.st_size, sourceIdentity=base.evidence.image_identity(info),
                    mode=stat.S_IMODE(info.st_mode), uid=info.st_uid, gid=info.st_gid)
    finally:
        os.close(fd)


def prepare():
    current.configure()
    # No output directory or helper is created before the offline gate passes.
    offline = current.validate(json.loads(base.evidence.read(current.WORK / 'offline-plan.json')))
    final_path = current.WORK / 'finalization.json'
    if not final_path.is_file():
        raise ValueError('Complete independently finalized offline acceptance required; native run is pending')
    final = json.loads(base.evidence.read(final_path))
    phase = json.loads(base.evidence.read(current.WORK / 'execution/exp/reapplied.json'))
    disk_sha = completed(final, phase, offline)
    runner.configure(final['planSHA256'])
    base.verify_execution_inputs(); base.verify_inputs(offline)
    from finalize_t33_staged_dsc_acceptance import OUT
    if base.evidence.digest(OUT / 'manifest.json') != final['manifestSHA256']:
        raise ValueError('Final offline manifest changed')
    for row in json.loads(base.evidence.read(OUT / 'manifest.json'))['files']:
        if base.evidence.digest(OUT / row['path']) != row['sha256']:
            raise ValueError('Final offline evidence changed')
    if WORK.exists() or base.target_attachments(offline):
        raise ValueError('Existing runtime output or attached target; preserve it')
    geometry = validate_control_socket(runner.VM)
    binary = runner.CLI.with_name('vphone-vm')
    vm_sha = base.evidence.digest(binary)
    if vm_sha != offline['candidate']['vmSHA256']:
        raise ValueError('Installed VM executable differs from offline candidate')
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(binary)], check=True)
    signature = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(binary)],
                               check=True, text=True, capture_output=True)
    matches = re.findall(r'^CDHash=([0-9a-f]{40})$', signature.stderr, re.M)
    if len(matches) != 1:
        raise ValueError('Unique signed VM CDHash required')
    cdhash = matches[0]
    prior = json.loads(base.evidence.read(TEMPLATE / 'runtime-plan.json'))
    helper_path = TEMPLATE / 'boot-window/scoped-amfidont.py'
    if base.evidence.digest(helper_path) != prior['frozenTools'][str(helper_path)]:
        raise ValueError('Previously reviewed helper template changed')
    window = WORK / 'boot-window'
    helper = scoped_helper(base.evidence.read(helper_path).decode(), prior, window, binary, vm_sha, cdhash)
    names = sorted(set(offline['sourceBootFiles']) | {'launchpad.json'})
    config = plistlib.loads(base.evidence.read(runner.VM / 'config.plist'))
    for name in [config['diskImage'], config['nvramStorage'], config['sepStorage'], *config['romImages'].values()]:
        if Path(name).is_absolute() or len(Path(name).parts) != 1 or name not in names:
            raise ValueError('Boot input escapes the verified target')
    with base.audit.locked_vm(runner.VM):
        base.txn.require_unheld(runner.VM / 'Disk.img', os.getpid(), 'consumer preparation')
        WORK.mkdir(mode=0o700); backup = WORK / 'pre-runtime-backup'; backup.mkdir(mode=0o700)
        files = {name: backup_member(runner.VM / name, backup / name,
                    disk_sha if name == 'Disk.img' else None) for name in names}
        info = (runner.VM / 'Disk.img').stat()
        identity = dict(base.evidence.image_identity(info), ctime_ns=info.st_ctime_ns)
        base.save(WORK / 'runtime-backup.json', dict(schemaVersion=1, state='verified-backup',
            vm=str(runner.VM), backup=str(backup), files=files, generationID=runner.GENERATION,
            transactionID=phase['transactionID'], restoreAuthorized=False,
            VMWritten=False, VMStarted=False, securityWindowStarted=False))
    window.mkdir(mode=0o700)
    base.evidence.write_new(window / 'scoped-amfidont.py', helper.encode())
    starter = WORK / 'start_t33_observation_window.py'
    source = ('import importlib.util\nfrom pathlib import Path\n'
        f'spec=importlib.util.spec_from_file_location("t33_window",{str(TOOLS / "start_t32_observation_window.py")!r})\n'
        'module=importlib.util.module_from_spec(spec)\nspec.loader.exec_module(module)\n'
        f'module.WORK=Path({str(WORK)!r})\n'
        'if __name__=="__main__":raise SystemExit(module.main())\n')
    base.evidence.write_new(starter, source.encode())
    observer = WORK / 'observe_t33_consumer_runtime.py'
    source = ('import sys\n' + f'sys.path.insert(0,{str(TOOLS)!r})\n'
        'from observe_t33_consumer_runtime import main\n'
        f'if __name__=="__main__":raise SystemExit(main(["--work-directory",{str(WORK)!r},*sys.argv[1:]]))\n')
    base.evidence.write_new(observer, source.encode())
    paths = {Path(path) for path in prior['frozenTools']} - {helper_path, Path(prior['vmExecutable'])}
    paths |= {p for p in runner.CLI.parents[2].rglob('*') if p.is_file()}
    paths |= {Path(__file__).resolve(), starter, observer, window / 'scoped-amfidont.py',
              current.WORK / 'finalization.json', OUT / 'manifest.json'}
    paths |= {TOOLS / name for name in ('observe_t33_consumer_runtime.py', 'observe_t32_budgeted_runtime.py',
        't32_runtime_hash_only_transport.py', 't32_runtime_rpc_transport.py', 't33_consumer_observations.py',
        't32_t33_runtime_evidence.py', 't32_runtime_preflight.py', 'test_t33_consumer_preparation.py')}
    frozen = {str(path.resolve(strict=True)): base.evidence.digest(path) for path in sorted(paths)}
    plan = copy.deepcopy(prior)
    # Remove stale snapshot/qualification references from the historical template.
    for key in ('runtimeSnapshotOnly', 'CFWAuthorityCopied', 'sourceVM', 'sourceSnapshotManifestSHA256',
                'sourceVMGenerationID', 'sourcePublicationTransactionID', 'signatureTimeQualification',
                'signatureTimeQualificationSHA256'):
        plan.pop(key, None)
    plan.update(scope='One EXP GUI, Settings About and complete AA.gl observation after unlock attempt',
        approved=False, vm=str(runner.VM), vmExecutable=str(binary), vmSHA256=vm_sha, CDHash=cdhash,
        expectedDiskIdentity=identity, expectedCurrentImageSHA256=disk_sha, backup=str(backup),
        backupManifestSHA256=base.evidence.digest(WORK / 'runtime-backup.json'), frozenTools=frozen,
        generationID=runner.GENERATION, transactionID=phase['transactionID'], expectedBuildVersion='23Z999999',
        runtimeObserver=str(observer), rootWindowStarter=str(starter), socketPreflight=geometry,
        priorOfflinePlanSHA256=final['planSHA256'], priorOfflineManifestSHA256=final['manifestSHA256'],
        priorExactWholeFileAcceptancePassed=True, trustedGuestOriginQualified=True,
        runtimeValidated=False, patchCausalityValidated=False, sourceVMWritten=False)
    base.save(WORK / 'runtime-plan.json', plan)
    return dict(state='runtime-plan-prepared-not-approved', planSHA256=base.evidence.digest(WORK / 'runtime-plan.json'),
                bootBackupFiles=len(files), frozenTools=len(frozen), CDHash=cdhash, VMStarts=0, securityWindows=0)


if __name__ == '__main__':
    if sys.argv[1:] != ['--prepare-only']:
        raise ValueError('Preparation only; no runtime execution entrypoint')
    print(json.dumps(prepare()), flush=True)
