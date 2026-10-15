"""Pure RAM tests for the pre-boot witness gates; no helper main or VM access."""
import ast
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

E = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, E / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


fixtures = load('task8_documents_freeze_fixtures', 'test-verify-documents-persistence.py')
h = load('task8_documents_freeze_tested', 'freeze-documents-rollback-b-boot.py')


def scenario():
    evidence = fixtures.synthetic_complete()
    # Use the saved real host4 binding bytes; future R_B rows remain in RAM only.
    bind = (E / 'kernel-v9-rollback-a-host4-host-binding.json').read_bytes()
    rebind_name = h.LABEL + '-host4-host-rebind-check.json'
    rebind = evidence.json(rebind_name)
    rebind['after']['binding_sha256'] = h.v.sha(bind)
    evidence.put(rebind_name, rebind)
    owner_name = h.LABEL + '-host4-binding-owner-check.json'
    owner = evidence.json(owner_name); owner['binding_sha256'] = h.v.sha(bind)
    evidence.put(owner_name, owner)
    live = {'launchpad.json': bind,
            '.firmware-component-receipts.json': evidence.data[h.LABEL + '-committed-component-receipts.json'],
            '.firmware-desired-plan.json': evidence.data[h.LABEL + '-before-desired.json']}
    return evidence, live


class FreezeExpectationsTests(unittest.TestCase):
    def setUp(self):
        self.guards = [patch.object(subprocess, name, side_effect=AssertionError('Native commands forbidden'))
                       for name in ('run', 'Popen', 'call', 'check_call', 'check_output')]
        self.guards += [patch.object(os, name, side_effect=AssertionError('Native process operations forbidden'))
                        for name in ('kill', 'killpg', 'system', 'posix_spawn') if hasattr(os, name)]
        for guard in self.guards: guard.start()
    def tearDown(self):
        for guard in reversed(self.guards): guard.stop()
    def test_valid_memory_witness_builds_expected_metadata(self):
        evidence, live = scenario(); expected = h.build_expectations(evidence, live)
        self.assertEqual(expected['transaction_id'], h.v.RB_TX)
        self.assertEqual(expected['payload_sha256'], h.v.PAYLOAD_B)
        self.assertEqual(expected['receipt_sha256'], h.v.sha(live['.firmware-component-receipts.json']))
    def test_wrong_formal_rebind_command_or_target_refuses(self):
        for field, value in [('target_version', h.v.V9), ('command', ['preview']), ('exit_code', 1)]:
            evidence, live = scenario(); name = h.LABEL + '-host4-host-rebind-check.json'
            row = evidence.json(name); row[field] = value; evidence.put(name, row)
            with self.subTest(field=field), self.assertRaises(ValueError): h.build_expectations(evidence, live)
    def test_rebind_cannot_change_kernel_receipt_desired_journal_proof_or_files(self):
        for field in ('binding', 'receipt_sha256', 'desired_sha256', 'journal_sha256', 'proof_sha256', 'files_metadata'):
            evidence, live = scenario(); name = h.LABEL + '-host4-host-rebind-check.json'; row = evidence.json(name)
            row['after'][field] = {} if field in ('binding', 'files_metadata') else '0' * 64; evidence.put(name, row)
            with self.subTest(field=field), self.assertRaises(ValueError): h.build_expectations(evidence, live)
    def test_owner_label_uid_gid_mode_and_inode_refuse(self):
        for field in ('rebind_label', 'uid', 'gid', 'mode', 'inode'):
            evidence, live = scenario(); name = h.LABEL + '-host4-binding-owner-check.json'; row = evidence.json(name)
            if field == 'rebind_label': row[field] = 'wrong-label'
            else: row['after'][field] = 1
            evidence.put(name, row)
            with self.subTest(field=field), self.assertRaises(ValueError): h.build_expectations(evidence, live)
    def test_live_bytes_and_digest_must_match_saved_contract(self):
        for name in ('launchpad.json', '.firmware-component-receipts.json', '.firmware-desired-plan.json'):
            evidence, live = scenario(); live[name] += b' '
            with self.subTest(name=name), self.assertRaises(ValueError): h.build_expectations(evidence, live)
    def test_uncommitted_and_preview_publication_refuse(self):
        evidence, live = scenario(); name = h.LABEL + '.json'; row = evidence.json(name)
        row['command'] += ['--preview']; evidence.put(name, row)
        with self.assertRaises(ValueError): h.build_expectations(evidence, live)
        evidence, live = scenario(); name = h.LABEL + '-committed-journal.json'; row = evidence.json(name)
        row['phase'] = 'publishing'; evidence.put(name, row)
        with self.assertRaises(ValueError): h.build_expectations(evidence, live)
    def test_source_identity_changes_refuse(self):
        evidence, live = scenario(); evidence.changed = h.LABEL + '-readback.json'
        with self.assertRaises(ValueError): h.build_expectations(evidence, live)
    def test_validation_has_no_optimizable_asserts(self):
        for name in ('freeze-documents-rollback-b-boot.py', 'verify-documents-persistence.py'):
            self.assertFalse(any(isinstance(node, ast.Assert) for node in ast.walk(ast.parse((E / name).read_text()))))


if __name__ == '__main__': unittest.main(verbosity=2)
