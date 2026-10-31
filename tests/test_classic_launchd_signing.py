"""Actual guarded classic injection -> signing -> final-copy regression."""
import contextlib
import hashlib
import io
import json
import os
import shutil
import struct
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

from tests import test_patch_plan_gate as fixtures
from tests import test_component_signatures as signature_fixtures
from patchers import cfw, guest_write, component_effects as effects


class ClassicLaunchdSigningTests(unittest.TestCase):
    setUp=fixtures.FrozenGateTests.setUp
    publish=fixtures.FrozenGateTests.publish
    load=fixtures.FrozenGateTests.load

    def run_chain(self, initial, text, *, signer=None, jetsam=False):
        _,digest=guest_write.target_table()
        for declaration in ('system-launchd-jb-hook','system-launchd-boot-jetsam_panic_guard_bypass'):
            self.entries.append(dict(id=declaration,disposition='guestUncovered',recordRules=[
                dict(literal='guest-target-map-v1:'+digest+':'+declaration,hexadecimalOffsetSuffix=False)]))
        self.plan['variant']='exp';self.plan['gates']['variant']='exp';self.context['variant']='exp';self.publish()
        os.environ.update(VPHONE_CFW_VARIANT='exp',VPHONE_FROZEN_PLAN_SHA256=self.digest,
                          VPHONE_FROZEN_CONTEXT=json.dumps(self.context))
        plan=self.load();target=self.mount/'mnt1/sbin/launchd';target.parent.mkdir()
        target.write_bytes(initial)
        source=self.stage/'launchd'
        guest_write.run(plan,['cp',str(target),str(source)])
        with patch.object(sys,'argv',['cfw.py','inject-dylib',str(source),'/b']),contextlib.redirect_stdout(io.StringIO()):
            cfw.main()
        if jetsam:
            with patch.object(sys,'argv',['cfw.py','patch-launchd-jetsam',str(source)]),contextlib.redirect_stdout(io.StringIO()):
                cfw.main()
        # The injector is real. Only the signing tool is modeled; its output
        # goes through the unchanged real signing and final-effect validators.
        def modeled_signer(argv):
            path=Path(argv[-1]);body=bytearray(path.read_bytes()[:4096])
            body.extend(bytes(4096-len(body)));count,size=struct.unpack_from('<II',body,16)
            struct.pack_into('<II',body,16,count+1,size+16)
            tail=signature_fixtures.signed_macho()[4096:]
            struct.pack_into('<IIII',body,32+size,0x1d,16,4096,len(tail))
            data=body+tail;data[4168:4200]=hashlib.sha256(data[:4096]).digest();path.write_bytes(data)
        guest_write.sign(plan,['ldid','-S',str(source)],execute=signer or modeled_signer)
        if not jetsam:
            self.assertEqual(source.read_bytes()[text:text+64],initial[text:text+64])
        guest_write.run(plan,['cp',str(source),str(target)])
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        outputs=effects.verify_rows(plan,rows,{'system':self.mount/'mnt1'},self.evidence.parent/'effect-blobs')
        self.assertEqual(len(outputs),1);self.assertEqual(outputs[0]['target'],'system:/sbin/launchd')
        return source, rows, outputs

    def test_classic_injection_reserves_space_before_actual_sign_guard(self):
        initial,text=signature_fixtures.SigningCommandSpaceTests.signed_injection_input()
        self.run_chain(initial,text)

    @unittest.skipUnless(shutil.which('ldid'), 'ldid unavailable')
    def test_classic_injection_with_actual_ldid(self):
        initial,text=signature_fixtures.SigningCommandSpaceTests.signed_injection_input()
        self.run_chain(initial,text,signer=lambda argv: subprocess.run(argv,check=True,capture_output=True))

    @unittest.skipUnless(shutil.which('ldid'), 'ldid unavailable')
    def test_missing_reservation_reproduces_original_ldid_collision(self):
        from patchers import component_signatures
        initial,text=signature_fixtures.SigningCommandSpaceTests.signed_injection_input()
        with patch.object(component_signatures,'reserve_signature_command',return_value=False):
            with self.assertRaisesRegex(ValueError,'signature load command overwrote non-padding bytes'):
                self.run_chain(initial,text,signer=lambda argv: subprocess.run(argv,check=True,capture_output=True))


if __name__=='__main__':unittest.main()
