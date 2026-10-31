"""Compose readonly Cryptex copy and three real guarded DSC command invocations."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import struct
import sys
import unittest
from unittest.mock import patch

from tests import test_patch_plan_gate as fixtures
from tests.test_component_signatures import signed_macho
from patchers import cfw, component_effects as effects, cryptex_source, guest_write, plan_gate as gate


class EXPStagedDSCEffectsTests(unittest.TestCase):
    setUp=fixtures.FrozenGateTests.setUp
    publish=fixtures.FrozenGateTests.publish
    load=fixtures.FrozenGateTests.load

    def cache(self,code):
        data=bytearray(signed_macho(code));data[:16]=b'dyld_v1 arm64e'.ljust(16,b' ')
        struct.pack_into('<QQ',data,0x28,4096,len(data)-4096)
        data[4168:4200]=hashlib.sha256(data[:4096]).digest()
        return bytes(data)

    def test_readonly_copy_then_hv_camera_iomfb_uses_installed_effect_chain(self):
        _,digest=guest_write.target_table()
        for declaration in ('system-cryptex-boot-install','dyld-exp-hv_vmm','dyld-cfw-camera','dyld-boot-iomfb_swapend'):
            self.entries.append(dict(id=declaration,disposition='guestUncovered',recordRules=[
                dict(literal='guest-target-map-v1:'+digest+':'+declaration,hexadecimalOffsetSuffix=False)]))
        self.plan['variant']='exp';self.plan['gates']['variant']='exp';self.context['variant']='exp';self.publish()
        os.environ.update(VPHONE_CFW_VARIANT='exp',VPHONE_FROZEN_PLAN_SHA256=self.digest,
                          VPHONE_FROZEN_CONTEXT=json.dumps(self.context))
        plan=self.load();store=self.evidence.parent/'effect-blobs'
        image=self.stage/'CryptexSystemOS.dmg';image.write_bytes(b'immutable source image fixture')
        original=self.vm/'.firmware-generations'/self.context['generationID']/'originals/SystemOS.dmg'
        original.parent.mkdir(parents=True);original.write_bytes(image.read_bytes())
        binding=dict(schemaVersion=1,generationID=self.context['generationID'],planDigest=plan.record['planSHA256'],
            source=str(original),sourceSHA256=effects.digest(original),cacheSHA256=effects.digest(image))
        cryptex_source.marker(image).write_bytes(gate.canonical(binding))
        source=self.mount/'mnt_sysos';relative=Path('System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e')
        member=source/relative;member.parent.mkdir(parents=True);member.write_bytes(self.cache(b'00000000'))
        (source/'required-sibling').write_bytes(b'original sibling')
        target=self.mount/'mnt1/System/Cryptexes/OS';target.mkdir(parents=True)
        info=plistlib.dumps(dict(images=[{'image-path':str(image),'system-entities':[{'mount-point':str(source)}]}]))
        with patch.object(cryptex_source.subprocess,'check_output',return_value=info):
            guest_write.run(plan,['cp','-R',str(source)+'/.',str(target)])
        installed=target/relative;directory=installed.parent
        calls=(('patch-hv-vmm-dsc','patch_hv_vmm_in_dsc',b'10000000',[]),
               ('patch-camera-dsc','apply_all_camera_patches',b'11000000',[str(installed)]),
               ('patch-iomfb-swapend','patch_iomfb_swapend',b'11100000',['--target-size','0x560']))
        for command,function,code,extra in calls:
            def produce(path,*args,**kwargs):
                self.assertEqual(Path(path),directory)
                installed.write_bytes(self.cache(code));return {}
            with patch.object(cfw,function,side_effect=produce), \
                 patch.object(sys,'argv',['cfw.py',command,str(directory),*extra]), \
                 contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit) as result:cfw.main()
                self.assertEqual(result.exception.code,0)
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        self.assertEqual([row['declarationID'] for row in rows[1:]],
            ['dyld-exp-hv_vmm','dyld-cfw-camera','dyld-boot-iomfb_swapend'])
        self.assertTrue(all('sourceImage' not in row for row in rows[1:]))
        outputs=effects.verify_rows(plan,rows,{'system':self.mount/'mnt1','dsc':directory},store)
        self.assertTrue(any(row['target']=='dsc:/dyld_shared_cache_arm64e' for row in outputs))
        self.assertEqual(member.read_bytes(),self.cache(b'00000000'))
        self.assertEqual(image.read_bytes(),b'immutable source image fixture')
        (target/'required-sibling').write_bytes(b'unrecorded mutation')
        with self.assertRaises(ValueError):effects.verify_rows(plan,rows,{'system':self.mount/'mnt1','dsc':directory},store)


if __name__=='__main__':unittest.main()
