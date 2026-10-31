"""Compose real base cleanup and EXP LaunchDaemon staging without path reuse."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import unittest

from tests import test_patch_plan_gate as fixtures
from patchers import component_effects as effects

ROOT = Path(__file__).resolve().parents[1]


class EXPPlistStagingLifetimeTests(unittest.TestCase):
    setUp = fixtures.FrozenGateTests.setUp
    publish = fixtures.FrozenGateTests.publish
    load = fixtures.FrozenGateTests.load

    def chain(self):
        self.plan['variant'] = self.plan['gates']['variant'] = self.context['variant'] = 'exp'
        self.publish()
        os.environ.update(VPHONE_CFW_VARIANT='exp',VPHONE_FROZEN_PLAN_SHA256=self.digest,
                          VPHONE_FROZEN_CONTEXT=json.dumps(self.context))
        plan=self.load()
        guest=self.mount/'mnt1/System/Library/xpc/launchd.plist';guest.parent.mkdir(parents=True)
        raw=plistlib.dumps(dict(LaunchDaemons={}))
        guest.write_bytes(raw);guest.with_suffix('.plist.bak').write_bytes(raw)
        base=(ROOT/'scripts/cfw_install.sh').read_text().splitlines()
        start,=[line for line in base if line.startswith('cfw_guest_write cp "$MNT1/System/Library/xpc/launchd.plist.bak"')]
        finish,=[line for line in base if line.startswith('cfw_guest_write cp -R "$TEMP_DIR/launchd.plist"')]
        cleanup,=[line for line in base if line=='cfw_guest_write rm -rf "$TEMP_DIR"']
        exp=(ROOT/'scripts/cfw_install_exp.sh').read_text().splitlines()
        blocks=[]
        for index,line in enumerate(exp):
            if line.startswith('    cfw_guest_write cp "$MNT1/System/Library/xpc/launchd.plist"'):
                # guest -> private copy, actual daemon patcher, private -> guest copy, chmod
                blocks.extend(exp[index:index+5])
        self.assertEqual(len(blocks),10)
        assignments=[line for line in exp if line.startswith('JB_LAUNCHD_PLIST=')]
        wrapper='cfw_guest_write() { '+str(Path(sys.executable))+' -B '+str(ROOT/'scripts/patchers/plan_gate.py')+' write "$@"; }'
        script=('set -euo pipefail\n'+wrapper+'\n'+f'MNT1={str(self.mount/"mnt1")!r}\nTEMP_DIR={str(self.stage)!r}\n'
                +f'PYTHON3={sys.executable!r}\nSCRIPT_DIR={str(ROOT/"scripts")!r}\n'
                +f'SETUP_PLIST={str(ROOT/"scripts/vphone_jb_setup.plist")!r}\n'
                +f'SSHD_PLIST={str(ROOT/"scripts/vphone_sshd.plist")!r}\n'
                +start+'\n'+finish+'\n'+cleanup+'\nmkdir -p "$TEMP_DIR"\n'
                +'\n'.join(assignments+blocks)+'\n')
        result=subprocess.run(['/bin/zsh','-c',script],env=dict(os.environ),pass_fds=(self.lock_fd,),
                              capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        store=self.evidence.parent/'effect-blobs'
        outputs=effects.verify_rows(plan,rows,{'system':self.mount/'mnt1'},store)
        return plan,guest,rows,store,outputs

    def test_base_cleanup_and_both_exp_injections_keep_complete_effect_chain(self):
        _,guest,rows,_,outputs=self.chain()
        daemons=plistlib.loads(guest.read_bytes())['LaunchDaemons']
        self.assertIn('/System/Library/LaunchDaemons/com.vphone.jb-setup.plist',daemons)
        self.assertIn('/System/Library/LaunchDaemons/com.vphone.sshd.plist',daemons)
        self.assertTrue(any(row['target']=='system:/System/Library/xpc/launchd.plist' for row in outputs))
        self.assertTrue(any(Path(row['path']).name=='jb_launchd.plist' for row in rows))

    def test_unrecorded_guest_plist_mutation_is_still_rejected(self):
        plan,guest,rows,store,_=self.chain()
        guest.write_bytes(plistlib.dumps(dict(LaunchDaemons={})))
        with self.assertRaises(ValueError):
            effects.verify_rows(plan,rows,{'system':self.mount/'mnt1'},store)


if __name__=='__main__':
    unittest.main()
