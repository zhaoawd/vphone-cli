"""Preserve bootstrap hidden members through the actual EXP Shell and guards."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

from tests import test_patch_plan_gate as fixtures
from patchers import component_effects as effects, guest_write, plan_gate as gate

ROOT = Path(__file__).resolve().parents[1]


class EXPBootstrapFlattenTests(unittest.TestCase):
    setUp = fixtures.FrozenGateTests.setUp
    publish = fixtures.FrozenGateTests.publish
    load = fixtures.FrozenGateTests.load

    def bootstrap(self):
        _, digest = guest_write.target_table()
        self.entries.append(dict(id='preboot-jb-bootstrap-install', disposition='guestUncovered', recordRules=[
            dict(literal='guest-target-map-v1:'+digest+':preboot-jb-bootstrap-install', hexadecimalOffsetSuffix=False)]))
        self.plan['variant'] = self.plan['gates']['variant'] = self.context['variant'] = 'exp'
        self.publish()
        os.environ.update(VPHONE_CFW_VARIANT='exp', VPHONE_FROZEN_PLAN_SHA256=self.digest,
                          VPHONE_FROZEN_CONTEXT=json.dumps(self.context))
        plan = self.load()
        original = self.stage/'bootstrap/jb'; original.mkdir(parents=True)
        (original/'.procursus_strapped').write_bytes(b'')
        (original/'usr').mkdir()
        destination = self.mount/'mnt5'/('A'*96)/'jb-vphone/procursus'
        destination.mkdir(parents=True)
        guest_write.run(plan, ['cp','-R',str(original),str(destination)])
        return plan, destination

    def flatten(self, *, fail=False):
        lines = (ROOT/'scripts/cfw_install_exp.sh').read_text().splitlines()
        line, = [line for line in lines if line.startswith('cfw_guest_write mv ') and '/procursus/jb' in line]
        wrapper = 'cfw_guest_write() { return 19; }' if fail else (
            'cfw_guest_write() { '+str(Path(sys.executable))+' -B '+str(ROOT/'scripts/patchers/plan_gate.py')+' write "$@"; }')
        script = ('set -euo pipefail\n'+wrapper+'\n'+f'MNT5={str(self.mount/"mnt5")!r}\n'
                  +f'BOOT_HASH={"A"*96}\nJB_DIR_NAME=jb-vphone\n'+line+'\n')
        return subprocess.run(['/bin/zsh','-c',script], env=dict(os.environ), pass_fds=(self.lock_fd,),
                              capture_output=True, text=True)

    def test_hidden_marker_survives_exact_transport_and_final_readback(self):
        plan, destination = self.bootstrap()
        completed = self.flatten()
        self.assertEqual(completed.returncode,0,completed.stdout+completed.stderr)
        guest_write.run(plan,['rm','-rf',str(destination/'jb')])
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        outputs=effects.verify_rows(plan,rows,{'preboot':self.mount/'mnt5'},self.evidence.parent/'effect-blobs')
        self.assertTrue((destination/'.procursus_strapped').is_file(),completed.stdout+completed.stderr)
        self.assertEqual((destination/'.procursus_strapped').read_bytes(),b'')
        self.assertTrue(any(row['target'].endswith('/procursus/.procursus_strapped') for row in outputs))
        (destination/'.procursus_strapped').write_bytes(b'unrecorded drift')
        with self.assertRaises(ValueError):
            effects.verify_rows(plan,rows,{'preboot':self.mount/'mnt5'},self.evidence.parent/'effect-blobs')

    def test_guard_failure_is_not_suppressed(self):
        _, destination = self.bootstrap()
        completed = self.flatten(fail=True)
        self.assertEqual(completed.returncode,19,completed.stdout+completed.stderr)
        self.assertTrue((destination/'jb/.procursus_strapped').is_file())


if __name__ == '__main__':
    unittest.main()
