"""Exercise the actual guarded patcher after its producer's staging copy."""
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import sys
import unittest
from unittest.mock import patch

from tests import test_patch_plan_gate as fixtures
from patchers import cfw, guest_write


class BuildVersionTargetBindingTests(unittest.TestCase):
    setUp=fixtures.FrozenGateTests.setUp
    publish=fixtures.FrozenGateTests.publish
    load=fixtures.FrozenGateTests.load

    def prepare(self,volume):
        _,digest=guest_write.target_table()
        declaration='system-systemversion-cfw-build_version'
        self.entries.append(dict(id=declaration,disposition='guestUncovered',recordRules=[
            dict(literal='guest-target-map-v1:'+digest+':'+declaration,hexadecimalOffsetSuffix=False)]))
        self.plan['variant']='exp';self.plan['gates']['variant']='exp'
        self.context.update(variant='exp',spoofBuild='23Z999999');self.publish()
        os.environ.update(VPHONE_CFW_VARIANT='exp',VPHONE_FROZEN_PLAN_SHA256=self.digest,
                          VPHONE_FROZEN_CONTEXT=json.dumps(self.context))
        if volume=='preboot':
            source=self.mount/'mnt5/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist'
            target='preboot:/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist'
        else:
            source=self.mount/'mnt1/System/Library/CoreServices/SystemVersion.plist'
            target='system:/System/Library/CoreServices/SystemVersion.plist'
        source.parent.mkdir(parents=True,exist_ok=True)
        source.write_bytes(plistlib.dumps(dict(ProductBuildVersion='23A341',ProductVersion='26.0')))
        staged=self.stage/(str(source).replace('/','_')+'.plist')
        guest_write.run(self.load(),['cp',str(source),str(staged)])
        self.assertEqual(guest_write.logical(source),target)
        self.assertEqual(json.loads(self.evidence.read_text().splitlines()[-1])['target'],target)
        return staged,target,source

    def invoke(self,staged):
        with patch.object(sys,'argv',['cfw.py','patch-build-version',str(staged),'23Z999999']), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as stopped:cfw.main()
        self.assertEqual(stopped.exception.code,0)

    def test_root_staging_copy_keeps_its_source_target(self):
        staged,target,source=self.prepare('system');self.invoke(staged)
        self.assertEqual(json.loads(self.evidence.read_text().splitlines()[-1])['target'],target)
        self.assertEqual(plistlib.loads(source.read_bytes())['ProductBuildVersion'],'23A341')

    def test_preboot_staging_copy_keeps_its_source_target(self):
        staged,target,source=self.prepare('preboot');self.invoke(staged)
        self.assertEqual(json.loads(self.evidence.read_text().splitlines()[-1])['target'],target)
        self.assertEqual(plistlib.loads(source.read_bytes())['ProductBuildVersion'],'23A341')


if __name__=='__main__':unittest.main()
