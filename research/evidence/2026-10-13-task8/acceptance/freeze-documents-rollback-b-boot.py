"""Freeze V4 expectations after saved actual B readback and formal host4 contracts."""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import sys

E = Path(__file__).resolve().parent
VM = Path('/private/tmp/vphone-task8-acceptance-vms/task8-copy')
LABEL = 'kernel-v9-documents-rollback-b'


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, E / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


v = load('task8_documents_verifier_for_freeze', 'verify-documents-persistence.py')


def build_expectations(evidence, live):
    """Pure evidence seam: no VM read, command or output write."""
    inputs = v.FrozenInputs(evidence)
    try:
        commit, journal, publication, proof, before, names = v.validate_commit(inputs, LABEL, v.RB_TX, 4, v.B_TX)
        target, _, _, _, _, _ = v.validate_commit(inputs, v.HISTORY, v.B_TX, 3)
        for field in ('payload_sha256', 'im4p_sha256', 'img4_sha256'):
            v.require(commit['kernel'][field] == target['kernel'][field], 'Actual historical B kernel differs')
        v.require(commit['kernel']['payload_sha256'] == v.PAYLOAD_B, 'Expected known B payload')
        rebind = v.validate_rebind(inputs, LABEL + '-host4', commit['binding'],
                                  inputs.digest(names['component-receipts']), v.DESIRED_B_SHA,
                                  inputs.digest(names['journal']), inputs.digest(names['installed-component-proof']), v.V4)
        committed_binding = next(item['output'] for item in journal['metadata'] if item['name'] == 'launchpad.json')
        v.require(rebind['before']['binding_sha256'] == committed_binding, 'Host4 rebind did not start from committed bytes')
        v.require(set(live) == {'launchpad.json', '.firmware-component-receipts.json', '.firmware-desired-plan.json'}, 'Wrong live metadata set')
        binding = v.decode(live['launchpad.json'])
        current = v.decode(live['.firmware-component-receipts.json'])
        v.require(binding == rebind['after']['binding'] == {'bundle': v.V4, 'kernel': v.V9}, 'Live binding differs')
        v.require(current == publication and live['.firmware-component-receipts.json'] == inputs.raw(names['component-receipts']), 'Live committed receipt differs')
        v.require(v.sha(live['launchpad.json']) == rebind['after']['binding_sha256'], 'Live binding digest differs')
        v.require(v.sha(live['.firmware-desired-plan.json']) == rebind['after']['desired_sha256'] == before['desired_sha256'] == v.DESIRED_B_SHA, 'Live desired B differs')
        return dict(binding=binding, binding_sha256=v.sha(live['launchpad.json']),
                    receipt_sha256=v.sha(live['.firmware-component-receipts.json']),
                    desired_sha256=v.sha(live['.firmware-desired-plan.json']),
                    transaction_id=commit['transaction_id'], payload_sha256=commit['kernel']['payload_sha256'])
    finally:
        inputs.recheck()


def main():
    v.require(len(sys.argv) == 1, 'No arguments permitted')
    path = E / (LABEL + '-boot-expectations.json')
    v.require(not os.path.lexists(path), 'Boot expectations already exist')
    fd = os.open(VM, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for name in ('.firmware-transaction', '.firmware-desired-pending.json'):
            v.require(not os.path.lexists(VM / name), 'Pending transaction')
        marker = load('task8_marker_strict_read_for_freeze', 'guest-rollback-marker-v2.py')
        live = {name: marker.strict_read(VM / name) for name in ('launchpad.json', '.firmware-component-receipts.json', '.firmware-desired-plan.json')}
        expected = build_expectations(v.FileEvidence(), live)
        for name, data in live.items(): v.require(marker.strict_read(VM / name) == data, 'Live inputs changed before freeze')
        with v.reserve_output(path) as output:
            output.write((json.dumps(expected, indent=2, allow_nan=False) + '\n').encode())
            output.flush(); os.fsync(output.fileno())
        print(json.dumps(expected), flush=True)
    finally:
        os.close(fd)


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    try: main()
    except Exception as error:
        print(type(error).__name__ + ': ' + str(error), file=sys.stderr)
        sys.exit(1)
