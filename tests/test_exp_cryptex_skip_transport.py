"""Model the installed-Cryptex fast path using real effect and final readers."""
import hashlib
import json
import os
from pathlib import Path
import struct
import unittest

from tests import test_patch_plan_gate as fixtures
from tests.test_component_signatures import signed_macho
from patchers import component_effects as effects, cryptex_source, plan_gate as gate


class EXPSkipTransportTests(unittest.TestCase):
    setUp=fixtures.FrozenGateTests.setUp
    publish=fixtures.FrozenGateTests.publish
    load=fixtures.FrozenGateTests.load

    def cache(self,code):
        data=bytearray(signed_macho(code));data[:16]=b'dyld_v1 arm64e'.ljust(16,b' ')
        struct.pack_into('<QQ',data,0x28,4096,len(data)-4096)
        data[4168:4200]=hashlib.sha256(data[:4096]).digest()
        return bytes(data)

    def observe_without_copy(self,installed_patched):
        from patchers import guest_write
        _,digest=guest_write.target_table();declaration='dyld-exp-hv_vmm'
        self.entries.append(dict(id=declaration,disposition='guestUncovered',recordRules=[
            dict(literal='guest-target-map-v1:'+digest+':'+declaration,hexadecimalOffsetSuffix=False)]))
        self.plan['variant']='exp';self.plan['gates']['variant']='exp';self.context['variant']='exp';self.publish()
        plan=self.load();gate.require_write_context(plan);store=self.evidence.parent/'effect-blobs'
        source=self.mount/'mnt_sysos_hv_vmm/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e'
        source.parent.mkdir(parents=True);source.write_bytes(self.cache(b'00000000'))
        image=self.stage/'CryptexSystemOS.dmg';image.write_bytes(b'image fixture')
        original=self.vm/'.firmware-generations'/self.context['generationID']/'originals/SystemOS.dmg'
        original.parent.mkdir(parents=True);original.write_bytes(b'original fixture')
        observation=cryptex_source.observation(image)
        binding=dict(schemaVersion=1,generationID=self.context['generationID'],planDigest=plan.record['planSHA256'],
            source=str(original),sourceSHA256=cryptex_source.file_sha(original),cacheSHA256=observation['sha256'],imageBefore=observation,
            baselineTree=cryptex_source.tree(self.mount/'mnt_sysos_hv_vmm'))
        cryptex_source.marker(image).write_bytes(gate.canonical(binding))
        before=effects.capture_input(source,store);snapshot=gate.snapshot(source)
        source.write_bytes(self.cache(b'10000000'))
        gate.append_evidence(plan,declaration,'dsc:/'+source.name,source,snapshot,gate.snapshot(source),
            source_image=image,source_binding=cryptex_source.proof(plan,image),effect=effects.capture_change(before,source,store))
        installed=self.mount/'mnt1/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld'/source.name
        installed.parent.mkdir(parents=True)
        installed.write_bytes(self.cache(b'10000000' if installed_patched else b'00000000'))
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        return effects.verify_rows(plan,rows,{'system':self.mount/'mnt1','dsc':installed.parent},store)

    def test_skip_cannot_deploy_new_cached_dsc_changes_to_pristine_target(self):
        with self.assertRaisesRegex(ValueError,'final transported member differs'):
            self.observe_without_copy(False)

    def test_existing_identical_target_still_requires_exact_final_readback(self):
        outputs=self.observe_without_copy(True)
        self.assertEqual(len(outputs),1)
        self.assertEqual(outputs[0]['target'],'dsc:/dyld_shared_cache_arm64e')


if __name__=='__main__':unittest.main()
